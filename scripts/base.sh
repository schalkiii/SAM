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

# 程序是否运行
isRun(){
    echo "${1}" | grep -q "/" && pid=$(pgrep -f "${1}" 2>/dev/null) || pid=$(pidof "${1}" 2>/dev/null)
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
