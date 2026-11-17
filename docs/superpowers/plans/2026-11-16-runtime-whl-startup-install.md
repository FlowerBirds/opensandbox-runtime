# Runtime 镜像启动时安装本地 wheel + 构建日期标签 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 让 runtime 镜像在容器启动时把 `/opt/install/pkgs` 下的 wheel 装进系统 Python（换包不用重建镜像），并给镜像加上含实际构建时间的 OCI 标签。

**Architecture:** 新增两个 bash 脚本 —— `scripts/install-pkgs.sh`（只做安装，幂等、可单独调用）与 `scripts/runtime-entrypoint.sh`（薄入口：调安装 → `exec "$@"`）。镜像新增 `ENTRYPOINT` 指向入口脚本，`CMD ["python"]` 保持不变，因此 `docker run <image> python` 等既有用法语义不变。构建日期标签由 CI（`build.yml`）注入 `org.opencontainers.image.created` 等 OCI 标签，不改 Dockerfile。

**Tech Stack:** Bash（无外部依赖，只需 bash + coreutils）、Docker / Dockerfile、Docker Buildx、GitHub Actions、Python + PyYAML（仅用于本地校验 workflow YAML）

**Spec:** `docs/superpowers/specs/2026-11-16-runtime-whl-startup-install-design.md`

---

## 背景与约束（执行前必读）

- **本机没有容器工具**：`docker` / `podman` / `buildah` 全部不可用。镜像构建只能靠 CI（push `main` 触发 `.github/workflows/build.yml`）。所有需要构建的验证步骤都在 Task 6。
- **构建上下文被严格限制**：`Dockerfile_runtime.dockerignore` 是 `**` + 两条 negation，**只放行 `Dockerfile_runtime` 和 `requirements.txt`**。新增脚本必须同步改这个文件，否则 `COPY` 阶段直接失败。
- **仓库的 `.sh` 文件在 git 里是 `100644`（无执行位）**，与 `scripts/code-interpreter.sh` 一致。新脚本同样不加执行位，镜像内用 `chmod +x` 处理，测试用 `bash <脚本>` 调用。
- **`.gitattributes` 强制 `*.sh` 为 LF**，脚本内不要出现 CRLF。
- **既有 README 描述的是 code-interpreter 镜像**（Ubuntu 24.04 / 多语言 / Jupyter），不是 runtime 镜像。文档要新增独立的「Runtime 镜像」章节。
- **禁止 `-c` 参数**：`git` 命令一律用全局配置，不要 `git -c ...`。
- **不写 `Co-Authored-By`**。

## File Structure

| 文件 | 动作 | 职责 |
| --- | --- | --- |
| `scripts/install-pkgs.sh` | 新建 | 扫描 `/opt/install/pkgs/*.whl`，逐个 `pip install`（离线）。只做安装，幂等，可单独 `docker exec` 调用 |
| `scripts/runtime-entrypoint.sh` | 新建 | 调安装脚本 → `exec "$@"`。不含安装细节 |
| `tests/test_install_pkgs.sh` | 新建 | `install-pkgs.sh` 的单元测试（stub `pip` 记录调用参数） |
| `tests/test_runtime_entrypoint.sh` | 新建 | `runtime-entrypoint.sh` 的单元测试（stub 安装脚本 + stub exec 目标） |
| `Dockerfile_runtime` | 修改 | 新增 step 7：`COPY` 两个脚本、`mkdir -p /opt/install/pkgs`、新增 `ENTRYPOINT` |
| `Dockerfile_runtime.dockerignore` | 修改 | 放行两个脚本 |
| `.github/workflows/build.yml` | 修改 | 新增构建时间戳步骤、扩充 OCI 标签、构建前跑测试、tarball 步骤同样带标签 |
| `README_zh.md` | 修改 | 新增「Runtime 镜像（opensandbox-runtime）」章节 |
| `README.md` | 修改 | 同上（英文版） |

---

