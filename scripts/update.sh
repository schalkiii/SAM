#!/system/bin/sh
# 加载基础脚本
source "/data/adb/modules/SAM/scripts/base.sh"

# 下载地址
download_url=""
# 保存文件
save_file=""
# 是否已更新
is_update=false
# 是否为了替换内核而停过服务
services_stopped=0
# 更新前服务是否本来就处于停止状态
was_stopped=0
case "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" in
    stopped*) was_stopped=1 ;;
esac

# SmartDNS 版本
smartdns_ver=$(cd ${SMARTDNS_PATH} && SMARTDNS_WORKDIR="${SMARTDNS_PATH}" exec ${SMARTDNS_BIN} -v | sed -n 's/^.*[[:space:]]\(.*\)[[:space:]].*/\1/p')
# AdGuardHome 版本
agh_ver=$(${AGH_BIN} --version | sed -n 's/^.*version[[:space:]]\(.*\)$/\1/p')
# Mihomo 版本
mihomo_ver=$(${MIHOMO_BIN} -v | sed -n "s/^.*Meta[[:space:]]\(.*\)[[:space:]]android.*$/\1/p")

# 获取下载地址
get_download_url(){
    # API 地址
    api_url="https://api.github.com/repos/${1}/releases"
    # API 内容
    api_content=$(curl --connect-timeout 10 -m 15 -s -f ${api_url})

    # 获取下载地址
    download_url=$(echo "${api_content}" | grep "browser_download_url" | grep -E "${2}")
    if [ ${3} = 1 ]; then
        download_url=$(echo "${download_url}" | grep -Ev "Prerelease-Alpha|-b|nightly")
    fi
    download_url=$(echo "${download_url}" | sed -n "1p" | sed -n "s/^.*:[[:space:]]\"\(.*\)\"$/\1/p")

    # 跳过签名/校验文件，避免把 .sha256 当二进制下载
    if echo "${download_url}" | grep -qE "\.(sha256|sig|asc)$"; then
        log "e" "选到的下载地址是校验文件，跳过: ${download_url}"
        return 1
    fi

    # 检查
    if [ -n "${4}" ] && echo "${download_url}" | grep -qF "${4}"; then
        log "i" "已是最新版本"
        return 1
    fi
    if [ -n "${download_url}" ]; then
        log "i" "获取下载地址 > ${download_url}"
        return 0
    else
        log "e" "未成功获取下载地址"
        return 1
    fi
}

# 下载文件
# 必须有连接/总时长超时，否则网络卡住时 WebUI 会一直等
download_file(){
    save_file="${TMP_PATH}/$(echo ${download_url} | sed 's/^.*\///g')"
    curl -f -L -# --connect-timeout 15 -m 300 -o "${save_file}" "${download_url}" && return 0
    rm -f "${save_file}"
    log "e" "下载失败: ${download_url}"
    return 1
}

# 替换前停服务：直接覆盖运行中的二进制会 ETXTBSY，覆盖已 mmap 的 libc 还可能 SIGBUS
stop_for_replace(){
    [ ${services_stopped} -eq 1 ] && return 0
    log "i" "停止服务以便替换内核文件"
    # 更新前留一份完整配置备份，便于回滚
    [ -f "${SCRIPTS_PATH}/backup.sh" ] && sh "${SCRIPTS_PATH}/backup.sh" save > /dev/null 2>&1
    sh "${SCRIPTS_PATH}/service.sh" stop > /dev/null 2>&1
    services_stopped=1
}

# 文件替换，保留 .bak 供自检失败时回滚
replace_file(){
    log "i" "替换文件: ${1} > ${2}"
    if [ -f "${2}" ]; then
        cp -f -p "${2}" "${2}.bak" 2>/dev/null
    fi
    cp -R -f -p "${1}" "${2}"
}

restore_bak(){
    if [ -f "${1}.bak" ]; then
        mv -f "${1}.bak" "${1}" && log "i" "已回滚: ${1}"
    fi
}

