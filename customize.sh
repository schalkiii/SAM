#!/system/bin/sh
SKIPUNZIP=1

# 模块路径
MODULE_PATH="/data/adb/modules/SAM"

# MODPATH 由管理器提供(临时 root 下手动安装可能缺失)
if [ -z "${MODPATH}" ]; then
    ui_print "❌ 缺少 MODPATH，请在模块管理器中刷入，或使用 manual.sh install <zip>"
    exit 1
fi

ui_print "📥 开始安装"
ui_print "📥 解压模块文件"
unzip -o "${ZIPFILE}" "*" -x "META-INF/*" -d "${MODPATH}" >/dev/null 2>&1
unzip_rc=$?
if [ ${unzip_rc} -ne 0 ] || [ ! -f "${MODPATH}/module.prop" ] || [ ! -f "${MODPATH}/scripts/service.sh" ]; then
    ui_print "❌ 解压失败或模块包缺少关键文件，安装中止"
    rm -rf "${MODPATH}" 2>/dev/null
    exit 1
fi
ui_print "💾 文件解压完成"

ui_print "🔒 设置权限"
chmod -R +x "${MODPATH}/bin"
chmod +x "${MODPATH}/etc/SmartDNS/smartdns"
chmod +x "${MODPATH}/etc/SmartDNS/smartdns_ui.so"
chmod -R +x "${MODPATH}/etc/SmartDNS/lib"
chown root:net_raw "${MODPATH}/etc/SmartDNS/smartdns"
chown root:net_raw "${MODPATH}/bin/AdGuardHome"
chown root:net_admin "${MODPATH}/bin/mihomo"
find "${MODPATH}" -type f -name "*.sh" -exec chmod +x {} \;

