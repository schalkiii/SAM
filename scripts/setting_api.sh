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
#   setting_api.sh cron get | cron set <行>...

# 加载基础脚本；屏蔽加载过程中的日志输出，避免污染 get 的结果
source "/data/adb/modules/SAM/scripts/base.sh" > /dev/null 2>&1

CONF_FILE="${MODULE_PATH}/setting.conf"
CHANGED_FILE="${TMP_PATH}/.setting_changed"

# 进程内互斥，避免 WebUI 与命令行同时写导致互相覆盖
acquire_lock(){
    sam_lock_acquire "setting" 30
}

release_lock(){
    sam_lock_release "setting"
}

# 只写日志文件，不污染 WebUI 的返回值
file_log(){
    log_file "${1}"
}

# 开关一次飞行模式，让系统与 App 立即重新发起 DNS 查询
# airplane_set / refresh_network 已统一放在 base.sh，此处直接复用

# 判断本次变更是否需要刷新网络
need_refresh(){
    [ "${NETWORK_REFRESH}" = "true" ] || return 1
    [ -f "${CHANGED_FILE}" ] || return 1
    grep -qE "^(BYPASS_ENABLE|MODULE_DNS_MODE|AGH_DNS_PORT|MIHOMO_DNS_PORT)$" "${CHANGED_FILE}"
}

# 判断本次变更是否只改了直通模式
# 直通只影响 DNS 劫持与 Mihomo，不需要重启 AGH/SmartDNS(重启会清掉缓存与统计)
is_bypass_only_change(){
    [ -s "${CHANGED_FILE}" ] || return 1
    grep -q "^BYPASS_ENABLE$" "${CHANGED_FILE}" || return 1
    [ -z "$(grep -v "^BYPASS_ENABLE$" "${CHANGED_FILE}" 2>/dev/null)" ]
}

# 只改 DNS 劫持规则的直通切换，不重启 AGH / SmartDNS
apply_bypass_only(){
    if [ "${BYPASS_ENABLE}" = "true" ]; then
        if ! sh "${IPTABLES_PATH}/dns.sh" disable > /dev/null 2>&1; then
            echo "关闭 DNS 劫持失败，请到日志页查看" >&2
            rm -f "${CHANGED_FILE}"
            return 1
        fi
        # 直通模式下 Mihomo 仍会劫持 DNS，需要停掉；AGH/SmartDNS 保持运行
        if isRun ${MIHOMO_BIN}; then
            sh "${SERVICE_PATH}/mihomo.sh" stop > /dev/null 2>&1
            sh "${IPTABLES_PATH}/mihomo.sh" del > /dev/null 2>&1
        fi
        file_log "直通模式开启：仅撤销 DNS 劫持并暂停 Mihomo，未重启 AGH/SmartDNS"
        bypass_text="直通模式已开启，Mihomo 已暂停，AGH/SmartDNS 未重启"
    else
        if ! sh "${IPTABLES_PATH}/dns.sh" enable > /dev/null 2>&1; then
            echo "重建 DNS 劫持失败，请到日志页查看" >&2
            rm -f "${CHANGED_FILE}"
            return 1
        fi
        if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && ! isRun ${MIHOMO_BIN}; then
            sh "${SERVICE_PATH}/mihomo.sh" start > /dev/null 2>&1
        fi
        file_log "直通模式关闭：仅重建 DNS 劫持并恢复 Mihomo，未重启 AGH/SmartDNS"
        bypass_text="直通模式已关闭，DNS 劫持已重建，AGH/SmartDNS 未重启"
    fi

    sh "${UPDATE_PATH}/desc.sh" > /dev/null 2>&1

    if [ "${NETWORK_REFRESH}" = "true" ]; then
        refresh_network force
        echo "${bypass_text}，已刷新网络"
    else
        echo "${bypass_text}"
    fi

    rm -f "${CHANGED_FILE}"
}

