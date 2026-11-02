#!/usr/bin/env python3
"""Build the static site of the Helm repository (GitHub Pages, branch gh-pages).

Inputs: the charts (charts/*/Chart.yaml), the UnxWares images (the matrix of .github/workflows/images.yaml, the
`ARG VERSION` of each Dockerfile, its .trivyignore, the table of images/README.md) and the CI results gathered by
.github/scripts/site-collect.py. Output, in <output dir>:
  index.html, charts/<chart>.html, images/<image>.html, status.json (the same data as JSON), assets/ (styles,
  fonts, logo, copied from .github/site/assets).

The pages carry no build timestamp, so that an unchanged result gives byte-identical files and no commit. No file
is deleted here; status.json lists the generated files ("files"), so that the publishing job can remove a page of a
chart or image that no longer exists, by name.

usage: .github/scripts/site.py <results.json> <output dir>
"""
import datetime, html, json, pathlib, re, shutil, sys
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSETS = ROOT / ".github/site/assets"
SITE = "https://helm.unxwares.studio"
OURS = "ghcr.io/unxwares/"
SEVERITIES = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"]
# Files of gh-pages that belong to the release workflow: never generated here.
PROTECTED = {"index.yaml", "CNAME", "artifacthub-repo.yml", "pgp-public-key.asc", ".nojekyll"}
CHANGE_KINDS = {"added": "Added", "changed": "Changed", "deprecated": "Deprecated", "removed": "Removed",
                "fixed": "Fixed", "security": "Security"}

e = html.escape


# --- inputs --------------------------------------------------------------------------------------------------------

def load_yaml_block(text, default):
    try:
        return yaml.safe_load(text or "") or default
    except yaml.YAMLError:
        return default


def load_charts():
    charts = []
    for path in sorted((ROOT / "charts").glob("*/Chart.yaml")):
        meta = yaml.safe_load(path.read_text())
        ann = meta.get("annotations") or {}
        changes = []
        for c in load_yaml_block(ann.get("artifacthub.io/changes"), []):
            if isinstance(c, str):
                changes.append({"kind": "", "description": c})
            elif isinstance(c, dict) and c.get("description"):
                changes.append({"kind": str(c.get("kind", "")), "description": str(c["description"])})
        images = [{"name": str(i.get("name", "")), "image": str(i["image"])}
                  for i in load_yaml_block(ann.get("artifacthub.io/images"), []) if isinstance(i, dict) and i.get("image")]
        sign = load_yaml_block(ann.get("artifacthub.io/signKey"), {})
        charts.append({
            "name": meta["name"], "version": str(meta.get("version", "")), "appVersion": str(meta.get("appVersion", "")),
            "description": str(meta.get("description", "")).strip(), "kubeVersion": str(meta.get("kubeVersion", "")),
            "displayName": str(ann.get("artifacthub.io/displayName", meta["name"])),
            "containsSecurityUpdates": str(ann.get("artifacthub.io/containsSecurityUpdates", "")).lower() == "true",
            "images": images, "changes": changes, "signKey": sign if isinstance(sign, dict) else {},
            "has_unit_tests": any((path.parent / "tests").glob("*_test.yaml")),
        })
    return charts


def inline_md(text):
    """Escape text, keeping `code` spans."""
    parts = re.split(r"`([^`]+)`", text)
    return "".join(f"<code>{e(p)}</code>" if i % 2 else e(p) for i, p in enumerate(parts))


def parse_trivyignore(path):
    """IDs of a .trivyignore with the comment paragraph written above them."""
    accepted, paragraph, current = {}, [], []
    if not path.is_file():
        return accepted
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line.startswith("#"):
            text = line.lstrip("#").strip()
            if text:
                current.append(text)
            elif current:
                paragraph, current = current, []
            continue
        if not line:
            if current:
                paragraph, current = current, []
            continue
        if current:
            paragraph, current = current, []
        vuln = line.split()[0]
        accepted[vuln] = " ".join(paragraph)
    return accepted


def images_readme():
    """images/README.md table: (name, tag) -> upstream, changes."""
    rows = {}
    path = ROOT / "images/README.md"
    if not path.is_file():
        return rows
    for line in path.read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 3 or not cells[0].startswith("`"):
            continue
        for ref in re.findall(r"`([^`:]+):([^`]+)`", cells[0]):
            rows[ref] = {"upstream": cells[1], "changes": cells[2]}
    return rows


def load_images():
    """The UnxWares images built by images.yaml, with their tag, upstream, differences and accepted CVEs."""
    workflow = load_yaml_block((ROOT / ".github/workflows/images.yaml").read_text(), {})
    matrix = (((workflow.get("jobs") or {}).get("build") or {}).get("strategy") or {}).get("matrix") or {}
    entries = [m for m in matrix.get("image", []) if isinstance(m, dict) and m.get("context")]
    if not entries:  # fall back to the Dockerfiles
        entries = [{"name": p.parent.name, "context": str(p.parent.relative_to(ROOT)), "suffix": ""}
                   for p in sorted((ROOT / "images").glob("*/Dockerfile"))]
    readme = images_readme()
    images = []
    for m in entries:
        context = ROOT / m["context"]
        dockerfile = context / "Dockerfile"
        version = ""
        if dockerfile.is_file():
            found = re.search(r"^ARG VERSION=(\S+)", dockerfile.read_text(), re.M)
            version = found.group(1) if found else ""
        tag = version + (m.get("suffix") or "")
        info = readme.get((m["name"], tag)) or next((v for (n, _), v in readme.items() if n == m["name"]), {})
        images.append({
            "name": m["name"], "context": m["context"], "tag": tag, "ref": f"{OURS}{m['name']}:{tag}",
            "slug": m["context"].removeprefix("images/").replace("/", "-"),
            "upstream": info.get("upstream", ""), "changes": info.get("changes", ""),
            "accepted": parse_trivyignore(context / ".trivyignore"),
        })
    return images


