# Unreleased
- 架构: DNS 入口选择链三处重复实现合一（审计 A-1，v20261024.18 计数器归零故障的复发面）
  - 新增 `base.sh dns_entry_port()`：按 `MODULE_DNS_MODE` 逐级回退（模式 2 Mihomo→AGH→SmartDNS，模式 1 AGH→Mihomo→SmartDNS），判定口径统一为 `isRun` + `is_port_listening`（进程活着不代表端口可用），输出「名称:端口」或空
  - 三处消费方改为调用共享函数，只保留各自格式化：`iptables/dns.sh select_dns_port`（解析端口/名称建规则，删除 `set_dns_entry`）、`watchdog.sh current_dns_entry`（拓扑比对，空时输出 none）、`webui.sh resolve_dns_entry`（状态页显示，保留直通模式分支；SmartDNS 端口来源从配置解析改为设置项，与建规则一方同源）
  - 新增 `tools/test_dns_entry.py`（66 项）：抽取三个真实函数，mock `isRun`/`is_port_listening` 驱动 16 组场景矩阵 + 独立算盘交叉验证 + 三处消费方一致性断言；变异验证（对调回退顺序即 8 项失败）
  - CI 增加该测试步骤；六套件合计 203 项断言

# 2026.10.25.3
- 热修复: `backup.sh restore` 与 WebUI 配置写操作的竞态
  - restore 此前完全不持锁且用 `cp -f` 原地覆盖，而 WebUI 工具页有「恢复最近备份」按钮：
    恢复进行时另一标签页保存设置/定时任务会互相覆盖；`cp` 的截断窗口内并发的
    `setting_api get` / crond 重读可能看到半截的 setting.conf / crontabs/root
  - restore 现在持 setting 锁覆盖文件写入期(与 `set`/`cron set` 互斥)，锁只持到文件
    写完——随后的服务重启由 service.sh 自己的锁串行化，不把 setting 锁握过重启；
    成功与失败路径都确保释放
  - 文件写入改为同目录临时文件 + `mv` 的原子替换(临时文件不放 tmp：重启会清 tmp，
    且跨文件系统 mv 退化为拷贝)；`mv` 后补 `-f` 守卫——目标意外是目录时 mv 按 POSIX
    会把临时文件移进目录并返回成功，守卫把这种假成功判失败
  - 数据目录(AGH/SmartDNS/Mihomo)无法原子替换(先移走再换有消失窗口，中断即丢数据)，
    保持原地覆盖：WebUI 不写它们，且恢复完成后服务重启会重新初始化
- 配置锁契约统一: `setting_api.sh cron set` 与 `set`/`setarr`/`apply` 一致走 setting 锁
  - 修复前定时任务保存是唯一不持锁的 WebUI 写入口，与「进程内互斥，避免 WebUI 与
    命令行同时写导致互相覆盖」的契约不一致；成功与失败(整批拒绝)路径都确保释放锁
  - `tools/test_cron_validate.py` 增补锁接线用例（19 → 29 项）
- 测试增补
  - `tools/test_backup_semantics.py`（31 → 43 项）：restore 持锁并释放(真实锁 + 记录型
    stub 双验证)、失败路径释放锁、原子替换无临时残留、`mv` 目录目标假成功守卫
    (变异验证: 去掉 `-f` 守卫即失败)
  - 五个测试文件合计 137 项断言，CI `module-check` 全量执行

# 2026.10.25.2
- 热修复: `backup.sh list` 在「没有任何完整备份」时输出为空
  - 行尾追加标记的 sed 写成 `s/$| (未完成)/`，少一个闭合分隔符，GNU/busybox sed 均报
    `unterminated s command`；改为 `s/$/ (未完成)/` 后未完成备份正常列出供排查
  - 该问题由 v20261025.1 的备份语义修复引入，发布前无自动化用例覆盖，已被新增的
    `tools/test_backup_semantics.py` 逮住并纳入 CI
- 测试增补（software-improvement 测试分支，对应审计建议 S-2）
  - 新增 `tools/test_cron_validate.py`（19 项）：cron get/set 合法行、非法行整批拒绝且不碰原文件、清空语义
  - 新增 `tools/test_tar_guard.py`（18 项）：从 `update.sh` 抽取真实 `safe_tar_extract`，覆盖链接/穿越/绝对路径/成员数与体积上限/垃圾内容
  - 新增 `tools/test_owner_probe.py`（20 项）：从 `dns.sh` 抽取真实 `owner_supported`，mock iptables 驱动支持/不支持/残留链/缓存命中/幂等五场景
  - 新增 `tools/test_backup_semantics.py`（31 项）：`.complete` 完成标记、restore 先选目标再拍快照、extra 清单往返、轮转、失败不轮转、快照不受开关限制
  - 四个用例共 88 项断言，连同既有 `test_ad_sh.py` 27 项，CI `module-check` 全量执行

# 2026.10.25.1
- 修复 v20261024.18 回归与二次全面 review 发现的问题
  - `is_port_listening` 改回「TCP 与 UDP 任一在监听即可用」：SmartDNS 默认只有 `bind`（UDP），旧判定把它误判为未监听，DNS 入口选择跳过 SmartDNS，表现为「开启直通再关闭后 SmartDNS 计数一直是零、AGH 计数持续增长」；同时给 SmartDNS 补 `bind-tcp`，53 的 TCP 查询（大响应/截断重试）不再被拒绝
  - `iptables/dns.sh` 新增 `owner_supported` 探测（结果写 `tmp/owner.supported`）：无 `xt_owner` 的内核上 `check_dns_chain`/`enable_dns` 不再强求 owner 规则，规则从「每轮重建」变为收敛
  - watchdog 在 `BLOCK_IPV6_DNS=false` 时改调 `dns.sh disablev6`，只清理 IPv6 侧规则，不再连带删掉 IPv4 `REDIRECT_DNS`
  - watchdog 服务恢复后按「DNS 入口是否变化」决定是否重写下游上游，且重启前比对配置 cksum：同名端口恢复（SmartDNS 重启仍是 3721）不再重启 AGH/Mihomo，缓存与统计不再被清
  - `service.sh stop/restart` 锁等待 30/60 秒提高到 120/180 秒，避免守护循环做服务恢复时用户停止操作超时退出
  - `manual.sh` 激活校验失败时把新包保留到 `/data/adb/SAM.rejected.<时间>` 而非直接删除；卸载时清理 `/data/adb/SAM-activate.sh`、`SAM-activate.log`、`SAM.previous`、rejected/old 残留，`repair` 不能再复活已卸载模块
  - `ad.sh`：拿不到广告锁直接退出；`is_locked` 以备份清单为权威并只解析 lsattr 属性列（不再把路径当正则）；发现「有旧备份但未锁定」时跳过屏蔽并提示先 recovery，不再把 `.samhold` 挪成无索引的 `.prev.*`；占位目录/文件按原属主权限重建，`chattr +i` 失败时用严格权限兜底；purge 不再删除「空壳没删成」路径的备份
  - `update.sh`：`safe_tar_extract` 改为 `-tvzf` 判链接 + `-tzf` 判成员名（原实现对整行做 `^/` 判断永远为假），并加体积/成员数上限；缺 `sha256sum` 时降级为跳过校验而非判失败；新增更新互斥锁
  - `run.sh`：`stat -c %u` 不可用时不再把所有 WebUI 命令判成「参数文件属主异常」
  - WebUI 读路径（allstatus/设置/日志/广告清单/挂载状态）统一按 `errno` 判断，失败时明确报错，不再静默显示「未运行/暂无日志」或用空值覆盖表单
  - 服务页端口说明改为按真实配置动态显示（`data-port-label` + `webui.sh` 输出 `smartdns_port`），改过 DNS 端口后文案不再过期
