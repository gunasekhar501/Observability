#!/bin/bash
# ══════════════════════════════════════════════════════════════
#  SecureOps — Local Security Scan Runner
#  Runs Maven security scans and streams real findings to the
#  SecureOps API so the dashboard shows live data.
#
#  Usage:
#    ./scripts/run-local-scan.sh
#
#  Environment variables:
#    SECUREOPS_API_URL  default: http://localhost:8080
#    SONAR_HOST_URL     default: http://localhost:9200
#    SONAR_TOKEN        set after running setup-local.sh
#    SONAR_PROJECT_KEY  default: java-secure-pipeline
# ══════════════════════════════════════════════════════════════
set -uo pipefail

API_URL="${SECUREOPS_API_URL:-http://localhost:8080}"
SCAN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[SCAN]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

cd "$SCAN_DIR"

# ── Check API is reachable ─────────────────────────────────────
if ! curl -sf "${API_URL}/health" > /dev/null 2>&1; then
    warn "SecureOps API not reachable at ${API_URL}"
    warn "Start the stack first: docker compose up -d secureops-api"
    warn "Scan will still run; POST will be skipped."
fi

echo ""
echo "SecureOps Local Scan — $(date '+%Y-%m-%d %H:%M:%S')"
echo "────────────────────────────────────────────────────────"

# ── Step 1: Compile ───────────────────────────────────────────
info "Step 1 — Compiling project..."
mvn --batch-mode --no-transfer-progress compile -q
success "Compilation OK"

# ── Step 2: Unit tests + JaCoCo ───────────────────────────────
info "Step 2 — Running unit tests..."
mvn --batch-mode --no-transfer-progress test jacoco:report -q || true
success "Tests complete (see target/site/jacoco/index.html)"

# ── Step 3: SpotBugs static analysis ──────────────────────────
info "Step 3 — Running SpotBugs (with findsecbugs)..."
mvn --batch-mode --no-transfer-progress spotbugs:spotbugs \
    -Dspotbugs.failOnError=false -q 2>/dev/null || true

SPOTBUGS_XML="target/spotbugsXml.xml"
if [ -f "$SPOTBUGS_XML" ]; then
    SPOTBUGS_COUNT=$(grep -c '<BugInstance' "$SPOTBUGS_XML" 2>/dev/null || echo 0)
    success "SpotBugs: ${SPOTBUGS_COUNT} bugs found → $SPOTBUGS_XML"
else
    warn "SpotBugs report not generated"
fi

# ── Step 4: PMD ───────────────────────────────────────────────
info "Step 4 — Running PMD..."
mvn --batch-mode --no-transfer-progress pmd:pmd pmd:cpd -q 2>/dev/null || true

PMD_XML="target/pmd.xml"
if [ -f "$PMD_XML" ]; then
    PMD_COUNT=$(grep -c '<violation' "$PMD_XML" 2>/dev/null || echo 0)
    success "PMD: ${PMD_COUNT} violations found → $PMD_XML"
fi

# ── Step 5: OWASP Dependency-Check ────────────────────────────
info "Step 5 — Running OWASP Dependency-Check (needs NVD data, may take a few minutes)..."
mvn --batch-mode --no-transfer-progress \
    org.owasp:dependency-check-maven:"${OWASP_PLUGIN_VERSION:-9.0.9}":check \
    -DfailBuildOnCVSS=11 \
    -Dformat=ALL \
    -DoutputDirectory=target/dependency-check \
    -DnvdApiKeyEnvironmentVariable=NVD_API_KEY \
    -q 2>/dev/null || true

OWASP_JSON="target/dependency-check/dependency-check-report.json"
if [ -f "$OWASP_JSON" ]; then
    VULN_COUNT=$(python3 -c \
        "import json; r=json.load(open('$OWASP_JSON')); \
         print(sum(len(d.get('vulnerabilities',[])) for d in r.get('dependencies',[])))" \
        2>/dev/null || echo "?")
    success "OWASP: ${VULN_COUNT} CVEs found → $OWASP_JSON"
else
    warn "OWASP report not generated (run with NVD_API_KEY for full data)"
fi

echo "────────────────────────────────────────────────────────"

# ── Step 6: POST SpotBugs findings to API ─────────────────────
if [ -f "$SPOTBUGS_XML" ]; then
    info "Step 6 — Posting SpotBugs findings to SecureOps API..."
    python3 << PYEOF
