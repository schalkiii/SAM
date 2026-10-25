#!/system/bin/sh
# 守护循环 - 每 5 秒自检一次
#
# 借鉴 schalkiii/Adguard-Home-For-Magisk-Mod 的守护脚本思路:
#   1. 每轮重读 setting.conf  -> 改配置最迟 5 秒生效，不需要重启
#   2. 进程掉线自动拉起       -> 服务被系统杀掉后能自己回来
#   3. iptables 规则被清自动重建 -> 其他模块清规则后不会静默失效
#   4. 日志超限自动清空       -> 避免常年运行把 tmp 撑爆
#
# 与"手动停止"的关系: scripts/service.sh stop 会把状态写成 stopped，
# 守护循环看到 stopped 就只休眠、不拉起，避免和用户的停止操作打架。
#
# 关于"服务跑着跑着就自己停了":
#   1. 服务进程挂在调用方会话上(经 WebUI 启动)，会话被回收时一起被杀
#      -> 服务启动时用 setsid 脱离会话，见 base.sh 的 detach_exec
#   2. AGH / SmartDNS 是内存大户，系统内存紧张时被 LMKD 优先回收
#      -> 启动后把 oom_score_adj 设为 -1000，见 base.sh 的 protect_process
#   3. 守护循环自身被回收后就没人拉起服务了
#      -> 本脚本同样保护自己，并由 service.sh 在异常恢复后重新拉起

source "/data/adb/modules/SAM/scripts/base.sh"

# 防止重复启动：用 PID 锁而不是 pgrep check-then-exit，避免并发时两个实例都退出
sam_lock_acquire "watchdog_instance" 2 || exit 0

# 服务状态文件(running / stopped)
STATE_FILE="${TMP_PATH}/service.state"
# 日志上限 100 KB
LOG_MAX_SIZE=102400
# 拉起失败后的退避轮数(6 轮 = 30 秒)，避免每 5 秒刷日志 + 反复 fork
BACKOFF_ROUNDS=6
# 异常恢复后是否自动刷新一次网络
RECOVER_REFRESH_NETWORK=true

# 缺少 pgrep / pidof 时无法判断进程存活，守护循环会把所有服务误判成掉线并无限重启
if ! has_cmd pgrep && ! has_cmd pidof; then
    log "e" "缺少 pgrep/pidof，守护循环退出(避免反复重启服务)"
    exit 0
fi

# 守护循环自身也要免被回收，否则没人拉起掉线的服务
protect_process "$$"

sd_backoff=0
agh_backoff=0
mihomo_backoff=0
# AGH 配置校验失败时只提示一次，避免刷日志
agh_config_skip_logged=0

# 本轮是否发生了"服务异常死亡后被拉起"
# 异常死亡意味着系统的网络状态可能已经被判成无网络，
# 恢复后需要重新验证一次网络，否则表现为"服务起来了但还是没网"。
recovered_abnormal=0
# 服务拓扑变化后是否需要重写 AGH/Mihomo 上游并重启下游
need_chain_refresh=0

# 至少有一个 DNS 服务在跑，才值得去重建规则
any_dns_service(){
    isRun ${SMARTDNS_BIN} || isRun ${AGH_BIN} || isRun ${MIHOMO_BIN}
}

# 所有启用的服务是否都健康
# 刷新网络只对"服务恢复后系统仍认为无网络"有意义；
# 如果还有服务起不来，刷新不会解决问题，反而会反复断开 WiFi。
all_services_running(){
    [ "${SMARTDNS_ENABLE}" = "true" ] && ! isRun ${SMARTDNS_BIN} && return 1
    [ "${AGH_ENABLE}" = "true" ] && ! isRun ${AGH_BIN} && return 1
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        isRun ${MIHOMO_BIN} || return 1
    fi
    return 0
}