- 定时任务（crontabs）WebUI 化
  - `setting_api.sh` 新增 `cron get` / `cron set`：一行一条参数传入，逐行校验时间字段（注释/空行放过，`@daily` 类快捷键支持），非法行整批拒绝且不碰原文件
  - 工具页新增「定时任务」卡片：文本框编辑 + 读取/保存，清空全部行需确认；由 busybox crond 下一分钟自动生效，无需重启服务
- 备份增强
  - 备份新增 `/data/adb/SAM-ad-hold.list`（广告屏蔽清单，丢失就定位不到 `.samhold` 备份），存到备份的 `extra/` 子目录，恢复时按原路径写回
  - 备份写完成标记 `.complete`：`list`/`restore` 只认完整备份，半截备份不会被当成最新恢复；备份失败不轮转、不写标记
  - `restore` 前先自动留存一份当前配置快照（不受 `BACKUP_CONF` 开关限制），还原本身变得可回退
  - watchdog 每天自动备份一次（成功才记时间戳，失败按小时重试）
- 设置与默认值
  - `SMARTDNS_TTL_MIN` 下限改为 60 秒（WebUI、`setting_api.sh`、`setting.sh` 三处一致）：30 秒会让客户端频繁回查、冷查询与测速被反复触发
  - SmartDNS / AdGuardHome 默认密码由 `root` 改为 `sam123456`（AGH 模板同步换 bcrypt 哈希），安装输出与 README 同步说明
- 直通模式不再重启 AGH/SmartDNS
  - `setting_api.sh apply` 新增 `is_bypass_only_change`：只改 `BYPASS_ENABLE` 时调用 `dns.sh disable/enable` 与 `mihomo.sh start/stop`，不再 `service.sh restart`
  - 保留 AGH 查询统计与 SmartDNS 缓存；WebUI 文案同步说明「只改直通不重启」
- 临时 root 免重启激活增强
  - 已启动的 Android 中安装结束后自动延迟执行一次 `autoactivate`，无需 WebUI 或手动传参；日志写 `/data/adb/SAM-activate.log`
  - `manual.sh repair` 在 active 损坏/丢失时按 `active -> modules_update -> /data/adb/SAM.previous` 自动恢复
  - 激活前校验模块结构，上一版保留到 `/data/adb/SAM.previous`，失败自动回滚，不再立即删除旧版本
  - 安装器写入模块外恢复入口 `/data/adb/SAM-activate.sh`，软重启后模块目录消失也可直接执行 `repair`
  - WebUI 工具页新增「修复 / 免重启激活」
- 二次复审补充修复（第三轮）
  - `service/sd.sh` 补 `bind-tcp` 时只在第一条 `bind` 之后插入一次：用户手工配置出现多条 `bind` 时，`sed a` 会跟在每条匹配行后补出多条重复 `bind-tcp`
  - `iptables/dns.sh` `owner_supported` 探测前先清理上次被打断残留的 `SAM_OWNER_PROBE` 链再重试：残留链会让 `-N` 失败并被误判成「内核不支持」，owner 排除规则将被永久关掉
  - WebUI 服务页 SmartDNS 端口标签的 key 修正为 `smartdns_port`（与 `webui.sh allstatus` 输出一致），此前大小写不匹配导致该标签永不刷新
  - `tools/pack_module.py` 必需文件清单补 `scripts/update/proxy.sh`（`service/mihomo.sh` 的运行时依赖，此前不在打包门禁内）

# 2026.10.24.18
- WebUI 新增「自动停止分析」，一键输出手动/WiFi 停止、watchdog 拉起或系统/小米杀后台的判断；「一键诊断」默认带 15 秒 IPv6 阻断采样
- 服务自动停止排查
  - `service.sh` start/stop/restart、watchdog、配置 apply 增加 PID 目录锁；watchdog 拿锁后二次检查状态，修复停止后仍被拉起/重建规则的竞态
  - WiFi 黑名单查询失败时保持现状，不再把空 SSID 当成非黑名单；开机延迟 start 与 WiFi 监控竞争时由 `service.sh` 再次校验黑名单
  - 服务异常消失时自动写 `tmp/auto-stop.<bin>.*.log`，`diagnose.sh` 增加 `SERVICE-EVENT`、`watchdog.heartbeat`、`oom_score_adj`、MIUI/`logcat` 杀后台取证
  - 开机不再清空历史 `module.log`，保留 `module.log.boot.1`
- 配置与 DNS
  - `setting_api.sh set/setarr` 改为事务副本 + 最后一次原子提交；同批次 DNS 端口冲突按最终值校验，TTL 独立 0-86400
  - DNS 端口 53 不再删除重定向；`dns.sh check` 补 owner/回环规则校验，关闭 IPv6 阻断时会清理旧链
  - IP 屏蔽改用 `SAM_BLOCK_IP` 专用链，自检/清理不再依赖单个探针；TUN 改名会清理旧设备规则
  - AGH/Mihomo 上游在期望链路不可用时回退到真正可用的本地 DNS，并在服务拓扑变化后重写下游配置
- 广告/备份/更新
  - 文件类广告恢复保留屏蔽期间新内容到 `.samnew`；恢复失败返回非零，卸载只有全部恢复成功才删除备份清单
  - 备份覆盖 AGH/SmartDNS/Mihomo 用户数据目录，复制失败返回失败；恢复同样校验结果
  - 组件下载优先校验 `.sha256`，tar 拒绝绝对路径/`..`/链接，AGH/Mihomo 替换失败回滚，安装解压失败中止
  - `run.sh` 提权参数改用随机私有目录并校验属主；WebUI 全面按 `errno` 判定执行结果
