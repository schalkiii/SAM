# AGENTS.md

## 定位
Magisk / KernelSU 模块：SmartDNS + AdGuardHome + Mihomo 三合一，负责本机 DNS 劫持、广告过滤与代理。本仓库是 [5MayRain/SAM](https://github.com/5MayRain/SAM) 的增强 fork。

## 怎么跑
- 安装：模块管理器刷 zip；临时 root 下 `sh scripts/manual.sh install <zip>`
- 激活：`sh scripts/manual.sh activate`
- 软重启后恢复：`sh scripts/manual.sh resume`
- 卸载（不需要重启）：`sh scripts/manual.sh uninstall`
- 打包：`python tools/pack_module.py`；只检查用 `--check`；不改源文件用 `--no-write`
- 广告屏蔽回归测试：`python tools/test_ad_sh.py`（改 `scripts/ad.sh` 后必跑，25 项断言）

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
- `scripts/ad.sh list` 输出广告屏蔽的影响范围（App|路径|状态|备份KB），WebUI「查看影响范围」用它；`scripts/ad.sh hold` 列出广告备份路径与占用总量
- 广告屏蔽是**改名保留**不是删除：屏蔽时把内容 `mv` 到 `<路径>.samhold`，原位置重建空目录并 `chattr +i`；恢复时改回原名。备份清单在 `/data/adb/SAM-ad-hold.list`（模块目录外，重装不丢）
- WebUI「工具」页是各脚本命令的图形入口：新增带子命令的脚本时，同步在 `webroot/index.html` 加 `data-script` / `data-args` 按钮
- 配置真身只有 `setting.conf`，注释即文档。**新增配置键必须同步四处**：
  `scripts/setting.sh` 默认值与校验 → `scripts/setting_api.sh` 的 KEY 白名单 → `customize.sh` 升级迁移列表 → WebUI 的 `data-key`
- **缓存只有一层**：`AdGuardHome` 的 DNS 缓存保持关闭，缓存职责由上游 SmartDNS 独占（`prefetch-domain` / `serve-expired` / `cache-persist`）。再叠一层 AGH 缓存会吃双份内存，还会把 SmartDNS 选出的最优 IP 冻结住、绕过测速选优
- 行尾统一 LF；脚本 0755；不要提交 `dist/`
- **写 shell 里的反斜杠转义要用八进制**（`\015` = CR、`\012` = LF），不要写 `\n` / `\n`：这类转义经编辑工具多层传递会被破坏，且破坏后语法检查依然通过，只能靠回读字节发现

## 当前状态与下一步
- 已具备：直通模式、WebUI 设置页、守护循环、全量配置备份、打包校验、免重启激活/卸载
- 广告屏蔽为可逆设计（改名保留而非删除），设计与踩坑记录见 `docs/ad-block-hold-design.md`
- 已知取舍：未做代码与数据分离（配置仍随模块目录，卸载靠备份找回；广告备份清单例外，刻意放在模块目录外）；
  订阅链接明文存在 `setting.conf`
