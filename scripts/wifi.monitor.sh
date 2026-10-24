#!/system/bin/sh
# 加载基础脚本(含路径配置与安全加载的 settings)
source "/data/adb/modules/SAM/scripts/base.sh"

# 防止重复启动：PID 锁避免并发启动时两个实例互相误判退出
sam_lock_acquire "wifi_monitor_instance" 2 || exit 0
trap 'sam_lock_release "wifi_monitor_instance"' EXIT HUP INT TERM

# 获取当前连接 WIFI 的 SSID
# cmd wifi status 的输出比 dumpsys connectivity 小一个数量级，优先使用
# 返回:
#   0 = 查询成功
#   1 = 查询失败（调用方必须保持现状，不能把空 SSID 当成非黑名单）
get_WIFI_SSID(){
    wifi_ssid=""
    wifi_query_ok=0
    if has_cmd cmd; then
        wifi_status=$(cmd wifi status 2>/dev/null)
        if [ -n "${wifi_status}" ]; then
            wifi_ssid=$(printf '%s\n' "${wifi_status}" | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
            wifi_query_ok=1
        fi
    fi
    if [ ${wifi_query_ok} -eq 0 ] && has_cmd dumpsys; then
        wifi_status=$(dumpsys connectivity 2>/dev/null)
        if [ -n "${wifi_status}" ]; then
            wifi_ssid=$(printf '%s\n' "${wifi_status}" | grep "WIFI CONNECTED" | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
            wifi_query_ok=1
        fi
    fi
    echo "${wifi_ssid}"
    [ ${wifi_query_ok} -eq 1 ]
}

# 统计正在运行的服务数量
count_running_service(){
    running_number=0
    for running_bin in ${MIHOMO_BIN} ${SMARTDNS_BIN} ${AGH_BIN}; do
        isRun ${running_bin} && running_number=$((running_number + 1))
    done
    echo ${running_number}
}

# 是否有任何服务期望运行；全禁用时不能反复执行 service.sh start
any_service_enabled(){
    [ "${SMARTDNS_ENABLE}" = "true" ] && return 0
    [ "${AGH_ENABLE}" = "true" ] && return 0
    [ "${MIHOMO_ENABLE}" = "true" ] && [ "${#SUB_URL[@]}" -gt 0 ] && return 0
    return 1
}

setting_file="/data/adb/modules/SAM/setting.conf"
setting_stamp=""
setting_sum=""

# 无限循环
while true
do
    # 设置没变就不重复解析，避免每 10 秒生成一批临时文件
    # mtime 秒级精度不够时用 cksum 兜底，避免同秒最终写入永久漏读
    if has_cmd stat; then
        new_stamp=$(stat -c "%Y" "${setting_file}" 2>/dev/null)
    else
        new_stamp=""
    fi
    new_sum=$(cksum "${setting_file}" 2>/dev/null)
    if [ -z "${new_stamp}" ] || [ "${new_stamp}" != "${setting_stamp}" ] || [ "${new_sum}" != "${setting_sum}" ]; then
        load_setting "${setting_file}"
        setting_stamp="${new_stamp}"
        setting_sum="${new_sum}"
    fi

    # 用户在界面上手动停止服务后，监控只负责"保持在黑名单里停止"，
    # 不再自动拉起；否则手动停止会被监控反复推翻。
    # 注意: 因黑名单触发的停止会写成 stopped-by-wifi，不算手动停止。
    manual_stopped=0
    [ "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" = "stopped" ] && manual_stopped=1

    # 判断黑名单为空，和服务未启动，则启动服务并且退出监控
    if [ ${#BLACKLIST_WIFI[@]} -eq 0 ]; then
        [ ${manual_stopped} -eq 0 ] && any_service_enabled && [ $(count_running_service) -le 0 ] && $SCRIPTS_PATH/service.sh start
        exit 0
    fi

    # 手动停止时不会再自动拉起，没必要每 10 秒读一次 WiFi 状态
    if [ ${manual_stopped} -eq 1 ]; then
        sleep 10
        continue
    fi

    # 每轮只取一次 SSID；查询失败时保持现状，不能把空 SSID 当成非黑名单
    current_ssid=$(get_WIFI_SSID)
    wifi_query_rc=$?
    if [ ${wifi_query_rc} -ne 0 ]; then
        log "e" "WiFi 状态查询失败，保持当前服务状态"
        sleep 10
        continue
    fi

    # 状态值
    state=1
    # 索引
    i=0
    # 循环遍历黑名单 WIFI
    while(($i < ${#BLACKLIST_WIFI[@]}))
    do
        # 判断当前所连接WIFI是否在黑名单
        if [ "${current_ssid}" = "${BLACKLIST_WIFI[$i]}" ]; then
            state=0
            break
        fi
        let "i++"
    done

    if [ $state -eq 1 ]; then
        # 不在黑名单且服务未启动，则启动；没有任何服务启用时不执行
        any_service_enabled && [ $(count_running_service) -le 0 ] && $SCRIPTS_PATH/service.sh start
    else
        # 在黑名单且服务正在运行，则停止，并标记停止原因是 WiFi 黑名单
        [ $(count_running_service) -gt 0 ] && $SCRIPTS_PATH/service.sh stop stopped-by-wifi
    fi

    # 等待10秒
    sleep 10
done
