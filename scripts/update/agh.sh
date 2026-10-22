# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 读取配置内容
content=$(cat ${AGH_CONF})

# 获取 SmartDNS 端口
SMARTDNS_PORT=$(cat ${SMARTDNS_CONF} | grep "bind" | sed -n "s/bind.*:\(.*\)/\1/p")

# 修改配置
modify_conf(){
    # 获取开始行
    start_line=$(echo "${content}" | sed -n "/upstream_dns:/=")
    let "start_line++"
    # 获取结束行
    end_line=$(echo "${content}" | sed -n "/upstream_dns_file:/=")
    let "end_line--"
    # 获取项的前缀
    prefix=$(echo "${content}" | sed -n "${start_line}p" | sed -e "s/-.*/- /g" -e "s/ /$(placeholder 1)/g")
    # 获取默认DNS
    default_dns=$(echo "${DNS_LIST}" | grep -Ev "^[[:space:]]*$" | sed "s/^/${prefix}/g")
    default_dns=$(echo ${default_dns} | sed "s/ /∷/g")
    # 判断 SmartDNS 启用，则使用 SmartDNS，未启用则使用默认DNS
    if [ "${SMARTDNS_ENABLE}" = true ] && [ "${MODULE_DNS_MODE}" = 2 ] && [ $(isRun ${SMARTDNS_BIN} "pid") ]; then
        log "i" "${AGH_BIN} 上游DNS使用 ${SMARTDNS_BIN}"
        modify_dns "${prefix}127.0.0.1:${SMARTDNS_PORT}"
    elif [ "${MIHOMO_ENABLE}" = true ] && [ "${MODULE_DNS_MODE}" = 1 ] && [ $(isRun ${MIHOMO_BIN} "pid") ]; then
        log "i" "${AGH_BIN} 上游DNS使用 ${MIHOMO_BIN}"
        modify_dns "${prefix}127.0.0.1:${MIHOMO_DNS_PORT}"
    elif [ "${MIHOMO_ENABLE}" = false ] && [ "${SMARTDNS_ENABLE}" = true ] && [ $(isRun ${SMARTDNS_BIN} "pid") ]; then
        log "i" "${AGH_BIN} 上游DNS使用 ${SMARTDNS_BIN}"
        modify_dns "${prefix}127.0.0.1:${SMARTDNS_PORT}"
    else
        log "i" "${AGH_BIN} 上游DNS使用默认DNS"
        modify_dns "${default_dns}"
    fi
}

# 修改DNS
modify_dns(){
    echo "${content}" | sed "${start_line},${end_line}d" | sed "${start_line}i ${1}" | sed -e "s/$(placeholder 1)/ /g" -e "s/∷/\n/g" > ${AGH_CONF}
}

# 修改 DNS 端口
modify_dns_port(){
    # 获取 AdGuardHome DNS 端口
    port_value=$(cat ${AGH_CONF} | sed -n '/port:/p' | grep "port" | awk 'NR==2{print $2}' | tr -d "[:space:]")
    # 判断 AdGuardHome DNS 端口与设置的端口不一致则修改
    # port_value 读不到时不要做数值比较，否则 [ 会直接报错
    [ -z "${port_value}" ] && return 0

    if ! [ "${AGH_DNS_PORT}" -eq "${port_value}" ]; then
        log "i" "修改 AdGuardHome DNS 端口 ${port_value} 为 ${AGH_DNS_PORT}"
        cat ${AGH_CONF} | sed -i "s/port: ${port_value}/port: ${AGH_DNS_PORT}/g" ${AGH_CONF}
    fi
}

# 获取结束行数
get_end_line(){
    line=${1}
    # 获取当前行数的内容
    item=$(echo "${content}" | sed -n "${line}p" | grep "-")
    # 判断当前内容是否还在项内
    if [ "${item}" ]; then
        # 自增，并重新调用当前函数
        let "line++"
        get_end_line ${line}
    else
        # 自减，并返回行数
        let "line--"
        echo ${line}
        return 0
    fi
}

# 修改 WebUI 监听地址
# 默认只监听回环: 0.0.0.0 会让同一 WiFi 下的设备用默认密码直接登进来
modify_web_addr(){
    if [ "${LAN_ACCESS}" = "true" ]; then
        web_addr="0.0.0.0:3000"
    else
        web_addr="127.0.0.1:3000"
    fi

    current_addr=$(grep -m1 "^  address:" "${AGH_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${current_addr}" ] && [ "${current_addr}" != "${web_addr}" ]; then
        log "i" "修改 ${AGH_BIN} WebUI 监听 ${current_addr} 为 ${web_addr}"
        sed -i "s|^  address: .*|  address: ${web_addr}|" "${AGH_CONF}"
    fi
}

# 明确关闭 AGH 自己的 DNS 缓存
# 理由: 上游 SmartDNS 已经带缓存(prefetch-domain / serve-expired / cache-persist)，
#       缓存职责放在 SmartDNS 一侧即可。AGH 再开一层缓存有两个问题:
#         1. 双份缓存白白吃掉内存(本模块最怕的就是内存紧张被 LMKD 杀)
#         2. AGH 缓存会把 SmartDNS 精心选出的最优 IP 冻结住,
#            后续查询直接命中 AGH 缓存, 绕过 SmartDNS 的测速与选优逻辑
#       延迟优化应从 SmartDNS 侧做(rr-ttl / response-mode / speed-check-mode)，
#       而不是在这里加一层缓存。
modify_cache(){
    grep -q "^  cache_enabled:" "${AGH_CONF}" 2>/dev/null || return 0

    if ! grep -q "^  cache_enabled: false" "${AGH_CONF}" 2>/dev/null; then
        log "i" "关闭 ${AGH_BIN} DNS 缓存(缓存由上游 ${SMARTDNS_BIN} 负责)"
        sed -i "s|^  cache_enabled: .*|  cache_enabled: false|" "${AGH_CONF}"
    fi

    cache_size=$(grep -m1 "^  cache_size:" "${AGH_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${cache_size}" ] && [ "${cache_size}" != "0" ]; then
        log "i" "重置 ${AGH_BIN} 缓存大小为 0"
        sed -i "s|^  cache_size: .*|  cache_size: 0|" "${AGH_CONF}"
    fi

    if ! grep -q "^  cache_optimistic: false" "${AGH_CONF}" 2>/dev/null; then
        log "i" "关闭 ${AGH_BIN} 乐观缓存"
        sed -i "s|^  cache_optimistic: .*|  cache_optimistic: false|" "${AGH_CONF}"
    fi
}

modify_conf
modify_dns_port
modify_web_addr
modify_cache