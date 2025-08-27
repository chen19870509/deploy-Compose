#!/usr/bin/env bash
# =============================================================================
#  MinDoc 一键部署脚本（统一风格优化版）
#  支持重复运行，保护持久化数据
#  版本：2.8 - 镜像源精简优化版
#  最后更新：2025-08-28
# =============================================================================

# ---------- 变更记录 ----------
# 版本 2.8 (2025-08-28)
#   - 移除不可达镜像源: github.com.cnpmjs.org, hub.fastgit.org
#   - 优化网络诊断域名列表
#   - 保持高成功率源优先级
#
# 版本 2.7 (2025-08-28) 
#   - 添加下载成功率统计功能
#   - 实现智能超时策略（CDN 15s, GitHub 12s, 其他 10s）
#   - 增加源间请求间隔（1秒）
#   - 添加历史成功率展示
#
# 版本 2.6 (2025-08-28)
#   - 基于历史成功率优化镜像源优先级
#   - 新增镜像源: ghproxy.net, mirror.ghproxy.com, gcore.jsdelivr.net
#   - 增强网络诊断功能
#   - 添加多级重试机制
#
# 版本 2.5 (2025-08-28)
#   - 添加网络诊断功能
#   - 优化错误处理和日志输出
#   - 改进下载重试逻辑
#   - 增加手动下载指导
#
# 版本 2.4 (2025-08-28)
#   - 采用函数式错误检查替代 set -e
#   - 统一 run_command 和 run_function 执行方式
#   - 增加文件夹存在性预检规范
#   - 优化环境检测逻辑
#
# 版本 2.3 (2025-08-28)
#   - 移除脱敏处理要求，简化日志系统
#   - 增加文件夹存在性预检规范
#   - 完善目录权限检查要求
#   - 优化代码结构模板
#
# 版本 2.2 (2025-08-28)
#   - 增加环境检测规范
#   - 完善错误处理策略
#   - 统一日志输出格式
#   - 优化代码组织结构
#
# 版本 2.1 (2025-08-28)
#   - 初始统一风格版本
#   - 建立常量定义规范
#   - 实现函数式错误检查
#   - 统一变量命名规范

# ---------- 常量定义 ----------
readonly APP_NAME="mindoc"
readonly WORKDIR_ROOT="/home/mindoc"
readonly BACKUP_DIR_ROOT="/home/mindoc_backup"
readonly LOG_DIR="/home/mindoc_logs"
readonly LOG_FILE="${LOG_DIR}/install.log"
readonly TIMEOUT_SECONDS=30
readonly CURL_CONNECT_TIMEOUT=10
readonly MAX_DOWNLOAD_RETRIES=3
readonly HEALTH_PROBE_INTERVAL=1
readonly COMPOSE_FILE_NAME="docker-compose.yml"
readonly DOCKER_LOG_DIR="/home/dockerlog/mindoc"
readonly INSTALL_LOCK_FILE="/tmp/mindoc_install.lock"
readonly DATA_VOLUME_NAME="mindoc_data"
readonly STATS_FILE="/tmp/mindoc_download_stats.txt"

# 2025年优化加速镜像源列表（移除不可达源，按成功率和速度排序）
readonly URL_BACKUPS=(
    # 高成功率源（优先尝试）- 基于历史数据
    "https://gh-proxy.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    "https://ghproxy.net/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    "https://mirror.ghproxy.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    
    # CDN加速源
    "https://cdn.jsdelivr.net/gh/chen19870509/deploy-Compose@main/mindoc/mindoc_config.yaml"
    "https://gcore.jsdelivr.net/gh/chen19870509/deploy-Compose@main/mindoc/mindoc_config.yaml"
    
    # 其他代理服务
    "https://gh.api.99988866.xyz/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    "https://g.ioiox.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    
    # 原始地址（备用）
    "https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
)

# ---------- 日志函数 ----------
# 记录信息日志
log_info() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $*" | tee -a "$LOG_FILE"
}