- 测试
  - `test_ad_sh.py` 新增文件类恢复期间新内容不丢断言

# 2026.10.24.17
- 发布与打包
  - 打包排除 `.workbuddy/` 等会话残留目录，避免内部排查笔记进入 release zip
  - 发布前校验 zip 根目录、模块版本、脚本权限位与 SHA256
- 修复服务异常检测反转
  - `detect_abnormal` 原先把 `return 0`（全部健康）当成异常：正常重启会误写异常标记，健康启动反而误报「服务未全部恢复」，真实异常时不写标记也不刷新网络
  - 改为 `has_abnormal_service`，返回 0 才表示有服务缺失；服务仍缺失时保留异常标记，等下一次真正恢复后再刷新网络
- hosts 启动更新时序
  - 服务启动后延迟 10 秒再拉取 hosts，避免刚重启时网络/解析未就绪导致所有候选源一起失败
  - 单个候选源失败改为 INFO；只有最终失败/部分失败记 ERROR，避免把降级尝试计入「重启错误数」
  - 只有 GitHub 与 FCM 都更新成功才写 24 小时时间戳；部分失败时下次启动会重试，不再被一次部分成功挡住
- 修正 DNS 状态误导
  - `manual.sh status` 不再只判断 `REDIRECT_DNS` 链是否存在；改为调用 `dns.sh check`，同时核对当前实际监听端口，并显示「服务名:端口」
  - `dns.sh` 的入口选择统一记录服务名，日志与检查结果不再只有裸端口
  - 直通模式下 `dns.sh check` 返回「直通模式(不劫持 DNS)」，不再误报规则缺失
- WebUI 去重与语义整理
  - 服务页按钮改为「启动/停止/重启全部服务」；明确「重启」不刷新网络
  - 「恢复运行(软重启后)」统一为服务页的「软重启后恢复」，工具页不再重复；说明其会重挂 hosts、启动监控并按设置刷新网络
  - 检测到待激活包时，服务页按钮自动变为「激活并恢复新版」；`manual.sh resume` 也会先激活再恢复，不再出现「恢复完成但仍是旧版本」的歧义
  - `activate_module` 先把旧版本暂存到 `/data/adb/SAM.old.<pid>`，新包移动失败时自动恢复，避免激活中途失败留下空目录
  - 待激活包出现时，服务页额外显示提示，避免把旧版本运行误认为新版本已生效
  - 监控页新增「DNS 入口」：显示 53 端口当前转发到 Mihomo/AGH/SmartDNS 的哪个端口，并说明规则正常不等于有查询经过
  - 移除工具页重复的「检查/重建 DNS 规则」，统一到监控页；「更新内核」更名为「更新内置组件」；卸载移入工具页「危险操作」
  - 修正服务角色文案（SmartDNS 解析、AGH 过滤、Mihomo 代理）、「打开」→「打开面板」、DNS 结构模式选项与 Mihomo 增强模式文案
- 服务启动依赖收口
  - 三服务统一通过 `base.sh` 的 `service_exec` 启动；`busybox setuidgid` 或独立 `setuidgid` 不可用时降级为 root 并记录 ERROR，避免三服务一起静默失败
  - 诊断脚本同步显示降级风险，不再把该情况报告成“三服务都无法拉起”
- IPv6 DNS 阻断优化
  - 优先用 REJECT：UDP `icmp6-port-unreachable`、TCP `tcp-reset`，让解析器立即回退 IPv4，减少 WiFi 下等待 IPv6 DNS 超时
  - 内核/ip6tables 不支持 REJECT 时自动回退 DROP，并把探测结果写入 `tmp/ipv6.block.mode`，守护循环不会反复删加规则
- AGH schema 与配置恢复
  - AGH 校验失败时记录具体原因（`yaml` / `schema` / `encoding` / `generate`），WebUI 显示「配置版本不兼容」等明确状态
  - 新增 `scripts/agh_reset.sh` 与内置模板：先完整备份并保留单文件副本，再重置、按 `setting.conf` 重写并校验；WebUI「危险操作 → 重置 AGH 配置」调用
  - 刷入时若旧 AGH 配置 schema 高于新包模板，安装日志会提示回退风险
  - 组件更新日志记录 AGH 版本与配置 schema，并提示大版本升级后回退的恢复方式
- 诊断与文档
  - 诊断脚本新增当前 DNS 入口核对、系统私人 DNS(Private DNS) 状态、IPv6 阻断方式
  - README/AGENTS 补充 DNS 计数延迟、缓存、私人 DNS、IPv6 REJECT、AGH 重置与 WebUI 按钮语义

# 2026.10.24.16
- 默认关闭 Mihomo
  - `setting.conf` / `setting.sh` 默认值改为 `MIHOMO_ENABLE=false`；新安装不再默认拉起代理/TUN
  - 已有 `setting.conf` 保留用户原值；需要代理时开启并填写 `SUB_URL`
- AGH 启动前配置校验
  - 启动前执行 `AdGuardHome --check-config`；失败时把校验输出写进 module.log，并在 `tmp/agh.config.bad` 记录配置 cksum
  - 守护循环发现同一份坏配置时暂停自动拉起，只提示一次；配置内容变化或手动重启后才重试
  - WebUI 服务页 AGH 状态显示「配置错误」；监控页新增「AdGuardHome 配置」状态
- SmartDNS 启动失败日志
  - 失败时把 `tmp/smartdns.log` 最后 5 行写入 module.log；`smartdns.out` 只有 wrapper 提示，不能定位原因
- 配置 BOM/CR 清洗
  - AGH/SmartDNS 启动前由 `sanitize_config` 去掉 UTF-8 BOM 与 CR，并备份原文件
  - 检测到 UTF-16 时明确报错、拒绝自动转换（请另存为 UTF-8）
- 集成一键诊断
  - `tools/diagnose.sh` 移到 `scripts/diagnose.sh` 随模块打包
  - WebUI 工具页新增「一键诊断」；脚本补充 `smartdns.log` 尾部输出
- 文档: README/AGENTS 同步默认 Mihomo 关闭、AGH 校验、配置清洗与一键诊断

