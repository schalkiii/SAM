#!/system/bin/sh
# 以 root 身份执行传入的命令
# WebUI 与 action.sh 统一走这里，避免依赖 su 是否存在
# (CVE 临时 root / KernelSU 环境里可能根本没有 su 命令，但调用方本身已是 root)
#
# 非 root 时的提权方式:
#   不把参数拼进 "su -c" 的字符串里 —— 那样引号、&、$ 会被 shell 二次解释，
#   订阅链接里带 & 就会被截断甚至变成后台执行。
#   改为把参数逐行写进临时文件，提权后由本脚本用 --args-file 原样读回。

# 提权后的第二段: 从文件还原位置参数
if [ "$1" = "--args-file" ]; then
    args_file="$2"
    [ -f "${args_file}" ] || { echo "参数文件不存在: ${args_file}" >&2; exit 1; }
    set --
    while IFS= read -r arg_line; do
        set -- "$@" "${arg_line}"
    done < "${args_file}"
    rm -f "${args_file}"
    [ "$#" -gt 0 ] || exit 1
    exec "$@"
fi

[ "$#" -gt 0 ] || { echo "用法: sh run.sh <命令> [参数...]"; exit 1; }

# 已是 root，直接执行
if [ "$(id -u)" = "0" ]; then
    exec "$@"
fi

# 非 root: 参数落盘后提权
args_file="/data/local/tmp/.sam_args.$$"
: > "${args_file}" 2>/dev/null || { echo "无法创建临时文件: ${args_file}" >&2; exit 1; }
for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${args_file}"
done

for elevator in su ksu apd; do
    if command -v "${elevator}" > /dev/null 2>&1; then
        case "${elevator}" in
            su)  exec su -c "sh '$0' --args-file '${args_file}'" ;;
            ksu) exec ksu -c "sh '$0' --args-file '${args_file}'" ;;
            apd) exec apd -c "sh '$0' --args-file '${args_file}'" ;;
        esac
    fi
done

rm -f "${args_file}"
echo "[×] 无法提权：当前非 root，且未找到 su / ksu / apd" >&2
exit 1