# 支持的设置项分类
BOOL_KEYS="SMARTDNS_ENABLE AGH_ENABLE BLOCK_IPV6_DNS MIHOMO_ENABLE MIHOMO_IPV6 IP_IPTABLES HOST_ENABLE CRONTAB_ENABLE BACKUP_CONF ENABLE_WHITELIST BYPASS_ENABLE NETWORK_REFRESH AD_BLOCK_ENABLE LAN_ACCESS SMARTDNS_DUALSTACK"
PORT_KEYS="AGH_DNS_PORT MIHOMO_DNS_PORT"
TTL_KEYS="SMARTDNS_TTL_MIN"
TEXT_KEYS="TUN_DEVICE EXCLUDE_NODE SMARTDNS_SPEED_CHECK"
ENUM_KEYS="MODULE_DNS_MODE WHITELIST_MODE MIHOMO_DNS_MODE SMARTDNS_RESPONSE_MODE"
ARRAY_KEYS="SUB_URL BLACKLIST_WIFI"

# 枚举项的允许值
enum_allowed(){
    case "${1}" in
        MODULE_DNS_MODE) echo "1 2" ;;
        WHITELIST_MODE) echo "1 2" ;;
        MIHOMO_DNS_MODE) echo "fake-ip redir-host" ;;
        SMARTDNS_RESPONSE_MODE) echo "first-ping fastest-ip fastest-response" ;;
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
    for key in ${BOOL_KEYS} ${PORT_KEYS} ${TTL_KEYS} ${TEXT_KEYS} ${ENUM_KEYS}; do
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

    cp -f "${SETTING_CLEAN}" "${TMP_PATH}/setting.prepare.$$" || return 1
    mv -f "${TMP_PATH}/setting.prepare.$$" "${CONF_FILE}"
}

# 事务写入：先在副本上完成全部校验和替换，最后一次性原子提交
begin_setting_transaction(){
    SETTING_TARGET="${TMP_PATH}/setting.transaction.$$"
    cp -f "${CONF_FILE}" "${SETTING_TARGET}" 2>/dev/null || return 1
}

commit_setting_transaction(){
    [ -s "${SETTING_TARGET}" ] || return 1
    mv -f "${SETTING_TARGET}" "${CONF_FILE}"
    SETTING_TARGET=""
}

abort_setting_transaction(){
    rm -f "${SETTING_TARGET}" 2>/dev/null
    SETTING_TARGET=""
}

