# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# DNS 链
DNS_CHAIN="REDIRECT_DNS"
IPV6_DNS_CHAIN="REDIRECT_IPV6_DNS"
# 阻断 ipv6 链
BLOCK_IPV6_CHAIN="BLOCK_IPV6_DNS"

# 获取 SmartDNS 端口
SMARTDNS_PORT=$(cat "${SMARTDNS_CONF}" | grep "bind" | sed -n "s/bind.*:\(.*\)/\1/p")

# 选择实际可用的 DNS 转发端口
# 说明: 原实现按"模式 + 启用开关"选端口，一旦被选中的服务没起来
#       (例如 Mihomo 没填订阅、AdGuardHome 启动失败)，DNS_PORT 就为空，
#       结果是完全不创建重定向规则，整机 DNS 绕过模块直连运营商。
#       这里改为按"进程确实在运行"逐级回退，保证至少有一个可用入口。
select_dns_port(){
    DNS_PORT=""
    agh_port=""
    mihomo_port=""
    smartdns_port=""

    isRun ${AGH_BIN} && agh_port=${AGH_DNS_PORT}
    isRun ${MIHOMO_BIN} && mihomo_port=${MIHOMO_DNS_PORT}
    isRun ${SMARTDNS_BIN} && smartdns_port=${SMARTDNS_PORT}

    if [ "${MODULE_DNS_MODE}" = "2" ]; then
        # 期望链路: Mihomo -> AdGuardHome -> SmartDNS
        for candidate_port in "${mihomo_port}" "${agh_port}" "${smartdns_port}"; do
            if [ -n "${candidate_port}" ]; then
                DNS_PORT="${candidate_port}"
                break
            fi
        done
    else
        # 期望链路: AdGuardHome -> Mihomo -> SmartDNS
        for candidate_port in "${agh_port}" "${mihomo_port}" "${smartdns_port}"; do
            if [ -n "${candidate_port}" ]; then
                DNS_PORT="${candidate_port}"
                break
            fi
        done
    fi
}

select_dns_port

if [ -n "${DNS_PORT}" ]; then
    log "i" "当前 DNS 转发端口 ${DNS_PORT}"
else
    log "e" "没有可用的 DNS 服务在运行，跳过 DNS 重定向"
fi

itw=${iptables_w}

# 启用 dns
enable_dns(){
    [ "${1}" = "ipv4" ] && itw=${iptables_w} || itw=${ip6tables_w}
    if ${itw} -t nat -L ${2} > /dev/null 2>&1; then
        log "e" "${2} 链已存在"
        return 1
    fi
    log "i" "创建 ${2} 链并添加规则"
    ${itw} -t nat -N ${2} || return 1
    ${itw} -t nat -A ${2} -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j RETURN || return 1
    ${itw} -t nat -A ${2} -m owner --uid-owner ${SAM_USER} --gid-owner ${TUN_GROUP} -j RETURN || return 1
    ${itw} -t nat -A ${2} -p tcp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    ${itw} -t nat -A ${2} -p udp --dport 53 -j REDIRECT --to-ports ${DNS_PORT} || return 1
    ${itw} -t nat -A ${2} -d 127.0.0.0/8 -j ACCEPT || return 1
    ${itw} -t nat -I OUTPUT -j ${2} || return 1
}

# 禁用 dns
disable_dns(){
    [ "${1}" = "ipv4" ] && itw=${iptables_w} || itw=${ip6tables_w}
    if ! ${itw} -t nat -L ${2} > /dev/null 2>&1; then
        log "e" "${2} 链不存在"
        return 1
    fi
    log "i" "删除 ${2} 链及规则"
    # 逐条删除，兼容历史上重复追加的跳转规则(单条 -D 只会删掉一条)
    while ${itw} -t nat -C OUTPUT -j ${2} > /dev/null 2>&1; do
        ${itw} -t nat -D OUTPUT -j ${2} || break
    done
    ${itw} -t nat -F ${2} 2>/dev/null
    ${itw} -t nat -X ${2} 2>/dev/null
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

    # 放行本机解析器(插到链首，必须排在 DROP 之前)
    # 部分内核没有 xt_owner，这里失败只降级、不中断整个流程
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p udp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I ${BLOCK_IPV6_CHAIN} 1 -p udp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT 2>/dev/null
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p tcp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I ${BLOCK_IPV6_CHAIN} 1 -p tcp --dport 53 -m owner --uid-owner ${SAM_USER} --gid-owner ${DNS_GROUP} -j ACCEPT 2>/dev/null

    # 拦截其余 v6 DNS
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p tcp --dport 53 -j DROP > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -A ${BLOCK_IPV6_CHAIN} -p tcp --dport 53 -j DROP || return 1
    ${ip6tables_w} -t filter -C ${BLOCK_IPV6_CHAIN} -p udp --dport 53 -j DROP > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -A ${BLOCK_IPV6_CHAIN} -p udp --dport 53 -j DROP || return 1

    # 挂到 OUTPUT(只在缺失时插入)
    ${ip6tables_w} -t filter -C OUTPUT -j ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1 || \
        ${ip6tables_w} -t filter -I OUTPUT -j ${BLOCK_IPV6_CHAIN} || return 1
}

# 禁用 ipv6 阻断
disable_block_ipv6(){
    if ! ${ip6tables_w} -t filter -L ${BLOCK_IPV6_CHAIN} > /dev/null 2>&1; then
        log "e" "${BLOCK_IPV6_CHAIN} 链不存在"
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

# 是否支持 ipv6 nat
is_ipv6_nat(){
    if ${ip6tables_w} -t nat -L >/dev/null 2>&1; then
        return 0
    else
        log "e" "不支持 ipv6 nat"
        return 1
    fi
}

# 判断端口是否等于 53
is_dns_port(){
    if [ "${DNS_PORT}" = "53" ]; then
        log "i" "端口等于 53，跳过添加规则"
        return 0
    else
        return 1
    fi
}

# 添加指令
case "$1" in
    # 启用
    enable)
        if [ -n "${DNS_PORT}" ]; then
            is_dns_port || enable_dns "ipv4" ${DNS_CHAIN}
        fi
        if [ "${BLOCK_IPV6_DNS}" = "true" ]; then
            enable_block_ipv6
        elif is_ipv6_nat; then
            enable_dns "ipv6" ${IPV6_DNS_CHAIN}
        else
            # 内核没有 IPv6 nat 表: 既不能重定向、用户也没要求阻断，
            # 此时 v6 DNS 会整块绕过本模块，这里显式留痕，避免"过滤悄悄失效"
            log "e" "内核无 IPv6 nat 表且未开启 IPv6 阻断，IPv6 DNS 将绕过本模块"
        fi
        ;;
    # 禁用
    disable)
        disable_dns "ipv4" ${DNS_CHAIN}
        is_ipv6_nat && disable_dns "ipv6" ${IPV6_DNS_CHAIN}
        disable_block_ipv6
        ;;
esac