# --- formatting ----------------------------------------------------------------------------------------------------

def parse_time(iso):
    return datetime.datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


def day(iso):
    t = parse_time(iso)
    return f"{t.day} {t.strftime('%b %Y')}"


def stamp(iso):
    t = parse_time(iso)
    return f'<time datetime="{e(iso)}">{t.day} {t.strftime("%b %Y, %H:%M")} UTC</time>'


def plural(n, word, words=None):
    return f"{n} {word if n == 1 else (words or word + 's')}"


def st(kind, text):
    return f'<span class="st st-{kind}">{e(text)}</span>'


def sub(html_text):
    return f'<span class="sub">{html_text}</span>' if html_text else ""


def link(href, text):
    return f'<a href="{e(href)}">{text}</a>'


class Site:
    def __init__(self, results):
        self.results = results
        self.repo = results.get("repository", "UnxWares/helm")
        self.gh = f"https://github.com/{self.repo}"
        self.charts = load_charts()
        self.images = load_images()
        self.cve = results.get("cve") or {}
        self.files = []

    # --- data ----------------------------------------------------------------------------------------------------

    def result(self, chart, kind):
        return ((self.results.get("charts") or {}).get(chart) or {}).get(kind)

    def cve_of(self, ref):
        return (self.cve.get("images") or {}).get(ref)

    def image_of(self, ref):
        return next((i for i in self.images if i["ref"] == ref), None)

    def cve_counts(self, ref):
        """critical, high, fixable critical/high, accepted critical/high, total, eosl (None when not scanned)."""
        c = self.cve_of(ref)
        if not c or c.get("scan_failed"):
            return None
        sev = c.get("severity") or {}
        image = self.image_of(ref)
        accepted_ids = set(image["accepted"]) if image else set()
        ch = ("CRITICAL", "HIGH")
        if "fixable" in c:  # report.json
            fixable = c["fixable"].get("CRITICAL", 0) + c["fixable"].get("HIGH", 0)
            vulns = [v for v in c.get("vulnerabilities", []) if v["severity"] in ch]
            accepted = sum(1 for v in vulns if v["id"] in accepted_ids)
            open_fixable = fixable - sum(1 for v in vulns if v["id"] in accepted_ids and v.get("fixed"))
        else:  # summary table of the CVE watch issue: only the fixable critical/high are listed
            fixable = c.get("fixable_critical_high", 0)
            accepted = sum(1 for v in c.get("fixable_critical_high_list", []) if v["id"] in accepted_ids)
            open_fixable = fixable - accepted
        return {"critical": sev.get("CRITICAL", 0), "high": sev.get("HIGH", 0), "medium": sev.get("MEDIUM"),
                "low": sev.get("LOW"), "total": c.get("total"),
                "fixable": fixable, "accepted": accepted, "open_fixable": open_fixable, "eosl": c.get("eosl", False)}

    def cve_phrase(self, counts, long=False):
        if counts is None:
            return st("none", "Not scanned yet")
        main = f"{counts['critical']} critical, {counts['high']} high"
        kind = ("pass" if counts["critical"] + counts["high"] == 0 else
                "fail" if counts["open_fixable"] > 0 else "none")
        detail = []
        if counts["fixable"]:
            detail.append(f"{counts['fixable']} fixable")
        if counts["accepted"]:
            detail.append(f"{counts['accepted']} accepted")
        if long and counts.get("total") is not None:
            detail.append(f"{counts['total']} in total")
        if counts.get("eosl"):
            detail.append("base image end of life")
        return st(kind, main) + sub(e(", ".join(detail)))

    def chart_cve(self, chart):
        """Sum over the default images of the chart."""
        counts = [self.cve_counts(i["image"]) for i in chart["images"]]
        if not counts or any(c is None for c in counts):
            return None
        total = {k: sum(c[k] for c in counts) for k in ("critical", "high", "fixable", "accepted", "open_fixable")}
        total["eosl"] = any(c["eosl"] for c in counts)
        return total

    def latest_date(self):
        dates = [r["date"] for c in (self.results.get("charts") or {}).values() for r in c.values() if r.get("date")]
        dates += [i["date"] for i in (self.results.get("images") or {}).values() if i.get("date")]
        if self.cve.get("date"):
            dates.append(self.cve["date"])
        return max(dates) if dates else None

    # --- result phrases --------------------------------------------------------------------------------------------

    def origin(self, r):
        bits = [stamp(r["date"])]
        if r.get("pr"):
            bits.append(link(r["pr_url"], f"pull request #{r['pr']}"))
        if r.get("commit"):
            bits.append("commit " + link(f"{self.gh}/commit/{r['commit']}", f"<code>{e(r['commit'][:7])}</code>"))
        bits.append(link(r.get("job_url") or r["run_url"], "run"))
        return '<p class="origin">' + " · ".join(bits) + "</p>"

    # Each summary: (kind, word, note, detail, result). kind: pass, fail, none (no result yet), na (no such test);
    # word and note for the table of the index, word and detail for the chart page.

    def lint_summary(self, chart):
        r = self.result(chart["name"], "lint")
        if not r:
            return "none", "No result yet", "", "", None
        helm = r.get("helm") or {}
        versions = sorted(helm)
        first = next(iter(helm.values()), {})
        ci_files = max(first.get("lint_runs", 1) - 1, 0)
        schema = first.get("schema") or {}
        detail = (f"`helm lint --strict` with Helm {' and '.join(versions)}, on the default values and "
                  f"{plural(ci_files, 'ci values file')}")
        if schema:
            detail += (f"; `kubeconform` on Kubernetes {' and '.join(schema.get('kubernetes', []))}, "
                       f"{plural(len(schema.get('renders', [])), 'rendering')}")
        if first.get("default_values_note"):
            detail += (f". The default values need your input ({first['default_values_note']}): they are rendered "
                       "with the ci values only")
        if r["status"] == "passed":
            return "pass", "Passed", "", detail, r
        problems = []
        for v, d in sorted(helm.items()):
            if d.get("lint_failed"):
                problems.append(f"`helm lint` failed with Helm {v}" + (f": {d['lint_error']}" if d.get("lint_error") else ""))
            if d.get("schema_error") or (d.get("schema") or {}).get("invalid"):
                problems.append(f"kubeconform failed ({d.get('schema_error') or 'invalid resources'})")
            if not d.get("schema") and not d.get("lint_failed"):
                problems.append(f"kubeconform did not run with Helm {v}" +
                                (f" (step {d['failed_step']} failed)" if d.get("failed_step") else ""))
        return "fail", "Failed", "lint" if any(d.get("lint_failed") for d in helm.values()) else "kubeconform", \
            "; ".join(problems) or detail, r

    def install_summary(self, chart):
        name = chart["name"]
        r = self.result(name, "install")
        if not r:
            if name in (self.results.get("install_excluded") or []):
                return ("na", "Not installed", "excluded from chart-testing",
                        "Excluded from `ct install` in `lint-test.yaml`: the chart needs prerequisites that a bare kind "
                        "cluster does not have (its README says which)", None)
            return "none", "No result yet", "", "", None
        values = [v["file"] for v in r.get("values", [])]
        total, passed = r.get("tests_total", 0), r.get("tests_passed", 0)
        note = f"helm test {passed} of {total}" if total else "no helm test pod"
        detail = f"Installed on kind with {' and '.join(f'`{v}`' for v in values) or 'its default values'}"
        detail += (f"; `helm test`: {passed} of {plural(total, 'test pod')} succeeded" if total
                   else "; the chart has no `helm test` pod")
        if (r.get("ct_lint") or {}).get("ok") is False:
            detail += f"; `ct lint` failed: {r['ct_lint'].get('error', '')}"
        elif r.get("ct_lint"):
            detail = "`ct lint` passed (version increment, YAML lint). " + detail
        if r["status"] == "passed":
            return "pass", "Passed", note, detail, r
        if r.get("error"):
            detail = f"{r['error']}; {detail}"
        return "fail", "Failed", note, detail, r

    def unit_summary(self, chart):
        r = self.result(chart["name"], "unit")
        if not r:
            if chart["has_unit_tests"]:
                return "none", "No result yet", "", "", None
            return "na", "No tests yet", "", "", None
        if r.get("status") == "error":
            return "fail", "Error", "", r.get("error", ""), r
        detail = f"{plural(r.get('tests', 0), 'test')} in {plural(r.get('suites', 0), 'suite')}".capitalize()
        if r.get("status") == "passed":
            return "pass", "Passed", plural(r.get("passed", 0), "test"), detail + ", all passed", r
        return ("fail", "Failed", f"{r.get('failed', 0)} of {r.get('tests', 0)} tests",
                detail + f": {r.get('failed', 0)} failed, {r.get('passed', 0)} passed", r)

    def e2e_summary(self, chart):
        r = self.result(chart["name"], "e2e")
        if not r:
            if chart["name"] in self.e2e_jobs():
                return "none", "No result yet", "", "", None
            return "na", "No test", "", "", None
        checks = plural(len(r.get("checks", [])), "check")
        if r["status"] == "passed":
            return "pass", "Passed", checks, f"{checks}, all passed".capitalize(), r
        detail = r.get("failure") or (f"Step failed: {r['failed_step']}" if r.get("failed_step") else "")
        return "fail", "Failed", f"{checks} passed before", detail, r

    def e2e_jobs(self):
        if not hasattr(self, "_e2e_jobs"):
            path = ROOT / ".github/workflows/e2e.yaml"
            workflow = load_yaml_block(path.read_text(), {}) if path.is_file() else {}
            self._e2e_jobs = {str(j.get("name", k)) for k, j in (workflow.get("jobs") or {}).items() if isinstance(j, dict)}
        return self._e2e_jobs

    # --- pages ---------------------------------------------------------------------------------------------------

    def page(self, path, title, description, body):
        root = "../" * path.count("/")
        nav = [("index.html#charts", "Charts"), ("index.html#images", "Images"), ("index.html#install", "Install"),
               ("index.html#verify", "Verify"), ("status.json", "Data")]
        items = "".join(f'<li><a href="{root}{h}">{t}</a></li>' for h, t in nav)
        items += f'<li><a href="{self.gh}">GitHub</a></li>'
        doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(description)}">