# 替换单个键所在的行；键不存在则追加
# 内容通过临时文件传入，避免 awk -v 解释反斜杠
replace_line(){
    target_key="${1}"
    target_line="${2}"
    target_conf="${SETTING_TARGET:-${CONF_FILE}}"

    line_file="${TMP_PATH}/.setting_line.$$"
    tmp_file="${TMP_PATH}/.setting_tmp.$$"

    printf '%s\n' "${target_line}" > "${line_file}"

    awk -v k="${target_key}" '
        NR == FNR { newline = $0; next }
        index($0, k "=") == 1 && !done { print newline; done = 1; next }
        { print }
        END { if (!done) print newline }
    ' "${line_file}" "${target_conf}" > "${tmp_file}"

    rm -f "${line_file}"

    # 写后自检: 语法不通过就丢弃本次修改，保持原文件不变
    if [ ! -s "${tmp_file}" ] || ! sh -n "${tmp_file}" 2>/dev/null; then
        rm -f "${tmp_file}"
        echo "写入失败: ${target_key} 会导致配置文件语法错误" >&2
        return 1
    fi

    mv -f "${tmp_file}" "${target_conf}"
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

    elif in_keys "${item_key}" ${PORT_KEYS}; then
        case "${item_value}" in
            ''|*[!0-9]*) echo "取值非法: ${item_key} 只能是数字" >&2; return 1 ;;
        esac
        if ! awk -v p="${item_value}" 'BEGIN { exit !(p >= 1 && p <= 65535) }'; then
            echo "取值非法: ${item_key} 必须在 1-65535 之间" >&2
            return 1
        fi
        # 同一批次必须基于最终候选值校验，不能只和进程内旧值比较
        pending_agh_port="${AGH_DNS_PORT}"
        pending_mihomo_port="${MIHOMO_DNS_PORT}"
        [ "${item_key}" = "AGH_DNS_PORT" ] && pending_agh_port="${item_value}"
        [ "${item_key}" = "MIHOMO_DNS_PORT" ] && pending_mihomo_port="${item_value}"
        if [ "${pending_agh_port}" = "3721" ] || [ "${pending_mihomo_port}" = "3721" ] || \
           [ "${pending_agh_port}" = "${pending_mihomo_port}" ]; then
            echo "取值非法: DNS 端口不能为 3721 或互相冲突" >&2
            return 1
        fi
        if [ "${item_key}" = "AGH_DNS_PORT" ]; then
            AGH_DNS_PORT="${item_value}"
        else
            MIHOMO_DNS_PORT="${item_value}"
        fi
        replace_line "${item_key}" "${item_key}=${item_value}" || return 1

    elif in_keys "${item_key}" ${TTL_KEYS}; then
        case "${item_value}" in
            ''|*[!0-9]*) echo "取值非法: ${item_key} 只能是数字" >&2; return 1 ;;
        esac
        # 下限 60: TTL 压到 30 秒这种值时客户端很快就会再来查，
        # 冷查询与测速被反复触发，表现为"网络变慢 + 上游流量暴涨"
        if ! awk -v p="${item_value}" 'BEGIN { exit !(p >= 60 && p <= 86400) }'; then
            echo "取值非法: ${item_key} 必须在 60-86400 之间" >&2
            return 1
        fi
        replace_line "${item_key}" "${item_key}=${item_value}" || return 1

    elif in_keys "${item_key}" ${ENUM_KEYS}; then
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
        if [ "${item_key}" = "TUN_DEVICE" ]; then
            case "${item_value}" in
                ''|*[!A-Za-z0-9_]*)
                    echo "取值非法: TUN_DEVICE 只能包含字母、数字和下划线" >&2
                    return 1
                    ;;
            esac
        fi
        if [ "${item_key}" = "EXCLUDE_NODE" ]; then
            case "${item_value}" in
                *\"*|*\\*)
                    echo "取值非法: EXCLUDE_NODE 不能包含双引号或反斜杠" >&2
                    return 1
                    ;;
            esac
        fi
        if [ "${item_key}" = "SMARTDNS_SPEED_CHECK" ]; then
            if ! setting_speed_check_valid "${item_value}"; then
                echo "取值非法: SMARTDNS_SPEED_CHECK 只允许 none 或 ping/tcp:端口 组合" >&2
                return 1
            fi
        fi
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
        # 订阅地址最终会进入 Mihomo 的 YAML 双引号字符串，必须提前拒绝会破坏 YAML 的字符
        if [ "${item_key}" = "SUB_URL" ]; then
            case "${array_item}" in
                *\"*|*\\*)
                    echo "取值非法: 订阅地址不能包含双引号或反斜杠" >&2
                    return 1
                    ;;
            esac
        fi
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
            rm -f "${CHANGED_FILE}"
            echo "配置已保存；服务当前处于停止状态，未自动启动"
            return 0
            ;;
    esac

    # 本次没有任何实际变更时不要重启服务，避免每次保存都中断一次 DNS
    if [ ! -s "${CHANGED_FILE}" ]; then
        echo "配置未变化，无需重启服务"
        return 0
    fi

    # 必须在 restart 之前判断: 重启过程中会清理 tmp 目录
    refresh_needed=0
    need_refresh && refresh_needed=1

    # 只切换直通时不要重启整套服务：AGH/SmartDNS 的缓存与统计会被清空，
    # 而直通本身只影响 DNS 劫持规则和 Mihomo。
    if is_bypass_only_change; then
        apply_bypass_only
        return $?
    fi

    # 服务重启的详细过程全部由 log 函数写进 module.log，
    # 这里只把结论返回给 WebUI —— 否则 toast 会变成几十行服务日志，没法读。
    restart_out="${TMP_PATH}/apply_restart.$$"
    sh "${SCRIPTS_PATH}/service.sh" restart > "${restart_out}" 2>&1
    restart_rc=$?
    # 只有真实退出码和最终服务数量才可信；日志文本可能不含 ERROR 字样
    expected_services=0
    [ "${SMARTDNS_ENABLE}" = "true" ] && expected_services=$((expected_services + 1))
    [ "${AGH_ENABLE}" = "true" ] && expected_services=$((expected_services + 1))
    if [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && [ "${BYPASS_ENABLE}" != "true" ]; then
        expected_services=$((expected_services + 1))
    fi
    running_services=0
    isRun ${SMARTDNS_BIN} && running_services=$((running_services + 1))
    isRun ${AGH_BIN} && running_services=$((running_services + 1))
    isRun ${MIHOMO_BIN} && running_services=$((running_services + 1))
    if [ ${restart_rc} -ne 0 ] || [ ${running_services} -lt ${expected_services} ]; then
        echo "配置已保存，但服务重启未完全成功(${running_services}/${expected_services})，请到日志页查看" >&2
        rm -f "${restart_out}" "${CHANGED_FILE}"
        return 1
    fi
    rm -f "${restart_out}"

    if [ ${refresh_needed} -eq 1 ]; then
        file_log "配置变更涉及 DNS 链路，刷新一次网络"
        refresh_network force
        echo "配置已应用，已刷新网络"
    else
        echo "配置已应用"
    fi

    # 变更记录用完即清，避免之后单独 apply 又触发一次刷新
    rm -f "${CHANGED_FILE}"
}

