#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 获取 Host
# 用法: get_host <名称> <候选URL> [候选URL...]
# 候选源逐个尝试, 第一个取到有效内容的即采用; 全部失败才返回 1
#
# 为什么要多个源:
#   raw.githubusercontent.com 在国内移动网络下经常超时或被限速,
#   单源失败就直接整条规则落空。备用顺序:
#     1. 直连 raw(最快, 网络好时首选)
#     2. ghfast.top 代理(国内可用的 GitHub raw 加速)
#     3. cdn.jsdelivr.net(另一个 CDN, 部分场景可达)
#
# 注意 curl 加 -f: 没有它时 404/500 也会输出错误页正文,
# 长度超过阈值就会被当成"取到内容"写进 hosts 文件, 反而污染规则
get_host(){
    # 规则名称: 必须在 shift 之前取出来。
    # shift 之后 $1 变成第一个候选 URL(含斜杠), 再拿它拼 sed 表达式会报
    # "unknown command: '/'" —— 这也是原来写 ${2} 拿不到全部候选的原因
    host_name="${1}"

    # 读取 hosts
    hosts_content=$(cat ${HOSTS_FILE} | grep -Ev "^[[:space:]]*$")

    log "i" "获取最新 ${host_name} host"

    # 逐个尝试候选源
    # shift 掉名称参数, 剩下的全部是候选 URL。
    # 注意不能只写 ${2}: 那样只能拿到第一个候选, 后面的源根本不会被遍历到
    shift
    get_content=""
    get_source=""
    for i in ${*}
    do
        [ -n "${i}" ] || continue
        log "i" "尝试源: ${i}"
        source_content=$(curl -m 15 -s -f ${i} 2>/dev/null | grep -Ev "^#.*$|^[[:space:]]*$" | awk -F' ' '{print $1, $2}')
        # 有效内容: 至少有一行, 且不含 HTML 标签(代理/错误页的特征)
        if [ -z "${source_content}" ] || echo "${source_content}" | grep -qE "^<|^!DOCTYPE|^html"; then
            log "e" "源不可用或内容无效: ${i}"
            continue
        fi
        # 至少要有"IP 域名"行，避免代理返回 JSON/纯文本错误信息被写进 hosts
        if ! echo "${source_content}" | awk 'NF >= 2 && $1 ~ /^[0-9A-Fa-f:.]+$/ { ok = 1 } END { exit !ok }'; then
            log "e" "源内容不是 hosts 格式: ${i}"
            continue
        fi
        get_content="${source_content}"
        get_source="${i}"
        break
    done

    # 全部候选源都没取到
    if [ -z "${get_content}" ]; then
        log "e" "获取失败: ${host_name} (所有候选源均不可用)"
        return 1
    fi
    log "i" "获取成功: ${host_name} <- ${get_source}"
     
    # 获取开始和结束行
    start_line=$(echo "${hosts_content}" | sed -n "/^#.*start.*${host_name}/=")
    end_line=$(echo "${hosts_content}" | sed -n "/^#.*${host_name}.*end/=")
    # 判断获取到则删除
    if [ -n "${start_line}" ] && [ -n "${end_line}" ]; then
        log "i" "删除 ${host_name} 旧规则"
        hosts_content=$(echo "${hosts_content}" | sed "${start_line},${end_line}d")
    fi
    
    # 排序并查重
    get_content=$(echo -e "${get_content}" | sort | uniq | grep -Ev "^[[:space:]]*$")
    # 输出
    hosts_content+="\n# start > ${host_name}\n${get_content}\n# ${host_name} < end"
    # 先写临时文件再替换: 原实现直接 > ${HOSTS_FILE} 覆盖写，
    # 中途出错(磁盘满/被杀)就会把 hosts 写成半截文件，
    # 而 hosts 是系统启动必需文件，损坏会直接导致开机异常。
    echo -e "${hosts_content}" | sed "s/^# .*start/\n# start/g" > "${HOSTS_FILE}.tmp" 2>/dev/null || {
        log "e" "写入 hosts 临时文件失败，保留原文件"
        rm -f "${HOSTS_FILE}.tmp"
        return 1
    }
    # 临时文件必须非空且包含 hosts 标记，否则视为失败
    if [ ! -s "${HOSTS_FILE}.tmp" ] || ! grep -q "^# start" "${HOSTS_FILE}.tmp"; then
        log "e" "hosts 临时文件校验失败，保留原文件"
        rm -f "${HOSTS_FILE}.tmp"
        return 1
    fi
    mv -f "${HOSTS_FILE}.tmp" "${HOSTS_FILE}"
    # update 用 mv 换掉了 inode，系统里的 bind 挂载仍指向旧文件，必须重挂才生效
    remount_hosts || log "e" "hosts 重挂载失败，新规则将在下次启动后生效"
    log "i" "写入 hosts 文件"
}



# 添加指令
# 候选源: 同一份内容的多个取回途径
# 直连优先(快), 失败依次降级到代理与另一个 CDN
GITHUB_HOST_SOURCES="
https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts
https://ghfast.top/https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts
https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@master/hosts
"
FCM_HOST_SOURCES="
https://raw.githubusercontent.com/cagedbird043/fcm-hosts-next/main/fcm_dual.hosts
https://ghfast.top/https://raw.githubusercontent.com/cagedbird043/fcm-hosts-next/main/fcm_dual.hosts
https://cdn.jsdelivr.net/gh/Mice-Tailor-Infra/fcm-hosts-next@master/fcm_dual.hosts
"

case "$1" in
    update)
        # 服务每次启动都会调用 update；24 小时内只更新一次，避免重复下载。
        # 手动更新/定时任务用 "update force" 强制刷新。
        host_stamp="${TMP_PATH}/hosts.updated"
        if [ "$2" != "force" ] && [ -f "${host_stamp}" ] && has_cmd stat; then
            host_stamp_mtime=$(stat -c "%Y" "${host_stamp}" 2>/dev/null)
            now_time=$(date +%s)
            if [ -n "${host_stamp_mtime}" ] && [ $((now_time - host_stamp_mtime)) -lt 86400 ]; then
                log "i" "hosts 24 小时内已更新，跳过(强制更新请用 update force)"
                exit 0
            fi
        fi

        log "i" "更新 host 规则"
        update_ok=0
        # GitHub
        get_host "GitHub" ${GITHUB_HOST_SOURCES} && update_ok=1
        # FCM
        get_host "FCM" ${FCM_HOST_SOURCES} && update_ok=1
        # 至少成功一个才记录时间，失败时下次启动还会重试
        [ ${update_ok} -eq 1 ] && touch "${host_stamp}" 2>/dev/null
        ;;
    *)
        echo "使用: update [force](更新)"
        exit 1
        ;;
esac
