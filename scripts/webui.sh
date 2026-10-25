#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 获取「期望运行」的服务数量
# Mihomo 没有订阅时本来就起不来，不计入期望值，否则界面会误报"启动失败"
get_service_number(){
    number=0

    [ "${SMARTDNS_ENABLE}" = "true" ] && number=$((number + 1))
    [ "${AGH_ENABLE}" = "true" ] && number=$((number + 1))
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        number=$((number + 1))
    fi

    echo ${number}
}

# 获取「实际运行」的服务数量
# 按服务计数而不是按进程计数；原先 pgrep -f 传多个模式是无效用法，结果永远是 0
get_process_number(){
    number=0

    [ "${SMARTDNS_ENABLE}" = "true" ] && isRun ${SMARTDNS_BIN} && number=$((number + 1))
    [ "${AGH_ENABLE}" = "true" ] && isRun ${AGH_BIN} && number=$((number + 1))
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        isRun ${MIHOMO_BIN} && number=$((number + 1))
    fi

    echo ${number}
}

# 获取挂载状态
get_mount_status(){
    hosts_mounted && echo "已挂载" || echo "未挂载"
}

# 获取监控
get_monitor_status(){
    status=$(get_monitor_pid "${1}")
    [ "${status}" ] && echo "已运行" || echo "未运行"
}

# 获取监控 pid
get_monitor_pid(){
    pid=$(pgrep -f "${SCRIPTS_PATH}/wifi.monitor.sh" 2>/dev/null)
    if [ "${1}" = "wifi" ]; then
        echo ${pid}
        return
    fi
    pid=$(pgrep -f "${INOTIFY_PATH}/host.sh" 2>/dev/null)
    if [ "${1}" = "host" ]; then
        echo ${pid}
        return
    fi
    pid=$(pgrep -l -f "${INOTIFY_PATH}/module.sh" 2>/dev/null | grep -E "inotifyd|busybox" | sed "s/ .*$//g")
    if [ "${1}" = "module" ]; then
        echo ${pid}
        return
    fi
}

# 杀死监控
kill_monitor(){
    pid_list=$(get_monitor_pid "${1}")
    # 没在运行就直接返回，避免 kill 空参数报错
    [ -z "${pid_list}" ] && return 0
    for pid in ${pid_list}; do
        kill ${pid} 2>/dev/null || kill -9 ${pid} 2>/dev/null
    done
    # 更新描述
    ${UPDATE_PATH}/desc.sh
}

# 启动监控
# 必须 detach: 从 WebUI 调用时进程挂在调用会话上，会话结束会被一起回收
start_monitor(){
    pid=$(get_monitor_pid "${1}")

    if [ "${1}" = "wifi" ] && [ -z "${pid}" ]; then
        detach_exec "${SCRIPTS_PATH}/wifi.monitor.sh" > /dev/null 2>&1
    elif [ "${1}" = "host" ] && [ -z "${pid}" ]; then
        if has_cmd inotifyd; then
            detach_exec inotifyd "${INOTIFY_PATH}/host.sh" "${MODULE_PATH}/etc" > /dev/null 2>&1
        else
            log "e" "缺少 inotifyd，无法启动 hosts 监控"
        fi
    elif [ -z "${pid}" ]; then
        if has_cmd inotifyd; then
            detach_exec inotifyd "${INOTIFY_PATH}/module.sh" "${MODULE_PATH}" > /dev/null 2>&1
        else
            log "e" "缺少 inotifyd，无法启动模块监控"
        fi
    fi

    # 更新描述
    ${UPDATE_PATH}/desc.sh
}