# 记录错误日志
log_error() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $*" | tee -a "$LOG_FILE"
}

# 记录警告日志
log_warning() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING - $*" | tee -a "$LOG_FILE"
}

# 记录成功日志
log_success() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SUCCESS - $*" | tee -a "$LOG_FILE"
}

# ---------- 错误处理 ----------
# 执行系统命令
run_command() {
    log_info "执行命令: $*"
    if ! command "$@"; then
        log_error "命令执行失败: $*"
        return 1
    fi
    return 0
}

# 执行脚本函数
run_function() {
    local func_name="$1"
    shift
    
    log_info "执行函数: $func_name $*"
    if ! $func_name "$@"; then
        local exit_code=$?
        if [[ $exit_code -eq 2 ]] && [[ "$func_name" == "check_installation_status" ]]; then
            # 特殊退出码，表示服务已运行，不是错误
            log_info "服务状态检查完成: MinDoc 已在运行中，跳过部署"
            return 2
        else
            log_error "函数执行失败: $func_name $* (退出码: $exit_code)"
            return 1
        fi
    fi
    return 0
}

# 主错误处理函数
handle_error() {
    local line_number="$1"
    log_error "脚本执行失败，位置: $line_number"
    run_function collect_diagnosis
    exit 1
}

# 清理函数
handle_exit() {
    run_command rm -f "$INSTALL_LOCK_FILE" 2>/dev/null || true
}

# ---------- 统计功能 ----------
# 下载成功率统计
track_download_success() {
    local source="$1"
    
    # 记录成功下载的源和时间戳
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$source" >> "$STATS_FILE"
    
    # 保持文件大小合理（最近100条记录）
    if [[ $(wc -l < "$STATS_FILE") -gt 100 ]]; then
        tail -n 50 "$STATS_FILE" > "${STATS_FILE}.tmp"
        mv "${STATS_FILE}.tmp" "$STATS_FILE"
    fi
}

# 显示下载统计信息
show_download_stats() {
    if [[ -f "$STATS_FILE" ]]; then
        log_info "=== 下载成功率统计 ==="
        awk -F, '{
            count[$2]++
            total++
        } END {
            for (source in count) {
                printf "%-25s: %d次 (%.1f%%)\n", source, count[source], (count[source]/total)*100
            }
        }' "$STATS_FILE" | tee -a "$LOG_FILE"
    else
        log_info "暂无下载统计信息"
    fi
}

# ---------- 环境检测 ----------
# 检测系统环境
detect_environment() {
    log_info "=== 环境检测 ==="
    log_info "系统架构: $(uname -m)"
    log_info "操作系统: $(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' | head -1)"
    log_info "内存总量: $(free -h | awk '/^Mem:/ {print $2}')"
    
    # 改进的磁盘空间检查
    local disk_info
    if [[ -d "$WORKDIR_ROOT" ]]; then
        disk_info=$(df -h "$WORKDIR_ROOT" | awk 'NR==2 {print $4 " (工作目录)"}')
    else
        disk_info=$(df -h / | awk 'NR==2 {print $4 " (根分区)"}')
    fi
    log_info "磁盘可用空间: $disk_info"
    
    if curl -4 -m 5 -s http://httpbin.org/get >/dev/null; then
        log_info "网络连通性: 正常"
    else
        log_warning "网络连通性: 受限"
    fi
}

# ---------- 网络诊断 ----------
# 网络诊断函数
network_diagnosis() {
    log_info "=== 网络诊断 ==="
    
    # 测试所有镜像源域名的可达性（移除不可达的源）
    local test_domains=(
        "gh-proxy.com"          # 高优先级
        "ghproxy.net"           # 高优先级  
        "mirror.ghproxy.com"    # 高优先级
        "cdn.jsdelivr.net"      # CDN加速
        "gcore.jsdelivr.net"    # CDN备用
        "gh.api.99988866.xyz"   # 代理服务
        "g.ioiox.com"           # 代理服务
        "raw.githubusercontent.com" # 原始地址
    )
    
    for domain in "${test_domains[@]}"; do
        if ping -c 2 -W 2 "$domain" &>/dev/null; then
            log_info "✅ 网络可达: $domain"
        else
            log_warning "⚠️  网络不可达: $domain"
        fi
    done
    
    # 显示历史成功率统计
    show_download_stats
}