<meta name="color-scheme" content="light dark">
<link rel="stylesheet" href="{root}assets/site.css">
<link rel="icon" href="{root}assets/mark.svg" type="image/svg+xml">
</head>
<body>
<a class="skip" href="#main">Skip to the content</a>
<header class="masthead"><div class="wrap">
<a class="brand" href="{root}index.html"><picture><source srcset="{root}assets/logo-dark.svg" media="(prefers-color-scheme: dark)"><img src="{root}assets/logo.svg" alt="UnxWares" width="122" height="26"></picture><span>Helm charts</span></a>
<nav aria-label="Site"><ul>{items}</ul></nav>
</div></header>
<main id="main" class="wrap">
{body}
</main>
{self.footer(root)}
</body>
</html>
"""
        self.write(path, doc)

    def footer(self, root):
        return f"""<footer class="colophon"><div class="wrap"><div class="colophon-grid">
<div><h2>UnxWares Helm charts</h2><ul>
<li>{link(self.gh, "Source on GitHub")}</li>
<li>{link("https://artifacthub.io/packages/search?repo=unxwares", "Artifact Hub")}</li>
<li>{link(root + "index.yaml", "index.yaml")}</li>
</ul></div>
<div><h2>Security</h2><ul>
<li>{link(f"{self.gh}/blob/main/SECURITY.md", "Security policy")}</li>
<li>{link(self.cve_issue_url(), "CVE watch issue")}</li>
<li>{link(f"{self.gh}/security/advisories/new", "Report a vulnerability")}</li>
</ul></div>
<div><h2>Data</h2><ul>
<li>{link(root + "status.json", "status.json")}, everything on these pages</li>
<li>{link(root + "pgp-public-key.asc", "Signing key")}</li>
</ul></div>
<div><h2>Colophon</h2><ul>
<li>UnxWares, Caen, France</li>
<li>Set in Poppins ({link(root + "assets/fonts/OFL.txt", "SIL Open Font License 1.1")})</li>
</ul></div>
</div></div></footer>"""

    def cve_issue_url(self):
        return self.cve.get("issue_url") or f"{self.gh}/issues?q=is%3Aissue+is%3Aopen+label%3Acve-watch"

    def write(self, rel, text):
        assert rel not in PROTECTED and not rel.endswith(".tgz"), rel
        path = self.out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        self.files.append(rel)

    def fingerprint(self):
        fp = next((c["signKey"].get("fingerprint") for c in self.charts if c["signKey"].get("fingerprint")), "")
        fp = re.sub(r"\s", "", str(fp)).upper()
        groups = [fp[i:i + 4] for i in range(0, len(fp), 4)]
        return fp, " ".join(groups[:5]) + ("  " + " ".join(groups[5:]) if len(groups) > 5 else "")

    def cosign(self, ref):
        return (f"cosign verify {ref} \\\n  --certificate-identity "
                f"'https://github.com/{self.repo}/.github/workflows/images.yaml@refs/heads/main' \\\n"
                f"  --certificate-oidc-issuer https://token.actions.githubusercontent.com")

    def index(self):
        fp, fp_spaced = self.fingerprint()
        latest = self.latest_date()
        example = next((c["name"] for c in self.charts if c["name"] == "powerdns"), self.charts[0]["name"] if self.charts else "")
        signed_image = next((i["ref"] for i in self.images if i["name"] == "taiga-back"), self.images[0]["ref"] if self.images else "")
        rows = []
        for c in self.charts:
            cells = [f'<td class="lead"><span class="name">{link("charts/" + c["name"] + ".html", e(c["name"]))}</span>'
                     f'{sub(e(c["displayName"] + " " + c["appVersion"]))}</td>',
                     f'<td data-label="Version">{e(c["version"])}</td>']
            for label, fn in (("Lint and schema", self.lint_summary), ("Install and helm test", self.install_summary),
                              ("Unit tests", self.unit_summary), ("End to end", self.e2e_summary)):
                kind, word, note, _, _ = fn(c)
                cells.append(f'<td data-label="{label}">{st(kind, word)}{sub(e(note))}</td>')
            cells.append(f'<td data-label="Default images">{self.cve_phrase(self.chart_cve(c))}</td>')
            rows.append("<tr>" + "".join(cells) + "</tr>")
        image_rows = []
        for i in self.images:
            build = (self.results.get("images") or {}).get(i["context"])
            used = sorted({c["name"] for c in self.charts for img in c["images"] if img["image"] == i["ref"]} |
                          set((self.cve_of(i["ref"]) or {}).get("charts", [])))
            if build:
                b = st("pass" if build["status"] == "passed" else "fail",
                       "Built " + day(build["date"]) if build["status"] == "passed" else "Failed")
                b += sub(e(", ".join(sorted(build.get("arch", {})))))
            else:
                b = st("none", "No result yet")
            if self.cve_of(i["ref"]) is None and not used:
                watch = st("na", "Not watched") + sub("no chart deploys this tag")
            else:
                watch = self.cve_phrase(self.cve_counts(i["ref"]), long=True)
            image_rows.append(
                "<tr>"
                f'<td class="lead"><span class="name">{link("images/" + i["slug"] + ".html", e(i["name"]))}</span>'
                f'{sub("<code>" + e(i["tag"]) + "</code>")}</td>'
                f'<td data-label="Replaces">{inline_md(i["upstream"]) or "<span class=zero>not listed</span>"}</td>'
                f'<td data-label="Used by">{", ".join(link("charts/" + n + ".html", e(n)) for n in used) or "<span class=zero>none</span>"}</td>'
                f'<td data-label="Build">{b}</td>'
                f'<td data-label="CVE watch">{watch}</td>'
                "</tr>")
        cve_note = ""
        if self.cve.get("date"):
            cve_note = (f'CVE watch of {stamp(self.cve["date"])}, {link(self.cve["run_url"], "run")}.')
        body = f"""<section class="opening">
