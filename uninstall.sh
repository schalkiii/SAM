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

{
    # 等待系统启动(最多 60 秒，避免卡死)
    waited=0
    while [ "$(getprop sys.boot_completed)" != "1" ] && [ ${waited} -lt 60 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    # 等待目录可用(最多 60 秒)
    waited=0
    while [ ! -d "/sdcard" ] && [ ${waited} -lt 60 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    # 模块路径
    MODULE_PATH="/data/adb/modules/SAM"
    # 脚本路径
    SCRIPTS_PATH="$MODULE_PATH/scripts"

    # 备份全部配置(setting / AdGuardHome / SmartDNS / Mihomo / 黑白名单 / hosts / 定时)
    [ -f "$SCRIPTS_PATH/backup.sh" ] && sh "$SCRIPTS_PATH/backup.sh" save

    # 恢复 App 广告文件(新方案是把内容改名保留，这里改回原名)
    [ -f "$SCRIPTS_PATH/ad.sh" ] && "$SCRIPTS_PATH/ad.sh" recovery

    # 清理广告备份清单(在模块目录外, 卸载时不会自动消失)
    rm -f "/data/adb/SAM-ad-hold.list"

    # 卸载 hosts 绑定，避免残留挂载
    mount | grep -q " /system/etc/hosts " && umount "/system/etc/hosts" 2>/dev/null

    # 删除模块目录(含待激活目录)
    rm -rf "$MODULE_PATH"
    rm -rf "/data/adb/modules_update/SAM"

} &
