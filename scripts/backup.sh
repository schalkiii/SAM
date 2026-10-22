#!/system/bin/sh
# 配置备份 / 恢复
#
# 原先只备份 Mihomo 配置，其余配置在卸载时直接随模块目录被删掉。
# 这里把用户真正会调的东西一起备份到 /sdcard/SAM-backup/<时间戳>/：
#   setting.conf、AdGuardHome.yaml、smartdns.conf、mihomo config.yaml、
#   黑白名单、hosts、定时任务
#
# 用法:
#   sh backup.sh save      备份一份(最多保留 5 份)
#   sh backup.sh list      列出已有备份
#   sh backup.sh restore   恢复最近一份

source "/data/adb/modules/SAM/scripts/base.sh"

BACKUP_ROOT="/sdcard/SAM-backup"
BACKUP_FILES="setting.conf etc/AdGuardHome/AdGuardHome.yaml etc/SmartDNS/smartdns.conf etc/mihomo/config.yaml etc/app_blacklist.prop etc/app_whitelist.prop etc/hosts etc/crontabs/root"
KEEP_BACKUP=5

# 备份
save_backup(){
    [ "${BACKUP_CONF}" = "true" ] || {
        echo "已关闭卸载备份(BACKUP_CONF=false)"
        return 0
    }

    backup_stamp=$(date "+%Y%m%d-%H%M%S")
    backup_dir="${BACKUP_ROOT}/${backup_stamp}"
    mkdir -p "${backup_dir}" || {
        echo "无法创建备份目录 ${backup_dir}"
        return 1
    }

    backup_count=0
    for backup_file in ${BACKUP_FILES}; do
        backup_src="${MODULE_PATH}/${backup_file}"
        [ -f "${backup_src}" ] || continue

        # 保留完整相对路径(含文件名)，
        # 不能用 cp 到目录的方式: 那样 "etc/crontabs/root" 会被存成
        # "<备份>/etc/crontabs/root"，而恢复时按同一相对路径拼回来会变成
        # "<备份>/etc/crontabs/etc/crontabs/root" —— 路径重复，定时任务恢复不出来。
        backup_target="${backup_dir}/${backup_file}"
        mkdir -p "$(dirname "${backup_target}")" 2>/dev/null
        cp -f "${backup_src}" "${backup_target}" && backup_count=$((backup_count + 1))
    done

    # 兼容旧路径，避免老用户找不到
    if [ -f "${MODULE_PATH}/etc/mihomo/config.yaml" ]; then
        cp -f "${MODULE_PATH}/etc/mihomo/config.yaml" "/sdcard/Mihomo配置.yaml" 2>/dev/null
    fi

    # 只保留最近 5 份
    ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUP + 1)) | while read -r old_backup; do
        rm -rf "${old_backup}"
    done

    echo "已备份 ${backup_count} 个文件到 ${backup_dir}"
}

# 列出备份
list_backup(){
    backup_list=$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null)
    if [ -z "${backup_list}" ]; then
        echo "暂无备份"
        return 0
    fi
    echo "${backup_list}" | sed "s|${BACKUP_ROOT}/||; s|/$||"
}

# 恢复最近一份
restore_backup(){
    latest_backup=$(ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r | head -n 1)
    if [ -z "${latest_backup}" ]; then
        echo "暂无备份可恢复"
        return 1
    fi

    restore_count=0
    for restore_file in ${BACKUP_FILES}; do
        restore_src="${latest_backup}${restore_file}"
        [ -f "${restore_src}" ] || continue

        restore_target="${MODULE_PATH}/${restore_file}"
        mkdir -p "$(dirname "${restore_target}")" 2>/dev/null
        cp -f "${restore_src}" "${restore_target}" && restore_count=$((restore_count + 1))
    done

    echo "已从 ${latest_backup} 恢复 ${restore_count} 个文件"
}

case "${1}" in
    save)
        save_backup
        ;;
    list)
        list_backup
        ;;
    restore)
        restore_backup
        ;;
    *)
        echo "用法: backup.sh save | list | restore"
        exit 1
        ;;
esac
