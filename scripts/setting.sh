#!/system/bin/sh
# 设置安全加载
# 背景: setting.conf 是被 source 的 shell 片段，一旦被编辑器改出 BOM、CRLF 换行
#       或括号/引号不配对，Android 的 mksh 会在 source 时直接终止整个脚本，
#       表现为"改完设置后服务再也起不来"。
# 处理: 清洗 -> 语法预检 -> 坏行逐行抢救 -> 缺失/非法项回退默认值，保证脚本永远能继续跑。

# 默认设置(与 setting.conf 保持一致)
setting_default(){
    SMARTDNS_ENABLE=true
    AGH_ENABLE=true
    AGH_DNS_PORT=5300
    BLOCK_IPV6_DNS=true
    MIHOMO_ENABLE=true
    MIHOMO_IPV6=true
    MIHOMO_DNS_PORT=1053
    MIHOMO_DNS_MODE=fake-ip
    TUN_DEVICE=Meta
    IP_IPTABLES=false
    HOST_ENABLE=true
    CRONTAB_ENABLE=false
    MODULE_DNS_MODE=2
    BYPASS_ENABLE=false
    LAN_ACCESS=false
    SMARTDNS_RESPONSE_MODE=first-ping
    SMARTDNS_SPEED_CHECK=ping,tcp:80,tcp:443
    SMARTDNS_DUALSTACK=true
    SMARTDNS_TTL_MIN=600
    NETWORK_REFRESH=true
    AD_BLOCK_ENABLE=true
    BACKUP_CONF=true
    EXCLUDE_NODE=""
    SUB_URL=()
    ENABLE_WHITELIST=false
    WHITELIST_MODE=1
    BLACKLIST_WIFI=()
}

# 清洗设置文件
# 1. 去掉文件开头的 UTF-8 BOM(EF BB BF)
# 2. 去掉 Windows 换行符 CRLF 中的 CR
setting_sanitize(){
    SETTING_CLEAN="${TMP_PATH}/setting.clean.$$"
    mkdir -p "${TMP_PATH}" 2>/dev/null

    # 仅在文件头确实是 BOM 时才裁掉 3 个字节，避免误伤正文里的多字节字符
    if [ "$(head -c 3 "${1}" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')" = "efbbbf" ]; then
        tail -c +4 "${1}" > "${SETTING_CLEAN}"
    else
        cp -f "${1}" "${SETTING_CLEAN}"
    fi

    # 去除行尾 CR
    # 原用 sed -i 's/\n$//'，但 \n 作为 sed 替换文本里的换行符只有 GNU sed 保证支持，
    # busybox / toybox sed 的行为依版本而异 —— 一旦不生效，CRLF 残留会让
    # 下面的 sh -n 预检直接失败，把好配置误判成坏配置。
    # tr -d 八进制 CR 去掉所有回车，语义明确且各实现一致，还少一次进程(不需要 sed -i 的临时文件)。
    # 注意: 必须用八进制写法，不要用反斜杠 r —— 那种转义经编辑器/脚本多层传递容易被破坏。
    # 曾经被破坏成 tr -d 换行符，把整个配置文件的换行全删掉，导致设置全部读成默认值。
    tr -d '\015' < "${SETTING_CLEAN}" > "${SETTING_CLEAN}.lf" 2>/dev/null && \
        mv -f "${SETTING_CLEAN}.lf" "${SETTING_CLEAN}"
}

# 逐行抢救
# 整体语法不合法时，只加载能够独立成立的赋值行，跳过坏行
setting_salvage(){
    SETTING_SALVAGE="${TMP_PATH}/setting.salvage.$$"
    grep -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=' "${1}" > "${SETTING_SALVAGE}" 2>/dev/null

    while IFS= read -r setting_line; do
        case "${setting_line}" in
            ''|'#'*) continue ;;
        esac
        if echo "${setting_line}" | sh -n 2>/dev/null; then
            eval "${setting_line}" 2>/dev/null
        else
            log "e" "已跳过非法设置项: ${setting_line}"
        fi
    done < "${SETTING_SALVAGE}"

    rm -f "${SETTING_SALVAGE}"
}

# 布尔项纠错
setting_fix_bool(){
    eval "check_value=\${${1}}"
    if [ "${check_value}" != "true" ] && [ "${check_value}" != "false" ]; then
        log "e" "设置项 ${1} 取值非法(${check_value})，已回退为 ${2}"
        eval "${1}=${2}"
    fi
}

