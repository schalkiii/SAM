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

# 下载 URL 到 stdout: curl 优先，无 curl 时退回 wget
# 设备不一定带 curl(部分 ROM 只有 toybox/Magisk busybox 的 wget)，
# 只写 curl 会让 hosts/组件更新在缺 curl 的机器上 100% 静默失败
fetch_url(){
    fetch_target="${1}"
    fetch_timeout="${2:-15}"
    if has_cmd curl; then
        curl -m "${fetch_timeout}" -s -f -L "${fetch_target}"
        return $?
    fi
    if has_cmd wget; then
        wget -T "${fetch_timeout}" -q -O - "${fetch_target}"
        return $?
    fi
    if has_cmd busybox && busybox wget --help > /dev/null 2>&1; then
        busybox wget -T "${fetch_timeout}" -q -O - "${fetch_target}"
        return $?
    fi
    return 1
}

# 下载 URL 到指定文件: 与 fetch_url 同一套降级顺序
# 组件更新要下载数十 MB 的二进制，不能走 fetch_url 的 stdout(整份内容会进管道/内存)，
# 也不能假设设备带 curl —— 部分 ROM 只有 busybox wget，缺工具时更新会 100% 静默失败
fetch_file(){
    fetch_file_url="${1}"
    fetch_file_target="${2}"
    fetch_file_timeout="${3:-300}"
    if has_cmd curl; then
        curl -f -L -# --connect-timeout 15 -m "${fetch_file_timeout}" -o "${fetch_file_target}" "${fetch_file_url}"
        return $?
    fi
    if has_cmd wget; then
        wget -T "${fetch_file_timeout}" -q -O "${fetch_file_target}" "${fetch_file_url}"
        return $?
    fi
    if has_cmd busybox && busybox wget --help > /dev/null 2>&1; then
        busybox wget -T "${fetch_file_timeout}" -q -O "${fetch_file_target}" "${fetch_file_url}"
        return $?
    fi
    return 1
}

# 网络是否可用: HTTPS 握手成功即可(不要求特定响应码)
# 用 IP 直连(223.5.5.5 阿里 DoH)绕过 DNS: 开机早期往往 DNS 还没就绪，
# 而 hosts 更新正是要在这种时刻判断"能不能联网"
# -k: 目的是判断"能不能连出去"，不是验证证书；按 IP 访问时证书校验
#     可能因缺少 IP SAN 直接失败，把可达网络误判成未就绪
is_network_ready(){
    if has_cmd curl; then
        curl -k -m 5 -s -o /dev/null "https://223.5.5.5/" 2>/dev/null && return 0
    fi
    ping -c 1 -W 2 223.5.5.5 > /dev/null 2>&1 && return 0
    return 1
}

# 等网络就绪，最多等 wait_network_timeout 秒(默认 60)
# 开机时 WiFi/移动数据常比服务晚就绪，一次性拉取会全源失败并把规则拖到下次启动
wait_network(){
    wait_network_timeout="${1:-60}"
    wait_network_elapsed=0
    while [ ${wait_network_elapsed} -lt ${wait_network_timeout} ]; do
        is_network_ready && return 0
        sleep 5
        wait_network_elapsed=$((wait_network_elapsed + 5))
    done
    return 1
}

# 确保 SmartDNS 运行所需的软链接存在
# SmartDNS 是 musl 动态链接的可执行文件，缺少 loader 软链时 exec 会直接失败，
# 表现为「AGH 能起来、SmartDNS 起不来」。开机脚本只在真开机时建这些链接，
# 软重启 / 临时 root 场景必须由运行时补齐。
# 建立/修复一条模块内软链(link_path, target)
# 两个要点都是实测踩出来的:
#   1. 目标用**相对路径**: 模块更新先把新版本建在 modules_update 再 mv 到
#      modules，绝对目标在 mv 后指向已消失的 modules_update，直接变悬空链
#   2. 悬空链(-L 真 / -e 假)必须删掉重建: 只看"链接是否存在"的守卫会一直
#      跳过它，表现为 SmartDNS 永远起不来(setuidgid: can't execute 'smartdns')
repair_module_link(){
    [ -e "${1}" ] && return 0
    mkdir -p "$(dirname "${1}")" 2>/dev/null
    rm -f "${1}" 2>/dev/null
    ln -s "${2}" "${1}" 2>/dev/null || log "e" "创建软链失败: ${1} -> ${2}"
}

