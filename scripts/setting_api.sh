#!/system/bin/sh
# 配置读写接口 - 供 WebUI 调用
#
# 设计目标:
#   1. 读: 输出 KEY=VALUE；数组输出 KEY[count]=N 与 KEY[i]=v
#   2. 写: 只替换目标行，保留全部注释、顺序与空行
#   3. 校验: 布尔 / 数字 / 枚举逐项校验，非法值直接拒绝，不写坏文件
#   4. 安全: 写前清洗 BOM/CRLF，写后先 sh -n 自检再原子替换
#
# 用法:
#   setting_api.sh get
#   setting_api.sh set KEY=VALUE [KEY=VALUE ...]
#   setting_api.sh setarr SUB_URL "url1" "url2"
#   setting_api.sh apply

# 加载基础脚本；屏蔽加载过程中的日志输出，避免污染 get 的结果
source "/data/adb/modules/SAM/scripts/base.sh" > /dev/null 2>&1

CONF_FILE="${MODULE_PATH}/setting.conf"
LOCK_DIR="${TMP_PATH}/.setting.lock"
CHANGED_FILE="${TMP_PATH}/.setting_changed"

# 进程内互斥，避免 WebUI 与命令行同时写导致互相覆盖
acquire_lock(){
    lock_try=0
    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
        lock_try=$((lock_try + 1))
        # 超过 5 秒视为残留锁，强制接管
        if [ ${lock_try} -gt 50 ]; then
            rm -rf "${LOCK_DIR}"
            mkdir "${LOCK_DIR}" 2>/dev/null
            break
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
}

release_lock(){
    rmdir "${LOCK_DIR}" 2>/dev/null
}

# 只写日志文件，不污染 WebUI 的返回值
file_log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${1}" >> "${LOG_FILE}" 2>/dev/null
}

# 开关一次飞行模式，让系统与 App 立即重新发起 DNS 查询
refresh_network(){
    file_log "配置变更涉及 DNS 链路，刷新一次网络"
    for airplane_state in 1 0; do
        settings put global airplane_mode_on ${airplane_state} 2>/dev/null
        am broadcast -a android.intent.action.AIRPLANE_MODE > /dev/null 2>&1
        sleep 1
    done
}

# 判断本次变更是否需要刷新网络
need_refresh(){
    [ "${NETWORK_REFRESH}" = "true" ] || return 1
    [ -f "${CHANGED_FILE}" ] || return 1
    grep -qE "^(BYPASS_ENABLE|MODULE_DNS_MODE|AGH_DNS_PORT|MIHOMO_DNS_PORT)$" "${CHANGED_FILE}"
}

# 支持的设置项分类
BOOL_KEYS="SMARTDNS_ENABLE AGH_ENABLE BLOCK_IPV6_DNS MIHOMO_ENABLE MIHOMO_IPV6 IP_IPTABLES HOST_ENABLE CRONTAB_ENABLE BACKUP_CONF ENABLE_WHITELIST BYPASS_ENABLE NETWORK_REFRESH AD_BLOCK_ENABLE"
NUMBER_KEYS="AGH_DNS_PORT MIHOMO_DNS_PORT"
TEXT_KEYS="TUN_DEVICE EXCLUDE_NODE"
ARRAY_KEYS="SUB_URL BLACKLIST_WIFI"

# 枚举项的允许值
enum_allowed(){
    case "${1}" in
        MODULE_DNS_MODE) echo "1 2" ;;
        WHITELIST_MODE) echo "1 2" ;;
        MIHOMO_DNS_MODE) echo "fake-ip redir-host" ;;
        *) echo "" ;;
    esac
}

# 是否属于某个键列表
in_keys(){
    search_key="${1}"
    shift
    for list_key in "$@"; do
        [ "${search_key}" = "${list_key}" ] && return 0
    done
    return 1
}

# 转义双引号字符串里的特殊字符
escape_value(){
    printf '%s' "${1}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g'
}

# 输出全部设置
get_all(){
    for key in ${BOOL_KEYS} ${NUMBER_KEYS} ${TEXT_KEYS} MODULE_DNS_MODE WHITELIST_MODE MIHOMO_DNS_MODE; do
        eval "value=\${${key}}"
        printf '%s=%s\n' "${key}" "${value}"
    done

    for key in ${ARRAY_KEYS}; do
        eval "count=\${#${key}[@]}"
        printf '%s[count]=%s\n' "${key}" "${count}"
        index=0
        while [ ${index} -lt ${count} ]; do
            eval "value=\${${key}[${index}]}"
            printf '%s[%s]=%s\n' "${key}" "${index}" "${value}"
            index=$((index + 1))
        done
    done
}

# 把配置文件统一成 LF 且去掉 BOM
prepare_conf(){
    setting_sanitize "${CONF_FILE}"

    # 清洗结果异常时绝不覆盖原文件，避免把配置清空
    if [ ! -s "${SETTING_CLEAN}" ]; then
        echo "配置清洗失败，已放弃写入" >&2
        return 1
    fi

    cp -f "${SETTING_CLEAN}" "${CONF_FILE}"
}