# 数字项纠错
setting_fix_number(){
    eval "check_value=\${${1}}"
    case "${check_value}" in
        ''|*[!0-9]*)
            log "e" "设置项 ${1} 取值非法(${check_value})，已回退为 ${2}"
            eval "${1}=${2}"
            ;;
        *)
            if [ "${#check_value}" -gt 5 ]; then
                log "e" "设置项 ${1} 取值越界(${check_value})，已回退为 ${2}"
                eval "${1}=${2}"
            else
                # 去掉前导 0，避免 test/算术把它当八进制(NT 下 08 会直接报错)
                while [ "${#check_value}" -gt 1 ] && [ "${check_value#0}" != "${check_value}" ]; do
                    check_value="${check_value#0}"
                done
                eval "${1}=${check_value}"
            fi
            ;;
    esac
}

# 端口项纠错: 数字、1-65535
setting_fix_port(){
    setting_fix_number "${1}" "${2}"
    eval "check_value=\${${1}}"
    if [ "${check_value}" -lt 1 ] || [ "${check_value}" -gt 65535 ]; then
        log "e" "设置项 ${1} 取值越界(${check_value})，已回退为 ${2}"
        eval "${1}=${2}"
    fi
}

# 枚举项纠错
setting_fix_enum(){
    setting_name="${1}"
    setting_default_value="${2}"
    shift 2

    eval "check_value=\${${setting_name}}"
    check_valid=0
    for check_allow in "$@"; do
        [ "${check_value}" = "${check_allow}" ] && check_valid=1
    done

    if [ ${check_valid} -eq 0 ]; then
        log "e" "设置项 ${setting_name} 取值非法(${check_value})，已回退为 ${setting_default_value}"
        eval "${setting_name}=${setting_default_value}"
    fi
}

# 数组项归一化
# 允许用户把 SUB_URL 写成字符串形式，这里统一转成数组，避免后续按数组取值时越界
# 注意: 必须加引号展开，否则 "公司 WIFI" 这种带空格的元素会被按空格拆成两个
setting_normalize(){
    sub_url_tmp=("${SUB_URL[@]}")
    SUB_URL=("${sub_url_tmp[@]}")

    blacklist_wifi_tmp=("${BLACKLIST_WIFI[@]}")
    BLACKLIST_WIFI=("${blacklist_wifi_tmp[@]}")

    # 去掉空元素
    sub_url_clean=()
    for sub_url_item in "${SUB_URL[@]}"; do
        [ -n "${sub_url_item}" ] && sub_url_clean+=("${sub_url_item}")
    done
    SUB_URL=("${sub_url_clean[@]}")

    blacklist_wifi_clean=()
    for blacklist_wifi_item in "${BLACKLIST_WIFI[@]}"; do
        [ -n "${blacklist_wifi_item}" ] && blacklist_wifi_clean+=("${blacklist_wifi_item}")
    done
    BLACKLIST_WIFI=("${blacklist_wifi_clean[@]}")
}

# 测速方式校验: none 单独使用；ping/tcp:端口 可组合
setting_speed_check_valid(){
    case "${1}" in
        ''|*[!a-z0-9:,]*) return 1 ;;
    esac
    # none 不能和其他项混用
    case ",${1}," in
        *,none,*)
            [ "${1}" = "none" ] || return 1
            ;;
    esac

    saved_ifs="${IFS}"
    IFS=','
    check_result=0
    for speed_item in ${1}; do
        case "${speed_item}" in
            none|ping) ;;
            tcp:*)
                speed_tcp_port="${speed_item#tcp:}"
                case "${speed_tcp_port}" in
                    ''|*[!0-9]*) check_result=1 ;;
                    *)
                        if [ "${speed_tcp_port}" -lt 1 ] || [ "${speed_tcp_port}" -gt 65535 ]; then
                            check_result=1
                        fi
                        ;;
                esac
                ;;
            *) check_result=1 ;;
        esac
    done
    IFS="${saved_ifs}"
    return ${check_result}
}

