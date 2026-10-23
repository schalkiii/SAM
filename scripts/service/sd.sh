#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 启动
start(){
    # 判断 SmartDNS 未启用，则退出
    if [ "${SMARTDNS_ENABLE}" = false ]; then
        log "i" "${SMARTDNS_BIN} 未启用"
        return 1
    fi

    # 判断 SmartDNS 已运行，则退出
    isRun ${SMARTDNS_BIN} && {
        log "i" "${SMARTDNS_BIN} 已运行"
        return 1
    }
    
    # 按 LAN_ACCESS 决定监听地址(默认只监听回环，避免同 WiFi 设备直接用本机 DNS)
    if [ "${LAN_ACCESS}" = "true" ]; then
        bind_addr="[::]:3721"
    else
        bind_addr="127.0.0.1:3721"
    fi
    current_bind=$(grep -m1 "^bind " "${SMARTDNS_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${current_bind}" ] && [ "${current_bind}" != "${bind_addr}" ]; then
        sed -i "s|^bind .*|bind ${bind_addr}|" "${SMARTDNS_CONF}"
        log "i" "${SMARTDNS_BIN} 监听地址改为 ${bind_addr}"
    fi

    # 按设置改写响应模式 / 测速方式 / 双栈优选
    # 这三项直接决定"冷查询"要等多久，值变了才改文件
    new_response=$(grep -m1 "^response-mode " "${SMARTDNS_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${new_response}" ] && [ "${new_response}" != "${SMARTDNS_RESPONSE_MODE}" ]; then
        sed -i "s|^response-mode .*|response-mode ${SMARTDNS_RESPONSE_MODE}|" "${SMARTDNS_CONF}"
        log "i" "${SMARTDNS_BIN} 响应模式改为 ${SMARTDNS_RESPONSE_MODE}"
    fi

    new_speed=$(grep -m1 "^speed-check-mode " "${SMARTDNS_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${new_speed}" ] && [ "${new_speed}" != "${SMARTDNS_SPEED_CHECK}" ]; then
        sed -i "s|^speed-check-mode .*|speed-check-mode ${SMARTDNS_SPEED_CHECK}|" "${SMARTDNS_CONF}"
        log "i" "${SMARTDNS_BIN} 测速方式改为 ${SMARTDNS_SPEED_CHECK}"
    fi

    if [ "${SMARTDNS_DUALSTACK}" = "true" ]; then
        dualstack_value="yes"
    else
        dualstack_value="no"
    fi
    new_dualstack=$(grep -m1 "^dualstack-ip-selection " "${SMARTDNS_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${new_dualstack}" ] && [ "${new_dualstack}" != "${dualstack_value}" ]; then
        sed -i "s|^dualstack-ip-selection .*|dualstack-ip-selection ${dualstack_value}|" "${SMARTDNS_CONF}"
        log "i" "${SMARTDNS_BIN} 双栈优选改为 ${dualstack_value}"
    fi

    new_ttl=$(grep -m1 "^rr-ttl-min " "${SMARTDNS_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${new_ttl}" ] && [ "${new_ttl}" != "${SMARTDNS_TTL_MIN}" ]; then
        sed -i "s|^rr-ttl-min .*|rr-ttl-min ${SMARTDNS_TTL_MIN}|" "${SMARTDNS_CONF}"
        log "i" "${SMARTDNS_BIN} 缓存 TTL 下限改为 ${SMARTDNS_TTL_MIN}s"
    fi

    # 二进制与 musl 加载器软链必须存在，否则 exec 直接失败
    if [ ! -x "${SMARTDNS_PATH}/${SMARTDNS_BIN}" ]; then
        log "e" "${SMARTDNS_BIN} 二进制不存在: ${SMARTDNS_PATH}/${SMARTDNS_BIN}"
        return 1
    fi
    ensure_module_links

    # 进入工作路径，并启动
    cd ${SMARTDNS_PATH}
    export SMARTDNS_WORKDIR="${SMARTDNS_PATH}"
    # 用 setsid 让进程脱离调用方会话，避免 WebUI/会话结束时被一起回收
    # stdout/stderr 单独落一个文件，避免和 SmartDNS 自己的日志文件互相截断
    detach_exec busybox setuidgid "${SAM_USER}:${DNS_GROUP}" ${SMARTDNS_BIN} -c ${SMARTDNS_CONF} -p - >> "${TMP_PATH}/${SMARTDNS_BIN}.out" 2>&1
    #SMARTDNS_WORKDIR="${SMARTDNS_PATH}" exec su -g $(id -g ${DNS_GROUP}) -- nohup ${SMARTDNS_BIN} -c ${SMARTDNS_CONF} -p - > "${TMP_PATH}/${SMARTDNS_BIN}.log" 2>&1 &
    
    # 轮询等待就绪(最多 5 秒)，比固定 sleep 1 更可靠
    wait_ready=0
    while [ ${wait_ready} -lt 10 ] && ! isRun ${SMARTDNS_BIN}; do
        sleep 0.5 2>/dev/null || sleep 1
        wait_ready=$((wait_ready + 1))
    done
    if isRun ${SMARTDNS_BIN}; then
        # 进程在不代表端口已经 bind，DNS 规则依赖端口真正可用来选上游
        if wait_port "$(smartdns_port)"; then
            log "i" "${SMARTDNS_BIN} 启动成功"
        else
            log "e" "${SMARTDNS_BIN} 进程已启动但端口 $(smartdns_port) 未监听"
        fi
        # 免被系统 LMKD 回收
        protect_process "$(isRun ${SMARTDNS_BIN} "pid")"
    else
        log "e" "${SMARTDNS_BIN} 启动失败"
        # 把最后一行日志带上，便于定位是缺 loader、配置错还是端口占用
        if [ -f "${TMP_PATH}/${SMARTDNS_BIN}.out" ]; then
            log "e" "${SMARTDNS_BIN} 日志: $(tail -n 1 "${TMP_PATH}/${SMARTDNS_BIN}.out" 2>/dev/null)"
        fi
    fi
}

# 停止
stop(){
    # 判断 SmartDNS 未运行，则退出
    isRun ${SMARTDNS_BIN} || {
        log "i" "${SMARTDNS_BIN} 已停止"
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
