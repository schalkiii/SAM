#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 工具页可能直接调用本脚本，先清洗 BOM/CR；UTF-16 明确拒绝
sanitize_config "${AGH_CONF}"
[ $? -eq 2 ] && exit 1

SMARTDNS_PORT=$(smartdns_port)
# 全文件改写的临时文件；每个修改函数写它再原子替换
# 放在 TMP_PATH 而不是配置目录，进程被杀时不会在 AGH 目录里留垃圾
AGH_TMP="${TMP_PATH}/agh.yaml.$$"

# 取 dns 段的 port
# 必须锚定在 dns: 段内：AGH 的 pprof/tls 段也有 port 字段，按"第 N 个 port:"取会随
# AGH 版本变化而错位，改端口时看起来成功、实际 DNS 还监听旧端口。
get_dns_port(){
    awk '
        /^dns:/ { in_dns = 1; next }
        in_dns && /^[^[:space:]]/ { in_dns = 0 }
        in_dns && /^  port:[[:space:]]/ { print $2; exit }
    ' "${AGH_CONF}" 2>/dev/null
}

# 原子替换配置；空文件或缺少关键段时放弃，避免把 AGH 配置写坏
commit_conf(){
    if [ ! -s "${AGH_TMP}" ] || ! grep -q "^dns:" "${AGH_TMP}" 2>/dev/null; then
        log "e" "${AGH_BIN} 配置生成结果异常，保留原文件"
        rm -f "${AGH_TMP}"
        return 1
    fi
    mv -f "${AGH_TMP}" "${AGH_CONF}"
}

# 生成 upstream_dns 列表行(4 空格缩进)
write_upstream_file(){
    : > "${AGH_TMP}.upstream"
    for upstream_item in "$@"; do
        printf '    - %s\n' "${upstream_item}" >> "${AGH_TMP}.upstream"
    done
}

# 替换 upstream_dns 列表，保留其后的 upstream_dns_file 等配置
replace_upstream(){
    write_upstream_file "$@"
    awk -v repl_file="${AGH_TMP}.upstream" '
        /^  upstream_dns:/ {
            # 统一写成块列表，兼容 AGH 把 upstream_dns 写成 [] 内联形式
            print "  upstream_dns:"
            while ((getline line < repl_file) > 0) print line
            skip = 1
            next
        }
        skip && /^    - / { next }
        skip { skip = 0 }
        { print }
    ' "${AGH_CONF}" > "${AGH_TMP}"
    rm -f "${AGH_TMP}.upstream"
    commit_conf
}

# 兜底: 配置里没有 upstream_dns 段时补一个，避免 AGH 退回默认公共 DNS
insert_upstream(){
    write_upstream_file "$@"
    awk -v repl_file="${AGH_TMP}.upstream" '
        { print }
        /^dns:$/ {
            print "  upstream_dns:"
            while ((getline line < repl_file) > 0) print line
        }
    ' "${AGH_CONF}" > "${AGH_TMP}"
    rm -f "${AGH_TMP}.upstream"
    commit_conf
}

modify_conf(){
    if ! grep -q "^  upstream_dns:" "${AGH_CONF}" 2>/dev/null; then
        log "e" "${AGH_BIN} 配置缺少 upstream_dns，已插入默认上游"
        insert_upstream $(echo "${DNS_LIST}")
        return $?
    fi

    # 判断 SmartDNS 启用且端口确实在监听，才把它作为上游
    # 期望链路不可用时回退到另一个可用本地 DNS；全不可用才使用公共 DNS
    if [ "${SMARTDNS_ENABLE}" = "true" ] && [ "${MODULE_DNS_MODE}" = "2" ] && \
       isRun "${SMARTDNS_BIN}" && is_port_listening "${SMARTDNS_PORT}"; then
        log "i" "${AGH_BIN} 上游DNS使用 ${SMARTDNS_BIN}"
        replace_upstream "127.0.0.1:${SMARTDNS_PORT}"
    elif [ "${MIHOMO_ENABLE}" = "true" ] && [ "${MODULE_DNS_MODE}" = "1" ] && \
         isRun "${MIHOMO_BIN}" && is_port_listening "${MIHOMO_DNS_PORT}"; then
        log "i" "${AGH_BIN} 上游DNS使用 ${MIHOMO_BIN}"
        replace_upstream "127.0.0.1:${MIHOMO_DNS_PORT}"
    elif [ "${SMARTDNS_ENABLE}" = "true" ] && isRun "${SMARTDNS_BIN}" && is_port_listening "${SMARTDNS_PORT}"; then
        log "i" "${AGH_BIN} 上游DNS回退到 ${SMARTDNS_BIN}"
        replace_upstream "127.0.0.1:${SMARTDNS_PORT}"
    elif [ "${MIHOMO_ENABLE}" = "true" ] && isRun "${MIHOMO_BIN}" && is_port_listening "${MIHOMO_DNS_PORT}"; then
        log "i" "${AGH_BIN} 上游DNS回退到 ${MIHOMO_BIN}"
        replace_upstream "127.0.0.1:${MIHOMO_DNS_PORT}"
    else
        log "i" "${AGH_BIN} 上游DNS使用默认DNS"
        replace_upstream $(echo "${DNS_LIST}")
    fi
}

