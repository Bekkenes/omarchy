#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# Session counting walks ~/.omp/agent/sessions; pin HOME so the collector
# reads the fixture, not the developer's real omp state.
mkdir -p "$TEST_HOME/.omp/agent/sessions"
printf '{}\n' > "$TEST_HOME/.omp/agent/sessions/session-a.jsonl"
printf '{}\n' > "$TEST_HOME/.omp/agent/sessions/session-b.jsonl"

# Fake omp binaries for run_stats: one healthy, one failing, one non-JSON.
mkdir -p "$TEST_HOME/bin"
cat > "$TEST_HOME/bin/omp-stats-ok" <<'EOF'
#!/bin/sh
printf '%s' '{"overall":{"totalRequests":1},"byModel":[],"timeSeries":[]}'
EOF
cat > "$TEST_HOME/bin/omp-stats-fail" <<'EOF'
#!/bin/sh
exit 3
EOF
cat > "$TEST_HOME/bin/omp-stats-badjson" <<'EOF'
#!/bin/sh
printf '%s' 'not json'
EOF
chmod +x "$TEST_HOME/bin/omp-stats-ok" "$TEST_HOME/bin/omp-stats-fail" "$TEST_HOME/bin/omp-stats-badjson"

# Without an omp binary on PATH the collector must still print a valid,
# hidden-by-default record.
no_omp=$(HOME="$TEST_HOME" PATH="$TEST_HOME/bin" "$ROOT/bin/omarchy-agent-usage-omp")
[[ $(jq -r '.id + ":" + (.ready | tostring) + ":" + .usageStatusText' <<<"$no_omp") == "omp:false:omp unavailable" ]] ||
  fail "omp collector prints a valid record without an omp binary" "$no_omp"
pass "omp collector prints a valid record without an omp binary"

result=$(HOME="$TEST_HOME" python3 - "$ROOT/bin/omarchy-agent-usage-omp" "$TEST_HOME" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

collector_path = str(Path(sys.argv[1]))
test_home = Path(sys.argv[2])
os.environ["HOME"] = str(test_home)

# Date bucketing resolves in local time; pin the zone so the today/yesterday
# fixtures land on the intended calendar days no matter where the test runs.
os.environ["TZ"] = "UTC"
time.tzset()

loader = importlib.machinery.SourceFileLoader("omp_collector", collector_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
scanner = importlib.util.module_from_spec(spec)
loader.exec_module(scanner)

# ---- summarize() mapping ----
now_ms = int(time.time() * 1000)
yesterday_ms = now_ms - 86400 * 1000
data = {
  "overall": {"totalRequests": 5},
  "byModel": [
    {"model": "deepseek-chat", "provider": "deepseek",
     "totalInputTokens": 500, "totalOutputTokens": 100,
     "totalCacheReadTokens": 50, "totalCacheWriteTokens": 10},
    {"model": "claude-sonnet-4", "provider": "anthropic",
     "totalInputTokens": 200, "totalOutputTokens": 40,
     "totalCacheReadTokens": 20, "totalCacheWriteTokens": 5},
  ],
  "timeSeries": [
    {"timestamp": now_ms, "requests": 3, "tokens": 120},
    {"timestamp": yesterday_ms, "requests": 1, "tokens": 40},
  ],
}
stats = scanner.summarize(data)
summary = {
  "totalPrompts": stats["totalPrompts"],
  "todayPrompts": stats["todayPrompts"],
  "todayTotalTokens": stats["todayTotalTokens"],
  "todaySessions": stats["todaySessions"],
  "totalSessions": stats["totalSessions"],
  "activeDays": stats["activeDays"],
  "modelUsage": stats["modelUsage"],
  "recentDaysLast": stats["recentDays"][-1]["messageCount"],
  "recentDaysPrev": stats["recentDays"][-2]["messageCount"],
}

# ---- run_stats failure modes ----
bin_dir = test_home / "bin"
summary["runStatsOk"] = isinstance(scanner.run_stats(str(bin_dir / "omp-stats-ok")), dict)
summary["runStatsNonZero"] = scanner.run_stats(str(bin_dir / "omp-stats-fail")) is None
summary["runStatsBadJson"] = scanner.run_stats(str(bin_dir / "omp-stats-badjson")) is None
summary["runStatsMissing"] = scanner.run_stats("/nonexistent/omp-binary") is None

# A timeout must degrade to no-stats, not raise through main().
original_run = scanner.subprocess.run
def timeout_run(*args, **kwargs):
    raise subprocess.TimeoutExpired(args[0] if args else ["omp"], 120)
scanner.subprocess.run = timeout_run
summary["runStatsTimeout"] = scanner.run_stats(str(bin_dir / "omp-stats-ok")) is None
scanner.subprocess.run = original_run

# ---- fetch_deepseek_balance() ----
class FakeResponse:
    def __init__(self, payload):
        self._payload = payload
    def read(self):
        return json.dumps(self._payload).encode("utf-8")
    def __enter__(self):
        return self
    def __exit__(self, *exc):
        return False

class FakeProc:
    def __init__(self, stdout):
        self.stdout = stdout

def with_balance(payload):
    scanner.subprocess.run = lambda *a, **k: FakeProc("ds_test_key\n")
    scanner.urllib.request.urlopen = lambda *a, **k: FakeResponse(payload)

with_balance({"balance_infos": [{"currency": "USD", "total_balance": "110.00",
                                  "granted_balance": "10.00", "topped_up_balance": "100.00"}]})
summary["balance"] = scanner.fetch_deepseek_balance("/fake/omp")

# An exhausted account still surfaces a zero balance, not no balance at all.
with_balance({"balance_infos": [{"currency": "USD", "total_balance": "0.00",
                                  "granted_balance": "0.00", "topped_up_balance": "0.00"}]})
summary["zeroBalance"] = scanner.fetch_deepseek_balance("/fake/omp")

# No stored key means no balance rather than a fabricated number.
scanner.subprocess.run = lambda *a, **k: FakeProc("")
scanner.urllib.request.urlopen = lambda *a, **k: FakeResponse(
    {"balance_infos": [{"currency": "USD", "total_balance": "1.00"}]})
summary["noKeyBalance"] = scanner.fetch_deepseek_balance("/fake/omp")

print(json.dumps(summary, separators=(",", ":")))
PY
)

[[ $(jq -r '.totalPrompts' <<<"$result") == "5" ]] ||
  fail "omp collector maps totalRequests to totalPrompts" "$result"
pass "omp collector maps totalRequests to totalPrompts"

[[ $(jq -r '.todayPrompts' <<<"$result") == "3" ]] ||
  fail "omp collector picks today's request count from the daily series" "$result"
pass "omp collector picks today's request count from the daily series"

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "120" ]] ||
  fail "omp collector totals today's tokens" "$result"
