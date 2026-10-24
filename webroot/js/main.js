import { fullScreen, exec, toast } from './kernelsu.js'

const module_path = "/data/adb/modules/SAM"
const scripts_path = "/data/adb/modules/SAM/scripts"

// 保存中标记，避免连点产生并发重启
let savingSettings = false;
// 服务/挂载/监控操作互斥，避免连点造成并发 start 或重复 bind
let serviceActionBusy = false;
let mountActionBusy = false;
let monitorActionBusy = false;

// 单引号转义，保证参数原样传给 shell
function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

// 以 root 执行脚本，参数逐个加引号
// 走 scripts/run.sh 而不是直接 su -c: 临时 root / KernelSU 环境里可能没有 su 命令
function runShellArgs(script, args) {
    const quoted = (args || []).map(shellQuote).join(" ");
    const suffix = quoted ? " " + quoted : "";
    return exec(`sh "${scripts_path}/run.sh" sh "${scripts_path}/${script}"${suffix}`);
}

// 兼容旧调用: 传空格分隔的参数字符串
function runShell(script, args) {
    const list = args ? String(args).split(/\s+/).filter(Boolean) : [];
    return runShellArgs(script, list);
}

// 执行非脚本命令(如 mount/umount)
function runCommand(command) {
    const quoted = String(command).split(/\s+/).filter(Boolean).map(shellQuote).join(" ");
    return exec(`sh "${scripts_path}/run.sh" ${quoted}`);
}

// 统一去掉 stdout/stderr 末尾的换行
// 有些管理器返回的 stdout 带 \n，直接和 "已运行" 比较会永远不相等
function out(result) {
    return String((result && result.stdout) || "").trim();
}

function err(result) {
    return String((result && result.stderr) || "").trim();
}

// 获取服务状态
function getServiceStatus(id, status) {
    const control = document.getElementById(id);
    if (!control) return;
    control.textContent = status;
    if ( status == "已运行" || status == "已挂载" ) {
        control.classList.remove('status-inactive');
        control.classList.add('status-active');
    } else {
        control.classList.remove('status-active');
        control.classList.add('status-inactive');
    }
}

// 解析 KEY=VALUE 形式的输出
function parseKeyValues(text) {
    const result = {};
    String(text || "").split(/\n?\n/).forEach(line => {
        if (!line) return;
        const pos = line.indexOf("=");
        if (pos > 0) result[line.slice(0, pos)] = line.slice(pos + 1);
    });
    return result;
}

// 最近一次状态快照，启动/停止后直接复用，省掉两次脚本调用
let lastStatus = {};

