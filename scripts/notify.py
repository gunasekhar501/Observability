#!/usr/bin/env python3
"""
Unified notification dispatcher.
Supports BOTH cloud (Jira/ServiceNow/Confluence/Slack) and
self-hosted (Plane/Mattermost/Wiki.js) modes.

Mode is selected by the NOTIFY_MODE env var:
  cloud      → Jira + ServiceNow + Confluence + Slack  (default)
  local      → Plane + Wiki.js + Mattermost
  api        → POST directly to SecureOps API (recommended for local stack)
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

import requests

# ── Mode ─────────────────────────────────────────────────────────────
NOTIFY_MODE = os.environ.get("NOTIFY_MODE", "cloud")   # cloud | local | api

# ── SecureOps API (api mode) ─────────────────────────────────────────
SECUREOPS_API_URL = os.environ.get("SECUREOPS_API_URL", "http://localhost:8080")

# ── Cloud integrations ───────────────────────────────────────────────
JIRA_URL       = os.environ.get("JIRA_URL", "")
JIRA_TOKEN     = os.environ.get("JIRA_TOKEN", "")
JIRA_PROJECT   = os.environ.get("JIRA_PROJECT", "SEC")
JIRA_USER      = os.environ.get("JIRA_USER", "")

SNOW_URL       = os.environ.get("SNOW_URL", "")
SNOW_USER      = os.environ.get("SNOW_USER", "")
SNOW_PASS      = os.environ.get("SNOW_PASS", "")

CONFLUENCE_URL        = os.environ.get("CONFLUENCE_URL", "")
CONFLUENCE_TOKEN      = os.environ.get("CONFLUENCE_TOKEN", "")
CONFLUENCE_SPACE      = os.environ.get("CONFLUENCE_SPACE", "PLATFORM")
CONFLUENCE_RCA_PARENT = os.environ.get("CONFLUENCE_RCA_PARENT_ID", "")

SLACK_WEBHOOK = os.environ.get("SLACK_SECURITY_WEBHOOK", "")

# ── Self-hosted integrations ─────────────────────────────────────────
PLANE_URL       = os.environ.get("PLANE_URL", "http://localhost:8000")
PLANE_TOKEN     = os.environ.get("PLANE_TOKEN", "")
PLANE_WORKSPACE = os.environ.get("PLANE_WORKSPACE", "secureops")
PLANE_PROJECT   = os.environ.get("PLANE_PROJECT_ID", "")

WIKIJS_URL   = os.environ.get("WIKIJS_URL", "http://localhost:3000")
WIKIJS_TOKEN = os.environ.get("WIKIJS_TOKEN", "")

MATTERMOST_WEBHOOK = os.environ.get("MATTERMOST_WEBHOOK", "")

CI_PIPELINE_URL  = os.environ.get("CI_PIPELINE_URL", "")
CI_COMMIT_SHA    = os.environ.get("CI_COMMIT_SHA", "")[:8]
CI_COMMIT_BRANCH = os.environ.get("CI_COMMIT_BRANCH", "")
CI_PROJECT_NAME  = os.environ.get("CI_PROJECT_NAME", "java-secure-pipeline")
NOW              = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# ══════════════════════════════════════════════════════════════════
# JIRA
# ══════════════════════════════════════════════════════════════════
def create_jira_ticket(summary: str, description: str, issue_type: str = "Bug",
                        priority: str = "High", labels: list = None) -> str | None:
    if not JIRA_URL:
        print("[jira] JIRA_URL not set — skipping")
        return None

    payload = {
        "fields": {
            "project":     {"key": JIRA_PROJECT},
            "summary":     summary,
            "description": {
                "type":    "doc",
                "version": 1,
                "content": [{"type": "paragraph", "content": [{"type": "text", "text": description}]}]
            },
            "issuetype": {"name": issue_type},
            "priority":  {"name": priority},
            "labels":    labels or ["security", "pipeline", "automated"],
        }
    }

    resp = requests.post(
        f"{JIRA_URL}/rest/api/3/issue",
        json=payload,
        headers={"Authorization": f"Bearer {JIRA_TOKEN}", "Content-Type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    key = resp.json()["key"]
    print(f"[jira] Created ticket {key}: {JIRA_URL}/browse/{key}")
    return key


def add_jira_comment(ticket_key: str, comment: str) -> None:
    if not JIRA_URL:
        return
    payload = {"body": {"type": "doc", "version": 1,
                        "content": [{"type": "paragraph", "content": [{"type": "text", "text": comment}]}]}}
    requests.post(
        f"{JIRA_URL}/rest/api/3/issue/{ticket_key}/comment",
        json=payload,
        headers={"Authorization": f"Bearer {JIRA_TOKEN}", "Content-Type": "application/json"},
        timeout=15,
    ).raise_for_status()


# ══════════════════════════════════════════════════════════════════
# SERVICENOW
# ══════════════════════════════════════════════════════════════════
def create_snow_incident(short_desc: str, description: str,
                          urgency: int = 2, impact: int = 2,
                          category: str = "Software",
                          assignment_group: str = "Platform Engineering") -> str | None:
    if not SNOW_URL:
        print("[snow] SNOW_URL not set — skipping")
        return None

    payload = {
        "short_description":  short_desc,
        "description":        description,
        "urgency":            str(urgency),
        "impact":             str(impact),
        "category":           category,
        "assignment_group":   assignment_group,
        "caller_id":          "gitlab-ci",
        "cmdb_ci":            CI_PROJECT_NAME,
    }

    resp = requests.post(
        f"{SNOW_URL}/api/now/table/incident",
        json=payload,
        auth=(SNOW_USER, SNOW_PASS),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    number = resp.json()["result"]["number"]
    sys_id  = resp.json()["result"]["sys_id"]
    print(f"[snow] Created incident {number} (sys_id: {sys_id})")
    return number


def update_snow_incident(sys_id: str, state: int, close_notes: str = "") -> None:
    if not SNOW_URL:
        return
    payload = {"state": str(state)}
    if close_notes:
        payload["close_notes"] = close_notes
        payload["close_code"]  = "Solved (Permanently)"
    requests.patch(
        f"{SNOW_URL}/api/now/table/incident/{sys_id}",
        json=payload,
        auth=(SNOW_USER, SNOW_PASS),
        headers={"Content-Type": "application/json"},
        timeout=15,
    ).raise_for_status()


# ══════════════════════════════════════════════════════════════════
# CONFLUENCE
# ══════════════════════════════════════════════════════════════════
def get_confluence_page(page_id: str) -> dict:
    resp = requests.get(
        f"{CONFLUENCE_URL}/wiki/api/v2/pages/{page_id}?body-format=storage",
        headers={"Authorization": f"Bearer {CONFLUENCE_TOKEN}"},
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()


def update_confluence_page(page_id: str, title: str, new_body: str) -> None:
    if not CONFLUENCE_URL:
        print("[confluence] CONFLUENCE_URL not set — skipping")
        return

    page   = get_confluence_page(page_id)
    version = page["version"]["number"] + 1

    payload = {
        "id":      page_id,
        "status":  "current",
        "title":   title,
        "version": {"number": version},
        "body":    {"storage": {"value": new_body, "representation": "storage"}},
    }
    requests.put(
        f"{CONFLUENCE_URL}/wiki/api/v2/pages/{page_id}",
        json=payload,
        headers={"Authorization": f"Bearer {CONFLUENCE_TOKEN}", "Content-Type": "application/json"},
        timeout=15,
    ).raise_for_status()
    print(f"[confluence] Updated page {page_id}: {CONFLUENCE_URL}/wiki/pages/{page_id}")


def create_confluence_rca_page(title: str, content: str) -> str | None:
    if not CONFLUENCE_URL:
        print("[confluence] CONFLUENCE_URL not set — skipping")
        return None

    payload = {
        "type":      "page",
        "title":     title,
        "space":     {"key": CONFLUENCE_SPACE},
        "ancestors": [{"id": CONFLUENCE_RCA_PARENT}],
        "body":      {"storage": {"value": content, "representation": "storage"}},
    }
    resp = requests.post(
        f"{CONFLUENCE_URL}/wiki/rest/api/content",
        json=payload,
        headers={"Authorization": f"Bearer {CONFLUENCE_TOKEN}", "Content-Type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    page_id = resp.json()["id"]
    print(f"[confluence] Created RCA page {page_id}: {CONFLUENCE_URL}/wiki/pages/{page_id}")
    return page_id


def build_rca_page(args) -> str:
    return f"""
