#!/usr/bin/env python3
"""Build the static site of the Helm repository (GitHub Pages, branch gh-pages).

Inputs: the charts (charts/*/Chart.yaml), the UnxWares images (the matrix of .github/workflows/images.yaml, the
`ARG VERSION` of each Dockerfile, its .trivyignore, the table of images/README.md) and the CI results gathered by
.github/scripts/site-collect.py. Output, in <output dir>:
  index.html (one page: the charts with their test results and vulnerabilities, the images, how to verify),
  status.json (the same data and more, as JSON), assets/ (styles, fonts, logo, copied from .github/site/assets).

The pages carry no build timestamp, so that an unchanged result gives byte-identical files and no commit. No file
is deleted here; status.json lists the generated files ("files"), so that the publishing job can remove, by name,
a page an earlier version generated (the former charts/*.html and images/*.html pages).

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

# Icons from Lucide (https://lucide.dev, ISC license), inline so that the page makes no other request.
def _icon(paths):
    return ('<svg class="i" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" '
            'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + paths + "</svg>")


ICON = {
    "check": _icon('<path d="M20 6 9 17l-5-5"/>'),
    "x": _icon('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>'),
    "minus": _icon('<path d="M5 12h14"/>'),
    "copy": _icon('<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/>'
                  '<path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>'),
    "package": _icon('<path d="m7.5 4.27 9 5.15"/><path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 '
                     '8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"/><path d="m3.3 7 8.7 5 8.7-5"/>'
                     '<path d="M12 22V12"/>'),
    "box": _icon('<path d="M22 7.7c0-.6-.4-1.2-.8-1.5l-6.3-3.9a1.72 1.72 0 0 0-1.7 0l-10.3 6c-.5.2-.9.8-.9 1.4v6.6c0 '
                 '.5.4 1.2.8 1.5l6.3 3.9a1.72 1.72 0 0 0 1.7 0l10.3-6c.5-.3.9-1 .9-1.5Z"/><path d="M10 21.9V14L2.1 9.1"/>'
                 '<path d="m10 14 11.9-6.9"/><path d="M14 19.8v-8.1"/><path d="M18 17.5V9.4"/>'),
    "shield": _icon('<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 '
                    '4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>'
                    '<path d="m9 12 2 2 4-4"/>'),
    "code": _icon('<path d="m16 18 6-6-6-6"/><path d="m8 6-6 6 6 6"/>'),
    "heart": _icon('<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 '
                   '5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>'),
}

# The footer of unxwares.com, with its markup: {year} is filled in.
FOOTER = ROOT / ".github/site/footer.html"


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
    upstream_file = ROOT / "images/upstream.yaml"
    upstream = load_yaml_block(upstream_file.read_text(), {}) if upstream_file.is_file() else {}
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
            "official": str(upstream.get(m["context"], "")).replace("{tag}", tag),
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

    # --- page -----------------------------------------------------------------------------------------------------

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
        return fp, " ".join(groups[:5]) + ("  " + " ".join(groups[5:]) if len(groups) > 5 else "")

    def cosign(self, ref):
        return (f"cosign verify {ref} \\\n  --certificate-identity "
                f"'https://github.com/{self.repo}/.github/workflows/images.yaml@refs/heads/main' \\\n"
                f"  --certificate-oidc-issuer https://token.actions.githubusercontent.com")

    def check(self, label, summary):
        """One test of a chart card: its name and a mark, linked to the run that produced it."""
        kind, word, note, detail, r = summary
        mark = {"pass": ICON["check"], "fail": ICON["x"]}.get(kind, ICON["minus"])
        title = word + (f": {note}" if note else "")
        text = f'<span class="mark">{mark}</span>{e(label)}'
        cls = f"test test-{kind}"
        if r and (r.get("job_url") or r.get("run_url")):
            return (f'<li><a class="{cls}" href="{e(r.get("job_url") or r["run_url"])}" title="{e(title)}">'
                    f'{text}</a></li>')
        return f'<li><span class="{cls}" title="{e(title)}">{text}</span></li>'

    def security_line(self, counts):
        if counts is None:
            return '<p class="security security-none">Vulnerabilities: not scanned yet</p>'
        n = counts["critical"] + counts["high"]
        if n == 0:
            return '<p class="security security-pass">No critical or high vulnerability</p>'
        parts = []
        if counts["critical"]:
            parts.append(f"{counts['critical']} critical")
        if counts["high"]:
            parts.append(f"{counts['high']} high")
        kind = "fail" if counts["open_fixable"] > 0 else "warn"
        note = " (fix available upstream)" if counts["open_fixable"] > 0 else " (no fix yet, or not reachable)"
        return f'<p class="security security-{kind}">{e(", ".join(parts))} vulnerabilities{e(note)}</p>'

    def chart_card(self, c):
        app = c.get("appVersion") or ""
        ours = any(i["image"].startswith(OURS) for i in c["images"])
        tests = "".join(self.check(label, fn(c)) for label, fn in (
            ("Lint", self.lint_summary), ("Install", self.install_summary),
            ("Unit", self.unit_summary), ("End to end", self.e2e_summary)))
        return f"""<article class="card chart">
