#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 启动
# 返回码语义: 0 = 正常(含"未启用/已运行")，1 = 真正失败
start(){
    # 判断 crontabs 未启用，则退出
    if [ "${CRONTAB_ENABLE}" = false ]; then
        log "i" "定时执行已禁用"
        return 0
    fi

    # 判断 crontabs 已运行，则退出
    isRun "${MODULE_PATH}/etc/crontabs" && {
        log "i" "crontabs 正在运行"
        return 0
    }
    # 启动
    busybox crond -c "$MODULE_PATH/etc/crontabs/"
    # 延时 1秒
    sleep 1
    # 输出 crontabs 状态
    if isRun "${MODULE_PATH}/etc/crontabs"; then
        log "i" "crontabs 启动成功"
        return 0
    fi
    log "e" "crontabs 启动失败"
    return 1
}

# 停止
# 返回码语义: 0 = 已停止(含本来就没运行)，1 = kill 失败
stop(){
    # crontabs 没有运行则退出
    isRun "${MODULE_PATH}/etc/crontabs" || {
        log "i" "crontabs 已停止"
        return 0
    }
    # 杀死 crontabs 进程
    if kill_process "${MODULE_PATH}/etc/crontabs"; then
        log "i" "crontabs 停止成功"
        return 0
    fi
    log "e" "crontabs 停止失败"
    return 1
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
