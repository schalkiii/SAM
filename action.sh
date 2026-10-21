#!/system/bin/sh
# 模块根目录(用脚本自身位置计算，避免依赖调用方的工作目录)
root="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# 非交互调用: sh action.sh resume|activate|start|stop|restart|uninstall|status
# 临时 root 环境下这个入口比音量键菜单更好用
if [ -n "$1" ]; then
    exec sh "${root}/scripts/run.sh" sh "${root}/scripts/manual.sh" "$@"
fi

# 菜单项数量
menu_count=5
selected=0

# 启动和停止
start_and_stop(){
    # 获取已启用服务数量
    service=$(sh "${root}/scripts/run.sh" sh "${root}/scripts/webui.sh" service)
    # 获取服务进程数量
    process=$(sh "${root}/scripts/run.sh" sh "${root}/scripts/webui.sh" process)
    # 判断数量相等，则停止，反之则运行
    if [ "${service}" = "${process}" ] || [ "${process}" -ne 0 ]; then
        sh "${root}/scripts/run.sh" sh "${root}/scripts/service.sh" stop
    else
        sh "${root}/scripts/run.sh" sh "${root}/scripts/service.sh" start
    fi
}

# 显示菜单(完整列出选项，当前项用 ▶ 标记)
show_menu(){
    echo "音量+ 确认 | 音量- 下一个 | 电源键 退出"
    [ ${selected} -eq 0 ] && echo "▶ 1. 启动/停止服务" || echo "  1. 启动/停止服务"
    [ ${selected} -eq 1 ] && echo "▶ 2. 恢复运行(软重启后)" || echo "  2. 恢复运行(软重启后)"
    [ ${selected} -eq 2 ] && echo "▶ 3. 激活模块" || echo "  3. 激活模块"
    [ ${selected} -eq 3 ] && echo "▶ 4. 更新服务" || echo "  4. 更新服务"
    [ ${selected} -eq 4 ] && echo "▶ 5. 立即卸载(不可恢复)" || echo "  5. 立即卸载(不可恢复)"
}

# 执行选中项
run_selected(){
    case ${selected} in
        0) start_and_stop ;;
        1) sh "${root}/scripts/run.sh" sh "${root}/scripts/manual.sh" resume ;;
        2) sh "${root}/scripts/run.sh" sh "${root}/scripts/manual.sh" activate ;;
        3) sh "${root}/scripts/run.sh" sh "${root}/scripts/update.sh" ;;
        4) sh "${root}/scripts/run.sh" sh "${root}/scripts/manual.sh" uninstall ;;
    esac
}

# 读取一次按键(音量上 24 | 音量下 25 | 电源 26)
wait_key(){
    getevent -l -q 2>/dev/null | while read -r event_line; do
        case "${event_line}" in
            *KEY_VOLUMEUP*DOWN*)
                echo 24
                exit 0
                ;;
            *KEY_VOLUMEDOWN*DOWN*)
                echo 25
                exit 0
                ;;
            *KEY_POWER*DOWN*)
                echo 26
                exit 0
                ;;
        esac
    done
}

if ! command -v getevent > /dev/null 2>&1; then
    echo "缺少 getevent，无法读取音量键"
    echo "请改用命令行: sh action.sh resume | activate | uninstall | start | stop | restart | status"
    exit 1
fi

while true; do
    show_menu
    key=$(wait_key)
    case ${key} in
        24)
            run_selected
            break
            ;;
        25)
            selected=$(( (selected + 1) % menu_count ))
            ;;
        26)
            echo "已退出"
            break
            ;;
        *)
            break
            ;;
    esac
done

sleep 1
