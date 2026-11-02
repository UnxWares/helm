#!/usr/bin/env python3
"""Collect the latest CI results of the charts and images, for the site (.github/scripts/site.py).

Reads what the workflows already produce, through read-only GitHub API calls (gh api with GET, gh run download):
  - lint and schema:  .github/workflows/lint-test.yaml, jobs "Lint (helm ...)": helm lint --strict and kubeconform,
                      for every chart. The workflow only runs on pull requests: the result shown is the one of the
                      last pull request merged into main (its last run on the merged commit).
  - install:          the same workflow, job "chart-testing lint + install": ct lint, ct install and helm test, for
                      the charts the pull request changed. Older merged pull requests are read until every chart
                      has a result, at most SITE_MAX_RUNS runs.
  - unit:             .github/workflows/unit.yaml, artifact unit-results (unit.json), latest run on main.
  - end to end:       .github/workflows/e2e.yaml, one job per chart, named after the chart: the "ok: ..." lines of
                      its log. Latest run on main where the job ran (not skipped).
  - images:           .github/workflows/images.yaml, jobs "Build <context> (<arch>)" and "Publish <context>":
                      conclusions and the Trivy summary of the build (fixable critical/high outside .trivyignore).
  - CVE watch:        .github/workflows/cve-watch.yaml, artifact cve-watch-report (report.json) of the latest
                      successful run; before that artifact existed, the summary table of the open cve-watch issue
                      and the cve-watch-state artifact.

Nothing is written to GitHub. Logs are parsed in memory; only counts, check names and short messages are kept.

usage: .github/scripts/site-collect.py <results.json>
env:   GH_TOKEN (actions: read, contents: read, issues: read, pull-requests: read; read by gh),
       REPOSITORY (default: $GITHUB_REPOSITORY, else UnxWares/helm),
       SITE_MAX_RUNS (default: 25), how far back to look in the runs of a workflow
"""
import datetime, json, os, pathlib, re, subprocess, sys, tempfile

REPO = os.environ.get("REPOSITORY") or os.environ.get("GITHUB_REPOSITORY") or "UnxWares/helm"
MAX_RUNS = int(os.environ.get("SITE_MAX_RUNS", "25"))
ROOT = pathlib.Path(__file__).resolve().parents[2]
MAIN_EVENTS = {"push", "schedule", "workflow_dispatch", "workflow_run"}
CHARTS = sorted(p.parent.name for p in (ROOT / "charts").glob("*/Chart.yaml"))
LOG_LINE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def warn(msg):
    print(f"::warning::{msg}", file=sys.stderr)


def gh(*args, text=True):
    """Run gh read-only; return stdout, or None on error (the error is reported as a warning)."""
    r = subprocess.run(["gh", *args], capture_output=True, text=text)
    if r.returncode != 0:
        err = r.stderr if text else r.stderr.decode(errors="replace")
        shown = " ".join(a for a in args if a != "-H" and not a.startswith("Accept:"))
        warn(f"gh {shown}: {err.strip()[:300]}")
        return None
    return r.stdout


def api(path):
    out = gh("api", "--method", "GET", "-H", "Accept: application/vnd.github+json", path)
    return json.loads(out) if out else None


def job_log(job_id):
    """The plain-text log of a job, timestamps and colours removed (None when unavailable)."""
    path = f"repos/{REPO}/actions/jobs/{job_id}/logs"
    r = subprocess.run(["gh", "api", "--method", "GET", "--allow-escape-sequences", path], capture_output=True)
    if r.returncode != 0 and b"unknown flag" in r.stderr:  # older gh: no escape-sequence check at all
        r = subprocess.run(["gh", "api", "--method", "GET", path], capture_output=True)
    if r.returncode != 0:
        warn(f"log of job {job_id}: {r.stderr.decode(errors='replace').strip()[:300]}")
        return None
    return [ANSI.sub("", LOG_LINE.sub("", line)) for line in r.stdout.decode(errors="replace").splitlines()]


def runs(workflow, **query):
    """Completed runs of a workflow, newest first (at most 100)."""
    q = "&".join(f"{k}={v}" for k, v in {"status": "completed", "per_page": 100, **query}.items())
    data = api(f"repos/{REPO}/actions/workflows/{workflow}/runs?{q}")
    return (data or {}).get("workflow_runs", [])


