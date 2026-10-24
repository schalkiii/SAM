#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# DNS 链
DNS_CHAIN="REDIRECT_DNS"
IPV6_DNS_CHAIN="REDIRECT_IPV6_DNS"
# 阻断 ipv6 链
BLOCK_IPV6_CHAIN="BLOCK_IPV6_DNS"

# 获取 SmartDNS 端口
SMARTDNS_PORT=$(smartdns_port)

# 记录选中的入口，日志与状态检查统一显示"服务名:端口"，
# 避免只看到 5300 却不知道当前是哪个服务在接 DNS
set_dns_entry(){
    [ -n "${1}" ] || return 1
    DNS_PORT="${1}"
    DNS_ENTRY="${2}"
}

# 选择实际可用的 DNS 转发端口
# 说明: 原实现按"模式 + 启用开关"选端口，一旦被选中的服务没起来
#       (例如 Mihomo 没填订阅、AdGuardHome 启动失败)，DNS_PORT 就为空，
#       结果是完全不创建重定向规则，整机 DNS 绕过模块直连运营商。
#       这里改为按"进程确实在运行"逐级回退，保证至少有一个可用入口。
select_dns_port(){
    DNS_PORT=""
    DNS_ENTRY=""
    agh_port=""
    mihomo_port=""
    smartdns_port=""

    isRun ${AGH_BIN} && is_port_listening "${AGH_DNS_PORT}" && agh_port=${AGH_DNS_PORT}
    isRun ${MIHOMO_BIN} && is_port_listening "${MIHOMO_DNS_PORT}" && mihomo_port=${MIHOMO_DNS_PORT}
    isRun ${SMARTDNS_BIN} && is_port_listening "${SMARTDNS_PORT}" && smartdns_port=${SMARTDNS_PORT}

    if [ "${MODULE_DNS_MODE}" = "2" ]; then
        # 期望链路: Mihomo -> AdGuardHome -> SmartDNS
        set_dns_entry "${mihomo_port}" "Mihomo" || \
        set_dns_entry "${agh_port}" "AdGuardHome" || \
        set_dns_entry "${smartdns_port}" "SmartDNS"
    else
        # 期望链路: AdGuardHome -> Mihomo -> SmartDNS
        set_dns_entry "${agh_port}" "AdGuardHome" || \
        set_dns_entry "${mihomo_port}" "Mihomo" || \
        set_dns_entry "${smartdns_port}" "SmartDNS"
    fi
}

select_dns_port

# check 模式只输出结论，避免污染 WebUI 的结果显示
if [ "${1}" = "check" ]; then
    log_quiet=1
fi

if [ -n "${DNS_PORT}" ]; then
    [ "${log_quiet}" = "1" ] || log "i" "当前 DNS 入口 ${DNS_ENTRY}:${DNS_PORT}"
else
    [ "${log_quiet}" = "1" ] || log "e" "没有可用的 DNS 服务在运行，跳过 DNS 重定向"
fi

# 按 v4 / v6 分发 iptables 命令
# 注意: 不能把 ${iptables_w}(含 "iptables -w 100" 这样的多词命令串)当成单个参数传递，
#       未加引号展开后会被拆成多个词，链名与规则参数全部错位。
ipt_run(){
    case "${1}" in
        v4) shift; ${iptables_w} "$@" ;;
        v6) shift; ${ip6tables_w} "$@" ;;
    esac
}

# 判断某条规则是否存在
rule_exists(){
    rule_ver="${1}"
    shift
    ipt_run ${rule_ver} -t nat -C "$@" > /dev/null 2>&1
}

# 检查 REDIRECT 链是否完整且指向当前 DNS_PORT
# 背景: 原实现只看"链名是否存在"，链在就直接返回。
#       当某个服务被杀后回退到另一个端口(例如 AGH 挂了改用 SmartDNS 3721)，
#       链里的 REDIRECT 仍指向旧端口 —— 那个端口已经没有进程监听，
#       整机 DNS 全部进黑洞，表现为"服务恢复了但还是没网"。
#       所以必须校验跳转与端口是否与当前实际服务一致。
check_dns_chain(){
    rule_ver="${1}"
    target_chain="${2}"

    # 链不存在
    ipt_run ${rule_ver} -t nat -L ${target_chain} > /dev/null 2>&1 || return 1
    # OUTPUT 未跳转到该链
    rule_exists ${rule_ver} OUTPUT -j ${target_chain} || return 1
    # tcp/udp 53 的重定向必须指向当前 DNS_PORT
    rule_exists ${rule_ver} ${target_chain} -p tcp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    rule_exists ${rule_ver} ${target_chain} -p udp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    return 0
}

# 清理链(含 OUTPUT 跳转)
remove_dns_chain(){
    rule_ver="${1}"
    target_chain="${2}"
    while rule_exists ${rule_ver} OUTPUT -j ${target_chain}; do
        ipt_run ${rule_ver} -t nat -D OUTPUT -j ${target_chain} || break
    done
    ipt_run ${rule_ver} -t nat -F ${target_chain} 2>/dev/null
    ipt_run ${rule_ver} -t nat -X ${target_chain} 2>/dev/null
}