# ---------- 文件夹存在性预检 ----------
# 检查目录存在性和权限
check_directories() {
    log_info "=== 文件夹存在性预检 ==="
    local dirs=("$WORKDIR_ROOT" "$LOG_DIR" "$(dirname "$BACKUP_DIR_ROOT")" "$DOCKER_LOG_DIR" "/tmp")
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            run_command mkdir -p "$dir" || return 1
            log_info "创建目录: $dir"
        fi
        if [[ ! -w "$dir" ]]; then
            log_error "目录无写权限: $dir"
            return 1
        fi
        log_info "目录可访问: $dir"
    done
    return 0
}

# ---------- 依赖检查 ----------
# 检查系统依赖
check_dependencies() {
    log_info "=== 依赖检查 ==="
    local deps=("curl" "docker")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null; then
            log_error "依赖缺失: $dep"
            return 1
        fi
        log_info "依赖存在: $dep"
    done
    
    if ! docker info >/dev/null; then
        log_error "Docker 服务未运行"
        return 1
    fi
    log_info "Docker 服务: 运行中"
    
    return 0
}

# 获取 compose 命令
get_compose_cmd() {
    if docker compose version &>/dev/null; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    else
        log_error "未找到 docker compose"
        return 1
    fi
}

# ---------- 安装状态检查 ----------
# 检查安装状态
check_installation_status() {
    if [[ -f "$INSTALL_LOCK_FILE" ]]; then
        log_error "检测到正在进行的安装进程: $INSTALL_LOCK_FILE"
        return 1
    fi
    run_command touch "$INSTALL_LOCK_FILE"
    
    if check_service_running; then
        log_info "MinDoc 已在运行中，无需重新安装"
        log_info "如需要重新部署，请先停止服务: cd $WORKDIR_ROOT && docker compose down"
        log_info "然后删除锁文件: rm -f $INSTALL_LOCK_FILE"
        return 2  # 使用特殊的退出码表示"服务已运行"
    fi
    return 0
}

# 检查服务运行状态
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
# 备份现有数据
backup_existing_data() {
    if docker volume inspect "$DATA_VOLUME_NAME" &>/dev/null; then
        local backup_path="${BACKUP_DIR_ROOT}_data_$(date +%Y%m%d_%H%M%S)"
        run_command mkdir -p "$backup_path"
        
        log_info "备份数据卷: $DATA_VOLUME_NAME"
        docker run --rm -v "${DATA_VOLUME_NAME}:/source" -v "${backup_path}:/backup" \
            alpine tar czf /backup/data_backup.tar.gz -C /source . || {
            log_error "数据卷备份失败"
            return 1
        }
    fi
    return 0
}

# 恢复数据
restore_data() {
    local backup_path=$(find "${BACKUP_DIR_ROOT}_data_"* -name "data_backup.tar.gz" 2>/dev/null | sort -r | head -1)
    
    if [[ -n "$backup_path" ]] && [[ -f "$backup_path" ]]; then
        log_info "恢复数据"
        docker volume create "$DATA_VOLUME_NAME" &>/dev/null || true
        docker run --rm -v "${DATA_VOLUME_NAME}:/target" -v "$(dirname "$backup_path"):/backup" \
            alpine sh -c "tar xzf /backup/data_backup.tar.gz -C /target && chmod -R 777 /target" || {
            log_error "数据恢复失败"
            return 1
        }
    fi
    return 0
}

