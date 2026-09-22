#!/usr/bin/env bash
# selftest.sh - exercise the remote ocw verbs without a Codespace or OpenCode.
#
# Every check runs against a temporary state root, so this never touches real
# worker state and never launches a model. It verifies the parts that are easy
# to break silently: state derivation, exit codes, prune safety, and the
# argument validation that protects a worker from a bad start.
#
# Usage: tests/selftest.sh

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCW="$HERE/../remote/ocw"
[[ -f "$OCW" ]] || { printf 'ocw not found at %s\n' "$OCW" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export OCW_STATE_ROOT="$WORK/state"
mkdir -p "$OCW_STATE_ROOT"

pass=0
fail=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  FAIL %s (expected %q, got %q)\n' "$label" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

# Build a worker directory directly, so state handling is tested without a model.
make_worker() {
  local name="$1" pid="$2" exit_code="$3"
  local dir="$OCW_STATE_ROOT/$name"
  mkdir -p "$dir"
  printf '%s' "$(date +%s)" > "$dir/started"
  printf 'opencode-go/deepseek-v4.1-flash' > "$dir/model"
  printf 'high' > "$dir/variant"
  printf '/workspaces/worktrees/%s' "$name" > "$dir/workdir"
  printf '%s title' "$name" > "$dir/title"
  if [[ -n "$pid" ]]; then printf '%s' "$pid" > "$dir/pid"; fi
  if [[ -n "$exit_code" ]]; then printf '%s' "$exit_code" > "$dir/exit"; fi
}

echo 'version'
check 'prints version' 'ocw 1.0.0' "$(bash "$OCW" version)"

echo 'empty state'
check 'reports no workers' 'No workers.' "$(bash "$OCW" status)"

echo 'state derivation'
# $$ is this shell, so the worker reads as RUNNING.
make_worker live-lane "$$" ''
make_worker done-lane '' '0'
make_worker failed-lane '' '3'
check 'running worker detected' 'RUNNING' "$(bash "$OCW" status live-lane | awk '{print $2}')"
check 'done worker detected' 'DONE' "$(bash "$OCW" status done-lane | awk '{print $2}')"
check 'failed worker detected' 'FAILED' "$(bash "$OCW" status failed-lane | awk '{print $2}')"
check 'missing worker reported' 'MISSING' "$(bash "$OCW" status nope-lane | awk '{print $2}' || true)"
check 'exit code surfaced' 'exit=3' "$(bash "$OCW" status failed-lane | grep -o 'exit=3')"

echo 'wait exit codes'
check 'wait on done exits 0' '0' "$(bash "$OCW" wait done-lane 5 >/dev/null 2>&1; echo $?)"
check 'wait on failed exits 1' '1' "$(bash "$OCW" wait failed-lane 5 >/dev/null 2>&1; echo $?)"

echo 'start validation'
check 'rejects a model without a provider' '2' \
  "$(bash "$OCW" start bad-model novalidator high /tmp t "prompt" >/dev/null 2>&1; echo $?)"
check 'rejects an unsafe worker name' '2' \
  "$(bash "$OCW" start '../escape' opencode-go/x high /tmp t p >/dev/null 2>&1; echo $?)"
check 'rejects a non-worktree directory' '2' \
  "$(bash "$OCW" start ok-name opencode-go/x high /tmp t p >/dev/null 2>&1; echo $?)"

echo 'prune safety'
check 'prune keeps a running worker' 'live-lane skipped (running)' \
  "$(bash "$OCW" prune live-lane | head -n 1)"
check 'prune removes a finished worker' 'done-lane pruned' \
  "$(bash "$OCW" prune done-lane | head -n 1)"
check 'pruned state is gone' '0' "$([[ -d "$OCW_STATE_ROOT/done-lane" ]] && echo 1 || echo 0)"
check 'running state survives prune' '1' "$([[ -d "$OCW_STATE_ROOT/live-lane" ]] && echo 1 || echo 0)"

echo 'argument handling'
check 'unknown verb exits 2' '2' "$(bash "$OCW" bogus >/dev/null 2>&1; echo $?)"
check 'help exits 0' '0' "$(bash "$OCW" help >/dev/null 2>&1; echo $?)"

echo 'opencode bootstrap (offline paths only)'
check 'upgrade-only refuses a missing binary' '2' \
  "$(OPENCODE_BIN="$WORK/absent" bash "$OCW" bootstrap --upgrade-only >/dev/null 2>&1; echo $?)"

# A stand-in binary lets the install-only path be verified without the network.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
# Stand-in for OpenCode: reports a version and accepts a `run` invocation.
case "${1:-}" in
  --version) printf '9.9.9\n' ;;