# 定时任务(crontabs)读写
# 文件由 busybox crond 直接读取，WebUI 通过这里安全地读写它。
# 一行一条: 每行作为独立参数传入(run.sh 不允许参数里带换行)，保存时逐行校验。
CRON_FILE="${MODULE_PATH}/etc/crontabs/root"

# 校验一行 crontab: 注释/空行放过；其余必须是 5 个时间字段 + 命令，
# 或 @reboot/@daily 这类快捷键 + 命令。时间字段字符限定数字/星号/逗号/斜杠/连字符，
# 防止把 shell 命令伪装成时间字段写进 crond。
# 用 awk 而不是 for ${1}: 未加引号的展开会做通配符展开，
# 时间字段里的 * 会变成当前目录的文件名，校验永远失败
cron_line_valid(){
    case "${1}" in
        ''|'#'*) return 0 ;;
    esac
    printf '%s\n' "${1}" | awk '
        {
            if ($1 ~ /^@/) exit ($2 == "" ? 1 : 0)
            if (NF < 6) exit 1
            for (i = 1; i <= 5; i++) {
                if ($i !~ /^[0-9*,\/-]+$/) exit 1
            }
            exit 0
        }
    '
}

cron_get(){
    if [ -f "${CRON_FILE}" ]; then
        cat "${CRON_FILE}"
    else
        echo "(暂无定时任务)"
    fi
}

cron_set(){
    cron_tmp="${TMP_PATH}/crontabs.write.$$"
    : > "${cron_tmp}" 2>/dev/null || { echo "无法创建临时文件" >&2; return 1; }
    for cron_line in "$@"; do
        if ! cron_line_valid "${cron_line}"; then
            rm -f "${cron_tmp}"
            echo "定时任务格式非法(需要 5 个时间字段 + 命令): ${cron_line}" >&2
            return 1
        fi
        printf '%s\n' "${cron_line}" >> "${cron_tmp}"
    done
    mkdir -p "$(dirname "${CRON_FILE}")" 2>/dev/null
    mv -f "${cron_tmp}" "${CRON_FILE}" || { rm -f "${cron_tmp}"; echo "写入定时任务失败" >&2; return 1; }
    echo "已保存 $(grep -cvE '^[[:space:]]*(#|$)' "${CRON_FILE}" 2>/dev/null) 条定时任务"
}