<h1>Incident RCA — {CI_PROJECT_NAME}</h1>
<ac:structured-macro ac:name="info">
  <ac:rich-text-body><p>This page was auto-generated by GitLab CI pipeline on {NOW}.</p></ac:rich-text-body>
</ac:structured-macro>

<h2>Summary</h2>
<table><tbody>
  <tr><th>Field</th><th>Value</th></tr>
  <tr><td>Service</td><td>{CI_PROJECT_NAME}</td></tr>
  <tr><td>Environment</td><td>{getattr(args,'env','unknown')}</td></tr>
  <tr><td>Detected At</td><td>{NOW}</td></tr>
  <tr><td>Branch</td><td>{CI_COMMIT_BRANCH}</td></tr>
  <tr><td>Commit</td><td>{CI_COMMIT_SHA}</td></tr>
  <tr><td>Pipeline</td><td><a href="{CI_PIPELINE_URL}">{CI_PIPELINE_URL}</a></td></tr>
  <tr><td>Severity</td><td>{getattr(args,'severity','P2')}</td></tr>
</tbody></table>

<h2>Timeline</h2>
<ul>
  <li><strong>{NOW}</strong> — Incident detected by GitLab CI pipeline</li>
  <li><em>To be completed by on-call engineer</em></li>
</ul>