# 启用 dns
enable_dns(){
    chain_ver="v4"
    [ "${1}" = "ipv6" ] && chain_ver="v6"
    target_chain="${2}"

    # 已存在且规则与当前端口一致 -> 无需重建
    if check_dns_chain ${chain_ver} ${target_chain}; then
        log "i" "${target_chain} 链已存在且规则正确(端口 ${DNS_PORT})"
        return 0
    fi

    # 链在但规则不全(常见于服务换端口后) -> 先清干净再重建
    if ipt_run ${chain_ver} -t nat -L ${target_chain} > /dev/null 2>&1; then
        log "i" "${target_chain} 链规则不完整或端口已变化，重建"
        remove_dns_chain ${chain_ver} ${target_chain}
    fi

    log "i" "创建 ${target_chain} 链并添加规则(端口 ${DNS_PORT})"
    ipt_run ${chain_ver} -t nat -N ${target_chain} || return 1
    ipt_run ${chain_ver} -t nat -A ${target_chain} -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j RETURN || return 1
    ipt_run ${chain_ver} -t nat -A ${target_chain} -m owner --uid-owner ${SAM_USER} --gid-owner ${TUN_GROUP} -j RETURN || return 1
    # 回环地址必须在 REDIRECT 之前放行，否则本机自建 DNS/代理会被一起劫持
    ipt_run ${chain_ver} -t nat -A ${target_chain} -d 127.0.0.0/8 -j ACCEPT || return 1
    ipt_run ${chain_ver} -t nat -A ${target_chain} -p tcp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    ipt_run ${chain_ver} -t nat -A ${target_chain} -p udp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    ipt_run ${chain_ver} -t nat -I OUTPUT -j ${target_chain} || return 1
}

# 禁用 dns
disable_dns(){
    chain_ver="v4"
    [ "${1}" = "ipv6" ] && chain_ver="v6"
    if ! ipt_run ${chain_ver} -t nat -L ${2} > /dev/null 2>&1; then
        log "i" "${2} 链不存在，无需删除"
        return 1
    fi
    log "i" "删除 ${2} 链及规则"
    remove_dns_chain ${chain_ver} ${2}
}

# 删除指定协议的旧 DROP 规则；REJECT 已就绪时避免旧规则排在前面抢先命中
remove_ipv6_drop_rule(){
    drop_proto="${1}"
    while ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p ${drop_proto} --dport 53 -j DROP > /dev/null 2>&1; do
        ${ip6tables_w} -t filter -D ${BLOCK_IPV6_CHAIN} -p ${drop_proto} --dport 53 -j DROP || break
    done
}

# 确保指定协议有一条 DROP 规则(REJECT 不可用时的回退)
ensure_ipv6_drop_rule(){
    drop_proto="${1}"
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p ${drop_proto} --dport 53 -j DROP > /dev/null 2>&1 && return 0
    ${ip6tables_w} -t filter -A ${BLOCK_IPV6_CHAIN} -p ${drop_proto} --dport 53 -j DROP > /dev/null 2>&1
}

# 优先把规则改为 REJECT：静默 DROP 会让解析器等满超时才回退 IPv4，
# WiFi 下发 IPv6 DNS 时表现成"网络慢"。
# 先追加 REJECT 再删旧 DROP；追加失败时保留 DROP，不制造无规则空窗。
ensure_ipv6_reject_rule(){
    reject_proto="${1}"
    reject_with="${2}"
    rule_args="-p ${reject_proto} --dport 53 -j REJECT --reject-with ${reject_with}"

    if ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} ${rule_args} > /dev/null 2>&1; then
        remove_ipv6_drop_rule "${reject_proto}"
        return 0
    fi

    if ${ip6tables_w} -t filter -A ${BLOCK_IPV6_CHAIN} ${rule_args} > /dev/null 2>&1; then
        remove_ipv6_drop_rule "${reject_proto}"
        log "i" "IPv6 DNS ${reject_proto} 改为 REJECT(${reject_with})"
        return 0
    fi
    return 1
}