import xml.etree.ElementTree as ET
import json
import urllib.request
import urllib.error
import sys

API = "${API_URL}"
PRIORITY_MAP = {"1": "HIGH", "2": "MEDIUM", "3": "LOW", "4": "LOW"}

try:
    tree = ET.parse("${SPOTBUGS_XML}")
except ET.ParseError as ex:
    print(f"  Cannot parse SpotBugs XML: {ex}")
    sys.exit(0)

root = tree.getroot()
posted = 0

for bug in root.findall(".//BugInstance"):
    priority = bug.get("priority", "3")
    bug_type = bug.get("type", "UNKNOWN")
    category = bug.get("category", "CORRECTNESS")
    severity = PRIORITY_MAP.get(priority, "LOW")
    if category in ("SECURITY", "MALICIOUS_CODE"):
        severity = "HIGH" if severity == "LOW" else severity

    clazz_elem = bug.find(".//Class")
    source_elem = bug.find(".//SourceLine")
    class_name = clazz_elem.get("classname", "Unknown").split(".")[-1] if clazz_elem is not None else "Unknown"
    line = int(source_elem.get("start", "0")) if source_elem is not None else 0
    msg_elem = bug.find("LongMessage") or bug.find("ShortMessage")
    message = (msg_elem.text or bug_type).strip() if msg_elem is not None else bug_type

    finding = {
        "title": f"SpotBugs: {bug_type}",
        "description": message,
        "severity": severity,
        "source": "spotbugs",
        "component": class_name,
        "line": line,
        "rule": bug_type,
        "category": category,
        "status": "OPEN",
    }

    try:
        req = urllib.request.Request(
            f"{API}/api/findings",
            data=json.dumps(finding).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5):
            posted += 1
            print(f"  [{severity:8s}] {bug_type} in {class_name}:{line}")
    except urllib.error.URLError as ex:
        print(f"  POST failed ({bug_type}): {ex}")

print(f"  SpotBugs: {posted} findings posted to {API}")
PYEOF
fi

# ── Step 7: POST PMD findings to API ──────────────────────────
if [ -f "$PMD_XML" ]; then
    info "Step 7 — Posting PMD findings to SecureOps API..."
    python3 << PYEOF
import xml.etree.ElementTree as ET
import json
import urllib.request
import urllib.error
import sys

API = "${API_URL}"
PRIORITY_MAP = {"1": "CRITICAL", "2": "HIGH", "3": "MEDIUM", "4": "LOW", "5": "LOW"}

try:
    tree = ET.parse("${PMD_XML}")
except ET.ParseError as ex:
    print(f"  Cannot parse PMD XML: {ex}")
    sys.exit(0)

root = tree.getroot()
posted = 0

for file_elem in root.findall(".//file"):
    filename = file_elem.get("name", "").split("\\")[-1].split("/")[-1]
    for violation in file_elem.findall("violation"):
        priority = violation.get("priority", "3")
        rule = violation.get("rule", "UNKNOWN")
        ruleset = violation.get("ruleset", "")
        line = int(violation.get("beginline", "0"))
        message = (violation.text or rule).strip()

        finding = {
            "title": f"PMD: {rule}",
            "description": message,
            "severity": PRIORITY_MAP.get(priority, "MEDIUM"),
            "source": "pmd",
            "component": filename,
            "line": line,
            "rule": rule,
            "category": ruleset,
            "status": "OPEN",
        }

        try:
            req = urllib.request.Request(
                f"{API}/api/findings",
                data=json.dumps(finding).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5):
                posted += 1
        except urllib.error.URLError:
            pass

print(f"  PMD: {posted} findings posted to {API}")
PYEOF
fi

# ── Step 8: POST OWASP findings to API ────────────────────────
if [ -f "$OWASP_JSON" ]; then
    info "Step 8 — Posting OWASP CVE findings to SecureOps API..."
    python3 << PYEOF
import json
import urllib.request
import urllib.error
import sys

API = "${API_URL}"

def cvss_to_severity(score):
    if score is None:
        return "MEDIUM"
    if score >= 9.0:
        return "CRITICAL"
    if score >= 7.0:
        return "HIGH"
    if score >= 4.0:
        return "MEDIUM"
    return "LOW"

try:
    with open("${OWASP_JSON}") as f:
        report = json.load(f)
except (json.JSONDecodeError, OSError) as ex:
    print(f"  Cannot read OWASP report: {ex}")
    sys.exit(0)