# AGH 配置是否仍处于上次校验失败的状态
# 用 cksum 而不是 mtime: update/agh.sh 每次启动都会重写配置，mtime 必然变化；
# 只有内容真的变了才允许再试，否则会陷入"校验失败 -> 5 秒后重试"的循环。
agh_config_blocked(){
    [ -s "${TMP_PATH}/agh.config.bad" ] || return 1
    [ -f "${AGH_CONF}" ] || return 1
    current_stamp=$(cksum "${AGH_CONF}" 2>/dev/null | awk '{print $1" "$2}')
    saved_stamp=$(cat "${TMP_PATH}/agh.config.bad" 2>/dev/null)
    if [ -n "${current_stamp}" ] && [ "${current_stamp}" = "${saved_stamp}" ]; then
        return 0
    fi
    rm -f "${TMP_PATH}/agh.config.bad"
    return 1
}

# 日志轮转
# 保留最后 200 行而不是整份清空: 整份清空会把"服务异常退出"前后的证据一起丢掉
rotate_log(){
    [ -f "${LOG_FILE}" ] || return 0
    [ "$(wc -c < "${LOG_FILE}")" -ge ${LOG_MAX_SIZE} ] || return 0
    tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.rot" 2>/dev/null && mv -f "${LOG_FILE}.rot" "${LOG_FILE}"
}

# 服务 stdout 是用 O_APPEND 打开的，不能 mv(进程仍写旧 inode)；
# 先取尾部再原地截断重写，进程后续写入会继续追加到新内容之后
rotate_append_log(){
    rotate_target="${1}"
    [ -f "${rotate_target}" ] || return 0
    [ "$(wc -c < "${rotate_target}")" -ge ${LOG_MAX_SIZE} ] || return 0
    tail -n 200 "${rotate_target}" > "${rotate_target}.rot" 2>/dev/null && \
        cat "${rotate_target}.rot" > "${rotate_target}" 2>/dev/null
    rm -f "${rotate_target}.rot"
}

rotate_all_logs(){
    rotate_log
    rotate_append_log "${TMP_PATH}/${AGH_BIN}.log"
    rotate_append_log "${TMP_PATH}/${MIHOMO_BIN}.log"
    rotate_append_log "${TMP_PATH}/${SMARTDNS_BIN}.out"
}

# 服务异常消失时抓一份系统侧证据，区分 LMKD/小米杀后台与模块主动停止
capture_auto_stop_snapshot(){
    snapshot_bin="${1}"
    snapshot_stamp="${TMP_PATH}/auto-stop.${snapshot_bin}.stamp"
    snapshot_now=$(date +%s)
    if [ -f "${snapshot_stamp}" ]; then
        snapshot_last=$(cat "${snapshot_stamp}" 2>/dev/null)
        [ -n "${snapshot_last}" ] && [ $((snapshot_now - snapshot_last)) -lt 300 ] && return 0
    fi
    date +%s > "${snapshot_stamp}" 2>/dev/null
    snapshot_file="${TMP_PATH}/auto-stop.${snapshot_bin}.$(date '+%Y%m%d-%H%M%S').log"
    {
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "bin=${snapshot_bin}"
        echo "state=$(cat "${STATE_FILE}" 2>/dev/null)"
        echo "abnormal=$(cat "${TMP_PATH}/service.abnormal" 2>/dev/null)"
        echo "watchdog_heartbeat=$(cat "${TMP_PATH}/watchdog.heartbeat" 2>/dev/null)"
        echo "--- processes ---"
        ps -A 2>/dev/null | grep -E "smartdns|AdGuardHome|mihomo|watchdog|wifi.monitor" | grep -v grep
        echo "--- recent service events ---"
        grep "SERVICE-EVENT" "${LOG_FILE}" 2>/dev/null | tail -n 20
        echo "--- logcat kill/lmkd ---"
        logcat -d -t 300 2>/dev/null | grep -iE "lowmemorykiller|lmkd|ActivityManager.*kill|Force stopping|Scheduling restart" | tail -n 30
    } > "${snapshot_file}" 2>/dev/null
    record_service_event "auto-stop snapshot ${snapshot_file}"
}

# 计算当前 DNS 入口(与 base.sh dns_entry_port 同一回退链)
# 用来判断"服务拓扑是否真的变了": 同名端口恢复(如 SmartDNS 重启)时入口不变，
# 不需要重写下游上游，更不需要重启 AGH/Mihomo(重启会清缓存与统计)。
# 无可用入口时输出 none
current_dns_entry(){
    dns_entry=$(dns_entry_port)
    echo "${dns_entry:-none}"
}

