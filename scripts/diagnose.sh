#!/system/bin/sh
# SAM 只读诊断脚本
#
# 用途: 一次采集"服务为什么起不来"与"DNS 链路为什么慢"的全部关键证据。
# 安全: 只读。不启动/停止服务，不改配置，不动 iptables，不写模块目录
#       (仅向 tmp 写一个探测文件并立即删除，用于判断可写性)。
#
# 用法(设备上, root):
#   sh /data/adb/modules/SAM/scripts/diagnose.sh
#   sh /data/adb/modules/SAM/scripts/diagnose.sh --watch 15   # 采样 15 秒看 v6 阻断增量
#   sh /data/adb/modules/SAM/scripts/diagnose.sh --auto-stop  # 只分析服务自动停止
#
# WebUI 工具页「一键诊断 / 自动停止分析」同样调用本脚本。

MODULE_PATH="/data/adb/modules/SAM"
UPDATE_DIR="/data/adb/modules_update/SAM"
TMP_PATH="${MODULE_PATH}/tmp"
AGH_PATH="${MODULE_PATH}/etc/AdGuardHome"
AGH_CONF="${AGH_PATH}/AdGuardHome.yaml"
SD_CONF="${MODULE_PATH}/etc/SmartDNS/smartdns.conf"
SETTING="${MODULE_PATH}/setting.conf"

WATCH_SEC=0
AUTO_STOP_ONLY=0
[ "${1}" = "--watch" ] && WATCH_SEC="${2:-15}"
[ "${1}" = "--auto-stop" ] && AUTO_STOP_ONLY=1

sep(){ echo "──────────────────────────────────────────"; }
sec(){ echo ""; sep; echo "## ${1}"; sep; }
kv(){ printf '%-26s %s\n' "${1}" "${2}"; }
have(){ command -v "${1}" > /dev/null 2>&1 && echo "yes" || echo "no"; }
cfg(){ grep -m1 "^${1}=" "${SETTING}" 2>/dev/null | cut -d= -f2-; }

