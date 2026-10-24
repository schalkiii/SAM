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

    # 启动前清理 BOM/CR；UTF-16 明确报错，不自动转换
    sanitize_config "${AGH_CONF}"
    if [ $? -eq 2 ]; then
        log "e" "${AGH_BIN} 配置未修复，取消启动"
        cksum "${AGH_CONF}" 2>/dev/null | awk '{print $1" "$2}' > "${TMP_PATH}/agh.config.bad"
        return 1
    fi

    # 更新 AdGuardHome 配置
    if ! ${UPDATE_PATH}/agh.sh; then
        log "e" "${AGH_BIN} 配置生成失败，取消启动"
        return 1
    fi

    # 启动前做一次 YAML 自检：坏配置直接拒绝启动并暂停守护循环重试，
    # 避免每 5 秒反复 attempt + 刷日志
    if ! agh_check_output=$("${AGH_BIN}" --check-config -c "${AGH_CONF}" -w "${AGH_PATH}" 2>&1); then
        log "e" "${AGH_BIN} 配置校验失败，已暂停自动拉起；请修复 AGH 配置后重启服务"
        log "e" "${AGH_BIN} 校验输出: $(printf '%s\n' "${agh_check_output}" | tail -n 3 | tr '\n' ' ')"
        cksum "${AGH_CONF}" 2>/dev/null | awk '{print $1" "$2}' > "${TMP_PATH}/agh.config.bad"
        return 1
    fi
    rm -f "${TMP_PATH}/agh.config.bad"

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
