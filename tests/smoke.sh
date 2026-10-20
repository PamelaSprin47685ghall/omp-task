#!/usr/bin/env bash
# End-to-end smoke test against your configured gateway (uses real model calls).
#   tests/smoke.sh            plain run + steer + resume + stop
#   tests/smoke.sh --vibe     additionally a vibe-director run with a worker
# Uses a throwaway runs dir and workdirs under a temp dir; prints PASS/FAIL per check.
set -uo pipefail
VIBE=0; [ "${1:-}" = "--vibe" ] && VIBE=1
T=$(mktemp -d "${TMPDIR:-/tmp}/omp-task-smoke.XXXXXX")
export OMP_TASK_RUNS="$T/runs"
OT=${OMP_TASK:-omp-task}
fails=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }

echo "smoke dir: $T"
check "omp on PATH"   'omp --version >/dev/null'
check "models config" '[ -f "$HOME/.omp/agent/models.yml" ]'

# 1. plain run
$OT start s-plain "$T/w1" "Create file answer.txt containing exactly the word PONG (no newline needed). Then reply DONE." >/dev/null
$OT wait s-plain --timeout 300 >/dev/null; rc=$?
check "plain run done (wait exit 0)" '[ $rc = 0 ]'
check "plain run wrote answer.txt"   'grep -q PONG "$T/w1/answer.txt"'

# 2. steer changes the outcome
$OT start s-steer "$T/w2" "Run the shell command 'sleep 20' first. After it finishes, write fruit.txt containing APPLE. Reply DONE." >/dev/null
for _ in $(seq 1 60); do $OT status s-steer -n 1 | grep -q "sleep" && break; sleep 1; done
$OT steer s-steer "Change of plan: write BANANA instead of APPLE into fruit.txt." >/dev/null
$OT wait s-steer --timeout 300 >/dev/null; rc=$?
check "steered run done"         '[ $rc = 0 ]'
check "steer changed the outcome" 'grep -q BANANA "$T/w2/fruit.txt"'

# 3. resume continues the same session
$OT resume s-plain "Append a second line DONE2 to answer.txt. Reply DONE." --wait >/dev/null; rc=$?
check "resume round 2 done" '[ $rc = 0 ] && grep -q DONE2 "$T/w1/answer.txt"'
check "single session file" '[ $(ls "$OMP_TASK_RUNS/s-plain/sessions"/*.jsonl | wc -l) = 1 ]'

# 4. stop mid-flight
$OT start s-stop "$T/w3" "Run the shell command 'sleep 120', then reply DONE." >/dev/null
for _ in $(seq 1 60); do $OT status s-stop -n 1 | grep -q "sleep" && break; sleep 1; done
$OT stop s-stop >/dev/null
check "stop -> status stopped" '$OT wait s-stop --timeout 30 >/dev/null; [ $? = 2 ]'

check "list shows runs" '[ $($OT list | grep -c "^s-") -ge 3 ]'

if [ "$VIBE" = 1 ]; then
  check "omp-vibe runs" 'omp-vibe --version >/dev/null'
  $OT start s-vibe "$T/w4" --vibe "Spawn one fast worker to create hello.txt containing HELLO-VIBE. Wait for it, verify with read, then kill the worker and reply DONE." >/dev/null
  $OT wait s-vibe --timeout 400 >/dev/null; rc=$?
  check "vibe run done"            '[ $rc = 0 ]'
  check "vibe worker wrote file"   'grep -q HELLO-VIBE "$T/w4/hello.txt"'
  check "vibe mode enabled"        'grep -q "vibe mode enabled" "$OMP_TASK_RUNS/s-vibe/omp.stderr"'
  check "director used vibe_spawn" 'grep -q "vibe_spawn" "$OMP_TASK_RUNS/s-vibe/actions.log"'
fi

echo; echo "models used (provider/model: assistant turns), from session files:"
python3 - "$OMP_TASK_RUNS" <<'PY'
import json, sys, glob, collections
c = collections.Counter()
for f in glob.glob(sys.argv[1] + "/*/sessions/**/*.jsonl", recursive=True):
    for l in open(f):
        try: m = json.loads(l).get("message") or {}
        except ValueError: continue
        if m.get("role") == "assistant": c[f'{f.split("/runs/")[1].split("/")[0]}  {m.get("provider")}/{m.get("model")}'] += 1
for k, v in sorted(c.items()): print(f"  {k}: {v}")
PY
echo; [ $fails = 0 ] && echo "ALL PASS (artifacts in $T)" || echo "$fails FAILED (artifacts in $T)"
exit $fails
