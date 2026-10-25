#!/system/bin/sh
# 模块路径
MODULE_PATH="/data/adb/modules/SAM"
# 脚本路径
SCRIPTS_PATH="${MODULE_PATH}/scripts"
# 监控脚本目录
INOTIFY_PATH="${SCRIPTS_PATH}/inotify"

# 等待系统启动
# 说明: 临时 root 环境可能永远等不到完整的开机流程，这里最多等 60 秒，
#       超时后照常往下走，避免模块卡死在等待循环里
boot_waited=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ ${boot_waited} -lt 60 ]; do
    sleep 3
    boot_waited=$((boot_waited + 3))
done

# 准备缓存目录
[ -d "${MODULE_PATH}/tmp" ] || mkdir -p "${MODULE_PATH}/tmp"

# 删除日志及缓存文件
# 自动停止排查依赖历史日志，不能开机直接清空；只保留最近一份后重新开始。
if [ -s "${MODULE_PATH}/tmp/module.log" ]; then
    mv -f "${MODULE_PATH}/tmp/module.log" "${MODULE_PATH}/tmp/module.log.boot.1" 2>/dev/null
fi
rm -f "${MODULE_PATH}/tmp/"*.log.rot "${MODULE_PATH}/tmp/setting.clean."* "${MODULE_PATH}/tmp/setting.error."* 2>/dev/null

# 加载设置(自动处理 BOM / CRLF / 语法错误 / 缺失项)
source "${SCRIPTS_PATH}/base.sh"

# 创建/修复 SmartDNS 软链接
# 规则只有 base.sh ensure_module_links 一处: 目标必须用相对路径(模块更新先建在
# modules_update 再 mv 到 modules，绝对目标在 mv 后即悬空)，且悬空链必须删掉重建。
# 开机这里不再自己写 ln，否则会多出一套"绝对路径 + 只看 -L 就跳过"的旧规则，
# 正是 v20261025.5 修复的那类故障。
ensure_module_links

# 重置描述: 开机阶段先标记正在启动，服务就绪后由 scripts/update/desc.sh 更新为实际状态
sed -i "s/^description=.*/description=正在启动（等待服务就绪）/" "${MODULE_PATH}/module.prop"

{
    # 等待10秒后启动
    sleep 10
    "${SCRIPTS_PATH}/service.sh" start
} > /dev/null 2>&1 &

# 监控模块
if has_cmd inotifyd; then
    inotifyd "${INOTIFY_PATH}/module.sh" "${MODULE_PATH}" > /dev/null 2>&1 &
else
    log "e" "缺少 inotifyd，跳过模块监控"
fi

# 判断 host 启用则执行
if [ "${HOST_ENABLE}" = "true" ]; then
    # 系统 hosts 文件路径
    SYSTEM_HOSTS="/system/etc/hosts"

    # 判断未挂载才挂载，避免重复执行时叠加
    mount | grep -q " ${SYSTEM_HOSTS} " || mount -o bind "${MODULE_PATH}/etc/hosts" "${SYSTEM_HOSTS}"

    # 监控 hosts 文件
    if has_cmd inotifyd; then
        inotifyd "${INOTIFY_PATH}/host.sh" "${MODULE_PATH}/etc" > /dev/null 2>&1 &
    fi
fi

# 判断黑名单不为空，则启动监听
if [ "${#BLACKLIST_WIFI[@]}" -ne 0 ]; then
    "${SCRIPTS_PATH}/wifi.monitor.sh" > /dev/null 2>&1 &
fi

# 判断定时启用则执行
if [ "${CRONTAB_ENABLE}" = "true" ]; then
    if has_cmd busybox; then
        busybox crond -c "${MODULE_PATH}/etc/crontabs/"
    else
        log "e" "缺少 busybox，跳过定时任务"
    fi
fi
