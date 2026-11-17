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

# Install every wheel found in a directory into the system Python.
#
# Used by the runtime image entrypoint so that frequently updated packages
# can be delivered as mounted wheels instead of an image rebuild.
#
# Usage:
#   install-pkgs.sh [PKGS_DIR]
#
# PKGS_DIR resolution order: argument > $RUNTIME_PKGS_DIR > /opt/install/pkgs
#
# Dependencies are resolved offline: pip is limited to the package directory
# with --no-index/--find-links, so a wheel whose dependency is missing fails
# instead of reaching out to a package index. --only-binary=:all: keeps pip
# from trying to compile a source distribution -- the image ships no compiler,
# so failing loudly is the only sensible outcome.
#
# Every log line goes to stderr on purpose: the container's stdout is the data
# channel the sandbox server collects and must stay free of noise.

set -uo pipefail

PKGS_DIR="${1:-${RUNTIME_PKGS_DIR:-/opt/install/pkgs}}"
PIP_BIN="${PIP_BIN:-pip}"

log() { printf '[install-pkgs] %s\n' "$*" >&2; }
err() { printf '[install-pkgs] ERROR: %s\n' "$*" >&2; }

if [ ! -d "$PKGS_DIR" ]; then
	log "no package directory at ${PKGS_DIR}, nothing to install"
	exit 0
fi

shopt -s nullglob
wheels=("$PKGS_DIR"/*.whl)
shopt -u nullglob

if [ "${#wheels[@]}" -eq 0 ]; then
	log "no wheels found in ${PKGS_DIR}, nothing to install"
	exit 0
fi

if ! command -v "$PIP_BIN" >/dev/null 2>&1; then
	err "pip not found in PATH"
	exit 1
fi

log "installing ${#wheels[@]} wheel(s) from ${PKGS_DIR}"
ok=0
failed=0
for wheel in "${wheels[@]}"; do
	name="$(basename "$wheel")"
	log "installing ${name}"
	if "$PIP_BIN" install --no-index --no-cache-dir --disable-pip-version-check \
			--only-binary=:all: --find-links="$PKGS_DIR" "$wheel"; then
		ok=$((ok + 1))
	else
		err "failed to install ${name}"
		failed=$((failed + 1))
	fi
done

log "done: ${ok} succeeded, ${failed} failed"
[ "$failed" -eq 0 ]
