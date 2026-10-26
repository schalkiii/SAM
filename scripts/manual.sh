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
#   sh manual.sh resume        软重启后恢复运行(有待激活包时先激活)
#   sh manual.sh start|stop|restart
#   sh manual.sh uninstall     立即卸载(停服务/清规则/卸 hosts/删目录，无需重启)
#   sh manual.sh status        查看状态
#   sh manual.sh install <zip> 从本地 zip 安装并激活

MODULE_ID="SAM"
ACTIVE_DIR="/data/adb/modules/${MODULE_ID}"
UPDATE_DIR="/data/adb/modules_update/${MODULE_ID}"
PREVIOUS_DIR="/data/adb/SAM.previous"
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
    say "  activate        免重启激活模块并启动(把 modules_update 搬到 modules)"
    say "  autoactivate    安装后后台延迟自动激活(供 customize.sh 调用)"
    say "  repair          免重启修复/恢复模块目录(active/update/previous 自动选择)"
    say "  resume          软重启后恢复运行(重启服务 + 挂载 hosts + 起监控；有待激活包时自动激活)"
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

# 从 WebUI 调用时让子进程脱离调用会话，避免会话结束把监控一起收走
detach_start(){
    if command -v setsid > /dev/null 2>&1; then
        setsid "$@" > /dev/null 2>&1 &
    elif command -v nohup > /dev/null 2>&1; then
        nohup "$@" > /dev/null 2>&1 &
    else
        "$@" > /dev/null 2>&1 &
    fi
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

# 建立/修复一条软链(link_path, target)
# manual.sh 故意不 source base.sh(安装/激活阶段 base.sh 可能还不可用)，
# 所以规则在这里复制一份，与 base.sh ensure_module_links 保持一致:
#   目标用相对路径(mv 到 modules 后仍有效)，悬空链(-L 真/-e 假)必须重建
fix_one_link(){
    [ -e "${1}" ] && return 0
    mkdir -p "$(dirname "${1}")" 2>/dev/null
    rm -f "${1}" 2>/dev/null
    ln -s "${2}" "${1}" 2>/dev/null
}

# 重建开机脚本会创建的那几个软链接
fix_symlink(){
    target_dir="${1}"
    [ -d "${target_dir}" ] || return 1

    fix_one_link "${target_dir}/bin/smartdns" "../etc/SmartDNS/smartdns"
    fix_one_link "${target_dir}/etc/SmartDNS/lib/ld-musl-aarch64.so.1" "libc.so"
    fix_one_link "${target_dir}/etc/SmartDNS/lib/ld-linux.so" "ld-musl-aarch64.so.1"
}

# 语法自检用哪个解释器
# manual.sh 不 source base.sh(激活阶段 base.sh 可能还不可用)，所以规则在这里独立探测:
# 设备 sh 就是 mksh，scripts/service.sh 里的数组展开在 dash 下会被误判成语法错误
MANUAL_SYNTAX_SHELL="sh"
command -v mksh > /dev/null 2>&1 && MANUAL_SYNTAX_SHELL="mksh"

# 校验模块目录结构：不能只看 module.prop，否则半截包会被当成可激活
validate_module_dir(){
    target_dir="${1}"
    [ -f "${target_dir}/module.prop" ] || return 1
    [ -f "${target_dir}/scripts/service.sh" ] || return 1
    [ -f "${target_dir}/scripts/manual.sh" ] || return 1
    [ -f "${target_dir}/scripts/base.sh" ] || return 1
    [ -x "${target_dir}/bin/AdGuardHome" ] || return 1
    [ -x "${target_dir}/etc/SmartDNS/smartdns" ] || return 1
    [ -x "${target_dir}/bin/mihomo" ] || return 1
    "${MANUAL_SYNTAX_SHELL}" -n "${target_dir}/scripts/service.sh" >/dev/null 2>&1 || return 1
    "${MANUAL_SYNTAX_SHELL}" -n "${target_dir}/scripts/manual.sh" >/dev/null 2>&1 || return 1
    return 0
}

# 清掉会让下次重启删除/禁用模块的标记
clear_module_markers(){
    target_dir="${1}"
    rm -f "${target_dir}/update" "${target_dir}/remove" "${target_dir}/disable" "${target_dir}/skip_mount"
}

# 激活
activate_module(){
    need_root

    source_dir="$(detect_source)"
    [ -n "${source_dir}" ] || die "未找到模块目录 ${UPDATE_DIR} 或 ${ACTIVE_DIR}，可改用: sh ${SELF_PATH} install <zip>"

    if [ "${source_dir}" = "${UPDATE_DIR}" ]; then
        warn "检测到待激活模块: ${UPDATE_DIR}"
        fix_permission "${UPDATE_DIR}"
        fix_symlink "${UPDATE_DIR}"
        if ! validate_module_dir "${UPDATE_DIR}"; then
            die "待激活包未通过结构校验，取消激活"
        fi

        old_dir=""
        if [ -d "${ACTIVE_DIR}" ]; then
            warn "暂存旧版本: ${ACTIVE_DIR}"
            [ -f "${ACTIVE_DIR}/scripts/service.sh" ] && sh "${ACTIVE_DIR}/scripts/service.sh" stop > /dev/null 2>&1
            old_dir="/data/adb/SAM.old.$(date '+%Y%m%d-%H%M%S').$$"
            rm -rf "${old_dir}"
            mv "${ACTIVE_DIR}" "${old_dir}" || die "无法暂存旧版本 ${ACTIVE_DIR}，已取消激活"
        fi
        if ! mv "${UPDATE_DIR}" "${ACTIVE_DIR}"; then
            # 更新包移动失败时把旧版本放回去，避免留下没有模块目录的状态
            [ -n "${old_dir}" ] && mv "${old_dir}" "${ACTIVE_DIR}"
            die "移动 ${UPDATE_DIR} 到 ${ACTIVE_DIR} 失败，已恢复旧版本"
        fi
        fix_permission "${ACTIVE_DIR}"
        fix_symlink "${ACTIVE_DIR}"
        if ! validate_module_dir "${ACTIVE_DIR}"; then
            warn "新版本未通过结构校验，恢复旧版本"
            # 不能直接 rm -rf 新包: 用户刚下载的更新会彻底消失，连问题都没法查。
            # 保留到 rejected 目录，由用户决定手动删除或重新安装
            rejected_dir="/data/adb/SAM.rejected.$(date '+%Y%m%d-%H%M%S')"
            rm -rf "${rejected_dir}"
            mv "${ACTIVE_DIR}" "${rejected_dir}" 2>/dev/null || rm -rf "${ACTIVE_DIR}"
            [ -n "${old_dir}" ] && mv "${old_dir}" "${ACTIVE_DIR}"
            say "未通过校验的新包已保留: ${rejected_dir}"
            die "激活失败，已恢复旧版本"
        fi
        # 保留上一版到固定路径，软重启/KSU 回滚把 active 弄丢时还能 repair
        if [ -n "${old_dir}" ]; then
            rm -rf "${PREVIOUS_DIR}"
            mv "${old_dir}" "${PREVIOUS_DIR}" 2>/dev/null || rm -rf "${old_dir}"
        fi
        ok "已激活到 ${ACTIVE_DIR}"
    else
        fix_permission "${ACTIVE_DIR}"
        fix_symlink "${ACTIVE_DIR}"
        if ! validate_module_dir "${ACTIVE_DIR}"; then
            warn "当前 active 目录结构异常，尝试从待激活包/上一版修复"
            repair_module
            return $?
        fi
        ok "模块已在 ${ACTIVE_DIR}"
    fi

    clear_module_markers "${ACTIVE_DIR}"
    rm -rf "${UPDATE_DIR}"
    fix_permission "${ACTIVE_DIR}"
    fix_symlink "${ACTIVE_DIR}"

    # 用激活后的新路径继续，避免脚本文件被移动后继续读取
    sh "${ACTIVE_DIR}/scripts/manual.sh" resume
}

# 模块目录丢失/损坏时的免重启修复入口
repair_module(){
    need_root

    if [ -d "${ACTIVE_DIR}" ] && validate_module_dir "${ACTIVE_DIR}"; then
        clear_module_markers "${ACTIVE_DIR}"
        fix_permission "${ACTIVE_DIR}"
        fix_symlink "${ACTIVE_DIR}"
        ok "模块目录正常"
        sh "${ACTIVE_DIR}/scripts/manual.sh" resume
        return $?
    fi

    if [ -d "${UPDATE_DIR}" ]; then
        say "发现待激活包，尝试免重启激活"
        activate_module
        return $?
    fi

    if [ -d "${PREVIOUS_DIR}" ] && validate_module_dir "${PREVIOUS_DIR}"; then
        say "active 目录缺失/损坏，从 ${PREVIOUS_DIR} 恢复"
        rm -rf "${ACTIVE_DIR}"
        mv "${PREVIOUS_DIR}" "${ACTIVE_DIR}" || die "恢复上一版失败"
        clear_module_markers "${ACTIVE_DIR}"
        fix_permission "${ACTIVE_DIR}"
        fix_symlink "${ACTIVE_DIR}"
        sh "${ACTIVE_DIR}/scripts/manual.sh" resume
        return $?
    fi

    die "未找到可恢复的 SAM 模块目录，请检查 ${ACTIVE_DIR}、${UPDATE_DIR}、${PREVIOUS_DIR}"
}

# 安装结束后自动激活：必须延迟，避开管理器仍在写 modules_update / 清理临时目录的窗口
autoactivate_module(){
    need_root
    say "安装后自动免重启激活：等待安装器收尾..."
    sleep 8

    # 等待待激活目录稳定；最多 20 秒
    auto_wait=0
    while [ ${auto_wait} -lt 20 ] && [ ! -f "${UPDATE_DIR}/module.prop" ] && [ ! -f "${ACTIVE_DIR}/module.prop" ]; do
        sleep 1
        auto_wait=$((auto_wait + 1))
    done

    if [ -d "${UPDATE_DIR}" ]; then
        say "检测到待激活包，自动激活"
        activate_module
        return $?
    fi

    repair_module
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

# 卸载 hosts 绑定挂载
# 历史版本每次只摘一层，叠挂时会留下指向旧模块文件的挂载；
# 这里循环摘到没有为止（上限 8 层，单次失败即停，避免刷日志）
umount_host(){
    umount_try=0
    while mount | grep -q " ${SYSTEM_HOSTS} "; do
        umount_try=$((umount_try + 1))
        [ "${umount_try}" -le 8 ] || break
        umount "${SYSTEM_HOSTS}" 2>/dev/null || break
    done
    return 0
}

# 启动监控(inotifyd 不存在就跳过，不要因此阻断启动)
start_monitor(){
    target_dir="${1}"

    if ! command -v inotifyd > /dev/null 2>&1; then
        warn "缺少 inotifyd，跳过模块/hosts 监控"
        return 0
    fi

    pgrep -f "${target_dir}/scripts/inotify/module.sh" > /dev/null 2>&1 || \
        detach_start inotifyd "${target_dir}/scripts/inotify/module.sh" "${target_dir}"
    if mount | grep -q " ${SYSTEM_HOSTS} "; then
        pgrep -f "${target_dir}/scripts/inotify/host.sh" > /dev/null 2>&1 || \
            detach_start inotifyd "${target_dir}/scripts/inotify/host.sh" "${target_dir}/etc"
    fi

    ok "监控已启动"
}

# 杀掉本模块的常驻监控
kill_monitor(){
    target_dir="${1}"
    for monitor_pid in $(pgrep -f "${target_dir}/scripts/inotify/" 2>/dev/null) \
                        $(pgrep -f "${target_dir}/scripts/wifi.monitor.sh" 2>/dev/null) \
                        $(pgrep -f "${target_dir}/scripts/supervisor.sh" 2>/dev/null) \
                        $(pgrep -f "${target_dir}/scripts/watchdog.sh" 2>/dev/null); do
        kill -9 "${monitor_pid}" 2>/dev/null
    done
}

# 软重启后恢复
resume_module(){
    need_root

    # 软重启后若存在待激活包，resume 直接完成激活再恢复；
    # 否则用户会看到"恢复完成"但 KernelSU 仍是旧版本/待激活状态
    if [ -d "${UPDATE_DIR}" ]; then
        say "检测到待激活包，先激活并恢复新版本"
        activate_module
        return $?
    fi

    need_active

    ensure_busybox

    # 免重启更新后，watchdog/supervisor/wifi 监控是常驻 shell 进程，脚本文件被
    # 替换后它们仍在跑内存里的旧代码（本次升级后 watchdog 就仍是旧版本，且还留在
    # 应用 cgroup 里）。先全部停掉，由下面的 restart/start 重新拉起新代码；
    # 软重启后恢复时这些进程本来就不存在，这一步等价于空操作。
    kill_monitor "${ACTIVE_DIR}"

    say "启动服务"
    sh "${ACTIVE_DIR}/scripts/service.sh" restart

    mount_host "${ACTIVE_DIR}"
    start_monitor "${ACTIVE_DIR}"

    sh "${ACTIVE_DIR}/scripts/update/desc.sh" > /dev/null 2>&1

    # 软重启后系统的网络状态可能仍停留在"无网络"，主动重新验证一次；
    # 但用户主动停止服务、或关闭了 NETWORK_REFRESH 时不要擅自刷新网络
    case "$(cat "${ACTIVE_DIR}/tmp/service.state" 2>/dev/null)" in
        stopped*)
            say "服务处于停止状态，跳过网络刷新"
            ;;
        *)
            if grep -q "^NETWORK_REFRESH=true" "${ACTIVE_DIR}/setting.conf" 2>/dev/null; then
                say "刷新网络"
                sh "${ACTIVE_DIR}/scripts/service.sh" refresh > /dev/null 2>&1
            else
                say "已关闭网络刷新，跳过"
            fi
            ;;
    esac

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
            umount_host
            if mount | grep -q " ${SYSTEM_HOSTS} "; then
                warn "卸载 hosts 失败"
            else
                ok "已卸载 hosts"
            fi
        fi

        # 先备份配置，再恢复广告文件；备份失败时不应先改变广告目录
        if [ -f "${ACTIVE_DIR}/scripts/backup.sh" ]; then
            backup_output=$(sh "${ACTIVE_DIR}/scripts/backup.sh" save 2>&1)
            backup_rc=$?
            if [ ${backup_rc} -ne 0 ] && grep -q "^BACKUP_CONF=true" "${ACTIVE_DIR}/setting.conf" 2>/dev/null; then
                die "配置备份失败，已中止卸载: ${backup_output}"
            fi
            ok "${backup_output}"
        fi

        # 恢复广告目录/文件(新方案是把内容改名保留, 这里改回原名)
        ad_recovery_ok=1
        if [ -f "${ACTIVE_DIR}/scripts/ad.sh" ]; then
            sh "${ACTIVE_DIR}/scripts/ad.sh" recovery > /dev/null 2>&1 || ad_recovery_ok=0
        fi
        # 清理广告备份清单(在模块目录外, 卸载时不会自动消失)
        # 只有全部恢复成功才删除清单，失败时保留索引并中止卸载
        if [ ${ad_recovery_ok} -eq 1 ]; then
            rm -f "/data/adb/SAM-ad-hold.list" 2>/dev/null
        else
            die "广告文件未全部恢复，已中止卸载；请修复后重试 scripts/ad.sh recovery"
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

    # 清理模块目录外的恢复入口与历史版本:
    # 留着 SAM-activate.sh + SAM.previous 会让 repair 把已卸载的模块复活，
    # 卸载后还占用一份完整模块目录的空间
    rm -f "/data/adb/SAM-activate.sh" "/data/adb/SAM-activate.log" 2>/dev/null
    rm -rf "${PREVIOUS_DIR}" 2>/dev/null
    for sam_residue in /data/adb/SAM.rejected.* /data/adb/SAM.old.*; do
        [ -d "${sam_residue}" ] && rm -rf "${sam_residue}"
    done

    ok "模块已卸载(无需重启)"
}