// 更新服务状态：一次 allstatus 拿到全部状态
async function updateServiceStatus() {
    const status = parseKeyValues(out(await runShell("webui.sh", "allstatus")));
    lastStatus = status;

    getServiceStatus("smartdns-status", status.smartdns || "未运行");
    const aghConfigBad = status.agh_config === "bad";
    getServiceStatus("agh-status", aghConfigBad ? "配置错误" : (status.agh || "未运行"));
    getServiceStatus("mihomo-status", status.mihomo || "未运行");
    getServiceStatus("host-mount-status", status.host || "未挂载");

    // 当前是否处于直通模式
    const bypassBadge = document.getElementById("bypass-badge");
    if (bypassBadge) {
        const bypassOn = status.bypass === "true";
        bypassBadge.textContent = bypassOn ? "直通模式" : "过滤模式";
        bypassBadge.classList.toggle("bypass-on", bypassOn);
        bypassBadge.classList.toggle("bypass-off", !bypassOn);
    }

    // 待激活更新：出现这个标记时，KernelSU 模块页显示的是 modules_update 里的新包，
    // WebUI 仍由旧 active 模块提供服务，需要完整重启或工具页「激活模块」
    const pendingBadge = document.getElementById("pending-update-badge");
    if (pendingBadge) {
        pendingBadge.hidden = status.pending_update !== "yes";
    }

    // 显示 module.prop 里实际写入的描述，用来区分"没写成"和"管理器缓存"
    const moduleDescStatus = document.getElementById("module-desc-status");
    if (moduleDescStatus) {
        const moduleDesc = String(status.module_desc || "").trim() || "未知";
        const descRunning = moduleDesc.indexOf("已运行") >= 0;
        moduleDescStatus.textContent = moduleDesc;
        moduleDescStatus.classList.toggle("status-active", descRunning);
        moduleDescStatus.classList.toggle("status-inactive", !descRunning);
    }

    // AGH 配置校验状态
    const aghConfigStatus = document.getElementById("agh-config-status");
    if (aghConfigStatus) {
        aghConfigStatus.textContent = aghConfigBad ? "校验失败(已暂停自动拉起)" : "正常";
        aghConfigStatus.classList.toggle("status-active", !aghConfigBad);
        aghConfigStatus.classList.toggle("status-inactive", aghConfigBad);
    }

    const host_mount_action = document.getElementById("host-mount-action");
    if (host_mount_action) {
        if ( status.host == "已挂载" ) {
            host_mount_action.classList.add('disable');
            host_mount_action.textContent = "禁用";
        } else {
            host_mount_action.classList.remove('disable');
            host_mount_action.textContent = "启用";
        }
    }

    updateMonitorStatus("wifi", status);
    updateMonitorStatus("host", status);
    updateMonitorStatus("module", status);

    updateHealthStatus(status);
}

// 更新健康状态(守护循环 + DNS 规则)
function updateHealthStatus(status) {
    const watchdog_status = document.getElementById("watchdog-status");
    if (watchdog_status) {
        const running = status.watchdog === "运行中";
        watchdog_status.textContent = running ? "运行中" : "未运行";
        watchdog_status.classList.toggle("status-active", running);
        watchdog_status.classList.toggle("status-inactive", !running);
    }

    const dns_status = document.getElementById("dns-rule-status");
    if (dns_status) {
        const ok = status.dns_rule === "正常" || status.dns_rule === "直通模式";
        dns_status.textContent = ok ? status.dns_rule : "异常";
        dns_status.classList.toggle("status-active", ok);
        dns_status.classList.toggle("status-inactive", !ok);
    }
}

// 更新监控状态(数据来自同一次 allstatus)
function updateMonitorStatus(value, status) {
    const monitor_status = document.getElementById(value + "-monitor-status");
    const monitor_action = document.getElementById(value + "-monitor-action");
    const pid_box = document.getElementById(value + "-monitor-pid");
    if (!monitor_status || !monitor_action) return;

    const running = status["monitor_" + value] === "已运行";
    const pid = status["monitor_" + value + "_pid"] || "";

    const hint = value == "module"
        ? " | 监听模块开关，模块启用则运行程序，模块禁用则停止程序"
        : value == "wifi"
            ? " | 监听已连接 WIFI，在黑名单内则停止服务，反之启动"
            : " | 监听 hosts 文件，修改文件实时生效";

    if (pid_box) {
        pid_box.textContent = "PID: " + (running ? pid : "null") + hint;
    }

    monitor_status.textContent = running ? "已运行" : "未运行";
    monitor_status.classList.toggle('status-active', running);
    monitor_status.classList.toggle('status-inactive', !running);
    monitor_action.classList.toggle('disable', running);
    monitor_action.textContent = running ? "禁用" : "启用";
}

/* ---------------- 设置页 ---------------- */