def main_runs(workflow):
    """Runs on main itself (push, schedule, manual), never pull requests, even from a fork branch named main."""
    return [r for r in runs(workflow, branch="main") if r["event"] in MAIN_EVENTS][:MAX_RUNS]


def jobs(run):
    data = api(f"repos/{REPO}/actions/runs/{run['id']}/jobs?per_page=100")
    return (data or {}).get("jobs", [])


def origin(run, pr=None):
    """Where a result comes from: date, commit, links."""
    o = {"run_id": run["id"], "run_url": run["html_url"], "date": run.get("updated_at") or run["created_at"],
         "event": run["event"], "commit": run["head_sha"]}
    if pr:
        o.update(pr=pr["number"], pr_url=pr["html_url"], commit=pr["merge_commit_sha"] or run["head_sha"],
                 tested_commit=run["head_sha"])
    return o


def steps_of(job):
    skip = ("Set up job", "Complete job")
    return [{"name": s["name"], "conclusion": s["conclusion"]} for s in job.get("steps", [])
            if s["name"] not in skip and not s["name"].startswith("Post ")]


def failed_step(job):
    return next((s["name"] for s in job.get("steps", []) if s.get("conclusion") == "failure"), None)


# --- lint-test.yaml: lint, schema, ct lint, ct install -----------------------------------------------------------

def merged_pull_requests():
    """Merged pull requests into main, by head commit."""
    heads = {}
    for page in (1, 2):
        data = api(f"repos/{REPO}/pulls?state=closed&base=main&sort=updated&direction=desc&per_page=100&page={page}")
        for pr in data or []:
            if pr.get("merged_at"):
                heads.setdefault(pr["head"]["sha"], pr)
        if not data or len(data) < 100:
            break
    return heads


def parse_lint(lines):
    """helm lint --strict and kubeconform.sh output, per chart."""
    res, chart = {}, None
    for line in lines:
        m = re.match(r"==> Linting charts/([a-z0-9-]+)/?$", line)
        if m:
            chart = m.group(1)
            r = res.setdefault(chart, {"lint_runs": 0, "lint_failed": 0})
            r["lint_runs"] += 1
            continue
        m = re.search(r"(\d+) chart\(s\) linted, (\d+) chart\(s\) failed", line)
        if m and chart:
            if int(m.group(2)):
                res[chart]["lint_failed"] += 1
            chart = None
            continue
        if chart and re.match(r"\[ERROR\]", line):
            res[chart].setdefault("lint_error", line[:300])
        m = re.match(r"charts/([a-z0-9-]+)(?: \(([^)]+)\))? \[k8s ([^\]]+)\]: Summary: (\d+) resources found.*"
                     r"Invalid: (\d+), Errors: (\d+)", line)
        if m:
            r = res.setdefault(m.group(1), {"lint_runs": 0, "lint_failed": 0})
            k = r.setdefault("schema", {"renders": [], "kubernetes": [], "resources": 0, "invalid": 0})
            label = m.group(2) or "default values"
            if label not in k["renders"]:
                k["renders"].append(label)
            if m.group(3) not in k["kubernetes"]:
                k["kubernetes"].append(m.group(3))
            k["resources"] += int(m.group(4))
            k["invalid"] += int(m.group(5)) + int(m.group(6))
            continue
        m = re.search(r"(?:##\[notice\]|::notice::)charts/([a-z0-9-]+): needs user values \((.*)\), validated", line)
        if m:
            r = res.setdefault(m.group(1), {"lint_runs": 0, "lint_failed": 0})
            r["default_values_note"] = m.group(2)[:300]
        m = re.search(r"(?:##\[error\]|::error::)charts/([a-z0-9-]+)(.*)", line)
        if m:
            r = res.setdefault(m.group(1), {"lint_runs": 0, "lint_failed": 0})
            r.setdefault("schema_error", (m.group(1) + m.group(2))[:300])
    return res


SUMMARY = re.compile(r'^\s*([✔✖])︎?\s+([a-z0-9-]+) => \(version: "([^"]*)", path: "([^"]*)"\)\s*(?:>\s*(.*))?$')