<header><h3>{e(c["name"])}</h3><span class="version">{e(c["version"])}</span></header>
<p class="app">{e(c["displayName"])} {e(app)}{' · UnxWares images' if ours else ''}</p>
<p class="desc">{e(c["description"])}</p>
<ul class="tests" aria-label="Tests">{tests}</ul>
{self.security_line(self.chart_cve(c))}
<p class="links"><a href="https://artifacthub.io/packages/helm/unxwares-sac/{e(c["name"])}">Artifact Hub</a><a href="{self.gh}/tree/main/charts/{e(c["name"])}#readme">README</a></p>
</article>"""

    def vuln_cell(self, ref, label, ours=False, accepted_link=""):
        counts = self.cve_counts(ref) if ref else None
        cls = "vcell ours" if ours else "vcell"
        shown = "" if ours else f'<code class="ref">{e(ref or "none")}</code>'
        if counts is None:
            return (f'<td class="{cls}" data-label="{label}"><span class="none">Scanned at the next CVE watch</span>'
                    f'{shown}</td>')
        parts = []
        for k in ("critical", "high"):
            parts.append(f'<span class="n {k if counts[k] else "zero"}"><strong>{counts[k]}</strong> {k}</span>')
        total = counts.get("total")
        detail = f"{total} known in total" if total is not None else ""
        if accepted_link and counts["accepted"]:
            detail += f' · <a href="{accepted_link}">{counts["accepted"]} accepted, with the reason</a>'
        return (f'<td class="{cls}" data-label="{label}"><span class="counts">{"".join(parts)}</span>'
                f'<span class="detail">{detail}</span>{shown}</td>')

    def compare_table(self):
        rows, totals = [], {"official": [0, 0], "ours": [0, 0], "pairs": 0}
        for i in self.images:
            ours, official = self.cve_counts(i["ref"]), self.cve_counts(i["official"]) if i["official"] else None
            if ours is not None and official is not None:
                totals["pairs"] += 1
                totals["official"][0] += official["critical"]
                totals["official"][1] += official["high"]
                totals["ours"][0] += ours["critical"]
                totals["ours"][1] += ours["high"]
            accepted = f"{self.gh}/blob/main/{i['context']}/.trivyignore"
            rows.append(f"""<tr><th scope="row"><code>{e(i["name"])}</code><span class="tag">{e(i["tag"])}</span></th>
{self.vuln_cell(i["official"], "Official image")}{self.vuln_cell(i["ref"], "UnxWares build", True, accepted)}</tr>""")
        o, u = totals["official"], totals["ours"]

        def num(n):
            return f'<strong class="{"bad" if n else ""}">{n}</strong>'

        summary = ""
        if totals["pairs"]:
            summary = f"""<div class="versus">
<div class="side"><span class="label">Official images</span>{num(o[0])}<span>critical</span>{num(o[1])}<span>high</span></div>
<div class="side ours"><span class="label">UnxWares builds</span>{num(u[0])}<span>critical</span>{num(u[1])}<span>high</span></div>
</div>
<p class="note">Known critical and high vulnerabilities, summed over the {totals["pairs"]} images scanned on both sides by the latest CVE watch.</p>"""
        return f"""{summary}