## Task 1: `scripts/install-pkgs.sh`（测试先行）

**Files:**
- Create: `tests/test_install_pkgs.sh`
- Create: `scripts/install-pkgs.sh`

- [x] **Step 1: 写失败测试 `tests/test_install_pkgs.sh`**

```bash
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

run_install() {
	: >"$call_log"
	local rc=0
	CALL_LOG="$call_log" PATH="$sandbox:$PATH" \
		bash "$script" "$@" >"$sandbox/out.log" 2>"$sandbox/err.log" || rc=$?
	echo "$rc" >"$sandbox/last-exit"
}

last_exit() { cat "$sandbox/last-exit"; }

pip_call_count() { grep -c '^pip install' "$call_log" 2>/dev/null || true; }

# --- Case 1: the package directory does not exist -----------------------
run_install "$sandbox/missing"
[ "$(last_exit)" = "0" ] || fail "expected exit 0 for a missing directory, got $(last_exit)"
[ "$(pip_call_count)" = "0" ] || fail "expected no pip call for a missing directory"
grep -q 'no package directory' "$sandbox/out.log" ||
	fail "expected a 'no package directory' log line"

# --- Case 2: the directory exists but holds no wheel --------------------
mkdir -p "$sandbox/empty"
run_install "$sandbox/empty"
[ "$(last_exit)" = "0" ] || fail "expected exit 0 for an empty directory, got $(last_exit)"
[ "$(pip_call_count)" = "0" ] || fail "expected no pip call for an empty directory"
grep -q 'no wheels found' "$sandbox/out.log" ||
	fail "expected a 'no wheels found' log line"

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
grep -q -- "$pkgdir/alpha-1.0-py3-none-any.whl" "$call_log" ||
	fail "expected the alpha wheel path in the pip call"
grep -q -- "$pkgdir/beta-2.0-py3-none-any.whl" "$call_log" ||
	fail "expected the beta wheel path in the pip call"

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
grep -q '1 succeeded, 1 failed' "$sandbox/out.log" ||
	fail "expected a summary line reporting 1 succeeded, 1 failed"

echo "OK: all install-pkgs tests passed"
```

- [x] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_install_pkgs.sh`
Expected: FAIL —— 脚本不存在，报 `No such file or directory`（`bash` 找不到 `scripts/install-pkgs.sh`）

- [x] **Step 3: 实现 `scripts/install-pkgs.sh`**

```bash
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
# instead of reaching out to a package index.

set -uo pipefail

PKGS_DIR="${1:-${RUNTIME_PKGS_DIR:-/opt/install/pkgs}}"
PIP_BIN="${PIP_BIN:-pip}"

log() { printf '[install-pkgs] %s\n' "$*"; }
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
			--find-links="$PKGS_DIR" "$wheel"; then
		ok=$((ok + 1))
	else
		err "failed to install ${name}"
		failed=$((failed + 1))
	fi
done

log "done: ${ok} succeeded, ${failed} failed"
[ "$failed" -eq 0 ]
```

- [x] **Step 4: 运行测试，确认通过**

Run: `bash tests/test_install_pkgs.sh`
Expected: 输出 `OK: all install-pkgs tests passed`，退出码 0

- [x] **Step 5: 提交**

```bash
git add scripts/install-pkgs.sh tests/test_install_pkgs.sh
git commit -m "feat(runtime): 新增启动时安装本地 wheel 的脚本"
```

---

## Task 2: `scripts/runtime-entrypoint.sh`（测试先行）

**Files:**
- Create: `tests/test_runtime_entrypoint.sh`
- Create: `scripts/runtime-entrypoint.sh`

- [x] **Step 1: 写失败测试 `tests/test_runtime_entrypoint.sh`**

```bash
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
if grep -q 'skipping package installation' "$sandbox/out.log"; then
	fail "did not expect the skip message when installing"
fi

# --- Case 2: a failing install must not block the container ------------
install_exit=1
run_entrypoint "$sandbox/echo-args"
[ "$(last_exit)" = "0" ] ||
	fail "expected exit 0 even when the install fails, got $(last_exit)"
