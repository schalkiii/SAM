#!/system/bin/sh
EVENT=$1
MONITOR_DIR=$2
MONITOR_FILE=$3

# 模块路径
MODULE_PATH="/data/adb/modules/SAM"
# 脚本路径
SCRIPTS_PATH="${MODULE_PATH}/scripts"
# Mihomo 配置的便捷备份(与 backup.sh 同目录，root-only)
MIHOMO_CONF="/data/adb/SAM-backup/Mihomo配置.yaml"
SYSTEM_HOSTS="/system/etc/hosts"

# 杀本模块的常驻监控(不杀当前这个 module.sh 监控进程)
kill_monitors(){
    for monitor_pid in $(pgrep -f "${SCRIPTS_PATH}/watchdog.sh" 2>/dev/null) \
                        $(pgrep -f "${SCRIPTS_PATH}/wifi.monitor.sh" 2>/dev/null) \
                        $(pgrep -f "${SCRIPTS_PATH}/inotify/host.sh" 2>/dev/null); do
        kill -9 "${monitor_pid}" 2>/dev/null
    done
}

# 模块禁用/移除时停干净: 服务、规则、hosts 挂载、监控
stop_all(){
    [ -f "${SCRIPTS_PATH}/service.sh" ] && sh "${SCRIPTS_PATH}/service.sh" stop > /dev/null 2>&1
    if mount | grep -q " ${SYSTEM_HOSTS} "; then
        umount "${SYSTEM_HOSTS}" 2>/dev/null
    fi
    kill_monitors
}

# 判断模块是否启用
if [ "${MONITOR_FILE}" = "disable" ]; then
    if [ "${EVENT}" = "d" ]; then
        # disable 文件被删除 = 重新启用
        ${SCRIPTS_PATH}/service.sh start
    elif [ "${EVENT}" = "n" ]; then
        # 模块被禁用时只停服务是不够的，hosts 挂载和监控也必须撤掉
        stop_all
    fi
fi

# 判断模块是否卸载
if [ "${MONITOR_FILE}" = "remove" ]; then
    if [ "${EVENT}" = "n" ]; then
        # Magisk 在 uninstall.sh 返回后会删除模块目录；
        # 这里先把配置备份和广告恢复做完，避免走到重启后的竞态
        stop_all
        [ -f "${SCRIPTS_PATH}/backup.sh" ] && sh "${SCRIPTS_PATH}/backup.sh" save > /dev/null 2>&1
        [ -f "${SCRIPTS_PATH}/ad.sh" ] && "${SCRIPTS_PATH}/ad.sh" recovery > /dev/null 2>&1
        if [ -f "${MODULE_PATH}/etc/mihomo/config.yaml" ] && grep -q "BACKUP_CONF=true" "${MODULE_PATH}/setting.conf" 2>/dev/null; then
            mkdir -p "$(dirname "${MIHOMO_CONF}")" 2>/dev/null
            cp -f "${MODULE_PATH}/etc/mihomo/config.yaml" "${MIHOMO_CONF}" 2>/dev/null
        fi
    elif [ "${EVENT}" = "d" ]; then
        # remove 标记被删除 = 取消卸载；模块本身仍是禁用状态时不要拉起服务
        rm -f "${MIHOMO_CONF}" 2>/dev/null
        [ -f "${MODULE_PATH}/disable" ] || ${SCRIPTS_PATH}/service.sh start
    fi
fi
