#!/system/bin/sh
# 配置备份 / 恢复
#
# 原先只备份 Mihomo 配置，其余配置在卸载时直接随模块目录被删掉。
# 这里把用户真正会调的东西一起备份到 /data/adb/SAM-backup/<时间戳>/：
#   setting.conf、AdGuardHome.yaml、smartdns.conf、mihomo config.yaml、
#   黑白名单、hosts、定时任务
#
# 备份目录放在 /data/adb 而不是 /sdcard:
#   1. 含订阅链接/节点密码，/sdcard 对其他有存储权限的应用可见
#   2. restore 直接信任备份内容(含 crontabs/root)，放 /sdcard 会被篡改成 root 命令入口
#   3. /data/adb 在卸载后仍保留，且 root-only
#
# 用法:
#   sh backup.sh save      备份一份(最多保留 5 份)
#   sh backup.sh list      列出已有备份
#   sh backup.sh restore   恢复最近一份

source "/data/adb/modules/SAM/scripts/base.sh"

BACKUP_ROOT="/data/adb/SAM-backup"
BACKUP_FILES="setting.conf etc/AdGuardHome/AdGuardHome.yaml etc/SmartDNS/smartdns.conf etc/mihomo/config.yaml etc/app_blacklist.prop etc/app_whitelist.prop etc/hosts etc/crontabs/root"
BACKUP_DIRS="etc/AdGuardHome/data etc/SmartDNS/data etc/mihomo/proxy_provider etc/mihomo/rule_provider"
KEEP_BACKUP=5

# 备份
save_backup(){
    [ "${BACKUP_CONF}" = "true" ] || {
        echo "已关闭卸载备份(BACKUP_CONF=false)"
        return 0
    }

    backup_stamp=$(date "+%Y%m%d-%H%M%S").$$
    backup_dir="${BACKUP_ROOT}/${backup_stamp}"
    mkdir -p "${backup_dir}" || {
        echo "无法创建备份目录 ${backup_dir}"
        return 1
    }
    # 备份含订阅链接与节点密码，只允许 root 读取
    chmod 700 "${BACKUP_ROOT}" 2>/dev/null

    backup_count=0
    backup_failed=0
    for backup_file in ${BACKUP_FILES}; do
        backup_src="${MODULE_PATH}/${backup_file}"
        [ -f "${backup_src}" ] || continue

        # 保留完整相对路径(含文件名)，
        # 不能用 cp 到目录的方式: 那样 "etc/crontabs/root" 会被存成
        # "<备份>/etc/crontabs/root"，而恢复时按同一相对路径拼回来会变成
        # "<备份>/etc/crontabs/etc/crontabs/root" —— 路径重复，定时任务恢复不出来。
        backup_target="${backup_dir}/${backup_file}"
        mkdir -p "$(dirname "${backup_target}")" 2>/dev/null
        if cp -f "${backup_src}" "${backup_target}"; then
            backup_count=$((backup_count + 1))
        else
            backup_failed=1
            echo "备份失败: ${backup_file}"
        fi
    done

    # 用户数据目录也必须备份，否则 AGH 自定义过滤器/SmartDNS 缓存/Mihomo 提供商会丢
    for backup_dir_name in ${BACKUP_DIRS}; do
        backup_src="${MODULE_PATH}/${backup_dir_name}"
        [ -d "${backup_src}" ] || continue
        backup_target="${backup_dir}/${backup_dir_name}"
        mkdir -p "$(dirname "${backup_target}")" 2>/dev/null
        if cp -R -f "${backup_src}/." "${backup_target}" 2>/dev/null; then
            backup_count=$((backup_count + 1))
        else
            backup_failed=1
            echo "备份失败: ${backup_dir_name}"
        fi
    done

    # 兼容旧路径的便捷副本，同样放在 root-only 目录
    if [ -f "${MODULE_PATH}/etc/mihomo/config.yaml" ]; then
        cp -f "${MODULE_PATH}/etc/mihomo/config.yaml" "${BACKUP_ROOT}/Mihomo配置.yaml" 2>/dev/null
    fi

    # 只保留最近 5 份
    ls -1d "${BACKUP_ROOT}"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUP + 1)) | while read -r old_backup; do
        rm -rf "${old_backup}"
    done

    if [ ${backup_failed} -ne 0 ]; then
        echo "备份未完整完成，保留现有备份文件"
        return 1
    fi
    echo "已备份 ${backup_count} 个文件/目录到 ${backup_dir}"
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
    restore_failed=0
    for restore_file in ${BACKUP_FILES}; do
        restore_src="${latest_backup}${restore_file}"
        [ -f "${restore_src}" ] || continue

        restore_target="${MODULE_PATH}/${restore_file}"
        mkdir -p "$(dirname "${restore_target}")" 2>/dev/null
        if cp -f "${restore_src}" "${restore_target}"; then
            restore_count=$((restore_count + 1))
        else
            restore_failed=1
            echo "恢复失败: ${restore_file}"
        fi
    done
    for restore_dir in ${BACKUP_DIRS}; do
        restore_src="${latest_backup}${restore_dir}"
        [ -d "${restore_src}" ] || continue
        restore_target="${MODULE_PATH}/${restore_dir}"
        mkdir -p "${restore_target}" 2>/dev/null
        if cp -R -f "${restore_src}/." "${restore_target}" 2>/dev/null; then
            restore_count=$((restore_count + 1))
        else
            restore_failed=1
            echo "恢复失败: ${restore_dir}"
        fi
    done

    if [ ${restore_failed} -ne 0 ]; then
        echo "备份恢复未完整完成，请检查磁盘与权限"
        return 1
    fi
    echo "已从 ${latest_backup} 恢复 ${restore_count} 个文件/目录"

    # 恢复后让新配置生效；用户主动停止服务时不要擅自拉起
    case "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" in
        stopped*)
            echo "服务当前处于停止状态，未自动启动"
            ;;
        *)
            if [ -f "${SCRIPTS_PATH}/service.sh" ]; then
                echo "重启服务使配置生效..."
                sh "${SCRIPTS_PATH}/service.sh" restart
            fi
            ;;
    esac
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
