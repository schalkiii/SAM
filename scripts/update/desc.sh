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
mihomo -v | grep -q "smart" && out_content+="[✅]" || out_content+="[❌]"

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

out_content+=" 📢注意: 所有服务默认账号和密码都是root"

# 写回模块描述
# 原实现用 sed "s/description=.*/description=${out_content}/g"，
# 一旦描述里出现路径(含 /)或 & / \ 就会报 "unknown option to `s'"，
# 导致描述更新失败、模块管理器里一直显示旧状态。
# 这里用环境变量把描述传给 awk(避免 -v 的反斜杠转义)，整体重写该行。
SAM_DESC="${out_content}" awk '
    /^description=/ { print "description=" ENVIRON["SAM_DESC"]; next }
    { print }
' "${MODULE_PATH}/module.prop" > "${MODULE_PATH}/module.prop.tmp" 2>/dev/null && \
    mv -f "${MODULE_PATH}/module.prop.tmp" "${MODULE_PATH}/module.prop"

log "i" "更新模块描述"