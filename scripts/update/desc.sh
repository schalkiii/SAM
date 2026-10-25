#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

out_content=""

start_service="🟢已运行: "
stop_service="🔴已停止: "
services=(${SMARTDNS_BIN} ${AGH_BIN} ${MIHOMO_BIN})
for i in ${services[@]}
do
    isRun ${i} && {
        start_service+="[${i}]"
    } || {
        stop_service+="[${i}]"
    }
done
[ ${#start_service} -gt 15 ] && out_content+=${start_service}
[ ${#stop_service} -gt 15 ] && out_content+=" ${stop_service}"

out_content+=" 🤖Smart内核: "
# 缓存探测结果: mihomo 是 60MB+ 的二进制，每次启停都执行 -v 代价偏高
core_cache="${TMP_PATH}/mihomo_core"
if [ -f "${core_cache}" ]; then
    core_type=$(cat "${core_cache}" 2>/dev/null)
else
    if mihomo -v 2>/dev/null | grep -q "smart"; then
        core_type="smart"
    else
        core_type="standard"
    fi
    echo "${core_type}" > "${core_cache}" 2>/dev/null
fi
[ "${core_type}" = "smart" ] && out_content+="[✅]" || out_content+="[❌]"

out_content+=" ⚙️模式: "
if [ "${ENABLE_WHITELIST}" = true ]; then
    [ "${WHITELIST_MODE}" = 1 ] && out_content+="[白名单 1]" || out_content+="[白名单 2]"
else
    out_content+="[黑名单]"
fi

out_content+=" 📊监控: "
isRun "${INOTIFY_PATH}/module.sh" && out_content+="[模块✅]" || out_content+="[模块❌]"
isRun "${INOTIFY_PATH}/host.sh" && out_content+="[Hosts✅]" || out_content+="[Hosts❌]"

out_content+=" 🚦直通: "
[ "${BYPASS_ENABLE}" = "true" ] && out_content+="[已开启]" || out_content+="[已关闭]"

out_content+=" 🌐Host: "
[ "${HOST_ENABLE}" = true ] && out_content+="[已启用]" || out_content+="[已禁用]"
out_content+=" ⏰定时: "
[ "${CRONTAB_ENABLE}" = true ] && out_content+="[已启用]" || out_content+="[已禁用]"

# 凭据必须写实：默认 root/root（AGH 模板与 SmartDNS 面板同源），
# 改默认值时要同步这两处配置 + 本文案 + README
out_content+=" 📢面板账号: root / root（Mihomo 无鉴权）"

# 写回模块描述
# 原实现用 sed "s/description=.*/description=${out_content}/g"，
# 一旦描述里出现路径(含 /)或 & / \ 就会报 "unknown option to `s'"，
# 导致描述更新失败、模块管理器里一直显示旧状态。
# 这里用环境变量把描述传给 awk(避免 -v 的反斜杠转义)，整体重写该行。
write_description(){
    desc_file="${1}"
    desc_text="${2}"
    [ -f "${desc_file}" ] || return 1

    desc_tmp="${TMP_PATH}/module.prop.$$"
    : > "${desc_tmp}" 2>/dev/null || return 1
    # 不依赖 awk 的 ENVIRON/sed 转义: 逐行重写，兼容描述里的 emoji、空格与特殊字符
    while IFS= read -r desc_line || [ -n "${desc_line}" ]; do
        case "${desc_line}" in
            description=*) printf 'description=%s\n' "${desc_text}" >> "${desc_tmp}" ;;
            *) printf '%s\n' "${desc_line}" >> "${desc_tmp}" ;;
        esac
    done < "${desc_file}"

    if [ ! -s "${desc_tmp}" ] || ! grep -q "^description=" "${desc_tmp}" 2>/dev/null; then
        rm -f "${desc_tmp}" 2>/dev/null
        return 1
    fi
    mv -f "${desc_tmp}" "${desc_file}" && return 0
    rm -f "${desc_tmp}" 2>/dev/null
    return 1
}

if write_description "${MODULE_PATH}/module.prop" "${out_content}"; then
    log "i" "更新模块描述: ${out_content}"
else
    log "e" "更新模块描述失败: ${MODULE_PATH}/module.prop"
fi

# 刷入后尚未重启/激活时，管理器可能显示的是 modules_update 里的 module.prop。
# 把待激活包描述改成明确状态，避免它一直显示"模块未启动"造成误判。
UPDATE_MODULE_PROP="/data/adb/modules_update/SAM/module.prop"
if [ -f "${UPDATE_MODULE_PROP}" ]; then
    if write_description "${UPDATE_MODULE_PROP}" "已安装，待重启/激活生效"; then
        log "i" "更新待激活模块描述"
    else
        log "e" "更新待激活模块描述失败: ${UPDATE_MODULE_PROP}"
    fi
fi