pass "omp collector totals today's tokens"

[[ $(jq -r '[.todaySessions, .totalSessions] | map(tostring) | join(":")' <<<"$result") == "2:2" ]] ||
  fail "omp collector counts sessions from ~/.omp/agent/sessions" "$result"
pass "omp collector counts sessions from ~/.omp/agent/sessions"

[[ $(jq -r '.activeDays' <<<"$result") == "2" ]] ||
  fail "omp collector counts active days" "$result"
pass "omp collector counts active days"

[[ $(jq -c '.modelUsage["deepseek-chat"]' <<<"$result") == '{"inputTokens":500,"outputTokens":100,"cacheReadInputTokens":50,"cacheCreationInputTokens":10}' ]] ||
  fail "omp collector maps per-model token buckets" "$result"
pass "omp collector maps per-model token buckets"

[[ $(jq -r '[.recentDaysLast, .recentDaysPrev] | map(tostring) | join(":")' <<<"$result") == "120:40" ]] ||
  fail "omp collector builds the seven-day token series" "$result"
pass "omp collector builds the seven-day token series"

[[ $(jq -r '[.runStatsOk, .runStatsNonZero, .runStatsBadJson, .runStatsMissing, .runStatsTimeout] | map(tostring) | join(":")' <<<"$result") == "true:true:true:true:true" ]] ||
  fail "omp collector degrades to no-stats on failure, missing binary, and timeout" "$result"
pass "omp collector degrades to no-stats on failure, missing binary, and timeout"

[[ $(jq -c '.balance' <<<"$result") == '{"remaining":110.0,"funded":0.0,"spent":0.0,"currency":"USD","estimated":false}' ]] ||
  fail "omp collector reports remaining-only balance, not a fabricated spend" "$result"
pass "omp collector reports remaining-only balance, not a fabricated spend"

[[ $(jq -c '.zeroBalance' <<<"$result") == '{"remaining":0.0,"funded":0.0,"spent":0.0,"currency":"USD","estimated":false}' ]] ||
  fail "omp collector keeps an exhausted zero balance" "$result"
pass "omp collector keeps an exhausted zero balance"

[[ $(jq -r '.noKeyBalance' <<<"$result") == "null" ]] ||
  fail "omp collector reports no balance without a stored key" "$result"
pass "omp collector reports no balance without a stored key"
