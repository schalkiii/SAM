#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 启动
start(){
    # 判断 AdGuardHome 未启用，则退出
    if [ "${AGH_ENABLE}" = false ]; then
        log "i" "${AGH_BIN} 未启用"
        return 1
    fi

    # 判断 AdGuardHome 已运行，则退出
    isRun ${AGH_BIN} && {
        log "i" "${AGH_BIN} 已运行"
        return 1
    }

    # 更新 AdGuardHome 配置
    if ! ${UPDATE_PATH}/agh.sh; then
        log "e" "${AGH_BIN} 配置生成失败，取消启动"
        return 1
    fi

    # 启动
    # 用 setsid 让进程脱离调用方会话，避免 WebUI/会话结束时被一起回收
    # 用 >> 追加而不是 > 截断，方便守护循环原地轮转日志
    detach_exec busybox setuidgid "${SAM_USER}:${DNS_GROUP}" ${AGH_BIN} -c ${AGH_CONF} -w ${AGH_PATH} --no-check-update >> "${TMP_PATH}/${AGH_BIN}.log" 2>&1

    # 轮询等待就绪(最多 5 秒)
    wait_ready=0
    while [ ${wait_ready} -lt 10 ] && ! isRun ${AGH_BIN}; do
        sleep 0.5 2>/dev/null || sleep 1
        wait_ready=$((wait_ready + 1))
    done
    if isRun ${AGH_BIN}; then
        if wait_port "${AGH_DNS_PORT}"; then
            log "i" "${AGH_BIN} 启动成功"
        else
            log "e" "${AGH_BIN} 进程已启动但 DNS 端口 ${AGH_DNS_PORT} 未监听"
        fi
        # 免被系统 LMKD 回收
        protect_process "$(isRun ${AGH_BIN} "pid")"
    else
        log "e" "${AGH_BIN} 启动失败"
        if [ -f "${TMP_PATH}/${AGH_BIN}.log" ]; then
            log "e" "${AGH_BIN} 日志: $(tail -n 1 "${TMP_PATH}/${AGH_BIN}.log" 2>/dev/null)"
        fi
    fi
}

# 停止
stop(){
    # 判断 AdGuardHome 未运行，则退出
    isRun ${AGH_BIN} || {
        log "i" "${AGH_BIN} 已停止"
        return 1
    }
    # 杀死 AdGuardHome 进程
    kill_process ${AGH_BIN} && log "i" "${AGH_BIN} 停止成功" || log "e" "${AGH_BIN} 停止失败"
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
