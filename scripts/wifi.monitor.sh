#!/system/bin/sh
# 防止重复启动
if [ $(pgrep -f "$0" | wc -l) -gt 1 ]; then
    exit 0
fi

# 加载基础脚本(含路径配置与安全加载的 settings)
source "/data/adb/modules/SAM/scripts/base.sh"

# 获取当前连接 WIFI 的 SSID
# cmd wifi status 的输出比 dumpsys connectivity 小一个数量级，优先使用
get_WIFI_SSID(){
    wifi_ssid=""
    if has_cmd cmd; then
        wifi_ssid=$(cmd wifi status 2>/dev/null | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
    fi
    if [ -z "${wifi_ssid}" ]; then
        wifi_ssid=$(dumpsys connectivity 2>/dev/null | grep "WIFI CONNECTED" | sed -n 's/.*SSID: "\(.*\)".*/\1/p' | head -n 1)
    fi
    echo "${wifi_ssid}"
}

# 统计正在运行的服务数量
count_running_service(){
    running_number=0
    for running_bin in ${MIHOMO_BIN} ${SMARTDNS_BIN} ${AGH_BIN}; do
        isRun ${running_bin} && running_number=$((running_number + 1))
    done
    echo ${running_number}
}

setting_file="/data/adb/modules/SAM/setting.conf"
setting_stamp=""

# 无限循环
while true
do
    # 设置没变就不重复解析，避免每 10 秒生成一批临时文件
    if has_cmd stat; then
        new_stamp=$(stat -c "%Y" "${setting_file}" 2>/dev/null)
    else
        new_stamp=""
    fi
    if [ -z "${new_stamp}" ] || [ "${new_stamp}" != "${setting_stamp}" ]; then
        load_setting "${setting_file}"
        setting_stamp="${new_stamp}"
    fi

    # 用户在界面上手动停止服务后，监控只负责"保持在黑名单里停止"，
    # 不再自动拉起；否则手动停止会被监控反复推翻。
    # 注意: 因黑名单触发的停止会写成 stopped-by-wifi，不算手动停止。
    manual_stopped=0
    [ "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" = "stopped" ] && manual_stopped=1

    # 判断黑名单为空，和服务未启动，则启动服务并且退出监控
    if [ ${#BLACKLIST_WIFI[@]} -eq 0 ]; then
        [ ${manual_stopped} -eq 0 ] && [ $(count_running_service) -le 0 ] && $SCRIPTS_PATH/service.sh start
        exit 0
    fi

    # 手动停止时不会再自动拉起，没必要每 10 秒读一次 WiFi 状态
    if [ ${manual_stopped} -eq 1 ]; then
        sleep 10
        continue
    fi

    # 每轮只取一次 SSID；原来在遍历黑名单时逐项调用 dumpsys，N 个 SSID 就是 N 次
    current_ssid=$(get_WIFI_SSID)

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
        # 不在黑名单且服务未启动，则启动
        [ $(count_running_service) -le 0 ] && $SCRIPTS_PATH/service.sh start
    else
        # 在黑名单且服务正在运行，则停止，并标记停止原因是 WiFi 黑名单
        [ $(count_running_service) -gt 0 ] && $SCRIPTS_PATH/service.sh stop stopped-by-wifi
    fi

    # 等待10秒
    sleep 10
done