# 服务掉线则拉起(只处理已启用的服务)
ensure_service(){
    if [ "${SMARTDNS_ENABLE}" = "true" ] && ! isRun ${SMARTDNS_BIN}; then
        if [ ${sd_backoff} -le 0 ]; then
            capture_auto_stop_snapshot "${SMARTDNS_BIN}"
            record_service_event "watchdog restart ${SMARTDNS_BIN}"
            log "i" "守护: ${SMARTDNS_BIN} 未运行，重新启动"
            ${SERVICE_PATH}/sd.sh start
            sd_backoff=${BACKOFF_ROUNDS}
            # 只有真正起来才算异常恢复；起不来就不刷新网络
            if isRun ${SMARTDNS_BIN}; then
                recovered_abnormal=1
                service_state_changed=1
            fi
        else
            sd_backoff=$((sd_backoff - 1))
        fi
    else
        sd_backoff=0
    fi

    if [ "${AGH_ENABLE}" = "true" ] && ! isRun ${AGH_BIN}; then
        if agh_config_blocked; then
            # 配置没修好，不再每轮尝试；只提示一次，等配置内容变化或用户手动重启
            if [ "${agh_config_skip_logged}" != "1" ]; then
                log "e" "守护: ${AGH_BIN} 配置校验失败，暂停自动拉起(修复后重启服务)"
                agh_config_skip_logged=1
            fi
            agh_backoff=0
        else
            agh_config_skip_logged=0
            if [ ${agh_backoff} -le 0 ]; then
                capture_auto_stop_snapshot "${AGH_BIN}"
                record_service_event "watchdog restart ${AGH_BIN}"
                log "i" "守护: ${AGH_BIN} 未运行，重新启动"
                ${SERVICE_PATH}/agh.sh start
                agh_backoff=${BACKOFF_ROUNDS}
                if isRun ${AGH_BIN}; then
                    recovered_abnormal=1
                    service_state_changed=1
                fi
            else
                agh_backoff=$((agh_backoff - 1))
            fi
        fi
    else
        agh_backoff=0
        agh_config_skip_logged=0
    fi

    # Mihomo 没有订阅时本身起不来，不反复重试刷日志；直通模式下停用
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ] && ! isRun ${MIHOMO_BIN}; then
        if [ ${mihomo_backoff} -le 0 ]; then
            capture_auto_stop_snapshot "${MIHOMO_BIN}"
            record_service_event "watchdog restart ${MIHOMO_BIN}"
            log "i" "守护: ${MIHOMO_BIN} 未运行，重新启动"
            ${SERVICE_PATH}/mihomo.sh start
            mihomo_backoff=${BACKOFF_ROUNDS}
            if isRun ${MIHOMO_BIN}; then
                recovered_abnormal=1
                service_state_changed=1
            fi
        else
            mihomo_backoff=$((mihomo_backoff - 1))
        fi
    else
        mihomo_backoff=0
    fi
}

