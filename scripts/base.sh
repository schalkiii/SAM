#!/system/bin/sh
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

# 以指定 用户:组 启动服务
# 三个服务原先直接依赖 busybox setuidgid，临时 root 环境下 busybox 不在 PATH
# 或缺少该 applet 时，SmartDNS/AGH/Mihomo 会一起启动失败。
# 这里统一探测：不可用时降级为 root 启动，并在 module.log 明确记录风险。
service_exec(){
    service_user_group="${1}"
    shift

    if has_cmd busybox && busybox setuidgid "${service_user_group}" true > /dev/null 2>&1; then
        detach_exec busybox setuidgid "${service_user_group}" "$@"
        return $?
    fi
    if has_cmd setuidgid && setuidgid "${service_user_group}" true > /dev/null 2>&1; then
        detach_exec setuidgid "${service_user_group}" "$@"
        return $?
    fi

    if [ "${SERVICE_EXEC_FALLBACK_LOGGED}" != "1" ]; then
        log "e" "没有可用的 setuidgid，服务降级为 root 启动；请安装 busybox 或检查 setuidgid"
        SERVICE_EXEC_FALLBACK_LOGGED=1
    fi
    detach_exec "$@"
}

# 判断 hosts 是否已挂载到系统路径
hosts_mounted(){
    mount | grep -q " /system/etc/hosts "
}

# 把当前 hosts 文件重新挂到系统路径
# mv 替换文件后 inode 会变，bind 挂载点仍指向旧 inode，必须 umount 后重挂
remount_hosts(){
    [ "${HOST_ENABLE}" = "true" ] || return 0
    [ -f "${HOSTS_FILE}" ] || return 1
    umount /system/etc/hosts 2>/dev/null
    mount -o bind "${HOSTS_FILE}" /system/etc/hosts 2>/dev/null
}

