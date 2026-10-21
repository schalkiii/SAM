# SAM
SAM 是 SmartDNS、AdGuardHome 和 Mihomo 三合一的 Magisk 模块。每一个服务都可以单独使用，或者两两组合，或者全部启用。

## 📖说明
- SmartDNS 的优先级最低，在无启用其它服务的情况下，才会作为本机的 DNS 转发服务，在有两种和三种服务启用，只会作为上游 DNS。
- AdGuardHome 在单独启用和 SmartDNS 一起使用，都会作为本机的 DNS 转发服务，再和 Mihomo 三种一起用，就根据设置文件的配置，来选择使用哪种结构。
- Mihomo 在单独使用，或者和另一种服务使用，都会作为本机的 DNS 转发服务。 

## 🧩 本 fork 增强
在原作者 [5MayRain/SAM](https://github.com/5MayRain/SAM) 基础上增加：

- **WebUI 设置页**：直通开关、DNS 结构模式、服务开关、端口、TUN、订阅与黑白名单等 22 项可直接改
- **直通模式**：临时撤销 DNS 劫持但保留服务与 WebUI，适合校园网、认证热点；改动 5 秒内由守护循环生效
- **免重启运维**：临时 root / 只能软重启环境使用 `sh scripts/manual.sh activate|resume|uninstall`
- **守护循环**：进程掉线自动拉起、iptables 规则被清自动重建、日志 100KB 轮转
- **配置安全加载**：`setting.conf` 出现 BOM / CRLF / 语法错误仍能启动，坏行单独跳过
- **全量配置备份**：卸载时备份到 `/sdcard/SAM-backup/<时间>/`（setting、AGH、SmartDNS、Mihomo、名单、hosts、定时）
- **默认仅回环监听**：AGH WebUI / Mihomo 控制台 / 各 DNS 默认只听 127.0.0.1，需要电脑管理时在设置里打开「允许局域网访问」
- **工具页**：WebUI 里 16 个按钮直接调用 `manual.sh` / `backup.sh` / `ad.sh` / `update.sh` 等脚本命令
- **打包校验**：`python tools/pack_module.py` 强制 LF、写权限位、CRC 与 `mksh -n` 校验
- 广告过滤加入 GOODBYEADS 规则集与其放行列表

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
- 模块所有服务的账号和密码都是 `root`
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