# DNS 重定向规则丢失或端口不匹配则重建
# 关键: 不能只判断链是否存在。服务换端口后(例如 AGH 被杀、回退到 SmartDNS)，
#       旧链里的 REDIRECT 仍指向已经没有进程监听的端口，整机 DNS 进黑洞。
ensure_dns_rules(){
    # 没有 DNS 服务在跑时不能保留劫持/阻断规则，否则 DNS 会指向死端口、
    # IPv6 也会被无谓阻断。清理一次后由 no_dns_cleaned 去重，避免刷日志。
    if ! any_dns_service; then
        if [ "${no_dns_cleaned}" != "1" ]; then
            log "e" "守护: 没有 DNS 服务在运行，移除重定向与 IPv6 阻断规则"
            ${IPTABLES_PATH}/dns.sh disable
            no_dns_cleaned=1
        fi
        return 0
    fi

    ${IPTABLES_PATH}/dns.sh check > /dev/null 2>&1
    dns_check_rc=$?
    case ${dns_check_rc} in
        0)
            no_dns_cleaned=""
            ;;
        2)
            # 有进程但端口没在监听: 旧规则可能还指向死端口，清理一次避免 DNS 黑洞
            if [ "${no_dns_cleaned}" != "1" ]; then
                log "e" "守护: 有 DNS 进程但端口未监听，移除重定向避免黑洞"
                ${IPTABLES_PATH}/dns.sh enable
                no_dns_cleaned=1
            fi
            ;;
        *)
            log "i" "守护: DNS 重定向链缺失或端口不匹配，重新添加"
            ${IPTABLES_PATH}/dns.sh enable
            no_dns_cleaned=""
            ;;
    esac

    if [ "${BLOCK_IPV6_DNS}" = "true" ]; then
        ${ip6tables_w} -t filter -C OUTPUT -j BLOCK_IPV6_DNS > /dev/null 2>&1 || {
            log "i" "守护: IPv6 DNS 阻断规则丢失，重新添加"
            ${IPTABLES_PATH}/dns.sh enable
        }
        # 只有跳转存在还不够：链体为空时等于没有阻断
        if ${ip6tables_w} -t filter -L BLOCK_IPV6_DNS > /dev/null 2>&1; then
            ${ip6tables_w} -t filter -L BLOCK_IPV6_DNS -n 2>/dev/null | grep -qE "DROP|REJECT" || {
                log "i" "守护: IPv6 DNS 阻断链为空，重新添加"
                ${IPTABLES_PATH}/dns.sh enable
            }
        fi
    else
        # 只清理 IPv6 侧规则: 原来的实现调用 dns.sh disable，
        # 会连带删掉 IPv4 的 REDIRECT_DNS，整机 DNS 绕过模块
        ${ip6tables_w} -t filter -C OUTPUT -j BLOCK_IPV6_DNS > /dev/null 2>&1 && {
            log "i" "守护: IPv6 DNS 阻断已关闭，清理旧规则"
            ${IPTABLES_PATH}/dns.sh disablev6
        }
    fi
}

# TUN 转发规则丢失则重建
ensure_tun_rules(){
    isRun ${MIHOMO_BIN} || return 0

    tun_rule_missing=0
    ${iptables_w} -C FORWARD -o ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || tun_rule_missing=1
    ${iptables_w} -C FORWARD -i ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || tun_rule_missing=1
    # 只有内核确实支持 ip6tables 时才检查 v6，避免无 v6 的设备每轮都判定缺失
    if ${ip6tables_w} -L FORWARD > /dev/null 2>&1; then
        ${ip6tables_w} -C FORWARD -o ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || tun_rule_missing=1
        ${ip6tables_w} -C FORWARD -i ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || tun_rule_missing=1
    fi

    [ ${tun_rule_missing} -eq 0 ] && return 0
    log "i" "守护: TUN 转发规则缺失，重新添加"
    ${IPTABLES_PATH}/mihomo.sh add
}

# IP 屏蔽规则自愈
ensure_ip_rules(){
    if [ "${IP_IPTABLES}" = "true" ]; then
        if ! ${iptables_w} -C OUTPUT -j SAM_BLOCK_IP > /dev/null 2>&1 || \
           ! ${iptables_w} -L SAM_BLOCK_IP -n 2>/dev/null | grep -q "DROP"; then
            log "i" "守护: IP 屏蔽规则缺失，重新添加"
            ${IPTABLES_PATH}/ip.sh enable
        fi
    else
        ${iptables_w} -C OUTPUT -j SAM_BLOCK_IP > /dev/null 2>&1 && \
            ${IPTABLES_PATH}/ip.sh disable
    fi
}

# 初始状态: 没有状态文件时视为运行中
[ -f "${STATE_FILE}" ] || echo running > "${STATE_FILE}"

# 直通模式切换标记，避免每轮都重复撤销规则
bypass_switched=""
# 端口未监听时的清理标记，避免每轮重复清理刷日志
no_dns_cleaned=""
# 服务是否在本轮被拉起/切换模式，决定是否需要立即重建规则
service_state_changed=1
# 规则检查降频: 服务存活每 5 秒查，iptables/DNS 链每 10 秒查一次
loop_count=0
# 已卸载 App 的锁定清理: 有备份清单时每 5 分钟检查一次
ad_cleanup_counter=0
# 配置文件修改时间戳: 没变就不重复解析，减少每 5 秒一次的磁盘写入
setting_file="/data/adb/modules/SAM/setting.conf"
setting_stamp=""
setting_sum=""

