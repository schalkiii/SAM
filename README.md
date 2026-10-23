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
- **守护循环**：进程掉线自动拉起、iptables 规则被清自动重建、日志 100KB 轮转（服务存活 5 秒检查，规则 10 秒）
- **配置安全加载**：`setting.conf` 出现 BOM / CRLF / 语法错误仍能启动，坏行单独跳过
- **全量配置备份**：卸载时备份到 `/data/adb/SAM-backup/<时间>/`（root-only，避免订阅链接/节点密码被普通应用读取）
- **默认仅回环监听**：AGH 面板/DNS、SmartDNS、Mihomo 控制台与代理端口默认只听 127.0.0.1；需要局域网使用时打开「允许局域网访问」，仅开放 AGH 面板/DNS 与 SmartDNS DNS，Mihomo 控制台与代理端口始终保持本机
- **内核安全更新**：先停服务再替换，自检失败自动回滚，下载有超时
- **工具页**：WebUI 工具页的按钮直接调用 `manual.sh` / `backup.sh` / `ad.sh` / `update.sh` 等脚本命令
- **打包校验**：`python tools/pack_module.py` 强制 LF、写权限位、CRC、`mksh -n` 校验；`.gitattributes` 保证 Windows 检出也是 LF
- 广告过滤加入 GOODBYEADS 规则集与其放行列表（AdGuardHome 侧）
- **广告屏蔽可逆**：屏蔽时把 App 广告缓存目录改名保留并锁定，屏蔽效果与清空相同但数据不丢，随时可原样还原；关闭开关会自动恢复
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
- 广告屏蔽会对目录设置 immutable（`chattr +i`）；卸载 App 前请先在「工具」页执行「恢复广告文件」，否则可能出现清理数据失败
- hosts 更新默认 24 小时节流；工具页的「更新 hosts」与每周定时任务会强制刷新
- 禁止该文件随意修改
  - /data/adb/modules/SAM/etc/mihomo/base.yaml

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