// 解析 setting_api.sh get 的输出
function parseSettingOutput(text) {
    const values = {};
    const arrays = {};

    String(text || "").split(/\n?\n/).forEach(line => {
        if (!line) return;

        let match = line.match(/^([A-Z0-9_]+)\[count\]=(\d+)$/);
        if (match) {
            arrays[match[1]] = [];
            return;
        }

        match = line.match(/^([A-Z0-9_]+)\[(\d+)\]=(.*)$/);
        if (match) {
            const key = match[1];
            if (!arrays[key]) arrays[key] = [];
            arrays[key][Number(match[2])] = match[3];
            return;
        }

        const pos = line.indexOf("=");
        if (pos > 0) {
            values[line.slice(0, pos)] = line.slice(pos + 1);
        }
    });

    return { values: values, arrays: arrays };
}

// 读取设置并填到表单
async function loadSettings(silent) {
    const result = await runShell("setting_api.sh", "get");
    const parsed = parseSettingOutput(result.stdout);

    document.querySelectorAll("[data-key]").forEach(el => {
        const key = el.dataset.key;

        if (key === "SUB_URL" || key === "BLACKLIST_WIFI") {
            const list = (parsed.arrays[key] || []).filter(v => v !== undefined);
            el.value = list.join("\n");
        } else if (el.type === "checkbox") {
            el.checked = parsed.values[key] === "true";
        } else {
            el.value = parsed.values[key] !== undefined ? parsed.values[key] : "";
        }
    });

    if (!silent) showToast("设置已加载");
    syncWhitelistMode();
    labelSettingsControls();
    setSettingsDirty(false);
}

// 白名单开关关闭时，"白名单模式"没有意义，置灰避免误改
function syncWhitelistMode() {
    const toggle = document.querySelector('[data-key="ENABLE_WHITELIST"]');
    const mode = document.querySelector('[data-key="WHITELIST_MODE"]');
    if (!toggle || !mode) return;

    mode.disabled = !toggle.checked;
    mode.style.opacity = toggle.checked ? "1" : "0.45";
}

// 未保存提示
function setSettingsDirty(dirty) {
    const badge = document.getElementById("setting-dirty");
    if (badge) badge.hidden = !dirty;
}

// 给控件补 aria-label，方便读屏
function labelSettingsControls() {
    document.querySelectorAll("[data-key]").forEach(el => {
        if (el.getAttribute("aria-label")) return;
        const row = el.closest(".setting-row") || el.closest(".setting-block");
        const title = row ? row.querySelector("h4") : null;
        if (title) el.setAttribute("aria-label", title.textContent.trim());
    });
}

// 查看日志
async function refreshLog() {
    const view = document.getElementById("log-view");
    if (!view) return;
    view.textContent = "加载中...";
    const result = await runShell("setting_api.sh", "logview 150");
    view.textContent = out(result) || "(暂无日志)";
    view.scrollTop = view.scrollHeight;
}

// 展示广告屏蔽的影响范围
async function showAdScope() {
    const view = document.getElementById("ad-list-view");
    if (!view) return;

    // 再点一次收起
    if (!view.hidden) {
        view.hidden = true;
        return;
    }

    view.hidden = false;
    view.textContent = "读取中...";

    const newline = String.fromCharCode(10);
    const result = await runShell("ad.sh", "list");
    const lines = out(result).split(newline).filter(line => line.length > 0);
    if (lines.length === 0) {
        view.textContent = "未读取到列表";
        return;
    }

    const counter = {};
    const groups = {};
    let hold_total = 0;

    lines.forEach(line => {
        const parts = line.split("|");
        if (parts.length < 3) return;
        if (parts[0] === "APP") return;
        const appName = parts[0];
        const itemPath = parts[1];
        const itemState = parts[2];
        const itemSize = parts.length > 3 ? parts[3] : "0";
        if (counter[itemState] === undefined) counter[itemState] = 0;
        counter[itemState]++;
        const sizeNum = parseInt(itemSize, 10) || 0;
        if (sizeNum > 0) hold_total += sizeNum;
        if (!groups[appName]) groups[appName] = [];
        const sizeText = sizeNum > 0 ? "  [" + sizeNum + " KB]" : "";
        groups[appName].push(itemState + sizeText + "  " + itemPath);
    });

    // 汇总: 备份总量 + 各项状态计数
    let text = "";
    if (hold_total > 0) {
        text += "已保留备份 " + hold_total + " KB(屏蔽时不再删除数据, 恢复后原样还原)" + newline;
    }
    Object.keys(counter).forEach(state => {
        text += state + " " + counter[state] + " 项  ";
    });
    text += newline;
    Object.keys(groups).forEach(appName => {
        text += newline + "【" + appName + "】" + newline + groups[appName].join(newline) + newline;
    });

    view.textContent = text;
}

