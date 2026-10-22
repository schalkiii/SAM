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

# 日志轮转
# 保留最后 200 行而不是整份清空: 整份清空会把"服务异常退出"前后的证据一起丢掉
rotate_log(){
    [ -f "${LOG_FILE}" ] || return 0
    [ "$(wc -c < "${LOG_FILE}")" -ge ${LOG_MAX_SIZE} ] || return 0
    tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.rot" 2>/dev/null && mv -f "${LOG_FILE}.rot" "${LOG_FILE}"
}

# 服务掉线则拉起(只处理已启用的服务)
ensure_service(){
    if [ "${SMARTDNS_ENABLE}" = "true" ] && ! isRun ${SMARTDNS_BIN}; then
        if [ ${sd_backoff} -le 0 ]; then
            log "i" "守护: ${SMARTDNS_BIN} 未运行，重新启动"
            ${SERVICE_PATH}/sd.sh start
            sd_backoff=${BACKOFF_ROUNDS}
            # 拉起来就算一次异常恢复
            recovered_abnormal=1
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
            recovered_abnormal=1
        else
            agh_backoff=$((agh_backoff - 1))
        fi
    else
        agh_backoff=0
    fi

    # Mihomo 没有订阅时本身起不来，不反复重试刷日志
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && ! isRun ${MIHOMO_BIN}; then
        if [ ${mihomo_backoff} -le 0 ]; then
            log "i" "守护: ${MIHOMO_BIN} 未运行，重新启动"
            ${SERVICE_PATH}/mihomo.sh start
            mihomo_backoff=${BACKOFF_ROUNDS}
            recovered_abnormal=1
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
    # 一个 DNS 服务都没跑时重建没有意义，只会刷日志
    any_dns_service || return 0

    if ! ${IPTABLES_PATH}/dns.sh check > /dev/null 2>&1; then
        log "i" "守护: DNS 重定向链缺失或端口不匹配，重新添加"
        ${IPTABLES_PATH}/dns.sh enable
    fi

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
    ${iptables_w} -C FORWARD -o ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 && return 0
    log "i" "守护: TUN 转发规则丢失，重新添加"
    ${IPTABLES_PATH}/mihomo.sh add
}

# 初始状态: 没有状态文件时视为运行中
[ -f "${STATE_FILE}" ] || echo running > "${STATE_FILE}"

# 直通模式切换标记，避免每轮都重复撤销规则
bypass_switched=""
# 配置文件修改时间戳: 没变就不重复解析，减少每 5 秒一次的磁盘写入
setting_file="/data/adb/modules/SAM/setting.conf"
setting_stamp=""

log "i" "守护循环已启动(每 5 秒自检)"

while true; do
    rotate_log

    # 手动停止 / WiFi 黑名单触发的停止，都不自动拉起
    case "$(cat "${STATE_FILE}" 2>/dev/null)" in
        stopped*)
            sleep 5
            continue
            ;;
    esac

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

    # 直通模式: 撤销 DNS 劫持，但服务进程与 WebUI 保持运行
    if [ "${BYPASS_ENABLE}" = "true" ]; then
        if [ "${bypass_switched}" != "on" ]; then
            log "i" "守护: 直通模式开启，撤销 DNS 劫持规则"
            ${IPTABLES_PATH}/dns.sh disable
            bypass_switched="on"
        fi
        ensure_service
        sleep 5
        continue
    fi

    # 从直通切回正常过滤，本轮就会重建规则
    if [ "${bypass_switched}" = "on" ]; then
        log "i" "守护: 直通模式关闭，恢复 DNS 劫持"
        bypass_switched=""
    fi

    ensure_service
    ensure_dns_rules
    ensure_tun_rules

    # 本轮发生过异常恢复: 重新验证一次网络
    # 场景: 服务被系统杀掉时，Android 已经把当前网络判成"无网络"，
    #       服务恢复后系统不会自动重新发起 DNS 查询，
    #       表现为"AGH 和 SmartDNS 都回来了，手机还是没网，必须手动开关一次飞行模式"。
    if [ ${recovered_abnormal} -eq 1 ]; then
        recovered_abnormal=0
        if [ "${RECOVER_REFRESH_NETWORK}" = "true" ] && [ "${NETWORK_REFRESH}" = "true" ]; then
            log "i" "守护: 检测到服务异常退出并已恢复，刷新一次网络"
            refresh_network
        fi
    fi

    sleep 5
done
