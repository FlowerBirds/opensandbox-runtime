# runtime 镜像启动时自动安装本地 wheel — 设计文档

- 日期：2026-11-16
- 状态：待评审
- 影响范围：`Dockerfile_runtime`、`Dockerfile_runtime.dockerignore`、`scripts/`、`tests/`、`.github/workflows/build.yml`、`README.md`、`README_zh.md`

## 1. 背景与目标

runtime 镜像（`ghcr.io/flowerbirds/opensandbox-runtime`）目前把 Python 依赖烤死在镜像里（`requirements.txt`），任何一次包升级都要重新走一遍 CI 构建 + 推送 + 拉取。在包更新频繁的场景下，这条链路成本过高。

目标：容器启动时自动执行一个安装脚本，把指定目录下的 `.whl` 安装进系统 Python，使"换包"退化为"换文件 + 重启容器"，不需要重新构建镜像。

核心诉求：

1. 挂载目录下的 wheel 在容器启动时被安装，无需重建镜像
2. 安装失败不能拖垮容器（沙箱仍要能用）
3. 保持现有 `docker run <image> python` 等所有用法完全兼容
4. 镜像携带构建日期等 OCI 标签，便于识别镜像批次

## 2. 非目标（YAGNI）

- 不递归扫描子目录
- 不支持 `.tar.gz` 源码包、`requirements.txt`、`setup.py`
- 不落盘安装清单 / 安装状态文件
- 不配置私有 PyPI 源（私有源能力已由构建期的 `PRIVATE_PYPI_*` 提供）
- 不改动 `code-interpreter` 镜像（`Dockerfile` / `Dockerfile_base`）

## 3. 现状

| 项 | 现状 |
| --- | --- |
| 基础镜像 | `python:3.12-slim`（Debian 12） |
| 入口 | 仅 `CMD ["python"]`，**无 ENTRYPOINT** |
| pip | 基础镜像自带（`pip` 在 PATH 中） |
| 构建上下文 | `Dockerfile_runtime.dockerignore` 为 `**` + `!Dockerfile_runtime` + `!requirements.txt`，**只放行这两个文件** |
| 脚本约定 | `scripts/` 目录，COPY 进镜像后 `chmod +x`（参照 `scripts/code-interpreter.sh`） |
| 现有测试 | `tests/test_code_interpreter_node_setup.sh`，bash + stub 风格，本地可直接运行 |

## 4. 已确认的决策

| 决策点 | 结论 |
| --- | --- |
| 触发方式 | 新增 `ENTRYPOINT` 包装脚本，安装后 `exec "$@"`，保留 `CMD ["python"]` |
| 失败策略 | 安装失败仅告警，容器照常启动 |
| 依赖来源 | 纯本地离线（`--no-index --find-links`），不访问任何索引 |
| 安装目标 | 系统 Python 3.12 的 site-packages（`/usr/local/lib/python3.12/site-packages`） |
| 脚本形态 | 双文件：独立的安装脚本 + 薄入口脚本 |
| 安装目录 | **`/opt/install/pkgs`**（由 `/opt/installs/pkgs` 改名而来） |
| 构建日期标签 | 用**实际构建时间**（UTC ISO-8601），写入 `org.opencontainers.image.created` |

## 5. 架构

```
docker run -v /host/pkgs:/opt/install/pkgs <image> python
   │
   └─ ENTRYPOINT /usr/local/bin/runtime-entrypoint.sh
        │
        ├─ 调 /usr/local/bin/install-pkgs.sh
        │     └─ 扫描 /opt/install/pkgs/*.whl，逐个 pip install（本地离线）
        │        失败 → 打 WARN，不阻断
        │
        └─ exec "$@"      → python（或用户指定的任意命令）
```

两个脚本职责严格分离：

- `install-pkgs.sh`：**只做安装**，幂等，可被单独 `docker exec` 调用（容器运行中换完 wheel 免重启重装）
- `runtime-entrypoint.sh`：**只做编排**（调安装 → `exec "$@"`），不含任何安装细节

`exec` 保证最终进程替换 shell，PID 1 与信号传递语义正确。

## 6. 组件规格

### 6.1 `scripts/install-pkgs.sh` → `/usr/local/bin/install-pkgs.sh`

行为规格：

1. 目录解析：命令行参数 > 环境变量 `RUNTIME_PKGS_DIR` > 默认 `/opt/install/pkgs`（入口脚本调用时**不传参**，也不把容器命令的 `"$@"` 透传给安装脚本 —— 两者语义不同：`"$@"` 是容器要执行的命令，安装目录只由 `RUNTIME_PKGS_DIR` 或默认值决定）
2. 目录不存在 → 打印一行 INFO，`exit 0`（不视为错误）
3. 只取目录**顶层**的 `*.whl`，不递归
4. 无 wheel → 打印一行 INFO，`exit 0`
5. `pip` 不在 PATH → 打印 ERROR，`exit 1`
6. **逐个**执行安装（不是一次 pip 调用装全部）：

   ```
   pip install --no-index --no-cache-dir --disable-pip-version-check \
       --find-links=<dir> <wheel 绝对路径>
   ```

