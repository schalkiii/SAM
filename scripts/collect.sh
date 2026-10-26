#!/system/bin/sh
# SAM 一键取证收集
#
# 为什么需要它:
#   自动停止类问题要同时看 module.log 三代、tmp 取证文件、diagnose 全量输出、
#   进程 cgroup 与内核/系统的击杀记录。在 WebUI 工具页逐个按钮运行、再分段
#   复制，既慢又容易漏段（每次运行还是不同时刻的快照）。本脚本把同一时刻的
#   全部证据写进一个报告文件，一次取走即可。
#
# 用法:
#   sh collect.sh          生成报告到 /data/adb/SAM-debug/（root-only）
#   sh collect.sh share    额外复制一份到 /sdcard/Download，方便手机端直接发送
#   sh collect.sh list     列出已有报告
#
# 安全:
#   报告含订阅链接、节点地址、DNS 查询与内网信息，默认只写 root 可读目录；
#   share 是显式导出，导出前会提示一次风险。

MODULE_PATH="/data/adb/modules/SAM"
SCRIPTS_PATH="${MODULE_PATH}/scripts"
TMP_PATH="${MODULE_PATH}/tmp"
LOG_FILE="${TMP_PATH}/module.log"
OUT_DIR="/data/adb/SAM-debug"
SHARE_DIR="/sdcard/Download"

# 单个日志文件的收录上限: module.log 单代通常几百 KB，这里防止历史异常把
# 报告撑到几十 MB（报告本身还要能被 WebUI/文件管理器打开）
MAX_LINES=4000
# 报告保留份数: 取证需要对比"这次"和"上次"，留最近 10 份
KEEP_REPORTS=10

REPORT=""
STAMP="$(date '+%Y%m%d-%H%M%S')"

section(){
    {
        echo ""
        echo "──────────────────────────────────────────"
        echo "## ${1}"
        echo "──────────────────────────────────────────"
    } >> "${REPORT}"
}

# 收录文件内容；超过上限只保留尾部，并注明完整文件位置
dump_file(){
    dump_path="${1}"
    dump_limit="${2:-${MAX_LINES}}"
    dump_title="${3:-${dump_path}}"

    if [ ! -f "${dump_path}" ]; then
        echo "(不存在: ${dump_path})" >> "${REPORT}"
        return 0
    fi

    dump_total=$(wc -l < "${dump_path}" 2>/dev/null | tr -d ' ')
    dump_size=$(wc -c < "${dump_path}" 2>/dev/null | tr -d ' ')
    echo "--- ${dump_title} (${dump_total:-0} 行 / ${dump_size:-0} 字节) ---" >> "${REPORT}"
    if [ "${dump_total:-0}" -gt "${dump_limit}" ]; then
        echo "[超过 ${dump_limit} 行，只显示最后 ${dump_limit} 行；完整文件: ${dump_path}]" >> "${REPORT}"
        tail -n "${dump_limit}" "${dump_path}" >> "${REPORT}" 2>/dev/null
    else
        cat "${dump_path}" >> "${REPORT}" 2>/dev/null
    fi
}

# 收录命令输出；失败也写进报告，避免"这一段空白"无法区分是没输出还是没跑
dump_cmd(){
    dump_cmd_title="${1}"
    shift
    echo "--- ${dump_cmd_title} ---" >> "${REPORT}"
    if ! "$@" >> "${REPORT}" 2>&1; then
        echo "(命令返回非零: $*) " >> "${REPORT}"
    fi
}

# 逐行 grep 一个文件（文件不存在时静默），用于从大日志里抽关键行
dump_grep(){
    dump_grep_path="${1}"
    dump_grep_title="${2}"
    dump_grep_pattern="${3}"
    dump_grep_limit="${4:-40}"

    echo "--- ${dump_grep_title} ---" >> "${REPORT}"
    if [ ! -f "${dump_grep_path}" ]; then
        echo "(不存在: ${dump_grep_path})" >> "${REPORT}"
        return 0
    fi
    grep -E "${dump_grep_pattern}" "${dump_grep_path}" 2>/dev/null | tail -n "${dump_grep_limit}" >> "${REPORT}"
    echo "(以上为最后 ${dump_grep_limit} 条命中)" >> "${REPORT}"
}