# 2026.10.23.15
- 继续修模块描述不更新
  - `desc.sh`/`customize.sh` 不再用 awk 改 description，改为逐行重写，
    兼容设备上 awk 不支持 ENVIRON 或转义差异的情况；写后校验 description 行存在
  - WebUI 服务页增加「待激活更新」徽章：发现 `/data/adb/modules_update/SAM` 时提示，
    避免把待激活包的错误描述误认为服务没启动
  - 监控页增加「模块描述」实时显示 `module.prop` 里的实际值，用来区分：
    描述没写成 / 管理器缓存旧列表 / 待激活包
  - 明确: **软重启不会激活 modules_update 里的新包**，必须完整重启或使用「工具 → 激活模块」
- 保留 v20261023.14 的 WiFi 修复：自动刷新 10 分钟节流、服务全部恢复才刷新、
  stopped-by-wifi 不写异常标记、手动/保存配置 force
- 文档: README 增加 WiFi 慢/5G 正常的隔离排查步骤（直通模式、停 Mihomo、IPv6/双栈/测速、TUN MTU/CPU）

# 2026.10.23.14
- 修复 KernelSU 模块描述长期显示「模块未启动」
  - 开机阶段描述改为「正在启动（等待服务就绪）」，服务就绪后由 `desc.sh` 更新为实际状态
  - `desc.sh` 写 module.prop 改为临时文件 + 原子替换，并真实记录写入成功/失败（原实现失败了也记“已更新”）
  - 刷入后未重启时，`modules_update` 里的待激活包描述改为「已安装，待重启/激活生效」，
    不再显示为新包的「模块未启动」；安装时 `customize.sh` 也会写入该状态
  - 说明: 此时 WebUI 仍由旧 active 模块提供服务；重启或「工具 → 激活模块」后新版本才生效
- 修复 WiFi 反复开关/重连
  - `refresh_network` 增加 10 分钟自动刷新节流和目录锁互斥，服务反复掉线时不会反复开关飞行模式
  - 自动刷新只在所有启用服务真正恢复后执行；任一服务仍启动失败时跳过，
    避免永久失败的服务每轮都拖着重启 WiFi
  - 手动「刷新网络」和保存配置触发的刷新传 `force`，不受节流限制
  - WiFi 黑名单触发的 `stopped-by-wifi` 不再写入“服务异常退出”标记，
    避免「刷新 → WiFi 断开 → 监控启动/停止」的循环
  - `manual.sh resume` 现在尊重 `NETWORK_REFRESH=false`，不再强制刷新
- 文档同步: 模块描述刷新/待激活说明、网络刷新节流与手动刷新语义

# 2026.10.23.13
- 自动清理已卸载 App 的广告锁定，缓解 `chattr +i` 阻止系统卸载清数据
  - 新增 `ad.sh cleanup`：包已不存在时解除 immutable、删除我们建的空壳；
    默认保留 `.samhold` 备份，`cleanup purge` 才删除孤儿备份
  - 服务启动时执行一次；守护循环在备份清单非空时每 5 分钟后台执行一次
  - `ad.sh block/recovery/cleanup` 增加进程锁，避免启动、守护循环与 WebUI 并发改写清单
  - WebUI 工具页新增「清理已卸载 App 的锁定」与「清理已卸载 App 及备份」
  - 说明: immutable 与系统卸载删除数据本质冲突，shell 层无法在卸载前拦截；
    系统卸载当下仍可能提示删除数据失败，但不会再永久留下锁定空壳
- TUN 规则自愈补全
  - 现在同时校验 v4 的 `-o`/`-i`；内核支持 ip6tables 时也校验 v6 两个方向，
    任一规则丢失都会重新调用 `mihomo.sh add`，不再只检查 v4 `-o`
- 设置写入临时文件移出模块根目录
  - `setting_api.sh` 的 `setting.conf.prepare.$$` / `.tmp.$$` 改放 `tmp/`，
    极端崩溃时不会在模块目录留下配置残片
- WebUI 操作防连点
  - 服务启动/停止/重启、挂载切换、监控启停增加互斥标记，
    避免快速双击造成并发 start 或重复 bind mount
- 文档补充: 广告屏蔽与 App 卸载的关系、`cleanup` 的两种模式与孤儿备份处理

# 2026.10.23.12
- 修复 WebUI 设置保存链路
  - `setting_api.sh get` 漏掉 `SMARTDNS_RESPONSE_MODE`，设置页读不到当前值；保存时还会提交空值导致整次保存失败/或静默重置为 first-ping
  - 保存时逐个比较新旧值，只写真正变化的项；`apply` 无变化时不再重启服务
  - 服务处于停止状态时清空待应用标记，避免后续无关的 apply 突然开关飞行模式
  - `prepare_conf` 改为临时文件 + mv 原子替换，避免守护循环读到写了一半的配置
  - 挂载页改用 `mount -o bind`，并同步写 `HOST_ENABLE`；修正页面里的源路径
- 修复打包与 CI
  - `normalize_bytes` 里的 `b"\\r\\n"` 是字面量反斜杠，不是 CR/LF，导致工具从未真正做 LF 规范化；本机（core.autocrlf=true）打出的 zip 会带 CRLF，设备端脚本全部无法解析
  - 新增 `.gitattributes` 强制文本文件以 LF 入库/检出；工作区已统一为 LF
  - 语法检查改为 stdin 传入，规避 Windows/MSYS 路径反斜杠被吞
  - `--check --no-write` 也检查 CR；CI 增加广告屏蔽回归测试
  - `test_ad_sh.py` 显式 UTF-8 解码，Windows 下可直接运行
- 修复 hosts 不生效
  - `update/host.sh` 用 mv 原子替换后 inode 变了，bind 挂载仍指向旧文件；
    现在写入后显式重挂，并把 host 监控改为监听 `etc/` 目录、处理 moved_to/close_write 事件
  - 服务启动时更新 hosts 会做 24 小时节流；手动/定时更新用 `update force` 强制刷新
  - 增加 hosts 内容格式校验，拒绝代理返回的 JSON/纯文本错误页
- 修复直通模式
  - Mihomo 的 TUN `auto-route + dns-hijack` 会在路由层继续劫持 DNS；
    直通开启时暂停 Mihomo，关闭后由守护循环自动恢复
- 修复开关副作用
  - 关闭「屏蔽 App 广告文件」会真正执行恢复，不再留下锁定空目录
  - 关闭「屏蔽 IP 规则」会清理历史规则；`ip.sh` 改为幂等、保留 CIDR、移除 127.0.0.2
  - 停止服务改为先删 DNS/TUN/IP 规则再停进程，避免 DNS 短暂进黑洞
  - 模块被禁用/移除时同步卸载 hosts、停止监控；`uninstall.sh` 改为同步执行，避免 Magisk 删除目录后备份/广告恢复才跑
  - 手动安装升级会先备份并保留旧 setting/AGH/名单/hosts/提供商缓存