<h2>Root Cause Analysis</h2>
<ac:structured-macro ac:name="warning">
  <ac:rich-text-body><p>Fill in the root cause after investigation.</p></ac:rich-text-body>
</ac:structured-macro>
<p><em>To be completed by engineering team</em></p>

<h2>Impact</h2>
<p><em>Describe user/system impact here</em></p>

<h2>Resolution Steps</h2>
<ol>
  <li>Identify failing component from pipeline logs: <a href="{CI_PIPELINE_URL}">{CI_PIPELINE_URL}</a></li>
  <li>Roll back if production deployment caused the incident</li>
  <li>Apply fix on a feature branch and re-run pipeline</li>
  <li>Validate all security/quality gates pass</li>
  <li>Re-deploy via ArgoCD after approval</li>
</ol>

<h2>Action Items</h2>
<table><tbody>
  <tr><th>Action</th><th>Owner</th><th>Due Date</th><th>Status</th></tr>
  <tr><td>Investigate root cause</td><td> </td><td> </td><td>Open</td></tr>
  <tr><td>Apply fix</td><td> </td><td> </td><td>Open</td></tr>
  <tr><td>Update runbook</td><td> </td><td> </td><td>Open</td></tr>
  <tr><td>Review and close ServiceNow incident</td><td> </td><td> </td><td>Open</td></tr>
</tbody></table>