case "${1}" in
    get)
        get_all
        ;;
    set)
        shift
        acquire_lock || { echo "获取配置锁失败" >&2; exit 1; }
        : > "${CHANGED_FILE}"
        prepare_conf || { release_lock; exit 1; }
        begin_setting_transaction || { release_lock; exit 1; }
        failed=0
        for pair in "$@"; do
            [ -z "${pair}" ] && continue
            pair_key="${pair%%=*}"
            pair_value="${pair#*=}"
            # 值没变就不重写文件，也不计入待应用列表
            if in_keys "${pair_key}" ${BOOL_KEYS} ${PORT_KEYS} ${TTL_KEYS} ${TEXT_KEYS} ${ENUM_KEYS}; then
                eval "old_value=\${${pair_key}}"
                [ "${old_value}" = "${pair_value}" ] && continue
            fi
            if set_scalar "${pair_key}" "${pair_value}"; then
                echo "${pair_key}" >> "${CHANGED_FILE}"
            else
                failed=1
            fi
        done
        if [ ${failed} -ne 0 ]; then
            abort_setting_transaction
            rm -f "${CHANGED_FILE}"
            release_lock
            exit 1
        fi
        commit_setting_transaction || { abort_setting_transaction; release_lock; exit 1; }
        release_lock
        echo "已保存"
        ;;
    setarr)
        array_key="${2}"
        [ -z "${array_key}" ] && { echo "用法: setting_api.sh setarr KEY [值...]" >&2; exit 1; }
        in_keys "${array_key}" ${ARRAY_KEYS} || {
            echo "不支持的数组项: ${array_key}" >&2
            exit 1
        }
        shift 2
        acquire_lock || { echo "获取配置锁失败" >&2; exit 1; }
        prepare_conf || { release_lock; exit 1; }

        # 与当前值一致时跳过写入，避免无谓的配置重写与 mtime 抖动
        eval "array_count=\${#${array_key}[@]}"
        array_same=1
        [ "${array_count}" -eq "$#" ] || array_same=0
        if [ ${array_same} -eq 1 ]; then
            array_index=0
            for array_item in "$@"; do
                eval "array_old=\${${array_key}[${array_index}]}"
                [ "${array_old}" = "${array_item}" ] || array_same=0
                array_index=$((array_index + 1))
            done
        fi
        if [ ${array_same} -eq 1 ]; then
            release_lock
            echo "已保存"
            exit 0
        fi

        begin_setting_transaction || { release_lock; exit 1; }
        if set_array "${array_key}" "$@"; then
            commit_setting_transaction || { abort_setting_transaction; release_lock; exit 1; }
            echo "${array_key}" >> "${CHANGED_FILE}"
            release_lock
            echo "已保存"
        else
            abort_setting_transaction
            release_lock
            exit 1
        fi
        ;;
    apply)
        acquire_lock || { echo "获取配置锁失败" >&2; exit 1; }
        apply_settings
        apply_rc=$?
        release_lock
        exit ${apply_rc}
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
    cron)
        case "${2}" in
            get)
                cron_get
                ;;
            set)
                # 不带任何行 = 清空全部定时任务(WebUI 清空文本框就是这个场景)；
                # crontabs/root 每天自动备份，误清也能找回
                # 与 set/setarr/apply 一致走配置锁: WebUI 所有写入口同一互斥语义，
                # 避免定时任务保存与其他配置写操作交叉时互相覆盖
                shift 2
                acquire_lock || { echo "获取配置锁失败" >&2; exit 1; }
                cron_set "$@"
                cron_rc=$?
                release_lock
                exit ${cron_rc}
                ;;
            *)
                echo "用法: setting_api.sh cron get | set <行>..." >&2
                exit 1
                ;;
        esac
        ;;
    *)
        echo "用法: setting_api.sh get | set KEY=VALUE... | setarr KEY 值... | apply | logview [行数] | clearlog | cron get | cron set <行>..." >&2
        exit 1
        ;;
esac
