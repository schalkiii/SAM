# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 单条规则不存在才插入(幂等，守护循环重复调用不会堆规则)
add_tun_rule(){
    ${iptables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || \
        ${iptables_w} -I FORWARD ${1} ${TUN_DEVICE} -j ACCEPT
    ${ip6tables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1 || \
        ${ip6tables_w} -I FORWARD ${1} ${TUN_DEVICE} -j ACCEPT
}

# 逐条删除直到不存在(兼容历史上重复追加的规则)
del_tun_rule(){
    while ${iptables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1; do
        ${iptables_w} -D FORWARD ${1} ${TUN_DEVICE} -j ACCEPT || break
    done
    while ${ip6tables_w} -C FORWARD ${1} ${TUN_DEVICE} -j ACCEPT > /dev/null 2>&1; do
        ${ip6tables_w} -D FORWARD ${1} ${TUN_DEVICE} -j ACCEPT || break
    done
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
        log "i" "添加 TUN 流量转发"
        ;;
    # 删除
    del)
        del_tun_rule "-o"
        del_tun_rule "-i"
        log "i" "删除 TUN 流量转发"
        ;;
esac
