#!/usr/bin/env bash
# ==============================================================================
# Mindoc 自动化部署脚本
# 描述: 自动下载并部署 Mindoc 文档管理系统
# 作者: AI Assistant
# 版本: 2.0
# ==============================================================================

# ------------------------------------------------------------------------------
# 配置区域 - 用户可以修改这些变量
# ------------------------------------------------------------------------------
readonly WORKDIR="/home/mindoc"
readonly COMPOSE_URL="https://raw.githubusercontent.com/chen19870509/deploy-Compose/main/mindoc/mindoc_config.yaml"
readonly COMPOSE_FILE="docker-compose.yml"
readonly TIMEOUT=30
readonly RETRIES=3
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 初始化设置
# ------------------------------------------------------------------------------
set -Eeuo pipefail  # 严格错误处理
umask 022          # 设置默认文件权限
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 颜色和样式定义
# ------------------------------------------------------------------------------
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[31m'
readonly COLOR_GREEN='\033[32m'
readonly COLOR_YELLOW='\033[33m'
readonly COLOR_BLUE='\033[34m'
readonly COLOR_CYAN='\033[36m'

readonly STYLE_BOLD='\033[1m'
readonly STYLE_UNDERLINE='\033[4m'
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 日志函数
# ------------------------------------------------------------------------------
log_header()   { echo -e "${STYLE_BOLD}${COLOR_CYAN}==>${COLOR_RESET}${STYLE_BOLD} $1${COLOR_RESET}"; }
log_success()  { echo -e "${COLOR_GREEN}✅ [SUCCESS]${COLOR_RESET} $(date '+%H:%M:%S') $1"; }
log_info()     { echo -e "${COLOR_BLUE}📋 [INFO]${COLOR_RESET}    $(date '+%H:%M:%S') $1"; }
log_warning()  { echo -e "${COLOR_YELLOW}⚠️  [WARNING]${COLOR_RESET} $(date '+%H:%M:%S') $1" >&2; }
log_error()    { echo -e "${COLOR_RED}❌ [ERROR]${COLOR_RESET}   $(date '+%H:%M:%S') $1" >&2; }
log_debug()    { [[ "${DEBUG:-false}" == "true" ]] && echo -e "${COLOR_CYAN}🐛 [DEBUG]${COLOR_RESET}   $(date '+%H:%M:%S') $1"; }

log_step()     { echo -e "\n${STYLE_BOLD}${COLOR_BLUE}▸${COLOR_RESET} ${STYLE_BOLD}$1${COLOR_RESET}"; }
log_substep()  { echo -e "  ${COLOR_CYAN}•${COLOR_RESET} $1"; }
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 错误处理函数
# ------------------------------------------------------------------------------
handle_error() {
    local errcode=$?
    local line=$1
    local command=${BASH_COMMAND}
    
    log_error "脚本执行失败!"
    log_error "退出码: $errcode"
    log_error "错误位置: 行号 $line"
    log_error "失败命令: $command"
    
    exit $errcode
}

handle_exit() {
    log_info "开始清理资源..."
    if docker compose down --remove-orphans --timeout $TIMEOUT 2>/dev/null; then
        log_success "容器清理完成"
    else
        log_warning "容器清理过程中出现警告（可能容器未运行）"
    fi
    log_info "脚本执行结束"
}

trap 'handle_error ${LINENO}' ERR
trap 'handle_exit' EXIT INT TERM
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 依赖检查函数
# ------------------------------------------------------------------------------
check_dependencies() {
    log_step "检查系统依赖"
    
    local -a required_deps=("curl" "docker")
    local -a missing_deps=()
    
    for dep in "${required_deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
            log_substep "缺失: $dep"
        else
            log_substep "已安装: $dep"
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要依赖: ${missing_deps[*]}"
        exit 1
    fi
    
    # 检查 Docker 守护进程
    if ! docker info &>/dev/null; then
        log_error "Docker 守护进程未运行"
        exit 1
    fi
    log_substep "Docker 守护进程: 运行中"
    
    # 检查 Docker Compose
    if get_compose_command &>/dev/null; then
        log_substep "Docker Compose: 可用"
    else
        log_error "Docker Compose 未安装"
        exit 1
    fi
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Docker Compose 命令兼容性函数
# ------------------------------------------------------------------------------
get_compose_command() {
    if command -v docker-compose &>/dev/null; then
        echo "docker-compose"
    elif docker compose version &>/dev/null; then
        echo "docker compose"
    else
        return 1
    fi
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 下载函数
# ------------------------------------------------------------------------------
download_with_retry() {
    local url=$1
    local output=$2
    local attempt=1
    
    log_substep "下载文件: $(basename "$output")"
    
    while [[ $attempt -le $RETRIES ]]; do
        log_info "下载尝试 #${attempt}..."
        
        if curl -fsSL --connect-timeout $TIMEOUT --show-error "$url" -o "$output"; then
            log_success "文件下载成功"
            return 0
        fi
        
        ((attempt++))
        sleep 2
    done
    
    log_error "下载失败: $url"
    return 1
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 文件验证函数
# ------------------------------------------------------------------------------
validate_compose_file() {
    local file=$1
    
    log_step "验证 Compose 文件"
    
    # 检查文件是否存在且非空
    if [[ ! -f "$file" ]]; then
        log_error "文件不存在: $file"
        return 1
    fi
    
    if [[ ! -s "$file" ]]; then
        log_error "文件为空: $file"
        return 1
    fi
    
    # 基本 YAML 结构检查
    if ! grep -qE "^(version:|services:)" "$file"; then
        log_error "无效的 Compose 文件格式"
        return 1
    fi
    
    log_success "Compose 文件验证通过"
    return 0
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 系统更新函数 (可选)
# ------------------------------------------------------------------------------
update_system_packages() {
    local update_flag="${1:-false}"
    
    if [[ "$update_flag" != "true" ]]; then
        log_info "跳过系统更新 (默认行为)"
        return 0
    fi
    
    log_step "更新系统软件包"
    
    if command -v apt-get &>/dev/null; then
        # Debian/Ubuntu
        log_substep "检测到 APT 包管理器"
        sudo apt-get update && sudo apt-get upgrade -y
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS
        log_substep "检测到 YUM 包管理器"
        sudo yum update -y
    elif command -v dnf &>/dev/null; then
        # Fedora
        log_substep "检测到 DNF 包管理器"
        sudo dnf update -y
    else
        log_warning "不支持的包管理器，跳过更新"
        return 0
    fi
    
    log_success "系统更新完成"
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 主执行函数
# ------------------------------------------------------------------------------
main() {
    log_header "Mindoc 部署脚本启动"
    log_info "工作目录: $WORKDIR"
    log_info "Compose 文件: $COMPOSE_URL"
    
    # 解析命令行参数
    local UPDATE_SYSTEM=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --update|-u)
                UPDATE_SYSTEM=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # 可选: 更新系统包
    update_system_packages "$UPDATE_SYSTEM"
    
    # 检查依赖
    check_dependencies
    
    # 获取 compose 命令
    local COMPOSE_CMD
    COMPOSE_CMD=$(get_compose_command)
    log_info "使用命令: $COMPOSE_CMD"
    
    # 创建工作目录
    log_step "准备工作目录"
    mkdir -p "$WORKDIR" && cd "$WORKDIR"
    log_success "工作目录就绪: $(pwd)"
    
    # 下载 compose 文件
    log_step "下载 Docker Compose 配置"
    download_with_retry "$COMPOSE_URL" "$COMPOSE_FILE"
    
    # 验证文件
    validate_compose_file "$COMPOSE_FILE"
    
    # 启动服务
    log_step "启动 Mindoc 服务"
    log_substep "执行: $COMPOSE_CMD up -d"
    
    if $COMPOSE_CMD up -d --wait --wait-timeout $TIMEOUT; then
        log_success "Mindoc 服务启动成功"
    else
        log_error "服务启动失败"
        $COMPOSE_CMD logs --tail=20
        exit 1
    fi
    
    # 显示部署结果
    show_deployment_info "$COMPOSE_CMD"
    
    log_header "🎉 Mindoc 部署完成!"
}

show_deployment_info() {
    local cmd=$1
    
    log_step "部署信息"
    log_substep "查看状态: $cmd ps"
    log_substep "查看日志: $cmd logs -f"
    log_substep "重启服务: $cmd restart"
    log_substep "停止服务: $cmd down"
    log_substep "工作目录: $WORKDIR"
}

show_usage() {
    echo -e "${STYLE_BOLD}使用方法:${COLOR_RESET}"
    echo -e "  $SCRIPT_NAME [选项]"
    echo
    echo -e "${STYLE_BOLD}选项:${COLOR_RESET}"
    echo -e "  -u, --update    部署前更新系统软件包"
    echo -e "  -h, --help      显示帮助信息"
    echo
    echo -e "${STYLE_BOLD}示例:${COLOR_RESET}"
    echo -e "  $SCRIPT_NAME                  # 直接部署"
    echo -e "  $SCRIPT_NAME --update         # 更新系统后部署"
}
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 脚本入口
# ------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
# ------------------------------------------------------------------------------
