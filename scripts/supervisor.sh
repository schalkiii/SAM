#!/system/bin/sh
# watchdog 的监督进程
#
# 背景: 服务与 watchdog 会在同一秒整组消失，且 module.log 里没有任何事件
#       (SIGKILL 不经过我们的脚本)。watchdog 自己被杀后，模块内没有任何
#       进程能把它拉回来，服务就一直停着，只能等用户手动「软重启后恢复」。
# 职责: 只做一件事——watchdog 不在了就重新拉起它。不碰服务、规则与配置，
#       避免与 watchdog / service.sh 的职责重叠。
# 启动: KernelSU 由 initrc/sam.rc 交给 init 托管(被强杀后 init 会重新拉起)；
#       Magisk 或未加载 initrc 时由 scripts/service.sh start 兜底拉起。
source "/data/adb/modules/SAM/scripts/base.sh"

sam_lock_acquire "supervisor_instance" 2 || exit 0

trap 'sam_lock_release "supervisor_instance"' EXIT
trap 'sam_lock_release "supervisor_instance"; exit 0' HUP INT TERM

# 与 watchdog 一样脱离 cgroup，否则监督进程和被监督者会被同一次整组清理带走
protect_process "$$"

log "i" "监督进程已启动(每 30 秒确认 watchdog 存活)"
while true; do
    if ! pgrep -f "${SCRIPTS_PATH}/watchdog.sh" > /dev/null 2>&1; then
        # 用户主动停止时不重复拉起守护：状态是 stopped* 就只保持监督
        case "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" in
            stopped*)
                ;;
            *)
                log "e" "监督: watchdog 不在运行，重新拉起"
                record_service_event "supervisor restart watchdog"
                detach_exec "${SCRIPTS_PATH}/watchdog.sh" > /dev/null 2>&1
                ;;
        esac
    fi
    sleep 30
done
