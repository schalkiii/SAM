#!/system/bin/sh
# 备份后用内置模板重置 AdGuardHome 配置
# 适用: 配置 schema 与当前二进制不兼容(升级 AGH 后又回退)、YAML 严重损坏、UTF-16 编码
# 副作用: 会丢失 AGH 面板密码与自定义过滤规则；先自动做完整备份并保留单文件副本

source "/data/adb/modules/SAM/scripts/base.sh"

TEMPLATE="${AGH_PATH}/AdGuardHome.template.yaml"

reset_conf(){
    if [ ! -f "${TEMPLATE}" ]; then
        echo "模板不存在: ${TEMPLATE}"
        return 1
    fi

    echo "备份当前配置..."
    sh "${SCRIPTS_PATH}/backup.sh" save > /dev/null 2>&1 || \
        echo "完整备份失败(可能关闭了 BACKUP_CONF)，继续保留单文件备份"

    reset_stamp=$(date '+%Y%m%d-%H%M%S')
    if [ -f "${AGH_CONF}" ]; then
        cp -f "${AGH_CONF}" "${AGH_CONF}.bak.${reset_stamp}" || {
            echo "单文件备份失败，取消重置"
            return 1
        }
        echo "原配置: ${AGH_CONF}.bak.${reset_stamp}"
    fi

    cp -f "${TEMPLATE}" "${AGH_CONF}" || {
        echo "写入模板失败"
        return 1
    }

    # 按当前 setting.conf 重写端口、上游、监听与缓存开关
    if ! sh "${SCRIPTS_PATH}/update/agh.sh"; then
        echo "按 setting.conf 重写配置失败；模板已保留，请检查设置"
        return 1
    fi

    reset_check_output=$("${AGH_BIN}" --check-config -c "${AGH_CONF}" -w "${AGH_PATH}" 2>&1)
    if [ $? -ne 0 ]; then
        echo "模板校验失败:"
        printf '%s\n' "${reset_check_output}" | tail -n 5
        return 1
    fi

    rm -f "${TMP_PATH}/agh.config.bad" "${TMP_PATH}/agh.config.bad.reason"
    echo "配置已重置并通过校验"

    case "$(cat "${TMP_PATH}/service.state" 2>/dev/null)" in
        stopped*)
            echo "服务处于停止状态，未自动启动"
            return 0
            ;;
    esac
    if [ "${AGH_ENABLE}" != "true" ]; then
        echo "AdGuardHome 未启用，配置已重置但未启动"
        return 0
    fi

    if isRun "${AGH_BIN}"; then
        sh "${SERVICE_PATH}/agh.sh" stop > /dev/null 2>&1
    fi
    sh "${SERVICE_PATH}/agh.sh" start
    if isRun "${AGH_BIN}"; then
        echo "AdGuardHome 已用新配置启动"
    else
        echo "AdGuardHome 启动失败，请查看 tmp/module.log"
        return 1
    fi
}

reset_conf
