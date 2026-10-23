#!/system/bin/sh
# 手动立即卸载: sh uninstall.sh now
# 说明: 临时 root 环境无法通过"打 remove 标记 + 硬重启"卸载(Magisk 永远等不到那次重启)，
#       这里提供当场卸载入口，直接停服务、清规则、删目录
if [ "$1" = "now" ]; then
    MODULE_PATH="/data/adb/modules/SAM"
    if [ -f "${MODULE_PATH}/scripts/manual.sh" ]; then
        sh "${MODULE_PATH}/scripts/manual.sh" uninstall
    else
        rm -rf "/data/adb/modules/SAM" "/data/adb/modules_update/SAM"
        echo "已删除模块目录"
    fi
    exit 0
fi

# 卸载逻辑必须同步执行:
# Magisk/KernelSU 在 uninstall.sh 返回后就会删除模块目录，
# 放到后台会在脚本/配置被删掉之后才去备份和恢复广告文件。
MODULE_PATH="/data/adb/modules/SAM"
SCRIPTS_PATH="${MODULE_PATH}/scripts"

# 先停服务，避免备份/恢复过程中还有进程在写配置
[ -f "${SCRIPTS_PATH}/service.sh" ] && sh "${SCRIPTS_PATH}/service.sh" stop > /dev/null 2>&1

# 备份全部配置(备份目录在 /data/adb/SAM-backup，root-only，不依赖 /sdcard)
[ -f "${SCRIPTS_PATH}/backup.sh" ] && sh "${SCRIPTS_PATH}/backup.sh" save

# 恢复 App 广告文件(新方案是把内容改名保留，这里改回原名)
[ -f "${SCRIPTS_PATH}/ad.sh" ] && "${SCRIPTS_PATH}/ad.sh" recovery

# 清理广告备份清单(在模块目录外, 卸载时不会自动消失)
rm -f "/data/adb/SAM-ad-hold.list"

# 卸载 hosts 绑定，避免残留挂载
mount | grep -q " /system/etc/hosts " && umount "/system/etc/hosts" 2>/dev/null

# 直接删除，不依赖 reboot 与 remove 标记
rm -rf "${MODULE_PATH}"
rm -rf "/data/adb/modules_update/SAM"