7. 单个 wheel 安装失败 → 打印 ERROR，**继续装下一个**；结束时打印汇总（成功 N / 失败 M）；存在失败则 `exit 1`
8. 日志前缀 `[install-pkgs]`，正常信息走 stdout，错误走 stderr
9. 脚本自身 `set -uo pipefail`（**不加 `-e`**），保证单个包失败不中断循环；数组展开依赖 `shopt -s nullglob` 处理空目录

参考实现：

```bash
#!/usr/bin/env bash
# Copyright 2026 Alibaba Group Holding Ltd.
# (Apache-2.0 头，与 scripts/code-interpreter.sh 保持一致)

# Install every wheel found in a directory into the system Python.
# Used by the runtime image entrypoint so frequently-updated packages can be
# delivered as mounted wheels instead of an image rebuild.

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

### 6.2 `scripts/runtime-entrypoint.sh` → `/usr/local/bin/runtime-entrypoint.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Alibaba Group Holding Ltd.
# (Apache-2.0 头，与 scripts/code-interpreter.sh 保持一致)

# Install mounted wheels, then hand over to the container command.

set -uo pipefail

skip="$(printf '%s' "${RUNTIME_SKIP_INSTALL:-0}" | tr '[:upper:]' '[:lower:]')"
case "$skip" in
1 | true | yes | on)
	printf '[runtime-entrypoint] RUNTIME_SKIP_INSTALL set, skipping package installation\n'
	;;
*)
	if ! /usr/local/bin/install-pkgs.sh; then
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

### 6.3 `Dockerfile_runtime` 改动

在现有 step 6（DPI 停用注释）之后、`WORKDIR` 之前新增：

```dockerfile
# 7. Startup hooks: install mounted wheels, then hand over to the container
#    command. The install step is a no-op when nothing is mounted at
#    /opt/install/pkgs, so existing deployments are unaffected.
COPY scripts/install-pkgs.sh scripts/runtime-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/install-pkgs.sh /usr/local/bin/runtime-entrypoint.sh \
    && mkdir -p /opt/install/pkgs

ENTRYPOINT ["/usr/local/bin/runtime-entrypoint.sh"]
CMD ["python"]
```

`CMD` 保持 `["python"]` 不变 —— 现有 `docker run <image> python` / `docker run <image> bash` / `docker run <image>` 全部保持原语义。

### 6.4 `Dockerfile_runtime.dockerignore` 改动

当前内容：

```
**
!Dockerfile_runtime
!requirements.txt
```

需要补充（注意 Docker 不允许在父目录被排除时重新包含子文件，因此要同时放行目录本身）：

```
**
!Dockerfile_runtime
!requirements.txt
!scripts
!scripts/install-pkgs.sh
!scripts/runtime-entrypoint.sh
```

### 6.5 构建产物标签（`.github/workflows/build.yml`）

目标：镜像带上可识别其构建批次的 OCI 标签，其中构建日期用**实际构建时间**（UTC ISO-8601）。

改动一，新增一个计算时间戳的步骤（放在现有 "Resolve image name and release tag" 之后）：

```yaml
      - name: Resolve build timestamp
        id: stamp
        run: echo "stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_OUTPUT"
```

改动二，"Build and push multi-arch image" 步骤的 `labels` 扩充为：

```yaml
          labels: |
            org.opencontainers.image.title=opensandbox-runtime
            org.opencontainers.image.description=Minimal runtime image with Python 3.12, Node.js 22 and Playwright Chromium
            org.opencontainers.image.source=${{ github.server_url }}/${{ github.repository }}
            org.opencontainers.image.revision=${{ github.sha }}
            org.opencontainers.image.version=${{ steps.meta.outputs.tag }}
            org.opencontainers.image.created=${{ steps.stamp.outputs.stamp }}
```

改动三，"Build multi-arch tarball" 步骤（离线包附件）同样传入这组 `labels`，保证用户 `docker load` 出来的镜像同样带标签，且 `created` 与推送的镜像一致（复用同一个 `stamp`）。

说明：

- 标签只改镜像 config，不产生文件层，不影响 `cache-from/cache-to: type=gha` 的层缓存命中率
- `Dockerfile_runtime` **不**加 `LABEL` 指令 —— 标签统一由 CI 注入，避免本地构建与 CI 构建出现两套标签来源
- `offline-bundle.yml` 从 registry 拉取 `:latest` 再导出，标签随镜像 config 一并保留，无需改动

## 7. 数据流

1. 宿主把 wheel 目录挂载到 `/opt/install/pkgs`
2. 容器启动 → ENTRYPOINT 脚本启动
3. `install-pkgs.sh` 扫描目录，对每个 wheel 调一次 `pip install`
4. pip 解析依赖时：已装版本满足 → 复用；不满足 → 从 `--find-links` 指向的目录找；找不到 → 该包安装失败
5. 安装完成后 `exec "$@"` 启动用户命令（如 `python`）

