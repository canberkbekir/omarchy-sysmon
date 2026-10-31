#!/bin/bash
# Integration test for wartafak.sysmon.
# Part A (static) always runs: stats.sh + processes.sh schemas and ranges,
# killproc.sh validation (incl. TERM/KILL on processes we own), Model.js loads.
# Part B (live) needs omarchy-shell running with the plugin enabled; it is
# skipped gracefully otherwise and leaves the panel closed (net-zero).
# Run with:  ./tests/integration.sh

set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ID="wartafak.sysmon"
# Bar-widget IpcHandler functions are NOT reachable via
# `omarchy-shell shell call` (that only routes to panel/overlay plugins,
# see shell.qml callIfLoaded) — use quickshell's native IPC instead.
SHELL_PATH="${OMARCHY_SHELL_PATH:-/usr/share/omarchy/shell}"
qshell() { quickshell --path "$SHELL_PATH" ipc call "$ID" "$1"; }
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# --- Part A: stats.sh (no shell needed) ---

RAW="$("$DIR/stats.sh" 2>/dev/null)"
[ $? -eq 0 ] && [ -n "$RAW" ] && ok "stats.sh exits 0 with output" || fail "stats.sh exits 0 with output"

echo "$RAW" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
  && ok "stats.sh prints valid JSON" || fail "stats.sh prints valid JSON"

check() { CHECK_EXPR="$1" python3 -c 'import json,sys,os; d=json.loads(sys.stdin.read()); assert eval(os.environ["CHECK_EXPR"])' <<< "$RAW" 2>/dev/null; }

check '"cpu" in d and "cpu_temp" in d and "gpu" in d and "gpu_temp" in d' \
  && ok "has cpu/gpu keys" || fail "has cpu/gpu keys"
check '"gpu_vendor" in d and "gpu_name" in d and "gpu_short" in d' \
  && ok "has gpu identity keys" || fail "has gpu identity keys"
check '"cpu_model" in d and "cpu_threads" in d and "cpu_max_ghz" in d' \
  && ok "has cpu identity keys" || fail "has cpu identity keys"
check '"mem" in d and "mem_used_kb" in d and "mem_total_kb" in d' \
  && ok "has mem keys" || fail "has mem keys"

check '(d["cpu"] is None) or (0 <= d["cpu"] <= 100)' \
  && ok "cpu in 0-100 or null" || fail "cpu in 0-100 or null"
check '(d["cpu_temp"] is None) or (0 <= d["cpu_temp"] <= 125)' \
  && ok "cpu_temp sane or null" || fail "cpu_temp sane or null"
check '(d["gpu"] is None) or (0 <= d["gpu"] <= 100)' \
  && ok "gpu in 0-100 or null" || fail "gpu in 0-100 or null"
check '(d["gpu_temp"] is None) or (0 <= d["gpu_temp"] <= 125)' \
  && ok "gpu_temp sane or null" || fail "gpu_temp sane or null"
check '(d["mem"] is None) or (0 <= d["mem"] <= 100)' \
  && ok "mem in 0-100 or null" || fail "mem in 0-100 or null"
check '(d["mem_used_kb"] is None or d["mem_total_kb"] is None) or (0 < d["mem_used_kb"] <= d["mem_total_kb"])' \
  && ok "mem_used <= mem_total" || fail "mem_used <= mem_total"
check 'd["gpu_vendor"] in ("none","nvidia","amd","intel")' \
  && ok "gpu_vendor known" || fail "gpu_vendor known"
check 'len(d["gpu_short"] or "") <= 60 and len(d["gpu_name"] or "") <= 80' \
  && ok "gpu names bounded" || fail "gpu names bounded"
check '(d["cpu_threads"] is None) or (d["cpu_threads"] > 0)' \
  && ok "cpu_threads positive or null" || fail "cpu_threads positive or null"
check '(d["cpu_max_ghz"] is None) or (0 < d["cpu_max_ghz"] < 10)' \
  && ok "cpu_max_ghz sane or null" || fail "cpu_max_ghz sane or null"

# Schema is stable across polls.
RAW2="$("$DIR/stats.sh" 2>/dev/null)"
KEYS1="$(echo "$RAW" | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')"
KEYS2="$(echo "$RAW2" | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')"
[ "$KEYS1" = "$KEYS2" ] && [ -n "$KEYS1" ] \
  && ok "stable schema across polls" || fail "stable schema across polls"