// 清空日志
async function clearLog() {
    await runShell("setting_api.sh", "clearlog");
    const view = document.getElementById("log-view");
    if (view) view.textContent = "(日志已清空)";
    showToast("日志已清空");
}

// 多行文本 -> 数组
function splitLines(text) {
    return String(text || "")
        .split(/\n?\n/)
        .map(v => v.trim())
        .filter(v => v.length > 0);
}

// 保存并应用
async function saveSettings() {
    if (savingSettings) {
        showToast("正在保存中，请稍候", 3000);
        return;
    }

    const scalars = [];
    const arrays = [];
    let invalid = "";

    document.querySelectorAll("[data-key]").forEach(el => {
        const key = el.dataset.key;

        if (key === "SUB_URL" || key === "BLACKLIST_WIFI") {
            arrays.push({ key: key, values: splitLines(el.value) });
            return;
        }

        if (el.type === "checkbox") {
            scalars.push(key + "=" + (el.checked ? "true" : "false"));
            return;
        }

        const value = String(el.value).trim();

        // 端口必须是 1-65535 的数字
        if (el.type === "number") {
            const port = Number(value);
            if (!value || !/^[0-9]+$/.test(value) || port < 1 || port > 65535) {
                invalid = key + " 必须是 1-65535 之间的数字";
                return;
            }
        }

        scalars.push(key + "=" + value);
    });

    if (invalid) {
        showToast("保存失败: " + invalid, 5000);
        return;
    }

    savingSettings = true;
    const saveBtn = document.querySelector('.save-setting');
    const saveBtnText = saveBtn ? saveBtn.textContent : "";
    if (saveBtn) {
        saveBtn.disabled = true;
        saveBtn.textContent = "保存中...";
    }

    try {
        toast("正在保存配置......");
        const setResult = await runShellArgs("setting_api.sh", ["set"].concat(scalars));
        if (err(setResult)) {
            showToast("保存失败: " + err(setResult), 6000);
            return;
        }

        for (let i = 0; i < arrays.length; i++) {
            const item = arrays[i];
            const arrResult = await runShellArgs("setting_api.sh", ["setarr", item.key].concat(item.values));
            if (err(arrResult)) {
                showToast("保存失败: " + err(arrResult), 6000);
                return;
            }
        }

        toast("正在应用配置，请稍等......");
        const applyResult = await runShell("setting_api.sh", "apply");
        await updateServiceStatus();
        setSettingsDirty(false);
        showToast(out(applyResult) || "已保存并应用", 4000);
    } finally {
        savingSettings = false;
        if (saveBtn) {
            saveBtn.disabled = false;
            saveBtn.textContent = saveBtnText || "保存并应用";
        }
    }
}

// ---- 工具页 ----

// 执行工具按钮对应的脚本命令，并把输出回显到页面
async function runToolButton(button) {
    const view = document.getElementById("tool-output");
    const script = button.dataset.script;
    const args = button.dataset.args || "";
    const originalText = button.textContent;
    const header = "执行: " + script + (args ? " " + args : "");

    button.disabled = true;
    button.textContent = "执行中...";
    if (view) view.textContent = header + newlineChar() + "请稍等...";

    try {
        const result = await runShell(script, args);
        const parts = [];
        if (out(result)) parts.push(out(result));
        if (err(result)) parts.push("[stderr] " + err(result));
        const text = parts.join(newlineChar());

        if (view) {
            view.textContent = header + newlineChar() + newlineChar() + (text || "(无输出)");
            view.scrollTop = 0;
        }
        showToast(text ? "执行完成" : "执行完成(无输出)", 3000);
        await updateServiceStatus();
    } catch (error) {
        if (view) view.textContent = header + newlineChar() + "执行失败: " + error;
        showToast("执行失败", 5000);
    } finally {
        button.disabled = false;
        button.textContent = originalText;
    }
}