# 自动停止分析：把命令行取证收敛成 WebUI 可读的结论
analyze_auto_stop(){
    sec "服务自动停止分析"
    kv "时间" "$(date '+%Y-%m-%d %H:%M:%S')"
    kv "service.state" "$(cat "${TMP_PATH}/service.state" 2>/dev/null || echo 无)"
    kv "service.abnormal" "$(cat "${TMP_PATH}/service.abnormal" 2>/dev/null || echo 无)"

    heartbeat=$(cat "${TMP_PATH}/watchdog.heartbeat" 2>/dev/null)
    if [ -n "${heartbeat}" ]; then
        heartbeat_age=$(( $(date +%s) - heartbeat ))
        kv "watchdog.heartbeat" "${heartbeat_age}s 前"
    else
        kv "watchdog.heartbeat" "无"
    fi

    for service_name in smartdns AdGuardHome mihomo watchdog.sh; do
        service_pid=$(pidof "${service_name}" 2>/dev/null)
        [ -z "${service_pid}" ] && service_pid=$(pgrep -f "${service_name}" 2>/dev/null | head -n 1)
        if [ -n "${service_pid}" ]; then
            kv "${service_name}" "PID ${service_pid}, oom=$(cat "/proc/${service_pid}/oom_score_adj" 2>/dev/null)"
        else
            kv "${service_name}" "未运行"
        fi
    done

    event_log="${TMP_PATH}/diag.events.$$"
    cat "${TMP_PATH}/module.log" "${TMP_PATH}/module.log.1" "${TMP_PATH}/module.log.boot.1" 2>/dev/null | \
        grep "SERVICE-EVENT" | tail -n 40 > "${event_log}" 2>/dev/null

    echo ""
    echo "最近 SERVICE-EVENT:"
    if [ -s "${event_log}" ]; then
        sed 's/^/  /' "${event_log}"
    else
        echo "  无"
    fi

    stop_requested=$(grep -c "stop requested" "${event_log}" 2>/dev/null)
    watchdog_restarts=$(grep -c "watchdog restart" "${event_log}" 2>/dev/null)
    wifi_stops=$(grep -c "stopped-by-wifi" "${event_log}" 2>/dev/null)
    kv "stop requested 次数" "${stop_requested:-0}"
    kv "watchdog restart 次数" "${watchdog_restarts:-0}"
    kv "WiFi 黑名单停止次数" "${wifi_stops:-0}"

    # 真实击杀证据必须能对上进程名/内核 OOM 记录。小米的
    # "IOMEM: handleLmkdMessage cmd: N" 只是厂商守护进程收到 lmkd 消息的
    # 日志，不含任何被杀的 PID/进程名——把它当证据会得出"被系统杀"的错误
    # 结论(2026-10-25 实际踩过: 真因是启动失败，却被判成 OOM)
    kill_pattern="lowmemorykiller|oom-kill|killinfo|Kill process|Force stopping .*(smartdns|AdGuardHome|mihomo)|ActivityManager.*(smartdns|AdGuardHome|mihomo)"
    kill_evidence=""
    lmkd_noise=""
    snapshot_found=0
    echo ""
    echo "auto-stop 取证文件:"
    for snapshot_file in "${TMP_PATH}"/auto-stop.*.log; do
        [ -f "${snapshot_file}" ] || continue
        snapshot_found=1
        echo "  --- ${snapshot_file##*/} ---"
        ls -l "${snapshot_file}" 2>/dev/null | sed 's/^/    /'
        # 服务自身日志尾部最能说明"自己退出"还是"被外力杀掉"
        grep -E "^(out|log):" "${snapshot_file}" 2>/dev/null | tail -n 3 | sed 's/^/    /'
        grep -iE "${kill_pattern}" "${snapshot_file}" 2>/dev/null | tail -n 8 | sed 's/^/    /'
        snapshot_kill=$(grep -icE "${kill_pattern}" "${snapshot_file}" 2>/dev/null)
        [ "${snapshot_kill:-0}" -gt 0 ] && kill_evidence=1
        grep -q "handleLmkdMessage" "${snapshot_file}" 2>/dev/null && lmkd_noise=1
    done
    [ ${snapshot_found} -eq 0 ] && echo "  暂无 auto-stop.*.log（服务尚未发生异常消失，或 watchdog 也被同时杀死）"

    # 启动失败统计: "服务根本没起来"(配置/权限/解释器/软链)与"起来后被杀死"
    # 是两种完全不同的故障，必须分开统计才能给出正确结论
    echo ""
    echo "启动失败线索(module.log):"
    start_fail_total=0
    for fail_bin in smartdns AdGuardHome mihomo; do
        fail_count=$(grep -c "${fail_bin} 启动失败" "${TMP_PATH}/module.log" 2>/dev/null)
        kv "  ${fail_bin} 启动失败次数" "${fail_count:-0}"
        if [ "${fail_count:-0}" -gt 0 ]; then
            start_fail_total=$((start_fail_total + fail_count))
            grep "${fail_bin} 日志:" "${TMP_PATH}/module.log" 2>/dev/null | tail -n 1 | sed 's/^/    最后一次原因: /'
        fi
    done

    echo ""
    echo "MIUI/系统限制:"
    kv "  MIUI" "$(getprop ro.miui.ui.version.name 2>/dev/null)"
    if command -v dumpsys > /dev/null 2>&1; then
        dumpsys deviceidle whitelist 2>/dev/null | grep -E "SAM|smartdns|AdGuardHome|mihomo" | sed 's/^/    /'
    fi

    echo ""
    echo "结论:"
    if [ "${start_fail_total}" -gt 0 ] && [ -z "${kill_evidence}" ]; then
        echo "  倾向启动失败/自行退出(不是被系统杀)：module.log 有 ${start_fail_total} 次服务启动失败记录。"
        echo "  下一步：看 tmp/<服务>.out 最后几行(上面 service own log 段)，那是服务自己吐的失败原因。"
        echo "  常见原因：软链/解释器缺失、端口被占、配置校验不过、二进制权限。"
    elif [ -n "${kill_evidence}" ]; then
        echo "  存在进程级击杀证据(内核 OOM / ActivityManager / Force stopping)，服务是被外力杀掉的。"
        echo "  注意：oom_score_adj=-1000 只挡住内核 OOM 与 LMKD 的分数选择，挡不住厂商守护进程与 kill -9。"
        echo "  建议：设为无限制后台、关闭电池优化、锁定最近任务，并观察 watchdog 心跳。"
    elif [ "${wifi_stops:-0}" -gt 0 ] && [ "${wifi_stops:-0}" -ge "${stop_requested:-0}" ]; then
        echo "  倾向 WiFi 黑名单触发停止：存在 stopped-by-wifi。"
    elif [ "${stop_requested:-0}" -gt 0 ]; then
        echo "  存在模块主动停止记录：优先检查手动停止/保存配置/卸载或 WiFi 黑名单链路。"
    elif [ "${watchdog_restarts:-0}" -gt 0 ]; then
        echo "  服务曾异常消失并由 watchdog 拉起，但当前没有系统杀进程证据。"
        echo "  若自动停止后本报告仍无 auto-stop 文件，说明 watchdog 可能也被一起杀死。"
    elif [ -n "${heartbeat}" ] && [ ${heartbeat_age:-0} -gt 120 ]; then
        echo "  watchdog 心跳过期：优先排查 watchdog 自身被杀，服务停止只是结果。"
    else
        echo "  当前没有足够证据区分系统杀后台与模块停止，请在下次自动停止后立即重新分析。"
    fi

    # 只出现厂商的 handleLmkdMessage 而没有任何进程级击杀记录时，明确说明
    # 它不算证据，避免下次又按"被系统杀"去调后台策略
    if [ -n "${lmkd_noise}" ] && [ -z "${kill_evidence}" ]; then
        echo "  说明：日志里的 IOMEM/handleLmkdMessage 是厂商守护进程收到 lmkd 消息的记录，"
        echo "        不含我们进程的 PID/名称，不作为击杀证据。"
    fi

    rm -f "${event_log}" 2>/dev/null
}

