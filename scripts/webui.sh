# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 获取「期望运行」的服务数量
# Mihomo 没有订阅时本来就起不来，不计入期望值，否则界面会误报"启动失败"
get_service_number(){
    number=0

    [ "${SMARTDNS_ENABLE}" = "true" ] && number=$((number + 1))
    [ "${AGH_ENABLE}" = "true" ] && number=$((number + 1))
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ]; then
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
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ]; then
        isRun ${MIHOMO_BIN} && number=$((number + 1))
    fi

    echo ${number}
}

# 获取挂载状态
get_mount_status(){
    status=$(mount | grep "/system/etc/hosts")
    [ "${status}" ] && echo "已挂载" || echo "未挂载"
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
    pid=$(get_monitor_pid "${1}")
    # 没在运行就直接返回，避免 kill 空参数报错
    [ -z "${pid}" ] && return 0
    kill ${pid} 2>/dev/null || kill -9 ${pid} 2>/dev/null
    # 更新描述
    ${UPDATE_PATH}/desc.sh
}

# 启动监控
start_monitor(){
    pid=$(get_monitor_pid "${1}")

    if [ "${1}" = "wifi" ] && [ -z "${pid}" ]; then
        ${SCRIPTS_PATH}/wifi.monitor.sh > /dev/null 2>&1 &
    elif [ "${1}" = "host" ] && [ -z "${pid}" ]; then
        if has_cmd inotifyd; then
            inotifyd "${INOTIFY_PATH}/host.sh" "${HOSTS_FILE}" > /dev/null 2>&1 &
        else
            log "e" "缺少 inotifyd，无法启动 hosts 监控"
        fi
    elif [ -z "${pid}" ]; then
        if has_cmd inotifyd; then
            inotifyd "${INOTIFY_PATH}/module.sh" "${MODULE_PATH}" > /dev/null 2>&1 &
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
    isRun ${SMARTDNS_BIN} && echo "smartdns=已运行" || echo "smartdns=未运行"
    isRun ${AGH_BIN} && echo "agh=已运行" || echo "agh=未运行"
    isRun ${MIHOMO_BIN} && echo "mihomo=已运行" || echo "mihomo=未运行"
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
    echo "process=$(get_process_number)"
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