# Model.js parses the live payload (same code QML runs).
echo "$RAW" | node -e 'let t="";process.stdin.on("data",c=>t+=c).on("end",()=>{const M=require("'"$DIR"'/Model.js");const s=M.parseStats(t);if(typeof s.cpu==="undefined"||typeof s.mem==="undefined"){console.error("missing fields");process.exit(1)}})' 2>/dev/null \
  && ok "Model.js parses live stats.sh output" || fail "Model.js parses live stats.sh output"

# --- Part A2: processes.sh (no shell needed) ---

PRAW="$("$DIR/processes.sh" 2>/dev/null)"
[ $? -eq 0 ] && [ -n "$PRAW" ] && ok "processes.sh exits 0 with output" || fail "processes.sh exits 0 with output"

echo "$PRAW" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and len(d) > 0' 2>/dev/null \
  && ok "processes.sh prints a non-empty JSON array" || fail "processes.sh prints a non-empty JSON array"

pcheck() { CHECK_EXPR="$1" python3 -c 'import json,sys,os; d=json.load(sys.stdin); assert eval(os.environ["CHECK_EXPR"])' <<< "$PRAW" 2>/dev/null; }

pcheck 'all(set(p) == {"pid","comm","cpu","mem","rss_kb"} for p in d)' \
  && ok "process rows have pid/comm/cpu/mem/rss_kb" || fail "process rows have pid/comm/cpu/mem/rss_kb"
pcheck 'all(p["pid"] > 0 and p["comm"] != "" for p in d)' \
  && ok "pids positive, names non-empty" || fail "pids positive, names non-empty"
pcheck 'all((p["cpu"] is None or 0 <= p["cpu"] <= 1600) and (p["mem"] is None or 0 <= p["mem"] <= 100) for p in d)' \
  && ok "cpu/mem in range" || fail "cpu/mem in range"
pcheck 'all(p["rss_kb"] is None or p["rss_kb"] >= 0 for p in d)' \
  && ok "rss_kb non-negative" || fail "rss_kb non-negative"
pcheck 'all(d[i]["cpu"] is None or d[i+1]["cpu"] is None or d[i]["cpu"] >= d[i+1]["cpu"] for i in range(len(d)-1))' \
  && ok "sorted by cpu desc" || fail "sorted by cpu desc"

# Model.js parses the live process payload.
echo "$PRAW" | node -e 'let t="";process.stdin.on("data",c=>t+=c).on("end",()=>{const M=require("'"$DIR"'/Model.js");const l=M.parseProcesses(t);if(!Array.isArray(l)||l.length===0){console.error("empty");process.exit(1)}})' 2>/dev/null \
  && ok "Model.js parses live processes.sh output" || fail "Model.js parses live processes.sh output"

# --- Part A2b: storage.sh + scan.sh (no shell needed) ---

SRAW="$("$DIR/storage.sh" 2>/dev/null)"
[ $? -eq 0 ] && [ -n "$SRAW" ] && ok "storage.sh exits 0 with output" || fail "storage.sh exits 0 with output"

scheck() { CHECK_EXPR="$1" python3 -c 'import json,sys,os; d=json.load(sys.stdin); assert eval(os.environ["CHECK_EXPR"])' <<< "$SRAW" 2>/dev/null; }

scheck 'isinstance(d, list) and len(d) > 0' \
  && ok "storage.sh prints a non-empty JSON array" || fail "storage.sh prints a non-empty JSON array"
scheck 'all(set(v) == {"mount","fstype","encrypted","size","used","avail","pct","shared"} for v in d)' \
  && ok "volumes have the expected keys" || fail "volumes have the expected keys"
scheck 'all(v["used"] <= v["size"] and v["avail"] <= v["size"] and 0 <= v["pct"] <= 100 for v in d)' \
  && ok "volume sizes in range" || fail "volume sizes in range"
scheck 'len({v["mount"] for v in d}) == len(d)' \
  && ok "one entry per mount" || fail "one entry per mount"

SCRAW="$("$DIR/scan.sh" 2>/dev/null)"
[ $? -eq 0 ] && [ -n "$SCRAW" ] && ok "scan.sh exits 0 with output" || fail "scan.sh exits 0 with output"
echo "$SCRAW" | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d["folders"]; assert f and d["total"] == sum(x["bytes"] for x in f) and all(f[i]["bytes"] >= f[i+1]["bytes"] for i in range(len(f)-1))' 2>/dev/null \
  && ok "scan.sh folders sum to total, biggest first" || fail "scan.sh folders sum to total, biggest first"

# --- Part A3: killproc.sh validation (no shell needed) ---

"$DIR/killproc.sh" TERM abc >/dev/null 2>&1; [ $? -eq 2 ] \
  && ok "killproc rejects non-numeric pid" || fail "killproc rejects non-numeric pid"