# ── 0. 运行身份门禁 ─────────────────────────────────────
# 非 root 时 iptables / dumpsys / pidof / 模块目录全部不可访问，
# 会得到一整篇「Permission denied + 未运行 + 缺失」的假结论，比不跑更浪费时间。
if [ "$(id -u)" != "0" ]; then
    echo "[×] 当前 uid=$(id -u)，不是 root，本报告无效。"
    echo ""
    echo "    非 root 下这些必然失败、且失败原因会被误判成模块故障:"
    echo "      iptables / ip6tables  -> Permission denied"
    echo "      dumpsys / cmd wifi    -> 空输出"
    echo "      pidof / busybox       -> 不在 PATH"
    echo "      /data/adb/modules/SAM -> 目录不可遍历，会被判成「模块未激活」"
    echo ""
    echo "    请用 root 执行:"
    echo "      su -c \"sh $0\""
    echo "    临时 root 且没有 su 命令时，改用 WebUI「工具 → 一键诊断」。"
    exit 1
fi

if [ ${AUTO_STOP_ONLY} -eq 1 ]; then
    analyze_auto_stop
    exit 0
fi

echo "SAM 诊断报告"
kv "时间" "$(date '+%Y-%m-%d %H:%M:%S')"
kv "机型/系统" "$(getprop ro.product.model) / Android $(getprop ro.build.version.release)"
kv "模块版本" "$(grep -m1 '^version=' "${MODULE_PATH}/module.prop" 2>/dev/null | cut -d= -f2-)"
kv "uid" "$(id -u)"

# ── 1. 模块目录与运行环境 ────────────────────────────────
sec "1. 模块目录 / 运行环境"

if [ -d "${MODULE_PATH}" ]; then
    kv "active 目录" "存在"
else
    kv "active 目录" "缺失 —— 模块未激活"
fi

if [ -d "${UPDATE_DIR}" ]; then
    kv "待激活包" "存在(${UPDATE_DIR})"
    echo "    >>> 这就是管理器显示「待重启/激活生效」的直接原因。"
    echo "    >>> 软重启不会合并该目录，需执行: sh ${MODULE_PATH}/scripts/manual.sh activate"
else
    kv "待激活包" "无"
fi

kv "module.prop 描述" "$(grep -m1 '^description=' "${MODULE_PATH}/module.prop" 2>/dev/null | cut -d= -f2-)"

# tmp 可写性：三服务的日志重定向与 AGH 配置临时文件都落在这里
if [ -d "${TMP_PATH}" ]; then
    if ( : > "${TMP_PATH}/.diag.$$" ) 2>/dev/null; then
        rm -f "${TMP_PATH}/.diag.$$"
        kv "tmp 可写" "yes"
    else
        kv "tmp 可写" "NO  <<< 三服务都会启动失败，AGH 会报配置异常"
    fi
