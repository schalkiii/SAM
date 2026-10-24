# SAM
SAM 是 SmartDNS、AdGuardHome 和 Mihomo 三合一的 Magisk 模块。每一个服务都可以单独使用，或者两两组合，或者全部启用。

## 📖说明
- SmartDNS 的优先级最低，在无启用其它服务的情况下，才会作为本机的 DNS 转发服务，在有两种和三种服务启用，只会作为上游 DNS。
- AdGuardHome 在单独启用和 SmartDNS 一起使用，都会作为本机的 DNS 转发服务，再和 Mihomo 三种一起用，就根据设置文件的配置，来选择使用哪种结构。
- Mihomo 在单独使用，或者和另一种服务使用，都会作为本机的 DNS 转发服务。 

## 🧩 本 fork 增强
在原作者 [5MayRain/SAM](https://github.com/5MayRain/SAM) 基础上增加：

- **WebUI 设置页**：直通开关、DNS 结构模式、服务开关、端口、TUN、订阅与黑白名单等可直接改
- **直通模式**：临时撤销 DNS 劫持并暂停 Mihomo（TUN 仍会劫持 DNS），适合校园网、认证热点；改动 5 秒内由守护循环生效
- **免重启运维**：临时 root / 只能软重启环境使用 `sh scripts/manual.sh activate|resume|uninstall`
- **守护循环**：进程掉线自动拉起、iptables 规则被清自动重建、日志 100KB 轮转（服务存活 5 秒检查，规则 10 秒）；只有服务全部恢复且距离上次自动刷新超过 10 分钟时才刷新网络，避免服务反复掉线时反复开关 WiFi
- **配置安全加载**：`setting.conf` 出现 BOM / CRLF / 语法错误仍能启动，坏行单独跳过
- **全量配置备份**：卸载时备份到 `/data/adb/SAM-backup/<时间>/`（root-only，避免订阅链接/节点密码被普通应用读取）
- **默认仅回环监听**：AGH 面板/DNS、SmartDNS、Mihomo 控制台与代理端口默认只听 127.0.0.1；需要局域网使用时打开「允许局域网访问」，仅开放 AGH 面板/DNS 与 SmartDNS DNS，Mihomo 控制台与代理端口始终保持本机
- **内核安全更新**：先停服务再替换，自检失败自动回滚，下载有超时
- **工具页**：WebUI 工具页的按钮直接调用 `manual.sh` / `backup.sh` / `ad.sh` / `update.sh` 等脚本命令
- **打包校验**：`python tools/pack_module.py` 强制 LF、写权限位、CRC、`mksh -n` 校验；`.gitattributes` 保证 Windows 检出也是 LF
- 广告过滤加入 GOODBYEADS 规则集与其放行列表（AdGuardHome 侧）
- **广告屏蔽可逆**：屏蔽时把 App 广告缓存目录改名保留并锁定，屏蔽效果与清空相同但数据不丢，随时可原样还原；关闭开关会自动恢复；已卸载 App 的锁定会在启动/每 5 分钟自动解除
- **缓存只留一层**：AdGuardHome 自身不缓存，缓存由上游 SmartDNS 独占，避免双份内存并保留其测速选优能力

> 本 fork 的 `updateJson` 指向本仓库，不再跟随上游自动更新。

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
- 定时执行

## 📢注意
- 禁止和其它同类型模块使用
- 模块所有服务的账号和密码都是 `root`，开启「允许局域网访问」前请先改密码
- 刷入新版本后需**完整重启**或使用「工具 → 激活模块」；**软重启不会激活 `modules_update` 里的新包**。未激活时 KernelSU 模块列表显示的是待激活包，WebUI 仍由旧版本提供服务
- WebUI 服务页出现「待激活更新」徽章时，说明新包还没激活；监控页「模块描述」显示的是 `module.prop` 里的实际值
- 如果 KernelSU 模块描述仍是旧状态，先确认 `cat /data/adb/modules/SAM/module.prop` 的 `description`，再返回/刷新模块页；管理器会缓存上次读取的模块列表
- 广告屏蔽会对目录设置 immutable（`chattr +i`），可能阻止系统卸载时清理 App 数据；卸载 App 前建议先在「工具」页执行「恢复广告文件」。如果直接卸载，模块会在启动和每 5 分钟自动解除已卸载 App 的锁定（默认保留 `.samhold` 备份）；系统卸载当下仍可能提示删除数据失败，可用工具页「清理已卸载 App 及备份」删除孤儿备份
- hosts 更新默认 24 小时节流；工具页的「更新 hosts」与每周定时任务会强制刷新
- 禁止该文件随意修改
  - /data/adb/modules/SAM/etc/mihomo/base.yaml

## WiFi 慢 / 5G 正常

如果只在某个 WiFi 下慢，按顺序隔离：

1. 打开「直通模式」测速。仍慢：关闭 Hosts 挂载并停止服务再测；仍慢基本不是模块，查 WiFi/路由器。
2. 直通正常：只停 Mihomo 再测。变快 → TUN/代理；仍慢 → DNS/IPv6。
3. DNS 方向逐项试：关闭「阻断 IPv6 DNS」、关闭「双栈 IP 优选」、测速方式改 `tcp:443`。
4. 下载/大流量慢再试 TUN MTU（1500/1400）；高带宽 WiFi 下 gvisor 可能 CPU 打满，测速时看 mihomo 的 CPU。

常见原因：IPv6 DNS 被 DROP 等超时、SmartDNS 的 ping/双栈冷查询、gvisor 用户态 TUN 的 CPU 上限、WiFi 限制公共 DNS 或代理路由。hosts 只影响 GitHub/FCM 等特定域名。

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
