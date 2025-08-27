通用 Shell 脚本开发提示词（Ubuntu 24.04 LTS • Compose • 单文件）
作用：指导一次性交付高质量、可排错的运维脚本
版本：3.0 - 生产就绪优化版
最后更新：2025-08-28
使用说明：复制整段到脚本顶部，按需调整后开发
统一风格要求：所有函数、变量、错误处理、日志输出保持一致的命名和结构
=============================================================================
----------- 1. 运行约束（严格执行） -----------
- 单脚本交付：不拆分 lib，所有函数内嵌
- 只依赖：bash(≥4.4)、curl、docker(≥26.x)、docker-compose(≥2.24)
- 日志目录：/home/${APP_NAME}_logs（自动创建）
- 错误处理：采用函数式错误检查，禁用 set -e
- 权限：umask 022
- 入口执行函数必须是：install_${APP_NAME}
- 严格线性执行：所有操作顺序执行，禁止并发操作
- 变更记录：必须在常量定义区块上方添加版本变更记录

----------- 2. 功能流程（严格顺序执行） -----------
1) 变更记录区块（记录版本演进）
2) 常量集中定义（APP_NAME 写死）
3) 环境检测和系统信息收集
4) 网络诊断和镜像源可达性检测
5) 统一依赖预检（所有依赖一次检查）
6) 文件夹存在性预检（提前检查所有需要的文件夹）
7) 安装状态检查和服务运行检测
8) 旧目录备份清理
9) 智能多源文件下载（支持动态超时和优先级）
10) 配置文件生成（使用 heredoc）
11) 启动容器
12) 业务探活（支持 200/301/302）
13) 诊断信息收集（包含网络统计）
14) 成功退出

----------- 3. 统一日志系统（函数式输出） -----------
- 日志文件：/home/${APP_NAME}_logs/install.log（唯一日志文件）
- 控制台输出：关键成功/失败信息
- 使用统一的日志函数输出，禁止直接使用 echo
- 格式：时间戳 - 级别 - 消息
- 级别：INFO, WARNING, ERROR, SUCCESS

----------- 4. 统一错误处理策略（函数式检查） -----------
采用函数式错误检查，禁用 set -e：
1) 所有命令通过 run_command 函数执行
2) 所有函数通过 run_function 函数执行
3) 统一检查返回值并处理错误
4) 预期可忽略的错误使用 || true 并明确注释
5) 支持多级重试的操作使用统一重试函数
6) 特殊退出码机制：2表示服务已运行（非错误）

----------- 5. 统一变量命名规范 -----------
常量：全大写+下划线，必须在脚本开头集中定义
局部变量：小写+下划线，仅在函数内部使用
路径变量：使用绝对路径，禁止相对路径
统计变量：使用明确的统计文件路径
示例：
APP_NAME="myapp"
WORKDIR_ROOT="/home/myapp"
LOG_DIR="/home/myapp_logs"
STATS_FILE="/tmp/mydownload_stats.txt"

----------- 6. 统一函数规范 -----------
函数命名：小写+下划线，动词开头
函数头部：必须有一行中文注释说明用途
参数传递：使用 $1, $2... 明确参数
返回值：成功返回 0，失败返回非 0，特殊状态返回 2
局部变量：所有变量必须 local 声明
示例：
# 下载文件并验证
download_file() {
    local url="$1"
    local output="$2"
    local retries="${3:-3}"
    # 函数体
}

----------- 7. 变更记录规范 -----------
必须在常量定义前添加变更记录区块：
格式：
# 版本 X.X (YYYY-MM-DD)
# - 变更描述1
# - 变更描述2
要求：
- 每次重大更新必须更新版本号
- 记录具体的优化内容和修复问题
- 保持时间顺序（最新版本在最上面）

----------- 8. 网络诊断规范 -----------
必须检测以下网络信息：
- 基础网络连通性：httpbin.org 检测
- 所有镜像源域名可达性：ping 测试
- 历史下载统计：显示各源的成功率
- 使用统一 network_diagnosis 函数实现
- 输出使用状态标识：[OK] 可达 [FAIL] 不可达

----------- 9. 镜像源管理规范 -----------
镜像源列表要求：
- 按历史成功率排序（高成功率优先）
- 移除不可达的镜像源
- 多类型备份：代理服务 + CDN + 镜像站 + 原始地址
- 支持动态超时：CDN 15s, GitHub 12s, 代理 10s
- 记录下载统计用于持续优化