# 取值校验
setting_validate(){
    setting_fix_bool SMARTDNS_ENABLE true
    setting_fix_bool AGH_ENABLE true
    setting_fix_bool BLOCK_IPV6_DNS true
    setting_fix_bool MIHOMO_ENABLE true
    setting_fix_bool MIHOMO_IPV6 true
    setting_fix_bool IP_IPTABLES false
    setting_fix_bool HOST_ENABLE true
    setting_fix_bool CRONTAB_ENABLE false
    setting_fix_bool BACKUP_CONF true
    setting_fix_bool ENABLE_WHITELIST false
    setting_fix_bool BYPASS_ENABLE false
    setting_fix_bool LAN_ACCESS false
    setting_fix_bool SMARTDNS_DUALSTACK true
    setting_fix_bool NETWORK_REFRESH true
    setting_fix_bool AD_BLOCK_ENABLE true

    setting_fix_port AGH_DNS_PORT 5300
    setting_fix_port MIHOMO_DNS_PORT 1053
    setting_fix_number SMARTDNS_TTL_MIN 600

    # SmartDNS 固定监听 3721，三个 DNS 端口不能互相冲突
    if [ "${AGH_DNS_PORT}" = "3721" ]; then
        log "e" "设置项 AGH_DNS_PORT 与 SmartDNS 端口冲突，已回退为 5300"
        AGH_DNS_PORT=5300
    fi
    if [ "${MIHOMO_DNS_PORT}" = "3721" ]; then
        log "e" "设置项 MIHOMO_DNS_PORT 与 SmartDNS 端口冲突，已回退为 1053"
        MIHOMO_DNS_PORT=1053
    fi
    if [ "${AGH_DNS_PORT}" = "${MIHOMO_DNS_PORT}" ]; then
        log "e" "设置项 AGH_DNS_PORT 与 MIHOMO_DNS_PORT 冲突，MIHOMO_DNS_PORT 已回退为 1053"
        MIHOMO_DNS_PORT=1053
        # 极端情况: AGH 本身设成了 1053，再把 AGH 退回默认
        if [ "${AGH_DNS_PORT}" = "${MIHOMO_DNS_PORT}" ]; then
            AGH_DNS_PORT=5300
        fi
    fi

    if [ "${SMARTDNS_TTL_MIN}" -gt 86400 ]; then
        log "e" "设置项 SMARTDNS_TTL_MIN 取值越界，已回退为 600"
        SMARTDNS_TTL_MIN=600
    fi

    setting_fix_enum MODULE_DNS_MODE 2 1 2
    setting_fix_enum WHITELIST_MODE 1 1 2
    setting_fix_enum MIHOMO_DNS_MODE fake-ip fake-ip redir-host
    setting_fix_enum SMARTDNS_RESPONSE_MODE first-ping first-ping fastest-ip fastest-response

    # 测速方式只允许 none / ping / tcp:端口 的组合
    if ! setting_speed_check_valid "${SMARTDNS_SPEED_CHECK}"; then
        log "e" "设置项 SMARTDNS_SPEED_CHECK 取值非法(${SMARTDNS_SPEED_CHECK})，已回退为默认"
        SMARTDNS_SPEED_CHECK="ping,tcp:80,tcp:443"
    fi

    case "${TUN_DEVICE}" in
        ''|*[!A-Za-z0-9_]*)
            log "e" "设置项 TUN_DEVICE 非法(${TUN_DEVICE})，已回退为 Meta"
            TUN_DEVICE="Meta"
            ;;
    esac
}

# 加载设置
load_setting(){
    setting_file="${1:-${MODULE_PATH}/setting.conf}"

    # 先建立默认值，后续任何一步失败都不会留下未定义变量
    setting_default

    if [ ! -f "${setting_file}" ]; then
        log "e" "未找到设置文件 ${setting_file}，使用默认设置"
        setting_normalize
        return 1
    fi

    setting_sanitize "${setting_file}"

    # 临时目录可能被并发清理，清洗文件不存在时重试一次再兜底
    if [ ! -f "${SETTING_CLEAN}" ]; then
        setting_sanitize "${setting_file}"
    fi
    if [ ! -f "${SETTING_CLEAN}" ]; then
        log "e" "配置清洗失败，使用默认设置"
        setting_normalize
        return 1
    fi

    if sh -n "${SETTING_CLEAN}" 2>"${TMP_PATH}/setting.error.$$"; then
        . "${SETTING_CLEAN}"
    else
        log "e" "设置文件语法错误: $(head -n 1 "${TMP_PATH}/setting.error.$$" 2>/dev/null)"
        log "e" "已跳过错误项，保留其余可用设置"
        setting_salvage "${SETTING_CLEAN}"
    fi

    setting_normalize
    setting_validate

    rm -f "${SETTING_CLEAN}" "${TMP_PATH}/setting.error.$$"
    return 0
}