# 设置输出内容
out_content=$(cat "${MODPATH}/setting.conf")
# 旧设置内容
# 先清洗 BOM 与 CRLF，避免把坏格式原样迁移进新版本
if [ -f "${MODULE_PATH}/setting.conf" ]; then
    if [ "$(head -c 3 "${MODULE_PATH}/setting.conf" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
        old_content=$(tail -c +4 "${MODULE_PATH}/setting.conf" | tr -d '\015')
    else
        # 用 tr -d '\n' 去掉 CRLF 的回车。
        # 原用 sed 's/\n$//'，但 \n 作为替换文本里的换行符只有 GNU sed 保证支持，
        # busybox / toybox sed 的行为依版本而异，一旦不生效就会把 CRLF 带进新版本配置。
        old_content=$(tr -d '\015' < "${MODULE_PATH}/setting.conf")
    fi
else
    old_content=""
fi

# 修改设置
modify_setting(){
    # 旧值(锚定 KEY=，避免新键是旧键子串时误匹配；示例行不参与迁移)
    old_value=$(echo "${1}" | grep -v "示例" | grep "^${3}=")
    # 判断内容为空则返回
    [ -z "${old_value}" ] && return 0
    # 新配置中找不到该键时必须放弃，否则 sed 的 c 命令会替换整个文件
    line_number=$(echo "${2}" | sed "/示例:/c \#" | sed -n "/^${3}=/=" | sed -n "1p")
    [ -z "${line_number}" ] && return 0
    # 替换
    out_content=$(echo "${2}" | sed "${line_number}c ${old_value}")
}

# 更新设置
update_setting(){
    modify_setting "${old_content}" "${out_content}" "SMARTDNS_ENABLE"
    modify_setting "${old_content}" "${out_content}" "AGH_ENABLE"
    modify_setting "${old_content}" "${out_content}" "AGH_DNS_PORT"
    modify_setting "${old_content}" "${out_content}" "BLOCK_IPV6_DNS"
    modify_setting "${old_content}" "${out_content}" "MIHOMO_ENABLE"
    modify_setting "${old_content}" "${out_content}" "MIHOMO_IPV6"
    modify_setting "${old_content}" "${out_content}" "MIHOMO_DNS_PORT"
    modify_setting "${old_content}" "${out_content}" "MIHOMO_DNS_MODE"
    modify_setting "${old_content}" "${out_content}" "TUN_DEVICE"
    modify_setting "${old_content}" "${out_content}" "IP_IPTABLES"
    modify_setting "${old_content}" "${out_content}" "HOST_ENABLE"
    modify_setting "${old_content}" "${out_content}" "CRONTAB_ENABLE"
    modify_setting "${old_content}" "${out_content}" "MODULE_DNS_MODE"
    modify_setting "${old_content}" "${out_content}" "BYPASS_ENABLE"
    modify_setting "${old_content}" "${out_content}" "LAN_ACCESS"
    modify_setting "${old_content}" "${out_content}" "SMARTDNS_RESPONSE_MODE"
    modify_setting "${old_content}" "${out_content}" "SMARTDNS_SPEED_CHECK"
    modify_setting "${old_content}" "${out_content}" "SMARTDNS_DUALSTACK"
    modify_setting "${old_content}" "${out_content}" "SMARTDNS_TTL_MIN"
    modify_setting "${old_content}" "${out_content}" "NETWORK_REFRESH"
    modify_setting "${old_content}" "${out_content}" "AD_BLOCK_ENABLE"
    modify_setting "${old_content}" "${out_content}" "BACKUP_CONF"
    modify_setting "${old_content}" "${out_content}" "EXCLUDE_NODE"
    modify_setting "${old_content}" "${out_content}" "SUB_URL"
    modify_setting "${old_content}" "${out_content}" "ENABLE_WHITELIST"
    modify_setting "${old_content}" "${out_content}" "WHITELIST_MODE"
    modify_setting "${old_content}" "${out_content}" "BLACKLIST_WIFI"
    echo "${out_content}" > "${MODPATH}/setting.conf"
}

if [ -e "${MODULE_PATH}/setting.conf" ]; then
    ui_print "🏷️ 使用已有配置"
    # 更新设置
    update_setting
    # 复制黑白名单和hosts文件
    find "${MODULE_PATH}/etc" -maxdepth 1 -type f -exec cp {} "${MODPATH}/etc" \;
    # 保留用户在 AGH 面板里加的过滤器/重写/统计配置
    if [ -f "${MODULE_PATH}/etc/AdGuardHome/AdGuardHome.yaml" ]; then
        cp -f "${MODULE_PATH}/etc/AdGuardHome/AdGuardHome.yaml" "${MODPATH}/etc/AdGuardHome/AdGuardHome.yaml"
        # 旧配置可能来自升级后的 AGH(schema 更高)；内置二进制回退时无法读取。
        # 安装阶段先提示，启动失败后可在工具页用模板重置。
        old_agh_schema=$(grep -m1 '^schema_version:' "${MODULE_PATH}/etc/AdGuardHome/AdGuardHome.yaml" 2>/dev/null | awk '{print $2}' | tr -d '\015')
        new_agh_schema=$(grep -m1 '^schema_version:' "${MODPATH}/etc/AdGuardHome/AdGuardHome.template.yaml" 2>/dev/null | awk '{print $2}' | tr -d '\015')
        if [ -n "${old_agh_schema}" ] && [ -n "${new_agh_schema}" ] && [ "${old_agh_schema}" -gt "${new_agh_schema}" ] 2>/dev/null; then
            ui_print "提示: 旧 AGH 配置 schema ${old_agh_schema} 高于本包模板 ${new_agh_schema}"
            ui_print "      若启动报 unknown current schema version，请用「工具 → 重置 AGH 配置」"
        fi
    fi
    # 复制 SmartDNS 使用缓存
    cp -R -f "${MODULE_PATH}/etc/SmartDNS/data/." "${MODPATH}/etc/SmartDNS/data"
    # 复制 AdGuardHome 使用缓存与 data/filters 下的自定义过滤器
    mkdir -p "${MODPATH}/etc/AdGuardHome/data"
    cp -R -f "${MODULE_PATH}/etc/AdGuardHome/data/." "${MODPATH}/etc/AdGuardHome/data"
    # 复制 Mihomo 使用缓存
    cp -R -f "${MODULE_PATH}/etc/mihomo/proxy_provider/." "${MODPATH}/etc/mihomo/proxy_provider"
    cp -R -f "${MODULE_PATH}/etc/mihomo/rule_provider/." "${MODPATH}/etc/mihomo/rule_provider"    
    cp -f "${MODULE_PATH}/etc/mihomo/cache.db" "${MODPATH}/etc/mihomo/cache.db"
fi

# 安装到 modules_update 时，模块管理器会先显示新包的 module.prop；
# 不要让它显示"模块未启动"，否则用户会误以为已安装的模块没有运行。
if [ -f "${MODPATH}/module.prop" ]; then
    pending_prop_tmp="${MODPATH}/module.prop.tmp"
    : > "${pending_prop_tmp}" 2>/dev/null
    while IFS= read -r pending_line || [ -n "${pending_line}" ]; do
        case "${pending_line}" in
            description=*) printf 'description=%s\n' "已安装，待重启/激活生效" >> "${pending_prop_tmp}" ;;
            *) printf '%s\n' "${pending_line}" >> "${pending_prop_tmp}" ;;
        esac
    done < "${MODPATH}/module.prop"
    mv -f "${pending_prop_tmp}" "${MODPATH}/module.prop" 2>/dev/null
fi

ui_print "🌐 SmartDNS ( 账号: root | 密码: root )"
ui_print "🌐 SmartDNS ( WebUI: 127.0.0.1:6080 )"
ui_print "🔰 AdGuardHome ( 账号: root | 密码: root )"
ui_print "🔰 AdGuardHome ( WebUI: 127.0.0.1:3000 )"
ui_print "✈️ Mihomo ( WebUI: 127.0.0.1:9090/ui/ )"

ui_print "🎉 安装完成"