def parse_ct(lines):
    """ct lint and ct install output, per chart."""
    lint, install, phase, chart, values = {}, {}, None, None, None
    for line in lines:
        if line.startswith("Linting charts..."):
            phase = "lint"
        elif line.startswith("Installing charts..."):
            phase, chart = "install", None
        m = SUMMARY.match(line)
        if m and phase:
            target = lint if phase == "lint" else install.setdefault(m.group(2), {"values": []})
            entry = {"ok": m.group(1) == "✔", "version": m.group(3)}
            if m.group(5):
                entry["error"] = m.group(5)[:300]
            if phase == "lint":
                lint[m.group(2)] = entry
            else:
                target.update(entry)
            continue
        if phase != "install":
            continue
        m = re.match(r'Installing chart "([a-z0-9-]+) => ', line)
        if m:
            chart = m.group(1)
            install.setdefault(chart, {"values": []})
            continue
        m = re.match(r'Installing chart with values file "([^"]+)"', line)
        if m and chart:
            values = {"file": m.group(1).rsplit("/", 1)[-1], "tests": []}
            install[chart]["values"].append(values)
            continue
        if chart is None and line.startswith("Installing chart with values file"):
            continue
        m = re.match(r"TEST SUITE:\s+(\S+)$", line)
        if m and values is not None and m.group(1) != "None":
            values["tests"].append({"name": m.group(1), "phase": None})
            continue
        m = re.match(r"Phase:\s+(\S+)", line)
        if m and values is not None and values["tests"] and values["tests"][-1]["phase"] is None:
            values["tests"][-1]["phase"] = m.group(1)
    return lint, install


def collect_lint_test(result):
    heads = merged_pull_requests()
    candidates = [r for r in runs("lint-test.yaml", event="pull_request") if r["head_sha"] in heads]
    candidates += main_runs("lint-test.yaml")
    candidates.sort(key=lambda r: r["created_at"], reverse=True)
    excluded = []
    m = re.search(r"--excluded-charts\s+([a-z0-9,-]+)", (ROOT / ".github/workflows/lint-test.yaml").read_text())
    if m:
        excluded = m.group(1).split(",")
    result["install_excluded"] = excluded
    need_lint = set(CHARTS)
    need_install = set(CHARTS) - set(excluded)
    seen = 0
    for run in candidates:
        if not need_lint and not need_install:
            break
        if run["conclusion"] in ("cancelled", "skipped") or seen >= MAX_RUNS:
            continue
        seen += 1
        pr = heads.get(run["head_sha"]) if run["event"] == "pull_request" else None
        run_jobs = jobs(run)
        lint_jobs = [j for j in run_jobs if j["name"].startswith("Lint (") and j["conclusion"] in ("success", "failure")]
        if need_lint and lint_jobs:
            per_version = {}
            for job in lint_jobs:
                lines = job_log(job["id"])
                if lines is None:
                    continue
                version = re.search(r"\(helm ([^)]+)\)", job["name"])
                per_version[version.group(1) if version else job["name"]] = (job, parse_lint(lines))
            for chart in sorted(need_lint):
                found = {v: (job, data[chart]) for v, (job, data) in per_version.items() if chart in data}
                if not found:
                    continue
                entry = origin(run, pr)
                entry["helm"] = {}
                for v, (job, data) in sorted(found.items()):
                    entry["helm"][v] = dict(data, job_url=job["html_url"], job_conclusion=job["conclusion"],
                                            failed_step=failed_step(job))
                lint_ok = all(d["lint_failed"] == 0 and d["lint_runs"] > 0 for d in entry["helm"].values())
                schema = [d.get("schema") for d in entry["helm"].values()]
                schema_ok = all(s and s["invalid"] == 0 for s in schema) and not any(
                    d.get("schema_error") for d in entry["helm"].values())
                entry["lint_status"] = "passed" if lint_ok else "failed"
                entry["schema_status"] = ("passed" if schema_ok else
                                          "failed" if any(s and s["invalid"] for s in schema) or any(
                                              d.get("schema_error") for d in entry["helm"].values()) else "not run")
                entry["status"] = "passed" if lint_ok and schema_ok else "failed"
                result["charts"].setdefault(chart, {})["lint"] = entry
                need_lint.discard(chart)
        ct_job = next((j for j in run_jobs if j["name"].startswith("chart-testing")), None)
        if need_install and ct_job and ct_job["conclusion"] in ("success", "failure"):
            lines = job_log(ct_job["id"])
            if lines is None:
                continue
            ct_lint, ct_install = parse_ct(lines)
            for chart in sorted(need_install):
                inst = ct_install.get(chart)
                if not inst or "ok" not in inst and not inst["values"]:
                    continue
                entry = origin(run, pr)
                entry.update(job_url=ct_job["html_url"], ct_lint=ct_lint.get(chart), values=inst["values"])
                tests = [t for v in inst["values"] for t in v["tests"]]
                entry["tests_total"] = len(tests)
                entry["tests_passed"] = sum(1 for t in tests if t["phase"] == "Succeeded")
                if "ok" in inst:
                    entry["status"] = "passed" if inst["ok"] and entry["tests_passed"] == len(tests) else "failed"
                    if inst.get("error"):
                        entry["error"] = inst["error"]
                else:  # the job stopped before the summary (timeout, runner lost)
                    entry["status"] = "failed" if ct_job["conclusion"] == "failure" else "unknown"
                result["charts"].setdefault(chart, {})["install"] = entry
                need_install.discard(chart)