# 清洗配置文件里的 UTF-8 BOM 与 CR
# 返回: 0 正常/已清洗, 1 文件缺失或读取失败, 2 检测到 UTF-16(不自动转换)
# UTF-16 很可能是 Windows 编辑器误存，强行按 UTF-8 处理会得到乱码配置，
# 所以这里只报错，让用户另存为 UTF-8。
sanitize_config(){
    clean_file="${1}"
    [ -f "${clean_file}" ] || return 1

    clean_head=$(head -c 2 "${clean_file}" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "${clean_head}" in
        fffe|feff)
            log "e" "配置文件是 UTF-16，未自动转换(请另存为 UTF-8): ${clean_file}"
            return 2
            ;;
    esac

    clean_tmp="${TMP_PATH}/$(basename "${clean_file}").clean.$$"
    if [ "$(head -c 3 "${clean_file}" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
        tail -c +4 "${clean_file}" > "${clean_tmp}"
    else
        cp -f "${clean_file}" "${clean_tmp}"
    fi
    tr -d '\015' < "${clean_tmp}" > "${clean_tmp}.lf" && mv -f "${clean_tmp}.lf" "${clean_tmp}"

    if cmp -s "${clean_file}" "${clean_tmp}" 2>/dev/null; then
        rm -f "${clean_tmp}"
        return 0
    fi

    # 改动前留一份备份；只保留最近一份
    cp -f "${clean_file}" "${clean_file}.bak" 2>/dev/null
    mv -f "${clean_tmp}" "${clean_file}"
    log "i" "已清洗配置的 BOM/CR: ${clean_file}"
    return 0
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
#
# 节流: 服务反复掉线时，守护循环会反复恢复并刷新网络，表现成 WiFi 反复断开/重连。
#       自动刷新 10 分钟内最多一次；手动工具/保存配置传 force 立即刷新。
# 互斥: WebUI、守护循环和启动流程可能同时触发，用目录锁避免并发开关飞行模式。
refresh_network(){
    refresh_mode="${1:-auto}"
    refresh_stamp="${TMP_PATH}/network.refresh.stamp"
    refresh_lock="${TMP_PATH}/.network_refresh.lock"
    refresh_window=600

    # 自动刷新尊重设置；手动刷新(force)不受 NETWORK_REFRESH 限制
    if [ "${refresh_mode}" != "force" ] && [ "${NETWORK_REFRESH}" != "true" ]; then
        log_file "NETWORK_REFRESH=false，跳过网络刷新"
        return 0
    fi

    if ! mkdir "${refresh_lock}" 2>/dev/null; then
        refresh_lock_time=$(stat -c %Y "${refresh_lock}" 2>/dev/null)
        refresh_now=$(date +%s)
        if [ -z "${refresh_lock_time}" ] || [ $((refresh_now - refresh_lock_time)) -gt 60 ]; then
            # 锁超过 60 秒视为崩溃残留
            rm -rf "${refresh_lock}"
            mkdir "${refresh_lock}" 2>/dev/null || {
                log_file "网络刷新锁被占用，跳过"
                return 0
            }
        else
            log_file "网络刷新正在进行，跳过"
            return 0
        fi
    fi

    if [ "${refresh_mode}" != "force" ] && [ -f "${refresh_stamp}" ]; then
        refresh_last=$(cat "${refresh_stamp}" 2>/dev/null)
        refresh_now=$(date +%s)
        if [ -n "${refresh_last}" ] && [ $((refresh_now - refresh_last)) -lt ${refresh_window} ]; then
            log_file "10 分钟内已自动刷新过网络，跳过"
            rmdir "${refresh_lock}" 2>/dev/null
            return 0
        fi
    fi

    # 先写时间戳再切换: 切换会让 WiFi 短暂断开，可能触发 WiFi 监控启动服务，
    # 后续自动刷新必须看到时间戳而直接跳过，避免形成开关循环
    date +%s > "${refresh_stamp}" 2>/dev/null
    log_file "刷新网络(开关一次飞行模式)"
    airplane_set enable 1
    sleep 1
    airplane_set disable 0
    sleep 1
    rmdir "${refresh_lock}" 2>/dev/null
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
# 性能: 用 case 代替 echo | grep，避免每次调用多 fork 两个进程。
#       本函数全项目被调用 50+ 处，守护循环每 5 秒就要调 6~8 次，
#       一次多两个 fork 相当于每天多出几十万次进程创建。
isRun(){
    pid=""
    case "${1}" in
        */*)
            pid=$(pgrep -f "${1}" 2>/dev/null)
            ;;
        *)
            pid=$(pidof "${1}" 2>/dev/null)
            [ -z "${pid}" ] && pid=$(pgrep -x "${1}" 2>/dev/null)
            ;;
    esac
    if [ "${pid}" ]; then
        [ "${2}" = "pid" ] && echo ${pid}
        return 0
    fi
    return 1
}

# 取 SmartDNS 实际监听端口
# 只认以 bind 开头的行，避免注释里出现 bind/冒号时解析出垃圾
smartdns_port(){
    sed -n 's/^bind .*:\([0-9][0-9]*\).*$/\1/p' "${SMARTDNS_CONF}" 2>/dev/null | head -n 1
}

# 判断端口是否有进程在监听
# 进程活着不代表 DNS 端口可用(端口冲突/配置错误都会出现"进程在、端口死")，
# 重定向规则必须指向真正在监听的端口。
# 没有 ss/netstat 时按"在监听"处理，避免在精简系统上误删规则。
is_port_listening(){
    listen_port="${1}"
    [ -n "${listen_port}" ] || return 1

    if has_cmd ss; then
        listen_out=$(ss -lnut 2>/dev/null) || return 0
        echo "${listen_out}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        return 1
    fi
    if has_cmd netstat; then
        listen_out=$(netstat -lnu 2>/dev/null) || listen_out=""
        echo "${listen_out}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        listen_out=$(netstat -lnt 2>/dev/null) || listen_out=""
        echo "${listen_out}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        return 1
    fi
    return 0
}

# 等待端口就绪(最多约 5 秒)，避免进程刚 fork 出来还没 bind 就被判定失败
wait_port(){
    wait_port_value="${1}"
    wait_port_try=0
    [ -n "${wait_port_value}" ] || return 1
    while [ ${wait_port_try} -lt 10 ]; do
        is_port_listening "${wait_port_value}" && return 0
        sleep 0.5 2>/dev/null || sleep 1
        wait_port_try=$((wait_port_try + 1))
    done
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
