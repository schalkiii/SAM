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

# 更新互斥: WebUI、命令行与定时任务可能并发触发，
# 两个实例同时停服务/替换二进制会互相把对方的文件回滚掉
sam_lock_acquire "update" 60 || {
    log "e" "另一个更新任务正在进行，退出"
    exit 1
}
release_update_lock(){
    sam_lock_release "update"
}
# 信号必须显式退出: 只释放锁会让脚本在收到 TERM/HUP 后继续替换内核
trap release_update_lock EXIT
trap 'release_update_lock; exit 1' HUP INT TERM

# SmartDNS 版本
smartdns_ver=$(cd ${SMARTDNS_PATH} && SMARTDNS_WORKDIR="${SMARTDNS_PATH}" exec ${SMARTDNS_BIN} -v | sed -n 's/^.*[[:space:]]\(.*\)[[:space:]].*/\1/p')
# AdGuardHome 版本
agh_ver=$(${AGH_BIN} --version | sed -n 's/^.*version[[:space:]]\(.*\)$/\1/p')
# AGH 配置 schema: 大版本升级会在首次启动时迁移，回退旧二进制会不兼容
agh_schema_ver=$(grep -m1 '^schema_version:' "${AGH_CONF}" 2>/dev/null | awk '{print $2}')
# Mihomo 版本
mihomo_ver=$(${MIHOMO_BIN} -v | sed -n "s/^.*Meta[[:space:]]\(.*\)[[:space:]]android.*$/\1/p")