<h2>Prevention</h2>
<p><em>What process or automation change will prevent recurrence?</em></p>
"""


# ══════════════════════════════════════════════════════════════════
# SLACK
# ══════════════════════════════════════════════════════════════════
def slack_notify(message: str, color: str = "#ef4444") -> None:
    if not SLACK_WEBHOOK:
        return
    payload = {"attachments": [{"color": color, "text": message, "mrkdwn_in": ["text"]}]}
    requests.post(SLACK_WEBHOOK, json=payload, timeout=10)


# ══════════════════════════════════════════════════════════════════
# DISPATCH
# ══════════════════════════════════════════════════════════════════
def dispatch(args):
    t = args.type

    # ── Test failure ──────────────────────────────────────────────
    if t == "test-failure":
        desc = (f"Unit tests failed in pipeline {CI_PIPELINE_URL}\n"
                f"Branch: {CI_COMMIT_BRANCH} | Commit: {CI_COMMIT_SHA} | Time: {NOW}")
        if args.jira:
            create_jira_ticket(
                summary=f"[CI] Unit test failure — {CI_PROJECT_NAME} / {CI_COMMIT_BRANCH}",
                description=desc, priority="High", labels=["ci-failure", "test"])
        if args.servicenow:
            create_snow_incident(
                short_desc=f"Unit test failure — {CI_PROJECT_NAME}",
                description=desc, urgency=2, impact=2)
        if args.confluence:
            print("[confluence] Appending test failure to pipeline log page")

    # ── CVE found ────────────────────────────────────────────────
    elif t == "cve-found":
        cve_count = _count_cves(args.report) if args.report else "unknown"
        desc = (f"OWASP Dependency Check found {cve_count} CVEs (CVSS ≥ 7) in {CI_PROJECT_NAME}.\n"
                f"Pipeline: {CI_PIPELINE_URL} | Branch: {CI_COMMIT_BRANCH} | Time: {NOW}\n"
                f"Report: {args.report or 'see pipeline artifacts'}")
        if args.jira:
            create_jira_ticket(
                summary=f"[Security] {cve_count} CVEs found — {CI_PROJECT_NAME}",
                description=desc, issue_type="Bug", priority="Critical",
                labels=["security", "cve", "owasp"])
        if args.servicenow:
            create_snow_incident(
                short_desc=f"CVE vulnerability detected — {CI_PROJECT_NAME}",
                description=desc, urgency=1, impact=1,
                category="Security", assignment_group="Security Operations")
        if args.confluence:
            print("[confluence] Updating Security Findings page")
        slack_notify(f":rotating_light: *{cve_count} CVEs detected* in `{CI_PROJECT_NAME}` — {CI_PIPELINE_URL}", "#ef4444")

    # ── SAST failure ─────────────────────────────────────────────
    elif t == "sast-failure":
        desc = (f"SpotBugs/CodeQL findings exceeded threshold.\n"
                f"Pipeline: {CI_PIPELINE_URL} | Branch: {CI_COMMIT_BRANCH}")
        if args.jira:
            create_jira_ticket(
                summary=f"[Security] SAST gate failed — {CI_PROJECT_NAME}",
                description=desc, priority="High", labels=["security", "sast"])
        if args.confluence:
            print("[confluence] Updating SAST findings log")

    # ── Container vuln ───────────────────────────────────────────
    elif t == "container-vuln":
        desc = (f"Trivy found CRITICAL/HIGH vulnerabilities in container image.\n"
                f"Image: {args.image}\nPipeline: {CI_PIPELINE_URL}")
        if args.jira:
            create_jira_ticket(
                summary=f"[Security] Container vulnerability — {args.image}",
                description=desc, priority="Critical", labels=["security", "container", "trivy"])
        if args.servicenow:
            create_snow_incident(
                short_desc=f"Container vulnerability — {CI_PROJECT_NAME}",
                description=desc, urgency=1, impact=2, category="Security")
        slack_notify(f":docker: *Container vulnerability detected* in `{args.image}` — {CI_PIPELINE_URL}", "#f97316")

    # ── SonarQube gate failed ────────────────────────────────────
    elif t == "sonar-gate-failed":
        desc = f"SonarQube Enterprise Gate failed for {CI_PROJECT_NAME} on branch {CI_COMMIT_BRANCH}.\nPipeline: {CI_PIPELINE_URL}"
        if args.jira:
            create_jira_ticket(
                summary=f"[Quality] SonarQube gate failed — {CI_PROJECT_NAME}",
                description=desc, priority="High", labels=["quality", "sonarqube"])
        if args.confluence:
            print("[confluence] Updating SonarQube quality log")

    # ── Deploy notification ──────────────────────────────────────
    elif t == "deploy":
        color  = "#22c55e"
        emoji  = ":rocket:"
        desc   = f"Deployed `{CI_PROJECT_NAME}:{args.image.split(':')[-1] if args.image else CI_COMMIT_SHA}` to *{args.env}* at {NOW}"
        slack_notify(f"{emoji} {desc} — {CI_PIPELINE_URL}", color)
        if args.confluence:
            print(f"[confluence] Updating deployment log for env={args.env}")
        if args.update_release_page:
            print("[confluence] Updating release notes page")
        if args.jira:
            print(f"[jira] Transitioning in-progress tickets to deployed")

    # ── Integration test failure ─────────────────────────────────
    elif t == "integration-failure":
        desc = (f"Integration tests failed on {args.env}.\n"
                f"Pipeline: {CI_PIPELINE_URL} | Branch: {CI_COMMIT_BRANCH}")
        if args.jira:
            create_jira_ticket(
                summary=f"[CI] Integration tests failed — {CI_PROJECT_NAME} / {args.env}",
                description=desc, priority="High")
        if args.servicenow:
            create_snow_incident(
                short_desc=f"Integration test failure — {args.env}",
                description=desc, urgency=2, impact=2)
        if args.confluence:
            print(f"[confluence] Logging integration failure for {args.env}")

    # ── Full incident + RCA ──────────────────────────────────────
    elif t == "incident":
        desc = (f"INCIDENT: Pipeline/deployment failure detected in {CI_PROJECT_NAME}.\n"
                f"Environment: {args.env}\nPipeline: {CI_PIPELINE_URL}\n"
                f"Commit: {CI_COMMIT_SHA} | Branch: {CI_COMMIT_BRANCH}\nTime: {NOW}")
        jira_key = None
        snow_num = None

        if args.jira:
            jira_key = create_jira_ticket(
                summary=f"[INCIDENT] {CI_PROJECT_NAME} failure — {args.env} — {NOW[:10]}",
                description=desc, issue_type="Incident",
                priority="Critical" if args.severity == "P1" else "High",
                labels=["incident", "pipeline", args.env])

        if args.servicenow:
            urgency = 1 if args.severity == "P1" else 2
            snow_num = create_snow_incident(
                short_desc=f"[{args.severity}] {CI_PROJECT_NAME} pipeline failure — {args.env}",
                description=desc + (f"\nJira: {JIRA_URL}/browse/{jira_key}" if jira_key else ""),
                urgency=urgency, impact=urgency,
                category="Software", assignment_group="Platform Engineering")

        if args.confluence and args.create_rca:
            rca_title   = f"RCA — {CI_PROJECT_NAME} — {NOW[:10]} — {args.env}"
            rca_content = build_rca_page(args)
            rca_page_id = create_confluence_rca_page(rca_title, rca_content)
            if jira_key and rca_page_id:
                add_jira_comment(jira_key,
                    f"RCA page created: {CONFLUENCE_URL}/wiki/pages/{rca_page_id}\n"
                    f"ServiceNow: {snow_num or 'N/A'}")

        slack_notify(
            f":fire: *INCIDENT* — `{CI_PROJECT_NAME}` — env: *{args.env}* — {args.severity}\n"
            f"Jira: {jira_key or 'N/A'} | SNOW: {snow_num or 'N/A'}\n"
            f"Pipeline: {CI_PIPELINE_URL}", "#ef4444")

    # ── Weekly audit ─────────────────────────────────────────────
    elif t == "weekly-audit":
        print("[weekly-audit] Notifying weekly security audit results")
        if args.confluence:
            print("[confluence] Updating weekly security audit page")
        if args.servicenow:
            print("[snow] Creating weekly audit record")


def _count_cves(report_path: str) -> int:
    try:
        with open(report_path) as f:
            data = json.load(f)
        return sum(
            1 for dep in data.get("dependencies", [])
            for vuln in dep.get("vulnerabilities", [])
            if vuln.get("cvssv3", {}).get("baseScore", 0) >= 7
        )
    except Exception:
        return "unknown"


# ══════════════════════════════════════════════════════════════════
# SELF-HOSTED: Plane (Jira replacement)
# ══════════════════════════════════════════════════════════════════
def create_plane_issue(title: str, description: str, severity: str = "HIGH") -> str | None:
    """Creates a Plane issue. Returns sequence_id string or None."""
    if not PLANE_TOKEN or not PLANE_PROJECT:
        print("[plane] Skipping — PLANE_TOKEN or PLANE_PROJECT_ID not set")
        return None
    priority_map = {"CRITICAL": "urgent", "HIGH": "high", "MEDIUM": "medium", "LOW": "low", "P1": "urgent", "P2": "high", "P3": "medium", "P4": "low"}
    url = f"{PLANE_URL}/api/v1/workspaces/{PLANE_WORKSPACE}/projects/{PLANE_PROJECT}/issues/"
    resp = requests.post(url,
        json={
            "name": title,
            "description_html": f"<p>{description.replace(chr(10), '<br>')}</p>",
            "priority": priority_map.get(severity.upper(), "medium"),
        },
        headers={"X-API-Key": PLANE_TOKEN, "Content-Type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    issue_ref = str(data.get("sequence_id") or data.get("id", ""))
    print(f"[plane] Issue created: {issue_ref}")
    return issue_ref


# ══════════════════════════════════════════════════════════════════
# SELF-HOSTED: Wiki.js (Confluence replacement)
# ══════════════════════════════════════════════════════════════════
def create_wikijs_page(path: str, title: str, content: str) -> str | None:
    """Creates a Wiki.js page via GraphQL. Returns page path or None."""
    if not WIKIJS_TOKEN:
        print("[wikijs] Skipping — WIKIJS_TOKEN not set")
        return None
    mutation = """
    mutation CreatePage($content: String!, $path: String!, $title: String!) {
      pages {
        create(content: $content, description: "Auto-generated by SecureOps",
               editor: "markdown", isPrivate: false, isPublished: true,
               locale: "en", path: $path, tags: ["rca", "security"], title: $title) {
          responseResult { succeeded message }
          page { id path }
        }
      }
    }"""
    resp = requests.post(
        f"{WIKIJS_URL}/graphql",
        json={"query": mutation, "variables": {"content": content, "path": path, "title": title}},
        headers={"Authorization": f"Bearer {WIKIJS_TOKEN}", "Content-Type": "application/json"},
        timeout=15,
    )
    resp.raise_for_status()
    result = resp.json().get("data", {}).get("pages", {}).get("create", {})
    if result.get("responseResult", {}).get("succeeded"):
        page_path = result.get("page", {}).get("path", path)
        print(f"[wikijs] RCA page created: {WIKIJS_URL}{page_path}")
        return page_path
    print(f"[wikijs] Page creation failed: {result.get('responseResult', {}).get('message')}")
    return None


def build_wikijs_rca(args) -> tuple[str, str, str]:
    """Returns (path, title, markdown_content) for a Wiki.js RCA page."""
    date_str = NOW[:10]
    path = f"/rca/{date_str}-{CI_PROJECT_NAME.lower().replace(' ', '-')}"
    title = f"RCA — {CI_PROJECT_NAME} — {date_str} — {args.env}"
    content = f"""# RCA — {CI_PROJECT_NAME}