- 安全加固
  - 配置备份从 `/sdcard` 移到 `/data/adb/SAM-backup`（root-only），避免订阅链接/节点密码被普通应用读取，也避免 restore 被篡改成 root 命令入口
  - Mihomo 控制端、mixed-port 与 DNS 始终只监听 127.0.0.1；LAN_ACCESS 只开放 AGH 面板/DNS 与 SmartDNS DNS，不再暴露无鉴权控制面和开放代理
  - 订阅地址/排除节点提前拒绝会破坏 YAML 的引号/反斜杠
- 配置健壮性
  - AGH 的端口、upstream、bind_hosts 改为锚定解析；`cache_enabled` 缺失时主动补 false
  - AGH 升级时保留 `AdGuardHome.yaml` 与 `data/filters`，不再重置用户过滤器
  - 端口范围/冲突、测速方式、TUN 网卡名、TTL 做严格校验
  - `customize.sh` 找不到目标键时不再让 sed 覆盖整个配置
- 内核更新
  - 下载加连接/总时长超时；替换前停服务，避免 ETXTBSY/SIGBUS
  - 替换后做 `-v` 自检，失败自动回滚并保留/清理 .bak
  - 修复 Mihomo 压缩包重命名逻辑：版本号里的点会被当成扩展名截断，实际文件总是找不到
- 性能
  - watchdog：服务存活仍 5 秒检查，iptables/DNS 链与日志轮转降为 10 秒；服务刚拉起时立即重建
  - WiFi 监控每轮只取一次 SSID，优先 `cmd wifi status`；手动停止后不再轮询
  - rule-provider 刷新从 3 小时改为 24 小时，关闭 ASN 每日自动更新
  - SmartDNS 日志级别 info -> notice；AGH 查询日志只保留内存；服务 stdout 日志统一轮转
  - 描述更新缓存 Mihomo 内核类型，避免每次启停都执行 60MB+ 二进制
- 其他
  - 所有 `.sh` 补齐 shebang；移除未使用的 `update_smart.json`
  - 新增端口监听校验：进程活着但端口没监听时不再把 DNS 重定向到死端口

# 2026.10.21.11
- 修复「host 规则获取失败」: 改为多源逐个降级
  - 原因: `raw.githubusercontent.com` 在国内移动网络下经常超时或被限速,
    而原实现只有一个主源 + 一个 jsdelivr 备用, 主源一挂整条规则就落空
  - 现在每条规则配 3 个候选源, 依次尝试直到取到有效内容:
    1. 直连 raw(网络好时最快)
    2. ghfast.top 代理(国内可用的 GitHub raw 加速)
    3. cdn.jsdelivr.net(另一个 CDN)
  - 日志会明确打出每次尝试的源与最终采用的源, 便于判断走的是哪条链路
- 修正 `curl` 缺少 `-f` 导致错误页被当成 hosts 内容写进去
  - 没有 `-f` 时 404/500 也会输出正文, 代理的报错页长度超过阈值就会通过校验,
    反而把垃圾内容写进 hosts 文件
  - 另加一道 HTML 特征检查(`^<` / `^!DOCTYPE` / `^html`), 识别代理与错误页
- 修正 awk 里的 `$1a` 笔误(应为 `$1`): GNU awk 下恰好等价, 但换实现就可能出错
- 修正 `get_host` 只能拿到第一个候选源的问题
  - 原实现用 `for i in ${2}`, 只能遍历到第 2 个参数, 多个候选源时后面的根本不会试
  - 改为 `shift` 后遍历 `$*`; 同时把规则名称在 shift 之前存进 `host_name`,
    避免 shift 后 `$1` 变成含斜杠的 URL 拼进 sed 表达式报 `unknown command: '/'`

# 2026.10.21.10
- 广告屏蔽改为「移走 + 保留备份」: 屏蔽不再删除数据
  - 旧行为: `rm -rf` 删掉 App 广告缓存目录里的全部内容并锁死,
    恢复时只能删掉空壳, **原数据永久丢失**
    - 受影响的不只是缓存: 路径列表里有 11 条 `shared_prefs/*.xml`
      (App 的 SharedPreferences 配置, 清空后 App 会丢本地设置)
  - 新行为: 屏蔽时把原内容**改名**到 `<路径>.samhold`, 原位置重建一个空的锁定目录
    - 屏蔽效果与清空完全相同(App 看到的仍是存在但为空、不可写的目录)
    - 恢复时改回原名, **数据原样还原**
    - 用同文件系统内的 rename 实现: 零额外空间, 屏蔽几乎不耗时
    - 备份与原路径同生命周期: App 被卸载时 /data/data/<包名> 整体被删, 备份跟着消失, 不留垃圾
  - 备份清单: `/data/adb/SAM-ad-hold.list`(在模块目录外, 模块重装不会丢)
  - 新增 `ad.sh hold` 子命令: 列出备份路径与占用总量
  - 「影响范围」列表状态扩展: 已锁定(有备份) / 已锁定(无备份) / 存在未锁定 / 不存在, 并显示各自占用
- 排除 `/data/system/ifw`
  - 它是 Android 的 Intent Firewall 规则目录(存 .xml 由 system_server 扫描执行)
  - 屏蔽它收益极低(目录本就几乎为空), 却会清掉用户或其它模块写入的 IFW 规则
  - 已从路径列表移除, 并加进 `ad_exclude` 作为双保险
- 修正路径列表里的 5 条重复条目(153 -> 147 条)
- 修正数组展开的拆词隐患
  - `for ad in ${ad_path[@]}` 未加引号时, shell 会对元素再做一次路径名展开:
    好处是 `*` 通配符自动生效, 坏处是**含空格的路径会被按空格拆开静默失效**
  - 改为 `"${ad_path[@]}"` 保住路径完整性, 含 `*` 的项由 case 分支显式做通配符展开
- 修正「影响范围」列表的解析范围
  - 原判断只要求「含引号」, 脚本函数体里带引号的行也会被当成路径条目混进列表
  - 收紧为「整行是双引号包裹的路径」且「以 / 开头」
- 卸载时清理备份清单(它在模块目录外, 不会随模块目录一起删)
- 设计与实现细节见 `docs/ad-block-hold-design.md`

