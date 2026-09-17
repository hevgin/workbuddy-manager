#!/usr/bin/env bash
# ============================================================
# WorkBuddy Manager —— 一键部署 / 重新部署脚本（Docker 单机版）
#
# 用法：
#   sh deploy.sh                  # 拉官方镜像并部署（最省事：无需 Node.js / Python 构建环境）
#   sh deploy.sh --local          # 用当前目录源码构建镜像（需 Node.js 或已有 web/out）
#   sh deploy.sh --skip-upstream  # 已自备上游 workbuddy2api，跳过检测与安装
#   sh deploy.sh --help
#
# 重复执行就是「更新 + 重启」：账号授权、密钥、日志与用量都在挂载的 data/ 里，不会丢。
#
# 适用：Linux 服务器 / 软路由（官方镜像同时提供 amd64 与 arm64）
# 依赖：Docker + 上游 workbuddy2api（账号池与 OpenAI 兼容网关）
#       —— 脚本默认自动检测并安装上游，装好后到页面「账号 → 添加账号」扫码即可
#       （扫码登录是交互式的，无法在脚本里自动化）
# ============================================================

# 用 `sh deploy.sh` 调用时自动切到 bash（本脚本用到数组）
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

set -e

# ── 可配置项（均可用同名环境变量覆盖）──────────────────────
IMAGE="${IMAGE:-ghcr.io/ithtelab/workbuddy-manager:latest}"  # 官方镜像
LOCAL_IMAGE="${LOCAL_IMAGE:-workbuddy-manager:local}"        # --local 模式构建的镜像名
CONTAINER_NAME="${CONTAINER_NAME:-workbuddy-manager}"
HOST_PORT="${HOST_PORT:-7864}"                               # 宿主侧端口
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"                          # 只监听本机；改成 0.0.0.0 前请先配 HTTPS
CONTAINER_PORT=7864                                          # 容器内端口（Dockerfile CMD 固定）
UPSTREAM_PORT="${UPSTREAM_PORT:-7863}"
UPSTREAM_CONTAINER="${UPSTREAM_CONTAINER:-workbuddy2api}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/opt/workbuddy2api}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/Sliverkiss/workbuddy2api.git}"
MEMORY="${MEMORY:-512m}"                                     # 内存上限，小内存机器可降到 256m
NETWORK_MODE="${NETWORK_MODE:-bridge}"                       # host = 直接用宿主网络
MOUNT_DOCKER_SOCK="${MOUNT_DOCKER_SOCK:-1}"                  # 0 = 不挂（容器内无法重载/更新上游容器）
ADMIN_PASSWORD="${WB_ADMIN_PASSWORD:-}"                      # 留空 = 首次启动随机生成并打印到容器日志
BUILD_LOCAL="${BUILD_LOCAL:-0}"
SKIP_UPSTREAM="${SKIP_UPSTREAM:-0}"
GIT_PULL="${GIT_PULL:-1}"

# ── 输出 helpers ───────────────────────────────────────────
info() { printf '\033[1;34m[·]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[✓]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[✗]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m══ %s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法：sh deploy.sh [选项]

  （无参数）       拉取官方镜像并（重新）部署，无需 Node.js / Python 构建环境
  --local          用当前目录源码构建镜像（需 Node.js，或已存在 web/out）
  --no-pull        本地构建时不执行 git pull
  --skip-upstream  已自备上游 workbuddy2api，跳过检测与安装
  -h, --help       显示本帮助

可用同名环境变量覆盖默认配置，常用几个：
  IMAGE / LOCAL_IMAGE / CONTAINER_NAME / HOST_PORT / BIND_ADDR
  UPSTREAM_DIR / UPSTREAM_PORT / UPSTREAM_CONTAINER / UPSTREAM_REPO
  DATA_DIR / MEMORY / NETWORK_MODE / MOUNT_DOCKER_SOCK / WB_ADMIN_PASSWORD

示例：
  HOST_PORT=8080 sh deploy.sh                       # 宿主端口改为 8080
  UPSTREAM_DIR=/srv/wb2api sh deploy.sh --skip-upstream
  NETWORK_MODE=host sh deploy.sh                    # 用宿主网络（此时通过 127.0.0.1 连上游）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local)   BUILD_LOCAL=1 ;;
    --no-pull) GIT_PULL=0 ;;
    --skip-upstream) SKIP_UPSTREAM=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 sh deploy.sh --help 查看用法）" ;;
  esac
  shift
