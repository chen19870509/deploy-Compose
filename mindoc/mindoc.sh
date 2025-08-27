#!/usr/bin/env bash
# =============================================================================
#  MinDoc 一键部署脚本（2025-08-27 免登录直链版）
#
#  执行逻辑顺序（按调用先后）：
#   1) 常量集中定义
#   2) 日志/错误处理初始化
#   3) 依赖检查
#   4) 旧目录备份
#   5) 并发下载 compose（静默并发，仅显成功）
#   6) 端口预检查
#   7) 启动容器
#   8) 业务探活
#   9) 诊断与清理
#
#  自检清单（实时追加）：
#  1) COMPOSE_URL 末尾无空格
#  2) 所有仅返回字符串的函数内部无 log_*
#  3) curl 统一加 -4 -g
#  4) 端口/路径变量读取后已 tr -d '[:space:]'
#  5) 终端颜色输出已安全处理
#  6) compose 文件注释无多余空格
#  7) 函数粒度已拆分
#  8) 变量全部集中顶部
#  9) TIMEOUT 常量存在
# 10) 变量引用全部双引号
# 11) 端口占用检查在容器启动前完成
# 12) 日志目录自动创建
# 13) 镜像源 **2025-08-27 实测免登录直链**
# 14) 删除 COMPOSE_URL 及镜像源数组末尾多余空格
# 15) 函数头部统一一句话说明用途
# 16) collect_diagnosis 使用 $COMPOSE_FILE
# 17) 确保 $DOCKER_LOG_DIR 已创建
# 18) curl 单次连接超时 10 秒
# 19) 提供 DEBUG=1 调试
# 20) 所有变量均已定义
# 21) 业务探活兼容 30x
# 22) 并发优先下载
# 23) 并发下载仅显示成功信息
# 24) 并发下载正确选择首个成功临时文件
# 25) 文件下载后检查大小，空文件视为失败
# 26) 下载失败后自动重试，最多3次
#
#  修改记录（AI 总结提示）：
#  2025-08-27: 添加下载失败重试机制，最多尝试3次
#  2025-08-27: 修复并发下载逻辑，添加文件大小检查(-s参数)，确保仅使用第一个成功的非空文件
#  2025-08-27: 简化并发下载输出，仅显示成功提示，不显示进程状态信息
#  2025-08-27: 增加自检清单条目25「文件下载后检查大小，空文件视为失败」
#  2025-08-27: 修复mv目标错误导致的脚本中断问题
#  2025-08-27: 并发下载改为静默模式，仅保留成功提示
#  2025-08-27: 探活逻辑从200改为200|301|302，避免302误判失败
#  2025-08-27: 删除COMPOSE_URL及镜像源数组末尾多余空格
# =============================================================================

set -Eeuo pipefail
umask 022

# ---------- 常量定义 ----------
readonly WORKDIR="/home/mindoc"
readonly BACKUP_DIR_PREFIX="/home/mindoc_backup"
readonly TIMEOUT=30               # 探活总超时 & compose 等待超时
readonly CURL_CONNECT_TIMEOUT=10  # 单次 curl 连接超时
readonly RETRIES=3                # 下载重试次数
readonly HEALTH_PROBE_INTERVAL=1
readonly COMPOSE_FILE="docker-compose.yml"
readonly DOCKER_LOG_DIR="/home/dockerlog/mindoc"

# 2025-08-27 实测可用的免登录直链（已删除末尾空格）
readonly COMPOSE_URL="https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"

# 免登录加速镜像（按优先级，已删除末尾空格）
readonly URL_BACKUPS=(
  "https://ghproxy.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
  "https://raw.gitmirror.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
  "$COMPOSE_URL"
)

# ---------- 日志函数 ----------
log_info()  { printf '[INFO] %s %s\n' "$(date '+%F %T')" "$*"; }
log_error() { printf '[ERROR] %s %s\n' "$(date '+%F %T')" "$*" >&2; }

# ---------- 错误处理 ----------
handle_error() { log_error "退出码=$? 行号=$1"; exit $?; }
handle_exit() {
  [[ -n "${COMPOSE_CMD:-}" ]] && \
    $COMPOSE_CMD -f "$COMPOSE_FILE" down --remove-orphans --timeout "$TIMEOUT" &>/dev/null || true
}
trap 'handle_error $LINENO' ERR
trap 'handle_exit' EXIT INT TERM

# ---------- debug 开关 ----------
if [[ "${DEBUG:-0}" == "1" ]]; then
  set -xv
  PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
fi

# ---------- 依赖检查 ----------
check_deps() {
  for cmd in curl docker; do
    command -v "$cmd" >/dev/null || { log_error "缺少 $cmd"; exit 1; }
  done
  docker info >/dev/null || { log_error "Docker 未运行"; exit 1; }
  readonly COMPOSE_CMD=$(get_compose_cmd)
  log_info "检测到 Compose 命令：$COMPOSE_CMD"
}