# 进程 + cgroup: 应用 cgroup 被整组 kill 时，这里能直接看出进程本来挂在哪一组
dump_processes(){
    echo "--- 相关进程(ps) ---" >> "${REPORT}"
    {
        ps -ef 2>/dev/null || ps -A 2>/dev/null
    } | grep -iE "smartdns|AdGuardHome|mihomo|watchdog|supervisor|inotify|wifi\.monitor|crond" \
        | grep -v " grep " >> "${REPORT}" 2>/dev/null
    echo "(以上为匹配到的进程; 空 = 全部不在运行)" >> "${REPORT}"

    echo "" >> "${REPORT}"
    echo "--- 相关进程的 cgroup ---" >> "${REPORT}"
    for cg_pattern in \
        "${SCRIPTS_PATH}/watchdog.sh" \
        "${SCRIPTS_PATH}/supervisor.sh" \
        "${SCRIPTS_PATH}/wifi.monitor.sh" \
        "${SCRIPTS_PATH}/inotify" \
        "smartdns" \
        "AdGuardHome" \
        "mihomo"; do
        for cg_pid in $(pgrep -f "${cg_pattern}" 2>/dev/null); do
            echo "${cg_pattern} pid=${cg_pid} cgroup=$(tr '\n' ' ' < "/proc/${cg_pid}/cgroup" 2>/dev/null)" >> "${REPORT}"
        done
    done
    echo "(空 = 没有匹配进程)" >> "${REPORT}"
}