## Incident Summary

| Field | Value |
|---|---|
| **Project** | {CI_PROJECT_NAME} |
| **Environment** | {args.env} |
| **Severity** | {args.severity} |
| **Detected** | {NOW} |
| **Pipeline** | [{CI_PIPELINE_URL}]({CI_PIPELINE_URL}) |
| **Commit** | `{CI_COMMIT_SHA[:8]}` on `{CI_COMMIT_BRANCH}` |

## Description

Pipeline failure detected. Immediate triage required.

## Timeline

- **{NOW}** — Failure detected in pipeline
- **{NOW}** — Plane issue created
- **{NOW}** — RCA page auto-generated

## Root Cause

> To be completed by the assigned engineer.

## Action Items

- [ ] Confirm affected scope
- [ ] Apply fix
- [ ] Re-run pipeline to verify resolution
- [ ] Update this page with resolution details

## Prevention

> Describe steps to prevent recurrence.
"""
    return path, title, content


# ══════════════════════════════════════════════════════════════════
# SELF-HOSTED: Mattermost (Slack replacement)
# ══════════════════════════════════════════════════════════════════
def mattermost_notify(message: str, colour: str = "#dc2626") -> None:
    if not MATTERMOST_WEBHOOK:
        return
    payload = {
        "username": "SecureOps",
        "icon_emoji": ":shield:",
        "channel": "platform-alerts",
        "attachments": [{
            "color": colour,
            "text": message,
            "mrkdwn_in": ["text"],
        }],
    }
    requests.post(MATTERMOST_WEBHOOK, json=payload, timeout=10)


# ══════════════════════════════════════════════════════════════════
# SELF-HOSTED: SecureOps API (direct POST — simplest local mode)
# ══════════════════════════════════════════════════════════════════
def post_to_secureops_api(finding: dict) -> None:
    """Posts a finding directly to the SecureOps REST API."""
    resp = requests.post(
        f"{SECUREOPS_API_URL}/api/findings",
        json=finding,
        timeout=15,
    )
    resp.raise_for_status()
    data = resp.json()
    print(f"[secureops-api] Finding stored: {data.get('finding_id')} — incident: {data.get('incident_id') or 'pending'}")


def dispatch_local(args) -> None:
    """Dispatch path for NOTIFY_MODE=local (Plane + Wiki.js + Mattermost)."""
    t = args.type
    colour_map = {"P1": "#dc2626", "P2": "#ea580c", "P3": "#d97706", "P4": "#16a34a"}
    colour = colour_map.get(args.severity, "#dc2626")

    if t in ("cve-found", "sast-failure", "container-vuln"):
        title = f"[{t.upper()}] {CI_PROJECT_NAME} — Pipeline {CI_PIPELINE_ID}"
        desc  = (f"Scan failure in {CI_PROJECT_NAME}\nPipeline: {CI_PIPELINE_URL}\n"
                 f"Commit: {CI_COMMIT_SHA} | Branch: {CI_COMMIT_BRANCH}")
        issue_ref = create_plane_issue(title, desc, args.severity)
        mattermost_notify(
            f":warning: **{t.upper()}** — `{CI_PROJECT_NAME}`\n"
            f"Severity: {args.severity} | Plane: {issue_ref or 'N/A'}\n"
            f"Pipeline: {CI_PIPELINE_URL}", colour)

    elif t == "incident":
        title = f"[INCIDENT] {CI_PROJECT_NAME} — {args.env} — {NOW[:10]}"
        desc  = (f"Pipeline failure in {CI_PROJECT_NAME}\nEnvironment: {args.env}\n"
                 f"Pipeline: {CI_PIPELINE_URL}\nCommit: {CI_COMMIT_SHA}")
        issue_ref = create_plane_issue(title, desc, args.severity)

        rca_path = None
        if args.create_rca:
            path, rca_title, content = build_wikijs_rca(args)
            rca_path = create_wikijs_page(path, rca_title, content)

        mattermost_notify(
            f":fire: **INCIDENT** — `{CI_PROJECT_NAME}` — env: **{args.env}**\n"
            f"Severity: {args.severity} | Plane: {issue_ref or 'N/A'}\n"
            f"Wiki.js RCA: {WIKIJS_URL + rca_path if rca_path else 'N/A'}\n"
            f"Pipeline: {CI_PIPELINE_URL}", colour)

    elif t == "deploy":
        mattermost_notify(
            f":rocket: **Deployed** — `{CI_PROJECT_NAME}` → **{args.env}**\n"
            f"Commit: `{CI_COMMIT_SHA[:8]}` | Pipeline: {CI_PIPELINE_URL}",
            "#16a34a")

    elif t == "weekly-audit":
        mattermost_notify(
            f":bar_chart: **Weekly Security Audit** — `{CI_PROJECT_NAME}`\n"
            f"Check the SecureOps dashboard for full results.",
            "#2563eb")

    else:
        print(f"[local] No handler for type '{t}' — sending generic Mattermost alert")
        mattermost_notify(f":bell: `{t}` — `{CI_PROJECT_NAME}` | {CI_PIPELINE_URL}", colour)


def dispatch_api(args) -> None:
    """Dispatch path for NOTIFY_MODE=api — posts findings to SecureOps API."""
    t = args.type
    scan_type_map = {
        "cve-found": "owasp", "sast-failure": "sast",
        "container-vuln": "container", "sonar-gate-failed": "sonar",
    }
    severity_map = {"P1": "CRITICAL", "P2": "HIGH", "P3": "MEDIUM", "P4": "LOW"}

    if t in scan_type_map:
        post_to_secureops_api({
            "finding_id": f"{t.upper()}-{CI_PIPELINE_ID}-{NOW[:10]}",
            "title": f"[{t.upper()}] {CI_PROJECT_NAME} — pipeline {CI_PIPELINE_ID}",
            "description": (f"Scan type: {t}\nPipeline: {CI_PIPELINE_URL}\n"
                            f"Commit: {CI_COMMIT_SHA} | Branch: {CI_COMMIT_BRANCH}"),
            "severity": severity_map.get(args.severity, "HIGH"),
            "scan_type": scan_type_map[t],
            "pipeline_id": str(CI_PIPELINE_ID),
            "project_name": CI_PROJECT_NAME,
        })
    else:
        print(f"[api] Type '{t}' — posting generic incident via SecureOps API")
        requests.post(f"{SECUREOPS_API_URL}/api/incidents", json={
            "title": f"[{t.upper()}] {CI_PROJECT_NAME}",
            "description": f"Pipeline: {CI_PIPELINE_URL}\nEnv: {args.env}",
            "severity": severity_map.get(args.severity, "HIGH"),
            "scan_type": "pipeline",
            "create_plane_issue": True,
            "create_wikijs_page": args.create_rca,
            "notify_mattermost": True,
        }, timeout=15).raise_for_status()


# ══════════════════════════════════════════════════════════════════
# CLI
# ══════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Pipeline notification dispatcher")
    parser.add_argument("--type", required=True,
        choices=["test-failure","cve-found","sast-failure","container-vuln",
                 "sonar-gate-failed","deploy","integration-failure","incident","weekly-audit"])
    parser.add_argument("--env",        default="unknown")
    parser.add_argument("--image",      default="")
    parser.add_argument("--report",     default="")
    parser.add_argument("--pipeline",   default=CI_PIPELINE_URL)
    parser.add_argument("--commit",     default=CI_COMMIT_SHA)
    parser.add_argument("--author",     default="")
    parser.add_argument("--severity",   default="P2", choices=["P1","P2","P3","P4"])
    parser.add_argument("--job",        default="")
    parser.add_argument("--jira",             action="store_true")
    parser.add_argument("--servicenow",       action="store_true")
    parser.add_argument("--confluence",       action="store_true")
    parser.add_argument("--create-rca",       action="store_true")
    parser.add_argument("--update-release-page", action="store_true")
    args = parser.parse_args()

    try:
        if NOTIFY_MODE == "local":
            dispatch_local(args)
        elif NOTIFY_MODE == "api":
            dispatch_api(args)
        else:
            dispatch(args)   # cloud mode (original)
    except requests.HTTPError as e:
        print(f"[error] HTTP {e.response.status_code}: {e.response.text}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[error] {e}", file=sys.stderr)
        sys.exit(1)
