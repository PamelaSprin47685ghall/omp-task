# omp-task

**For hermes agents: read the next section first.** omp-task runs [Oh My Pi (`omp`)](https://omp.sh) sessions as headless, steerable background workers. With `--vibe`, an omp *director* spawns and manages its own worker sessions. Hermes uses this **instead of its built-in subagents**.

## For hermes agents (read first)

**Rule: never use built-in subagents.**
- `delegate_task` is disabled (`agent.disabled_toolsets: [delegation]`).
- Anything that needs a subagent, a background worker or parallel work runs as `omp-task start --vibe`.
- Plain `omp-task start` (no `--vibe`) is only for a small single-agent job.

The full playbook ships as a hermes skill: [`hermes/SKILL.md`](hermes/SKILL.md) (`omp-vibe-subagents`). The short version, with the hermes terminal tool:

| step | hermes call |
|---|---|
| 1. brief | write a self-contained prompt file (goal, paths, constraints, acceptance commands), e.g. `/tmp/briefs/<name>.md` |
| 2. start | `terminal(command="omp-task start <name> <workdir> --vibe @/tmp/briefs/<name>.md")`; returns in seconds |
| 3. notify on finish | `terminal(command="omp-task wait <name>", background=true, notify=true)`: one notification when the run ends; read it with `process(action="log", session_id=…)`; exit code = outcome |
| 3b. or block | `process(action="wait", session_id=…, timeout=600)` |
| status | `omp-task status <name> -n 10` (step, workers, recent actions) |
| steer | `omp-task steer <name> "<correction>"`; one worker: `--agent <worker-id>` |
| more work | `omp-task followup <name> "<msg>"` (queued after the current turn) |
| abort | `omp-task stop <name>` |
| continue | `omp-task resume <name> "<next instruction>"`, then wait again (same session, still vibe) |
| result | wait output or `~/.omp-task/runs/<name>/final.md`; **verify yourself** (run the tests); `omp-task transcript <name>` |

**Exit codes of `wait`:** `0` done · `1` error · `2` stopped · `3` timeout (run continues) · `4` no such run. Don't poll in a loop; the background `wait` with `notify=true` is the completion signal. For parallel work, use one run plus one background `wait` per task, each with a unique name and its own workdir.

### Setting up hermes for this

Per profile (`-p <profile>`, or omit it for the default):

```sh
hermes -p <profile> config set agent.disabled_toolsets "[delegation]"      # remove delegate_task
hermes -p <profile> skills install https://raw.githubusercontent.com/PamelaSprin47685ghall/omp-task/main/hermes/SKILL.md \
  --category autonomous-ai-agents --yes                                     # the playbook as a skill
cat >> ~/.hermes/profiles/<profile>/SOUL.md <<'RULE'

## Subagents
Never use built-in subagents/delegation. Anything that needs a subagent, background worker or parallel task
must run through omp vibe: `omp-task start <name> <workdir> --vibe @brief.md`, then a background
`omp-task wait <name>` with notify=true. Follow the `omp-vibe-subagents` skill.
RULE
systemctl restart hermes-gateway-<profile>   # or: hermes -p <profile> gateway restart
```

The gateway's systemd PATH must find `omp-task`, `omp`, `omp-vibe` and `bun`. Either symlink them into `/usr/local/bin` or add `~/.local/bin` to the unit's `Environment=PATH`. Check by asking the agent to run `omp-task list`.

## Why

`omp` already has a robust headless JSONL protocol (`omp --mode rpc --no-ui`) with `prompt`, `steer`, `follow_up`, `abort`, `get_state`, subagent control, and resumable session files. What it doesn't ship is a way to run that **detached** and talk to it **from other processes** later. `omp-task` is that thin layer:

- one small supervisor process per run owns omp's RPC stdin/stdout and exposes a Unix control socket;
- each run is a directory on disk with state, an action log, raw events, final answers and the omp session;
- all agent behavior, models, tools and sessions are native omp.

`--vibe` turns the top-level agent into a **director** whose only tools are `read`, `todo` and `vibe_spawn / vibe_send / vibe_wait / vibe_kill / vibe_list`; persistent worker sessions (fast tier = `smol` role, good tier = `task` role) do the actual work. This is omp's own vibe runtime, activated on an RPC session (see [How the vibe hook works](#how-the-vibe-hook-works)).

## Prerequisites

- Linux x86_64/arm64 (tested on Linux x86_64; macOS should work but is untested), `bash`, `curl`, `git`, `python3` (≥ 3.8, standard library only), `unzip` (only if bun has to be installed)
- An **OpenAI-compatible** chat-completions endpoint and API key (any gateway / router / provider: LiteLLM, vLLM, OpenRouter, a self-hosted proxy, …). omp's built-in providers (Anthropic, OpenAI, …) work too; the templates just show the generic case.
- Installed by `install.sh` if missing: `omp` (pinned release binary), `bun` ≥ 1.3.14 (only for `--vibe`).

## Install (one command)

```sh
git clone https://github.com/PamelaSprin47685ghall/omp-task.git ~/.local/share/omp-task \
  && ~/.local/share/omp-task/install.sh --init-config
```

`install.sh` is idempotent (re-run it any time; it's also the upgrade path). It:

1. installs the `omp` **v18.12.4** prebuilt binary via the official installer (`curl -fsSL https://omp.sh/install | sh -s -- --binary --ref v18.12.4`) into `~/.local/bin`, unless that version is already there;
2. installs `bun` via `https://bun.sh/install` if missing or older than 1.3.14;
3. runs `bun install --frozen-lockfile` in `vibe/` (the pinned `@oh-my-pi/pi-coding-agent@18.12.4` source package, ~1 GB with its native prebuilds);
4. symlinks `omp-task` and `omp-vibe` into `~/.local/bin`;
5. with `--init-config`: writes `~/.omp/agent/models.yml` and `config.yml` from `config/*.example.yml` **only if they don't exist**, and creates an empty `~/.omp/gateway.token` (mode 600).

Options: `--no-vibe` (skip bun/vibe deps), `--check` (show what's installed). Env: `OMP_VERSION`, `BIN_DIR`, `OMP_TASK_RUNS`.

Make sure `~/.local/bin` is on `PATH`.

## Configure

omp reads `~/.omp/agent/models.yml` (providers/models) and `~/.omp/agent/config.yml` (model roles, settings).

1. **API key** → a file only you can read, never in config or on the command line:
   ```sh
   install -m 600 /dev/null ~/.omp/gateway.token
   $EDITOR ~/.omp/gateway.token            # paste the key (one line)
   ```
2. **Gateway** → edit `~/.omp/agent/models.yml` ([template](config/models.example.yml)): set `baseUrl` and the model `id`s your endpoint serves. The key is resolved with `apiKey: "!cat /home/you/.omp/gateway.token"` (omp runs the command and uses its stdout; use an absolute path).
3. **Roles** → `~/.omp/agent/config.yml` ([template](config/config.example.yml)) maps omp roles to `provider/model`:

   | role | used for | template |
   |---|---|---|
   | `default`, `slow`, `plan` | main agent, vibe director | `gateway/strong-model` |
   | `task` | task subagents, vibe **good** workers | `gateway/fast-model` |
   | `smol`, `tiny` | vibe **fast** workers, light helpers | `gateway/fast-model` |
   | `vision` | image understanding | `gateway/vision-model` |

   `setupVersion: 2` skips omp's interactive first-run wizard; `tools.approvalMode: yolo` is needed because headless runs can't answer approval prompts.
4. If your gateway hostname needs a static mapping, add it to `/etc/hosts`.

Check: `omp -p "Reply with exactly: PONG" </dev/null` → `PONG` (without a TTY, `omp -p` otherwise waits for piped stdin). Then run the smoke test:

```sh
~/.local/share/omp-task/tests/smoke.sh          # plain: run, steer, resume, stop, list
~/.local/share/omp-task/tests/smoke.sh --vibe   # + a vibe director/worker run
```

It uses a temp runs dir, makes real model calls (a few minutes), prints PASS/FAIL per check and which `provider/model` each run used.

## Usage

```
omp-task start <name> <workdir> <prompt> [--vibe] [--model M] [--max-time 30m] [--wait] [-- omp args...]
omp-task wait <name> [--timeout SEC]          block until finished; print summary + final answer
omp-task steer <name> <message> [--agent ID]  inject into the running turn (--agent: one subagent / vibe worker)
omp-task followup <name> <message>            queue a message for after the current turn
omp-task status <name> [-n N] [--json]        status, current step, workers, todos, last N actions
omp-task transcript <name> [--full|--raw]     conversation from the omp session file
omp-task stop <name>                          abort and shut omp down (status: stopped)
omp-task resume <name> <prompt> [--wait]      new round in the same session (after done/error/stopped)
omp-task list [--json]                        all runs
```

- `<prompt>` / `<message>` may be `@file` (read from file) or `-` (stdin).
- `<workdir>` is created if missing; omp runs with it as cwd.
- Extra omp flags go after `--`, e.g. `-- --thinking=high`.

Examples:

```sh
omp-task start wordstats ~/scratch/ws "Write wordstats.py (CLI: top-N words of a file) with pytest tests; run them."
omp-task start refactor ~/src/app --vibe @task.md      # director + workers
omp-task status refactor -n 10
omp-task steer refactor "Use the existing logger, not print()"
omp-task steer refactor --agent api-worker "Skip the v1 endpoints"
omp-task transcript wordstats | less
omp-task resume wordstats "Also add a --json output flag" --wait
```

## Agent playbook (other agents)

For AI agents other than hermes (hermes: see the first section) that have a shell tool that can run commands in the background and be notified when they exit.

1. **Start** — returns immediately:
   `omp-task start <name> <workdir> "<self-contained task, with acceptance criteria>"`
   Use a unique, descriptive `<name>`. Put long prompts in a file and pass `@file`.
2. **Get notified** — run `omp-task wait <name>` as a **background shell job** (don't poll). When it exits, the job's output is the summary and final answer, and its exit code is the outcome. Use `--timeout SEC` if you want a deadline (exit 3 = still running, the run keeps going).
3. **While it runs**:
   - `omp-task status <name> -n 10` — current step and tool, workers, todos, recent actions. Cheap; doesn't disturb the run.
   - `omp-task steer <name> "<correction>"` — delivered into the current turn (after the running tool call). Use it to change direction.
   - `omp-task followup <name> "<more work>"` — queued; runs after the current turn, within the same round.
   - `omp-task stop <name>` — abort now; status becomes `stopped`, `wait` exits 2.
4. **After it ends** — read the `wait` output or `final.md`; verify the work yourself (files in `<workdir>`). `omp-task transcript <name>` shows everything it did.
5. **Continue** — `omp-task resume <name> "<next instruction>"`, then `wait` again (same session and context; the round number increments).
6. **Parallelism** — several runs can go at once (each is its own omp process). Give them separate workdirs unless they're meant to collaborate.
7. **Vibe** — for larger jobs use `start --vibe`: tell the director what to delegate ("spawn a fast worker to…", "use a good worker for…"). `status` lists workers; `steer` talks to the director (which relays with `vibe_send`); `steer --agent <worker-id>` talks to a worker directly. The mode persists across `resume`.

**`wait` / `start --wait` / `resume --wait` exit codes:** `0` done · `1` error · `2` stopped · `3` timeout (still running) · `4` no such run.

**Status values:** `starting` → `running` → `done` | `error` | `stopped`.

## Run directory

`$OMP_TASK_RUNS/<name>/` (default `~/.omp-task/runs/<name>/`):

| file | contents |
|---|---|
| `meta.json` | name, workdir, created, omp version, options (`vibe`, model, …) |
| `state.json` | status, round, step, current action, session file, pids, exit code |
| `prompts.jsonl` | every prompt / steer / follow-up with timestamps |
| `actions.log` | human-readable log: tool calls and results, messages, steers, workers (UTC) |
| `events.jsonl` | raw omp RPC frames (streaming deltas omitted) |
| `final.md`, `rounds/<k>.md` | last assistant answer (latest round / round k) |
| `stats.json` | omp session stats (tokens, cost) per round |
| `omp.stderr`, `supervisor.log` | diagnostics |
| `sessions/` | the omp session (`--session-dir`); worker/subagent transcripts in a subfolder |
| `ctl.sock` | control socket, only while running |

The session file is a normal omp session: `omp --session-dir <run>/sessions --continue` opens it in the TUI too.

## Environment

| variable | default | |
|---|---|---|
| `OMP_TASK_RUNS` | `~/.omp-task/runs` | runs directory (`OMP_TASK_HOME` accepted as alias) |
| `OMP_BIN` | `omp` on `PATH`, else `~/.local/bin/omp` | omp binary for plain runs |
| `OMP_VIBE_BIN` | `omp-vibe` next to `omp-task` | launcher for `--vibe` runs |
| `OMP_VIBE` | `1` | `0` makes `omp-vibe` run plain omp from source |

## How it works

`omp-task start` writes the run dir, then forks a detached supervisor (`omp-task _supervise <dir>`, own session/process group). The supervisor:

1. spawns `omp --mode rpc --no-ui --cwd <workdir> --session-dir <run>/sessions --approval-mode yolo [--continue]`;
2. negotiates RPC protocol v2, subscribes to subagent progress, enables delta-only message updates;
3. sends the prompt, logs every frame, and serves `ctl.sock` (`steer`, `follow_up`, `abort`, `get_state`, `get_subagents`, `steer_subagent`);
4. treats the round as done when omp reports `prompt_result` + `session_settled` and `get_state` confirms it's idle with an empty queue; then it writes `final.md`/`stats.json`, closes omp's stdin (omp exits 0) and records the status.

| capability | native omp mechanism | omp-task |
|---|---|---|
| background run | `omp --mode rpc --no-ui` + `prompt` | `start` |
| completion notice | `prompt_result`, `session_settled` frames | `wait` (exit code) |
| steer | RPC `steer` / `steer_subagent` | `steer [--agent]` |
| follow-up | RPC `follow_up` | `followup` |
| status | RPC `get_state`, `get_subagents` | `status` |
| stop | RPC `abort` + close stdin | `stop` |
| resume | `--session-dir … --continue` | `resume` |
| transcript | session `.jsonl` | `transcript` |
| list / multiple runs | — | `list`, one supervisor per run |

### How the vibe hook works

References are to omp **v18.12.4** (`packages/coding-agent/src/` in the omp repo):

- `/vibe` is a TUI-only slash command: `slash-commands/builtin-modes.ts:359–376` defines only `handleTui`, so it isn't available in RPC, and sending `"/vibe"` as a prompt just goes to the model as text.
- The TUI implementation is `modes/interactive-mode.ts` `#enterVibeMode` (~6287–6345):
  1. registers the session with `VibeSessionRegistry.global().ownerScope(parent)` + `activateScope`;
  2. records `previousTools = session.getEnabledToolNames()`;
  3. calls `session.activateVibeTools(["read", "todo"])`, which swaps to `read`, `todo`, `vibe_spawn/send/wait/kill/list` (`session/session-tools.ts:785`);
  4. calls `session.setVibeModeState({ enabled: true })`, which injects the director prompt `prompts/system/vibe-mode-active.md`;
  5. persists `sessionManager.appendModeChange("vibe", { previousTools })`.

  On resume, `#reconcileModeFromSession` (~5040) calls `VibeSessionRegistry.rehydrate()` (~5073) and re-enters vibe without a new mode change (~5107).
- The vibe *tools* aren't TUI-specific: `sdk.ts:4792` creates them for every top-level session, including RPC ones. Only the activation is missing.
- **Hook:** `main.ts` exports `runRootCommand(parsed, rawArgs, deps)`; `deps.createAgentSession` (`main.ts:1755–1763`, used for the root session at `:2323`) is a dependency-injection seam. [`vibe/omp-vibe-rpc.ts`](vibe/omp-vibe-rpc.ts) parses the normal omp CLI args, calls `runRootCommand` with a `createAgentSession` that wraps the real one and applies the same five steps to the root session (or `rehydrate()` when the session's persisted mode is already `vibe`), then lets omp continue into its unmodified `runRpcMode`. `bin/omp-vibe` runs it with bun; it accepts every omp flag.

Verified behavior: `get_state` reports tools `read, todo, vibe_spawn, vibe_send, vibe_wait, vibe_kill, vibe_list`; the director (default role) uses only those; workers run on the `smol`/`task` role models with normal coding tools; `steer`, `steer --agent`, `status`, `stop`, `resume` (`omp.stderr`: `vibe mode restored`) and concurrent vibe runs all work.

## Limitations

- **Pinned omp version.** The vibe hook imports omp internals (`main.runRootCommand` deps, `vibe/runtime`), which aren't a stable public API. `vibe/` pins `@oh-my-pi/pi-coding-agent@18.12.4` with a lockfile, and `install.sh` pins the binary to the same version.
- **`--vibe` runs omp from source under bun**, not the compiled binary: ~1 GB of `node_modules`, somewhat slower startup. Plain runs use the binary.
- **Yolo approvals.** Runs execute shell commands, file edits and package installs without asking. Use a sandbox/VM or a dedicated user, and give each run a workdir it may modify.
- **In-process vibe workers.** Embedded this way, omp's worker host runs workers inline in the director's process: memory adds up per run, and `stop` ends the workers together with the director (no orphaned processes, but no detached survivors either).
- **No daemon.** Each run is an independent supervisor plus omp. After a reboot, running runs are lost; finished runs can still be resumed. Steering is delivered after the currently executing tool call finishes (a long `sleep` is interruptible via `stop`, not via `steer`).
- Unix only (Unix sockets, `setsid`).

## Upgrading omp

1. Check the new omp version still has the seam: `main.ts` `runRootCommand(…, deps)` with `deps.createAgentSession`, and `AgentSession.activateVibeTools` / `setVibeModeState` / `VibeSessionRegistry` with the same shapes as `#enterVibeMode` in `modes/interactive-mode.ts`. If omp adds native RPC vibe support, prefer that and drop the hook.
2. Bump the version in `vibe/package.json`, run `cd vibe && bun install` to refresh `bun.lock`, and update `OMP_VERSION` in `install.sh`.
3. Re-run `./install.sh` and `tests/smoke.sh --vibe`.

Plain (non-vibe) `omp-task` only depends on omp's documented RPC protocol, so it's much less version-sensitive (`OMP_VERSION=x.y.z ./install.sh --no-vibe`).

## License

MIT, see [LICENSE](LICENSE).
