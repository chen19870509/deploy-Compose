#!/usr/bin/env bash
# =============================================================================
#  MinDoc 一键部署脚本（2025-08-28 精简日志版）
#  支持重复运行，保护持久化数据
# =============================================================================

set -Eeuo pipefail
umask 022

# ---------- 常量定义 ----------
readonly WORKDIR="/home/mindoc"
readonly BACKUP_DIR_PREFIX="/home/mindoc_backup"
readonly TIMEOUT=30
readonly CURL_CONNECT_TIMEOUT=10
readonly RETRIES=3
readonly HEALTH_PROBE_INTERVAL=1
readonly COMPOSE_FILE="docker-compose.yml"
readonly DOCKER_LOG_DIR="/home/dockerlog/mindoc"
readonly INSTALL_LOCK_FILE="/tmp/mindoc_install.lock"
readonly DATA_VOLUME_NAME="mindoc_data"

# 镜像源
readonly COMPOSE_URL="https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
readonly URL_BACKUPS=(
  "https://ghproxy.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
  "https://raw.gitmirror.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
  "$COMPOSE_URL"
)

# ---------- 日志函数 ----------
log_info()  { printf '[INFO] %s %s\n' "$(date '+%F %T')" "$*"; }
log_error() { printf '[ERROR] %s %s\n' "$(date '+%F %T')" "$*" >&2; }

# ---------- 错误处理 ----------
handle_error() { 
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "脚本执行失败，退出码: $exit_code"
        collect_diagnosis
    fi
    exit $exit_code
}

handle_exit() {
    rm -f "$INSTALL_LOCK_FILE"
}

trap 'handle_error $LINENO' ERR
trap 'handle_exit' EXIT INT TERM

# ---------- 安装状态检查 ----------
check_installation_status() {
    if [[ -f "$INSTALL_LOCK_FILE" ]]; then
        log_error "检测到正在进行的安装进程: $INSTALL_LOCK_FILE"
        exit 1
    fi
    touch "$INSTALL_LOCK_FILE"
    
    if check_service_running; then
        log_info "MinDoc 已在运行中，无需重新安装"
        exit 0
    fi
}

check_service_running() {
    local port
    read -r port _ < <(extract_health_vars)
    
    if ss -lnt 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {exit 0}'; then
        local code
        code=$(curl -4 -g -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "http://localhost:${port}/" || true)
        if [[ "$code" =~ ^(200|301|302)$ ]]; then
            return 0
        fi
    fi
    return 1
}

# ---------- 数据持久化处理 ----------
backup_existing_data() {
    if docker volume inspect "$DATA_VOLUME_NAME" &>/dev/null; then
        local backup_path="${BACKUP_DIR_PREFIX}_data_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_path"
        
        log_info "备份数据卷: $DATA_VOLUME_NAME"
        docker run --rm -v "${DATA_VOLUME_NAME}:/source" -v "${backup_path}:/backup" \
            alpine tar czf /backup/data_backup.tar.gz -C /source . || {
            log_error "数据卷备份失败"
            return 1
        }
    fi
}

restore_data() {
    local backup_path=$(find "${BACKUP_DIR_PREFIX}_data_"* -name "data_backup.tar.gz" 2>/dev/null | sort -r | head -1)
    
    if [[ -n "$backup_path" ]] && [[ -f "$backup_path" ]]; then
        log_info "恢复数据"
        docker volume create "$DATA_VOLUME_NAME" &>/dev/null || true
        docker run --rm -v "${DATA_VOLUME_NAME}:/target" -v "$(dirname "$backup_path"):/backup" \
            alpine sh -c "tar xzf /backup/data_backup.tar.gz -C /target && chmod -R 777 /target" || {
            log_error "数据恢复失败"
            return 1
        }
    fi
}

# ---------- 依赖检查 ----------
check_deps() {
  for cmd in curl docker; do
    command -v "$cmd" >/dev/null || { log_error "缺少 $cmd"; exit 1; }
  done
  docker info >/dev/null || { log_error "Docker 未运行"; exit 1; }
  readonly COMPOSE_CMD=$(get_compose_cmd)
  log_info "Compose 命令: $COMPOSE_CMD"
}

get_compose_cmd() {
  if docker compose version &>/dev/null; then
    echo "docker compose"
  elif command -v docker-compose &>/dev/null; then
    echo "docker-compose"
  else
    log_error "未找到 docker compose"
    exit 1
  fi
}