# 校验 zip 成员名: 拒绝绝对路径与 .. 穿越
# 与 update.sh 的 safe_tar_extract 同口径；unzip -l 的成员名在长度/日期/时间之后，
# 这里去掉前三列再判断，兼容成员名里带空格的情况。解压前校验，避免先删待激活目录
zip_members_safe(){
    zip_listing=$(unzip -l "${1}" 2>/dev/null) || return 1
    printf '%s\n' "${zip_listing}" | \
        awk 'NR > 3 && $1 ~ /^[0-9]+$/ { $1 = $2 = $3 = ""; sub(/^[[:space:]]+/, ""); print }' | \
        grep -qE '(^/|(^|/)\.\.(/|$))' && return 1
    return 0
}

# 从本地 zip 安装
install_zip(){
    zip_file="${1}"
    [ -n "${zip_file}" ] || die "用法: sh ${SELF_PATH} install <模块zip路径>"
    [ -f "${zip_file}" ] || die "文件不存在: ${zip_file}"
    need_root
    command -v unzip > /dev/null 2>&1 || die "缺少 unzip，请先准备 busybox，或改用管理器刷入"
    zip_members_safe "${zip_file}" || die "压缩包包含绝对路径或 .. 成员，拒绝安装"

    warn "清理旧的待激活目录: ${UPDATE_DIR}"
    rm -rf "${UPDATE_DIR}"
    mkdir -p "${UPDATE_DIR}"

    say "解压到 ${UPDATE_DIR}"
    unzip -o "${zip_file}" -x "META-INF/*" -d "${UPDATE_DIR}" > /dev/null 2>&1 || die "解压失败"
    [ -f "${UPDATE_DIR}/module.prop" ] || die "压缩包内缺少 module.prop，可能不是模块包"

    # 留下模块外的免重启恢复入口，模块目录被 KSU 软重启/回滚弄丢时仍可 repair
    cp -f "${UPDATE_DIR}/scripts/manual.sh" "/data/adb/SAM-activate.sh" 2>/dev/null
    chmod 700 "/data/adb/SAM-activate.sh" 2>/dev/null

    # manual 安装不会经过 customize.sh 的升级迁移；
    # 先备份并保留旧配置，否则激活时删除旧目录会把订阅/设置一起丢掉
    if [ -d "${ACTIVE_DIR}" ]; then
        [ -f "${ACTIVE_DIR}/scripts/backup.sh" ] && sh "${ACTIVE_DIR}/scripts/backup.sh" save > /dev/null 2>&1
        for preserve_file in setting.conf etc/app_blacklist.prop etc/app_whitelist.prop etc/hosts etc/crontabs/root etc/AdGuardHome/AdGuardHome.yaml; do
            [ -f "${ACTIVE_DIR}/${preserve_file}" ] || continue
            mkdir -p "$(dirname "${UPDATE_DIR}/${preserve_file}")" 2>/dev/null
            cp -f "${ACTIVE_DIR}/${preserve_file}" "${UPDATE_DIR}/${preserve_file}" 2>/dev/null
        done
        for preserve_dir in etc/AdGuardHome/data etc/SmartDNS/data etc/mihomo/proxy_provider etc/mihomo/rule_provider; do
            [ -d "${ACTIVE_DIR}/${preserve_dir}" ] || continue
            mkdir -p "${UPDATE_DIR}/${preserve_dir}" 2>/dev/null
            cp -R -f "${ACTIVE_DIR}/${preserve_dir}/." "${UPDATE_DIR}/${preserve_dir}" 2>/dev/null
        done
        [ -f "${ACTIVE_DIR}/etc/mihomo/cache.db" ] && \
            cp -f "${ACTIVE_DIR}/etc/mihomo/cache.db" "${UPDATE_DIR}/etc/mihomo/cache.db" 2>/dev/null
    fi

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
    [ -d "${PREVIOUS_DIR}" ] && say "上一版备份: ${PREVIOUS_DIR}"
    [ -f "/data/adb/SAM-activate.sh" ] && ok "免重启恢复入口: /data/adb/SAM-activate.sh"

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

    # 只判断链存在会漏掉"链还在但端口已经死了"的情况，
    # 那种状态比没有规则更糟：整机 DNS 会被送进没有进程的端口。
    if [ -d "${ACTIVE_DIR}" ]; then
        dns_check_output=$(sh "${ACTIVE_DIR}/scripts/iptables/dns.sh" check 2>&1)
        dns_check_rc=$?
        case ${dns_check_rc} in
            0) ok "${dns_check_output}" ;;
            2) say "-    没有可用的 DNS 服务在运行" ;;
            *) warn "${dns_check_output}" ;;
        esac
    else
        say "-    DNS 重定向规则未知(模块未激活)"
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
    autoactivate)
        autoactivate_module
        ;;
    repair)
        repair_module
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
