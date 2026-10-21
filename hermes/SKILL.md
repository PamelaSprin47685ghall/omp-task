---
name: omp-vibe-subagents
description: "MANDATORY for any subagent, background worker or parallel task: run it with `omp-task start --vibe` (omp vibe director + workers on the lazy models), never with built-in delegation. Covers start, notify-on-finish, wait, status, steer, followup, stop, resume and the exit codes."
version: 1.0.0
author: omp-task
license: MIT
metadata:
  hermes:
    tags: [subagents, delegation, background, parallel, omp, vibe]
prerequisites:
  commands: [omp-task, omp, omp-vibe]
---

# Subagents = omp vibe (omp-task)

**Rule:** do not use built-in subagents. `delegate_task` is disabled on purpose. When a task would benefit from a subagent, a background worker or parallel work, use `omp-task start --vibe` instead. Use plain `omp-task start` (no `--vibe`) only for a small, single-agent job.

A vibe run is a headless omp *director* that spawns its own worker sessions on the lazy models. You stay in control from the terminal tool.

## Pattern (terminal tool)

1. **Write the brief to a file** (file tool), e.g. `/tmp/briefs/<name>.md`. Make it self-contained: goal, exact paths, constraints and acceptance checks (commands that must pass). The run cannot see your conversation.
2. **Start** (foreground; returns in about 1-5 s):
   `terminal(command="omp-task start <name> <workdir> --vibe @/tmp/briefs/<name>.md")`
   - `<name>` must be unique (`[a-z0-9-]`); reusing a name fails.
   - `<workdir>` is created if missing.
3. **Get notified when it ends.** Don't poll in a loop:
   `terminal(command="omp-task wait <name>", background=true, notify=true)`
   The completion notification carries the summary and final answer. `process(action="log", session_id=...)` shows the full text, and its exit code is the outcome. To block instead, use `process(action="wait", session_id=..., timeout=600)`.
4. **While it runs** (all foreground, cheap):
   - `omp-task status <name> -n 10`: status, current step, workers and recent actions.
   - `omp-task steer <name> "<correction>"`: redirect the director now. It relays to workers.
   - `omp-task steer <name> --agent <worker-id> "<msg>"`: talk to one worker directly (ids come from `status`).
   - `omp-task followup <name> "<more work>"`: queued after the current turn.
   - `omp-task stop <name>`: abort the run and its workers.
5. **After it ends:**
   - Read the `wait` output, or `cat ~/.omp-task/runs/<name>/final.md`.
   - **Verify the result yourself** (run the tests, read the files) before reporting.
   - `omp-task transcript <name>` shows everything it did.
6. **Continue the same run:** `omp-task resume <name> "<next instruction>"`, then wait again. It keeps the same session and vibe mode.
7. **Parallel work:** start several runs with different names and workdirs, with one background `wait` each.

## Exit codes of `wait` / `--wait`

`0` done · `1` error · `2` stopped · `3` timeout (only with `--timeout`; the run keeps going) · `4` no such run.

On `1`, check `omp-task status <name>`, `~/.omp-task/runs/<name>/omp.stderr` and the transcript. Then `resume` with a fix, or start a new run.

## Example

```
file: /tmp/briefs/fizz.md
  Create /srv/demo/fizz.py (FizzBuzz 1..30, one value per line) and test_fizz.py (pytest).
  Use a fast worker for the code and a good worker for the tests.
  Done when `python3 -m pytest -q /srv/demo` passes. Reply with the pytest summary.
terminal: omp-task start fizz /srv/demo --vibe @/tmp/briefs/fizz.md
terminal(background=true, notify=true): omp-task wait fizz
... notification: "run fizz status=done ... 2 passed" -> verify: python3 -m pytest -q /srv/demo
```

## Notes

- Runs execute commands without approval prompts (yolo) inside `<workdir>`. Point them only at what they may change.
- Workers run on the `smol`/`task` role models and the director on `default` (`~/.omp/agent/config.yml`).
- Run directory: `~/.omp-task/runs/<name>/`. It holds `state.json`, `actions.log`, `final.md` and `sessions/`.
