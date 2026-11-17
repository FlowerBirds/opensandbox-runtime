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

# Install mounted wheels, then hand over to the container command.
#
# The install step never blocks container startup: a failure is logged as a
# warning and the container command still runs.
#
# The install script is called without arguments on purpose -- "$@" is the
# command the container should run, while the package directory is decided by
# $RUNTIME_PKGS_DIR or its default.
#
# All output goes to stderr: the container's stdout is the data channel the
# sandbox server collects and must stay free of noise.

set -uo pipefail

INSTALL_PKGS_BIN="${INSTALL_PKGS_BIN:-/usr/local/bin/install-pkgs.sh}"

skip="$(printf '%s' "${RUNTIME_SKIP_INSTALL:-0}" | tr '[:upper:]' '[:lower:]')"
case "$skip" in
1 | true | yes | on)
	printf '[runtime-entrypoint] RUNTIME_SKIP_INSTALL set, skipping package installation\n' >&2
	;;
*)
	if ! "$INSTALL_PKGS_BIN"; then
		printf '[runtime-entrypoint] WARN: package installation failed, continuing anyway\n' >&2
	fi
	;;
esac

if [ "$#" -gt 0 ]; then
	exec "$@"
fi

printf '[runtime-entrypoint] ERROR: no command given\n' >&2
exit 1