# 修改 DNS 端口（只匹配 dns 段的两空格缩进 port:）
modify_dns_port(){
    port_value=$(get_dns_port)
    [ -z "${port_value}" ] && {
        log "e" "读取 ${AGH_BIN} DNS 端口失败"
        return 1
    }
    if [ "${AGH_DNS_PORT}" != "${port_value}" ]; then
        log "i" "修改 AdGuardHome DNS 端口 ${port_value} 为 ${AGH_DNS_PORT}"
        sed "s|^  port: .*|  port: ${AGH_DNS_PORT}|" "${AGH_CONF}" > "${AGH_TMP}" && commit_conf
    fi
}

# 修改 dns.bind_hosts
# LAN_ACCESS=true 时 AGH DNS 对局域网开放；Mihomo 的代理/控制端不在此开放(见 update/mihomo.sh)
modify_dns_bind(){
    if [ "${LAN_ACCESS}" = "true" ]; then
        bind_value="0.0.0.0"
    else
        bind_value="127.0.0.1"
    fi

    if grep -q "^  bind_hosts:" "${AGH_CONF}" 2>/dev/null; then
        awk -v addr="${bind_value}" '
            /^  bind_hosts:/ { print "  bind_hosts:"; print "    - " addr; skip = 1; next }
            skip && /^    - / { next }
            skip { skip = 0 }
            { print }
        ' "${AGH_CONF}" > "${AGH_TMP}"
    else
        awk -v addr="${bind_value}" '
            { print }
            /^dns:$/ { print "  bind_hosts:"; print "    - " addr }
        ' "${AGH_CONF}" > "${AGH_TMP}"
    fi
    commit_conf
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
        sed "s|^  address: .*|  address: ${web_addr}|" "${AGH_CONF}" > "${AGH_TMP}" && commit_conf
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
    # 新版 AGH 可能省略 cache_enabled，缺省值会重新打开缓存，必须补上 false
    if ! grep -q "^  cache_enabled:" "${AGH_CONF}" 2>/dev/null; then
        awk '{ print } /^dns:$/ { print "  cache_enabled: false" }' "${AGH_CONF}" > "${AGH_TMP}" && \
            commit_conf || return 1
    fi

    if ! grep -q "^  cache_enabled: false" "${AGH_CONF}" 2>/dev/null; then
        log "i" "关闭 ${AGH_BIN} DNS 缓存(缓存由上游 ${SMARTDNS_BIN} 负责)"
        sed "s|^  cache_enabled: .*|  cache_enabled: false|" "${AGH_CONF}" > "${AGH_TMP}" && commit_conf || return 1
    fi

    cache_size=$(grep -m1 "^  cache_size:" "${AGH_CONF}" 2>/dev/null | awk '{print $2}')
    if [ -n "${cache_size}" ] && [ "${cache_size}" != "0" ]; then
        log "i" "重置 ${AGH_BIN} 缓存大小为 0"
        sed "s|^  cache_size: .*|  cache_size: 0|" "${AGH_CONF}" > "${AGH_TMP}" && commit_conf || return 1
    fi

    if ! grep -q "^  cache_optimistic: false" "${AGH_CONF}" 2>/dev/null; then
        log "i" "关闭 ${AGH_BIN} 乐观缓存"
        sed "s|^  cache_optimistic: .*|  cache_optimistic: false|" "${AGH_CONF}" > "${AGH_TMP}" && commit_conf || return 1
    fi
}

agh_failed=0
modify_conf || agh_failed=1
modify_dns_port || agh_failed=1
modify_dns_bind || agh_failed=1
modify_web_addr || agh_failed=1
modify_cache || agh_failed=1
rm -f "${AGH_TMP}"
[ ${agh_failed} -eq 0 ] || exit 1
