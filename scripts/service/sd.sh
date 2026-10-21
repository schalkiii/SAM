# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 启动
start(){
    # 判断 SmartDNS 未启用，则退出
    if [ ${SMARTDNS_ENABLE} = false ]; then
        log "e" "${SMARTDNS_BIN} 未启用"
        return 1
    fi
    
    # 判断 SmartDNS 已运行，则退出
    isRun ${SMARTDNS_BIN} && {
        log "e" "${SMARTDNS_BIN} 已运行"
        return 1
    }
    
    # 进入工作路径，并启动
    cd ${SMARTDNS_PATH}
    SMARTDNS_WORKDIR="${SMARTDNS_PATH}" exec busybox setuidgid "${SAM_USER}:${DNS_GROUP}" ${SMARTDNS_BIN} -c ${SMARTDNS_CONF} -p - > "${TMP_PATH}/${SMARTDNS_BIN}.log" 2>&1 &
    #SMARTDNS_WORKDIR="${SMARTDNS_PATH}" exec su -g $(id -g ${DNS_GROUP}) -- nohup ${SMARTDNS_BIN} -c ${SMARTDNS_CONF} -p - > "${TMP_PATH}/${SMARTDNS_BIN}.log" 2>&1 &
    
    # 轮询等待就绪(最多 5 秒)，比固定 sleep 1 更可靠
    wait_ready=0
    while [ ${wait_ready} -lt 10 ] && ! isRun ${SMARTDNS_BIN}; do
        sleep 0.5 2>/dev/null || sleep 1
        wait_ready=$((wait_ready + 1))
    done
    isRun ${SMARTDNS_BIN} && log "i" "${SMARTDNS_BIN} 启动成功" || log "e" "${SMARTDNS_BIN} 启动失败"
}

# 停止
stop(){
    # 判断 SmartDNS 未运行，则退出
    isRun ${SMARTDNS_BIN} || {
        log "e" "${SMARTDNS_BIN} 已停止"
        return 1
    }
    # 杀死 SmartDNS 进程
    kill_process ${SMARTDNS_BIN} && log "i" "${SMARTDNS_BIN} 停止成功" || log "e" "${SMARTDNS_BIN} 停止失败"
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