else
    kv "tmp 目录" "不存在"
fi

# AGH 配置目录可写性不再直接探测：诊断必须只读。
# 配置生成失败会在 service/agh 日志里体现，避免为了探测写 .diag 文件。
kv "etc/AdGuardHome 存在" "$([ -d "${AGH_PATH}" ] && echo yes || echo no)"

kv "磁盘剩余(/data)" "$(df -h /data 2>/dev/null | awk 'NR==2{print $4" / 已用 "$5}')"
kv "tmp 占用" "$(du -sh "${TMP_PATH}" 2>/dev/null | awk '{print $1}')"

echo ""
echo "关键命令:"
kv "  busybox" "$(have busybox)"
if command -v busybox > /dev/null 2>&1 && busybox setuidgid root:net_raw true > /dev/null 2>&1; then
    kv "  busybox setuidgid" "OK"
    kv "  busybox 路径" "$(command -v busybox)"
elif command -v setuidgid > /dev/null 2>&1 && setuidgid root:net_raw true > /dev/null 2>&1; then
    kv "  busybox setuidgid" "busybox 不可用，独立 setuidgid 可用"
else
    kv "  busybox setuidgid" "FAIL <<< 三服务将以 root 降级启动(见 module.log)"
fi
kv "  setsid" "$(have setsid)"
kv "  inotifyd" "$(have inotifyd)"
kv "  pidof" "$(have pidof)"
kv "  ss" "$(have ss)"
kv "  netstat" "$(have netstat)"
kv "  curl" "$(have curl)"
# 用 id <组名> 查 AID：Android 10+ 的 /system/etc/group 并不完整，
# 用 grep group 文件会误报「组不存在」
if id net_raw > /dev/null 2>&1; then
    kv "  net_raw 组" "$(id net_raw 2>/dev/null | tr -d '\n')"
else
    kv "  net_raw 组" "缺失  <<< chown root:net_raw 会失败"
fi
if id net_admin > /dev/null 2>&1; then
    kv "  net_admin 组" "$(id net_admin 2>/dev/null | tr -d '\n')"
else
    kv "  net_admin 组" "缺失  <<< chown root:net_admin 会失败(Mihomo 需要)"
fi

echo ""
echo "SmartDNS 软链:"
# 三种状态必须分开: 悬空链(-L 真/-e 假)是更新后 mv 目录的典型后果，
# 只看 -e 会显示"缺失"，让人误以为是没建过链接
smartdns_link_state(){
    [ -e "${1}" ] && { echo "存在"; return 0; }
    if [ -L "${1}" ]; then
        echo "悬空 -> $(readlink "${1}" 2>/dev/null)"
    else
        echo "缺失"
    fi
}
smartdns_link_missing=0
for smartdns_link in \
    "${MODULE_PATH}/bin/smartdns" \
    "${MODULE_PATH}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" \
    "${MODULE_PATH}/etc/SmartDNS/lib/ld-linux.so"; do
    smartdns_link_now=$(smartdns_link_state "${smartdns_link}")
    kv "  ${smartdns_link#${MODULE_PATH}/}" "${smartdns_link_now}"
    [ "${smartdns_link_now}" = "存在" ] || smartdns_link_missing=1
done
[ "${smartdns_link_missing}" = "1" ] && \
    echo "  >>> 软链不可用会导致 setuidgid: can't execute 'smartdns'。执行 service.sh restart 由 ensure_module_links 重建(悬空链会自动删除重建)"
kv "  smartdns 可执行" "$([ -x "${MODULE_PATH}/etc/SmartDNS/smartdns" ] && echo yes || echo NO)"
kv "  AdGuardHome 可执行" "$([ -x "${MODULE_PATH}/bin/AdGuardHome" ] && echo yes || echo NO)"

# ── 2. 服务进程与端口 ────────────────────────────────────
sec "2. 服务进程 / 端口"

for bin in smartdns AdGuardHome mihomo; do
    pid=$(pidof "${bin}" 2>/dev/null)
    kv "${bin}" "${pid:-未运行}"
done

echo ""
echo "监听端口(53/1053/3721/5300/3000/9090):"
if command -v ss > /dev/null 2>&1; then
    ss -lnut 2>/dev/null | grep -E ":(53|1053|3721|5300|3000|9090)[[:space:]]" || echo "  无匹配"
