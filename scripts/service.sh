#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 服务状态文件(守护循环据此决定是否自动拉起)
STATE_FILE="${TMP_PATH}/service.state"
# 异常标记文件: 停止前发现"本该在跑的服务已经不在了"，说明它是被系统回收的
ABNORMAL_FILE="${TMP_PATH}/service.abnormal"
# 停止原因: stopped(用户手动) / stopped-by-wifi(WiFi 黑名单触发)
# 两者都不该被守护循环拉起，但只有前者不该被 WiFi 监控重新拉起
stop_reason="stopped"

# 判断是否有"本该运行却已经消失"的服务
# 用于识别: 服务不是被用户停的，而是被系统(LMKD/OOM/会话回收)杀掉的
detect_abnormal(){
    abnormal=0

    [ "${SMARTDNS_ENABLE}" = "true" ] && ! isRun ${SMARTDNS_BIN} && abnormal=1
    [ "${AGH_ENABLE}" = "true" ] && ! isRun ${AGH_BIN} && abnormal=1
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        ! isRun ${MIHOMO_BIN} && abnormal=1
    fi

    return ${abnormal}
}

# 启动
start(){
    # 补齐 SmartDNS 的软链接(软重启/临时 root 下开机脚本不会执行)
    ensure_module_links

    # 启动 SmartDNS
    ${SERVICE_PATH}/sd.sh start
    if [ "${BYPASS_ENABLE}" = "true" ]; then
        # 直通模式的目的是让系统使用网络下发的 DNS；
        # Mihomo 的 TUN(auto-route + dns-hijack) 会在路由层继续劫持 DNS，必须停掉。
        # 只保留 SmartDNS/AdGuardHome 供 WebUI 查看与订阅更新。
        ${SERVICE_PATH}/mihomo.sh stop
        ${IPTABLES_PATH}/mihomo.sh del
        ${SERVICE_PATH}/agh.sh start
    elif [ "${MODULE_DNS_MODE}" = "2" ]; then
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
        # dns.sh enable 现在会校验链内规则与当前端口是否一致，
        # 端口变了(服务掉过线)会自动重建，不会留下指向死端口的旧规则
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
            detach_exec "${SCRIPTS_PATH}/wifi.monitor.sh" > /dev/null 2>&1
        fi
    else
        for wifi_monitor_pid in $(pgrep -f "${SCRIPTS_PATH}/wifi.monitor.sh" 2>/dev/null); do
            kill -9 ${wifi_monitor_pid} 2>/dev/null
        done
    fi
    # 屏蔽 app 广告文件、更新 host 都依赖大量 IO 与网络，
    # 放后台执行，避免点"启动服务"要等几十秒才返回(离线时 curl 各自要等 10 秒超时)
    if [ "${AD_BLOCK_ENABLE}" = "true" ]; then
        detach_exec "${SCRIPTS_PATH}/ad.sh" block > /dev/null 2>&1
    elif [ -s "${AD_HOLD_LIST}" ]; then
        # 关闭开关必须真正解除屏蔽，否则"App 异常时关掉此项"的提示就是无效的
        detach_exec "${SCRIPTS_PATH}/ad.sh" recovery > /dev/null 2>&1
    fi
    # 已卸载 App 的 immutable 空壳会阻止系统清理数据，启动时自动解除
    if [ -s "${AD_HOLD_LIST}" ]; then
        detach_exec "${SCRIPTS_PATH}/ad.sh" cleanup > /dev/null 2>&1
    fi
    if [ "${HOST_ENABLE}" = "true" ]; then
        # 只更新文件不挂载是不会生效的，这里补上挂载动作
        # (在 WebUI 里把「Hosts 挂载」从关改到开时，走的就是这条路径)
        mount | grep -q " /system/etc/hosts " || mount -o bind "${MODULE_PATH}/etc/hosts" /system/etc/hosts
        detach_exec "${UPDATE_PATH}/host.sh" update > /dev/null 2>&1
    else
        # 关掉开关时要真正卸载，否则旧 hosts 会一直生效
        mount | grep -q " /system/etc/hosts " && umount /system/etc/hosts 2>/dev/null
    fi

    # 确保模块 / hosts 监控在跑
    # 放在 hosts 挂载之后，否则首次启动时 hosts 还没挂上，host 监控不会被拉起
    # 开机脚本只在真开机时执行，从 WebUI 启动时这两类监控可能根本不存在
    if has_cmd inotifyd; then
        if ! pgrep -f "${INOTIFY_PATH}/module.sh" > /dev/null 2>&1; then
            detach_exec inotifyd "${INOTIFY_PATH}/module.sh" "${MODULE_PATH}" > /dev/null 2>&1
        fi
        if mount | grep -q " /system/etc/hosts "; then
            if ! pgrep -f "${INOTIFY_PATH}/host.sh" > /dev/null 2>&1; then
                detach_exec inotifyd "${INOTIFY_PATH}/host.sh" "${MODULE_PATH}/etc" > /dev/null 2>&1
            fi
        fi
    fi

    # 更新描述
    ${UPDATE_PATH}/desc.sh

    # 标记为运行中，并启动守护循环
    # 守护循环必须重定向输出，否则 WebUI 调用时会一直占用管道、等不到命令结束
    # 同时用 setsid 让它脱离当前会话，避免调用方退出时守护循环被一起回收
    echo running > "${STATE_FILE}"
    if ! pgrep -f "${SCRIPTS_PATH}/watchdog.sh" > /dev/null 2>&1; then
        detach_exec "${SCRIPTS_PATH}/watchdog.sh" > /dev/null 2>&1
    fi

    # 上一次停止时发现服务已经异常消失(被系统回收)，
    # 说明系统的网络状态可能已经被判成"无网络"，恢复后需要重新验证一次
    if [ -f "${ABNORMAL_FILE}" ]; then
        rm -f "${ABNORMAL_FILE}"
        if [ "${NETWORK_REFRESH}" = "true" ]; then
            log "i" "检测到上次服务曾异常退出，刷新一次网络"
            refresh_network
        fi
    fi
}

