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

# 防止重复启动
[ "$(pgrep -f "${SCRIPTS_PATH}/watchdog.sh" | wc -l)" -gt 1 ] && exit 0

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

# 本轮是否发生了"服务异常死亡后被拉起"
# 异常死亡意味着系统的网络状态可能已经被判成无网络，
# 恢复后需要重新验证一次网络，否则表现为"服务起来了但还是没网"。
recovered_abnormal=0

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

# 服务掉线则拉起(只处理已启用的服务)
ensure_service(){
    if [ "${SMARTDNS_ENABLE}" = "true" ] && ! isRun ${SMARTDNS_BIN}; then
        if [ ${sd_backoff} -le 0 ]; then
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
        if [ ${agh_backoff} -le 0 ]; then
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
    else
        agh_backoff=0
    fi

    # Mihomo 没有订阅时本身起不来，不反复重试刷日志；直通模式下停用
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ] && ! isRun ${MIHOMO_BIN}; then
        if [ ${mihomo_backoff} -le 0 ]; then
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

log "i" "守护循环已启动(每 5 秒自检)"

while true; do
    loop_count=$((loop_count + 1))

    # 手动停止 / WiFi 黑名单触发的停止，都不自动拉起
    case "$(cat "${STATE_FILE}" 2>/dev/null)" in
        stopped*)
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
    if has_cmd stat; then
        new_stamp=$(stat -c "%Y" "${setting_file}" 2>/dev/null)
    else
        new_stamp=""
    fi
    if [ -z "${new_stamp}" ] || [ "${new_stamp}" != "${setting_stamp}" ]; then
        load_setting "${setting_file}"
        setting_stamp="${new_stamp}"
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
        sleep 5
        continue
    fi

    # 从直通切回正常过滤，本轮就会重建规则
    if [ "${bypass_switched}" = "on" ]; then
        log "i" "守护: 直通模式关闭，恢复 DNS 劫持"
        bypass_switched=""
        service_state_changed=1
    fi

    ensure_service

    # 服务刚被拉起、模式刚切换时立即重建规则；其余情况每 10 秒检查一次
    if [ ${service_state_changed} -eq 1 ] || [ $((loop_count % 2)) -eq 0 ]; then
        ensure_dns_rules
        ensure_tun_rules
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

    sleep 5
done