ensure_module_links(){
    # bin/ 缺失时建出来: 模块更新/半截解压后目录可能不完整
    [ -d "${BIN_PATH}" ] || mkdir -p "${BIN_PATH}" 2>/dev/null

    # SmartDNS 是 musl 二进制，ELF 解释器写成相对路径 "lib/ld-musl-aarch64.so.1"，
    # 解析基准是进程 CWD(service/sd.sh 会 cd 到 SMARTDNS_PATH)。三条软链缺一不可:
    #   bin/smartdns                            PATH 查找(service_exec 按裸名调用)
    #   etc/SmartDNS/lib/ld-musl-aarch64.so.1   解释器 → libc.so
    #   etc/SmartDNS/lib/ld-linux.so            解释器兼容名
    repair_module_link "${BIN_PATH}/${SMARTDNS_BIN}" "../etc/SmartDNS/${SMARTDNS_BIN}"
    repair_module_link "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" "libc.so"
    repair_module_link "${SMARTDNS_PATH}/lib/ld-linux.so" "ld-musl-aarch64.so.1"

    # 建完复查: 缺链时给出定位用的具体路径，不再只靠 exec 的 ENOENT 反推
    for link_path in "${BIN_PATH}/${SMARTDNS_BIN}" \
                     "${SMARTDNS_PATH}/lib/ld-musl-aarch64.so.1" \
                     "${SMARTDNS_PATH}/lib/ld-linux.so"; do
        [ -e "${link_path}" ] && continue
        if [ -L "${link_path}" ]; then
            log "e" "软链悬空: ${link_path} -> $(readlink "${link_path}" 2>/dev/null)"
        else
            log "e" "软链缺失且创建失败: ${link_path}"
        fi
    done
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

# 统一目录锁
# 所有服务启停、配置写入、广告清单更新都走这里，避免 WebUI / watchdog / WiFi 监控并发覆盖状态。
# 锁目录内记录持有者 PID：只有持有者已死才允许接管，不能按固定秒数强删活锁。
sam_lock_acquire(){
    sam_lock_name="${1}"
    sam_lock_timeout="${2:-30}"
    sam_lock_dir="${TMP_PATH}/.${sam_lock_name}.lock"
    sam_lock_try=0
    while ! mkdir "${sam_lock_dir}" 2>/dev/null; do
        sam_lock_pid=$(cat "${sam_lock_dir}/pid" 2>/dev/null)
        if [ -n "${sam_lock_pid}" ] && ! kill -0 "${sam_lock_pid}" 2>/dev/null; then
            rm -rf "${sam_lock_dir}" 2>/dev/null
            continue
        fi
        sam_lock_try=$((sam_lock_try + 1))
        [ ${sam_lock_try} -ge ${sam_lock_timeout} ] && return 1
        sleep 1
    done
    printf '%s\n' "$$" > "${sam_lock_dir}/pid" 2>/dev/null
    return 0
}

sam_lock_release(){
    sam_release_name="${1}"
    sam_release_dir="${TMP_PATH}/.${sam_release_name}.lock"
    sam_release_pid=$(cat "${sam_release_dir}/pid" 2>/dev/null)
    [ "${sam_release_pid}" = "$$" ] && rm -rf "${sam_release_dir}" 2>/dev/null
    return 0
}

# 记录服务生命周期事件，供自动停止排查
record_service_event(){
    log_file "[SERVICE-EVENT] ${1}"
}

# WiFi / 黑名单判定
# 返回:
#   0 = 已连接黑名单 WiFi，必须停止服务
#   1 = 可以运行服务（不在黑名单、蜂窝网络、未连接 WiFi）
#   2 = 状态未知（查询失败/权限不足），调用方应保持现状，不能盲目启动
wifi_blacklist_state(){
    wifi_cmd_output=""
    wifi_known=0

    if has_cmd cmd; then
        wifi_cmd_output=$(cmd wifi status 2>/dev/null)
        [ -n "${wifi_cmd_output}" ] && wifi_known=1
    fi
    if [ ${wifi_known} -eq 0 ] && has_cmd dumpsys; then
        wifi_cmd_output=$(dumpsys connectivity 2>/dev/null | grep -E "WIFI|SSID" | head -n 20)
        [ -n "${wifi_cmd_output}" ] && wifi_known=1
    fi

    if [ ${wifi_known} -eq 0 ]; then
        return 2
    fi

    current_wifi_ssid=$(printf '%s\n' "${wifi_cmd_output}" | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
    for blacklist_ssid in "${BLACKLIST_WIFI[@]}"; do
        [ -n "${blacklist_ssid}" ] || continue
        [ "${current_wifi_ssid}" = "${blacklist_ssid}" ] && return 0
    done
    return 1
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

    if ! sam_lock_acquire "network_refresh" 60; then
        log_file "网络刷新正在进行，跳过"
        return 0
    fi

    if [ "${refresh_mode}" != "force" ] && [ -f "${refresh_stamp}" ]; then
        refresh_last=$(cat "${refresh_stamp}" 2>/dev/null)
        refresh_now=$(date +%s)
        if [ -n "${refresh_last}" ] && [ $((refresh_now - refresh_last)) -lt ${refresh_window} ]; then
            log_file "10 分钟内已自动刷新过网络，跳过"
            sam_lock_release "network_refresh"
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
    sam_lock_release "network_refresh"
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
# 协议语义: TCP 与 UDP 都要查，但任一在监听即视为可用。
#   SmartDNS 默认只有 bind(UDP)，AGH/Mihomo 两者都听；
#   要求"同时监听"会把只有 UDP 的 SmartDNS 误判成未监听，
#   DNS 入口选择跳过它 -> 整机查询全走 AGH，SmartDNS 计数永远为零。
# 没有 ss/netstat 时按"在监听"处理，避免在精简系统上误删规则。
is_port_listening(){
    listen_port="${1}"
    [ -n "${listen_port}" ] || return 1

    if has_cmd ss; then
        listen_udp=$(ss -lun 2>/dev/null) || listen_udp=""
        listen_tcp=$(ss -ltn 2>/dev/null) || listen_tcp=""
        echo "${listen_udp}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        echo "${listen_tcp}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        return 1
    fi
    if has_cmd netstat; then
        listen_udp=$(netstat -lnu 2>/dev/null) || listen_udp=""
        listen_tcp=$(netstat -lnt 2>/dev/null) || listen_tcp=""
        echo "${listen_udp}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        echo "${listen_tcp}" | grep -qE "[:.]${listen_port}[[:space:]]" && return 0
        return 1
    fi
    return 0
}

# Mihomo 是否应该参与运行: 启用 + 有订阅地址 + 非直通模式
# 三条件缺一不可，漏判的后果各不相同:
#   - 没有订阅地址时 Mihomo 本身起不来，不该被当成异常反复重启刷日志
#   - 直通模式的目的是让系统使用网络下发的 DNS，Mihomo 的 TUN(auto-route +
#     dns-hijack) 会在路由层继续劫持，必须停掉
# 判定点分布在启动编排(service.sh)、健康检查与拓扑刷新(watchdog.sh)，
# 集中在这里避免各处条件漂移
mihomo_expected(){
    [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]
}

# 计算当前 DNS 入口: 按 MODULE_DNS_MODE 逐级回退，输出 "名称:端口"，无可用入口时输出空
# 三处消费方必须同序，否则会出现"规则指向已死端口"或"规则正常但显示异常":
#   iptables/dns.sh select_dns_port(建重定向规则)
#   watchdog.sh   current_dns_entry(判断服务拓扑是否真的变了)
#   webui.sh      resolve_dns_entry(状态页显示入口)
# 判定口径统一为 isRun + is_port_listening: 进程活着不代表端口可用
# (端口冲突/配置错误都会出现"进程在、端口死")，重定向规则必须指向真正在监听的端口
dns_entry_port(){
    dns_agh_port=""
    dns_mihomo_port=""
    dns_smartdns_port=""
    # SmartDNS 的实际监听端口从配置解析(可被 LAN_ACCESS 改写成 [::]:3721)，
    # 不能读 SMARTDNS_PORT 变量: 那个变量只有 iptables/dns.sh 才会设，
    # watchdog/webui 里是空的，is_port_listening "" 恒失败 -> SmartDNS 永远选不上，
    # 表现为"只有 SmartDNS 在跑时整机 DNS 被判成无入口并清掉重定向"
    dns_sd_listen_port=""
    if isRun ${SMARTDNS_BIN}; then
        dns_sd_listen_port=$(smartdns_port)
        if [ -n "${dns_sd_listen_port}" ] && is_port_listening "${dns_sd_listen_port}"; then
            dns_smartdns_port=${dns_sd_listen_port}
        fi
    fi
    isRun ${AGH_BIN} && is_port_listening "${AGH_DNS_PORT}" && dns_agh_port=${AGH_DNS_PORT}
    isRun ${MIHOMO_BIN} && is_port_listening "${MIHOMO_DNS_PORT}" && dns_mihomo_port=${MIHOMO_DNS_PORT}
    if [ "${MODULE_DNS_MODE}" = "2" ]; then
        # 期望链路: Mihomo -> AdGuardHome -> SmartDNS
        [ -n "${dns_mihomo_port}" ] && { echo "Mihomo:${dns_mihomo_port}"; return 0; }
        [ -n "${dns_agh_port}" ] && { echo "AdGuardHome:${dns_agh_port}"; return 0; }
    else
        # 期望链路: AdGuardHome -> Mihomo -> SmartDNS
        [ -n "${dns_agh_port}" ] && { echo "AdGuardHome:${dns_agh_port}"; return 0; }
        [ -n "${dns_mihomo_port}" ] && { echo "Mihomo:${dns_mihomo_port}"; return 0; }
    fi
    [ -n "${dns_smartdns_port}" ] && echo "SmartDNS:${dns_smartdns_port}"
    return 0
}

# 沿 DNS 服务链找 consumer 的下一个可用上游端口，输出端口号；找不到返回 1
# 链路按 MODULE_DNS_MODE 定义:
#   模式 2: Mihomo -> AdGuardHome -> SmartDNS
#   模式 1: AdGuardHome -> Mihomo -> SmartDNS
# 只允许沿链路向后找: 若允许回头，模式 1 下 SmartDNS 掉线时会把 Mihomo 的上游
# 设成 AGH，而 AGH 的上游正是 Mihomo —— 两者互指形成转发环，查询一直转发到超时。
# 下游配置(update/agh.sh、update/mihomo.sh)必须共用这里，避免各自维护一份回退链
dns_chain_upstream(){
    dns_chain_consumer="${1}"
    case "${MODULE_DNS_MODE}" in
        2) dns_chain_list="${MIHOMO_BIN} ${AGH_BIN} ${SMARTDNS_BIN}" ;;
        *) dns_chain_list="${AGH_BIN} ${MIHOMO_BIN} ${SMARTDNS_BIN}" ;;
    esac

    dns_chain_passed=0
    for dns_chain_bin in ${dns_chain_list}; do
        if [ "${dns_chain_passed}" -eq 0 ]; then
            [ "${dns_chain_bin}" = "${dns_chain_consumer}" ] && dns_chain_passed=1
            continue
        fi
        case "${dns_chain_bin}" in
            "${SMARTDNS_BIN}")
                if [ "${SMARTDNS_ENABLE}" = "true" ] && isRun ${SMARTDNS_BIN}; then
                    dns_chain_port=$(smartdns_port)
                    [ -n "${dns_chain_port}" ] && is_port_listening "${dns_chain_port}" && \
                        { echo "${dns_chain_port}"; return 0; }
                fi
                ;;
            "${AGH_BIN}")
                if [ "${AGH_ENABLE}" = "true" ] && isRun ${AGH_BIN} && \
                   is_port_listening "${AGH_DNS_PORT}"; then
                    echo "${AGH_DNS_PORT}"
                    return 0
                fi
                ;;
            *)
                if mihomo_expected && isRun ${MIHOMO_BIN} && \
                   is_port_listening "${MIHOMO_DNS_PORT}"; then
                    echo "${MIHOMO_DNS_PORT}"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}
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
