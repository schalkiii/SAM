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
backup_ok=1
if [ -f "${SCRIPTS_PATH}/backup.sh" ]; then
    sh "${SCRIPTS_PATH}/backup.sh" save || backup_ok=0
fi
if [ ${backup_ok} -eq 0 ] && grep -q "^BACKUP_CONF=true" "${MODULE_PATH}/setting.conf" 2>/dev/null; then
    echo "配置备份失败，已中止卸载以避免丢失订阅/节点配置"
    exit 1
fi

# 恢复 App 广告文件(新方案是把内容改名保留，这里改回原名)
# 恢复失败时保留备份清单，避免 .samhold 数据变成无法定位的孤儿
ad_recovery_ok=1
if [ -f "${SCRIPTS_PATH}/ad.sh" ]; then
    "${SCRIPTS_PATH}/ad.sh" recovery || ad_recovery_ok=0
fi

# 清理广告备份清单(在模块目录外, 卸载时不会自动消失)
if [ ${ad_recovery_ok} -eq 1 ]; then
    rm -f "/data/adb/SAM-ad-hold.list"
else
    echo "广告文件未全部恢复，已中止卸载；请修复后重试 scripts/ad.sh recovery"
    exit 1
fi

# 卸载 hosts 绑定，避免残留挂载
# 叠挂时只摘一层会留下指向已删除模块文件的旧挂载，循环摘到没有为止
umount_try=0
while mount | grep -q " /system/etc/hosts "; do
    umount_try=$((umount_try + 1))
    [ "${umount_try}" -le 8 ] || break
    umount "/system/etc/hosts" 2>/dev/null || break
done

# 直接删除，不依赖 reboot 与 remove 标记
rm -rf "${MODULE_PATH}"
rm -rf "/data/adb/modules_update/SAM"

# 清理模块目录外的恢复入口与历史版本，避免 repair 复活已卸载模块
rm -f "/data/adb/SAM-activate.sh" "/data/adb/SAM-activate.log" 2>/dev/null
rm -rf "/data/adb/SAM.previous" 2>/dev/null
for sam_residue in /data/adb/SAM.rejected.* /data/adb/SAM.old.*; do
    [ -d "${sam_residue}" ] && rm -rf "${sam_residue}"
done