# --- unit.yaml -----------------------------------------------------------------------------------------------------

def collect_unit(result):
    for run in main_runs("unit.yaml"):
        if run["conclusion"] in ("cancelled", "skipped"):
            continue
        with tempfile.TemporaryDirectory() as tmp:
            if gh("run", "download", str(run["id"]), "--repo", REPO, "--name", "unit-results", "--dir", tmp) is None:
                continue
            path = pathlib.Path(tmp) / "unit.json"
            if not path.is_file():
                continue
            data = json.loads(path.read_text())
        for chart, entry in (data.get("charts") or {}).items():
            result["charts"].setdefault(chart, {})["unit"] = dict(origin(run), **entry)
        return


# --- e2e.yaml ------------------------------------------------------------------------------------------------------

def collect_e2e(result):
    need = set(CHARTS)
    for run in main_runs("e2e.yaml"):
        if not need:
            break
        for job in jobs(run):
            chart = job["name"]
            if chart not in need or job["conclusion"] not in ("success", "failure"):
                continue
            lines = job_log(job["id"]) or []
            checks, failure = {}, None
            for line in lines:
                m = re.match(r"ok: (.+)$", line)
                if m:
                    checks[m.group(1).strip()] = checks.get(m.group(1).strip(), 0) + 1
                m = re.match(r"FAIL: (.+)$", line)
                if m and failure is None:
                    failure = m.group(1).strip()[:300]
            entry = origin(run)
            entry.update(job_url=job["html_url"], status="passed" if job["conclusion"] == "success" else "failed",
                         checks=[{"name": k, "runs": n} for k, n in checks.items()], steps=steps_of(job),
                         failed_step=failed_step(job))
            if failure:
                entry["failure"] = failure
            result["charts"].setdefault(chart, {})["e2e"] = entry
            need.discard(chart)


# --- images.yaml ---------------------------------------------------------------------------------------------------

def trivy_findings(lines):
    """Sum of the 'Vulnerabilities' column of Trivy's report summary (fixable critical/high outside .trivyignore)."""
    total, seen, inside = 0, False, False
    for line in lines:
        if line.strip() == "Report Summary":
            inside, seen = True, True
            continue
        if inside:
            cells = [c.strip() for c in line.strip().strip("│").split("│")]
            if len(cells) >= 3 and cells[-1].isdigit():
                total += int(cells[-1])
            elif line.strip() == "" or line.startswith("```") or line.startswith("##[") or "Legend" in line:
                inside = False
    return total if seen else None


def collect_images(result):
    # The image directories of the build matrix; else, those of the latest run.
    workflow = ROOT / ".github/workflows/images.yaml"
    contexts = set(re.findall(r"context: (images/[\w./-]+)", workflow.read_text())) if workflow.is_file() else set()
    need = contexts or None
    for run in main_runs("images.yaml"):
        run_jobs = jobs(run)
        contexts = {}
        for job in run_jobs:
            m = re.match(r"Build (\S+) \((\w+)\)$", job["name"]) or re.match(r"Publish (\S+)$", job["name"])
            if m:
                contexts.setdefault(m.group(1), []).append((job, m.group(2) if m.lastindex == 2 else None))
        if need is None:
            need = set(contexts)
        for context in sorted(need & set(contexts)):
            entries = contexts[context]
            builds = [(j, a) for j, a in entries if a]
            if not builds or any(j["conclusion"] in ("cancelled", "skipped", None) for j, _ in builds):
                continue
            entry = origin(run)
            entry["arch"] = {}
            for job, arch in builds:
                a = {"status": "passed" if job["conclusion"] == "success" else "failed", "job_url": job["html_url"],
                     "failed_step": failed_step(job)}
                lines = job_log(job["id"])
                if lines is not None:
                    a["scan_findings"] = trivy_findings(lines)
                entry["arch"][arch] = a
            publish = next((j for j, a in entries if a is None), None)
            if publish:
                entry["publish"] = {"status": {"success": "passed", "failure": "failed"}.get(publish["conclusion"],
                                                                                                 publish["conclusion"]),
                                    "job_url": publish["html_url"]}
            entry["status"] = "passed" if all(a["status"] == "passed" for a in entry["arch"].values()) and (
                not publish or publish["conclusion"] == "success") else "failed"
            result["images"][context] = entry
            need.discard(context)
        if need is not None and not need:
            break