# SmartDNS 二进制/loader 不兼容时，二进制、ui.so 和 lib 目录一起回滚
lib_backup=""
smartdns_rollback(){
    if [ -n "${lib_backup}" ] && [ -d "${lib_backup}" ]; then
        rm -rf "${SMARTDNS_PATH}/lib"
        mv -f "${lib_backup}" "${SMARTDNS_PATH}/lib"
    fi
    restore_bak "${SMARTDNS_PATH}/${SMARTDNS_BIN}"
    restore_bak "${SMARTDNS_PATH}/smartdns_ui.so"
    rm -rf "${TMP_PATH}/${SMARTDNS_BIN}"
}

# SmartDNS 下载
smartdns_download(){
    log "i" "更新 SmartDNS"
    get_download_url "pymumu/smartdns" "aarch64-linux-all" 1 ${smartdns_ver} || return 1
    log "i" "开始下载，请稍等..."
    download_file || return 1
    log "i" "解压缩 > ${save_file}"
    tar -zxvf "${save_file}" -C "${TMP_PATH}" || { rm -f "${save_file}"; return 1; }
    rm -f "${save_file}"
    # 删除软连接
    rm -rf "${TMP_PATH}/${SMARTDNS_BIN}/usr/local/lib/smartdns/lib/ld-linux.so"
    rm -rf "${TMP_PATH}/${SMARTDNS_BIN}/usr/local/lib/smartdns/lib/ld-musl-aarch64.so.1"
    stop_for_replace

    # 记录旧 lib 目录，二进制或 loader 不兼容时一起回滚
    lib_backup="${TMP_PATH}/smartdns_lib.bak"
    rm -rf "${lib_backup}"
    cp -R -p "${SMARTDNS_PATH}/lib" "${lib_backup}" 2>/dev/null

    # 替换文件
    replace_file "${TMP_PATH}/${SMARTDNS_BIN}/usr/share/smartdns/wwwroot" "${SMARTDNS_PATH}" || { smartdns_rollback; return 1; }
    replace_file "${TMP_PATH}/${SMARTDNS_BIN}/usr/local/lib/smartdns/smartdns_ui.so" "${SMARTDNS_PATH}/smartdns_ui.so" || { smartdns_rollback; return 1; }
    replace_file "${TMP_PATH}/${SMARTDNS_BIN}/usr/local/lib/smartdns/smartdns" "${SMARTDNS_PATH}/smartdns" || { smartdns_rollback; return 1; }
    replace_file "${TMP_PATH}/${SMARTDNS_BIN}/usr/local/lib/smartdns/lib" "${SMARTDNS_PATH}" || { smartdns_rollback; return 1; }
    log "i" "修改权限"
    chmod 755 "${SMARTDNS_PATH}/${SMARTDNS_BIN}"
    chmod 755 "${SMARTDNS_PATH}/smartdns_ui.so"
    chmod -R 755 "${SMARTDNS_PATH}/lib"
    chown "${SAM_USER}:${DNS_GROUP}" "${SMARTDNS_PATH}/${SMARTDNS_BIN}"
    chown root:root "${SMARTDNS_PATH}/smartdns_ui.so"
    chown -R root:root "${SMARTDNS_PATH}/lib"

    # 自检: 新二进制必须能在当前 loader 下输出版本
    if ! (cd "${SMARTDNS_PATH}" && SMARTDNS_WORKDIR="${SMARTDNS_PATH}" ./${SMARTDNS_BIN} -v > /dev/null 2>&1); then
        log "e" "新 SmartDNS 无法运行，回滚"
        smartdns_rollback
        return 1
    fi
    rm -rf "${lib_backup}" "${TMP_PATH}/${SMARTDNS_BIN}"
    rm -f "${SMARTDNS_PATH}/${SMARTDNS_BIN}.bak" "${SMARTDNS_PATH}/smartdns_ui.so.bak"
    log "i" "删除下载文件"
    is_update=true
}