# 报告生成
do_collect(){
    if [ "$(id -u)" != "0" ]; then
        echo "需要 root 权限运行"
        exit 1
    fi
    mkdir -p "${OUT_DIR}" 2>/dev/null || {
        echo "无法创建 ${OUT_DIR}"
        exit 1
    }

    REPORT="${OUT_DIR}/SAM-report-${STAMP}.txt"
    : > "${REPORT}" || exit 1

    section "报告信息"
    # boot_count 在 MIUI 上是 settings 的 global 项，/proc/sys/kernel/boot_count
    # 并不存在；读不到时退回 watchdog 记录的 tmp/boot.count，避免报告头一直是空的
    boot_count_now="$(settings get global boot_count 2>/dev/null)"
    case "${boot_count_now}" in
        ''|null|*[!0-9]*) boot_count_now="$(cat "${TMP_PATH}/boot.count" 2>/dev/null)" ;;
    esac
    {
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "模块目录: ${MODULE_PATH}"
        echo "模块版本: $(grep -m1 '^version=' "${MODULE_PATH}/module.prop" 2>/dev/null | cut -d= -f2-)"
        echo "模块描述: $(grep -m1 '^description=' "${MODULE_PATH}/module.prop" 2>/dev/null | cut -d= -f2-)"
        echo "系统运行秒数: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
        echo "boot_count: ${boot_count_now:-未知}"
        echo "SELinux: $(getenforce 2>/dev/null)"
        echo "设备型号: $(getprop ro.product.model 2>/dev/null)"
        echo "Android: $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
        echo "MIUI: $(getprop ro.miui.ui.version.name 2>/dev/null)"
        echo "内核: $(uname -a 2>/dev/null)"
    } >> "${REPORT}"

    section "服务状态与取证标记"
    for state_file in service.state service.abnormal boot.count boot.count.previous watchdog.heartbeat ipv6.block.mode owner.supported; do
        dump_file "${TMP_PATH}/${state_file}" 200 "${state_file}"
    done
    dump_file "${TMP_PATH}/agh.config.bad.reason" 200 "agh.config.bad.reason"

    section "module.log 三代(完整)"
    dump_file "${TMP_PATH}/module.log.boot.1" "${MAX_LINES}" "module.log.boot.1 (上次开机)"
    dump_file "${TMP_PATH}/module.log.1" "${MAX_LINES}" "module.log.1 (上一次重启前)"
    dump_file "${LOG_FILE}" "${MAX_LINES}" "module.log (当前)"

    section "SERVICE-EVENT / ERROR 摘要"
    for log_variant in "${TMP_PATH}/module.log.boot.1" "${TMP_PATH}/module.log.1" "${LOG_FILE}"; do
        dump_grep "${log_variant}" "${log_variant##*/} 的 SERVICE-EVENT/ERROR" "SERVICE-EVENT|ERROR" 30
    done

    section "auto-stop 取证文件"
    auto_stop_found=0
    for auto_stop_file in "${TMP_PATH}"/auto-stop.*.log; do
        [ -f "${auto_stop_file}" ] || continue
        auto_stop_found=1
        dump_file "${auto_stop_file}" "${MAX_LINES}" "${auto_stop_file##*/}"
    done
    [ "${auto_stop_found}" -eq 0 ] && echo "暂无 auto-stop.*.log（未发生过异常消失，或 watchdog 同时被杀）" >> "${REPORT}"

    section "三服务自身日志(尾部)"
    dump_file "${TMP_PATH}/smartdns.out" 120 "smartdns.out"
    dump_file "${TMP_PATH}/smartdns.log" 200 "smartdns.log"
    dump_file "${TMP_PATH}/AdGuardHome.log" 200 "AdGuardHome.log"
    dump_file "${TMP_PATH}/mihomo.log" 200 "mihomo.log"

    section "一键诊断(diagnose.sh 全量只读输出)"
    if [ -f "${SCRIPTS_PATH}/diagnose.sh" ]; then
        sh "${SCRIPTS_PATH}/diagnose.sh" >> "${REPORT}" 2>&1 || echo "(diagnose.sh 返回非零)" >> "${REPORT}"
    else
        echo "(缺少 ${SCRIPTS_PATH}/diagnose.sh)" >> "${REPORT}"
    fi

    section "进程与 cgroup"
    dump_processes

    section "防火墙与端口"
    dump_cmd "nat 表 DNS 重定向链" iptables -w 100 -t nat -L REDIRECT_DNS -n -v
    dump_cmd "OUTPUT 跳转是否存在" sh -c 'iptables -w 100 -t nat -C OUTPUT -j REDIRECT_DNS > /dev/null 2>&1 && echo 存在 || echo 缺失'
    dump_cmd "IPv6 DNS 阻断链" ip6tables -w 100 -t filter -L BLOCK_IPV6_DNS -n -v
    dump_cmd "IPv6 DNS 重定向链" ip6tables -w 100 -t nat -L REDIRECT_IPV6_DNS -n -v
    dump_cmd "监听端口" sh -c 'ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null'

    section "系统击杀线索"
    dump_cmd "dmesg 中的 OOM/击杀记录" sh -c 'dmesg 2>/dev/null | grep -iE "out of memory|oom|lowmemorykiller|kill" | tail -n 40'
    dump_cmd "logcat events 的 am_kill/am_proc_died" sh -c 'logcat -b events -d 2>/dev/null | grep -E "am_kill|am_proc_died" | tail -n 40'
    dump_cmd "logcat 中的进程清理记录" sh -c 'logcat -d -t 800 2>/dev/null | grep -iE "lowmemorykiller|lmkd|ActivityManager.*kill|Force stopping|Scheduling restart" | tail -n 40'
    dump_cmd "deviceidle 白名单(SAM 相关)" sh -c 'dumpsys deviceidle whitelist 2>/dev/null | grep -iE "SAM|smartdns|AdGuardHome|mihomo"'

    section "文件与挂载状态"
    dump_cmd "bin/ 软链" ls -l "${MODULE_PATH}/bin"
    dump_cmd "SmartDNS 软链" ls -l "${MODULE_PATH}/etc/SmartDNS"
    dump_cmd "hosts 挂载" sh -c "mount 2>/dev/null | grep -E ' /system/etc/hosts '"
    dump_cmd "data 分区空间" df -h /data

    echo "" >> "${REPORT}"
    echo "── 报告结束 $(date '+%Y-%m-%d %H:%M:%S') ──" >> "${REPORT}"

    # 只保留最近 KEEP_REPORTS 份，避免长期占用 /data
    ls -t "${OUT_DIR}"/SAM-report-*.txt 2>/dev/null | tail -n +$((KEEP_REPORTS + 1)) | while read -r old_report; do
        rm -f "${old_report}" 2>/dev/null
    done

    echo "报告已生成: ${REPORT}"
    echo "大小: $(wc -c < "${REPORT}" 2>/dev/null | tr -d ' ') 字节, $(wc -l < "${REPORT}" 2>/dev/null | tr -d ' ') 行"

    if [ "${1}" = "share" ]; then
        mkdir -p "${SHARE_DIR}" 2>/dev/null
        share_target="${SHARE_DIR}/SAM-report-${STAMP}.txt"
        if cp -f "${REPORT}" "${share_target}" 2>/dev/null; then
            echo "已导出到: ${share_target}"
            echo "注意: 导出文件含订阅链接/节点地址/查询日志，发送前确认接收方与渠道。"
        else
            echo "导出失败: ${SHARE_DIR} 不可写"
        fi
    else
        echo "提示: 手机端不便读 /data 时用「导出报告到下载目录」，或再次运行 sh collect.sh share"
    fi
}

list_reports(){
    if [ ! -d "${OUT_DIR}" ]; then
        echo "暂无报告(${OUT_DIR} 不存在)"
        return 0
    fi
    ls -lh "${OUT_DIR}"/SAM-report-*.txt 2>/dev/null || echo "暂无报告"
}

case "${1}" in
    ""|share)
        do_collect "${1}"
        ;;
    list)
        list_reports
        ;;
    *)
        echo "用法: collect.sh [share|list]"
        echo "  无参数  生成报告到 ${OUT_DIR}"
        echo "  share   生成报告并复制一份到 ${SHARE_DIR}"
        echo "  list    列出已有报告"
        exit 1
        ;;
esac
