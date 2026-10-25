#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 启动
start(){
    # 判断 Mihomo 未启用，则退出
    if [ "${MIHOMO_ENABLE}" = false ]; then
        log "i" "${MIHOMO_BIN} 未启用"
        return 1
    fi

    # 本地短路: 没订阅时 Mihomo 起不来。外部"是否该运行"的判定统一用
    # base.sh 的 mihomo_expected(启用 + 有订阅 + 非直通)，这里只做启动前检查
    if [ ${#SUB_URL[@]} = 0 ]; then
        log "i" "未填写订阅地址，无法启动 ${MIHOMO_BIN}"
        return 1
    fi

    # 判断 Mihomo 已运行，则退出
    isRun ${MIHOMO_BIN} && {
        log "i" "${MIHOMO_BIN} 已运行"
        return 1
    }

    # 更新 Mihomo 配置
    if ! ${UPDATE_PATH}/mihomo.sh; then
        log "e" "${MIHOMO_BIN} 配置生成失败，取消启动"
        return 1
    fi
    # 更新代理名单
    if ! ${UPDATE_PATH}/proxy.sh; then
        log "e" "${MIHOMO_BIN} 代理名单生成失败，取消启动"
        return 1
    fi

    # 启动
    # 用 setsid 让进程脱离调用方会话，避免 WebUI/会话结束时被一起回收
    service_exec "${SAM_USER}:${TUN_GROUP}" ${MIHOMO_BIN} -d ${MIHOMO_PATH} >> "${TMP_PATH}/${MIHOMO_BIN}.log" 2>&1

    # 轮询等待就绪(最多 5 秒)
    wait_ready=0
    while [ ${wait_ready} -lt 10 ] && ! isRun ${MIHOMO_BIN}; do
        sleep 0.5 2>/dev/null || sleep 1
        wait_ready=$((wait_ready + 1))
    done
    if isRun ${MIHOMO_BIN}; then
        if wait_port "${MIHOMO_DNS_PORT}"; then
            log "i" "${MIHOMO_BIN} 启动成功"
        else
            log "e" "${MIHOMO_BIN} 进程已启动但 DNS 端口 ${MIHOMO_DNS_PORT} 未监听"
        fi
        # 免被系统 LMKD 回收
        protect_process "$(isRun ${MIHOMO_BIN} "pid")"
        # 添加 TUN 规则
        ${IPTABLES_PATH}/mihomo.sh add
    else
        log "e" "${MIHOMO_BIN} 启动失败"
        if [ -f "${TMP_PATH}/${MIHOMO_BIN}.log" ]; then
            log "e" "${MIHOMO_BIN} 日志: $(tail -n 1 "${TMP_PATH}/${MIHOMO_BIN}.log" 2>/dev/null)"
        fi
    fi
}

# 停止
stop(){
    # 判断 Mihomo 未运行，则退出
    isRun ${MIHOMO_BIN} || {
        log "i" "${MIHOMO_BIN} 已停止"
        return 1
    }
    # 杀死 Mihomo 进程
    kill_process ${MIHOMO_BIN} && log "i" "${MIHOMO_BIN} 停止成功" || log "e" "${MIHOMO_BIN} 停止失败"
}

# 添加指令
case "$1" in
    # 启动
    start)
        start
        ;;
    # 停止
    stop)
        stop
        ;;
esac
