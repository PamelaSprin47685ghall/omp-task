#!/usr/bin/env bash
# omp-task installer — idempotent; safe to re-run (also used for upgrades).
#
#   ./install.sh                 install omp (pinned), bun, vibe deps, symlinks
#   ./install.sh --init-config   additionally write ~/.omp/agent/{models,config}.yml from the
#                                templates if they do not exist yet (never overwrites)
#   ./install.sh --no-vibe       skip bun + vibe dependencies (plain omp-task only)
#   ./install.sh --check         only report what is installed
#
# Env: OMP_VERSION (default 18.12.4; must match vibe/package.json for --vibe),
#      BIN_DIR (default ~/.local/bin), OMP_TASK_RUNS (default ~/.omp-task/runs)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OMP_VERSION="${OMP_VERSION:-18.12.4}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
RUNS="${OMP_TASK_RUNS:-$HOME/.omp-task/runs}"
MIN_BUN="1.3.14"
INIT_CONFIG=0 VIBE=1 CHECK=0
for a in "$@"; do
  case $a in
    --init-config) INIT_CONFIG=1 ;;
    --no-vibe) VIBE=0 ;;
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }
export PATH="$BIN_DIR:$HOME/.bun/bin:$PATH"

omp_ver() { omp --version 2>/dev/null | sed -n 's#^omp/##p' | head -1; }
bun_ver() { bun --version 2>/dev/null | head -1; }

if [ "$CHECK" = 1 ]; then
  echo "omp:      $(command -v omp || echo missing) $(omp_ver)"
  echo "bun:      $(command -v bun || echo missing) $(bun_ver)"
  echo "python3:  $(command -v python3 || echo missing)"
  echo "vibe deps: $([ -d "$ROOT/vibe/node_modules/@oh-my-pi/pi-coding-agent" ] && echo installed || echo missing)"
  echo "omp-task: $(readlink "$BIN_DIR/omp-task" 2>/dev/null || echo 'not linked')"
  echo "omp-vibe: $(readlink "$BIN_DIR/omp-vibe" 2>/dev/null || echo 'not linked')"
  echo "models.yml: $([ -f "$HOME/.omp/agent/models.yml" ] && echo present || echo missing)"
  echo "config.yml: $([ -f "$HOME/.omp/agent/config.yml" ] && echo present || echo missing)"
  exit 0
fi

need curl; need python3
mkdir -p "$BIN_DIR" "$RUNS"

# 1. omp binary (official installer, prebuilt SHA-verified binary, pinned release)
if [ "$(omp_ver)" = "$OMP_VERSION" ]; then
  say "omp $OMP_VERSION already installed ($(command -v omp))"
else
  say "installing omp v$OMP_VERSION via https://omp.sh/install (current: $(omp_ver || true))"
  curl -fsSL https://omp.sh/install | PI_INSTALL_DIR="$BIN_DIR" sh -s -- --binary --ref "v$OMP_VERSION"
fi

if [ "$VIBE" = 1 ]; then
  # 2. bun (needed to run omp from source for --vibe)
  if command -v bun >/dev/null 2>&1 && ver_ge "$(bun_ver)" "$MIN_BUN"; then
    say "bun $(bun_ver) ok"
  else
    say "installing bun via https://bun.sh/install"
    need unzip
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
    ver_ge "$(bun_ver)" "$MIN_BUN" || { echo "bun >= $MIN_BUN required, got $(bun_ver)" >&2; exit 1; }
  fi
  # 3. pinned omp source package for the vibe hook
  say "installing vibe dependencies (@oh-my-pi/pi-coding-agent, pinned by vibe/bun.lock)"
  (cd "$ROOT/vibe" && bun install --frozen-lockfile)
fi

# 4. symlinks
for b in omp-task omp-vibe; do
  ln -sfn "$ROOT/bin/$b" "$BIN_DIR/$b"
done
chmod +x "$ROOT/bin/omp-task" "$ROOT/bin/omp-vibe"
say "linked $BIN_DIR/omp-task and $BIN_DIR/omp-vibe -> $ROOT/bin/"

# 5. optional config templates
if [ "$INIT_CONFIG" = 1 ]; then
  mkdir -p "$HOME/.omp/agent"; chmod 700 "$HOME/.omp"
  for f in models config; do
    dst="$HOME/.omp/agent/$f.yml"
    if [ -e "$dst" ]; then
      say "keeping existing $dst"
    else
      sed "s#__HOME__#$HOME#g" "$ROOT/config/$f.example.yml" > "$dst"; chmod 600 "$dst"
      say "wrote $dst from the template — edit it (see README: Configure)"
    fi
  done
  tok="$HOME/.omp/gateway.token"
  [ -e "$tok" ] || { install -m 600 /dev/null "$tok"; say "created empty $tok (mode 600) — put your API key in it"; }
fi

case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "note: add $BIN_DIR to PATH" ;; esac
say "done. omp $(omp_ver); runs dir $RUNS. Next: configure ~/.omp/agent (see README), then tests/smoke.sh"