# 获取下载地址
get_download_url(){
    # API 地址
    api_url="https://api.github.com/repos/${1}/releases"
    # API 内容
    # 与 hosts 更新同源: 部分 ROM 没有 curl，直接调 curl 会让所有组件更新 100% 失败
    api_content=$(fetch_url "${api_url}" 15)

    # release tag 与当前版本一致时直接跳过，避免 AGH 这类固定资产名每次重复停服替换
    release_tag=$(printf '%s\n' "${api_content}" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | sed 's/^[vV]//')
    if [ -n "${4}" ] && [ -n "${release_tag}" ] && [ "${release_tag}" = "${4}" ]; then
        log "i" "已是最新版本(tag ${release_tag})"
        return 1
    fi
    release_prerelease=$(printf '%s\n' "${api_content}" | sed -n 's/.*"prerelease"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -n 1)
    if [ "${3}" = "1" ] && [ "${release_prerelease}" = "true" ]; then
        log "i" "最新 release 是预发布版本，按设置跳过"
        return 1
    fi

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
    fetch_file "${download_url}" "${save_file}" 300 || {
        rm -f "${save_file}"
        log "e" "下载失败: ${download_url}"
        return 1
    }
    verify_download_checksum "${download_url}" "${save_file}"
}

# 发布方提供 .sha256 时强制校验；未提供时记录风险但不阻断
verify_download_checksum(){
    checksum_url="${1}.sha256"
    checksum_file="${TMP_PATH}/download.sha256.$$"
    if ! fetch_url "${checksum_url}" 30 > "${checksum_file}"; then
        rm -f "${checksum_file}"
        log "i" "发布未提供 .sha256，无法做下载摘要校验"
        return 0
    fi
    # 缺 sha256sum 时不能把"没法校验"当成"校验失败":
    # 原实现 actual_hash 为空 -> 与期望不等 -> 删除文件并判失败，
    # 用户在精简系统上会永远更新不了任何组件
    if ! has_cmd sha256sum; then
        rm -f "${checksum_file}"
        log "e" "缺少 sha256sum，跳过下载摘要校验(存在被篡改风险)"
        return 0
    fi
    expected_hash=$(awk 'NF {print $1; exit}' "${checksum_file}" | tr 'A-F' 'a-f')
    actual_hash=$(sha256sum "${2}" 2>/dev/null | awk '{print $1}')
    rm -f "${checksum_file}"
    if [ -z "${expected_hash}" ] || [ "${expected_hash}" != "${actual_hash}" ]; then
        log "e" "下载摘要校验失败，删除文件"
        rm -f "${2}"
        return 1
    fi
    log "i" "下载摘要校验通过"
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
        cp -f -p "${2}" "${2}.bak" 2>/dev/null || {
            log "e" "备份旧文件失败，取消替换: ${2}"
            return 1
        }
    fi
    cp -R -f -p "${1}" "${2}" || {
        log "e" "复制新文件失败: ${1} -> ${2}"
        restore_bak "${2}"
        return 1
    }
}

# 校验 tar 归档，拒绝绝对路径、.. 穿越与链接成员
# 不能对 tar -tvzf 的整行做 ^/ 判断: 行首是权限位，成员名在行尾，
# 原来的判断永远为假，等于没有校验。
# -tvzf 用来看类型位(l/h = 符号链接/硬链接)，-tzf 用来看纯净成员名；
# 另外限制解压体积与成员数，避免损坏/恶意归档解出巨量文件占满存储。
safe_tar_extract(){
    tar_file="${1}"
    extract_dir="${2}"
    tar_list="${TMP_PATH}/tar.list.$$"
    tar_names="${TMP_PATH}/tar.names.$$"
    tar -tvzf "${tar_file}" > "${tar_list}" 2>/dev/null || {
        rm -f "${tar_list}" "${tar_names}"
        return 1
    }
    # 链接与硬链接成员一律拒绝(替换二进制/配置不需要链接)
    if grep -qE '^[lh]' "${tar_list}"; then
        log "e" "归档包含链接成员，拒绝解压"
        rm -f "${tar_list}" "${tar_names}"
        return 1
    fi
    # 只取成员名做路径校验，避免把权限位也拿去做判断
    tar -tzf "${tar_file}" > "${tar_names}" 2>/dev/null || {
        rm -f "${tar_list}" "${tar_names}"
        return 1
    }
    if grep -qE '(^/|(^|/)\.\.(/|$))' "${tar_names}"; then
        log "e" "归档包含绝对路径或 .. 穿越，拒绝解压"
        rm -f "${tar_list}" "${tar_names}"
        return 1
    fi
    tar_count=$(wc -l < "${tar_names}" 2>/dev/null | tr -d ' ')
    tar_total=$(awk '{sum += $3} END {print sum + 0}' "${tar_list}" 2>/dev/null)
    if [ "${tar_count}" -gt 20000 ] || [ "${tar_total}" -gt 1073741824 ]; then
        log "e" "归档体积或成员数超限(${tar_count} 个, ${tar_total} 字节)，拒绝解压"
        rm -f "${tar_list}" "${tar_names}"
        return 1
    fi
    rm -f "${tar_list}" "${tar_names}"
    mkdir -p "${extract_dir}" 2>/dev/null
    tar -zxf "${tar_file}" -C "${extract_dir}" >/dev/null 2>&1
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
    safe_tar_extract "${save_file}" "${TMP_PATH}" || { rm -f "${save_file}"; return 1; }
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
    safe_tar_extract "${save_file}" "${TMP_PATH}" || { rm -f "${save_file}"; return 1; }
    rm -f "${save_file}"
    stop_for_replace
    # 替换文件
    replace_file "${TMP_PATH}/${AGH_BIN}/${AGH_BIN}" "${BIN_PATH}/${AGH_BIN}" || {
        log "e" "AdGuardHome 替换失败，尝试回滚"
        restore_bak "${BIN_PATH}/${AGH_BIN}"
        rm -rf "${TMP_PATH}/${AGH_BIN}"
        return 1
    }
    log "i" "修改权限"
    chmod 755 "${BIN_PATH}/${AGH_BIN}"
    chown "${SAM_USER}:${DNS_GROUP}" "${BIN_PATH}/${AGH_BIN}"

    # 一次 --version 同时完成"能不能运行"自检与版本提取，避免对 30MB+ 二进制跑两遍
    if ! agh_version_output=$("${BIN_PATH}/${AGH_BIN}" --version 2>/dev/null); then
        log "e" "新 AdGuardHome 无法运行，回滚"
        restore_bak "${BIN_PATH}/${AGH_BIN}"
        rm -rf "${TMP_PATH}/${AGH_BIN}"
        return 1
    fi
    new_agh_ver=$(printf '%s\n' "${agh_version_output}" | sed -n 's/^.*version[[:space:]]\(.*\)$/\1/p')
    # 自检通过后删除 .bak，避免常驻占用 30MB+
    rm -f "${BIN_PATH}/${AGH_BIN}.bak"
    log "i" "AdGuardHome 版本: ${agh_ver} -> ${new_agh_ver}；配置 schema ${agh_schema_ver:-未知}"
    log "i" "新版本首次启动会迁移配置 schema；若之后回退旧版无法启动，用「工具 → 重置 AGH 配置」恢复模板"
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
    replace_file "${TMP_PATH}/${MIHOMO_BIN}" "${BIN_PATH}/${MIHOMO_BIN}" || {
        log "e" "Mihomo 替换失败，尝试回滚"
        restore_bak "${BIN_PATH}/${MIHOMO_BIN}"
        rm -rf "${TMP_PATH}/${MIHOMO_BIN}"
        return 1
    }
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
update_failed=0
mihomo_download || update_failed=1
agh_download || update_failed=1
smartdns_download || update_failed=1
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

[ ${update_failed} -eq 0 ] || {
    log "e" "部分组件更新失败，请查看上方日志"
    exit 1
}
