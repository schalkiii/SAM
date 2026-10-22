# 模块路径
MODULE_PATH="/data/adb/modules/SAM"

# 加载固定配置(路径、日志文件、程序名等)
source "${MODULE_PATH}/scripts/config.sh"

# 缓存目录(日志写入依赖此目录，临时 root 下可能尚未创建)
[ -d "${TMP_PATH}" ] || mkdir -p "${TMP_PATH}" 2>/dev/null

# 添加环境
[ -d "/data/adb/magisk" ] && export PATH="/data/adb/magisk:${PATH}"
[ -d "/data/adb/ksu/bin" ] && export PATH="/data/adb/ksu/bin:${PATH}"
[ -d "/data/adb/ap/bin" ] && export PATH="/data/adb/ap/bin:${PATH}"
[ -d "/data/adb/modules/busybox-ndk/system/bin" ] && export PATH="/data/adb/modules/busybox-ndk/system/bin:${PATH}"
export PATH="${BIN_PATH}:${PATH}"
export SSL_CERT_DIR="/system/etc/security/cacerts/"
export TZ="Asia/Shanghai"

# 防火墙指令
iptables_w="iptables -w 100"
ip6tables_w="ip6tables -w 100"

# 判断命令是否存在
has_cmd(){
    command -v "${1}" > /dev/null 2>&1
}

# 确保 SmartDNS 运行所需的软链接存在
# SmartDNS 是 musl 动态链接的可执行文件，缺少 loader 软链时 exec 会直接失败，
# 表现为「AGH 能起来、SmartDNS 起不来」。开机脚本只在真开机时建这些链接，
# 软重启 / 临时 root 场景必须由运行时补齐。
ensure_module_links(){
    [ -d "${BIN_PATH}" ] || return 0

    if [ ! -e "${BIN_PATH}/${SMARTDNS_BIN}" ] && [ ! -L "${BIN_PATH}/${SMARTDNS_BIN}" ]; then
        ln -s "${SMARTDNS_PATH}/${SMARTDNS_BIN}" "${BIN_PATH}/${SMARTDNS_BIN}" 2>/dev/null
    fi

    if [ ! -e "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" ] && [ ! -L "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" ]; then
        ln -s "${SMARTDNS_PATH}/lib/libc.so" "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" 2>/dev/null
    fi

    if [ ! -e "${SMARTDNS_PATH}/lib/ld-linux.so" ] && [ ! -L "${SMARTDNS_PATH}/lib/ld-linux.so" ]; then
        ln -s "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" "${SMARTDNS_PATH}/lib/ld-linux.so" 2>/dev/null
    fi
}

# 把进程从当前会话/进程组里剥离
# 背景: 通过 KernelSU/Magisk 的 WebUI 执行脚本时，整棵进程树挂在调用方的会话上，
#       调用结束或会话被回收时，服务进程会跟着被系统一起收走，
#       表现为"跑了一阵子，AGH 和 SmartDNS 一起消失，看门狗也没留下记录"。
# 解决: 用 setsid 让服务脱离会话，独立于调用方存活。
detach_exec(){
    # setsid 不可用或调用失败时回退 nohup；
    # 两条路径都保证子进程不随调用方会话结束而退出
    if has_cmd setsid; then
        setsid "$@" &
    elif has_cmd nohup; then
        nohup "$@" &
    else
        "$@" &
    fi
}

# 保护进程不被系统 LMKD/OOM killer 回收
# AGH 与 SmartDNS 是常驻内存大户，系统内存紧张时会被优先杀掉；
# 把 oom_score_adj 设为 -1000 让内核把它们视为不可回收进程。
protect_process(){
    for protect_pid in ${1}; do
        [ -n "${protect_pid}" ] || continue
        [ -w "/proc/${protect_pid}/oom_score_adj" ] || continue
        echo -1000 > "/proc/${protect_pid}/oom_score_adj" 2>/dev/null
    done
}

# 设置飞行模式: Android 11+ 优先用 cmd connectivity，老系统回退 settings + broadcast
airplane_set(){
    if command -v cmd > /dev/null 2>&1 && cmd connectivity airplane-mode "${1}" > /dev/null 2>&1; then
        return 0
    fi
    settings put global airplane_mode_on "${2}" 2>/dev/null
    am broadcast -a android.intent.action.AIRPLANE_MODE > /dev/null 2>&1
}

# 开关一次飞行模式，让系统与 App 立即重新发起 DNS 查询
# 场景: DNS 服务异常退出后，系统的网络状态已被判成"无网络"，
#       即使服务恢复也需要重新验证一次网络，否则表现为"还是没网"。
refresh_network(){
    log_file "刷新网络(开关一次飞行模式)"
    airplane_set enable 1
    sleep 1
    airplane_set disable 0
    sleep 1
}

# 占位符
placeholder(){
    i=0
    out=""
    while(( i<${1} ))
    do
        out+="▇"
        let "i++"
    done
    echo ${out}
}

# 日志
log(){
    # 时间
    time=$(date "+%Y-%m-%d %H:%M:%S")
    # 输出内容
    out="[${time}]"
    # 判断日志格式
    if [ "${1}" = "i" ]; then
        out+="[INFO]"
    elif [ "${1}" = "e" ]; then
        out+="[ERROR]"
    fi
    out+=": ${2}"
    echo "${2}"
    echo "${out}" >> "${LOG_FILE}" 2>/dev/null
}

# 只写日志文件，不输出到 stdout
# 供 WebUI 调用的脚本使用，避免污染返回结果
log_file(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${1}" >> "${LOG_FILE}" 2>/dev/null
}

# 程序是否运行
# 优先用 pidof 精确匹配进程名(路径参数才用 pgrep -f)；
# pidof 缺失时回退 pgrep -x，避免在精简系统上永远判定为"未运行"
isRun(){
    pid=""
    if echo "${1}" | grep -q "/"; then
        pid=$(pgrep -f "${1}" 2>/dev/null)
    else
        pid=$(pidof "${1}" 2>/dev/null)
        [ -z "${pid}" ] && pid=$(pgrep -x "${1}" 2>/dev/null)
    fi
    if [ "${pid}" ]; then
        [ "${2}" = "pid" ] && echo ${pid}
        return 0
    fi
    return 1
}

# 杀死进程
kill_process(){
    pid=$(isRun "${1}" "pid") && {
        sleep 1
        kill -9 ${pid} && return 0 || return 1
    } || return 1
}

# 安全加载设置
# 自动处理 BOM / CRLF / 语法错误 / 缺失项，避免改坏 setting.conf 后脚本整体退出
source "${MODULE_PATH}/scripts/setting.sh"
load_setting "${MODULE_PATH}/setting.conf"