<div>
<span class="kicker">helm.unxwares.studio</span>
<h1>UnxWares Helm charts</h1>
<p class="lede">Helm charts we run ourselves, maintained by UnxWares, a small independent team in Caen, France.
This page lists each chart with the latest results of its tests and of the vulnerability scans of its images, as the
continuous integration of the repository reports them.</p>
<p>Every result links to the run that produced it. Where a chart has no test of a kind yet, the page says so.</p>
</div>
<aside class="facts" aria-label="Repository">
<dl>
<dt>Charts</dt><dd><span class="figure">{len(self.charts)}</span></dd>
<dt>UnxWares images</dt><dd><span class="figure">{len(self.images)}</span></dd>
<dt>Latest result</dt><dd>{stamp(latest) if latest else "none yet"}</dd>
<dt>Repository</dt><dd><code>{e(SITE)}</code></dd>
</dl>
</aside>
</section>

<section class="part" id="install">
<header><h2>Install</h2><p>Helm 3.18 or later, or Helm 4.</p></header>
<div>
<pre><code>helm repo add unxwares {SITE}
helm repo update
helm search repo unxwares

helm install my-dns unxwares/{e(example)} --namespace dns --create-namespace</code></pre>
<p>Each chart page gives its install command, its README and its values.</p>
</div>
</section>