done

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${DATA_DIR:-${ROOT_DIR}/data}"

echo ""
echo "========================================="
echo "  WorkBuddy Manager 部署"
echo "========================================="

# ── 1/6 环境预检 ───────────────────────────────────────────
step "1/6 环境预检"

command -v docker >/dev/null 2>&1 || die "未检测到 Docker，请先安装：https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || die "Docker 守护进程不可用（试试 sudo sh deploy.sh）"
ok "Docker $(docker --version | awk '{print $3}' | tr -d ,)"

COMPOSE=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  warn "未检测到 docker compose（自动安装上游时需要）"
fi

HAVE_CURL=1
command -v curl >/dev/null 2>&1 || { HAVE_CURL=0; warn "未检测到 curl，健康检查将跳过"; }

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${1}$"; then return 0; fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"${1}" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
  fi
  return 1
}

if port_in_use "$HOST_PORT"; then
  warn "宿主端口 ${HOST_PORT} 已被占用（可能是旧的 systemd 部署）"
  info "如需让位：systemctl stop workbuddy-web && systemctl disable workbuddy-web"
fi

# ── 2/6 上游 workbuddy2api ─────────────────────────────────
step "2/6 上游 workbuddy2api"

wait_upstream() {
  if [ "$HAVE_CURL" -ne 1 ]; then return 0; fi
  info "等待上游就绪…"
  for _ in $(seq 1 60); do
    if curl -sf -m 3 "http://127.0.0.1:${UPSTREAM_PORT}/healthz" >/dev/null 2>&1; then
      ok "上游已就绪（http://127.0.0.1:${UPSTREAM_PORT}）"
      return 0
    fi
    sleep 2
  done
  warn "等待上游超时：管理端仍能启动，但页面会提示上游不可用"
  warn "排查：cd ${UPSTREAM_DIR} && ${COMPOSE} logs --tail 50"
  return 0
}

if [ "$SKIP_UPSTREAM" -eq 1 ]; then
  info "按参数跳过（--skip-upstream），假定上游已就绪"
elif [ "$HAVE_CURL" -eq 1 ] && curl -sf -m 3 "http://127.0.0.1:${UPSTREAM_PORT}/healthz" >/dev/null 2>&1; then
  ok "上游已在运行（http://127.0.0.1:${UPSTREAM_PORT}）"
elif [ -f "${UPSTREAM_DIR}/config.json" ] || [ -f "${UPSTREAM_DIR}/docker-compose.yml" ]; then
  info "发现已有上游部署 ${UPSTREAM_DIR}，拉起容器（不改动配置与账号）"
  if [ -n "$COMPOSE" ] && ( cd "$UPSTREAM_DIR" && $COMPOSE up -d ); then
    wait_upstream
  else
    warn "启动失败，沿用现有状态；排查：cd ${UPSTREAM_DIR} && ${COMPOSE} logs"
  fi
else
  info "未检测到上游，安装到 ${UPSTREAM_DIR}"
  if [ -z "$COMPOSE" ]; then
    die "自动安装上游需要 docker compose；也可自行部署后用 --skip-upstream 跳过"
  fi
  command -v git >/dev/null 2>&1 || die "自动安装上游需要 git"

  if [ -d "${UPSTREAM_DIR}/.git" ]; then
    ( cd "$UPSTREAM_DIR" && git pull --ff-only ) || warn "git pull 失败，沿用现有代码"
  else
    git clone --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_DIR"
  fi

  cd "$UPSTREAM_DIR"

  # 已有 config.json 绝不覆盖（里面是 api_key 与账号状态）
  if [ ! -f config.json ]; then
    [ -f config.example.json ] || die "上游缺少 config.example.json，无法生成配置"
    cp config.example.json config.json
    python3 - <<'PYEOF' 2>/dev/null || true
