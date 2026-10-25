# AGENTS.md

## 定位
Magisk / KernelSU 模块：SmartDNS + AdGuardHome + Mihomo 三合一，负责本机 DNS 劫持、广告过滤与代理。本仓库是 [5MayRain/SAM](https://github.com/5MayRain/SAM) 的增强 fork。

## 怎么跑
- 安装：模块管理器刷 zip；临时 root 下 `sh scripts/manual.sh install <zip>`
- 激活：`sh scripts/manual.sh activate`
- 软重启后恢复：`sh scripts/manual.sh resume`（检测到待激活包时会先 `activate`；WebUI 按钮同步变为「激活并恢复新版」）
- 卸载（不需要重启）：`sh scripts/manual.sh uninstall`
- 打包：`python tools/pack_module.py`；只检查用 `--check`；不改源文件用 `--no-write`；打包会跳过 `tools/`、`dist/`、`.workbuddy/` 等非模块内容
- 广告屏蔽回归测试：`python tools/test_ad_sh.py`（改 `scripts/ad.sh` 后必跑，27 项断言）
- 其余回归测试按改动选跑（全部由 CI 执行，本地改动后对应跑）：`test_backup_semantics.py`（backup.sh，48 项）、`test_cron_validate.py`（setting_api.sh 的 cron 与 TTL 边界，34 项）、`test_tar_guard.py`（update.sh 的 safe_tar_extract，18 项）、`test_owner_probe.py`（iptables/dns.sh 的 owner_supported，20 项）、`test_dns_entry.py`（DNS 入口回退链三处消费方一致性，66 项）、`test_watchdog_logic.py`（watchdog 健康判定/配置阻塞，20 项）。七套件合计 233 项断言
- 版本一致性：`python tools/check_version_sync.py`（module.prop / update.json / changelog 三处必须对齐，CI 每次 push 跑）
- 测试编写约定（照现有任一测试为范例）：driver 搭临时模块目录/路径重写、或从脚本**原样抽取真实函数体**（不复制实现，重构会立刻失败）；mock 用可执行文件或 driver 内函数覆盖；Checker 类统一输出「通过 N 项, 失败 M 项」；shell 函数不能当变量用（mksh 里 `${fn}` 展开为空）；依赖 PID 可见性的用例用 `live_pid_visible()` 门控（本机 sh.EXE 的 `kill -0` 看不到任何进程）

## 技术栈
- 设备端 `/system/bin/sh` 是 mksh：支持数组、`(( ))`、`let`；不要用 bash 专属语法
- 纯 shell + iptables + 静态 HTML/JS WebUI（依赖 KernelSU 的 `ksu.exec`）
- 设备固定路径 `/data/adb/modules/SAM`

## 目录与约定
- `service.sh` 开机入口；`scripts/service.sh` 负责 start / stop / restart
- `scripts/watchdog.sh` 5 秒守护：拉起掉线服务；iptables/DNS 链与日志轮转每 10 秒检查；配置按 mtime 热加载；备份清单非空时每 5 分钟清理已卸载 App 的广告锁定；网络自动刷新有 10 分钟节流
- `scripts/diagnose.sh` 只读诊断（服务/端口/AGH 配置校验/防火墙/DNS/MTU/私人 DNS/v6 REJECT/DROP 采样）；WebUI 工具页「一键诊断」调用它
- `scripts/agh_reset.sh`：备份后用 `etc/AdGuardHome/AdGuardHome.template.yaml` 重置 AGH 配置，再跑 `update/agh.sh`、`--check-config` 并按服务状态重启；WebUI「危险操作 → 重置 AGH 配置」调用它
- `etc/AdGuardHome/AdGuardHome.template.yaml` 是重置模板，不是运行时配置；改 AGH 默认字段时同步模板（schema 需与内置二进制匹配）
- **WebUI 语义**：服务页的「启动/停止/重启全部服务」只控制服务；「软重启后恢复」额外重挂 hosts、启动监控并按设置刷新网络；存在待激活包时按钮变为「激活并恢复新版」并会先激活。工具页只放一次性维护命令，不要再加「恢复运行」。监控页显示「DNS 入口」（当前 53 实际转到哪个服务），规则正常 ≠ 有查询经过
- `scripts/setting_api.sh` 是 WebUI 唯一写配置入口（有锁、有校验、写后 `sh -n` 再原子替换，临时文件放 `tmp/`）；`get` 必须覆盖 WebUI 所有 `data-key`；`cron get|set` 负责定时任务文件（一行一条参数，逐行校验时间字段，`@daily` 类快捷键支持）
- `scripts/manual.sh` 免重启运维；`scripts/run.sh` 提权包装（参数走临时文件，避免二次解释）
- **配置文件清洗**：`base.sh` 的 `sanitize_config` 在 AGH/SmartDNS 启动前清理 UTF-8 BOM 与 CR；UTF-16 明确报错不自动转换。AGH 启动前跑 `--check-config`，失败写 `tmp/agh.config.bad`（内容 cksum）和 `agh.config.bad.reason`（`yaml`/`schema`/`encoding`/`generate`），守护循环据此暂停自动拉起，配置内容变化或手动重启后才重试
- **服务用户降级**：三服务统一经 `base.sh` 的 `service_exec` 启动；`busybox setuidgid` 或独立 `setuidgid` 不可用时以 root 启动并在 `module.log` 记录 ERROR，避免临时 root 下三服务一起静默失败。当前 `SAM_USER=root`，只降组不降 UID，控制面仍需依赖回环监听和默认密码提醒。
- **服务启停互斥**：`service.sh start/stop/restart`、watchdog 的服务/规则恢复、`setting_api apply` 共用 `base.sh` 的 PID 目录锁；watchdog 拿锁后会再次检查 `service.state`，避免停止屏障失效。WiFi 查询失败时保持现状，不把空 SSID 当成非黑名单。
- **配置事务写入**：`setting_api.sh set/setarr` 先写临时副本，全部校验通过后一次 `mv`；端口冲突按同一批最终候选值校验，TTL 独立为 0-86400。
- **服务自动停止取证**：watchdog 在服务异常消失时写 `tmp/auto-stop.<bin>.*.log`，`diagnose.sh` 汇总 `SERVICE-EVENT`、`watchdog.heartbeat`、`oom_score_adj`、MIUI/`logcat` 杀进程线索。
- **广告恢复保护**：文件类路径屏蔽期间的新内容改名到 `.samnew`，恢复失败返回非零；卸载只有全部恢复成功才删除 `/data/adb/SAM-ad-hold.list`。
- **更新与安装安全**：组件下载优先校验 `.sha256`，tar 拒绝绝对路径/`..`/链接；AGH/Mihomo 替换失败会回滚；`customize.sh` 解压或关键文件失败会中止安装。
- **hosts 更新**：内容必须逐行是 `IP 域名`，更新使用 PID 锁与唯一临时文件，失败不覆盖原 hosts。
- **IPv6 DNS 阻断**：`iptables/dns.sh` 优先用 REJECT（UDP `icmp6-port-unreachable`、TCP `tcp-reset`），内核不支持时回退 DROP；探测结果写入 `tmp/ipv6.block.mode`，避免守护循环反复删加规则
- SmartDNS 启动失败时把 `tmp/smartdns.log` 最后 5 行写入 module.log（`smartdns.out` 只有 wrapper 提示）
- **服务异常检测**：`service.sh` 的 `has_abnormal_service` 返回 0 才表示有服务缺失；正常重启不应写 `tmp/service.abnormal`。异常标记只在全部启用服务恢复后才消费并刷新网络，仍缺失时保留标记等下次
- **hosts 启动更新**：服务启动后延迟 10 秒再拉取，给网络/解析就绪时间；单个候选源失败记 INFO，最终失败才记 ERROR；GitHub 与 FCM 都成功才写 24 小时时间戳
- **网络刷新**：`base.sh` 的 `refresh_network` 自动刷新最多 10 分钟一次并用目录锁互斥，手动工具/保存配置传 `force`；只有所有启用服务真正恢复后才自动刷新，WiFi 黑名单触发的停止不写异常标记，避免“刷新→WiFi 断开→监控启动/停止”循环
- **免重启激活/恢复**：`scripts/manual.sh activate` 直接合并 `modules_update`；`repair` 会按 `active -> modules_update -> /data/adb/SAM.previous` 恢复模块目录。激活前做结构校验，上一版保留到 `/data/adb/SAM.previous`，失败回滚。安装器把 `manual.sh` 复制到模块外的 `/data/adb/SAM-activate.sh`；Android 已启动时安装结束后自动延迟执行 `autoactivate`，无需 WebUI/命令行，日志 `/data/adb/SAM-activate.log`。
- **模块描述**：`scripts/update/desc.sh` 用逐行重写（不依赖 awk ENVIRON）更新 active 的 `module.prop`，并把 `modules_update` 的待激活包标记为“已安装，待重启/激活生效”；写入失败会记 ERROR。刷入后**软重启本身不会激活待生效包**，需完整重启、`manual.sh activate`，或使用会自动先激活的 `manual.sh resume`；WebUI 服务页会显示待激活徽章，监控页显示 module.prop 实际描述
- 监听地址由 `LAN_ACCESS` 决定（默认 false = 只回环）：AGH 在 `update/agh.sh` 改写并开放面板/DNS，SmartDNS 在 `service/sd.sh` 启动前改写；Mihomo 控制台/mixed-port/DNS 始终只监听 127.0.0.1（无鉴权控制面与开放代理不能暴露到局域网）
- `scripts/backup.sh` 把配置备份到 `/data/adb/SAM-backup/<时间>/`（root-only；不要放 `/sdcard`，备份含订阅链接与节点密码，且 restore 信任备份内容）。备份写完成标记 `.complete`，`list`/`restore` 只认完整备份；`restore` 前自动留存当前配置快照；广告屏蔽清单 `/data/adb/SAM-ad-hold.list` 存到备份的 `extra/` 并按原路径恢复；watchdog 每天自动备份一次
- `scripts/ad.sh list` 输出广告屏蔽的影响范围（App|路径|状态|备份KB），WebUI「查看影响范围」用它；`scripts/ad.sh hold` 列出广告备份路径与占用总量
- 广告屏蔽是**改名保留**不是删除：屏蔽时把内容 `mv` 到 `<路径>.samhold`，原位置重建空目录并 `chattr +i`；恢复时改回原名。备份清单在 `/data/adb/SAM-ad-hold.list`（模块目录外，重装不丢）；二次屏蔽发现「有旧备份但未锁定」时**跳过屏蔽并提示先 recovery**（`.prev.*` 另存方案已废弃，见设计文档 §14），rename 失败同样跳过而不是删数据；`cleanup purge` 会清理历史版本遗留的 `.samhold.prev.*` 孤立目录
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
- 已具备：直通模式（暂停 Mihomo）、WebUI 设置页、守护循环、全量配置备份、打包校验、免重启激活/卸载、定时任务 WebUI、每日自动备份
- 发布状态：线上最新 Release 为 **v20261025.3**（tag 与资产已推送，CI 通过）；**v20261025.4 已在本地构建**（`dist/SAM_20261025.4_release.zip`，module.prop/update.json/changelog 已 bump 至该版本），尚未推送 tag / 创建 GitHub Release。v20261025.4 内容：第二轮审计 S-2~S-9（restore 清中断残留、TTL 常量、版本一致性门禁、锁阻塞用例、watchdog 测试、Mihomo 判定收敛）+ DNS 入口链合一，测试 137 → 233 项（CI 241 项）；v20261025.3 是热修复版：① `backup.sh restore` 持 setting 锁覆盖文件写入期（与 `set`/`cron set` 互斥，锁不握过服务重启），文件写入改同目录临时文件 + `mv` 原子替换并加 `-f` 守卫（mv 对目录目标是"移入"而非报错）；② `setting_api.sh cron set` 补配置锁统一 WebUI 写入口互斥语义；③ 测试增补 24 项断言（备份语义 31→43、定时任务 19→29，五文件合计 137 项）；v20261025.2 为备份列表 sed 热修复 + 4 个新测试文件 88 项断言；v20261025.1 包含 v20261024.18 回归修复 + 二次 review 修复 + 定时任务/备份/默认密码增强 + 第三轮复审修复（sd.sh bind-tcp 单次插入、owner_supported 残留链清理、端口标签 key 修正、pack 清单补 proxy.sh）
- v20261024.18 回归（`is_port_listening` 曾要求 TCP+UDP 同时监听，SmartDNS 只有 UDP bind 被误判未监听 → 计数为零）已于 v20261025.1 修复并发布：恢复「任一协议监听即可用」+ SmartDNS 补 `bind-tcp`；`dns.sh` 有 `owner_supported` 探测（无 `xt_owner` 跳过 owner 规则，缓存 `tmp/owner.supported`）；watchdog 的 `BLOCK_IPV6_DNS=false` 分支只清 IPv6 侧（`dns.sh disablev6`），不碰 IPv4 劫持
- **watchdog 下游刷新按拓扑门控**：`current_dns_entry` 计算入口（与 `dns.sh select_dns_port` 同序），只有入口变化才跑 `update/agh.sh`+`update/mihomo.sh`，且重启前比对配置 cksum，内容不变只做等价重写——同名端口恢复（SmartDNS 重启仍是 3721）不再重启 AGH/Mihomo，缓存与统计保留
- **服务锁等待**：`service.sh stop/restart` 锁等待 120/180 秒，匹配守护循环持锁做服务恢复的最坏时长；用户停止操作不会因等不到锁而静默失败
- **setting 配置锁（跨文件边界，改动前三思）**：`sam_lock_acquire "setting" 30`（base.sh 实现，目录锁 + PID 陈旧检测）。持有者：`setting_api.sh` 的 `set`/`setarr`/`apply`/`cron set`（写 `setting.conf`/`etc/crontabs/root`）+ `backup.sh restore` 的**文件写入期**（持锁不含快照与服务重启——restart 由 service.sh 自己的锁串行化）。读路径（`get`/`cron get`/`save`）不持锁：原子写下读者只会看到完整文件。新增 WebUI 写入口必须走同一把锁
- **手动激活失败保留现场**：校验不过的新包移到 `/data/adb/SAM.rejected.<时间>`；卸载清理 `/data/adb/SAM-activate.sh`、`SAM-activate.log`、`SAM.previous`、rejected/old 残留，`repair` 不能复活已卸载模块
- **广告屏蔽稳健性**：`is_locked` 以 `HOLD_LIST` 为权威 + lsattr 属性列解析（不把路径当正则）；「有旧备份但未锁定」跳过屏蔽并提示先 recovery；占位目录/文件按原属主权限重建，`chattr +i` 失败用严格权限兜底；`ad.sh` 拿不到锁直接退出；purge 不删「空壳没删成」路径的备份
- **更新安全**：`safe_tar_extract` 用 `-tvzf` 判链接类型位、`-tzf` 判成员名（原整行 `^/` 判断永远为假），加体积/成员数上限；缺 `sha256sum` 降级跳过校验；`update.sh` 有更新互斥锁
- **备份语义**：完成标记 `.complete`，`list`/`restore` 只认完整备份；失败不轮转不写标记；`restore` 前自动留存当前配置快照；备份含 `/data/adb/SAM-ad-hold.list`（存 `extra/`，按原路径恢复）；watchdog 每日自动备份（失败按小时重试）
- **定时任务**：`setting_api.sh cron get|set` 一行一条参数传入，逐行校验时间字段（`@daily` 类支持，非法整批拒绝）；WebUI 工具页「定时任务」卡片编辑保存，busybox crond 下一分钟自动生效；清空全部行需确认
- **WebUI 读路径全部按 errno**：allstatus/设置/日志/广告清单/挂载状态失败时明确报错；设置读取失败不填表单（防止空值覆盖后误保存）；服务页端口说明用 `data-port-label` 动态显示（`webui.sh` 输出 `smartdns_port`）
- **`run.sh` 属主校验降级**：`stat -c %u` 不可用时跳过校验而不是拒绝所有命令
- **默认密码**：SmartDNS/AGH 默认密码 `sam123456`（AGH 模板为对应 bcrypt 哈希）；`SMARTDNS_TTL_MIN` 下限 60 秒（WebUI/API/加载三处一致）
- 广告屏蔽为可逆设计（改名保留而非删除），设计与踩坑记录见 `docs/ad-block-hold-design.md`
- 模块描述由 `desc.sh` 动态更新；待激活包单独标记。管理器缓存旧列表时，返回/刷新模块页即可
- WiFi 慢/5G 正常的隔离排查步骤见 README「WiFi 慢 / 5G 正常」；常见原因是 IPv6 DNS 被静默丢弃、SmartDNS 冷查询、gvisor CPU 与 TUN MTU
- 直通模式必须同时停 Mihomo，否则 TUN 的 `dns-hijack` 仍会接管 DNS
- `LAN_ACCESS=true` 只开放 AGH 面板/DNS 与 SmartDNS DNS；Mihomo 控制台、mixed-port、内部 DNS 始终回环
- 已知取舍：未做代码与数据分离（配置仍随模块目录，卸载靠备份找回；广告备份清单例外，刻意放在模块目录外）；
  订阅链接明文存在 `setting.conf`；配置备份在 `/data/adb/SAM-backup` 且仅 root 可读
- 验证命令：`python tools/test_ad_sh.py`；Windows 下若中文乱码可加 `PYTHONUTF8=1`；
  打包/语法检查 `python tools/pack_module.py --check`
