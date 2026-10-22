# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 获取 Host
get_host(){    
    # 读取 hosts
    hosts_content=$(cat ${HOSTS_FILE} | grep -Ev "^[[:space:]]*$")
        
    log "i" "获取最新 ${1} host"
    # 获取 host
    get_content=""
    for i in ${2}
    do
        get_content+=$(curl -m 10 -s ${i} | grep -Ev "^#.*$|^[[:space:]]*$" | awk -F' ' '{print $1a, $2}')
        get_content+="\n"
    done
        
    # 检查内容为空则退出
    if [ -z "${get_content}" ] || [ ${#get_content} -le 100 ]; then
        log "e" "获取失败"
        return 1
    fi
     
    # 获取开始和结束行
    start_line=$(echo "${hosts_content}" | sed -n "/^#.*start.*${1}/=")
    end_line=$(echo "${hosts_content}" | sed -n "/^#.*${1}.*end/=")
    # 判断获取到则删除
    if [ -n "${start_line}" ] && [ -n "${end_line}" ]; then
        log "i" "删除 ${1} 旧规则"
        hosts_content=$(echo "${hosts_content}" | sed "${start_line},${end_line}d")
    fi
    
    # 排序并查重
    get_content=$(echo -e "${get_content}" | sort | uniq | grep -Ev "^[[:space:]]*$")
    # 输出
    hosts_content+="\n# start > ${1}\n${get_content}\n# ${1} < end"
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
    log "i" "写入 hosts 文件"
}



# 添加指令
case "$1" in
    update)
        log "i" "更新 host 规则"
        # GitHub
        get_host "GitHub" "https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts" || {
            log "i" "更换备用链接"
            get_host "GitHub" "https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@master/hosts"
        }
        # FCM
        get_host "FCM" "https://raw.githubusercontent.com/cagedbird043/fcm-hosts-next/main/fcm_dual.hosts" || {
            log "i" "更换备用链接"
            get_host "FCM" "https://cdn.jsdelivr.net/gh/Mice-Tailor-Infra/fcm-hosts-next@master/fcm_dual.hosts"
        }
        ;;
    *)
        echo "使用: update(更新)"
        exit 1
        ;;
esac