<section class="part" id="verify">
<header><h2>Verify</h2><p>Charts are signed with an OpenPGP key, images with cosign.</p></header>
<div>
<div class="block">
<h3>Chart signatures</h3>
<p>Packages are signed with the UnxWares Helm Charts OpenPGP key, published at
{link("pgp-public-key.asc", "pgp-public-key.asc")}. Its fingerprint:</p>
<p class="fingerprint">{e(fp_spaced)}</p>
<pre><code>curl -fsSL {SITE}/pgp-public-key.asc | gpg --import
gpg --export {e(fp)} &gt; ~/.gnupg/unxwares-helm.gpg
helm install my-dns unxwares/{e(example)} --verify \\
  --keyring ~/.gnupg/unxwares-helm.gpg</code></pre>
</div>
<div class="block">
<h3>Image signatures</h3>
<p>Every published tag of the UnxWares images is signed with cosign, keyless, by the image workflow.</p>
<pre><code>{e(self.cosign(signed_image))}</code></pre>
</div>
</div>
</section>

<section class="part wide" id="charts">
<header><h2>Charts</h2><p>The latest result of each kind for what is on main. Open a chart for the dates, the runs and the details, and its images.</p></header>
<div>
<table class="reflow">
<thead><tr><th scope="col">Chart</th><th scope="col">Version</th><th scope="col">Lint and schema</th><th scope="col">Install and helm test</th><th scope="col">Unit tests</th><th scope="col">End to end</th><th scope="col">Default images</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</div>
</section>

<section class="part wide" id="images">
<header><h2>Images</h2><p>Where the upstream images lag behind, the charts default to these rebuilds, published on <code>ghcr.io/unxwares</code> and rebuilt every Monday and Thursday. {cve_note}</p></header>
<div>
<table class="reflow">
<thead><tr><th scope="col">Image</th><th scope="col">Replaces</th><th scope="col">Used by</th><th scope="col">Build</th><th scope="col">CVE watch</th></tr></thead>
<tbody>
{chr(10).join(image_rows)}
</tbody>
</table>
</div>
</section>

<section class="part" id="method">
<header><h2>How these results are collected</h2><p>From the GitHub Actions runs of {link(self.gh, e(self.repo))}, read through its API.</p></header>
<div>
<ul class="dash">
<li><span class="label">Lint and schema</span> {link(self.gh + "/blob/main/.github/workflows/lint-test.yaml", "lint-test.yaml")}
runs <code>helm lint --strict</code> with Helm 3 and 4 and kubeconform on every chart, for each pull request. Shown:
the last pull request merged into main.</li>
<li><span class="label">Install and helm test</span> the same workflow installs the charts a pull request changes on a
kind cluster with chart-testing, then runs <code>helm test</code>. Shown: the last merged pull request that changed the chart.</li>
<li><span class="label">Unit tests</span> {link(self.gh + "/blob/main/.github/workflows/unit.yaml", "unit.yaml")} runs the
helm-unittest suites of <code>charts/&lt;chart&gt;/tests</code>, on pull requests, every push to main and every Tuesday.</li>
<li><span class="label">End to end</span> {link(self.gh + "/blob/main/.github/workflows/e2e.yaml", "e2e.yaml")} installs a
chart in kind next to real dependencies and checks what the application answers; every push to main and every Tuesday.</li>
<li><span class="label">CVEs</span> {link(self.gh + "/blob/main/.github/workflows/cve-watch.yaml", "cve-watch.yaml")} scans
every image the charts can deploy with Trivy, every day. Fixable means Trivy knows a fixed version. Accepted means the
image's <code>.trivyignore</code> says why the vulnerability stays; the reasons are on the image pages.</li>
<li><span class="label">Images</span> {link(self.gh + "/blob/main/.github/workflows/images.yaml", "images.yaml")} builds
each image on amd64 and arm64, scans it and signs the published tags.</li>
</ul>
<p>A result is only as recent as its last run: a chart nobody changed keeps the install result of the last pull request
that touched it. Known vulnerabilities of the images are tracked in the {link(self.cve_issue_url(), "CVE watch issue")};
how to report one is in the {link(self.gh + "/blob/main/SECURITY.md", "security policy")}.</p>
</div>
</section>"""
        self.page("index.html", "UnxWares Helm charts",
                  "Helm charts maintained by UnxWares, with the latest test results and CVE scans of each chart and image.",
                  body)

    def result_block(self, title, summary, extra=""):
        kind, word, _, detail, r = summary
        text = f'<p class="verdict">{st(kind, word)}</p>'
        if detail:
            text += f"<p>{inline_md(detail)}{'' if detail.endswith('.') else '.'}</p>"
        text += extra
        if r:
            text += self.origin(r)
        return f'<div class="result"><h3>{e(title)}</h3><div>{text}</div></div>'

    def chart_page(self, c):
        name = c["name"]
        unit = self.result(name, "unit") or {}
        unit_extra = ""
        if unit.get("failures"):
            unit_extra = '<ul class="dash">' + "".join(
                f"<li>{e(f['suite'])}: {e(f['test'])}" + (f"<br><code>{e(f['message'])}</code>" if f.get("message") else "")
                + "</li>" for f in unit["failures"][:30]) + "</ul>"
        if c["has_unit_tests"]:
            unit_extra += f'<p>{link(f"{self.gh}/tree/main/charts/{name}/tests", "The suites")}</p>'
        e2e = self.result(name, "e2e") or {}
        e2e_extra = ""
        if e2e.get("checks"):
            repeats = {ch["runs"] for ch in e2e["checks"]}
            times = repeats.pop() if len(repeats) == 1 else 1
            note = {1: "", 2: " Each check ran twice in the job."}.get(times, f" Each check ran {times} times in the job.")
            e2e_extra += (f"<p>Checks of the end-to-end scripts, in order.{e(note)}</p>"
                          '<ul class="dash checks">' + "".join(f"<li>{e(ch['name'])}</li>" for ch in e2e["checks"]) + "</ul>")
        if e2e.get("steps"):
            e2e_extra += ("<details><summary>Steps of the job</summary><ul class=\"dash\">" + "".join(
                f"<li>{e(s['name'])}" + (f" ({e(s['conclusion'])})" if s.get("conclusion") not in ("success", None) else "")
                + "</li>" for s in e2e["steps"]) + "</ul></details>")
        install = self.result(name, "install") or {}
        install_extra = ""
        tests = [t for v in install.get("values", []) for t in v.get("tests", [])]
        if tests:
            install_extra = "<details><summary>helm test pods</summary><ul class=\"dash\">" + "".join(
                f"<li><code>{e(re.sub(r'^' + re.escape(name) + r'-[a-z0-9]{10}-', '', t['name']))}</code> with "
                f"{e(v['file'])}: {e(t['phase'] or 'no phase')}</li>" for v in install["values"] for t in v["tests"]) + "</ul></details>"

        image_rows, other_rows = [], []
        defaults = {i["image"] for i in c["images"]}
        for i in c["images"]:
            ours = self.image_of(i["image"])
            label = link("../images/" + ours["slug"] + ".html", f"<code>{e(i['image'])}</code>") if ours else f"<code>{e(i['image'])}</code>"
            image_rows.append(self.image_row(i["name"], label, "UnxWares" if i["image"].startswith(OURS) else "Upstream", i["image"]))
        for ref, data in sorted((self.cve.get("images") or {}).items()):
            if name in data.get("charts", []) and ref not in defaults:
                ours = self.image_of(ref)
                label = link("../images/" + ours["slug"] + ".html", f"<code>{e(ref)}</code>") if ours else f"<code>{e(ref)}</code>"
                other_rows.append(self.image_row("", label, "UnxWares" if ref.startswith(OURS) else "Upstream", ref))
        head = ('<thead><tr><th scope="col">Image</th><th scope="col">Source</th><th scope="col" class="num">Critical</th>'
                '<th scope="col" class="num">High</th><th scope="col" class="num">Medium</th><th scope="col" class="num">Low</th>'
                '<th scope="col" class="num">All</th><th scope="col" class="num">Fixable C/H</th>'
                '<th scope="col" class="num">Accepted C/H</th></tr></thead>')
        images_html = f'<table class="reflow">{head}<tbody>{"".join(image_rows)}</tbody></table>'
        if other_rows:
            images_html += ('<h3 style="margin-top:2rem">Other images it can deploy</h3>'
                            "<p>Rendered from the chart's <code>ci/</code> values, such as the upstream images or optional components.</p>"
                            f'<table class="reflow">{head}<tbody>{"".join(other_rows)}</tbody></table>')
        if self.cve.get("date"):
            images_html += f'<p class="origin">CVE watch of {stamp(self.cve["date"])} · {link(self.cve["run_url"], "run")} · {link(self.cve_issue_url(), "issue")}</p>'

        changes = "".join(
            f'<li>{(f"<span class=label>{e(CHANGE_KINDS.get(ch["kind"], ch["kind"]))}</span> " if ch["kind"] else "")}'
            f'{inline_md(ch["description"])}</li>' for ch in c["changes"])
        fp, _ = self.fingerprint()
        security = " This release contains security updates." if c["containsSecurityUpdates"] else ""
        body = f"""<section class="opening">
