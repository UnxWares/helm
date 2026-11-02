#!/usr/bin/env python3
"""Summarize the helm-unittest JUnit reports of .github/workflows/unit.yaml.

Reads <junit dir>/<chart>.xml (helm unittest --output-type JUnit), writes <output json> for the site
(.github/scripts/site-collect.py reads it from the unit-results artifact) and prints a Markdown summary for the job
summary. A chart with a tests/ directory but no report (helm-unittest stopped before writing it) is reported as an
error.

usage: .github/scripts/unittest-results.py <junit dir> <output json>
"""
import json, pathlib, sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]


def summarize(report):
    tree = ET.parse(report)
    suites = list(tree.getroot().iter("testsuite"))
    entry = {"suites": len(suites), "tests": 0, "passed": 0, "failed": 0, "skipped": 0, "failures": []}
    for suite in suites:
        for case in suite.iter("testcase"):
            entry["tests"] += 1
            problem = case.find("failure")
            if problem is None:
                problem = case.find("error")
            if problem is not None:
                entry["failed"] += 1
                # helm-unittest puts "Failed" in the message and the assertion, template and path in the text.
                text = " ".join((problem.text or "").split())
                message = problem.get("message") or ""
                if text and message in ("", "Failed"):
                    message = text.split(" , Expected")[0].lstrip(" -")
                entry["failures"].append({"suite": suite.get("name", ""), "test": case.get("name", ""),
                                          "message": message[:300]})
            elif case.find("skipped") is not None:
                entry["skipped"] += 1
            else:
                entry["passed"] += 1
    entry["status"] = "failed" if entry["failed"] or not entry["tests"] else "passed"
    return entry


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    reports = pathlib.Path(sys.argv[1])
    charts = {}
    for chart in sorted({p.parent.parent.name for p in (ROOT / "charts").glob("*/tests/*_test.yaml")}):
        report = reports / f"{chart}.xml"
        if report.is_file():
            try:
                charts[chart] = summarize(report)
            except ET.ParseError as e:
                charts[chart] = {"status": "error", "error": f"unreadable report: {e}"}
        else:
            charts[chart] = {"status": "error", "error": "helm unittest did not write a report"}
    output = pathlib.Path(sys.argv[2])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"charts": charts}, indent=1, sort_keys=True) + "\n")

    print("| Chart | Result | Suites | Tests | Passed | Failed |\n|---|---|---:|---:|---:|---:|")
    for chart, e in charts.items():
        print(f"| {chart} | {e['status']} | {e.get('suites', '')} | {e.get('tests', '')} | {e.get('passed', '')} "
              f"| {e.get('failed', '')} |")
    for chart, e in charts.items():
        for f in e.get("failures", []):
            print(f"\n- {chart}: {f['suite']}: {f['test']}: {f['message']}")


if __name__ == "__main__":
    main()