# AdGuardHome 下载
agh_download(){
    log "i" "更新 AdGuardHome"
    get_download_url "AdguardTeam/AdGuardHome" "linux_arm64" 1 ${agh_ver} || return 1
    log "i" "开始下载，请稍等..."
    download_file || return 1
    log "i" "解压缩 > ${save_file}"
    tar -zxvf "${save_file}" -C "${TMP_PATH}" || { rm -f "${save_file}"; return 1; }
    rm -f "${save_file}"
    stop_for_replace
    # 替换文件
    replace_file "${TMP_PATH}/${AGH_BIN}/${AGH_BIN}" "${BIN_PATH}/${AGH_BIN}" || return 1
    log "i" "修改权限"
    chmod 755 "${BIN_PATH}/${AGH_BIN}"
    chown "${SAM_USER}:${DNS_GROUP}" "${BIN_PATH}/${AGH_BIN}"

    if ! "${BIN_PATH}/${AGH_BIN}" --version > /dev/null 2>&1; then
        log "e" "新 AdGuardHome 无法运行，回滚"
        restore_bak "${BIN_PATH}/${AGH_BIN}"
        rm -rf "${TMP_PATH}/${AGH_BIN}"
        return 1
    fi
    # 自检通过后删除 .bak，避免常驻占用 30MB+
    rm -f "${BIN_PATH}/${AGH_BIN}.bak"
    log "i" "删除下载文件"
    rm -rf "${TMP_PATH}/${AGH_BIN}"
    is_update=true
}

# Mihomo 下载
mihomo_download(){
    log "i" "更新 Mihomo "
    # 检查内核
    ${MIHOMO_BIN} -v | grep -q "smart" && {
        log "i" "获取 Smart 内核"
        get_download_url "vernesong/mihomo" "android-arm64.*$(echo ${mihomo_ver} | sed -n 's/^\(.*-.*\)-.*$/\1/p')" 0 ${mihomo_ver} || return 1
    } || {
        log "i" "获取标准内核"
        get_download_url "MetaCubeX/mihomo" "android-arm64.*" 1 ${mihomo_ver} || return 1
    }
    log "i" "开始下载，请稍等..."
    download_file || return 1
    log "i" "解压缩 > ${save_file}"
    gzip -d "${save_file}" || { rm -f "${save_file}"; return 1; }
    mihomo_file="${save_file%.gz}"
    log "i" "重命名: ${mihomo_file} > ${TMP_PATH}/${MIHOMO_BIN}"
    mv -f "${mihomo_file}" "${TMP_PATH}/${MIHOMO_BIN}" || return 1
    stop_for_replace
    # 替换文件
    replace_file "${TMP_PATH}/${MIHOMO_BIN}" "${BIN_PATH}/${MIHOMO_BIN}" || return 1
    log "i" "修改权限"
    chmod 755 "${BIN_PATH}/${MIHOMO_BIN}"
    chown "${SAM_USER}:${TUN_GROUP}" "${BIN_PATH}/${MIHOMO_BIN}"

    if ! "${BIN_PATH}/${MIHOMO_BIN}" -v > /dev/null 2>&1; then
        log "e" "新 Mihomo 无法运行，回滚"
        restore_bak "${BIN_PATH}/${MIHOMO_BIN}"
        rm -rf "${TMP_PATH}/${MIHOMO_BIN}"
        return 1
    fi
    # 自检通过后删除 .bak，避免常驻占用 60MB+
    rm -f "${BIN_PATH}/${MIHOMO_BIN}.bak"
    log "i" "删除下载文件"
    rm -rf "${TMP_PATH}/${MIHOMO_BIN}"
    is_update=true
}

log "i" "update >>>"
mihomo_download
agh_download
smartdns_download
log "i" "<<< update"

# 替换过内核后重启服务；如果用户本来是手动停止的，保持停止
if [ ${services_stopped} -eq 1 ]; then
    if [ ${was_stopped} -eq 1 ]; then
        log "i" "服务原本处于停止状态，更新后保持停止"
    else
        log "i" "更新完成，重新启动服务"
        sh "${SCRIPTS_PATH}/service.sh" start
    fi
fi

if [ "${is_update}" = true ]; then
    # 内核类型可能变化(smart/标准)，让描述缓存重新探测
    rm -f "${TMP_PATH}/mihomo_core"
    log "i" "内核更新完成"
else
    log "i" "没有需要更新的内核"
fi