<div>
<span class="kicker"><a href="../index.html#charts">Charts</a></span>
<h1{' class="long"' if len(name) > 16 else ""}>{e(name)}</h1>
<p class="lede">{e(c["description"])}</p>
<ul class="inline">
<li>{link(f"{self.gh}/tree/main/charts/{name}#readme", "README and values")}</li>
<li>{link(f"https://artifacthub.io/packages/helm/unxwares-sac/{name}", "Artifact Hub")}</li>
<li>{link(f"{self.gh}/tree/main/charts/{name}", "Source")}</li>
</ul>
</div>
<aside class="facts" aria-label="Chart">
<dl>
<dt>Chart version</dt><dd><span class="figure">{e(c["version"])}</span></dd>
<dt>{e(c["displayName"])}</dt><dd>{e(c["appVersion"])}</dd>
{f'<dt>Kubernetes</dt><dd><code>{e(c["kubeVersion"])}</code></dd>' if c["kubeVersion"] else ""}
</dl>
</aside>
</section>

<section class="part">
<header><h2>Install</h2><p>With the signature check: see <a href="../index.html#verify">Verify</a> for the key.</p></header>
<div>
<pre><code>helm repo add unxwares {SITE}
helm install {e(name)} unxwares/{e(name)} --version {e(c["version"])} \\
  --namespace {e(name)} --create-namespace \\
  --verify --keyring ~/.gnupg/unxwares-helm.gpg</code></pre>
</div>
</section>

<section class="part">
<header><h2>Test results</h2><p>Latest result of each kind on main.</p></header>
<div>
{self.result_block("Lint and schema", self.lint_summary(c))}
{self.result_block("Install and helm test", self.install_summary(c), install_extra)}
{self.result_block("Unit tests", self.unit_summary(c), unit_extra)}
{self.result_block("End to end", self.e2e_summary(c), e2e_extra)}
</div>
</section>

<section class="part">
<header><h2>Images and CVEs</h2><p>Trivy, all severities. Fixable: a fixed version exists. Accepted: listed with a reason in the image's <code>.trivyignore</code>.{" Medium and low appear after the next run of the CVE watch." if self.cve.get("source") == "issue" else ""}</p></header>
<div>
{images_html}
</div>
</section>