# ---------- 备份旧配置 ----------
backup_old_config() {
  [[ -d "$WORKDIR" ]] || return 0
  local bak_path="${BACKUP_DIR_PREFIX}_config_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$(dirname "$bak_path")"
  cp -ra "$WORKDIR" "$bak_path" || { log_error "配置备份失败"; exit 1; }
  log_info "配置已备份: $bak_path"
}

# ---------- 端口与变量提取 ----------
extract_health_vars() {
  local port path
  if [[ ! -f "$WORKDIR/$COMPOSE_FILE" ]]; then
    printf '%s\n' "10004" "/"
    return 0
  fi
  
  port=$(grep -m1 '^# HEALTH_PORT=' "$WORKDIR/$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '[:space:]' || echo "10004")
  path=$(grep -m1 '^# HEALTH_PATH=' "$WORKDIR/$COMPOSE_FILE" | cut -d'=' -f2 | tr -d '[:space:]' || echo "/")
  printf '%s\n' "${port}" "${path}"
}

check_port_free() {
  local port=$1
  if ss -lnt 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {exit 1}'; then
    log_info "端口 $port 可用"
  else
    log_error "端口 $port 已被占用"
    exit 1
  fi
}

# ---------- 下载 compose ----------
download_compose() {
  local output=$1
  local all_urls=("${URL_BACKUPS[@]}")
  local attempt=1
  
  while (( attempt <= RETRIES )); do
    log_info "下载尝试 ${attempt}/${RETRIES}"
    
    for url in "${all_urls[@]}"; do
      if curl -4 -g --silent --show-error --connect-timeout "$CURL_CONNECT_TIMEOUT" "$url" -o "$output.tmp" 2>/dev/null; then
        if [[ -s "$output.tmp" ]]; then
          mv "$output.tmp" "$output"
          log_info "下载成功: $(wc -c < "$output") 字节"
          return 0
        fi
        rm -f "$output.tmp"
      fi
    done
    
    attempt=$((attempt + 1))
    sleep 2
  done
  
  log_error "下载失败"
  return 1
}

# ---------- 启动容器 ----------
start_containers() {
  mkdir -p "$DOCKER_LOG_DIR"
  local original_dir=$(pwd)
  
  cd "$WORKDIR" || { log_error "无法进入工作目录"; return 1; }
  
  log_info "启动容器..."
  $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --wait --timeout "$TIMEOUT" || {
    log_error "容器启动失败"
    $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail=20 >&2
    cd "$original_dir"
    return 1
  }
  
  cd "$original_dir"
}

# ---------- 业务探活 ----------
probe_service() {
  local port path
  read -r port path < <(extract_health_vars)
  local url="http://localhost:${port}${path}"
  
  log_info "健康检查中..."
  for ((i=1; i<=TIMEOUT; i++)); do
    local code
    code=$(curl -4 -g -k -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$url" || true)
    
    if [[ "$code" =~ ^(200|301|302)$ ]]; then
      log_info "服务就绪"
      return 0
    fi
    sleep "$HEALTH_PROBE_INTERVAL"
  done
  
  log_error "服务未就绪"
  return 1
}

# ---------- 诊断信息 ----------
collect_diagnosis() {
  local log="diagnosis_$(date +%s).log"
  mkdir -p "$DOCKER_LOG_DIR"
  {
    echo "===== 系统状态 ====="
    docker ps -a
    echo ""
    echo "===== 数据卷信息 ====="
    docker volume ls | grep mindoc || true
    echo ""
    echo "===== 服务日志 ====="
    if [[ -f "$WORKDIR/$COMPOSE_FILE" ]]; then
        (cd "$WORKDIR" && $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail=50 2>/dev/null || true)
    fi
  } > "$DOCKER_LOG_DIR/$log" 2>&1
  log_info "诊断信息: $DOCKER_LOG_DIR/$log"
}

# ---------- 主流程 ----------
install_mindoc() {
  log_info "开始部署 MinDoc"

  check_installation_status
  check_deps
  backup_existing_data
  backup_old_config
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR" && cd "$WORKDIR" || exit 1
  download_compose "$COMPOSE_FILE"
  restore_data

  local port
  read -r port _ < <(extract_health_vars)
  check_port_free "$port"
  start_containers
  probe_service

  log_info "MinDoc 部署完成"
  log_info "访问地址: http://localhost:${port}"
}

# ---------- 入口 ----------
install_mindoc "$@"