# 2026.10.21.9
- 修复 v20261021.8 引入的严重回归: 修改设置后保存不生效
  - 原因: 上一版把去 CR 的写法从 sed 换成 tr 时，反斜杠转义被编辑工具破坏，
    实际写进文件的是 tr -d 换行符，会把 setting.conf 的所有换行删掉
  - 后果: 配置文件被压成一行且以 # 开头(整行变成注释)，
    load_setting 读进去全是默认值；set 又会把压平的文件写回原文件，配置被逐步摧毁
  - 表现为: 改设置 -> 保存 -> 重开设置页看到还是旧值
  - 改用八进制写法 tr -d CR 的八进制转义，语义明确且不会被子工具转义破坏
  - customize.sh 里同样的两处一并修正
  - 已实测验证: LF 文件往返 / CRLF 文件清洗 / 数组 setarr / 原地替换均正常
- 简化「保存并应用」后的提示
  - 原因: service.sh restart 的详细过程(几十行)原本直接透传到 WebUI 的 toast，没法读
  - 这些内容 log 函数本来就同时写进了 module.log，stdout 侧属于重复
  - 现在只返回一行结论；重启过程出现 ERROR 时附带条数，引导去日志页查看

# 2026.10.21.8
- 修正 `rr-ttl-min` 取值: 60 -> 600
  - 官方 FAQ 明确建议「10~30 分钟」(600~1800 秒)，60 秒远低于下限
  - 配合 `prefetch-domain`(到期前 5 秒预取) 与 `serve-expired`(过期仍返回并后台刷新)，
    缓存条目实际不会真的过期，同时不会让 CDN 切换后的旧 IP 停留过久
  - `SMARTDNS_TTL_MIN` 默认值同步为 600
- 修复「定时任务备份能存进去但恢复不出来」
  - 原因: 备份用 `cp -f src target_dir/`(存成目录里的同名文件)，
    恢复时按同一相对路径拼回变成 `<备份>/etc/crontabs/etc/crontabs/root`，路径重复
  - 改为保留完整相对路径: `cp -f src <备份>/<相对路径>`
- 修复「模块描述更新可能整体失败」
  - 原因: `sed "s/description=.*/description=${out_content}/g"` 用 `/` 作分隔符，
    描述里一旦出现路径(含 `/`)就直接报 `unknown option to 's'`，描述停留在旧状态
  - 改用 awk 整体重写该行，替换文本经环境变量传递，无需转义
- 修复「hosts 文件可能被写成半截」
  - 原因: `update/host.sh` 直接 `> ${HOSTS_FILE}` 覆盖写，中途出错(磁盘满/被杀)会留下残缺文件，
    而 hosts 是系统启动必需文件
  - 改为先写临时文件、校验非空且含 hosts 标记后再原子替换
- 修复「CRLF 清洗在 busybox/toybox 上可能失效」
  - 原因: `sed -i 's/
$//'` 里的 `
` 作为替换文本中的换行符只有 GNU sed 保证支持，
    busybox / toybox sed 行为依版本而异；一旦不生效，CRLF 残留会让 `sh -n` 预检失败，
    把好配置误判成坏配置
  - 改用 `tr -d ''`，各实现语义一致，还少一次进程
  - `customize.sh` 里同样的写法一并修正
- 性能: `isRun` 去掉 `echo | grep` 判断
  - 改成 shell 内建 `case`，每次调用少两个 fork
  - 该函数全项目 50+ 处调用，守护循环每 5 秒调 6~8 次，省下的是每天几十万次进程创建
- 性能: `webui.sh allstatus` 不再重复取进程状态
  - 三个服务的运行状态取一次后复用，`process` 数值由它算出
  - DNS 规则检查不再 fork 完整的 `dns.sh check`(那会重新 source 一遍 base.sh 并写临时文件)，
    改为直接查 iptables；端口选择顺序与 `dns.sh` 的 `select_dns_port` 对齐，避免误报

# 2026.10.21.7
- 缓存职责归位: AdGuardHome 关闭 DNS 缓存，由 SmartDNS 独占缓存层
  - 原因: 上游 SmartDNS 本就带缓存(`prefetch-domain` / `serve-expired` / `cache-persist`)
    - AGH 再叠一层缓存有两个问题:
      1. 双份缓存白白吃内存(本模块最怕的就是内存紧张被 LMKD 杀)
      2. AGH 缓存会把 SmartDNS 选出的最优 IP 直接冻结，
         后续查询命中 AGH 缓存，绕过 SmartDNS 的测速与选优逻辑
  - SmartDNS 官方文档也明确: 开启缓存后不论用哪种 response-mode 都会把最佳结果存进缓存
  - `update/agh.sh` 每次启动都会校正为缓存关闭
- 修复「AGH 面板上 3721 上游延迟 100ms」: 根因在 SmartDNS 的 `rr-ttl-min`
  - 原值 5 秒会把上游返回的 TTL 一律压到 5 秒，缓存形同虚设，
    5 秒后每个域名都要重新解析 + 重新测速(`first-ping` 下每次冷查询都要等 ping 往返)
  - 改为 60 秒(与官方默认一致)，缓存命中率上来后冷查询本身就不常发生
  - `SMARTDNS_TTL_MIN` 默认值同步改为 60(设置页可继续调整)
- 保持不变: `serve-expired-reply-ttl 5` 与 `speed-check-mode ping,tcp:80,tcp:443`
  - 前者是「过期缓存返回给客户端的 TTL」，官方推荐 3~5 秒，调大会让客户端长时间拿着失效 IP
  - 后者与 `response-mode first-ping` 耦合(去掉 ping 会让 first-ping 退化)，不单独改动

# 2026.10.21.6
- 修复「跑着一阵子后 AGH 与 SmartDNS 一起消失，看门狗也没记录」
  - 原因 1: 服务进程挂在调用方会话上(经 WebUI 启动)，会话被回收时进程一起被杀
    - 所有服务与守护循环改用 `setsid` 脱离会话启动
  - 原因 2: AGH 与 SmartDNS 是内存大户，系统内存紧张时被 LMKD 优先回收
    - 启动后把 `oom_score_adj` 设为 `-1000`，守护循环自身同样受保护
  - 原因 3: SmartDNS `cache-size -1`(按内存自动放大) 占用可观内存
    - 改为固定 `cache-size 4096`
  - 守护循环启动时打一条日志，便于确认它是否存活
- 修复「服务恢复了但手机还是没网，必须手动开关一次飞行模式」
  - 原因: `dns.sh enable` 只判断链名是否存在，链在就直接返回；
    服务掉线后回退到另一个端口时，旧链里的 REDIRECT 仍指向已经没有进程监听的死端口，整机 DNS 进黑洞
  - 现在校验「链 + OUTPUT 跳转 + tcp/udp 53 重定向目标端口」，端口变了自动清链重建
  - 新增 `dns.sh check` 子命令，WebUI 与守护循环都用它判断规则是否与当前端口一致
  - 守护循环发现服务异常退出并拉起后，自动重新验证一次网络(开关一次飞行模式)
  - `service.sh stop` 检测到「本该在跑的服务已经消失」时记一笔异常，下次启动后自动刷网络
  - WebUI 工具页新增「刷新网络」按钮，监控页新增「守护循环」「DNS 重定向规则」健康状态