<section class="part">
<header><h2>Changes in {e(c["version"])}</h2><p>From the chart's <code>artifacthub.io/changes</code>.{e(security)}</p></header>
<div>
<ul class="dash">{changes or "<li>No changes listed.</li>"}</ul>
<p>{link(f"{self.gh}/releases/tag/{name}-{c['version']}", "Release " + e(name + "-" + c["version"]))} · earlier versions in {link(f"{self.gh}/releases?q={name}", "the releases")}</p>
</div>
</section>"""
        self.page(f"charts/{name}.html", f"{name} {c['version']}: UnxWares Helm charts",
                  f"{c['description']} Version {c['version']}, latest test results and CVE scans.", body)

    def image_row(self, name, label, source, ref):
        counts = self.cve_counts(ref)
        if counts is None:
            data = self.cve_of(ref)
            status = st("fail", "Scan failed") if data and data.get("scan_failed") else st("none", "Not scanned yet")
            return (f'<tr><td class="lead">{label}{sub(e(name))}</td><td data-label="Source">{source}</td>'
                    f'<td data-label="Critical" class="num" colspan="7">{status}</td></tr>')

        def num(v, warn=False):
            if v is None:
                return '<span class="zero">n/a</span>'
            return f'<span class="zero">0</span>' if v == 0 else (f'<span class="st-fail">{v}</span>' if warn else str(v))
        unaccepted = counts["open_fixable"]
        return (f'<tr><td class="lead">{label}{sub(e(name) + (" (base image end of life)" if counts["eosl"] else ""))}</td>'
                f'<td data-label="Source">{source}</td>'
                f'<td data-label="Critical" class="num">{num(counts["critical"])}</td>'
                f'<td data-label="High" class="num">{num(counts["high"])}</td>'
                f'<td data-label="Medium" class="num">{num(counts["medium"])}</td>'
                f'<td data-label="Low" class="num">{num(counts["low"])}</td>'
                f'<td data-label="All" class="num">{num(counts["total"])}</td>'
                f'<td data-label="Fixable C/H" class="num">{num(counts["fixable"], warn=unaccepted > 0 and ref.startswith(OURS))}</td>'
                f'<td data-label="Accepted C/H" class="num">{num(counts["accepted"]) if ref.startswith(OURS) else "<span class=zero>n/a</span>"}</td></tr>')

    def image_page(self, i):
        build = (self.results.get("images") or {}).get(i["context"])
        cve = self.cve_of(i["ref"]) or {}
        counts = self.cve_counts(i["ref"])
        used = sorted({c["name"] for c in self.charts for img in c["images"] if img["image"] == i["ref"]} |
                      set(cve.get("charts", [])))
        if build:
            archs = sorted(build.get("arch", {}).items())
            built = [a for a, d in archs if d["status"] == "passed"]
            failed = [a for a, d in archs if d["status"] != "passed"]
            pub = build.get("publish")
            text = (f"Built on {' and '.join(built)}" if built else "Not built") + (
                f"; the build failed on {' and '.join(failed)}" if failed else "")
            text += ("; published and signed." if pub and pub["status"] == "passed" else
                     "; not published." if not pub else "; publishing failed.")
            scans = [(a, d["scan_findings"]) for a, d in archs if d.get("scan_findings") is not None]
            if scans:
                text += (" Scan of the build, fixable critical or high vulnerabilities outside `.trivyignore`: "
                         + ", ".join(f"{n} on {a}" for a, n in scans) + ".")
            build_html = (f'<p class="verdict">{st("pass" if build["status"] == "passed" else "fail", "Passed" if build["status"] == "passed" else "Failed")}</p>'
                          f"<p>{inline_md(text)}</p>{self.origin(build)}")
        else:
            build_html = f'<p class="verdict">{st("none", "No result yet")}</p>'

        sev_rows = ""
        if counts:
            vulns = cve.get("vulnerabilities")
            accepted_ids = set(i["accepted"])
            for s in SEVERITIES:
                total = (cve.get("severity") or {}).get(s)
                if total is None:
                    continue
                fixable = (cve.get("fixable") or {}).get(s)
                acc = sum(1 for v in vulns if v["severity"] == s and v["id"] in accepted_ids) if vulns is not None else None
                sev_rows += (f'<tr><td class="lead">{e(s.capitalize())}</td><td data-label="Found" class="num">{total}</td>'
                             f'<td data-label="Fixable" class="num">{"n/a" if fixable is None else fixable}</td>'
                             f'<td data-label="Accepted" class="num">{"n/a" if acc is None else acc}</td></tr>')
        if sev_rows:
            cve_html = ('<table class="reflow"><thead><tr><th scope="col">Severity</th><th scope="col" class="num">Found</th>'
                        '<th scope="col" class="num">Fixable</th><th scope="col" class="num">Accepted</th></tr></thead>'
                        f"<tbody>{sev_rows}</tbody></table>")
            if "fixable" not in cve:
                cve_html += (f"<p>Critical or high and fixable: {counts['fixable']}, of which {counts['accepted']} "
                             "accepted. This summary comes from the CVE watch issue; the next run of the CVE watch "
                             "records every severity here.</p>")
        elif cve.get("scan_failed"):
            cve_html = f'<p class="verdict">{st("fail", "The last scan failed")}</p>'
        else:
            cve_html = f'<p class="verdict">{st("none", "Not scanned yet")}</p>'
        if self.cve.get("date"):
            cve_html += f'<p class="origin">CVE watch of {stamp(self.cve["date"])} · {link(self.cve["run_url"], "run")} · {link(self.cve_issue_url(), "issue")}</p>'

        fixable_rows = ""
        vulns = cve.get("vulnerabilities")
        if vulns is not None:
            open_fixable = [v for v in vulns if v.get("fixed") and v["id"] not in i["accepted"]]
            for v in open_fixable[:100]:
                fixable_rows += (f'<tr><td class="lead"><code>{e(v["id"])}</code>{sub(e(v["severity"].capitalize()))}</td>'
                                 f'<td data-label="Package">{e(v["package"])}</td><td data-label="Installed"><code>{e(v["installed"])}</code></td>'
                                 f'<td data-label="Fixed in"><code>{e(v["fixed"])}</code></td></tr>')
        elif cve.get("fixable_critical_high_list") is not None:
            for v in cve["fixable_critical_high_list"]:
                if v["id"] not in i["accepted"]:
                    fixable_rows += (f'<tr><td class="lead"><code>{e(v["id"])}</code></td><td data-label="Package">{e(v["package"])}</td>'
                                     '<td data-label="Installed">n/a</td><td data-label="Fixed in">n/a</td></tr>')
        none_text = ("None outside the accepted list." if vulns is not None else
                     "No fixable critical or high outside the accepted list. Medium and low appear after the next "
                     "run of the CVE watch.")
        fixable_html = (f"<p>{none_text}</p>" if not fixable_rows else
                        '<table class="reflow"><thead><tr><th scope="col">Vulnerability</th><th scope="col">Package</th>'
                        f'<th scope="col">Installed</th><th scope="col">Fixed in</th></tr></thead><tbody>{fixable_rows}</tbody></table>')

        by_reason = {}
        for vuln, reason in i["accepted"].items():
            by_reason.setdefault(reason, []).append(vuln)
        accepted_html = "".join(
            f"<p>{e(reason) or 'No reason written.'}</p><ul class=\"dash checks\">" +
            "".join(f"<li><code>{e(v)}</code></li>" for v in vs) + "</ul>" for reason, vs in by_reason.items())
        if not accepted_html:
            accepted_html = "<p>None: the image has no <code>.trivyignore</code>.</p>"

        body = f"""<section class="opening">