# --- cve-watch.yaml ------------------------------------------------------------------------------------------------

def parse_issue(body):
    """Fallback: the summary table of the CVE watch issue (critical, high, total and fixable critical/high)."""
    images = {}
    for line in body.splitlines():
        m = re.match(r"\| `([^`]+)`( \(EOL base\))? \| ([^|]*) \| (\d+) \| (\d+) \| (\d+) \| (\d+) \|$", line)
        if m:
            images[m.group(1)] = {"image": m.group(1), "charts": [c.strip() for c in m.group(3).split(",") if c.strip()],
                                  "eosl": bool(m.group(2)), "severity": {"CRITICAL": int(m.group(4)), "HIGH": int(m.group(5))},
                                  "total": int(m.group(6)), "fixable_critical_high": int(m.group(7))}
        m = re.match(r"\| `([^`]+)` \| ([^|]*) \| scan failed \|", line)
        if m:
            images[m.group(1)] = {"image": m.group(1), "charts": [c.strip() for c in m.group(2).split(",")],
                                  "scan_failed": True}
    return images


def collect_cve(result):
    for run in [r for r in runs("cve-watch.yaml", branch="main") if r["conclusion"] == "success"][:MAX_RUNS]:
        with tempfile.TemporaryDirectory() as tmp:
            if gh("run", "download", str(run["id"]), "--repo", REPO, "--name", "cve-watch-report", "--dir", tmp) is not None:
                path = pathlib.Path(tmp) / "report.json"
                if path.is_file():
                    data = json.loads(path.read_text())
                    result["cve"] = dict(origin(run), source="report", images={i["image"]: i for i in data["images"]})
                    return
            # Runs from before the report artifact: the issue table, and the fixable critical/high of the state.
            issue = api(f"repos/{REPO}/issues?labels=cve-watch&state=open&per_page=1")
            if not issue:
                return
            images = parse_issue(issue[0].get("body") or "")
            if gh("run", "download", str(run["id"]), "--repo", REPO, "--name", "cve-watch-state", "--dir", tmp) is not None:
                state = pathlib.Path(tmp) / "state.json"
                if state.is_file():
                    by_name = {}
                    for key in json.loads(state.read_text()):
                        name, pkg, vuln = key.split("|")
                        by_name.setdefault(name, []).append({"package": pkg, "id": vuln})
                    for image, entry in images.items():
                        name = image.split("@")[0].rsplit(":", 1)[0] if ":" in image.split("/")[-1] else image
                        if image.startswith("ghcr.io/unxwares/"):
                            entry["fixable_critical_high_list"] = by_name.get(name, [])
            result["cve"] = dict(origin(run), source="issue", issue_url=issue[0]["html_url"],
                                 issue_updated=issue[0]["updated_at"], images=images)
            return


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    result = {"repository": REPO, "collected_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "charts": {}, "images": {}, "cve": None, "install_excluded": []}
    for step in (collect_lint_test, collect_unit, collect_e2e, collect_images, collect_cve):
        try:
            step(result)
        except Exception as e:  # one source failing must not hide the others
            warn(f"{step.__name__}: {type(e).__name__}: {e}")
    pathlib.Path(sys.argv[1]).write_text(json.dumps(result, indent=1, sort_keys=True) + "\n")
    print(f"{len(result['charts'])} charts, {len(result['images'])} images, "
          f"CVE watch: {(result['cve'] or {}).get('source', 'none')}")


if __name__ == "__main__":
    main()
