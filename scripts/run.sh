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
    caller_uid="${3:-}"
    [ -f "${args_file}" ] || { echo "参数文件不存在: ${args_file}" >&2; exit 1; }
    if [ -n "${caller_uid}" ]; then
        file_uid=$(stat -c %u "${args_file}" 2>/dev/null)
        # 只有成功读到属主且不一致时才拒绝: 精简系统没有 stat -c 时
        # file_uid 为空，原来的实现会把所有 WebUI 命令都判成"属主异常"
        if [ -n "${file_uid}" ] && [ "${file_uid}" != "${caller_uid}" ]; then
            echo "参数文件属主异常，拒绝执行" >&2
            rm -rf "$(dirname "${args_file}")"
            exit 1
        fi
    fi
    set --
    while IFS= read -r arg_line; do
        set -- "$@" "${arg_line}"
    done < "${args_file}"
    rm -rf "$(dirname "${args_file}")"
    [ "$#" -gt 0 ] || exit 1
    exec "$@"
fi

[ "$#" -gt 0 ] || { echo "用法: sh run.sh <命令> [参数...]"; exit 1; }

# 已是 root，直接执行
if [ "$(id -u)" = "0" ]; then
    exec "$@"
fi

# 非 root: 参数落盘后提权
# /data/local/tmp 其他应用可进入，必须用随机私有目录，不能用可预测的 PID 文件名
umask 077
args_dir=""
if command -v mktemp > /dev/null 2>&1; then
    args_dir=$(mktemp -d /data/local/tmp/.sam_args.XXXXXX 2>/dev/null)
fi
if [ -z "${args_dir}" ]; then
    args_dir="/data/local/tmp/.sam_args.$$.$(date +%s).${RANDOM:-0}"
    rm -rf "${args_dir}" 2>/dev/null
    mkdir -m 700 "${args_dir}" 2>/dev/null || { echo "无法创建临时目录: ${args_dir}" >&2; exit 1; }
fi
chmod 700 "${args_dir}" 2>/dev/null
args_file="${args_dir}/args"
: > "${args_file}" 2>/dev/null || { echo "无法创建临时文件: ${args_file}" >&2; exit 1; }
chmod 600 "${args_file}" 2>/dev/null
caller_uid=$(id -u)
for arg in "$@"; do
    case "${arg}" in
        *'
'*) echo "参数不能包含换行: ${arg}" >&2; rm -rf "${args_dir}"; exit 1 ;;
    esac
    printf '%s\n' "${arg}" >> "${args_file}"
done

for elevator in su ksu apd; do
    if command -v "${elevator}" > /dev/null 2>&1; then
        case "${elevator}" in
            su)  exec su -c "sh '$0' --args-file '${args_file}' '${caller_uid}'" ;;
            ksu) exec ksu -c "sh '$0' --args-file '${args_file}' '${caller_uid}'" ;;
            apd) exec apd -c "sh '$0' --args-file '${args_file}' '${caller_uid}'" ;;
        esac
    fi
done

rm -rf "${args_dir}"
echo "[×] 无法提权：当前非 root，且未找到 su / ksu / apd" >&2
exit 1