# 替换单个键所在的行；键不存在则追加
# 内容通过临时文件传入，避免 awk -v 解释反斜杠
replace_line(){
    target_key="${1}"
    target_line="${2}"

    line_file="${TMP_PATH}/.setting_line.$$"
    tmp_file="${CONF_FILE}.tmp.$$"

    printf '%s\n' "${target_line}" > "${line_file}"

    awk -v k="${target_key}" '
        NR == FNR { newline = $0; next }
        index($0, k "=") == 1 && !done { print newline; done = 1; next }
        { print }
        END { if (!done) print newline }
    ' "${line_file}" "${CONF_FILE}" > "${tmp_file}"

    rm -f "${line_file}"

    # 写后自检: 语法不通过就丢弃本次修改，保持原文件不变
    if [ ! -s "${tmp_file}" ] || ! sh -n "${tmp_file}" 2>/dev/null; then
        rm -f "${tmp_file}"
        echo "写入失败: ${target_key} 会导致配置文件语法错误" >&2
        return 1
    fi

    mv -f "${tmp_file}" "${CONF_FILE}"
    return 0
}

# 写单个标量
set_scalar(){
    item_key="${1}"
    item_value="${2}"

    if in_keys "${item_key}" ${BOOL_KEYS}; then
        case "${item_value}" in
            true|false) ;;
            *) echo "取值非法: ${item_key} 只能是 true/false" >&2; return 1 ;;
        esac
        replace_line "${item_key}" "${item_key}=${item_value}" || return 1

    elif in_keys "${item_key}" ${NUMBER_KEYS}; then
        case "${item_value}" in
            ''|*[!0-9]*) echo "取值非法: ${item_key} 只能是数字" >&2; return 1 ;;
        esac
        # 端口必须落在 1-65535；用 awk 做数值比较，避免 shell 对前导 0 的歧义
        if ! awk -v p="${item_value}" 'BEGIN { exit !(p >= 1 && p <= 65535) }'; then
            echo "取值非法: ${item_key} 必须在 1-65535 之间" >&2
            return 1
        fi
        replace_line "${item_key}" "${item_key}=${item_value}" || return 1

    elif in_keys "${item_key}" MODULE_DNS_MODE WHITELIST_MODE MIHOMO_DNS_MODE; then
        allowed_values="$(enum_allowed "${item_key}")"
        allowed_ok=0
        for allowed_value in ${allowed_values}; do
            [ "${item_value}" = "${allowed_value}" ] && allowed_ok=1
        done
        if [ ${allowed_ok} -ne 1 ]; then
            echo "取值非法: ${item_key} 只允许 ${allowed_values}" >&2
            return 1
        fi
        replace_line "${item_key}" "${item_key}=${item_value}" || return 1

    elif in_keys "${item_key}" ${TEXT_KEYS}; then
        # 单行文本，统一加引号
        escaped_value="$(escape_value "${item_value}")"
        replace_line "${item_key}" "${item_key}=\"${escaped_value}\"" || return 1

    else
        echo "不支持的设置项: ${item_key}" >&2
        return 1
    fi

    return 0
}

# 写数组
set_array(){
    item_key="${1}"
    shift

    in_keys "${item_key}" ${ARRAY_KEYS} || {
        echo "不支持的数组项: ${item_key}" >&2
        return 1
    }

    array_line="${item_key}=("
    array_first=1
    for array_item in "$@"; do
        escaped_item="$(escape_value "${array_item}")"
        if [ ${array_first} -eq 1 ]; then
            array_line="${array_line}\"${escaped_item}\""
            array_first=0
        else
            array_line="${array_line} \"${escaped_item}\""
        fi
    done
    array_line="${array_line})"

    replace_line "${item_key}" "${array_line}"
}

# 应用配置
apply_settings(){
    # 服务处于「停止」状态时不要擅自拉起(含 WiFi 黑名单触发的停止)
    case "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" in
        stopped*)
            echo "配置已保存；服务当前处于停止状态，未自动启动"
            return 0
            ;;
    esac

    echo "正在应用配置..."
    sh "${SCRIPTS_PATH}/service.sh" restart

    if need_refresh; then
        refresh_network
        echo "配置已应用，已刷新网络"
    else
        echo "配置已应用"
    fi
}

case "${1}" in
    get)
        get_all
        ;;
    set)
        shift
        acquire_lock
        : > "${CHANGED_FILE}"
        prepare_conf || { release_lock; exit 1; }
        failed=0
        for pair in "$@"; do
            [ -z "${pair}" ] && continue
            pair_key="${pair%%=*}"
            pair_value="${pair#*=}"
            if set_scalar "${pair_key}" "${pair_value}"; then
                echo "${pair_key}" >> "${CHANGED_FILE}"
            else
                failed=1
            fi
        done
        release_lock
        [ ${failed} -eq 0 ] && echo "已保存" || exit 1
        ;;
    setarr)
        array_key="${2}"
        [ -z "${array_key}" ] && { echo "用法: setting_api.sh setarr KEY [值...]" >&2; exit 1; }
        shift 2
        acquire_lock
        prepare_conf || { release_lock; exit 1; }
        if set_array "${array_key}" "$@"; then
            echo "${array_key}" >> "${CHANGED_FILE}"
            release_lock
            echo "已保存"
        else
            release_lock
            exit 1
        fi
        ;;
    apply)
        apply_settings
        ;;
    logview)
        if [ -f "${LOG_FILE}" ]; then
            tail -n "${2:-120}" "${LOG_FILE}"
        else
            echo "(暂无日志)"
        fi
        ;;
    clearlog)
        : > "${LOG_FILE}"
        echo "日志已清空"
        ;;
    *)
        echo "用法: setting_api.sh get | set KEY=VALUE... | setarr KEY 值... | apply | logview [行数] | clearlog" >&2
        exit 1
        ;;
esac