grep -q '^exec-target' "$call_log" ||
	fail "expected the command to still run after a failed install"
grep -q 'WARN: package installation failed' "$sandbox/err.log" ||
	fail "expected a WARN line about the failed installation"

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

# --- Case 4: arguments are passed through untouched -------------------
skip_install=""
run_entrypoint "$sandbox/echo-args" python -c "print(1)"
grep -q '^exec-target python -c print(1)$' "$call_log" ||
	fail "expected the arguments to be passed through verbatim"

echo "OK: all runtime-entrypoint tests passed"
```

- [x] **Step 2: 运行测试，确认失败**

Run: `bash tests/test_runtime_entrypoint.sh`
Expected: FAIL —— 找不到 `scripts/runtime-entrypoint.sh`

- [x] **Step 3: 实现 `scripts/runtime-entrypoint.sh`**

```bash
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

set -uo pipefail

INSTALL_PKGS_BIN="${INSTALL_PKGS_BIN:-/usr/local/bin/install-pkgs.sh}"

skip="$(printf '%s' "${RUNTIME_SKIP_INSTALL:-0}" | tr '[:upper:]' '[:lower:]')"
case "$skip" in
1 | true | yes | on)
	printf '[runtime-entrypoint] RUNTIME_SKIP_INSTALL set, skipping package installation\n'
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
```

- [x] **Step 4: 运行测试，确认通过**

Run: `bash tests/test_runtime_entrypoint.sh`
Expected: 输出 `OK: all runtime-entrypoint tests passed`，退出码 0

- [x] **Step 5: 提交**

```bash
git add scripts/runtime-entrypoint.sh tests/test_runtime_entrypoint.sh
git commit -m "feat(runtime): 新增镜像启动入口脚本"
```

---

## Task 3: 接入镜像（Dockerfile + dockerignore）

**Files:**
- Modify: `Dockerfile_runtime`（在 step 6 的 DPI 注释块之后、`WORKDIR /workspace` 之前）
- Modify: `Dockerfile_runtime.dockerignore`

- [x] **Step 1: 改 `Dockerfile_runtime.dockerignore`**

替换整个文件内容为：

```
**
!Dockerfile_runtime
!requirements.txt
!scripts
!scripts/install-pkgs.sh
!scripts/runtime-entrypoint.sh
```

> `!scripts` 不能省：Docker 的排除规则里，父目录被排除时无法重新包含其子文件。副作用是 `scripts/` 下其他文件（`code-interpreter.sh` 等）也可能进入构建上下文 —— 只是多几 KB，不影响构建结果。若 CI 报 `COPY` 找不到源文件，改用回退方案（见 Step 4）。

- [x] **Step 2: 改 `Dockerfile_runtime`**

在 DPI 注释块（`#     rm -f /tmp/dpi.zip`）之后、`WORKDIR /workspace` 之前插入：

```dockerfile
# 7. Startup hooks. The entrypoint installs every wheel found in
#    /opt/install/pkgs (normally a mounted directory) before handing over to
#    the container command, so frequently updated packages can be delivered
#    without rebuilding the image. With nothing mounted the install step is a
#    no-op and the container behaves exactly as before.
COPY scripts/install-pkgs.sh scripts/runtime-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-pkgs.sh /usr/local/bin/runtime-entrypoint.sh \
    && mkdir -p /opt/install/pkgs

ENTRYPOINT ["/usr/local/bin/runtime-entrypoint.sh"]
CMD ["python"]
```

- [x] **Step 3: 提交**

```bash
git add Dockerfile_runtime Dockerfile_runtime.dockerignore
git commit -m "feat(runtime): 镜像接入启动时安装 wheel 的入口脚本"
```