elif command -v netstat > /dev/null 2>&1; then
    netstat -lnut 2>/dev/null | grep -E ":(53|1053|3721|5300|3000|9090)[[:space:]]" || echo "  无匹配"
else
    echo "  缺少 ss / netstat"
    for p in 53 1053 3721 5300 3000; do
        grep -q ":$(printf '%04X' "${p}") " /proc/net/tcp 2>/dev/null && echo "  tcp ${p} 在监听"
    done
fi

echo ""
echo "AGH 配置自检:"
if [ -x "${MODULE_PATH}/bin/AdGuardHome" ]; then
    agh_check_work="${TMP_PATH}/diag.agh.$$"
    mkdir -p "${agh_check_work}" 2>/dev/null
    agh_check_status=0
    agh_check=$("${MODULE_PATH}/bin/AdGuardHome" --check-config -c "${AGH_CONF}" -w "${agh_check_work}" 2>&1) || agh_check_status=$?
    rm -rf "${agh_check_work}" 2>/dev/null
    echo "${agh_check}" | sed 's/^/  /'
    kv "  check-config" "$([ ${agh_check_status} -eq 0 ] && echo PASS || echo "FAIL(${agh_check_status})")"
    kv "  schema_version" "$(grep -m1 '^schema_version:' "${AGH_CONF}" 2>/dev/null | awk '{print $2}')"
    if [ -s "${TMP_PATH}/agh.config.bad" ]; then
        kv "  已暂停自动拉起" "$(cat "${TMP_PATH}/agh.config.bad.reason" 2>/dev/null || echo 未知)"
    fi
    kv "  dns.port" "$(awk '/^dns:/{f=1} f&&/^  port:/{print $2; exit}' "${AGH_CONF}" 2>/dev/null)"
    echo "  upstream_dns:"
    awk '/^  upstream_dns:/{f=1;next} f&&/^    - /{print "    "$2} f&&!/^    - /{exit}' "${AGH_CONF}" 2>/dev/null | sed 's/^/  /'
else
    echo "  AdGuardHome 不可执行，跳过"
fi

echo ""
echo "服务日志尾部:"
# smartdns.log 是 SmartDNS 自己的运行日志(log-file ../../tmp/smartdns.log)，
# smartdns.out 只是 stdout/stderr。排查"上游慢"要看 smartdns.log，不是 .out。
for f in "${TMP_PATH}/AdGuardHome.log" "${TMP_PATH}/smartdns.log" "${TMP_PATH}/smartdns.out" "${TMP_PATH}/mihomo.log"; do
    if [ -f "${f}" ]; then
        echo "  --- ${f} (最后 15 行) ---"
        tail -n 15 "${f}" 2>/dev/null | sed 's/^/    /'
    fi
done

echo ""
echo "错误聚合(三个服务日志中的 error/warn):"
for f in "${TMP_PATH}/AdGuardHome.log" "${TMP_PATH}/smartdns.log"; do
    [ -f "${f}" ] || continue
    err_count=$(grep -icE "error|warn|fail|timeout" "${f}" 2>/dev/null)
    kv "  ${f##*/} 命中行数" "${err_count:-0}"
    grep -iE "error|warn|fail|timeout" "${f}" 2>/dev/null | tail -n 12 | sed 's/^/    /'
done

if [ -f "${TMP_PATH}/module.log" ]; then
    echo "  --- module.log 中的 ERROR (最后 15 条) ---"
    grep "ERROR" "${TMP_PATH}/module.log" 2>/dev/null | tail -n 15 | sed 's/^/    /'
fi

# ── 3. 防火墙规则 ────────────────────────────────────────
sec "3. 防火墙规则"

echo "IPv4 nat (DNS 劫持):"
iptables -w 100 -t nat -S REDIRECT_DNS 2>&1 | sed 's/^/  /'
iptables -w 100 -t nat -S OUTPUT 2>/dev/null | grep -E "REDIRECT|BLOCK" | sed 's/^/  OUTPUT: /'

echo ""
echo "DNS 入口(规则期望端口 vs 当前监听):"
sh "${MODULE_PATH}/scripts/iptables/dns.sh" check 2>&1 | sed 's/^/  /'

echo ""
echo "IPv6 filter (DNS 阻断，含计数):"
ip6tables -w 100 -t filter -L BLOCK_IPV6_DNS -v -n 2>&1 | sed 's/^/  /'
kv "  阻断方式" "$(cat "${TMP_PATH}/ipv6.block.mode" 2>/dev/null || echo 未记录)"