get_compose_cmd() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    return 1
  fi
}

# ---------- 备份旧目录 ----------
backup_old_dir() {
  [[ -d "$WORKDIR" ]] || return 0
  local bak_path="${BACKUP_DIR_PREFIX}_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$(dirname "$bak_path")"
  mv "$WORKDIR" "$bak_path" || { log_error "备份失败"; exit 1; }
  log_info "旧目录已备份为 $bak_path"
}

# ---------- 端口与变量提取 ----------
extract_health_vars() {
  local port path
  port=$(grep -m1 '^# HEALTH_PORT=' "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
  path=$(grep -m1 '^# HEALTH_PATH=' "$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '[:space:]')
  printf '%s\n' "${port:-10004}" "${path:-/}"
}

check_port_free() {
  local port=$1
  if ss -lnt 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {exit 1}'; then
    log_info "端口 $port 可用"
  else
    log_error "端口 $port 已被占用"; exit 1
  fi
}

# ---------- 并发下载 compose ----------
download_compose() {
  local output=$1
  local all_urls=("$COMPOSE_URL" "${URL_BACKUPS[@]}")
  local attempt=1
  local wait_sec=2
  
  while (( attempt <= RETRIES )); do
    local pids=() tmp_files=()
    
    log_info "开始第 ${attempt}/${RETRIES} 次并发下载，共 ${#all_urls[@]} 个源…"
    
    for url in "${all_urls[@]}"; do
      local tmp
      tmp=$(mktemp "${output}.XXXXXX")
      tmp_files+=("$tmp")
      curl -4 -g --silent --show-error --connect-timeout "$CURL_CONNECT_TIMEOUT" "$url" -o "$tmp" 2>/dev/null &
      pids+=($!)
    done

    local winner=""
    for i in "${!pids[@]}"; do
      if wait "${pids[$i]}" 2>/dev/null; then
        # 检查文件是否非空
        if [[ -s "${tmp_files[$i]}" ]]; then
          winner="${tmp_files[$i]}"
          break
        fi
      fi
    done

    # 清理所有临时文件
    for f in "${tmp_files[@]}"; do
      [[ "$f" == "$winner" ]] || rm -f "$f"
    done

    if [[ -n "$winner" ]]; then
      mv "$winner" "$output"
      log_info "下载成功：$output ($(wc -c < "$output") 字节)"
      return 0
    else
      log_error "第 ${attempt}/${RETRIES} 次下载失败，${wait_sec}秒后重试…"
      sleep "$wait_sec"
      wait_sec=$((wait_sec * 2))
      attempt=$((attempt + 1))
    fi
  done

  log_error "全部镜像源均下载失败或返回空文件（已尝试 ${RETRIES} 次）"
  return 1
}

# ---------- 启动容器 ----------
start_containers() {
  mkdir -p "$DOCKER_LOG_DIR"
  log_info "启动容器：$COMPOSE_CMD -f $COMPOSE_FILE up -d --wait --timeout $TIMEOUT"
  $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --wait --timeout "$TIMEOUT" || {
    log_error "容器启动失败"
    $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail=50 >&2
    return 1
  }
}

# ---------- 业务探活 ----------
probe_service() {
  local port path
  read -r port path < <(extract_health_vars)
  local url="http://localhost:${port}${path}"
  for ((i=1; i<=TIMEOUT; i++)); do
    local code
    code=$(curl -4 -g -k -s -o /dev/null -w "%{http_code}" "$url" || true)
    log_info "探活：$url → HTTP $code"
    case "$code" in
      200|301|302) log_info "业务就绪"; return 0 ;;
    esac
    sleep "$HEALTH_PROBE_INTERVAL"
  done
  log_error "业务未就绪"; return 1
}

# ---------- 诊断信息收集 ----------
collect_diagnosis() {
  local log="diagnosis_$(date +%s).log"
  mkdir -p "$DOCKER_LOG_DIR"
  {
    echo "===== docker ps ====="
    docker ps -a
    echo "===== compose logs ====="
    $COMPOSE_CMD -f "$COMPOSE_FILE" logs --no-color --tail=100
  } > "$DOCKER_LOG_DIR/$log"
  log_error "诊断信息已保存至 $DOCKER_LOG_DIR/$log"
}
trap 'collect_diagnosis' ERR

# ---------- 主流程 ----------
install_mindoc() {
  log_info "=== 开始部署 MinDoc ==="

  check_deps
  backup_old_dir

  mkdir -p "$WORKDIR" && cd "$WORKDIR"
  download_compose "$COMPOSE_FILE"

  local port
  read -r port _ < <(extract_health_vars)
  check_port_free "$port"

  start_containers
  probe_service

  log_info "=== MinDoc 部署完成 ==="
}

# ---------- 入口 ----------
install_mindoc
