#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

EVENT=$1
WATCH_PATH=$2
WATCH_NAME=$3

# 系统 hosts 文件路径
SYSTEM_HOSTS="/system/etc/hosts"
# 日志文件
LOG_FILE="${TMP_PATH}/hosts.log"

# 监听目录时只处理 hosts 本身的变更；兼容旧版本直接监听文件(此时 WATCH_NAME 为空)
if [ -n "${WATCH_NAME}" ] && [ "${WATCH_NAME}" != "hosts" ]; then
    exit 0
fi

# mv 会先产生 moved_to，编辑器保存则产生 close_write/modify；
# 这些事件都意味着磁盘上的 hosts 已经换成新内容，需要重挂
case "${EVENT}" in
    m|0|w)
        [ "${HOST_ENABLE}" = "true" ] || exit 0
        log "i" "检测到 hosts 文件发生改变"
        log "i" "重新挂载 hosts 文件"
        if remount_hosts; then
            log "i" "重新挂载成功"
        else
            log "e" "重新挂载失败"
        fi
        ;;
esac
