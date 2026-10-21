# AGENTS.md

## 定位
Magisk / KernelSU 模块：SmartDNS + AdGuardHome + Mihomo 三合一，负责本机 DNS 劫持、广告过滤与代理。本仓库是 [5MayRain/SAM](https://github.com/5MayRain/SAM) 的增强 fork。

## 怎么跑
- 安装：模块管理器刷 zip；临时 root 下 `sh scripts/manual.sh install <zip>`
- 激活：`sh scripts/manual.sh activate`
- 软重启后恢复：`sh scripts/manual.sh resume`
- 卸载（不需要重启）：`sh scripts/manual.sh uninstall`
- 打包：`python tools/pack_module.py`；只检查用 `--check`；不改源文件用 `--no-write`

## 技术栈
- 设备端 `/system/bin/sh` 是 mksh：支持数组、`(( ))`、`let`；不要用 bash 专属语法
- 纯 shell + iptables + 静态 HTML/JS WebUI（依赖 KernelSU 的 `ksu.exec`）
- 设备固定路径 `/data/adb/modules/SAM`

## 目录与约定
- `service.sh` 开机入口；`scripts/service.sh` 负责 start / stop / restart
- `scripts/watchdog.sh` 5 秒守护：拉起掉线服务、重建 iptables、按 mtime 热加载配置
- `scripts/setting_api.sh` 是 WebUI 唯一写配置入口（有锁、有校验、写后 `sh -n` 再原子替换）
- `scripts/manual.sh` 免重启运维；`scripts/run.sh` 提权包装（参数走临时文件，避免二次解释）
- 监听地址由 `LAN_ACCESS` 决定（默认 false = 只回环）：AGH 在 `update/agh.sh` 改写、Mihomo 在 `update/mihomo.sh` 改写、SmartDNS 在 `service/sd.sh` 启动前改写
- `scripts/backup.sh` 卸载前把配置备份到 `/sdcard/SAM-backup/<时间>/`
- `scripts/ad.sh list` 输出广告屏蔽的影响范围（App|路径|状态），WebUI「查看影响范围」用它
- WebUI「工具」页是各脚本命令的图形入口：新增带子命令的脚本时，同步在 `webroot/index.html` 加 `data-script` / `data-args` 按钮
- 配置真身只有 `setting.conf`，注释即文档。**新增配置键必须同步四处**：
  `scripts/setting.sh` 默认值与校验 → `scripts/setting_api.sh` 的 KEY 白名单 → `customize.sh` 升级迁移列表 → WebUI 的 `data-key`
- 行尾统一 LF；脚本 0755；不要提交 `dist/`

## 当前状态与下一步
- 已具备：直通模式、WebUI 设置页、守护循环、全量配置备份、打包校验、免重启激活/卸载
- 已知取舍：未做代码与数据分离（配置仍随模块目录，卸载靠备份找回）；订阅链接明文存在 `setting.conf`