// 换行符: 避免在 JS 源码里写转义序列
function newlineChar() {
    return String.fromCharCode(10);
}

// 危险操作需要二次点击确认
function initToolButtons() {
    document.querySelectorAll(".tool-btn").forEach(button => {
        let armed = false;
        let timer = null;
        const originalText = button.textContent;

        button.addEventListener("click", () => {
            if (button.dataset.confirm === "1" && !armed) {
                armed = true;
                button.textContent = "再点一次确认";
                showToast("再次点击执行：" + originalText, 4000);
                timer = setTimeout(() => {
                    armed = false;
                    button.textContent = originalText;
                }, 4000);
                return;
            }

            clearTimeout(timer);
            armed = false;
            button.textContent = originalText;
            runToolButton(button);
        });
    });

    // 监控页的「重建 DNS 规则」按钮
    const dns_rule_action = document.getElementById("dns-rule-action");
    if (dns_rule_action) {
        dns_rule_action.addEventListener("click", async () => {
            dns_rule_action.disabled = true;
            dns_rule_action.textContent = "重建中...";
            try {
                await runShellArgs("iptables/dns.sh", ["enable"]);
                showToast("DNS 规则已重建", 3000);
                await updateServiceStatus();
            } catch (error) {
                showToast("重建失败: " + error, 5000);
            } finally {
                dns_rule_action.disabled = false;
                dns_rule_action.textContent = "重建";
            }
        });
    }
}

// 页面导航功能
function pageNavigation() {
    const navItems = document.querySelectorAll('.nav-item');
    const pages = document.querySelectorAll('.page');

    navItems.forEach(item => {
        item.addEventListener('click', function() {
            const targetPageId = this.getAttribute('data-page');

            // 更新导航状态
            navItems.forEach(nav => nav.classList.remove('active'));
            this.classList.add('active');

            // 更新页面显示
            pages.forEach(page => {
                page.classList.remove('active');
                if (page.id === targetPageId) {
                    page.classList.add('active');
                }
            });

            // 进入设置页时重新读取，反映当前真实配置
            if (targetPageId === "setting-page") {
                loadSettings(true);
            }
        });
    });
}

// 服务控制功能
async function serviceControls(text, cmd) {
    if (serviceActionBusy) {
        showToast("服务操作进行中，请稍候", 2000);
        return;
    }
    serviceActionBusy = true;
    try {
        toast(`正在${text}，请稍等......`);
        await runShell("service.sh", cmd);
        await updateServiceStatus();
        var outNumber = parseInt(lastStatus.process, 10) || 0;
        var serNumber = parseInt(lastStatus.service, 10) || 0;
        if ( outNumber < serNumber && ( cmd == "start" || cmd == "restart" )) {
            showToast(text+"失败(部分服务未起来)", 5000);
        } else if ( outNumber == serNumber && ( cmd == "start" || cmd == "restart" )) {
            showToast(text+"成功");
        } else if ( outNumber > 0 && cmd == "stop" ) {
            showToast(text+"失败(仍有进程在运行)", 5000);
        } else if ( outNumber == 0 && cmd == "stop" ) {
            showToast(text+"成功");
        }
    } finally {
        serviceActionBusy = false;
    }
}