<div>
<span class="kicker"><a href="../index.html#images">Images</a></span>
<h1>{e(i["name"])}<span class="mono">{e(i["ref"])}</span></h1>
<p class="lede">{("Replaces " + inline_md(i["upstream"]) + ". ") if i["upstream"] else ""}{inline_md(i["changes"])}{"." if i["changes"] and not i["changes"].endswith(".") else ""}</p>
<ul class="inline">
<li>{link(f"{self.gh}/tree/main/{i['context']}", "Dockerfile and sources")}</li>
<li>{link(f"{self.gh}/blob/main/images/README.md", "About the images")}</li>
<li>{link(f"https://github.com/orgs/UnxWares/packages/container/package/{i['name']}", "Package on GitHub")}</li>
</ul>
</div>
<aside class="facts" aria-label="Image">
<dl>
<dt>Tag</dt><dd><span class="figure">{e(i["tag"])}</span></dd>
<dt>Used by</dt><dd>{", ".join(link("../charts/" + n + ".html", e(n)) for n in used) or "no chart by default"}</dd>
</dl>
</aside>
</section>

<section class="part">
<header><h2>Build</h2><p>Latest build on main, amd64 and arm64. Rebuilt every Monday and Thursday on current bases.</p></header>
<div>{build_html}</div>
</section>

<section class="part">
<header><h2>CVE watch</h2><p>Trivy scan of the published tag.</p></header>
<div>{cve_html}</div>
</section>

<section class="part">
<header><h2>Fixable, not accepted</h2><p>Fixed by bumping the dependency or the base in <code>{e(i["context"])}</code>, or by the next rebuild.</p></header>
<div>{fixable_html}</div>
</section>

<section class="part">
<header><h2>Accepted</h2><p>From <code>{e(i["context"])}/.trivyignore</code>: the pull request gate of the image workflow lets these pass. They still show in scans and on Artifact Hub.</p></header>
<div>{accepted_html}</div>
</section>

<section class="part">
<header><h2>Verify</h2><p>Signed with cosign, keyless, by the image workflow on main.</p></header>
<div><pre><code>{e(self.cosign(i["ref"]))}</code></pre></div>
</section>"""
        self.page(f"images/{i['slug']}.html", f"{i['name']}:{i['tag']}: UnxWares images",
                  f"The UnxWares {i['name']} image: build, CVE watch and accepted vulnerabilities.", body)

    def status_json(self):
        charts = []
        for c in self.charts:
            results = {}
            for kind, fn in (("lint", self.lint_summary), ("install", self.install_summary),
                             ("unit", self.unit_summary), ("e2e", self.e2e_summary)):
                k, word, note, detail, r = fn(c)
                results[kind] = {"status": {"pass": "passed", "fail": "failed", "none": "no result",
                                            "na": "not applicable"}[k], "summary": word, "note": note,
                                 "detail": detail, "result": r}
            charts.append(dict(
                {k: c[k] for k in ("name", "version", "appVersion", "description", "kubeVersion", "changes",
                                   "containsSecurityUpdates")},
                images=[dict(i, ours=i["image"].startswith(OURS), cve=self.cve_counts(i["image"])) for i in c["images"]],
                results=results, page=f"charts/{c['name']}.html",
                links={"readme": f"{self.gh}/tree/main/charts/{c['name']}#readme",
                       "artifacthub": f"https://artifacthub.io/packages/helm/unxwares-sac/{c['name']}"}))
        images = [dict({k: i[k] for k in ("name", "tag", "ref", "context", "upstream", "changes", "accepted")},
                       page=f"images/{i['slug']}.html", build=(self.results.get("images") or {}).get(i["context"]),
                       cve=self.cve_counts(i["ref"])) for i in self.images]
        fp, _ = self.fingerprint()
        data = {"repository": self.repo, "site": SITE, "latest_result": self.latest_date(), "signing_key": fp,
                "charts": charts, "images": images, "cve_watch": self.cve or None,
                "files": sorted(self.files + ["status.json"])}
        self.write("status.json", json.dumps(data, indent=1, sort_keys=True) + "\n")

    def build(self, out):
        self.out = out
        for asset in sorted(ASSETS.rglob("*")):
            if asset.is_file():
                rel = "assets/" + str(asset.relative_to(ASSETS))
                (out / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(asset, out / rel)
                self.files.append(rel)
        self.index()
        for c in self.charts:
            self.chart_page(c)
        for i in self.images:
            self.image_page(i)
        self.status_json()


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    results = json.loads(pathlib.Path(sys.argv[1]).read_text())
    out = pathlib.Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    site = Site(results)
    site.build(out)
    print(f"{len(site.files)} files in {out}")


if __name__ == "__main__":
    main()
