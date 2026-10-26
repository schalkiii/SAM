# SAM
SAM 是 SmartDNS、AdGuardHome 和 Mihomo 三合一的 Magisk 模块。每一个服务都可以单独使用，或者两两组合，或者全部启用。

## 📖说明
- SmartDNS 的优先级最低，在无启用其它服务的情况下，才会作为本机的 DNS 转发服务，在有两种和三种服务启用，只会作为上游 DNS。
- AdGuardHome 在单独启用和 SmartDNS 一起使用，都会作为本机的 DNS 转发服务，再和 Mihomo 三种一起用，就根据设置文件的配置，来选择使用哪种结构。
- Mihomo 在单独使用，或者和另一种服务使用，都会作为本机的 DNS 转发服务。 

## 🧩 本 fork 增强
在原作者 [5MayRain/SAM](https://github.com/5MayRain/SAM) 基础上增加：

- **WebUI 设置页**：直通开关、DNS 结构模式、服务开关、端口、TUN、订阅与黑白名单等可直接改
- **直通模式**：临时撤销 DNS 劫持并暂停 Mihomo（TUN 仍会劫持 DNS），适合校园网、认证热点；仅切换直通时只改 DNS 劫持规则、不重启 AGH/SmartDNS，缓存与统计保留；WebUI 保存直通开关立即生效，守护循环也会在 5 秒内校正规则
- **免重启运维**：临时 root / 只能软重启环境使用 `sh scripts/manual.sh activate|resume|uninstall`
- **启动降级**：三服务优先用 `busybox setuidgid` 指定用户/组；缺少该 applet 时以 root 启动并在 `module.log` 记录，避免临时 root 下三服务一起静默失败
- **服务页语义明确**：启动/停止/重启全部服务；「软重启后恢复」会额外重挂 hosts、启动监控并按设置刷新网络；存在待激活包时按钮自动变为「激活并恢复新版」，不会再恢复旧版
- **DNS 入口可见**：监控页显示当前 53 端口实际转发到的服务与端口，区分「DNS 规则正常」和「查询真的经过模块」
- **守护循环**：进程掉线自动拉起、iptables 规则被清自动重建、日志 100KB 轮转（服务存活 5 秒检查，规则 10 秒）；服务恢复后只在 DNS 入口真正变化时才重写下游上游并重启，同名端口恢复不重启 AGH/Mihomo（缓存与统计保留）；只有服务全部恢复且距离上次自动刷新超过 10 分钟时才刷新网络，避免服务反复掉线时反复开关 WiFi
- **守护自愈**：`scripts/supervisor.sh` 专盯 watchdog 存活（不在就 30 秒内重新拉起），KernelSU 下由 `initrc/sam.rc` 交给 init 托管——服务与 watchdog 被外力整组 SIGKILL 时也能恢复；进程启动时 best-effort 迁出调用方 cgroup（`oom_score_adj=-1000` 挡不住 cgroup 整组 kill）
- **配置安全加载**：`setting.conf` 出现 BOM / CRLF / 语法错误仍能启动，坏行单独跳过
- **全量配置备份**：卸载/更新/恢复前自动备份到 `/data/adb/SAM-backup/<时间>/`（root-only，含 AGH/SmartDNS/Mihomo 用户数据目录、crontabs 与广告屏蔽清单；任一复制失败会返回失败并保留清单，避免假备份）。备份带完成标记，`list`/`restore` 只认完整备份；`restore` 前会先自动留存一份当前配置快照，还原可回退；守护循环每天自动备份一次
- **定时任务 WebUI**：工具页「定时任务」卡片可直接编辑 `/etc/crontabs/root`（一行一条，保存时逐行校验时间字段），busybox crond 下一分钟自动生效，无需重启服务
- **默认仅回环监听**：AGH 面板/DNS、SmartDNS、Mihomo 控制台与代理端口默认只听 127.0.0.1；需要局域网使用时打开「允许局域网访问」，仅开放 AGH 面板/DNS 与 SmartDNS DNS，Mihomo 控制台与代理端口始终保持本机
- **组件安全更新**：先停服务再替换，自检失败自动回滚，下载有超时；缺 curl 的设备自动退回 wget
- **工具页**：WebUI 工具页的按钮直接调用 `manual.sh` / `backup.sh` / `ad.sh` / `update.sh` 等脚本命令
- **打包校验**：`python tools/pack_module.py` 强制 LF、写权限位、CRC、`mksh -n` 校验；`.gitattributes` 保证 Windows 检出也是 LF
- **一键诊断**：WebUI「工具 → 一键诊断」或 `scripts/diagnose.sh` 只读采集服务、端口、AGH 配置校验、防火墙、DNS、MTU 与 IPv6 阻断方式/计数
- **AGH 配置恢复**：`--check-config` 失败会暂停自动拉起并区分 YAML / schema / 编码原因；schema 不兼容时可从工具页「重置 AGH 配置」恢复内置模板（先完整备份）
- **IPv6 DNS 快速回退**：阻断优先用 `REJECT`（UDP `icmp6-port-unreachable`、TCP `tcp-reset`），让解析器立即回退 IPv4；内核不支持时记录并回退 `DROP`
- **Mihomo 默认关闭**：没有订阅地址时它本身也起不来；需要代理时在设置里开启并填写订阅
- **广告过滤加入 GOODBYEADS 规则集与其放行列表**（AdGuardHome 侧）
- **广告屏蔽可逆**：屏蔽时把 App 广告缓存目录改名保留并锁定，屏蔽效果与清空相同但数据不丢，随时可原样还原；关闭开关会自动恢复；已卸载 App 的锁定会在启动/每 5 分钟自动解除
- **缓存只留一层**：AdGuardHome 自身不缓存，缓存由上游 SmartDNS 独占，避免双份内存并保留其测速选优能力

> 本 fork 的 `updateJson` 指向本仓库，不再跟随上游自动更新。

## ⚠️ 当前已知问题与发布状态

- 线上最新 Release 为 **v20261026.1**：服务与 watchdog 整组消失的恢复能力（`supervisor.sh` + KernelSU `initrc` 托管 + cgroup 迁出）与 auto-stop 取证增补（uptime / cgroup / 其他模块进程 / `am_kill`）；十二套件 423 项全部通过。刷入后可免重启激活（模块管理器安装后自动执行，或「工具 → 激活待更新版本」），激活时 `service.sh start` 会兜底拉起 supervisor、cgroup 迁出即时生效；只有 `initrc` 托管需要下次完整重启（KernelSU 可先试 `ksud initrc refresh`）。
- 逐版变更、历史修复与已知问题的处理记录只维护在 [changelog.md](changelog.md)。本段不重复版本叙事，避免与 changelog 二次维护后漂移。

## ⚙️功能
- 两种服务结构:
  - `SmartDNS > Mihomo > AdGuardHome`
  - `SmartDNS > AdGuardHome > Mihomo`
- 监听:
  - 模块:
    - 启用即运行，禁用即停止
    - 卸载备份配置，恢复拦截广告
  - hosts:
    - 修改实时生效
- 黑名单 WIFI 配置
- 黑白名单代理 App 配置
- 定时执行（出厂任务默认注释：自动更新组件与每日重启需在工具页「定时任务」里自行取消注释）

## 📢注意
- 禁止和其它同类型模块使用
- 模块所有服务的账号为 `root`，默认密码 `root`（AGH 与 SmartDNS 面板一致；重置 AGH 配置后同样恢复为该默认密码）。**改密码**：AGH 在面板「设置 → 常规设置」里改；SmartDNS 面板改 `etc/SmartDNS/smartdns.conf` 的 `smartdns-ui.password` 后重启服务。开启「允许局域网访问」前请先改密码
- SmartDNS 面板的登录令牌默认 30 天（`smartdns-ui.token-expire 2592000` 秒），令牌存在浏览器 localStorage，所以正常不会每次打开都要登录；若把面板开放到局域网，建议缩回 600-3600 秒
- 刷入新版本后需**完整重启**，或使用「工具 → 激活待更新版本」/ 服务页「激活并恢复新版」（等价于 `manual.sh resume`，检测到待激活包会先激活）；**软重启本身不会激活 `modules_update` 里的新包**。未激活时 KernelSU 模块列表显示的是待激活包，WebUI 仍由旧版本提供服务
- WebUI 服务页出现「待激活更新」徽章时，说明新包还没激活；此时服务页按钮会变为「激活并恢复新版」，点击会先激活再恢复。监控页「模块描述」显示的是 `module.prop` 里的实际值
- 如果 KernelSU 模块描述仍是旧状态，先确认 `cat /data/adb/modules/SAM/module.prop` 的 `description`，再返回/刷新模块页；管理器会缓存上次读取的模块列表
- 广告屏蔽会对目录设置 immutable（`chattr +i`），可能阻止系统卸载时清理 App 数据；卸载 App 前建议先在「工具」页执行「恢复广告文件」。如果直接卸载，模块会在启动和每 5 分钟自动解除已卸载 App 的锁定（默认保留 `.samhold` 备份）；系统卸载当下仍可能提示删除数据失败，可用工具页「清理已卸载 App 及备份」删除孤儿备份
- hosts 更新默认 24 小时节流；工具页的「更新 hosts」与每周定时任务会强制刷新
- AGH 大版本升级会迁移配置 schema；回退旧二进制后若报 `unknown current schema version`，用「工具 → 重置 AGH 配置」恢复模板（会先完整备份并保留单文件副本，但会丢失面板密码与自定义过滤规则）
- 禁止该文件随意修改
  - /data/adb/modules/SAM/etc/mihomo/base.yaml

## 临时 root / 只能软重启：免重启激活与恢复

KernelSU/Magisk 的升级包通常先进入 `/data/adb/modules_update/SAM`，正常需要下一次完整开机的 `post-fs-data` 才会合并；普通软重启不一定激活，部分新版 KSU 的模拟软重启还可能触发更新/回滚，所以模块列表偶尔会“消失”。

本模块支持免重启处理：

- **安装后自动激活**：在已启动的 Android 中刷入后，安装器会延迟数秒自动执行一次免重启激活，无需 WebUI、无需手动传参。日志在 `/data/adb/SAM-activate.log`。
- `sh /data/adb/SAM-activate.sh activate`：立即激活 `modules_update` 中的新包。
- `sh /data/adb/SAM-activate.sh repair`：模块目录丢失/损坏时，按 `active -> modules_update -> /data/adb/SAM.previous` 自动恢复。
- WebUI「工具 → 修复 / 免重启激活」执行同一逻辑。

激活会先校验模块结构，保留上一版到 `/data/adb/SAM.previous`，失败自动回滚；只有成功后才删除 `modules_update`。安装器还会在 `/data/adb/SAM-activate.sh` 留下模块外恢复入口，避免 active 目录消失后无法自救。

## 日志与取证（一次性取全）

排查时不需要在 WebUI 里逐个按钮运行再分段复制。运行一次
`sh /data/adb/modules/SAM/scripts/collect.sh`（或 WebUI「工具 → 日志取证 → 一键收集日志」），
它会把同一时刻的所有证据写进一个报告：

- `tmp/module.log`、`module.log.1`、`module.log.boot.1`（三代完整）
- `tmp/auto-stop.*.log`、`service.state`、`service.abnormal`、`boot.count`、`watchdog.heartbeat`
- SmartDNS / AdGuardHome / Mihomo 自身日志尾部
- `diagnose.sh` 全量只读输出
- 相关进程与 cgroup、iptables/ip6tables 链与监听端口
- `dmesg` 的 OOM 记录、`logcat -b events` 的 `am_kill`、deviceidle 白名单

报告固定写在 `/data/adb/SAM-debug/SAM-report-<时间>.txt`（root-only，保留最近 10 份，
`collect.sh list` 查看）。手机端不方便读 `/data` 时用「导出报告到下载目录」或
`sh collect.sh share`，它会在 `/sdcard/Download` 再复制一份——报告含订阅链接、节点地址与
查询日志，发送前确认接收方与渠道。

日志文件的职责分工：`tmp/module.log` 是模块自身事件（含 SERVICE-EVENT/ERROR）；
`tmp/smartdns.out`/`smartdns.log`、`tmp/AdGuardHome.log`、`tmp/mihomo.log` 是服务自己吐的
输出；`tmp/auto-stop.<bin>.<时间>.log` 是 watchdog 发现服务异常消失时的现场快照；
`/data/adb/SAM-activate.log` 是安装后自动激活的日志。

## 服务过一段时间自动停止

先看一个判据：**模块自身的停止路径一定会留痕**。`service.sh stop`（含 WebUI 按钮、WiFi 黑名单、
定时重启）会写 `stop requested` + `stop complete`；禁用/卸载监控会先走 `service.sh stop`；
`sd.sh/agh.sh/mihomo.sh stop` 会写“停止成功”。所以「三服务 + watchdog 在同一窗口消失、
`module.log` 里没有任何事件、`service.state` 仍是 `running`」只可能来自**模块外的整组 SIGKILL**，
不是模块自己停的。

排查顺序：

1. 跑 `sh scripts/diagnose.sh --auto-stop`（root，或 WebUI「工具 → 自动停止分析」）。
   - 「系统框架已重启（boot_count 变化）」：**软重启**。软重启不执行模块开机脚本，watchdog 与服务
     一起被杀，属正常现象，用服务页「软重启后恢复」即可。
   - 「定向 kill」：只有服务与 watchdog 消失，crond / inotifyd / WiFi 监控还在 → 按进程名/脚本名做的
     kill（其它 root 清理类 App、其它模块、单条 kill 脚本），重点排查 fellow root 工具。
   - 「整组清理」：所有模块进程一起消失且 boot_count 未变 → 应用 cgroup 被整组 kill 或厂商强杀。
   - 「模块主动停止」：`service.state` 是 `stopped`（或 `stopped-by-wifi`），看最后一条 SERVICE-EVENT 定位。
2. 看诊断里的「其他模块进程 / cgroup」两段：进程若在 `uid_10xxx`（应用组）里，就会被清理后台连带杀死；
   在 `system` 组则不会。本版已把进程 best-effort 迁到 `system`，`tmp/module.log` 里有
   `cgroup: pid=... -> ...` 或 `迁出失败` 记录。
3. 看 `tmp/auto-stop.*.log`（诊断会完整打印）与 `logcat -b events` 的 `am_kill` Reason。
   注意：模块进程不是 App 进程，AMS 通常不记录；**没有记录不等于没被杀**。
4. 恢复不再依赖手动操作：`scripts/supervisor.sh` 每 30 秒确认 watchdog 存活，KernelSU 下由
   `initrc/sam.rc` 交给 init 托管（被强杀后 init 会重新拉起）。若诊断里 `supervisor` 也显示「未运行」
   且长期如此，说明你的管理器没有加载 initrc，可在 root shell 里确认 `ksud initrc refresh` 是否可用。
5. 仍然反复发生时，跑一次 `sh scripts/collect.sh` 把整份报告回传定位（报告含 cgroup、
   其他模块进程、`am_kill` 三段，以及 module.log 三代与 auto-stop 取证）。

## WiFi 慢 / 5G 正常

如果只在某个 WiFi 下慢，按顺序隔离：

1. 打开「直通模式」测速。仍慢：关闭 Hosts 挂载并停止服务再测；仍慢基本不是模块，查 WiFi/路由器。
2. 直通正常：只停 Mihomo 再测。变快 → TUN/代理；仍慢 → DNS/IPv6。
3. DNS 方向逐项试：关闭「阻断 IPv6 DNS」、关闭「双栈 IP 优选」、测速方式改 `tcp:443`。
4. 下载/大流量慢再试 TUN MTU（1500/1400）；高带宽 WiFi 下 gvisor 可能 CPU 打满，测速时看 mihomo 的 CPU。

常见原因：IPv6 DNS 被静默 DROP 等超时（本版优先 REJECT，仅在不支持时回退 DROP）、SmartDNS 的 ping/双栈冷查询、gvisor 用户态 TUN 的 CPU 上限、WiFi 限制公共 DNS 或代理路由。hosts 只影响 GitHub/FCM 等特定域名。

## 解析量不增加 / 过一阵才增加

「DNS 重定向规则正常」只说明 53 端口的劫持链存在且目标端口在监听，不代表已经有查询经过。排查顺序：

1. 看「监控 → DNS 入口」：当前是 `Mihomo:1053`、`AdGuardHome:5300` 还是 `SmartDNS:3721`。只有入口服务会统计全部查询；下游服务命中缓存时计数可能不变（AGH 不缓存，命中 SmartDNS 缓存时 SmartDNS 的上游请求也不会增加）。
2. 这是缓存不是启动延迟：Android/应用/浏览器会缓存 DNS，SmartDNS 还有 `cache-persist yes` 与 `rr-ttl-min 600`（最短 10 分钟）。刚恢复运行或刷新网络后，短时间内没有新查询很正常。
3. 检查系统「私人 DNS」：指定主机名时一定走 853，不经过本模块的 53 重定向；「自动」也可能协商 DoT。排查时先关闭再验证。
4. 用 `sh /data/adb/modules/SAM/scripts/diagnose.sh` 或 `iptables -t nat -L REDIRECT_DNS -v -n` 看重定向包数；换一个未访问过的域名再看 AGH/SmartDNS 计数。

## ⚠️无网络
- 检查手机网络，开关飞行模式
- 排查 Mihomo 和 AdGuardHome 的拦截日志，手动添加规则放行

## 🤝使用项目
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)
- [vernesong/mihomo](https://github.com/vernesong/mihomo)
- [AdguardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome)
- [pymumu/smartdns](https://github.com/pymumu/smartdns)

## 🙏感谢
- [twoone-3/AdGuardHomeForRoot](https://github.com/twoone-3/AdGuardHomeForRoot)
- [GitMetaio/Surfing](https://github.com/GitMetaio/Surfing)
- Kisaratan