- 修复「日志里查不到掉线原因」
  - `service.sh stop` 不再清空 `module.log`，改为保留上一份为 `module.log.1`
  - 守护循环日志轮转保留最后 200 行，不再整份清空
- 健壮性: `isRun` 在 `pidof` 缺失时回退 `pgrep -x`，避免精简系统上永远判定「未运行」
- 降噪: 「已停止 / 未启用 / 已运行 / 链不存在」由 ERROR 降为 INFO

# 2026.10.21.5
- 新增 SmartDNS 调优项（设置页「SmartDNS 调优」）
  - `SMARTDNS_RESPONSE_MODE`: first-ping / fastest-ip / fastest-response
  - `SMARTDNS_SPEED_CHECK`: none / ping / tcp:443 / ping,tcp:80,tcp:443
  - `SMARTDNS_DUALSTACK`: 双栈 IP 优选开关
  - `SMARTDNS_TTL_MIN`: 缓存 TTL 下限，提高可减少冷查询与测速次数
- 以上四项在 SmartDNS 启动前按设置改写 `smartdns.conf`，值变化才写文件
- 用于定位「AGH 里 3721 上游延迟 100ms」：测速阶段（ping 在移动网络常被限制）与响应模式等待是主因

# 2026.10.21.4
- 安全: 新增 `LAN_ACCESS`(默认 false)。关闭时只监听回环
  - AdGuardHome WebUI: `127.0.0.1:3000`
  - Mihomo: `external-controller 127.0.0.1:9090`、`allow-lan false`、`bind-address 127.0.0.1`、`dns.listen 127.0.0.1`
  - SmartDNS: `bind 127.0.0.1:3721`
  - 开启后恢复 `0.0.0.0` / `[::]`，供电脑等其它设备访问
- 性能: Mihomo `find-process-mode` 由 `always` 改为 `off`（本配置没有 PROCESS-NAME 规则，省掉每连接的进程查找）
- 安全: `run.sh` 提权时参数文件加 `umask 077`，避免 `/data/local/tmp` 下被其它应用读取（可能含订阅链接）
- 健壮性: Mihomo 配置改写对 `device` / `enhanced-mode` / `listen` 缺失做了保护，不再出现空值比较报错
- 内核: Mihomo `1.19.31` -> `1.19.32`（android-arm64-v8，已校验 ELF aarch64）
- 版本核对: SmartDNS 48.4 为最新稳定；AdGuardHome 0.107.79 为最新稳定，`1.0.0-b.1` 仍是 beta（新 UI 与新版本方案），默认不采用

# 2026.10.21.3
- 修复软重启后「恢复运行」只有 AdGuardHome 起来、SmartDNS 起不来
  - 原因: SmartDNS 是 musl 动态链接的可执行文件，缺少 loader 软链时 `exec` 直接失败；AGH 是静态 Go 二进制所以不受影响
  - 开机脚本只在真开机时建软链，软重启 / 临时 root 下不会执行
  - 新增 `ensure_module_links()`，在 `service.sh start` 与 `sd.sh start` 时补齐 `bin/smartdns`、`ld-musl-aarch64.so.1`、`ld-linux.so`
- SmartDNS 启动失败时把日志最后一行写进 `module.log`，便于定位是缺 loader、配置错还是端口占用
- 修复改设置后报「设置文件语法错误 ... setting.clean no such file or directory」
  - 原因: `service.sh start` 会 `rm -rf tmp/*`，把其他进程正在用的 `setting.clean.<pid>` 一并删掉
  - 启动时不再清空 tmp；`load_setting` 对清洗文件缺失做重试与兜底
- 修复「恢复运行」「立即卸载」按钮白底白字：补上背景色

# 2026.10.21.2
- 新增 WebUI「工具」页：15 个按钮覆盖脚本命令
  - 模块: `manual.sh activate / resume / status`
  - 备份: `backup.sh save / list / restore`
  - 广告与 Hosts: `ad.sh block / recovery / list`、`update/host.sh update`
  - 高级: `iptables/dns.sh enable`、`update/agh.sh`、`update/mihomo.sh`、`update/proxy.sh`、`update/desc.sh`
  - 内核: `update.sh`
  - 恢复备份与更新内核需二次点击确认，输出直接回显在页面
- `ad.sh list` 改为批量读取属性：1 次 `lsattr` 替代 153 次，并用参数展开去掉每行的 `sed` fork
- 修复 `list_ad` 在属性文件为空时 `awk` 的 `FNR==NR` 恒成立、导致只输出表头的问题
- README 增加工具页说明

# 2026.10.21.1
- 新增「查看影响范围」：列出广告屏蔽会处理/已锁定的 App 与路径（`sh scripts/ad.sh list`），并在设置页内展示统计
- 修复从 WebUI 启动时 hosts 监控不会启动（挂载动作排在监控之后）
- 修复「切换后刷新网络」的判断时机：改为重启前判定，不再依赖 tmp 里的隐藏文件
- 修复 `setting.clean` 等临时文件在多进程并发解析时互相覆盖（改用 PID 后缀）
- 飞行模式优先使用 `cmd connectivity airplane-mode`，老系统回退 `settings` + 广播
- 设置页折叠标题支持键盘操作（role / tabindex / Enter）
- 变量比较统一加引号；AGH 端口读不到时不再触发数值比较错误

# 2026.10.21
- 新增 `scripts/setting.sh` 配置安全加载：自动处理 BOM / CRLF / 语法错误 / 缺失项，改坏 `setting.conf` 不再导致服务无法启动
- 新增 `scripts/manual.sh` 手动控制：`activate` / `resume` / `start` / `stop` / `restart` / `uninstall` / `status`，全程不依赖重启
- 支持 CVE 临时 root、只能软重启的环境：模块激活与卸载均可当场完成，不再依赖 `remove` 标记 + 硬重启
- 新增 `scripts/run.sh` 提权包装，WebUI 与 `action.sh` 不再强依赖 `su` 命令
- `service.sh` 改为有限等待开机完成，移除 `su -c`，`inotifyd` / `busybox` 缺失时跳过而不是报错
- 修复 `iptables/dns.sh` 入口选择：按进程实际运行状态在 Mihomo / AdGuardHome / SmartDNS 之间逐级回退，避免某个服务没起来就完全不劫持 DNS
- 修复 `wifi.monitor.sh` 中 `pgrep -f` 多模式的错误用法，改为按进程逐个统计
- WebUI 增加「恢复运行(软重启后)」与「立即卸载」按钮，并修复服务状态刷新函数的递归调用