// 挂载控制
// 挂载状态必须与 HOST_ENABLE 保持一致，否则下次启动服务会被设置重新挂回去
async function mountControls(){
    if (mountActionBusy) {
        showToast("挂载操作进行中，请稍候", 2000);
        return;
    }
    mountActionBusy = true;
    try {
        const hostMountStatus = document.getElementById("host-mount-status");
        var host_mount_status = await runShell("webui.sh", "mount");
        if ( out(host_mount_status) == "已挂载" ) {
            const saved = await runShellArgs("setting_api.sh", ["set", "HOST_ENABLE=false"]);
            if (err(saved)) {
                showToast("保存设置失败: " + err(saved), 6000);
                return;
            }
            await runCommand("umount /system/etc/hosts");
            showToast(`Host 未挂载`);
        } else {
            const saved = await runShellArgs("setting_api.sh", ["set", "HOST_ENABLE=true"]);
            if (err(saved)) {
                showToast("保存设置失败: " + err(saved), 6000);
                return;
            }
            await runCommand(`mount -o bind ${module_path}/etc/hosts /system/etc/hosts`);
            showToast(`Host 已挂载`);
        }
        await updateServiceStatus();
    } finally {
        mountActionBusy = false;
    }
}

// 监控控制
async function monitorControls(text) {
    if (monitorActionBusy) {
        showToast("监控操作进行中，请稍候", 2000);
        return;
    }
    monitorActionBusy = true;
    try {
        var pid_status = await runShell("webui.sh", `monitor ${text}`);
        if ( out(pid_status) == "已运行" ) {
            await runShell("webui.sh", `kill ${text}`);
            showToast(text == "module" ? "模块未监控" : text == "wifi" ? "WIFI未监控" : "host未监控");
        } else {
            await runShell("webui.sh", `start ${text}`);
            showToast(text == "module" ? "模块已监控" : text == "wifi" ? "WIFI已监控" : "host已监控");
        }
        await updateServiceStatus();
    } finally {
        monitorActionBusy = false;
    }
}

// 软重启后恢复运行
async function resumeModule() {
    toast("正在恢复运行，请稍等......");
    await runShell("manual.sh", "resume");
    await updateServiceStatus();
    showToast("恢复完成");
}

// 立即卸载
// 不用 window.confirm: 部分 WebView 里 confirm 会被禁用或返回 false，
// 表现为"点了没反应"。改为按钮二次确认(见绑定处)。
async function uninstallModule() {
    toast("正在卸载，请稍等......");
    const result = await runShell("manual.sh", "uninstall");
    const message = err(result);
    if (message) {
        showToast("卸载失败: " + message, 6000);
        return;
    }
    showToast("已卸载，可关闭此页面", 6000);
}

