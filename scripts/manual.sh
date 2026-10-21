#!/system/bin/sh
# 手动控制脚本 - 面向"CVE 临时 root、无法硬重启、只能软重启"的环境
#
# 为什么需要它:
#   1. 正常模块靠"刷入 -> 硬重启"完成激活，靠"打 remove 标记 -> 硬重启"完成卸载
#   2. 临时 root 一硬重启就丢 root，根本等不到那次重启
#   3. 软重启只是重启 Android 框架，不会再走 Magisk/KernelSU 的开机阶段
#      -> 模块永远不会被激活/卸载，service.sh 也不会被重新执行
#   本脚本把这些步骤改成"当场执行"，全程不依赖 reboot，也不依赖 su 命令是否存在。
#
# 用法:
#   sh manual.sh activate      激活(把 modules_update 搬到 modules)并启动
#   sh manual.sh resume        软重启后恢复运行(重启服务 + 挂载 hosts + 起监控)
#   sh manual.sh start|stop|restart
#   sh manual.sh uninstall     立即卸载(停服务/清规则/卸 hosts/删目录，无需重启)
#   sh manual.sh status        查看状态
#   sh manual.sh install <zip> 从本地 zip 安装并激活

MODULE_ID="SAM"
ACTIVE_DIR="/data/adb/modules/${MODULE_ID}"
UPDATE_DIR="/data/adb/modules_update/${MODULE_ID}"
SYSTEM_HOSTS="/system/etc/hosts"

# 自身路径(兼容 modules 与 modules_update 两种位置)
SELF_PATH="$(readlink -f "${0}" 2>/dev/null)"
[ -z "${SELF_PATH}" ] && SELF_PATH="${0}"
SELF_DIR="$(cd "$(dirname "${SELF_PATH}")" 2>/dev/null && pwd)"

say(){ echo "${1}"; }
ok(){ echo "[√] ${1}"; }
warn(){ echo "[!] ${1}"; }
die(){ echo "[×] ${1}" >&2; exit 1; }

usage(){
    say "用法: sh manual.sh <命令>"
    say "  activate        激活模块并启动(把 modules_update 搬到 modules)"
    say "  resume          软重启后恢复运行"
    say "  start           启动服务"
    say "  stop            停止服务"
    say "  restart         重启服务"
    say "  uninstall       立即卸载模块(无需重启)"
    say "  status          查看模块状态"
    say "  install <zip>   从本地 zip 安装并激活"
}

# 需要 root
need_root(){
    [ "$(id -u)" = "0" ] || die "需要 root 权限运行(请用 root 终端或 su -c 执行)"
}

# 需要模块已激活
need_active(){
    [ -d "${ACTIVE_DIR}" ] || die "模块尚未激活(缺少 ${ACTIVE_DIR})，请先执行: sh ${SELF_PATH} activate"
}

has_busybox(){
    command -v busybox > /dev/null 2>&1
}

# 临时 root 环境下 PATH 可能不完整，尽量把 busybox 找回来
ensure_busybox(){
    if ! has_busybox; then
        for busybox_dir in /data/adb/magisk /data/adb/ksu/bin /data/adb/ap/bin /data/adb/modules/busybox-ndk/system/bin /system/xbin /system/bin; do
            [ -x "${busybox_dir}/busybox" ] && export PATH="${busybox_dir}:${PATH}"
        done
    fi
    has_busybox || warn "未找到 busybox，服务可能无法以指定用户组启动"
}

# 找到当前可用的模块目录(优先待激活目录)
detect_source(){
    if [ -d "${UPDATE_DIR}" ]; then
        echo "${UPDATE_DIR}"
    elif [ -d "${ACTIVE_DIR}" ]; then
        echo "${ACTIVE_DIR}"
    else
        echo ""
    fi
}

# 修正权限与属主(临时 root 下解压出来的文件常常权限不对)
fix_permission(){
    target_dir="${1}"
    [ -d "${target_dir}" ] || return 1

    chmod -R +x "${target_dir}/bin" 2>/dev/null
    chmod +x "${target_dir}/etc/SmartDNS/smartdns" 2>/dev/null
    chmod +x "${target_dir}/etc/SmartDNS/smartdns_ui.so" 2>/dev/null
    chmod -R +x "${target_dir}/etc/SmartDNS/lib" 2>/dev/null
    find "${target_dir}" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null

    chown root:net_raw "${target_dir}/etc/SmartDNS/smartdns" 2>/dev/null
    chown root:net_raw "${target_dir}/bin/AdGuardHome" 2>/dev/null
    chown root:net_admin "${target_dir}/bin/mihomo" 2>/dev/null
    chown root:root "${target_dir}/etc/SmartDNS/smartdns_ui.so" 2>/dev/null
    chown -R root:root "${target_dir}/etc/SmartDNS/lib" 2>/dev/null

    mkdir -p "${target_dir}/tmp"
}