# ---------- 备份旧配置 ----------
# 备份旧配置文件
backup_old_config() {
    [[ -d "$WORKDIR_ROOT" ]] || return 0
    local bak_path="${BACKUP_DIR_ROOT}_config_$(date +%Y%m%d_%H%M%S)"
    run_command mkdir -p "$(dirname "$bak_path")"
    run_command cp -ra "$WORKDIR_ROOT" "$bak_path" || {
        log_error "配置备份失败"
        return 1
    }
    log_info "配置已备份: $bak_path"
    return 0
}

# ---------- 端口与变量提取 ----------
# 提取健康检查变量
extract_health_vars() {
    local port path
    if [[ ! -f "$WORKDIR_ROOT/$COMPOSE_FILE_NAME" ]]; then
        printf '%s\n' "10004" "/"
        return 0
    fi
    
    port=$(grep -m1 '^# HEALTH_PORT=' "$WORKDIR_ROOT/$COMPOSE_FILE_NAME" | cut -d'=' -f2 | tr -d '[:space:]' || echo "10004")
    path=$(grep -m1 '^# HEALTH_PATH=' "$WORKDIR_ROOT/$COMPOSE_FILE_NAME" | cut -d'=' -f2 | tr -d '[:space:]' || echo "/")
    printf '%s\n' "${port}" "${path}"
}

# 检查端口是否空闲
check_port_free() {
    local port=$1
    if ss -lnt 2>/dev/null | awk -v p="$port" '$4 ~ ":"p"$" {exit 1}'; then
        log_info "端口 $port 可用"
    else
        log_error "端口 $port 已被占用"
        return 1
    fi
    return 0
}

# ---------- 下载 compose ----------
# 增强的下载函数 with 智能重试策略
download_compose() {
    local output="$1"
    local all_urls=("${URL_BACKUPS[@]}")
    local attempt=1
    local max_network_retries=2
    
    # 网络重试循环
    for ((network_retry=1; network_retry<=max_network_retries; network_retry++)); do
        log_info "网络尝试 ${network_retry}/${max_network_retries}"
        
        while (( attempt <= MAX_DOWNLOAD_RETRIES )); do
            log_info "下载尝试 ${attempt}/${MAX_DOWNLOAD_RETRIES}"
            
            for url in "${all_urls[@]}"; do
                local domain=$(echo "$url" | awk -F/ '{print $3}')
                log_info "尝试从: $domain"
                
                # 根据域名类型设置不同的超时时间
                local timeout=$CURL_CONNECT_TIMEOUT
                if [[ "$domain" == *"jsdelivr.net"* ]]; then
                    timeout=15  # CDN服务超时稍长
                elif [[ "$domain" == *"github.com"* ]]; then
                    timeout=12  # GitHub原始地址超时稍长
                fi
                
                if curl -4 -g --silent --show-error --connect-timeout "$timeout" "$url" -o "$output.tmp" 2>/dev/null; then
                    if [[ -s "$output.tmp" ]]; then
                        run_command mv "$output.tmp" "$output"
                        local file_size=$(wc -c < "$output")
                        log_info "下载成功: ${file_size} 字节 (来源: $domain)"
                        
                        # 记录成功源用于统计
                        track_download_success "$domain"
                        return 0
                    else
                        log_warning "下载文件为空: $domain"
                        run_command rm -f "$output.tmp"
                    fi
                else
                    log_warning "下载失败: $domain"
                fi
                
                # 在同一个尝试周期内，不同源之间短暂间隔
                sleep 1
            done
            
            attempt=$((attempt + 1))
            sleep 3  # 适当增加重试间隔
        done
        
        # 一轮尝试失败后等待更长时间
        if (( network_retry < max_network_retries )); then
            log_warning "网络下载失败，等待15秒后重试..."
            sleep 15
            attempt=1  # 重置尝试计数器
        fi
    done
    
    log_error "所有镜像源下载失败，请检查网络连接"
    log_error "可以手动下载并重试:"
    log_error "  cd /home/mindoc"
    log_error "  # 使用高成功率源"
    log_error "  curl -O https://gh-proxy.com/https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
    log_error "  # 或者使用CDN加速"
    log_error "  curl -O https://cdn.jsdelivr.net/gh/chen19870509/deploy-Compose@main/mindoc/mindoc_config.yaml"
    log_error "  mv mindoc_config.yaml docker-compose.yml"
    log_error "然后重新运行脚本"
    return 1
}