echo ""
echo "IPv6 nat 支持:"
# 必须区分「内核没有 nat 表」和「当前身份没有权限」：
# 权限不足时 ip6tables 返回非 0，直接看退出码会把后者误判成前者
v6nat_out=$(ip6tables -w 100 -t nat -L 2>&1)
case "${v6nat_out}" in
    *"Permission denied"*|*"must be root"*)
        echo "  无法判断(权限不足)" ;;
    *"can't initialize"*|*"does not exist"*|*"No such file"*)
        echo "  no(该内核无 ip6tables nat)" ;;
    *)
        echo "  yes" ;;
esac

echo ""
echo "TUN 转发规则:"
iptables -w 100 -S FORWARD 2>/dev/null | grep -E "Meta|tun" | sed 's/^/  /' || echo "  无"

# ── 4. 当前网络与 DNS 服务器 ─────────────────────────────
sec "4. 当前网络 / 系统 DNS"

net_type="未知"
if command -v cmd > /dev/null 2>&1; then
    wifi_status=$(cmd wifi status 2>/dev/null)
    case "${wifi_status}" in
        *"Wifi is enabled"*|*"enabled"*)
            ssid=$(echo "${wifi_status}" | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
            [ -n "${ssid}" ] && net_type="WiFi(${ssid})"
            ;;
    esac
fi
kv "网络类型" "${net_type}"

echo ""
echo "系统下发的 DNS 服务器(dumpsys connectivity):"
if command -v dumpsys > /dev/null 2>&1; then
    dumpsys connectivity 2>/dev/null | grep -oE "DnsAddresses: \[[^]]*\]" | head -3 | sed 's/^/  /'
else
    echo "  无 dumpsys"
fi

echo ""
echo "私人 DNS(Private DNS):"
if command -v settings > /dev/null 2>&1; then
    private_dns_mode=$(settings get global private_dns_mode 2>/dev/null)
    private_dns_host=$(settings get global private_dns_specifier 2>/dev/null)
    echo "  mode: ${private_dns_mode:-未知}  host: ${private_dns_host:-无}"
    case "${private_dns_mode}" in
        off|null|"") ;;
        *) echo "  >>> 已开启时会走 853 端口，不经过本模块的 53 重定向；计数不动时先检查这里" ;;
    esac
else
    echo "  无 settings 命令"
fi

echo ""
echo "IPv6 DNS 地址(系统配置):"
if command -v dumpsys > /dev/null 2>&1; then
    dumpsys connectivity 2>/dev/null | grep -oE "DnsAddresses: \[[^]]*\]" | head -3 | grep -oE "[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){2,}" | head -5 | sed 's/^/  /'
    echo "  (若上面有地址、而下面 counters 在涨，就是 WiFi 慢的主因)"
fi

echo ""
echo "接口 MTU:"
ip -o link 2>/dev/null | awk '{print "  "$2" mtu "$5}' | head -10

# ── 5. 解析耗时实测 ─────────────────────────────────────
sec "5. DNS 解析耗时实测(走模块链路)"

if command -v curl > /dev/null 2>&1; then
    for d in www.baidu.com www.qq.com github.com; do
        t=$(curl -s -o /dev/null -m 8 -w "%{time_namelookup}" "https://${d}/" 2>/dev/null)
        kv "  ${d}" "${t}s"
    done
else
    echo "  无 curl，改用 ping 首次解析"
    for d in www.baidu.com github.com; do
        ping -c 1 -W 3 "${d}" > /dev/null 2>&1 && echo "  ${d} 解析成功" || echo "  ${d} 解析失败/超时"
    done
fi

echo ""
echo "SmartDNS 关键参数:"
for k in "response-mode" "speed-check-mode" "rr-ttl-min" "dualstack-ip-selection" "cache-size"; do
    kv "  ${k}" "$(grep -m1 "^${k} " "${SD_CONF}" 2>/dev/null | cut -d' ' -f2-)"
done
echo ""
echo "模块设置:"
for k in SMARTDNS_RESPONSE_MODE SMARTDNS_SPEED_CHECK SMARTDNS_TTL_MIN SMARTDNS_DUALSTACK \
         BLOCK_IPV6_DNS MODULE_DNS_MODE LAN_ACCESS NETWORK_REFRESH BYPASS_ENABLE \
         MIHOMO_ENABLE AGH_ENABLE SMARTDNS_ENABLE; do
    kv "  ${k}" "$(cfg "${k}")"