# 重建开机脚本会创建的那几个软链接
fix_symlink(){
    target_dir="${1}"
    [ -d "${target_dir}" ] || return 1

    if [ ! -e "${target_dir}/bin/smartdns" ] && [ ! -L "${target_dir}/bin/smartdns" ]; then
        ln -s "${target_dir}/etc/SmartDNS/smartdns" "${target_dir}/bin/smartdns" 2>/dev/null
    fi
    if [ ! -e "${target_dir}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" ] && [ ! -L "${target_dir}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" ]; then
        ln -s "${target_dir}/etc/SmartDNS/lib/libc.so" "${target_dir}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" 2>/dev/null
    fi
    if [ ! -e "${target_dir}/etc/SmartDNS/lib/ld-linux.so" ] && [ ! -L "${target_dir}/etc/SmartDNS/lib/ld-linux.so" ]; then
        ln -s "${target_dir}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" "${target_dir}/etc/SmartDNS/lib/ld-linux.so" 2>/dev/null
    fi
}

# 激活
activate_module(){
    need_root

    source_dir="$(detect_source)"
    [ -n "${source_dir}" ] || die "未找到模块目录 ${UPDATE_DIR} 或 ${ACTIVE_DIR}，可改用: sh ${SELF_PATH} install <zip>"

    if [ "${source_dir}" = "${UPDATE_DIR}" ]; then
        warn "检测到待激活模块: ${UPDATE_DIR}"
        if [ -d "${ACTIVE_DIR}" ]; then
            warn "移除旧版本: ${ACTIVE_DIR}"
            [ -f "${ACTIVE_DIR}/scripts/service.sh" ] && sh "${ACTIVE_DIR}/scripts/service.sh" stop > /dev/null 2>&1
            rm -rf "${ACTIVE_DIR}"
        fi
        mv "${UPDATE_DIR}" "${ACTIVE_DIR}" || die "移动 ${UPDATE_DIR} 到 ${ACTIVE_DIR} 失败"
        ok "已激活到 ${ACTIVE_DIR}"
    else
        ok "模块已在 ${ACTIVE_DIR}"
    fi

    # 清掉会让下次重启删除/禁用模块的标记
    # 临时 root 等不到那次重启，标记留着只会让人以为"已经卸载了"
    rm -f "${ACTIVE_DIR}/update" "${ACTIVE_DIR}/remove" "${ACTIVE_DIR}/disable" "${ACTIVE_DIR}/skip_mount"
    rm -rf "${UPDATE_DIR}"

    fix_permission "${ACTIVE_DIR}"
    fix_symlink "${ACTIVE_DIR}"

    # 用激活后的新路径继续，避免脚本文件被移动后继续读取
    sh "${ACTIVE_DIR}/scripts/manual.sh" resume
}

# 挂载 hosts
mount_host(){
    target_dir="${1}"

    grep -q "HOST_ENABLE=true" "${target_dir}/setting.conf" 2>/dev/null || {
        say "Host 未启用，跳过挂载"
        return 0
    }

    if mount | grep -q " ${SYSTEM_HOSTS} "; then
        ok "hosts 已处于挂载状态"
        return 0
    fi

    mount -o bind "${target_dir}/etc/hosts" "${SYSTEM_HOSTS}" && ok "hosts 已挂载" || warn "hosts 挂载失败"
}

# 启动监控(inotifyd 不存在就跳过，不要因此阻断启动)
start_monitor(){
    target_dir="${1}"

    if ! command -v inotifyd > /dev/null 2>&1; then
        warn "缺少 inotifyd，跳过模块/hosts 监控"
        return 0
    fi

    pgrep -f "${target_dir}/scripts/inotify/module.sh" > /dev/null 2>&1 || \
        inotifyd "${target_dir}/scripts/inotify/module.sh" "${target_dir}" > /dev/null 2>&1 &
    if mount | grep -q " ${SYSTEM_HOSTS} "; then
        pgrep -f "${target_dir}/scripts/inotify/host.sh" > /dev/null 2>&1 || \
            inotifyd "${target_dir}/scripts/inotify/host.sh" "${target_dir}/etc/hosts" > /dev/null 2>&1 &
    fi

    ok "监控已启动"
}

# 杀掉本模块的常驻监控
kill_monitor(){
    target_dir="${1}"
    for monitor_pid in $(pgrep -f "${target_dir}/scripts/inotify/" 2>/dev/null) \
                        $(pgrep -f "${target_dir}/scripts/wifi.monitor.sh" 2>/dev/null) \
                        $(pgrep -f "${target_dir}/scripts/watchdog.sh" 2>/dev/null); do
        kill -9 "${monitor_pid}" 2>/dev/null
    done
}

# 软重启后恢复
resume_module(){
    need_root
    need_active

    ensure_busybox

    say "启动服务"
    sh "${ACTIVE_DIR}/scripts/service.sh" restart

    mount_host "${ACTIVE_DIR}"
    start_monitor "${ACTIVE_DIR}"

    sh "${ACTIVE_DIR}/scripts/update/desc.sh" > /dev/null 2>&1

    show_status
}