# 启用 ipv6 阻断
# 幂等: 链/规则/跳转分别检查后补齐，守护循环重复调用不会堆规则
# 注意: 本机解析器(SmartDNS)的 v6:53 必须在链首放行，否则会把它自己打死
enable_block_ipv6(){
    # 链不存在则创建
    if ! ${ip6tables_w} -t filter -L ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1; then
        log "i" "创建 ${BLOCK_IPV6_CHAIN} 链"
        ${ip6tables_w} -t filter -N ${BLOCK_IPV6_CHAIN} || return 1
    fi

    # 放行本机解析器(插到链首，必须排在 DROP/REJECT 之前)
    # 部分内核没有 xt_owner，这里失败只降级、不中断整个流程
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p udp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I ${BLOCK_IPV6_CHAIN} 1 -p udp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT 2>/dev/null
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p tcp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I ${BLOCK_IPV6_CHAIN} 1 -p tcp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT 2>/dev/null

    # 记录一次探测结果: 某些内核不支持 ip6tables REJECT，
    # 记住 drop 后不再每 10 秒重复删/加规则。
    block_mode_file="${TMP_PATH}/ipv6.block.mode"
    block_mode=$(cat "${block_mode_file}" 2>/dev/null)

    if [ "${block_mode}" = "drop" ]; then
        ensure_ipv6_drop_rule udp || return 1
        ensure_ipv6_drop_rule tcp || return 1
    else
        reject_ok=1
        ensure_ipv6_reject_rule udp "icmp6-port-unreachable" || reject_ok=0
        ensure_ipv6_reject_rule tcp "tcp-reset" || reject_ok=0

        if [ ${reject_ok} -eq 1 ]; then
            [ "${block_mode}" = "reject" ] || echo "reject" > "${block_mode_file}" 2>/dev/null
        else
            # 至少一个协议不支持 REJECT: 用 DROP 兜底，并记录避免反复探测
            ensure_ipv6_drop_rule udp || return 1
            ensure_ipv6_drop_rule tcp || return 1
            [ "${block_mode}" = "drop" ] || echo "drop" > "${block_mode_file}" 2>/dev/null
            log "e" "部分内核不支持 IPv6 REJECT，已回退 DROP；WiFi 下解析超时风险仍在"
        fi
    fi

    # 挂到 OUTPUT(只在缺失时插入)
    ${ip6tables_w} -t filter -C OUTPUT -j ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I OUTPUT -j ${BLOCK_IPV6_CHAIN} || return 1
}

# 禁用 ipv6 阻断
disable_block_ipv6(){
    if ! ${ip6tables_w} -t filter -L ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1; then
        log "i" "${BLOCK_IPV6_CHAIN} 链不存在，无需删除"
        return 1
    fi
    log "i" "删除 ${BLOCK_IPV6_CHAIN} 链及规则"
    # 先摘跳转，再清链，最后删链；逐条删兼容重复追加
    while ${ip6tables_w} -t filter -C OUTPUT -j ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1; do
        ${ip6tables_w} -t filter -D OUTPUT -j ${BLOCK_IPV6_CHAIN} || break
    done
    ${ip6tables_w} -t filter -F ${BLOCK_IPV6_CHAIN} 2>/dev/null
    ${ip6tables_w} -t filter -X ${BLOCK_IPV6_CHAIN} 2>/dev/null
}

# 是否支持 ipv6 nat(静默版本，供内部判断用)
has_ipv6_nat(){
    ${ip6tables_w} -t nat -L >/dev/null 2>&1
}

# 添加指令
case "$1" in
    # 启用
    enable)
        if [ -n "${DNS_PORT}" ]; then
            if [ "${DNS_PORT}" = "53" ]; then
                log "i" "端口等于 53，移除旧重定向规则"
                disable_dns "ipv4" ${DNS_CHAIN}
            else
                enable_dns "ipv4" ${DNS_CHAIN}
            fi
            if [ "${BLOCK_IPV6_DNS}" = "true" ]; then
                # v6 阻断优先于重定向，清掉历史版本可能残留的 v6 重定向链
                has_ipv6_nat && remove_dns_chain v6 ${IPV6_DNS_CHAIN}
                enable_block_ipv6
            else
                has_ipv6_nat && remove_dns_chain v6 ${IPV6_DNS_CHAIN}
                log "i" "未阻断 IPv6 DNS，v6 查询将绕过本模块"
            fi
        else
            # 进程在但端口没在监听时，保留旧规则会把整机 DNS 指向死端口；
            # 这里清掉重定向与 v6 阻断，让系统回退到网络下发的 DNS
            log "e" "没有正在监听的 DNS 服务，移除重定向规则避免 DNS 进黑洞"
            disable_dns "ipv4" ${DNS_CHAIN}
            has_ipv6_nat && remove_dns_chain v6 ${IPV6_DNS_CHAIN}
            disable_block_ipv6
        fi
        ;;
    # 禁用
    disable)
        disable_dns "ipv4" ${DNS_CHAIN}
        has_ipv6_nat && remove_dns_chain v6 ${IPV6_DNS_CHAIN}
        disable_block_ipv6
        ;;
    # 状态检查(供 WebUI/守护循环判断规则是否与当前端口一致)
    check)
        # 直通模式本来就不该有重定向规则，不能判成异常
        if [ "${BYPASS_ENABLE}" = "true" ]; then
            echo "直通模式(不劫持 DNS)"
            exit 0
        fi
        if [ -z "${DNS_PORT}" ]; then
            echo "无 DNS 服务在运行"
            exit 2
        fi
        if check_dns_chain v4 ${DNS_CHAIN}; then
            echo "DNS 规则正常(${DNS_ENTRY}:${DNS_PORT})"
            exit 0
        fi
        echo "DNS 规则缺失或端口不匹配(期望 ${DNS_ENTRY}:${DNS_PORT})"
        exit 1
        ;;
esac
