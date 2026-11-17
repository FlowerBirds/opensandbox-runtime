#!/usr/bin/env bash
# Copyright 2026 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Unit tests for scripts/runtime-entrypoint.sh.
#
# The install script is stubbed via $INSTALL_PKGS_BIN and the command the
# entrypoint is supposed to exec is stubbed by a tiny "echo-args" script, so
# the test can assert on the ordering and the argument pass-through without
# a container.
#
# Run: bash tests/test_runtime_entrypoint.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/runtime-entrypoint.sh"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

call_log="$sandbox/calls.log"

cat >"$sandbox/install-pkgs.sh" <<'STUB'
#!/usr/bin/env bash
echo "install-pkgs $*" >>"$CALL_LOG"
exit "${INSTALL_STUB_EXIT:-0}"
STUB
chmod +x "$sandbox/install-pkgs.sh"

cat >"$sandbox/echo-args" <<'STUB'
#!/usr/bin/env bash
echo "exec-target $*" >>"$CALL_LOG"
STUB
chmod +x "$sandbox/echo-args"

fail() {
	echo "FAIL: $*" >&2
	if [ -f "$call_log" ]; then cat "$call_log" >&2; fi
	exit 1
}

run_entrypoint() {
	: >"$call_log"
	local rc=0
	CALL_LOG="$call_log" \
		INSTALL_PKGS_BIN="$sandbox/install-pkgs.sh" \
		INSTALL_STUB_EXIT="$install_exit" \
		RUNTIME_SKIP_INSTALL="$skip_install" \
		bash "$script" "$@" >"$sandbox/out.log" 2>"$sandbox/err.log" || rc=$?
	echo "$rc" >"$sandbox/last-exit"
}

last_exit() { cat "$sandbox/last-exit"; }

# The entrypoint must not pollute stdout either: the container's stdout is
# the data channel the sandbox server collects.
assert_stdout_clean() {
	[ ! -s "$sandbox/out.log" ] ||
		fail "expected empty stdout, got: $(cat "$sandbox/out.log")"
}

# Per-case knobs. They are plain variables (not `VAR=x func` prefixes) so the
# outcome does not depend on how the shell treats assignments before a
# function call.
install_exit=0
skip_install=""

# --- Case 1: the install runs, then the command is executed ------------
run_entrypoint "$sandbox/echo-args"
[ "$(last_exit)" = "0" ] || fail "expected exit 0, got $(last_exit)"
grep -q '^install-pkgs' "$call_log" || fail "expected the install script to be called"
grep -q '^exec-target' "$call_log" || fail "expected the command to be executed"
if grep -q 'skipping package installation' "$sandbox/err.log"; then
	fail "did not expect the skip message when installing"
fi
# The install script must not receive the container command as arguments:
# the two have different meanings.
grep -q '^install-pkgs *$' "$call_log" ||
	fail "expected the install script to be called without arguments"
assert_stdout_clean

# --- Case 2: a failing install must not block the container ------------
install_exit=1
run_entrypoint "$sandbox/echo-args"
[ "$(last_exit)" = "0" ] ||
	fail "expected exit 0 even when the install fails, got $(last_exit)"
grep -q '^exec-target' "$call_log" ||
	fail "expected the command to still run after a failed install"
grep -q 'WARN: package installation failed' "$sandbox/err.log" ||
	fail "expected a WARN line about the failed installation"
assert_stdout_clean

# --- Case 3: RUNTIME_SKIP_INSTALL skips the install --------------------
install_exit=0
skip_install="1"
run_entrypoint "$sandbox/echo-args"
[ "$(last_exit)" = "0" ] || fail "expected exit 0, got $(last_exit)"
if grep -q '^install-pkgs' "$call_log"; then
	fail "expected no install call when RUNTIME_SKIP_INSTALL is set"
fi
grep -q '^exec-target' "$call_log" ||
	fail "expected the command to still run when skipping the install"
assert_stdout_clean

# --- Case 4: arguments are passed through untouched -------------------
skip_install=""
run_entrypoint "$sandbox/echo-args" python -c "print(1)"
grep -q '^exec-target python -c print(1)$' "$call_log" ||
	fail "expected the arguments to be passed through verbatim"

# --- Case 5: every documented skip spelling is honoured ---------------
for value in 1 true yes on TRUE Yes ON; do
	skip_install="$value"
	run_entrypoint "$sandbox/echo-args"
	if grep -q '^install-pkgs' "$call_log"; then
		fail "expected no install call for RUNTIME_SKIP_INSTALL=$value"
	fi
	grep -q '^exec-target' "$call_log" ||
		fail "expected the command to still run for RUNTIME_SKIP_INSTALL=$value"
done
skip_install=""

# --- Case 6: no command at all -> install only, exit 0 -----------------
# The orchestrator may use this script as an "install only" hook (Cmd
# position, no command). It must not fail: the packages are installed and a
# non-zero exit would abort a caller running with `set -e`.
run_entrypoint
[ "$(last_exit)" = "0" ] || fail "expected exit 0 when no command is given, got $(last_exit)"
grep -q '^install-pkgs' "$call_log" ||
	fail "expected the install script to still run when no command is given"
grep -q 'no container command given' "$sandbox/err.log" ||
	fail "expected a log line about exiting after installation"
if grep -q '^exec-target' "$call_log"; then
	fail "expected no command to be executed when none was given"
fi
assert_stdout_clean

echo "OK: all runtime-entrypoint tests passed"