"$DIR/killproc.sh" TERM 1 >/dev/null 2>&1; [ $? -eq 2 ] \
  && ok "killproc refuses pid 1" || fail "killproc refuses pid 1"
"$DIR/killproc.sh" HUP 123 >/dev/null 2>&1; [ $? -eq 2 ] \
  && ok "killproc rejects unknown signal" || fail "killproc rejects unknown signal"
"$DIR/killproc.sh" TERM '1;touch /tmp/pwned' >/dev/null 2>&1; [ $? -eq 2 ] && [ ! -e /tmp/pwned ] \
  && ok "killproc rejects injection" || fail "killproc rejects injection"

# End-to-end on processes we own: TERM then KILL, both net-zero.
sleep 120 & VICTIM=$!
"$DIR/killproc.sh" TERM "$VICTIM" >/dev/null 2>&1
sleep 0.5
if kill -0 "$VICTIM" 2>/dev/null; then fail "killproc TERM kills own process"; kill -KILL "$VICTIM" 2>/dev/null; else ok "killproc TERM kills own process"; fi
sleep 120 & VICTIM=$!
"$DIR/killproc.sh" KILL "$VICTIM" >/dev/null 2>&1
sleep 0.5
if kill -0 "$VICTIM" 2>/dev/null; then fail "killproc KILL kills own process"; kill -KILL "$VICTIM" 2>/dev/null; else ok "killproc KILL kills own process"; fi

# --- Part B: live shell (skipped when the shell is not running or stale) ---

# Non-JSON output (shell down, plugin disabled) means SKIP, not FAIL.
if ! qshell debugState 2>/dev/null | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
  echo "SKIP: live shell checks need omarchy-shell running with $ID enabled"
  echo "--- $PASS passed, $FAIL failed ---"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

state() { qshell debugState; }
field() { python3 -c 'import json,sys; v=json.load(sys.stdin)["'"$1"'"]; print("True" if v is True else "False" if v is False else v if v is not None else "null")'; }

S="$(state)"
echo "$S" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
  && ok "debugState returns JSON" || fail "debugState returns JSON"

echo "$S" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert all(k in d for k in ("opened","cpu","gpu","mem","sampleCount","cpuHistLen","hasGpu","processCount"))' 2>/dev/null \
  && ok "debugState has expected fields" || fail "debugState has expected fields"

# hasGpu agrees with the vendor string.
VENDOR="$(echo "$S" | field gpuVendor)"
HASGPU="$(echo "$S" | field hasGpu)"
if { [ "$VENDOR" = "none" ] && [ "$HASGPU" = "False" ]; } || { [ "$VENDOR" != "none" ] && [ "$HASGPU" = "True" ]; }; then
  ok "hasGpu agrees with vendor ($VENDOR)"
else
  fail "hasGpu agrees with vendor (vendor=$VENDOR hasGpu=$HASGPU)"
fi

echo "$S" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert 0 <= d["sampleCount"] <= 300 and 0 <= d["cpuHistLen"] <= 300' 2>/dev/null \
  && ok "histories bounded (<=300)" || fail "histories bounded (<=300)"

# refresh is callable and a second poll keeps the schema.
qshell refresh >/dev/null 2>&1 \
  && ok "refresh callable" || fail "refresh callable"
sleep 3
S2="$(state)"
K1="$(echo "$S" | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')"
K2="$(echo "$S2" | python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.stdin.read()).keys())))')"
[ "$K1" = "$K2" ] && ok "debugState schema stable" || fail "debugState schema stable"

# Panel open/close round-trip, left closed (net-zero).
qshell open >/dev/null 2>&1
sleep 1
[ "$(state | field opened)" = "True" ] && ok "open shows panel" || fail "open shows panel"
# Processes are sampled only while open; allow one 2s poll to land.
sleep 4
[ "$(state | field processCount)" != "0" ] && [ "$(state | field processCount)" != "null" ] \
  && ok "process list populates while open ($(state | field processCount) rows)" || fail "process list populates while open"
qshell close >/dev/null 2>&1
sleep 1
[ "$(state | field opened)" = "False" ] && ok "close hides panel" || fail "close hides panel"

# toggle flips both ways, ends closed.
qshell toggle >/dev/null 2>&1
sleep 1
[ "$(state | field opened)" = "True" ] && ok "toggle opens" || fail "toggle opens"
qshell toggle >/dev/null 2>&1
sleep 1
[ "$(state | field opened)" = "False" ] && ok "toggle closes" || fail "toggle closes"

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