# 停止
stop(){
    # 记录停止前的状态: 只有"本来在运行"的服务消失了，才算异常退出
    prev_state="$(cat "${STATE_FILE}" 2>/dev/null)"

    # 先标记为已停止，避免守护循环在停止过程中把服务又拉起来
    echo "${stop_reason}" > "${STATE_FILE}"

    # 停止前先看服务是否"本该在跑却已经没了"，
    # 这种情况下记一笔异常，下次启动后自动刷一次网络
    case "${prev_state}" in
        running|"")
            if detect_abnormal; then
                echo "$(date '+%Y-%m-%d %H:%M:%S')" > "${ABNORMAL_FILE}"
                log "i" "检测到有服务已异常退出(非手动停止)"
            fi
            ;;
    esac

    # 先撤销规则再停服务：反过来的话，服务已停、规则还在，DNS 会短暂进黑洞
    # 删除 DNS 规则
    ${IPTABLES_PATH}/dns.sh disable
    # 删除 TUN 规则
    ${IPTABLES_PATH}/mihomo.sh del
    # 删除屏蔽 IP 规则(即使当前设置为 false 也要清理历史遗留规则)
    ${IPTABLES_PATH}/ip.sh disable
    # 停止 SmartDNS
    ${SERVICE_PATH}/sd.sh stop
    # 停止 AdGuardHome
    ${SERVICE_PATH}/agh.sh stop
    # 停止 Mihomo
    ${SERVICE_PATH}/mihomo.sh stop
    # 停止 crontabs
    ${SERVICE_PATH}/crontabs.sh stop
    # 更新描述
    ${UPDATE_PATH}/desc.sh
}

# 添加指令
case "$1" in
    # 启动
    start)
        # 不再 rm -rf tmp/*: 会把其他进程正在用的 setting.clean.* 一起删掉，
        # 表现为"设置文件语法错误 ... no such file or directory"
        log "i" "start >>>"
        start
        log "i" "<<< start"
        ;;
    # 停止
    stop)
        # 不再清空日志: 之前的实现直接截断 module.log，
        # 恰好把"服务为什么掉线"的证据一起抹掉了(停止时正是最需要看日志的时候)。
        # 改为保留上一份日志为 module.log.1，当前日志重新开始。
        if [ -s "${LOG_FILE}" ]; then
            mv -f "${LOG_FILE}" "${LOG_FILE}.1"
        fi
        : > "${LOG_FILE}"
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
    # 刷新网络(手动开关一次飞行模式)
    refresh)
        refresh_network
        ;;
esac
