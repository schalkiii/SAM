# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 服务状态文件(守护循环据此决定是否自动拉起)
STATE_FILE="${TMP_PATH}/service.state"
# 停止原因: stopped(用户手动) / stopped-by-wifi(WiFi 黑名单触发)
# 两者都不该被守护循环拉起，但只有前者不该被 WiFi 监控重新拉起
stop_reason="stopped"

# 启动
start(){
    # 启动 SmartDNS
    ${SERVICE_PATH}/sd.sh start
    if [ "${MODULE_DNS_MODE}" = "2" ]; then
        # 启动 AdGuardHome
        ${SERVICE_PATH}/agh.sh start
        # 启动 Mihomo
        ${SERVICE_PATH}/mihomo.sh start
    else
        # 启动 Mihomo
        ${SERVICE_PATH}/mihomo.sh start
        # 启动 AdGuardHome
        ${SERVICE_PATH}/agh.sh start
    fi
    # 添加 DNS 规则
    # 直通模式下不劫持，但服务进程照常运行，WebUI 仍然可访问
    if [ "${BYPASS_ENABLE}" = "true" ]; then
        log "i" "直通模式已开启，跳过 DNS 劫持规则"
    else
        ${IPTABLES_PATH}/dns.sh enable
    fi
    # 添加屏蔽 IP 规则
    [ "${IP_IPTABLES}" = "true" ] && ${IPTABLES_PATH}/ip.sh enable
    # 启动 crontabs
    ${SERVICE_PATH}/crontabs.sh start
    # WiFi 黑名单监控: 名单非空才需要
    # 原先只在开机脚本里启动，导致在 WebUI 里新加黑名单后要重启才生效
    if [ "${#BLACKLIST_WIFI[@]}" -ne 0 ]; then
        if ! pgrep -f "${SCRIPTS_PATH}/wifi.monitor.sh" > /dev/null 2>&1; then
            ${SCRIPTS_PATH}/wifi.monitor.sh > /dev/null 2>&1 &
        fi
    else
        for wifi_monitor_pid in $(pgrep -f "${SCRIPTS_PATH}/wifi.monitor.sh" 2>/dev/null); do
            kill -9 ${wifi_monitor_pid} 2>/dev/null
        done
    fi
    # 屏蔽 app 广告文件、更新 host 都依赖大量 IO 与网络，
    # 放后台执行，避免点"启动服务"要等几十秒才返回(离线时 curl 各自要等 10 秒超时)
    if [ "${AD_BLOCK_ENABLE}" = "true" ]; then
        ${SCRIPTS_PATH}/ad.sh block > /dev/null 2>&1 &
    fi
    if [ "${HOST_ENABLE}" = "true" ]; then
        # 只更新文件不挂载是不会生效的，这里补上挂载动作
        # (在 WebUI 里把「Hosts 挂载」从关改到开时，走的就是这条路径)
        mount | grep -q " /system/etc/hosts " || mount -o bind "${MODULE_PATH}/etc/hosts" /system/etc/hosts
        ${UPDATE_PATH}/host.sh update > /dev/null 2>&1 &
    else
        # 关掉开关时要真正卸载，否则旧 hosts 会一直生效
        mount | grep -q " /system/etc/hosts " && umount /system/etc/hosts 2>/dev/null
    fi
    # 更新描述
    ${UPDATE_PATH}/desc.sh

    # 标记为运行中，并启动守护循环
    # 守护循环必须重定向输出，否则 WebUI 调用时会一直占用管道、等不到命令结束
    echo running > "${STATE_FILE}"
    ${SCRIPTS_PATH}/watchdog.sh > /dev/null 2>&1 &
}

# 停止
stop(){
    # 先标记为已停止，避免守护循环在停止过程中把服务又拉起来
    echo "${stop_reason}" > "${STATE_FILE}"

    # 停止 SmartDNS
    ${SERVICE_PATH}/sd.sh stop
    # 停止 AdGuardHome
    ${SERVICE_PATH}/agh.sh stop
    # 停止 Mihomo
    ${SERVICE_PATH}/mihomo.sh stop
    # 删除 DNS 规则
    ${IPTABLES_PATH}/dns.sh disable
    # 删除 TUN 规则
    ${IPTABLES_PATH}/mihomo.sh del
    # 删除屏蔽 IP 规则
    [ "${IP_IPTABLES}" = "true" ] && ${IPTABLES_PATH}/ip.sh disable
    # 停止 crontabs
    ${SERVICE_PATH}/crontabs.sh stop
    # 更新描述
    ${UPDATE_PATH}/desc.sh
}

# 添加指令
case "$1" in
    # 启动
    start)
        rm -rf "${TMP_PATH}/"*
        log "i" "start >>>"
        start
        log "i" "<<< start"
        ;;
    # 停止
    stop)
        > "${LOG_FILE}"
        # 支持停止原因: sh service.sh stop stopped-by-wifi
        stop_reason="${2:-stopped}"
        log "i" "stop >>>"
        stop
        log "i" "<<< stop"
        ;;
    # 重启
    restart)
        log "i" "restart >>>"
        stop
        start
        log "i" "<<< restart"
        ;;
esac