esac
exit 0
FAKE
chmod +x "$WORK/bin/opencode"
check 'install-only leaves a present binary alone' '0' \
  "$(OPENCODE_BIN="$WORK/bin/opencode" bash "$OCW" bootstrap --install-only >/dev/null 2>&1; echo $?)"

echo 'start to finish without a model'
# A real worktree is required, so build a throwaway repository.
git init -q "$WORK/repo"
git -C "$WORK/repo" -c user.email=t@example.com -c user.name=t \
  commit -q --allow-empty -m init

check 'start launches a worker' '0' \
  "$(OPENCODE_BIN="$WORK/bin/opencode" bash "$OCW" start e2e-lane opencode-go/x high \
     "$WORK/repo" 'e2e lane' 'do the thing' >/dev/null 2>&1; echo $?)"
check 'literal prompt is stored' 'do the thing' \
  "$(cat "$OCW_STATE_ROOT/e2e-lane/prompt.md")"
check 'worker reaches DONE' 'DONE' \
  "$(bash "$OCW" wait e2e-lane 30 | awk '{print $2}')"
check 'wait exits 0 on success' '0' \
  "$(bash "$OCW" wait e2e-lane 30 >/dev/null 2>&1; echo $?)"

# A prompt file must win over the literal-text path.
printf 'from a file\n' > "$WORK/prompt.md"
check 'prompt file starts a worker' '0' \
  "$(OPENCODE_BIN="$WORK/bin/opencode" bash "$OCW" start file-lane opencode-go/x high \
     "$WORK/repo" 'file lane' "$WORK/prompt.md" >/dev/null 2>&1; echo $?)"
check 'prompt file is copied, not treated as text' 'from a file' \
  "$(cat "$OCW_STATE_ROOT/file-lane/prompt.md")"

echo 'restart is clean'
# A rerun rebuilds the worker directory, so a previous exit code, log, and
# prompt cannot leak into the new run.
check 'restart reuses the worker name' '0' \
  "$(OPENCODE_BIN="$WORK/bin/opencode" bash "$OCW" start e2e-lane opencode-go/x high \
     "$WORK/repo" 'e2e lane' 'second run' >/dev/null 2>&1; echo $?)"
check 'restart replaces the stored prompt' 'second run' \
  "$(cat "$OCW_STATE_ROOT/e2e-lane/prompt.md")"

echo 'opencode release channel'
check 'unknown bootstrap option exits 2' '2' \
  "$(bash "$OCW" bootstrap --nope >/dev/null 2>&1; echo $?)"
check '--channel without a name exits 2' '2' \
  "$(bash "$OCW" bootstrap --channel >/dev/null 2>&1; echo $?)"

# A channel installs into its own prefix. Staging a stand-in binary there proves
# resolution and the runner wiring without touching npm or the network.
mkdir -p "$WORK/ch/dev/bin"
cp "$WORK/bin/opencode" "$WORK/ch/dev/bin/opencode"
chmod +x "$WORK/ch/dev/bin/opencode"
check 'channel install-only is a no-op when present' '0' \
  "$(OCW_OPENCODE_CHANNEL_ROOT="$WORK/ch" bash "$OCW" bootstrap --channel dev --install-only >/dev/null 2>&1; echo $?)"
check 'channel binary starts a worker' '0' \
  "$(OCW_OPENCODE_CHANNEL_ROOT="$WORK/ch" OCW_OPENCODE_CHANNEL=dev bash "$OCW" start ch-lane \
     opencode-go/x high "$WORK/repo" 'channel lane' 'channel run' >/dev/null 2>&1; echo $?)"
check 'channel worker reaches DONE' 'DONE' \
  "$(bash "$OCW" wait ch-lane 30 | awk '{print $2}')"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