> 本机不构建镜像，Dockerfile 与 dockerignore 的实际效果由 CI 构建验证（见 Task 6）。
> 如果 CI 报 `COPY failed: file not found in build context`，说明 Docker 版本的父目录排除语义与预期不同，回退方案：
>
> - **方案 A（推荐）**：把两个脚本移到仓库根目录 `install-pkgs.sh` / `runtime-entrypoint.sh`，dockerignore 改为：
>   ```
>   **
>   !Dockerfile_runtime
>   !requirements.txt
>   !install-pkgs.sh
>   !runtime-entrypoint.sh
>   ```
>   根目录不在任何排除目录内，不涉及父目录语义。
> - **方案 B**：保留 `scripts/` 布局，把 dockerignore 改为：
>   ```
>   *
>   !Dockerfile_runtime
>   !requirements.txt
>   !scripts
>   !scripts/*
>   ```

---

## Task 4: CI —— 构建日期标签 + 跑测试

**Files:**
- Modify: `.github/workflows/build.yml`

- [x] **Step 1: 新增构建时间戳步骤**

在 `Resolve image name and release tag` 步骤之后、`Set up QEMU` 之前插入：

```yaml
      - name: Resolve build timestamp
        id: stamp
        run: echo "stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_OUTPUT"
```

- [x] **Step 2: 扩充推送镜像的标签**

把 `Build and push multi-arch image` 步骤里的 `labels:` 整块替换为：

```yaml
          labels: |
            org.opencontainers.image.title=opensandbox-runtime
            org.opencontainers.image.description=Minimal runtime image with Python 3.12, Node.js 22 and Playwright Chromium
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=${{ steps.meta.outputs.tag }}
            org.opencontainers.image.created=${{ steps.stamp.outputs.stamp }}
```

- [x] **Step 3: tarball 构建步骤也带上同一组标签**

在 `Build multi-arch tarball` 步骤的 `with:` 里，把 `outputs:` 之后补上 `labels:`（其余键不动）：

```yaml
          outputs: type=tar,dest=opensandbox-runtime-${{ steps.meta.outputs.tag }}.tar
          labels: |
            org.opencontainers.image.title=opensandbox-runtime
            org.opencontainers.image.description=Minimal runtime image with Python 3.12, Node.js 22 and Playwright Chromium
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=${{ steps.meta.outputs.tag }}
            org.opencontainers.image.created=${{ steps.stamp.outputs.stamp }}
```

- [x] **Step 4: 构建前跑测试**

在 `Login to GHCR` 步骤之后、`Build and push multi-arch image` 之前插入：

```yaml
      - name: Run startup script tests
        run: |
          bash tests/test_install_pkgs.sh
          bash tests/test_runtime_entrypoint.sh
```

> 放在 `Login to GHCR` 之后是为了让测试失败在登录之后、构建之前 —— 构建耗时最长，测试挂在前面能更快暴露问题。

- [x] **Step 5: 本地校验 YAML 语法**

Run:
```bash
python -c "
import yaml
d = yaml.safe_load(open('.github/workflows/build.yml', encoding='utf-8'))
steps = d['jobs']['build']['steps']
names = [s.get('name') for s in steps]
assert 'Resolve build timestamp' in names, names
assert 'Run startup script tests' in names, names
build = next(s for s in steps if s.get('name') == 'Build and push multi-arch image')
labels = build['with']['labels']
assert 'org.opencontainers.image.created=${{ steps.stamp.outputs.stamp }}' in labels, labels
tar = next(s for s in steps if s.get('name') == 'Build multi-arch tarball')
assert 'labels' in tar['with'], tar['with'].keys()
print('workflow OK')
"
```
Expected: 输出 `workflow OK`

- [x] **Step 6: 提交**

```bash
git add .github/workflows/build.yml
git commit -m "ci: runtime 镜像补充构建日期标签并在构建前跑测试"
```

---

## Task 5: 文档

**Files:**
- Modify: `README_zh.md`
- Modify: `README.md`

> 两份 README 现在描述的是 **code-interpreter 镜像**，所以要新开一个独立章节，不要混进 code-interpreter 的「高级用法」。