# 一次性输出全部状态
# WebUI 首屏从 10 次 exec 降到 1 次(每次 exec 都要 source 一遍 base.sh，开销不小)
get_all_status(){
    # 先取一次三个服务的运行状态，后面多处复用，避免重复 fork pidof
    smartdns_running="未运行"
    agh_running="未运行"
    mihomo_running="未运行"
    isRun ${SMARTDNS_BIN} && smartdns_running="已运行"
    isRun ${AGH_BIN} && agh_running="已运行"
    isRun ${MIHOMO_BIN} && mihomo_running="已运行"

    echo "smartdns=${smartdns_running}"
    echo "agh=${agh_running}"
    echo "mihomo=${mihomo_running}"
    mount | grep -q "/system/etc/hosts" && echo "host=已挂载" || echo "host=未挂载"

    wifi_pid=$(get_monitor_pid wifi)
    host_pid=$(get_monitor_pid host)
    module_pid=$(get_monitor_pid module)

    [ -n "${wifi_pid}" ] && echo "monitor_wifi=已运行" || echo "monitor_wifi=未运行"
    [ -n "${host_pid}" ] && echo "monitor_host=已运行" || echo "monitor_host=未运行"
    [ -n "${module_pid}" ] && echo "monitor_module=已运行" || echo "monitor_module=未运行"
    echo "monitor_wifi_pid=${wifi_pid}"
    echo "monitor_host_pid=${host_pid}"
    echo "monitor_module_pid=${module_pid}"

    echo "bypass=${BYPASS_ENABLE}"
    echo "service=$(get_service_number)"
    # 进程数直接由上面已取到的状态算出，不再重复调 isRun
    echo "process=$(get_process_number_from "${smartdns_running}" "${agh_running}" "${mihomo_running}")"

    # 模块描述是 KernelSU 模块页读取的值；用来区分"描述没写成"和"管理器缓存/待激活"
    module_desc=$(grep -m1 '^description=' "${MODULE_PATH}/module.prop" 2>/dev/null | cut -d= -f2-)
    echo "module_desc=${module_desc}"
    if [ -f "/data/adb/modules_update/SAM/module.prop" ]; then
        echo "pending_update=yes"
    else
        echo "pending_update=no"
    fi
    if [ -s "${TMP_PATH}/agh.config.bad" ]; then
        echo "agh_config=bad"
        agh_bad_reason=$(cat "${TMP_PATH}/agh.config.bad.reason" 2>/dev/null)
        echo "agh_config_reason=${agh_bad_reason:-unknown}"
    else
        echo "agh_config=ok"
    fi
    echo "agh_schema=$(grep -m1 '^schema_version:' "${AGH_CONF}" 2>/dev/null | awk '{print $2}')"

    # 守护循环与 DNS 规则状态: 服务异常退出后这两项最能说明问题
    if pgrep -f "${SCRIPTS_PATH}/watchdog.sh" > /dev/null 2>&1; then
        echo "watchdog=运行中"
    else
        echo "watchdog=未运行"
    fi
    # SmartDNS 实际监听端口(配置可被 sd.sh 按 LAN_ACCESS 改写)，供服务页端口说明动态显示
    echo "smartdns_port=$(smartdns_port)"
    resolve_dns_entry
    echo "dns_rule=$(check_dns_rule)"
    echo "dns_entry=${dns_entry_label}"
}

# 用已取到的运行状态算进程数，避免再次 fork pidof
get_process_number_from(){
    number=0

    [ "${SMARTDNS_ENABLE}" = "true" ] && [ "${1}" = "已运行" ] && number=$((number + 1))
    [ "${AGH_ENABLE}" = "true" ] && [ "${2}" = "已运行" ] && number=$((number + 1))
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        [ "${3}" = "已运行" ] && number=$((number + 1))
    fi

    echo ${number}
}

# 解析当前实际 DNS 入口
# 解析状态页要显示的 DNS 入口(与 base.sh dns_entry_port 同一回退链)
# 顺序必须与建规则的一方一致，否则会出现"规则其实正常但显示异常"的误报。
# 入口只代表 53 端口被转发到哪里：下游命中 SmartDNS 缓存时，它的查询计数
# 可能不变，这是正常现象。直通模式本来就不该有重定向规则，不能显示成"异常"
resolve_dns_entry(){
    dns_check_port=""
    dns_entry_label="未监听"

    if [ "${BYPASS_ENABLE}" = "true" ]; then
        dns_entry_label="直通模式"
        return 0
    fi

    dns_entry=$(dns_entry_port)
    if [ -n "${dns_entry}" ]; then
        dns_entry_label="${dns_entry}"
        dns_check_port="${dns_entry##*:}"
    fi
}

# 检查 DNS 重定向规则是否完整
# 不复用 dns.sh check: 那个子命令会重新 source 一遍 base.sh 并写临时文件，
# WebUI 每次刷新都调它，开销与整轮 allstatus 相当。这里直接查 iptables。
check_dns_rule(){
    [ "${BYPASS_ENABLE}" = "true" ] && {
        echo "直通模式"
        return 0
    }

    # 没有服务在跑时谈不上规则是否正确
    [ -z "${dns_check_port}" ] && {
        echo "端口未监听"
        return 0
    }

    if ${iptables_w} -t nat -L REDIRECT_DNS > /dev/null 2>&1 && \
       ${iptables_w} -t nat -C REDIRECT_DNS -p udp --dport 53 -j REDIRECT --to-ports ${dns_check_port} > /dev/null 2>&1 && \
       ${iptables_w} -t nat -C REDIRECT_DNS -p tcp --dport 53 -j REDIRECT --to-ports ${dns_check_port} > /dev/null 2>&1; then
        echo "正常"
    else
        echo "异常"
    fi
}

# 添加指令
case "$1" in
    status)
        isRun "${2}" && echo "已运行" || echo "未运行"
        ;;
    service)
        get_service_number
        ;;
    process)
        get_process_number
        ;;
    mount)
        get_mount_status
        ;;
    allstatus)
        get_all_status
        ;;
    monitor)
        get_monitor_status "${2}"
        ;;
    pid)
        get_monitor_pid "${2}"
        ;;
    start)
        start_monitor "${2}"
        ;;
    kill)
        kill_monitor "${2}"
        ;;
    *)
        echo "使用: status(服务状态) | allstatus(全部状态) | service(服务数量) | process(进程数量) | mount(挂载状态) | monitor(监控状态) | pid(监控pid) | start(启动监控) | kill(杀死监控)"
        exit 1
        ;;
esac
