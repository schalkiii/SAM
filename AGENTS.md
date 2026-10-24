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
- `scripts/watchdog.sh` 5 秒守护：拉起掉线服务；iptables/DNS 链与日志轮转每 10 秒检查；配置按 mtime 热加载；备份清单非空时每 5 分钟清理已卸载 App 的广告锁定；网络自动刷新有 10 分钟节流
- `scripts/setting_api.sh` 是 WebUI 唯一写配置入口（有锁、有校验、写后 `sh -n` 再原子替换，临时文件放 `tmp/`）；`get` 必须覆盖 WebUI 所有 `data-key`
- `scripts/manual.sh` 免重启运维；`scripts/run.sh` 提权包装（参数走临时文件，避免二次解释）
- **网络刷新**：`base.sh` 的 `refresh_network` 自动刷新最多 10 分钟一次并用目录锁互斥，手动工具/保存配置传 `force`；只有所有启用服务真正恢复后才自动刷新，WiFi 黑名单触发的停止不写异常标记，避免“刷新→WiFi 断开→监控启动/停止”循环
- **模块描述**：`scripts/update/desc.sh` 用逐行重写（不依赖 awk ENVIRON）更新 active 的 `module.prop`，并把 `modules_update` 的待激活包标记为“已安装，待重启/激活生效”；写入失败会记 ERROR。刷入后**软重启不会激活待生效包**，必须完整重启或 `manual.sh activate`；WebUI 服务页会显示待激活徽章，监控页显示 module.prop 实际描述
- 监听地址由 `LAN_ACCESS` 决定（默认 false = 只回环）：AGH 在 `update/agh.sh` 改写并开放面板/DNS，SmartDNS 在 `service/sd.sh` 启动前改写；Mihomo 控制台/mixed-port/DNS 始终只监听 127.0.0.1（无鉴权控制面与开放代理不能暴露到局域网）
- `scripts/backup.sh` 把配置备份到 `/data/adb/SAM-backup/<时间>/`（root-only；不要放 `/sdcard`，备份含订阅链接与节点密码，且 restore 信任备份内容）
- `scripts/ad.sh list` 输出广告屏蔽的影响范围（App|路径|状态|备份KB），WebUI「查看影响范围」用它；`scripts/ad.sh hold` 列出广告备份路径与占用总量
- 广告屏蔽是**改名保留**不是删除：屏蔽时把内容 `mv` 到 `<路径>.samhold`，原位置重建空目录并 `chattr +i`；恢复时改回原名。备份清单在 `/data/adb/SAM-ad-hold.list`（模块目录外，重装不丢）；二次屏蔽会把旧备份保留为 `.samhold.prev.<时间戳>`，rename 失败则跳过而不是删数据
- `chattr +i` 会阻止系统卸载时删除 App 数据：`ad.sh cleanup` 在包已不存在时解除 immutable 并删除空壳（默认保留 `.samhold`），`cleanup purge` 才删孤儿备份；由启动、守护循环与 WebUI 工具触发，`ad.sh` 有进程锁
- hosts 监控监听 `etc/` 目录而不是单个文件：`update/host.sh` 用 mv 原子替换后 inode 会变，必须重挂 bind mount；`inotify/host.sh` 处理 moved_to/close_write
- `scripts/update.sh` 先检查版本并下载，替换当前组件前停服务，替换后做 `-v` 自检并自动回滚；不要在服务运行时直接 `cp` 二进制
- WebUI「工具」页是各脚本命令的图形入口：新增带子命令的脚本时，同步在 `webroot/index.html` 加 `data-script` / `data-args` 按钮
- 配置真身只有 `setting.conf`，注释即文档。**新增配置键必须同步五处**：
  `scripts/setting.sh` 默认值与校验 → `scripts/setting_api.sh` 的 KEY 列表**与 `get_all` 输出** → `customize.sh` 升级迁移列表 → WebUI 的 `data-key`
- **缓存只有一层**：`AdGuardHome` 的 DNS 缓存保持关闭，缓存职责由上游 SmartDNS 独占（`prefetch-domain` / `serve-expired` / `cache-persist`）。再叠一层 AGH 缓存会吃双份内存，还会把 SmartDNS 选出的最优 IP 冻结住、绕过测速选优
- 行尾统一 LF；`.gitattributes` 已固定 `* text=auto eol=lf`，不要在 Windows 下关闭；脚本 0755；不要提交 `dist/`
- **写 shell 里的反斜杠转义要用八进制**（`\015` = CR、`\012` = LF），不要写 `\n` / `\n`：这类转义经编辑工具多层传递会被破坏，且破坏后语法检查依然通过，只能靠回读字节发现

## 当前状态与下一步
- 已具备：直通模式（暂停 Mihomo）、WebUI 设置页、守护循环、全量配置备份、打包校验、免重启激活/卸载
- 广告屏蔽为可逆设计（改名保留而非删除），设计与踩坑记录见 `docs/ad-block-hold-design.md`
- 模块描述由 `desc.sh` 动态更新；待激活包单独标记。管理器缓存旧列表时，返回/刷新模块页即可
- WiFi 慢/5G 正常的隔离排查步骤见 README「WiFi 慢 / 5G 正常」；常见原因是 IPv6 DNS DROP、SmartDNS 冷查询、gvisor CPU 与 TUN MTU
- 直通模式必须同时停 Mihomo，否则 TUN 的 `dns-hijack` 仍会接管 DNS
- `LAN_ACCESS=true` 只开放 AGH 面板/DNS 与 SmartDNS DNS；Mihomo 控制台、mixed-port、内部 DNS 始终回环
- 已知取舍：未做代码与数据分离（配置仍随模块目录，卸载靠备份找回；广告备份清单例外，刻意放在模块目录外）；
  订阅链接明文存在 `setting.conf`；配置备份在 `/data/adb/SAM-backup` 且仅 root 可读
- 验证命令：`python tools/test_ad_sh.py`；Windows 下若中文乱码可加 `PYTHONUTF8=1`；
  打包/语法检查 `python tools/pack_module.py --check`