<div class="card table-card"><table class="compare">
<thead><tr><th scope="col">Image</th><th scope="col">Official image</th><th scope="col">UnxWares build</th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody></table></div>"""

    def footer(self):
        html_text = FOOTER.read_text().split("\n", 1)[1]  # without the comment line
        return html_text.replace("{year}", str(datetime.date.today().year))

    def index(self):
        fp, fp_spaced = self.fingerprint()
        latest = self.latest_date()
        unit_total = sum((self.result(c["name"], "unit") or {}).get("tests", 0) for c in self.charts)
        e2e_total = sum(len((self.result(c["name"], "e2e") or {}).get("checks", [])) for c in self.charts)
        stats = [(len(self.charts), "Charts"), (len(self.images), "UnxWares images")]
        if unit_total:
            stats.append((unit_total, "Unit tests"))
        if e2e_total:
            stats.append((e2e_total, "End-to-end checks"))
        stats_html = "".join(f'<div class="stat"><strong>{n}</strong><span>{e(t)}</span></div>' for n, t in stats)
        cards = "\n".join(self.chart_card(c) for c in self.charts)
        sample = next((i["ref"] for i in self.images if i["name"] == "taiga-back"), self.images[0]["ref"] if self.images else "")
        updated = f"Results of {stamp(latest)}." if latest else ""
        scan_line = (f'<p class="note scan">Latest scan: {stamp(self.cve["date"])}. The next one within 6 hours.</p>'
                     if self.cve.get("date") else "")
        doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>UnxWares Helm Repository</title>
<meta name="description" content="Helm charts maintained by UnxWares, with the latest results of their tests and vulnerability scans.">
<meta name="color-scheme" content="light dark">
<link rel="stylesheet" href="assets/site.css">
<link rel="icon" href="assets/mark.svg" type="image/svg+xml">
</head>
<body>
<div class="navbar-wrapper"><nav class="navbar" aria-label="Site"><div class="navbar-container">
<a class="navbar-brand" href="https://unxwares.com"><picture><source srcset="assets/mark-dark.svg" media="(prefers-color-scheme: dark)"><img class="logo" src="assets/mark.svg" alt="UnxWares Logo" width="38" height="38"></picture><span class="brand-name">UnxWares</span></a>
<div class="navbar-center"><a class="nav-link" href="#charts">Charts</a><a class="nav-link" href="#images">Images</a><a class="nav-link" href="#verify">Verify</a><a class="nav-link" href="#open-source">Open source</a><a class="nav-link" href="{self.gh}">GitHub</a></div>
<div class="navbar-actions"><a class="btn-primary" href="https://artifacthub.io/packages/search?repo=unxwares">Artifact Hub</a></div>
</div></nav></div>
<main>
<section class="hero">
<picture><source srcset="assets/logo-dark.svg" media="(prefers-color-scheme: dark)"><img class="logo" src="assets/logo.svg" alt="UnxWares" width="306" height="64"></picture>
<h1>Helm Repository</h1>
<p class="lead">Helm charts maintained by UnxWares, tested on every change, with their images scanned every 6 hours.</p>
<div class="code"><code id="repo-add">helm repo add unxwares {SITE}/</code><button type="button" class="copy" data-copy="repo-add" aria-label="Copy the command">{ICON["copy"]}</button></div>
<p class="buttons"><a class="button" href="https://artifacthub.io/packages/search?repo=unxwares">{ICON["package"]}Browse on Artifact Hub</a><a class="button button-light" href="{self.gh}">{ICON["code"]}Source on GitHub</a></p>
<div class="stats">{stats_html}</div>
</section>

<div class="divider"><picture><source srcset="assets/mark-dark.svg" media="(prefers-color-scheme: dark)"><img src="assets/mark.svg" alt="" width="16" height="16"></picture></div>

<section id="charts">
<h2><span class="icon">{ICON["package"]}</span>Charts</h2>
<p class="section-lead">Each chart with the latest result of its tests on main and the vulnerabilities of the images it deploys by default. A mark links to the run that produced it.</p>
<div class="grid">
{cards}
</div>
<p class="legend"><span class="test test-pass"><span class="mark">{ICON["check"]}</span>passed</span><span class="test test-fail"><span class="mark">{ICON["x"]}</span>failed</span><span class="test test-na"><span class="mark">{ICON["minus"]}</span>no such test yet</span></p>
</section>

<div class="divider"><picture><source srcset="assets/mark-dark.svg" media="(prefers-color-scheme: dark)"><img src="assets/mark.svg" alt="" width="16" height="16"></picture></div>

<section id="images">
<h2><span class="icon">{ICON["box"]}</span>Images</h2>
<p class="section-lead">Where an official image lags behind, the charts default to our own build, published on <code>ghcr.io/unxwares</code>, rebuilt twice a week and scanned every 6 hours (<a href="{self.cve_issue_url()}">CVE watch</a>). Both are scanned with Trivy: the official image on the left, our build on the right.</p>
{scan_line}
{self.compare_table()}
</section>

<div class="divider"><picture><source srcset="assets/mark-dark.svg" media="(prefers-color-scheme: dark)"><img src="assets/mark.svg" alt="" width="16" height="16"></picture></div>

<section id="verify">
<h2><span class="icon">{ICON["shield"]}</span>Verify</h2>
<div class="grid grid-2">
<div class="card">
<h3>Charts</h3>
<p>Signed with the <a href="pgp-public-key.asc">UnxWares Helm Charts key</a>, fingerprint <code>{e(fp_spaced)}</code>.</p>
<pre><code>curl -fsSL {SITE}/pgp-public-key.asc | gpg --import
gpg --export {e(fp)} > ~/.gnupg/unxwares-helm.gpg
helm install my-release unxwares/&lt;chart&gt; --verify \\
  --keyring ~/.gnupg/unxwares-helm.gpg</code></pre>
</div>
<div class="card">
<h3>Images</h3>
<p>Every published image is signed with cosign, keyless, by the image workflow.</p>
<pre><code>{e(self.cosign(sample))}</code></pre>
</div>
</div>
</section>

<div class="divider"><picture><source srcset="assets/mark-dark.svg" media="(prefers-color-scheme: dark)"><img src="assets/mark.svg" alt="" width="16" height="16"></picture></div>

<section id="open-source">
<h2><span class="icon">{ICON["heart"]}</span>Open source</h2>
<p class="section-lead">These charts are part of <strong>UnxWares Open Source &amp; Community</strong> (UWOSC): the open source work that UnxWares supports and maintains, in the open and for everyone.</p>
<div class="card uwosc">
<picture><source srcset="assets/uwosc/badge-maintained-dark.svg" media="(prefers-color-scheme: dark)"><img src="assets/uwosc/badge-maintained.svg" alt="UnxWares Open Source &amp; Community: supported and maintained by UnxWares" width="308" height="44"></picture>
<p><strong>Maintained</strong> means UnxWares answers for these charts: we keep them current, test every change and fix what breaks. Each chart README carries the badge.</p>
<div class="code"><code id="uwosc-badge">[![UWOSC: maintained]({SITE}/assets/uwosc/mini-maintained.svg)]({SITE}/#open-source)</code><button type="button" class="copy" data-copy="uwosc-badge" aria-label="Copy the badge">{ICON["copy"]}</button></div>
</div>
</section>
<p class="results">{updated} <a href="status.json">status.json</a> · <a href="index.yaml">index.yaml</a> · <a href="{self.cve_issue_url()}">CVE watch</a> · <a href="{self.gh}/blob/main/SECURITY.md">Security policy</a></p>
</main>
{self.footer()}
<script>
// How long ago each result is, from the visitor's clock (the page itself is rebuilt every 6 hours at least).
document.querySelectorAll("time[datetime]").forEach(function (t) {{
  var minutes = Math.round((Date.now() - Date.parse(t.getAttribute("datetime"))) / 60000);
  if (!(minutes >= 0)) return;
  var ago = minutes < 60 ? minutes + " min ago" : minutes < 2880 ? Math.round(minutes / 60) + " h ago" : Math.round(minutes / 1440) + " days ago";
  t.insertAdjacentText("beforeend", " (" + ago + ")");
}});
document.querySelectorAll("button.copy").forEach(function (b) {{
  b.addEventListener("click", function () {{
    var text = document.getElementById(b.dataset.copy).textContent;
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () {{ b.classList.add("done"); }});
  }});
}});
</script>
</body>
</html>
"""
        self.write("index.html", doc)

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
                results=results,
                links={"readme": f"{self.gh}/tree/main/charts/{c['name']}#readme",
                       "artifacthub": f"https://artifacthub.io/packages/helm/unxwares-sac/{c['name']}"}))
        images = [dict({k: i[k] for k in ("name", "tag", "ref", "context", "upstream", "changes", "accepted")},
                       build=(self.results.get("images") or {}).get(i["context"]),
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
