#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 单条规则不存在才插入(幂等，守护循环重复调用不会堆规则)
TUN_APPLIED_FILE="${TMP_PATH}/tun.applied.device"

add_tun_rule(){
    ${iptables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || \
        ${iptables_w} -I FORWARD ${1} ${TUN_DEVICE} -j ACCEPT
    ${ip6tables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -I FORWARD ${1} ${TUN_DEVICE} -j ACCEPT
}

# 逐条删除直到不存在(兼容历史上重复追加的规则)
del_tun_rule_for_device(){
    del_device="${1}"
    [ -n "${del_device}" ] || return 0
    while ${iptables_w} -C FORWARD ${2} ${del_device} -j ACCEPT > /dev/null 2>&1; do
        ${iptables_w} -D FORWARD ${2} ${del_device} -j ACCEPT || break
    done
    while ${ip6tables_w} -C FORWARD ${2} ${del_device} -j ACCEPT > /dev/null 2>&1; do
        ${ip6tables_w} -D FORWARD ${2} ${del_device} -j ACCEPT || break
    done
}

del_tun_rule(){
    del_tun_rule_for_device "${TUN_DEVICE}" "${1}"
    # 配置改名后必须清理旧网卡规则，否则旧接口被复用时会残留放行
    if [ -f "${TUN_APPLIED_FILE}" ]; then
        old_tun_device=$(cat "${TUN_APPLIED_FILE}" 2>/dev/null)
        [ "${old_tun_device}" != "${TUN_DEVICE}" ] && del_tun_rule_for_device "${old_tun_device}" "${1}"
    fi
}

# 添加指令
case "$1" in
    # 添加
    add)
        # IP 转发
        if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "0" ]; then
            echo 1 > /proc/sys/net/ipv4/ip_forward && log "i" "开启 IP 转发" || log "e" "开启 IP 转发失败"
        fi
        add_tun_rule "-o"
        add_tun_rule "-i"
        echo "${TUN_DEVICE}" > "${TUN_APPLIED_FILE}" 2>/dev/null
        log "i" "添加 TUN 流量转发"
        ;;
    # 删除
    del)
        del_tun_rule "-o"
        del_tun_rule "-i"
        rm -f "${TUN_APPLIED_FILE}" 2>/dev/null
        log "i" "删除 TUN 流量转发"
        ;;
esac