- [x] **Step 1: 在 `README_zh.md` 的「## 快速开始」之前插入 runtime 镜像章节**

（`## 快速开始` 之前是 `## 支持的语言与版本` 表格及其后的注意事项段落）

```markdown
## Runtime 镜像（opensandbox-runtime）

除了上面这个多语言 Code Interpreter 镜像，本仓库还构建一个精简的 **runtime 镜像**，
用于沙箱执行环境：

- 基础镜像：`python:3.12-slim`（Debian 12）
- 预装：Python 3.12 常用包（numpy / pandas / openpyxl / python-docx / python-pptx /
  markitdown / PyMuPDF / SQLAlchemy / PyMySQL / gmssl 国密 等）、Node.js 22、
  Playwright + Chromium
- 入口：`python`（无参数启动进入 REPL）
- 多架构：`linux/amd64` + `linux/arm64`

```bash
docker pull ghcr.io/flowerbirds/opensandbox-runtime:latest
docker run --rm -it ghcr.io/flowerbirds/opensandbox-runtime:latest
```

### 启动时安装本地 wheel

把 `.whl` 挂载到 `/opt/install/pkgs`，容器启动时会自动把它们装进系统 Python。
适合包更新频繁、不想每次都重新构建镜像的场景：

```bash
docker run --rm -it \
  -v /host/pkgs:/opt/install/pkgs \
  ghcr.io/flowerbirds/opensandbox-runtime:latest
```

- 目录约定：`/opt/install/pkgs`，只看该目录**顶层**的 `*.whl`，不递归子目录
- 依赖解析：**完全离线** —— pip 只从该目录找依赖（`--no-index --find-links`），
  缺失的依赖需要在同目录补上对应 wheel
- 安装失败**不会阻断容器启动**：失败的包会在日志里报错，其余包继续装，容器照常运行
- 跳过安装：设置 `RUNTIME_SKIP_INSTALL=1`
- 容器运行中换完 wheel 想立刻生效，无需重启：

  ```bash
  docker exec -it <container> install-pkgs.sh
  ```

### 查看镜像构建信息

镜像带 OCI 标签，其中 `org.opencontainers.image.created` 是本次构建的时间（UTC）：

```bash
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.created"}}' \
  ghcr.io/flowerbirds/opensandbox-runtime:latest
```

> 需要按内容（而非构建批次）比对镜像时，用 `org.opencontainers.image.revision`，
> 它是触发构建的 commit SHA。
```

- [x] **Step 2: 在 `README.md` 写对应的英文章节**

放在 `## Quick Start` 之前，标题与内容对应上面中文章节：

```markdown
## Runtime image (opensandbox-runtime)

Besides the multi-language Code Interpreter image above, this repository also builds a
lean **runtime image** for sandbox execution environments:

- Base image: `python:3.12-slim` (Debian 12)
- Preinstalled: common Python 3.12 packages (numpy / pandas / openpyxl / python-docx /
  python-pptx / markitdown / PyMuPDF / SQLAlchemy / PyMySQL / gmssl ...), Node.js 22,
  Playwright + Chromium
- Entry point: `python` (starts a REPL with no arguments)
- Architectures: `linux/amd64` + `linux/arm64`

```bash
docker pull ghcr.io/flowerbirds/opensandbox-runtime:latest
docker run --rm -it ghcr.io/flowerbirds/opensandbox-runtime:latest
```

### Installing local wheels at startup

Mount `.whl` files to `/opt/install/pkgs` and they are installed into the system
Python when the container starts — useful when packages change often and rebuilding
the image is too expensive:

```bash
docker run --rm -it \
  -v /host/pkgs:/opt/install/pkgs \
  ghcr.io/flowerbirds/opensandbox-runtime:latest