log "i" "守护循环已启动(每 5 秒自检)"
date +%s > "${TMP_PATH}/watchdog.heartbeat" 2>/dev/null

while true; do
    loop_count=$((loop_count + 1))
    date +%s > "${TMP_PATH}/watchdog.heartbeat" 2>/dev/null

    # 手动停止 / WiFi 黑名单触发的停止，都不自动拉起
    case "$(cat "${STATE_FILE}" 2>/dev/null)" in
        stopped*)
            sleep 5
            continue
            ;;
    esac

    # 所有会修改服务/规则的动作都必须与 service.sh 的 start/stop/restart 互斥。
    # 不能只在循环开头看一次 stopped：stop 可能在本轮执行过程中发生。
    if ! sam_lock_acquire "service" 5; then
        sleep 5
        continue
    fi

    # 拿到锁后再确认一次状态，避免刚好在等待锁时用户停止
    case "$(cat "${STATE_FILE}" 2>/dev/null)" in
        stopped*)
            sam_lock_release "service"
            sleep 5
            continue
            ;;
    esac

    # 日志轮转与 iptables 检查一起降频到 10 秒，减少空闲时的 fork 与磁盘写入
    if [ $((loop_count % 2)) -eq 0 ]; then
        rotate_all_logs
    fi

    # 已卸载 App 的 immutable 空壳会阻止系统清理数据；
    # 每 5 分钟（60 轮）后台解除一次，避免常驻 pm 查询开销
    if [ -s "${AD_HOLD_LIST}" ]; then
        ad_cleanup_counter=$((ad_cleanup_counter + 1))
        if [ ${ad_cleanup_counter} -ge 60 ]; then
            ad_cleanup_counter=0
            detach_exec "${SCRIPTS_PATH}/ad.sh" cleanup > /dev/null 2>&1
        fi
    else
        ad_cleanup_counter=0
    fi

    # 每轮检查设置是否变化，变了才重新解析(load_setting 会写临时文件，不宜每 5 秒跑一次)
    # 同秒多次写入时 mtime 不变，必须叠加 cksum，避免永久漏掉最终配置
    if has_cmd stat; then
        new_stamp=$(stat -c "%Y" "${setting_file}" 2>/dev/null)
    else
        new_stamp=""
    fi
    new_sum=$(cksum "${setting_file}" 2>/dev/null)
    if [ -z "${new_stamp}" ] || [ "${new_stamp}" != "${setting_stamp}" ] || [ "${new_sum}" != "${setting_sum}" ]; then
        load_setting "${setting_file}"
        setting_stamp="${new_stamp}"
        setting_sum="${new_sum}"
    fi

    # 每天自动备份一次配置: 用户不再需要为了备份去手动点更新/卸载。
    # 成功才记时间戳；失败按小时重试，避免备份失败时每 5 秒重试刷日志
    if [ "${BACKUP_CONF}" = "true" ]; then
        backup_now=$(date +%s)
        backup_last=$(cat "${TMP_PATH}/backup.stamp" 2>/dev/null)
        [ -z "${backup_last}" ] && backup_last=0
        backup_retry=$(cat "${TMP_PATH}/backup.retry.stamp" 2>/dev/null)
        [ -z "${backup_retry}" ] && backup_retry=0
        if [ $((backup_now - backup_last)) -ge 86400 ] && [ $((backup_now - backup_retry)) -ge 3600 ]; then
            if sh "${SCRIPTS_PATH}/backup.sh" save > /dev/null 2>&1; then
                echo "${backup_now}" > "${TMP_PATH}/backup.stamp" 2>/dev/null
                rm -f "${TMP_PATH}/backup.retry.stamp" 2>/dev/null
                log "i" "守护: 每日自动备份完成"
            else
                echo "${backup_now}" > "${TMP_PATH}/backup.retry.stamp" 2>/dev/null
                log "e" "守护: 自动备份失败，1 小时后重试"
            fi
        fi
    fi

    # 直通模式: 撤销 DNS 劫持，停掉 Mihomo，服务进程与 WebUI 保持运行
    if [ "${BYPASS_ENABLE}" = "true" ]; then
        if [ "${bypass_switched}" != "on" ]; then
            log "i" "守护: 直通模式开启，撤销 DNS 劫持并暂停 Mihomo"
            ${IPTABLES_PATH}/dns.sh disable
            bypass_switched="on"
        fi
        if isRun ${MIHOMO_BIN}; then
            ${SERVICE_PATH}/mihomo.sh stop
            ${IPTABLES_PATH}/mihomo.sh del
            mihomo_backoff=0
        fi
        ensure_service
        sam_lock_release "service"
        sleep 5
        continue
    fi

    # 从直通切回正常过滤，本轮就会重建规则
    if [ "${bypass_switched}" = "on" ]; then
        log "i" "守护: 直通模式关闭，恢复 DNS 劫持"
        bypass_switched=""
        service_state_changed=1
    fi

    # 拓扑变化才重写下游上游: 先记入口，ensure_service 之后再比一次。
    # 同名端口恢复(SmartDNS 重启后仍是 3721)时入口不变，
    # 重写+重启 AGH/Mihomo 只会白清缓存与统计
    dns_entry_before=$(current_dns_entry)
    ensure_service
    dns_entry_after=$(current_dns_entry)
    if [ "${dns_entry_before}" != "${dns_entry_after}" ]; then
        need_chain_refresh=1
        log "i" "守护: DNS 入口变化 ${dns_entry_before} -> ${dns_entry_after}，重写下游上游"
    fi

    # 服务拓扑变化后重写下游上游，避免 AGH/Mihomo 仍指向已死亡的本地 DNS
    # 重启也按配置内容是否变化来决定: update 脚本在内容不变时只做等价重写，
    # 此时重启纯粹是清缓存与统计，必须跳过
    if [ ${need_chain_refresh} -eq 1 ]; then
        need_chain_refresh=0
        agh_before=$(cksum "${AGH_CONF}" 2>/dev/null)
        ${UPDATE_PATH}/agh.sh > /dev/null 2>&1
        agh_after=$(cksum "${AGH_CONF}" 2>/dev/null)
        if [ "${agh_before}" != "${agh_after}" ] && [ "${AGH_ENABLE}" = "true" ]; then
            ${SERVICE_PATH}/agh.sh stop > /dev/null 2>&1
            ${SERVICE_PATH}/agh.sh start > /dev/null 2>&1
        fi
        mihomo_before=$(cksum "${MIHOMO_CONF}" 2>/dev/null)
        ${UPDATE_PATH}/mihomo.sh > /dev/null 2>&1
        mihomo_after=$(cksum "${MIHOMO_CONF}" 2>/dev/null)
        if [ "${mihomo_before}" != "${mihomo_after}" ] && [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
            ${SERVICE_PATH}/mihomo.sh stop > /dev/null 2>&1
            ${SERVICE_PATH}/mihomo.sh start > /dev/null 2>&1
        fi
    fi

    # 服务刚被拉起、模式刚切换时立即重建规则；其余情况每 10 秒检查一次
    if [ ${service_state_changed} -eq 1 ] || [ $((loop_count % 2)) -eq 0 ]; then
        ensure_dns_rules
        ensure_tun_rules
        ensure_ip_rules
        service_state_changed=0
    fi

    # 本轮发生过异常恢复: 重新验证一次网络
    # 场景: 服务被系统杀掉时，Android 已经把当前网络判成"无网络"，
    #       服务恢复后系统不会自动重新发起 DNS 查询，
    #       表现为"AGH 和 SmartDNS 都回来了，手机还是没网，必须手动开关一次飞行模式"。
    if [ ${recovered_abnormal} -eq 1 ]; then
        recovered_abnormal=0
        # 还有启用的服务没起来时，刷新网络解决不了问题，只会反复断开 WiFi
        if ! all_services_running; then
            log "e" "守护: 仍有服务未恢复，跳过网络刷新"
        elif [ "${RECOVER_REFRESH_NETWORK}" = "true" ] && [ "${NETWORK_REFRESH}" = "true" ]; then
            log "i" "守护: 检测到服务异常退出并已恢复，刷新一次网络"
            refresh_network
        fi
    fi

    sam_lock_release "service"
    sleep 5
done