# ---------- 启动容器 ----------
# 启动 Docker 容器
start_containers() {
    local original_dir=$(pwd)
    
    run_command cd "$WORKDIR_ROOT" || return 1
    
    # 检查文件是否存在
    if [[ ! -f "$COMPOSE_FILE_NAME" ]]; then
        log_error "配置文件不存在: $COMPOSE_FILE_NAME"
        return 1
    fi
    
    # 获取 compose 命令
    local compose_cmd
    compose_cmd=$(get_compose_cmd) || return 1
    
    log_info "启动容器..."
    run_command $compose_cmd -f "$COMPOSE_FILE_NAME" up -d --wait --timeout "$TIMEOUT_SECONDS" || {
        log_error "容器启动失败"
        run_command $compose_cmd -f "$COMPOSE_FILE_NAME" logs --tail=20
        run_command cd "$original_dir"
        return 1
    }
    
    run_command cd "$original_dir"
    return 0
}

# ---------- 业务探活 ----------
# 服务健康检查
probe_service() {
    local port path
    read -r port path < <(extract_health_vars)
    local url="http://localhost:${port}${path}"
    
    log_info "健康检查中..."
    for ((i=1; i<=TIMEOUT_SECONDS; i++)); do
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
# 收集诊断信息
collect_diagnosis() {
    local log_file="${DOCKER_LOG_DIR}/diagnosis_$(date +%s).log"
    
    {
        echo "===== 系统状态 ====="
        docker ps -a
        echo ""
        echo "===== 数据卷信息 ====="
        docker volume ls | grep mindoc || true
        echo ""
        echo "===== 服务日志 ====="
        if [[ -f "$WORKDIR_ROOT/$COMPOSE_FILE_NAME" ]]; then
            local compose_cmd
            compose_cmd=$(get_compose_cmd 2>/dev/null) || exit 0
            (cd "$WORKDIR_ROOT" && $compose_cmd -f "$COMPOSE_FILE_NAME" logs --tail=50 2>/dev/null || true)
        fi
        echo ""
        echo "===== 网络诊断 ====="
        network_diagnosis
    } > "$log_file" 2>&1
    
    log_info "诊断信息: $log_file"
}

# ---------- 主流程 ----------
# 主安装函数
install_mindoc() {
    run_function check_directories || exit 1
    run_function detect_environment
    run_function network_diagnosis
    run_function check_dependencies || exit 1
    
    # 特殊处理安装状态检查
    if ! run_function check_installation_status; then
        local status_code=$?
        if [[ $status_code -eq 2 ]]; then
            # 服务已运行，正常退出
            log_info "安装流程终止: 服务已在运行中"
            exit 0
        else
            # 其他错误，异常退出
            exit 1
        fi
    fi
    
    run_function backup_existing_data
    run_function backup_old_config
    
    run_command rm -rf "$WORKDIR_ROOT"
    run_command mkdir -p "$WORKDIR_ROOT" && run_command cd "$WORKDIR_ROOT" || exit 1
    
    # 下载失败时立即退出
    run_function download_compose "$COMPOSE_FILE_NAME" || {
        log_error "无法下载配置文件，请检查网络连接"
        exit 1
    }
    
    run_function restore_data

    local port
    read -r port _ < <(extract_health_vars)
    run_function check_port_free "$port"
    run_function start_containers || exit 1
    run_function probe_service || exit 1

    log_success "MinDoc 部署完成"
    local path
    read -r port path < <(extract_health_vars)
    log_info "访问地址: http://localhost:${port}"
}

# ---------- 入口 ----------
# 设置错误处理陷阱
trap 'handle_error $LINENO' ERR
trap 'handle_exit' EXIT INT TERM

# 执行主函数
install_mindoc "$@"