----------- 10. 统计功能规范 -----------
必须实现以下统计功能：
- 下载成功率统计：记录每个源的成功次数
- 统计文件维护：保持最近50-100条记录
- 统计信息展示：在网络诊断中显示
- 使用统一的统计函数实现

----------- 11. 文件夹存在性预检规范 -----------
在脚本生命周期早期检查所有需要的文件夹：
- 工作目录：WORKDIR_ROOT
- 日志目录：LOG_DIR
- 备份目录：BACKUP_DIR_ROOT
- Docker日志目录：DOCKER_LOG_DIR
- 临时目录：/tmp 相关目录
检查权限：确保当前用户有读写权限
使用统一的 check_directories 函数实现

----------- 12. 依赖检查规范 -----------
所有依赖在脚本开始时一次性检查：
- 系统命令：bash, curl, docker, docker-compose
- 服务状态：docker 守护进程
- 端口占用：需要使用的端口
- 目录权限：工作目录和日志目录
使用统一的 check_dependencies 函数实现

----------- 13. 下载策略规范 -----------
智能下载策略要求：
- 多级重试：网络尝试 × 下载尝试
- 智能超时：根据域名类型设置不同超时
- 源间间隔：同一周期内源之间短暂间隔
- 优先级重试：先高成功率源，后备用源
- 统计记录：成功下载后记录统计信息

----------- 14. 自检清单（必须满足） -----------
[ ] 所有变量引用使用双引号
[ ] 所有函数顶部有一行中文注释
[ ] 所有命令通过 run_command 或错误抑制执行
[ ] 所有函数通过 run_function 执行
[ ] 所有日志输出通过统一的日志函数
[ ] 包含完整的变更记录区块
[ ] 实现网络诊断和统计功能
[ ] 镜像源按成功率排序且移除不可达源
[ ] 通过 shellcheck 检查，零警告

----------- 15. 常量定义模板 -----------
必须在变更记录后定义常量：
APP_NAME="myapp" # 唯一必须修改的常量
WORKDIR_ROOT="/home/myapp"
BACKUP_DIR_ROOT="/home/myapp_backup"
LOG_DIR="/home/myapp_logs"
LOG_FILE="${LOG_DIR}/install.log"
STATS_FILE="/tmp/mydownload_stats.txt"
COMPOSE_FILE_NAME="docker-compose.yml"
TIMEOUT_SECONDS=30
CURL_CONNECT_TIMEOUT=10
MAX_DOWNLOAD_RETRIES=3
HEALTH_PROBE_INTERVAL=1
COMPOSE_PROJECT_NAME="myapp_project"
DOCKER_LOG_DIR="/home/dockerlog/myapp"

----------- 16. 代码结构模板 -----------
严格按以下顺序组织代码：
1) 变更记录区块
2) 常量定义区块
3) 日志函数区块（log_info, log_warning, log_error, log_success）
4) 错误处理区块（run_command, run_function, handle_error, handle_exit）
5) 统计功能区块（track_download_success, show_download_stats）
6) 环境检测区块（detect_environment）
7) 网络诊断区块（network_diagnosis）
8) 文件夹预检区块（check_directories）
9) 依赖检查区块（check_dependencies）
10) 安装状态区块（check_installation_status, check_service_running）
11) 数据操作区块（backup_existing_data, restore_data, backup_old_config）
12) 下载区块（download_compose）
13) 容器操作区块（start_containers, probe_service, get_compose_cmd）
14) 诊断收集区块（collect_diagnosis）
15) 主流程函数（install_${APP_NAME}）
16) 主程序入口

----------- 17. 镜像源优化准则 -----------
基于历史数据优化镜像源：
1. 移除不可达的镜像源（如 github.com.cnpmjs.org, hub.fastgit.org）
2. 提高成功率高的源优先级（如 gh-proxy.com, ghproxy.net）
3. 保持多类型备份：代理服务 + CDN + 原始地址
4. 定期更新镜像源列表 based on 网络诊断结果
5. 使用统计数据驱动优先级调整

----------- 18. 网络诊断必检项目 -----------
必须检测以下域名：
- 高优先级代理：gh-proxy.com, ghproxy.net, mirror.ghproxy.com
- CDN服务：cdn.jsdelivr.net, gcore.jsdelivr.net
- 其他代理：gh.api.99988866.xyz, g.ioiox.com
- 原始地址：raw.githubusercontent.com
输出格式：使用状态标识清晰标识状态
=============================================================================