start_service(){
    need_root
    need_active
    ensure_busybox
    sh "${ACTIVE_DIR}/scripts/service.sh" start
    show_status
}

stop_service(){
    need_root
    need_active
    sh "${ACTIVE_DIR}/scripts/service.sh" stop
    show_status
}

restart_service(){
    need_root
    need_active
    ensure_busybox
    sh "${ACTIVE_DIR}/scripts/service.sh" restart
    show_status
}

# 立即卸载
uninstall_module(){
    need_root

    # 只有已激活的模块才会真正跑着服务，先把它停干净
    if [ -d "${ACTIVE_DIR}" ]; then
        say "停止服务并清理规则"
        [ -f "${ACTIVE_DIR}/scripts/service.sh" ] && sh "${ACTIVE_DIR}/scripts/service.sh" stop > /dev/null 2>&1
        kill_monitor "${ACTIVE_DIR}"

        if mount | grep -q " ${SYSTEM_HOSTS} "; then
            umount "${SYSTEM_HOSTS}" 2>/dev/null && ok "已卸载 hosts" || warn "卸载 hosts 失败"
        fi

        # 恢复被 chattr 锁住的广告目录/文件
        [ -f "${ACTIVE_DIR}/scripts/ad.sh" ] && sh "${ACTIVE_DIR}/scripts/ad.sh" recovery > /dev/null 2>&1

        # 备份全部配置(setting / AdGuardHome / SmartDNS / Mihomo / 黑白名单 / hosts / 定时)
        if [ -f "${ACTIVE_DIR}/scripts/backup.sh" ]; then
            backup_output=$(sh "${ACTIVE_DIR}/scripts/backup.sh" save 2>&1)
            ok "${backup_output}"
        fi

        # 先清软链接，避免留下悬空链接
        rm -f "${ACTIVE_DIR}/bin/smartdns" 2>/dev/null
        rm -f "${ACTIVE_DIR}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" 2>/dev/null
        rm -f "${ACTIVE_DIR}/etc/SmartDNS/lib/ld-linux.so" 2>/dev/null
    fi

    # 待激活目录里也可能残留监控进程
    kill_monitor "${UPDATE_DIR}"

    # 直接删除，不依赖 reboot 与 remove 标记
    rm -rf "${ACTIVE_DIR}"
    rm -rf "${UPDATE_DIR}"

    if [ -d "${ACTIVE_DIR}" ] || [ -d "${UPDATE_DIR}" ]; then
        die "删除失败，请确认目录未被占用后重试"
    fi

    ok "模块已卸载(无需重启)"
}

# 从本地 zip 安装
install_zip(){
    zip_file="${1}"
    [ -n "${zip_file}" ] || die "用法: sh ${SELF_PATH} install <模块zip路径>"
    [ -f "${zip_file}" ] || die "文件不存在: ${zip_file}"
    need_root
    command -v unzip > /dev/null 2>&1 || die "缺少 unzip，请先准备 busybox，或改用管理器刷入"

    warn "清理旧的待激活目录: ${UPDATE_DIR}"
    rm -rf "${UPDATE_DIR}"
    mkdir -p "${UPDATE_DIR}"

    say "解压到 ${UPDATE_DIR}"
    unzip -o "${zip_file}" -x "META-INF/*" -d "${UPDATE_DIR}" > /dev/null 2>&1 || die "解压失败"
    [ -f "${UPDATE_DIR}/module.prop" ] || die "压缩包内缺少 module.prop，可能不是模块包"

    activate_module
}

show_status(){
    say "──────── 模块状态 ────────"
    if [ -d "${ACTIVE_DIR}" ]; then
        say "目录    : ${ACTIVE_DIR} (已激活)"
    else
        say "目录    : 未激活"
    fi
    [ -d "${UPDATE_DIR}" ] && say "待激活  : ${UPDATE_DIR}"

    for service_bin in smartdns AdGuardHome mihomo; do
        if pidof "${service_bin}" > /dev/null 2>&1; then
            ok "${service_bin} 运行中"
        else
            say "-    ${service_bin} 未运行"
        fi
    done

    if mount | grep -q " ${SYSTEM_HOSTS} "; then
        ok "hosts 已挂载"
    else
        say "-    hosts 未挂载"
    fi

    if iptables -t nat -L REDIRECT_DNS > /dev/null 2>&1; then
        ok "DNS 重定向规则存在"
    else
        say "-    DNS 重定向规则不存在"
    fi

    if [ -d "${ACTIVE_DIR}" ] && pgrep -f "${ACTIVE_DIR}/scripts/watchdog.sh" > /dev/null 2>&1; then
        ok "守护循环运行中(每 5 秒自检/热加载配置)"
    else
        say "-    守护循环未运行"
    fi
}

case "${1}" in
    activate)
        activate_module
        ;;
    resume|boot|restore)
        resume_module
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    uninstall|remove)
        uninstall_module
        ;;
    status)
        show_status
        ;;
    install)
        install_zip "${2}"
        ;;
    ''|-h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