(async () => {
    // 全屏
    fullScreen(true);

    // 消息提示功能
    const toastBox = document.getElementById('toast');
    let toastTimer = null;
    window.showToast = function(message, duration) {
        if (!toastBox) return;
        toastBox.textContent = message;
        toastBox.classList.add('show');
        clearTimeout(toastTimer);
        // 错误信息默认显示更久
        toastTimer = setTimeout(() => toastBox.classList.remove('show'), duration || 2500);
    };

    // 页面导航
    pageNavigation();

    // 工具页按钮
    initToolButtons();

    // 更新服务状态
    await updateServiceStatus();

    // 预填设置页(失败不影响其他功能)
    await loadSettings(true).catch(() => {});

    // 启动点击事件
    const startBtn = document.querySelector('.start-service');
    if (startBtn) {
        startBtn.addEventListener('click', () => {
            serviceControls("启动","start");
        });
    }

    // 停止点击事件
    const stopBtn = document.querySelector('.stop-service');
    if (stopBtn) {
        stopBtn.addEventListener('click', () => {
            serviceControls("停止","stop");
        });
    }

    // 重启点击事件
    const restartBtn = document.querySelector('.restart-service');
    if (restartBtn) {
        restartBtn.addEventListener('click', () => {
            serviceControls("重启","restart");
        });
    }

    // 软重启后恢复
    const resumeBtn = document.querySelector('.resume-service');
    if (resumeBtn) {
        resumeBtn.addEventListener('click', () => {
            resumeModule();
        });
    }

    // 立即卸载: 二次确认，不依赖 window.confirm
    const uninstallBtn = document.querySelector('.uninstall-service');
    if (uninstallBtn) {
        let uninstallArmed = false;
        let uninstallTimer = null;

        uninstallBtn.addEventListener('click', () => {
            if (!uninstallArmed) {
                uninstallArmed = true;
                uninstallBtn.textContent = "再点一次确认卸载";
                showToast("再次点击将立即删除模块目录", 4000);
                uninstallTimer = setTimeout(() => {
                    uninstallArmed = false;
                    uninstallBtn.textContent = "立即卸载";
                }, 4000);
                return;
            }

            clearTimeout(uninstallTimer);
            uninstallArmed = false;
            uninstallBtn.textContent = "立即卸载";
            uninstallModule();
        });
    }

    // 设置页按钮
    const saveSettingBtn = document.querySelector('.save-setting');
    if (saveSettingBtn) {
        saveSettingBtn.addEventListener('click', () => {
            saveSettings();
        });
    }

    const reloadSettingBtn = document.querySelector('.reload-setting');
    if (reloadSettingBtn) {
        reloadSettingBtn.addEventListener('click', () => {
            loadSettings(false);
        });
    }

    // 白名单开关联动: 关闭时把"白名单模式"置灰
    const whitelistToggle = document.querySelector('[data-key="ENABLE_WHITELIST"]');
    if (whitelistToggle) {
        whitelistToggle.addEventListener('change', syncWhitelistMode);
    }

    // 设置页: 改动即标记未保存；分区可折叠
    const settingPage = document.getElementById("setting-page");
    if (settingPage) {
        settingPage.addEventListener("input", () => setSettingsDirty(true));
        settingPage.addEventListener("change", () => setSettingsDirty(true));

        settingPage.querySelectorAll(".content-section h3").forEach(title => {
            const toggleSection = () => {
                const section = title.parentElement;
                if (section) section.classList.toggle("collapsed");
            };

            title.setAttribute("role", "button");
            title.setAttribute("tabindex", "0");
            title.addEventListener("click", toggleSection);
            title.addEventListener("keydown", event => {
                if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    toggleSection();
                }
            });
        });
    }

    // 日志面板
    const logRefreshBtn = document.getElementById("log-refresh");
    if (logRefreshBtn) {
        logRefreshBtn.addEventListener("click", refreshLog);
    }
    const logClearBtn = document.getElementById("log-clear");
    if (logClearBtn) {
        logClearBtn.addEventListener("click", clearLog);
    }

    const adListBtn = document.getElementById("ad-list-btn");
    if (adListBtn) {
        adListBtn.addEventListener("click", showAdScope);
    }

    // host 挂载按钮点击事件
    const hostMountAction = document.getElementById("host-mount-action");
    if (hostMountAction) {
        hostMountAction.addEventListener('click', () => {
            mountControls();
        });
    }

    // 模块目录监控点击事件
    const module_monitor_action = document.getElementById("module-monitor-action");
    if (module_monitor_action) {
        module_monitor_action.addEventListener('click', () => {
            monitorControls("module");
        });
    }

    // hosts文件监控点击事件
    const host_monitor_action = document.getElementById("host-monitor-action");
    if (host_monitor_action) {
        host_monitor_action.addEventListener('click', () => {
            monitorControls("host");
        });
    }

    // wifi监控点击事件
    const wifi_monitor_action = document.getElementById("wifi-monitor-action");
    if (wifi_monitor_action) {
        wifi_monitor_action.addEventListener('click', () => {
            monitorControls("wifi");
        });
    }

})().catch((err) => 'null')