posted = 0

for dep in report.get("dependencies", []):
    dep_name = dep.get("fileName", "unknown")
    for vuln in dep.get("vulnerabilities", []):
        cve_id = vuln.get("name", "CVE-UNKNOWN")
        description = vuln.get("description", "Vulnerable dependency")[:500]

        cvss = None
        cvss3 = vuln.get("cvssv3")
        if isinstance(cvss3, dict):
            cvss = cvss3.get("baseScore")
        if cvss is None:
            cvss2 = vuln.get("cvssv2")
            if isinstance(cvss2, dict):
                cvss = cvss2.get("score")

        finding = {
            "title": cve_id,
            "description": description,
            "severity": cvss_to_severity(cvss),
            "source": "owasp",
            "component": dep_name,
            "cvss_score": cvss,
            "rule": cve_id,
            "category": "DEPENDENCY",
            "status": "OPEN",
        }

        try:
            req = urllib.request.Request(
                f"{API}/api/findings",
                data=json.dumps(finding).encode(),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=5):
                posted += 1
                sev = finding["severity"]
                print(f"  [{sev:8s}] {cve_id} in {dep_name}")
        except urllib.error.URLError as ex:
            print(f"  POST failed ({cve_id}): {ex}")

print(f"  OWASP: {posted} CVE findings posted to {API}")
PYEOF
fi

# ── Step 9: Poll SonarQube ─────────────────────────────────────
SONAR_URL="${SONAR_HOST_URL:-http://localhost:9200}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_PROJECT="${SONAR_PROJECT_KEY:-java-secure-pipeline}"

if curl -sf "${SONAR_URL}/api/system/status" > /dev/null 2>&1 && [ -n "$SONAR_TOKEN" ]; then
    info "Step 9 — Running SonarQube analysis and fetching findings..."

    mvn --batch-mode --no-transfer-progress sonar:sonar \
        -Dsonar.host.url="${SONAR_URL}" \
        -Dsonar.login="${SONAR_TOKEN}" \
        -Dsonar.projectKey="${SONAR_PROJECT}" \
        -Dsonar.qualitygate.wait=false \
        -q 2>/dev/null || true

    python3 << PYEOF
import json
import urllib.request
import urllib.parse
import urllib.error
import base64
import sys

API = "${API_URL}"
SONAR_URL = "${SONAR_URL}"
TOKEN = "${SONAR_TOKEN}"
PROJECT = "${SONAR_PROJECT}"

auth = base64.b64encode(f"{TOKEN}:".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}
SEV_MAP = {"BLOCKER": "CRITICAL", "CRITICAL": "HIGH", "MAJOR": "MEDIUM", "MINOR": "LOW", "INFO": "LOW"}

params = urllib.parse.urlencode({
    "componentKeys": PROJECT, "statuses": "OPEN", "ps": "100",
    "types": "VULNERABILITY,BUG,CODE_SMELL",
})

try:
    req = urllib.request.Request(f"{SONAR_URL}/api/issues/search?{params}", headers=headers)
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
except urllib.error.URLError as ex:
    print(f"  SonarQube fetch failed: {ex}")
    sys.exit(0)

posted = 0
for issue in data.get("issues", []):
    finding = {
        "title": f"SonarQube: {issue.get('message', 'Issue')[:80]}",
        "description": issue.get("message", ""),
        "severity": SEV_MAP.get(issue.get("severity", "MAJOR"), "MEDIUM"),
        "source": "sonarqube",
        "component": issue.get("component", PROJECT).split(":")[-1],
        "rule": issue.get("rule", ""),
        "category": issue.get("type", "VULNERABILITY"),
        "line": issue.get("line", 0),
        "status": "OPEN",
    }
    try:
        post_req = urllib.request.Request(
            f"{API}/api/findings",
            data=json.dumps(finding).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(post_req, timeout=5):
            posted += 1
    except urllib.error.URLError:
        pass

print(f"  SonarQube: {posted} issues posted to {API}")
PYEOF
else
    warn "Step 9 — SonarQube not reachable or SONAR_TOKEN not set; skipping"
    warn "   Set SONAR_TOKEN after running ./scripts/setup-local.sh"
fi

echo ""
echo "────────────────────────────────────────────────────────"
echo -e "${GREEN}Scan complete! Open the dashboard:${NC}"
echo "  http://localhost:8081"
echo ""
