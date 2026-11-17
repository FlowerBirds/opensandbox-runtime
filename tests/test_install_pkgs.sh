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

# Unit tests for scripts/install-pkgs.sh.
#
# A stub `pip` is placed first on PATH. It records every invocation so the
# tests can assert on the exact pip arguments, and fails for wheels whose
# name contains "broken" to exercise the per-wheel error path.
#
# Run: bash tests/test_install_pkgs.sh

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/install-pkgs.sh"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

call_log="$sandbox/pip-calls.log"

cat >"$sandbox/pip" <<'STUB'
#!/usr/bin/env bash
echo "pip $*" >>"$CALL_LOG"
for arg in "$@"; do
	case "$arg" in
	*broken*) exit 1 ;;
	esac
done
exit 0
STUB
chmod +x "$sandbox/pip"

fail() {
	echo "FAIL: $*" >&2
	if [ -f "$call_log" ]; then cat "$call_log" >&2; fi
	exit 1
}

# EXTRA_ENV holds an optional "NAME=value" pair exported to the script under
# test; it is empty for the cases that do not need it.
EXTRA_ENV=""

run_install() {
	: >"$call_log"
	local rc=0
	(
		export CALL_LOG="$call_log"
		export PATH="$sandbox:$PATH"
		if [ -n "$EXTRA_ENV" ]; then export "${EXTRA_ENV:?}"; fi
		bash "$script" "$@"
	) >"$sandbox/out.log" 2>"$sandbox/err.log" || rc=$?
	echo "$rc" >"$sandbox/last-exit"
}

last_exit() { cat "$sandbox/last-exit"; }

pip_call_count() { grep -c '^pip install' "$call_log" 2>/dev/null || true; }

# The install logs must never reach stdout: the container's stdout is the
# data channel the sandbox server collects, so it has to stay clean.
assert_stdout_clean() {
	[ ! -s "$sandbox/out.log" ] ||
		fail "expected empty stdout, got: $(cat "$sandbox/out.log")"
}

# --- Case 1: the package directory does not exist -----------------------
run_install "$sandbox/missing"
[ "$(last_exit)" = "0" ] || fail "expected exit 0 for a missing directory, got $(last_exit)"
[ "$(pip_call_count)" = "0" ] || fail "expected no pip call for a missing directory"
grep -q 'no package directory' "$sandbox/err.log" ||
	fail "expected a 'no package directory' log line"
assert_stdout_clean

# --- Case 2: the directory exists but holds no wheel --------------------
mkdir -p "$sandbox/empty"
run_install "$sandbox/empty"
[ "$(last_exit)" = "0" ] || fail "expected exit 0 for an empty directory, got $(last_exit)"
[ "$(pip_call_count)" = "0" ] || fail "expected no pip call for an empty directory"
grep -q 'no wheels found' "$sandbox/err.log" ||
	fail "expected a 'no wheels found' log line"
assert_stdout_clean

# --- Case 3: two wheels are installed one by one, offline ---------------
pkgdir="$sandbox/pkgs"
mkdir -p "$pkgdir"
: >"$pkgdir/alpha-1.0-py3-none-any.whl"
: >"$pkgdir/beta-2.0-py3-none-any.whl"
run_install "$pkgdir"
[ "$(last_exit)" = "0" ] || fail "expected exit 0 when all wheels install, got $(last_exit)"
[ "$(pip_call_count)" = "2" ] || fail "expected 2 pip calls, got $(pip_call_count)"
grep -q -- '--no-index' "$call_log" || fail "expected --no-index so pip stays offline"
grep -q -- "--find-links=$pkgdir" "$call_log" ||
	fail "expected --find-links to point at the package directory"
grep -q -- '--only-binary=:all:' "$call_log" ||
	fail "expected --only-binary=:all: so pip never tries to compile an sdist"
grep -q -- "$pkgdir/alpha-1.0-py3-none-any.whl" "$call_log" ||
	fail "expected the alpha wheel path in the pip call"
grep -q -- "$pkgdir/beta-2.0-py3-none-any.whl" "$call_log" ||
	fail "expected the beta wheel path in the pip call"
assert_stdout_clean

# --- Case 4: a broken wheel fails but the other one still installs ------
# NOTE: the directory name must not contain "broken" -- the stub pip fails on
# ANY argument containing that substring, including --find-links=<dir>.
pkgdir="$sandbox/mixed"
mkdir -p "$pkgdir"
: >"$pkgdir/broken-1.0-py3-none-any.whl"
: >"$pkgdir/good-1.0-py3-none-any.whl"
run_install "$pkgdir"
[ "$(last_exit)" = "1" ] || fail "expected exit 1 when a wheel fails, got $(last_exit)"
[ "$(pip_call_count)" = "2" ] || fail "expected both wheels to be attempted, got $(pip_call_count)"
grep -q 'failed to install broken-1.0-py3-none-any.whl' "$sandbox/err.log" ||
	fail "expected an error line naming the broken wheel"
grep -q '1 succeeded, 1 failed' "$sandbox/err.log" ||
	fail "expected a summary line reporting 1 succeeded, 1 failed"
assert_stdout_clean

# --- Case 5: pip is missing -> fail loudly ------------------------------
pkgdir="$sandbox/pkgs"
EXTRA_ENV="PIP_BIN=definitely-not-pip"
run_install "$pkgdir"
[ "$(last_exit)" = "1" ] || fail "expected exit 1 when pip is missing, got $(last_exit)"
grep -q 'pip not found in PATH' "$sandbox/err.log" ||
	fail "expected a 'pip not found in PATH' error line"
assert_stdout_clean
EXTRA_ENV=""

# --- Case 6: RUNTIME_PKGS_DIR overrides the default directory -----------
pkgdir="$sandbox/env-pkgs"
mkdir -p "$pkgdir"
: >"$pkgdir/env-1.0-py3-none-any.whl"
EXTRA_ENV="RUNTIME_PKGS_DIR=$pkgdir"
run_install
[ "$(last_exit)" = "0" ] || fail "expected exit 0 when the env dir holds a wheel, got $(last_exit)"
[ "$(pip_call_count)" = "1" ] || fail "expected 1 pip call, got $(pip_call_count)"
grep -q -- "$pkgdir/env-1.0-py3-none-any.whl" "$call_log" ||
	fail "expected the wheel from RUNTIME_PKGS_DIR to be installed"
EXTRA_ENV=""

echo "OK: all install-pkgs tests passed"