## 8. 错误处理

| 场景 | 行为 | 容器是否启动 |
| --- | --- | --- |
| `/opt/install/pkgs` 不存在 | INFO 一行，`install-pkgs.sh` exit 0 | 是 |
| 目录存在但无 `.whl` | INFO 一行，exit 0 | 是 |
| 某个 wheel 损坏 / 依赖缺失 | ERROR 该包 → 继续装其它 → 汇总 → entrypoint 打 WARN | 是 |
| `pip` 不在 PATH | ERROR，exit 1 → entrypoint 打 WARN | 是 |
| 所有 wheel 都失败 | 同上，汇总显示 0 成功 / N 失败 | 是 |
| 用户显式 `--entrypoint` 覆盖 | 整个脚本不执行（预期行为） | 是（不安装） |
| `RUNTIME_SKIP_INSTALL=1` | 跳过安装，直接 `exec "$@"` | 是 |

设计取向：**安装失败永远不阻断容器启动**。沙箱可用性优先于单个辅助包的成功与否。

## 9. 测试策略

新增 `tests/test_runtime_entrypoint.sh`，沿用 `tests/test_code_interpreter_node_setup.sh` 的 stub 风格（PATH 前置假 `pip` 记录调用），本地 Git Bash 可直接运行，不依赖镜像：

| # | 用例 | 断言 |
| --- | --- | --- |
| 1 | 安装目录不存在 | 不调用 pip；后续命令被执行 |
| 2 | 目录含 2 个 wheel | pip 调用 2 次；参数含 `--no-index`、`--find-links=<dir>`、正确的 wheel 路径 |
| 3 | 某个 wheel 安装失败 | 另一个仍被安装；最终 `exec` 仍执行（容器继续） |
| 4 | `RUNTIME_SKIP_INSTALL=1` | 不调用 pip |
| 5 | 空目录（无 wheel） | 不调用 pip，正常退出 |
| 6 | 参数透传 | 入口脚本后的参数原样传给被 exec 的命令 |

构建验证（需 CI，因本机无 Docker）：

- `docker buildx build -f Dockerfile_runtime` 成功 → 验证 dockerignore 改动未破坏构建上下文
- 镜像内 `docker run --rm <image> python -c "import numpy"` 正常
- 挂载 wheel 后 `docker run --rm -v <dir>:/opt/install/pkgs <image> python -c "import <pkg>"` 生效
- 标签落地校验：

  ```bash
  docker inspect --format '{{index .Config.Labels "org.opencontainers.image.created"}}' <image>
  # 期望：2026-11-16T15:04:22Z 形式的 UTC ISO-8601
  ```

## 10. 文档

`README_zh.md` / `README.md` 增加「启动时安装本地 wheel」小节，说明：

- 挂载用法：

  ```bash
  docker run --rm -it \
    -v /host/pkgs:/opt/install/pkgs \
    ghcr.io/flowerbirds/opensandbox-runtime:latest
  ```

- 目录约定、离线依赖解析规则、失败不阻断的行为
- `RUNTIME_SKIP_INSTALL=1` 跳过开关
- 容器运行中手动重装：`docker exec -it <container> install-pkgs.sh`
- 镜像标签：如何用 `docker inspect` 查看构建日期

## 11. 取舍与已知限制

| 取舍 | 理由 |
| --- | --- |
| 不用 `--force-reinstall` | 该参数会把整个依赖闭包标记重装，本地目录里没有的依赖会直接失败。代价是"同名同版本重新打包"的 wheel 不会生效，需要时手动 `pip install --force-reinstall --no-deps <wheel>` |
| 逐个安装而非一次装全部 | 目录内同时存在新旧版本时，批量安装会触发 pip 版本冲突；逐个安装还能做到单包失败不影响其他包 |
| 依赖只从本地目录解析 | 内网/离线部署下访问公网索引会卡在连接超时；镜像已自带常用依赖，缺的依赖显式补 wheel 即可 |
| 安装到系统 site-packages 而非 `PYTHONPATH` 目录 | 标准 import 路径，无需额外配置；`PYTHONPATH=/opt/python/pkgs` 仍保留给宿主挂载纯目录型包的场景 |
| 标签只由 CI 注入，`Dockerfile_runtime` 不写 `LABEL` | 单一来源，避免本地构建与 CI 构建两套标签；标签只改 image config，不产生文件层，不影响 `type=gha` 层缓存命中率 |

已知限制：

- 每台机器、每次启动都要重装一遍挂载的 wheel（容器可写层是全新的），启动有额外开销（本地文件，通常 1～3 秒）
- wheel 与镜像内已有包存在依赖冲突时，安装失败并降级为告警
- 用户用 `--entrypoint` 覆盖时安装被跳过
- `created` 标签用实际构建时间，因此**每次构建产出的镜像 digest 都不同**（即使内容完全一致）；需要按内容比对时用 `org.opencontainers.image.revision`