```

- Directory: `/opt/install/pkgs`; only top-level `*.whl` files are considered (no recursion)
- Dependency resolution is **fully offline** — pip only looks in that directory
  (`--no-index --find-links`), so a missing dependency must be added there as a wheel too
- A failed install **never blocks container startup**: the failing package is reported
  in the log, the remaining packages are still installed, and the container starts
- Skip the install entirely with `RUNTIME_SKIP_INSTALL=1`
- To apply newly mounted wheels to a running container, no restart is needed:

  ```bash
  docker exec -it <container> install-pkgs.sh
  ```

### Inspecting the build

The image carries OCI labels; `org.opencontainers.image.created` is the build time (UTC):

```bash
docker inspect --format '{{index .Config.Labels "org.opencontainers.image.created"}}' \
  ghcr.io/flowerbirds/opensandbox-runtime:latest
```

> To compare images by content rather than by build batch, use
> `org.opencontainers.image.revision` — the commit SHA that triggered the build.
```

- [x] **Step 3: 检查 Markdown 围栏配对**

Run:
```bash
python -c "
for f in ('README.md', 'README_zh.md'):
    n = sum(1 for l in open(f, encoding='utf-8') if l.startswith('\`\`\`'))
    print(f, 'fences:', n, 'balanced' if n % 2 == 0 else 'UNBALANCED')
"
```
Expected: 两个文件都输出 `balanced`

- [x] **Step 4: 提交**

```bash
git add README.md README_zh.md
git commit -m "docs: 补充 runtime 镜像启动时安装 wheel 与构建标签说明"
```

---

## Task 6: 交付（提交并推送，由 CI 完成构建验证）

> 本机没有容器工具，镜像**不在本地构建** —— 推送 `main` 后由 GitHub Actions 构建并推送。
> 因此本任务只负责把改动推到远端触发构建；镜像层面的行为验证交给 CI 与使用方。

- [x] **Step 1: 确认工作区干净、提交完整**

Run: `git status --short && git log --oneline -6`
Expected: `git status --short` 无输出；日志里能看到本计划的 5 个提交

- [x] **Step 2: 推送（对外动作，执行前确认用户同意）**

Run: `git push origin main`
Expected: push 成功，`.github/workflows/build.yml`（`Build and Push Runtime Image`）被触发

- [x] **Step 3: 确认 CI 结果**

在 GitHub Actions 页面确认 `Build and Push Runtime Image / build` 作业：

- `Run startup script tests` 通过（两个脚本输出 `OK: all ... tests passed`）
- `Build and push multi-arch image` 成功
  - 若报 `COPY failed: ... not found in build context` → 执行 **Task 3 Step 3** 里的 dockerignore 回退方案，重新提交并重推

---

## 需求覆盖对照（spec → 任务）

| spec 章节 | 实现任务 |
| --- | --- |
| 6.1 `install-pkgs.sh` 规格（目录解析、离线安装、逐个安装、失败继续、汇总） | Task 1 |
| 6.2 `runtime-entrypoint.sh` 规格（跳过开关、告警不阻断、`exec "$@"`） | Task 2 |
| 6.3 `Dockerfile_runtime` 改动（COPY / chmod / mkdir / ENTRYPOINT / CMD 不变） | Task 3 |
| 6.4 `Dockerfile_runtime.dockerignore` 改动 | Task 3 |
| 6.5 构建产物标签（时间戳步骤、labels 扩充、tarball 同标签、CI 跑测试） | Task 4 |
| 8 错误处理矩阵（目录缺失 / 空目录 / 单包失败 / pip 缺失 / 跳过 / `--entrypoint` 覆盖） | Task 1 Case 1/2/4、Task 2 Case 2/3；`--entrypoint` 覆盖与 pip 缺失由脚本逻辑天然满足 |
| 9 测试策略（6 条用例 + 构建验证） | Task 1（4 例）、Task 2（4 例）、Task 4 Step 4（CI 跑测试）、Task 6（CI 构建） |
| 10 文档 | Task 5 |
| 11 取舍与限制 | 已在 spec 记录；Task 6 Step 4 验证限制行为 |