done

# ── 6. IPv6 阻断增量采样 ───────────────────────────────
if [ "${WATCH_SEC}" -gt 0 ]; then
    sec "6. IPv6 DNS 阻断增量采样(${WATCH_SEC}s)"
    count_v6_block(){
        ip6tables -w 100 -t filter -L BLOCK_IPV6_DNS -v -n 2>/dev/null | \
            awk '/udp/ && (/DROP/ || /REJECT/) {sum += $1} END {print sum + 0}'
    }
    before=$(count_v6_block)
    echo "  起始计数: ${before:-0}"
    sleep "${WATCH_SEC}"
    after=$(count_v6_block)
    echo "  结束计数: ${after:-0}"
    delta=$(( ${after:-0} - ${before:-0} ))
    echo "  增量: ${delta} 个 IPv6 DNS 包被阻断"
    echo "  >>> 增量 > 0 且网络是 WiFi 时，说明系统在向 IPv6 DNS 发查询并被本模块拦截。"
    echo "      REJECT 会立即回退 IPv4；若诊断上方显示阻断方式为 DROP，则仍可能等超时。"
fi

echo ""
echo "服务停止取证(区分系统杀后台 / 模块自身停止):"
kv "  service.state" "$(cat "${TMP_PATH}/service.state" 2>/dev/null || echo 无)"
kv "  service.abnormal" "$(cat "${TMP_PATH}/service.abnormal" 2>/dev/null || echo 无)"
kv "  watchdog.heartbeat" "$(cat "${TMP_PATH}/watchdog.heartbeat" 2>/dev/null || echo 无)"
for service_name in smartdns AdGuardHome mihomo watchdog.sh; do
    service_pid=$(pidof "${service_name}" 2>/dev/null)
    [ -z "${service_pid}" ] && service_pid=$(pgrep -f "${service_name}" 2>/dev/null | head -n 1)
    if [ -n "${service_pid}" ]; then
        kv "  ${service_name} oom_score_adj" "$(cat "/proc/${service_pid}/oom_score_adj" 2>/dev/null)"
    fi
done
for f in "${TMP_PATH}/module.log" "${TMP_PATH}/module.log.1" "${TMP_PATH}/module.log.boot.1"; do
    [ -f "${f}" ] || continue
    echo "  --- ${f##*/} 中的 SERVICE-EVENT/ERROR (最后 20 条) ---"
    grep -E "SERVICE-EVENT|ERROR" "${f}" 2>/dev/null | tail -n 20 | sed 's/^/    /'
done

echo ""
echo "小米/系统后台限制线索:"
kv "  MIUI 版本" "$(getprop ro.miui.ui.version.name 2>/dev/null)"
kv "  Android 版本" "$(getprop ro.build.version.release 2>/dev/null)"
kv "  SELinux" "$(getenforce 2>/dev/null || echo 未知)"
if command -v dumpsys > /dev/null 2>&1; then
    echo "  deviceidle 白名单:"
    dumpsys deviceidle whitelist 2>/dev/null | grep -E "SAM|smartdns|AdGuardHome|mihomo" | sed 's/^/    /'
    echo "  最近 LMKD/ActivityManager 杀进程线索:"
    logcat -d -t 500 2>/dev/null | grep -iE "lowmemorykiller|lmkd|ActivityManager.*kill|Force stopping|Scheduling restart" | tail -n 20 | sed 's/^/    /'
else
    echo "  无 dumpsys，无法读取系统后台限制信息"
fi

echo ""
echo "建议采集命令(发生自动停止后立即执行):"
echo "  su -c 'sh ${MODULE_PATH}/scripts/diagnose.sh --watch 15'"
echo "  su -c 'logcat -d -t 1000 | grep -iE \"lmkd|ActivityManager|kill|Scheduling restart\"'"
echo "  su -c 'dumpsys deviceidle whitelist'"
echo "  小米设置中将 SAM/SmartDNS/AdGuardHome/Mihomo 设为无限制后台、关闭电池优化，并锁定最近任务"

echo ""
sep
echo "诊断结束。把整段输出回传即可定位。"