import json, secrets
p = 'config.json'
cfg = json.load(open(p, encoding='utf-8'))
cfg['api_key'] = secrets.token_hex(16)
json.dump(cfg, open(p, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
PYEOF
    ok "已生成上游配置（api_key 随机）"
  fi

  # 上游容器以 uid 10001 运行，bind mount 的目录要归属同一 uid
  mkdir -p auths data
  chown -R 10001:10001 auths data 2>/dev/null || true

  info "构建并启动上游容器（首次构建需几分钟）"
  $COMPOSE up -d --build
  wait_upstream
fi

# ── 3/6 清理旧容器 ─────────────────────────────────────────
step "3/6 清理旧容器"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  info "停止容器 ${CONTAINER_NAME}（数据在挂载卷里，不会丢）"
  docker stop "$CONTAINER_NAME" >/dev/null
  docker rm "$CONTAINER_NAME" >/dev/null
  ok "旧容器已清理"
else
  echo "      - 未找到旧容器，跳过"
fi

# ── 4/6 准备镜像 ───────────────────────────────────────────
step "4/6 准备镜像"

if [ "$BUILD_LOCAL" -eq 1 ]; then
  cd "$ROOT_DIR"
  if [ "$GIT_PULL" -eq 1 ] && [ -d .git ]; then
    info "拉取最新代码"
    git pull --ff-only || warn "git pull 失败，沿用本地代码"
  fi
  if [ ! -f web/out/index.html ]; then
    if command -v npm >/dev/null 2>&1 && [ -f web/package.json ]; then
      info "构建前端产物 web/out"
      ( cd web && npm ci && npm run build:export )
    else
      die "缺少前端产物 web/out，且无 Node.js 可构建。请去掉 --local 直接用官方镜像，或下载 Release 包"
    fi
  fi
  info "构建镜像 ${LOCAL_IMAGE}（首次较慢，之后走层缓存）"
  docker build -t "$LOCAL_IMAGE" .
  IMAGE="$LOCAL_IMAGE"
else
  info "拉取官方镜像 ${IMAGE}"
  docker pull "$IMAGE" || die "拉取失败：${IMAGE}（网络不通时可用 --local 就地构建）"
fi

docker image prune -f >/dev/null 2>&1 || true
ok "镜像就绪：${IMAGE}"

# ── 5/6 启动容器 ───────────────────────────────────────────
step "5/6 启动容器"

cd "$ROOT_DIR"
mkdir -p "$DATA_DIR"
# 容器内以 uid 10001 运行，bind mount 目录属主不对会报 "unable to open database file"
if [ "$(id -u)" -eq 0 ]; then
  chown -R 10001:10001 "$DATA_DIR"
  if [ -d "${UPSTREAM_DIR}/auths" ]; then
    chown -R 10001:10001 "${UPSTREAM_DIR}/auths" 2>/dev/null || true
  fi
else
  warn "非 root，若容器起不来请执行一次：sudo chown -R 10001:10001 ${DATA_DIR}"
fi

# host 网络时容器里的 127.0.0.1 就是宿主；bridge 下靠 host-gateway 映射
if [ "$NETWORK_MODE" = "host" ]; then
  WB2API_BASE="http://127.0.0.1:${UPSTREAM_PORT}"
else
  WB2API_BASE="http://host.docker.internal:${UPSTREAM_PORT}"
fi

RUN_ARGS=(--name "$CONTAINER_NAME" --restart unless-stopped --network "$NETWORK_MODE")
if [ "$NETWORK_MODE" != "host" ]; then
  RUN_ARGS+=(--publish "${BIND_ADDR}:${HOST_PORT}:${CONTAINER_PORT}")
  RUN_ARGS+=(--add-host "host.docker.internal:host-gateway")
fi
RUN_ARGS+=(--memory "$MEMORY" --memory-swap "$MEMORY")
RUN_ARGS+=(--log-opt max-size=10m --log-opt max-file=3)
RUN_ARGS+=(
  -e TZ=Asia/Shanghai
  -e WB_RUN_MODE=docker
  -e WB_MANAGER_HOST=0.0.0.0
  -e WB_MANAGER_PORT="$CONTAINER_PORT"
  -e WB_TRUST_PROXY=1
  -e WB_ENABLE_DOCS=0
  -e WB2API_BASE="$WB2API_BASE"
  -e WB2API_CONTAINER="$UPSTREAM_CONTAINER"
  -e WB_UPSTREAM_DIR=/opt/workbuddy2api
  -e WB_AUTH_DIR=/opt/workbuddy2api/auths
  -e WB_UPSTREAM_CONFIG=/opt/workbuddy2api/config.json
  -e WB_DATA_DIR=/app/data
  -e WB_STATIC_DIR=/app/web/out
)
if [ -n "$ADMIN_PASSWORD" ]; then
  RUN_ARGS+=(-e WB_ADMIN_PASSWORD="$ADMIN_PASSWORD")
fi
RUN_ARGS+=(-v "${DATA_DIR}:/app/data")
if [ -d "$UPSTREAM_DIR" ]; then
  RUN_ARGS+=(-v "${UPSTREAM_DIR}:/opt/workbuddy2api")
else
  warn "未挂载上游目录 ${UPSTREAM_DIR}（不存在）—— 账号管理功能不可用"
fi
if [ "$MOUNT_DOCKER_SOCK" -eq 1 ] && [ -S /var/run/docker.sock ]; then
  RUN_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi
RUN_ARGS+=("$IMAGE")

docker run -d "${RUN_ARGS[@]}"
ok "容器已启动（内存上限 ${MEMORY}）"

# ── 6/6 验证 ───────────────────────────────────────────────
step "6/6 验证"

READY=0
if [ "$HAVE_CURL" -eq 1 ]; then
  info "等待服务就绪…"
  for _ in $(seq 1 30); do
    if curl -sf -m 3 "http://127.0.0.1:${HOST_PORT}/api/healthz" >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 2
  done
fi

if [ "$READY" -eq 1 ]; then
  ok "管理端已就绪：http://127.0.0.1:${HOST_PORT}"
  UPSTREAM_STATE="$(curl -s -m 5 "http://127.0.0.1:${HOST_PORT}/healthz" 2>/dev/null || true)"
  if [ -n "$UPSTREAM_STATE" ]; then
    info "上游连通性：${UPSTREAM_STATE}"
  fi
else
  warn "服务暂未响应，查看日志：docker logs -n 50 ${CONTAINER_NAME}"
fi

cat <<EOF

  ┌──────────────────────────────────────────────────────┐
  │  部署完成                                            │
  └──────────────────────────────────────────────────────┘

  管理端      http://127.0.0.1:${HOST_PORT}   （${BIND_ADDR} 监听）
  上游        http://127.0.0.1:${UPSTREAM_PORT}   （workbuddy2api）
  容器名称    ${CONTAINER_NAME}
  镜像        ${IMAGE}
  数据目录    ${DATA_DIR}
EOF

if [ -n "$ADMIN_PASSWORD" ]; then
  echo ""
  echo "  登录：admin / 你设置的 WB_ADMIN_PASSWORD"
else
  echo ""
  echo "  初始管理员密码（仅首次启动生成）："
  echo "    docker logs ${CONTAINER_NAME} 2>&1 | grep -A3 '初始管理员'"
fi

cat <<EOF

  下一步：
    1. 浏览器打开管理端（公网访问请先配 HTTPS 反向代理，见 deploy/README.md）
    2. 「账号」→「添加账号」扫码纳管，之后自动签到
    3. 「密钥」→「新建密钥」，用 OpenAI SDK 指向 http://<你的域名>/v1

  常用命令：
    docker logs -f ${CONTAINER_NAME}               # 管理端日志
    docker restart ${CONTAINER_NAME}               # 重启管理端
    cd ${UPSTREAM_DIR} && ${COMPOSE:-docker compose} logs -f   # 上游日志
    sh deploy.sh                                   # 再次执行 = 更新到最新版

EOF

docker ps --filter "name=${CONTAINER_NAME}" --format "ID: {{.ID}}  状态: {{.Status}}"
echo ""