## 本轮新增(借鉴 schalkiii/Adguard-Home-For-Magisk-Mod)
- 新增 `scripts/watchdog.sh` 守护循环：每 5 秒重读配置并自检
  - 改 `setting.conf` 最迟 5 秒生效，不需要重启服务
  - 服务进程被系统杀掉后自动拉起
  - `REDIRECT_DNS` / `BLOCK_IPV6_DNS` / TUN 转发规则被其他模块清掉后自动重建
  - 日志超过 100 KB 自动清空，避免常驻循环撑爆 `tmp`
  - 读取 `tmp/service.state` 区分「手动停止」与「掉线」，不会和停止操作打架
- `iptables/mihomo.sh` 改为幂等：单条规则不存在才插入；删除改为循环删到不存在，兼容历史重复规则
- `iptables/dns.sh` 的禁用逻辑改为循环删除，兼容重复追加的跳转规则
- IPv6 阻断链在链首放行本机解析器(uid+gid 窄匹配)，避免把 SmartDNS 的 IPv6 上游一起打死
- 内核无 IPv6 nat 表且未开启 IPv6 阻断时，显式记录「IPv6 DNS 将绕过本模块」，不再静默失效

## 2026.10.21 第二批(GUI 与打包)
- 新增 `BYPASS_ENABLE` 直通模式：撤销 DNS 劫持但保留服务与 WebUI，守护循环 5 秒内自动生效
- 新增 `scripts/setting_api.sh`：配置读写接口
  - 只替换目标行，完整保留注释、顺序与空行
  - 布尔 / 数字 / 枚举逐项校验，非法值直接拒绝
  - 写前清洗 BOM/CRLF，写后 `sh -n` 自检再原子替换
- 新增 WebUI「设置」页：直通开关、DNS 结构模式、三个服务开关、IPv6 相关、端口、TUN 网卡、Hosts/定时/屏蔽 IP/备份、订阅地址、排除节点、黑白名单
- 新增 `tools/pack_module.py`：打包校验工具
  - 文本强制 LF 并去 BOM，按路径写 0755/0644 权限位
  - 回读校验条目齐全、CRC、内容一致、行尾干净
  - `sh -n` / `mksh -n` 语法检查(有 mksh 时优先)
- `scripts/run.sh` 改为参数文件传递，非 root 提权时不再把参数拼进 `su -c` 字符串，订阅链接里的 `&` `$` 不会被二次解释
- 修复 `setting_normalize` 用未加引号展开导致 `"公司 WIFI"` 这类带空格元素被拆成两个的问题
- 后台常驻进程统一重定向输出，避免 WebUI 调用时管道被占用、命令迟迟不返回

## 2026.10.21 第三批(全量评审修复)
- 修复 WebUI 服务数量统计：`pgrep -f` 同时传多个模式是无效用法，进程数恒为 0，导致启动/停止结果误报
- 服务数量改为按服务计数，并把「没有订阅的 Mihomo」排除在期望值外，不再误报「启动失败」
- 修复 stdout 带换行导致 `== "已运行"` 永远不成立的问题，所有命令输出统一 trim
- 修复 WiFi 黑名单与手动停止互相打架：新增 `stopped-by-wifi` 停止原因，手动停止不再被监控推翻
- WebUI 保存后按需启动/停止 WiFi 监控，新加的黑名单立即生效，不必重启
- 守护循环：缺少 `pgrep`/`pidof` 时直接退出，避免把所有服务误判成掉线并无限重启
- 守护循环：拉起失败增加 30 秒退避；配置 mtime 未变时不再每 5 秒重复解析
- 启动服务时把广告屏蔽与 hosts 更新移到后台，避免离线时「启动服务」卡 20 秒以上
- WebUI 兼容：缺少 `ksu` 接口时不再整页初始化失败；卸载改为按钮二次确认，不依赖 `confirm`
- 保存按钮增加并发保护与「保存中」状态；端口校验 1-65535；白名单关闭时把模式选择置灰
- toast 支持自定义时长，错误信息显示更久
- `action.sh` 菜单完整列出所有选项并用 ▶ 标记当前项

## 2026.10.21 第四批(完整优化)
- WebUI 首屏状态合并为一次 `allstatus` 调用，从约 10 次 exec 降到 2 次
- 新增运行日志面板（刷新 / 清空，默认最近 150 行）
- 设置页分区可折叠；顶部显示「未保存」标记；控件自动补 `aria-label`
- 服务页新增「过滤模式 / 直通模式」徽章
- 新增「切换后刷新网络」开关：只在改动直通开关、DNS 模式或 DNS 端口时开关一次飞行模式（默认开）
- 新增「屏蔽 App 广告文件」开关（`AD_BLOCK_ENABLE`），App 异常时可单独关掉
- 卸载备份扩展为全量配置：setting / AdGuardHome / SmartDNS / Mihomo / 黑白名单 / hosts / 定时，保留最近 5 份
- 服务启动改为轮询就绪（最多 5 秒），不再固定 `sleep 1`
- `setting_api.sh` 增加进程内互斥锁，新增 `logview` / `clearlog` 命令
- 广告过滤新增 GOODBYEADS 规则集与其放行列表（保留原 5MayRain 列表）
- `pack_module.py` 新增 `--no-write`；新增 GitHub Actions 校验工作流
- 版本号提升为 20261021，`update.json` 指向本 fork 的 release




# 2026.09.07
- Mihomo 配置添加 `虚拟组网` 的代理组，筛选名称带有 `ZeroTier | EasyTier` 的节点
- 增加 ZeroTier 和 EasyTier 相关代码配置

## 虚拟组网
- 启动服务时自动处理 ZeroTier 和 EasyTier 的配置
- ZeroTier 添加绑定其网卡接口的节点，使其内网地址，通过该节点连接。获取其 udp 端口。使其通过 `虚拟组网` 连接
- EasyTier 添加绑定其网卡接口的节点，使其内网地址，通过该节点连接。获取其服务器地址和端口，使其通过 `虚拟组网` 连接
- 自建服务端: 如果是国外的服务器，需要在服务器创建节点，Mihomo 添加创建的节点，节点名要有该服务的名称，然后通过`虚拟组网`代理组，选择该节点连接服务，这样才不会丢包严重
