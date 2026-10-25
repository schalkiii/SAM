# SAM 项目审计报告（2026-10-25 第三轮）

> 审计对象：`D:\workspace\SAM`（SmartDNS + AdGuardHome + Mihomo 三合一 Magisk/KernelSU 模块）
> 审计基线：HEAD `c80a3f6`（v20261025.7 已提交，工作区干净；唯一未跟踪文件是本报告）
> 审计期间上游提交了 `63c30a0`（v20261025.7 正文）与 `c80a3f6`（update.json + `__pycache__` 忽略），
> 本报告针对这两个提交之后的代码复核；受影响条目已标注「审计期间已修复」。
> 本报告只记录发现与建议，**未修改任何代码**。

> **执行状态（2026-10-25 晚更新，报告本体保持审计时快照）**：S-2/S-3/S-4/S-5/S-6/S-7/S-8/S-9/S-10 与 S-11 的
> 代码项（A-4/C-2/C-5/C-6）+ 测试补强（T-2/T-3/R-2）已全部实施，随 v20261025.8 提交。
> 落地结果：九套件 327 项（本机 Windows 325 项，`test_ad_sh` 恢复 27/27）；`check_version_sync` 扩到 6 项。
> 未实施：C-7（退出码语义改造，会波及 service/watchdog/apply 三层调用方，风险大于收益）、
> A-5（`main.js` 拆分，收益/风险比待评估）、T-2 中 `manual.sh` 的激活/卸载编排用例（不可逆路径多，
> 本轮只补了 setting 事务与 DNS 参数级用例）。
> 与前两轮的关系：不重复登记已实施项。第二轮 S-1（DNS 入口合一）、S-2/S-4（restore 清残留+幂等注释）、S-3（setting.sh TTL 常量）、S-5（版本门禁）、S-6（AGENTS 门禁清单）、S-7（锁阻塞用例）、S-8（watchdog 测试）、S-9（Mihomo 判定收敛）在本轮逐条复核，其中 **S-3 与 S-9 只完成了一部分**，见 C-3、A-1。
> 编号规则：A=架构、C=代码写法、D=文档一致性、E=文档缺漏、T=测试覆盖、R=测试严谨、G=工程规范。

## 一、现状描述（可观察事实）

### 规模

| 项 | 数值 |
|---|---|
| Shell 脚本 | 33 个：`scripts/**` 29 个 + 根目录 4 个，合计 **7,122 行**（`pack_module.py --check` 自报 33 个） |
| WebUI | `index.html` 494 行 + `main.js` 1,085 行 + `kernelsu.js` 132 行 + `styles.css` 523 行，无构建步骤（浏览器原生 ES module） |
| Python 工具 | 10 个：`pack_module.py` 372 行、`check_version_sync.py` 125 行、8 个测试文件（`test_ad_sh` 299 行等） |
| 随包资源 | `etc/` 约 48MB（AGH 7.8MB / SmartDNS 19MB / mihomo 21MB），发布 zip 约 130MB |
| 单文件最大 | `main.js` 1,085、`ad.sh` 814、`setting_api.sh` 523、`manual.sh` 504、`watchdog.sh` 467、`diagnose.sh` 461 |
| 配置键 | `setting.conf` 27 个（15 布尔 + 2 端口 + 1 TTL + 3 文本 + 4 枚举 + 2 数组），与 `setting_api get` 输出、WebUI `data-key` 数量一致 |
| Git | 单分支 main；线上 Release 停在 v20261025.3；`module.prop`/`update.json`/`changelog.md` 均到 **20261025.7**（已提交，未打 tag；`module.prop` 的 `description` 仍是占位值 `模块未启动`） |

### 结构

- 分层：`base.sh`（路径/锁/日志/探测）→ `service.sh` + `service/{sd,agh,mihomo,crontabs}.sh` → `update/*.sh`（配置生成）→ `iptables/*.sh`（规则）→ `setting*.sh`（配置读写）→ `watchdog.sh`（5 秒守护）→ `ad.sh`（广告屏蔽）→ `webui.sh`（只读采集）。
- 锁体系 8 把目录锁（`service`/`setting`/`ad`/`update`/`watchdog_instance`/`network_refresh`/`host_update`/`wifi_monitor_instance`），实现于 `base.sh` 的 `sam_lock_acquire`，带 PID 陈旧检测。
- DNS 链路：53 → nat `REDIRECT_DNS` → 按 `MODULE_DNS_MODE` 逐级回退（`base.sh dns_entry_port` 为唯一判定源）。
- 测试：8 套件 **253 项断言**，CI（`.github/workflows/check.yml`）9 步全跑，装 mksh 以贴近设备 shell。

### 质量水平（本轮实测）

- `python tools/pack_module.py --check --no-write` **通过**（0 个文件需转换；33 个脚本语法检查用的是 bash，本机无 mksh）。
- `python tools/check_version_sync.py` **通过**（4 项，20261025.7 / 2026102507）。
- 7 套件全绿：`test_cron_validate` 34、`test_tar_guard` 18、`test_owner_probe` 20、`test_backup_semantics` 48、`test_dns_entry` 66、`test_watchdog_logic` 20、`test_module_links`（本机整文件跳过）。
- **`test_ad_sh.py` 本机 26/27，[4]「旧空壳被清理」失败**（根因见 T-1）。CI（Ubuntu）上 stub 能正常生效、用例预计通过，但本机基线并非全绿。
- 代码无 TODO/FIXME/调试残留；LF 入库；`dist/` 与 `__pycache__/` 已 gitignore；工作区干净（HEAD `c80a3f6`）。

## 二、问题清单（按七个审计维度）

### 维度 1 文档一致性 — 结论：**主矛盾已在审计期间修复；残留 1 项低危（AGENTS 描述已删除的实现）**

#### D-1（高，**审计期间已修复**）默认凭据三处真值曾互相矛盾，正好落在 v20261025.7 的发版内容上

- **位置（审计时）**：`README.md` 第 38 行与第 61 行；`AGENTS.md` 第 76 行；`etc/SmartDNS/smartdns.conf`；`etc/AdGuardHome/AdGuardHome.template.yaml`；`scripts/update/desc.sh`。
- **描述（审计时）**：v20261025.7 的实际改动是**恢复 root/root**（`smartdns.conf` 的 `smartdns-ui.password root`、AGH 模板注释「默认密码 root」、`desc.sh` 的「面板账号: root / root」、`changelog.md` 均一致），但 `README.md` 第 38 行的 .7 摘要仍写「默认凭据文案纠正（root/sam123456）」，`README.md` 第 61 行写的是 root，`AGENTS.md` 第 76 行仍写 `sam123456`——同一发版内三处互相矛盾。
- **现状**：`63c30a0` 已把 README 第 38 行改为「默认凭据恢复 root/root」、AGENTS 第 76 行改为 `root`。本轮复核 `grep -n sam123456 README.md AGENTS.md` 无命中，**该项已关闭**。
- **遗留价值**：CI 当时完整放行了这组矛盾（`check_version_sync` 只比版本号），门禁缺口仍在 → 见 **G-1 / S-8**。保留此条是为了让后续 Agent 知道"文档真值不一致"是已经发生过的事故类型。
- **严重程度**：高（发生时的用户影响是登录失败）；**当前状态：已修复**。

#### D-2（低）AGENTS.md 仍描述已被删除的 `dns.sh select_dns_port`，与同文件前文矛盾

- **位置**：`AGENTS.md` 第 66 行（「`current_dns_entry` 计算入口（与 `dns.sh select_dns_port` 同序）」）、对照第 12 行附近已改为 `base.sh dns_entry_port` 的表述；`README.md` 第 39 行（「Mihomo 判定五处收敛」）。
- **描述**：S-1 已把入口链合一到 `base.sh dns_entry_port`，`dns.sh select_dns_port` 现在只是它的一层薄包装（`dns.sh` 第 23-30 行），"同序"这个说法会让人以为仍有两份实现。README 第 39 行的"五处收敛"与实际仍内联 5 处（A-1）不符。
- **影响范围**：AGENTS 是后续 Agent 的约定入口，按"两处实现同序"的心智模型改代码会重复 S-1 的老路。
- **严重程度**：低（表述问题，非行为问题）。

#### D-3（低）小体量注释错误

- **位置**：`scripts/config.sh` 第 26 行（`# 用户组"` 多了引号）、第 31 行与第 33 行（两行都写 `# SmartDNS 路径`）。
- **描述**：复制粘贴残留，不影响行为。
- **严重程度**：低。

### 维度 2 文档缺漏 — 结论：**发现 1 项中危缺漏 + 1 项低危**

#### E-1（中）出厂 crontab 预置了 3 条高风险任务，但没有任何文档说明「启用定时执行」= 每天自动更新组件并重启

- **位置**：`etc/crontabs/root`（3 条有效行）、`setting.conf` 第 53-55 行（`CRONTAB_ENABLE=false` 的注释）、`README.md` 第 57 行（「定时执行」）、`scripts/service/crontabs.sh`。
- **描述**：出厂文件自带：每天 4:00 `scripts/update.sh`（联网替换三个二进制）、每天 5:00 `service.sh restart`（强制中断 DNS）、每周一 8:00 hosts 刷新。WebUI 的「定时任务」卡片默认就会把这三条读出来，用户点「保存」即生效。然而 `setting.conf` 与 README 对「定时执行」只有一句「启用/禁用」，从未说明它包含**自动升级二进制**与**每日重启**。
- **影响范围**：用户以为只是"开个定时"，实际开了自动更新（下载失败/校验失败会走回滚路径）与每天一次 DNS 中断；属于"默认值即危险操作"。
- **严重程度**：中。

#### E-2（低）`docs/` 会随发布包分发，但没有约定说明

- **位置**：`tools/pack_module.py` 第 55 行 `SKIP_DIRS`（含 `.github`/`tools`/`dist`，**不含 `docs`**）、`docs/` 下 4 个 md（含三份审计报告）。
- **描述**：`collect_files` 按目录遍历，`docs/*.md`、`AGENTS.md`、`README.md` 都会进模块 zip。体积影响可忽略，但这些是内部工程文档（含审计结论、已知缺陷清单）。
- **影响范围**：发布包对外暴露内部质量档案；`pack_module --check` 的必需文件清单也没有"是否应包含 docs"的判据。
- **严重程度**：低。

### 维度 3 架构优化点 — 结论：**S-1 已解决；S-9 未收敛干净，且存在第 4/5 份 DNS 选择逻辑**

#### A-1（中高）`mihomo_expected()` 已存在，但仍有 5 处内联同一判定，且其中 1 处口径不同

- **位置**：`scripts/base.sh` 第 394-396 行（`mihomo_expected`，唯一正确实现）；内联副本：
  - `scripts/webui.sh` 第 12、26、168 行（`get_service_number` / `get_process_number` / `get_process_number_from`）；
  - `scripts/setting_api.sh` 第 382 行（`apply_settings` 的成功判据）；
  - `scripts/wifi.monitor.sh` 第 45-50 行（`any_service_enabled`）。
- **描述**：五处都手写 `MIHOMO_ENABLE && ${#SUB_URL[@]} > 0 [&& BYPASS != true]`，其中 `wifi.monitor.sh` **漏了 `BYPASS_ENABLE` 判定**。第二轮 S-9 声称"五处收敛"，实际只改了启动编排与守护循环。直接后果：直通模式 + 只启用 Mihomo 时，`webui.sh` 的期望服务数是 0，而 `any_service_enabled` 仍返回真，WiFi 监控会反复调 `service.sh start`（被直通分支拦下、再停 Mihomo），形成无效启动循环与日志噪声。
- **影响范围**：条件再次漂移时（例如将来"无订阅也允许 Mihomo 用内置配置启动"）需改 6 处；`wifi.monitor` 与 `webui` 的口径不一致已经是事实。
- **严重程度**：中高。

#### A-2（中）`update/mihomo.sh` 与 `update/agh.sh` 各自实现"哪个本地 DNS 活着"，是第 4、5 份选择链

- **位置**：`scripts/update/mihomo.sh` 第 22-30 行（4 级 if/elif）；`scripts/update/agh.sh` 第 85-102 行（4 级 if/elif + 公共 DNS 兜底）。
- **描述**：S-1 把"53 该转发到哪"收敛为 `base.sh dns_entry_port`，但"下游服务的上游该指向谁"仍在两个 update 脚本里各写一遍。两者语义与 `dns_entry_port` 平行（都排除自身），且都没有测试锚定：`test_dns_entry.py` 只覆盖 3 个消费方，不含这两个 update 脚本。
- **影响范围**：调整回退顺序（例如"SmartDNS 优先于 Mihomo"）时漏改一处，会出现"入口正确但上游指向死端口"，表现为 AGH 上游超时、解析变慢，且 `diagnose.sh` 的"DNS 入口"显示正常，极难定位。
- **严重程度**：中。

#### A-3（中）根 `service.sh` 用绝对路径自建 SmartDNS 软链，与 `base.sh` 的规则相反且不修悬空链

- **位置**：根 `service.sh` 第 31-36 行；对照 `scripts/base.sh` 第 39-70 行（`repair_module_link` / `ensure_module_links`）、`scripts/manual.sh` 第 119-134 行（`fix_symlink`）。
- **描述**：开机路径建链用**绝对目标**（`${MODULE_PATH}/etc/SmartDNS/smartdns`），守卫是 `[ ! -e ] && [ ! -L ]`；`base.sh` 用的是**相对目标**且"悬空链（`-L` 真 / `-e` 假）必须删掉重建"。v20261025.5 修的正是"绝对路径 + 悬空链被守卫跳过"这个组合，但只修了 base.sh 与 manual.sh，根 `service.sh` 保留旧写法。当前能侥幸工作，是因为开机后 `scripts/service.sh start` 会再跑一次 `ensure_module_links` 兜底。
- **影响范围**：三份建链实现、两套规则；若将来有人删掉 start 里的 `ensure_module_links`（看似冗余），开机路径会重新退回 v20261025.5 的故障形态。
- **严重程度**：中。

#### A-4（低）三条卸载路径并存且行为不一致

- **位置**：`uninstall.sh`（第 35-62 行）、`scripts/manual.sh` 第 392-455 行（`uninstall_module`）、`scripts/inotify/module.sh` 第 44-59 行（remove 事件）。
- **描述**：三者都做"停服务→备份→广告恢复"，但只有前两者在恢复成功后删除 `/data/adb/SAM-ad-hold.list`、清理 `/data/adb/SAM.previous`、`SAM.rejected.*`、`SAM.old.*`；`inotify/module.sh` 的 remove 分支不删清单、不清理历史版本目录。正常卸载走 `uninstall.sh`，所以 inotify 分支是"补刀"，行为差异被掩盖。
- **影响范围**：若 Magisk 在某版本改为只发 remove 事件而不执行 `uninstall.sh`，残留清单与 `SAM.previous` 会让 `repair` 复活已卸载模块（这正是 v20261025.1 修过的问题）。
- **严重程度**：低。

#### A-5（低）`main.js` 仍是单文件 1,085 行

- **位置**：`webroot/js/main.js`（第二轮 C-2 提出，未处理）。
- **描述**：状态轮询、设置表单、工具按钮、日志、广告范围、定时任务、导航、剪贴板全部在一个文件；新增"一次保存多个事务"（C-8）会让它继续变长。
- **影响范围**：改动相互影响、只能靠 `node --check` 兜底语法。
- **严重程度**：低（本轮不主张拆分，见建议 S-9）。

### 维度 4 代码写法 — 结论：**未发现新的功能性缺陷；发现 1 项语义耦合、1 项状态残留、1 项单点硬编码、3 项脆弱写法**

#### C-1（中）`watchdog.sh` 的"端口未监听"分支日志说"移除规则"，实际调用的是 `dns.sh enable`

- **位置**：`scripts/watchdog.sh` 第 255-266 行（`case ${dns_check_rc} in 2)`）。
- **描述**：`dns.sh check` 返回 2 表示"有进程但没有可用入口（`DNS_PORT` 为空）"，此时 `dns.sh enable` 会走到自己的 `else` 分支把重定向与 v6 阻断一起清掉（`dns.sh` 第 299-306 行）。也就是说，守护循环靠"`enable` 在空端口时的副作用"完成清理，日志文案与命令名完全相反。任何对 `dns.sh enable` 空端口分支的改动（例如改成"空端口时直接 return"）都会让这段守护逻辑静默失效——DNS 继续指向死端口。
- **影响范围**：整机 DNS 黑洞（v20261024.18 同类故障的真实形态）；且这种耦合没有任何测试保护。
- **严重程度**：中（当前行为正确，但脆弱度不匹配后果）。

#### C-2（低-中）WebUI 的 hosts 挂载开关直接改配置、不 `apply`，失败时配置与状态不一致

- **位置**：`webroot/js/main.js` 第 815-862 行（`mountControls`）、`scripts/setting_api.sh` 第 462-493 行（`set` 写入 `${TMP_PATH}/.setting_changed`）。
- **描述**：`mountControls` 先 `setting_api.sh set HOST_ENABLE=<取反值>`，再单独 `mount`/`umount`；若 `mount` 失败，配置已变成 `true` 但实际未挂载（反过来则是 `false` 但仍在挂载）。同时 `set` 留下的 `.setting_changed` 只有 `apply` 会清，WebUI 这条路径从不 `apply`。
- **影响范围**：下次服务启动按 `HOST_ENABLE` 重新挂载/卸载，用户看到的状态与刚才的 toast 相反；残留标记还会让随后任意一次 `apply` 以"有变更"为由重启服务。
- **严重程度**：低-中。

#### C-3（中）TTL 边界在 `main.js` 仍是硬编码（第二轮 S-3 只做了一半）

- **位置**：`webroot/js/main.js` 第 522-531 行（`const min = isTtl ? 60 : 1; const max = isTtl ? 86400 : 65535;`）；对照 `scripts/setting.sh` 第 11-13 行（`SMARTDNS_TTL_DEFAULT/FLOOR/CEIL` 单一定义）、`scripts/setting_api.sh` 第 256-258 行（引用常量）。
- **描述**：第二轮 S-3 只在 `setting.sh` 内收敛默认值，边界值的三层（加载/接口/WebUI）里 WebUI 这一层仍写死 60/86400。修改边界时前两层自动跟随、WebUI 不会。
- **影响范围**：出现"WebUI 放行但服务端拒绝"或反向矛盾，用户看到"保存成功但配置没变"。
- **严重程度**：中（第二轮明确列为需单一来源，尚未闭环）。

#### C-4（中）WebUI 保存是"两次独立事务"，标量写成功而数组写失败时无补偿

- **位置**：`webroot/js/main.js` 第 550-576 行；`scripts/setting_api.sh` 第 462-534 行（`set` 与 `setarr` 各自 `begin/commit`）。
- **描述**：`saveSettings` 先 `set`（全部标量，一次事务提交），再逐项 `setarr`，最后 `apply`。任一 `setarr` 失败会立即 `return`，此时标量已落盘、数组未改、`apply` 未执行——配置文件处于"半套新值"状态，服务仍在跑旧配置。
- **影响范围**：用户以为"保存失败=什么都没变"，实际重启服务后新标量才生效；无回滚、无提示"部分已保存"。
- **严重程度**：中。

#### C-5（低）`ad.sh` 两处统计/展开边界

- **位置**：`scripts/ad.sh` 第 391-459 行（`block_ad` 末尾 `let "block_number++"`）、第 767-770 行（`lsattr -d $(cat "${ad_paths}")`）、第 353 行（`for exclude_path in ${ad_exclude[@]}`）。
- **描述**：① 目标既不是目录也不是普通文件时（符号链接等）两个分支都不进，但 `block_number` 仍自增，日志"已屏蔽 N 个"虚高；② `lsattr -d` 未加引号展开，路径含空格会拆词；`ad_exclude[@]` 同理（当前排除项无空格，属隐患）。
- **影响范围**：诊断数字失真；未来加含空格路径即失效。
- **严重程度**：低。

#### C-6（低）`update/mihomo.sh` 依赖行号 + `sed i/c` 改写 YAML，`add_smart_conf` 混用两份快照

- **位置**：`scripts/update/mihomo.sh` 第 309-312 行（第一次 `profile:` 定位用的是 `modify_sub` 阶段的旧 `${content}`，其余用刚重读的当前文件）。
- **描述**：整份配置靠"算行号再 `sed i`"生成，插入顺序与行号漂移靠"所有已发生的插入都在 `profile:` 之下"这一巧合成立；`add_smart_conf` 第一次定位用旧快照、之后用新快照，两套数据源混用一个变量名。
- **影响范围**：`base.yaml` 若调整段顺序（或订阅数为 0 与 >0 走不同插入量），插入点会错行，生成非法 YAML；好在末尾有 `mihomo -t` 校验兜底（失败保留原配置）。
- **严重程度**：低（有自检兜底，但可读性与可维护性差）。

#### C-7（低）服务脚本用退出码 1 表示"已运行/已停止"这类正常态

- **位置**：`scripts/service/sd.sh` 第 8-17 行、`scripts/service/agh.sh` 第 16-25 行、`scripts/service/mihomo.sh` 第 8-22 行。
- **描述**：`start` 在"未启用"或"已运行"时 `return 1`，`stop` 在"未运行"时 `return 1`。现有调用方（`service.sh`、`watchdog.sh`）都忽略 rc 后面再查 `isRun`，所以没出错；但 `setting_api apply` 已经开始用"退出码 + 进程数"双判据，任何新调用方直接信 rc 都会把正常态判成失败。
- **严重程度**：低（语义陷阱）。

### 维度 5 测试覆盖率 — 结论：**关键不可逆模块仍无覆盖；新增 1 项高优先问题（本机基线非全绿）**

#### T-1（高）`test_ad_sh.py` 在开发机上 26/27，stub 注入在 MSYS 下完全失效

- **位置**：`tools/test_ad_sh.py` 第 158-168 行（`run_ad` 用 `os.pathsep` 拼 PATH 注入 stub）、第 88-95 行（`make_stubs`）；失败用例在 `main()` 的 `[4]`（第 245-252 行）。
- **描述**：实测 `command -v lsattr` 解析到 **`/usr/bin/lsattr`（Git Bash 自带的真实程序）**，而不是测试目录里的 stub：MSYS 的 `sh.exe` 启动时会把自己的 `/usr/bin`、`/ucrt64/bin` 前置到 `PATH`，并且把 Windows 的 `;` 分隔 PATH 转成 `:`，注入目录既排在后面又被截断。因此 chattr/lsattr 模拟整体不生效，`is_locked` 永远查不到 `i` 属性，`[4]`「旧版本遗留的锁定空目录能被清理」必然失败；其余用例靠"路径不存在/存在"这类不依赖锁状态的断言侥幸通过。把 `os.pathsep` 换成 `:` 重跑仍失败（已验证）。
- **影响范围**：① 本机跑 `test_ad_sh.py` 稳定红灯，任何人按 AGENTS 的"改 ad.sh 必跑"都会看到伪失败；② 反向风险更大——真实回归（例如恢复逻辑真的不删空壳）在本机会被当成"已知的 1 项失败"忽略；③ CI（Ubuntu）上 stub 生效，本机与 CI 结论不一致。
- **严重程度**：高（回归网本身不可信）。

#### T-2（高）不可逆/高风险模块仍无任何自动化覆盖（第二轮清单未变化）

- **位置/缺口**：`scripts/manual.sh`（504 行，`activate`/`repair`/`uninstall` 全部不可逆）、`scripts/service.sh` + `service/*.sh`（启停编排、锁等待 120/180 秒）、`scripts/update/*.sh` 五个配置生成器（错一个字段服务起不来）、`scripts/update.sh` 的 `get_download_url`（用 `sed` 解析 GitHub JSON 并挑资产）、`scripts/webui.sh` 的 `allstatus`（读路径展示失真）、`scripts/setting_api.sh` 的 `set`/`setarr`（只测了 `cron`）。
- **描述**：本轮新增的 C-4（两次事务）与 C-1（`enable` 副作用）都落在无覆盖区，改动它们目前只能靠人工过一遍。
- **影响范围**：任何重构（尤其 C-1、C-4）没有安全网。
- **严重程度**：高。

#### T-3（中）`test_module_links.py` 在 Windows 上整文件跳过，且不覆盖根 `service.sh` 的建链分支

- **位置**：`tools/test_module_links.py`（本机输出：`当前文件系统不支持 symlink，跳过软链用例`，exit 0）。
- **描述**：该套件只测 `base.sh` 的 `repair_module_link`；A-3 里的根 `service.sh` 绝对路径分支无覆盖。本机跑它等于没跑，却计入"253 项"。
- **影响范围**：A-3 若按建议修复，没有可复用的断言；统计口径（253 项）在 Windows 上实际只执行 233 项。
- **严重程度**：中。

#### T-4（低）新套件缺少"故意改坏实现则必须变红"的变异验证记录

- **位置**：`tools/test_dns_entry.py`、`test_watchdog_logic.py`、`test_module_links.py`。
- **描述**：只有 v20261025.3 对 `restore` 的 `-f` 守卫做过一次变异验证；本轮新增的三个套件未见记录。
- **严重程度**：低。

### 维度 6 测试严谨性 — 结论：**断言具体、模式统一；两处环境依赖削弱可信度**

#### R-1（中）测试从未在设备同款环境（mksh + busybox 工具集）执行

- **位置**：全部 8 个套件；CI `check.yml` 装的是 `mksh` 而非 busybox。
- **描述**：模块大量依赖 `echo -e`、`sed i/c`、`sed -i`、`tr -d '\015'`、`let`、数组展开等 mksh/busybox 行为（`update/mihomo.sh`、`update/proxy.sh`、`customize.sh` 尤其集中）。`mksh -n` 只验语法，不验这些工具的运行时语义。
- **影响范围**：GNU vs busybox 的 `sed`/`echo` 差异只能靠真机冒烟发现；这是当前测试体系最大盲区。
- **严重程度**：中。

#### R-2（中）`test_dns_entry.py` 只到"函数返回值"层，未校验最终 iptables 命令

- **位置**：`tools/test_dns_entry.py`（66 项）。
- **描述**：用例打桩 `isRun`/`is_port_listening` 后断言三处消费方输出一致，但不检验 `dns.sh enable` 真正下发的 `--to-ports`；"规则指向正确端口"仍依赖人读 `check_dns_chain`。
- **影响范围**：`check_dns_chain`/`enable_dns` 的参数错误（例如端口变量用错）不会被抓到。
- **严重程度**：中。

#### R-3（低）stub 用"可执行文件 + PATH"模拟，而非"shell 函数覆盖"

- **位置**：`tools/test_ad_sh.py`、`tools/test_owner_probe.py` 的 mock 手法。
- **描述**：PATH 注入在 MSYS 下会被系统目录抢先（T-1 已实测）；同一模式复制到新测试会重复踩坑。
- **严重程度**：低（属 T-1 的根因归纳）。

### 维度 7 工程规范 — 结论：**基本规范；1 项门禁盲区（基线漂移项已随提交修复）**

#### G-1（中）发版门禁只校验三处版本号，不校验"文档与配置真值一致"

- **位置**：`tools/check_version_sync.py`（4 项检查）、`module.prop` 第 6 行（`description=模块未启动` 占位）、`README.md` 第 36-43 行。
- **描述**：D-1 这类矛盾（README 摘要与实际默认凭据相反）能完整通过 CI；`module.prop` 的 `description` 在仓库里是占位值，发版 zip 里也是占位值，只有首次启动后 `desc.sh` 才改写。`check_version_sync` 已能解析 changelog，扩展成本很低。
- **影响范围**：每次"改默认值/改文案"类发版都可能漏改一处，而门禁不会报警（v20261025.7 已经发生）。
- **严重程度**：中。

#### G-2（低，**审计期间已大部分修复**）交接基线曾漂移：v20261025.7 改动长时间滞留在工作区

- **位置（审计时）**：`git status` 显示 9 个文件已改未提交（`AGENTS.md`、`README.md`、`changelog.md`、`AdGuardHome.template.yaml`、`smartdns.conf`、`module.prop`、`desc.sh`、`update.json`、`webroot/index.html`），HEAD 仍是 v20261025.6；另有未跟踪 `tools/__pycache__/`。
- **描述**：审计期间 `63c30a0` + `c80a3f6` 把上述改动提交，并在 `.gitignore` 补了 `__pycache__/`、`*.pyc`。**当前已干净**。本轮保留此条是为了记录"发版内容与 HEAD 脱节"这一模式：D-1 的矛盾就是在这段滞留期产生的。
- **剩余项**：`module.prop` 的 `description` 仍是占位值 `模块未启动`（随包发布时即为此值，需 `desc.sh` 首次运行才改写）→ 并入 S-8。
- **严重程度**：低（当前状态：已修复）。

#### G-3（低）`changelog.md` 543 行、无归档策略

- **位置**：`changelog.md`（22+ 版本节）。
- **描述**：每次发版追加，`update.json` 的 `changelog` 字段直接指向该文件，设备 OTA 页会整份展示。
- **严重程度**：低。

#### G-4（低）CI 只校验 `--check --no-write`，不产出可复现的发布 zip

- **位置**：`.github/workflows/check.yml`（9 步，全部为检查）。
- **描述**：`dist/SAM_20261025.7_release.zip` 是本地构建产物（`dist/` 已 gitignore），CI 不重建也不比对哈希，发版资产与仓库状态之间没有可验证链接。
- **严重程度**：低。

## 三、改进建议

> 每条都给出做法、文件清单、验证方式；「验证方式」里的命令均可在本机或 CI 直接执行。

### S-1（已实施，对应 D-1）默认凭据文案统一 —— 本建议已由 `63c30a0` 完成，剩"防复发"

- **现状**：`smartdns.conf` `smartdns-ui.password root`、AGH 模板注释、`desc.sh`（root / root）、`README.md` 第 38/61 行、`AGENTS.md` 第 76 行已全部对齐到 root/root；`grep -rn sam123456 README.md AGENTS.md` 无命中。
- **剩余动作**：只做验收与防复发——
  1. `changelog.md` 的 `# 2026.10.25.7` 节已说明根因，无需再改；
  2. 门禁扩展见 **S-8**（把"README/AGENTS 与 `smartdns.conf` 的默认凭据必须同值"变成 CI 检查）；
  3. 若将来再次调整默认凭据，按 `desc.sh` 第 55-56 行注释里的"四处同步"清单执行：`smartdns.conf`、AGH 模板 + 运行时 yaml、`desc.sh`、README/AGENTS/changelog。
- **文件清单**：无代码改动；S-8 落地时涉及 `tools/check_version_sync.py`。
- **验证方式**：`grep -rn "sam123456" README.md AGENTS.md changelog.md` 只允许命中历史版本节；`grep -n "smartdns-ui.password" etc/SmartDNS/smartdns.conf` 为 `root`。

### S-2（高，对应 T-1）把 stub 注入改成"函数覆盖"或显式 PATH 前置，并让本机基线可见

- **做法**（推荐最小改动）：
  1. 在 `tools/test_ad_sh.py` 的 `run_ad` 里不再依赖 `os.pathsep`，改为在真实脚本副本中**重定义函数**：把 `ad.sh` 的 `is_locked` 用测试专用版本替换（追加快照：`is_locked(){ grep -qxF "$1" "$HOLD_LIST" && return 0; [ -f "$1/.locked" ] || [ -f "$(dirname "$1")/.$(basename "$1").locked" ]; }`），或把 stub 目录以 POSIX 形式放到 `sh -c 'PATH=...'` 内部前置。
  2. 在 `main()` 开头探测 stub 是否生效（`sh -c 'command -v lsattr'` 必须等于 stub 路径），不生效时打印 `SKIP` 并让套件**退出非零**或显式标注"本机不可信"，禁止静默 26/27。
  3. 同步更新 `AGENTS.md` 的自检清单：Windows 下 `test_ad_sh.py` 任何失败都必须先确认 stub 是否生效。
- **文件清单**：`tools/test_ad_sh.py`、`AGENTS.md`。
- **验证方式**：① 本机 `python tools/test_ad_sh.py` 输出 **27/27**；② 故意把 `recovery_ad` 的空壳删除分支注释掉 → 必须红；③ CI 日志仍全绿。

### S-3（中高，对应 A-1）把 `mihomo_expected` 用到全部 5 处，修掉 wifi.monitor 的口径差

- **做法**：`webui.sh` 三个计数函数、`setting_api.sh` 第 382 行、`wifi.monitor.sh` 的 `any_service_enabled` 全部改为 `mihomo_expected`（`base.sh` 已 source，可直接调用）。`service/mihomo.sh` 的 `start` 保留自身"未启用/无订阅"的早期返回（那是本地短路，不是同一语义），但在注释里注明"外部判定统一用 `mihomo_expected`"。
- **文件清单**：`scripts/webui.sh`、`scripts/setting_api.sh`、`scripts/wifi.monitor.sh`、`scripts/service/mihomo.sh`（仅注释）。
- **验证方式**：① `grep -rn '#SUB_URL\[@\]' scripts/` 只剩 `base.sh` 一处；② `python tools/test_watchdog_logic.py` 与新增用例：构造 `MIHOMO_ENABLE=true, SUB_URL=(x), BYPASS_ENABLE=true` → `any_service_enabled` 返回 1（不启动）；③ `mksh -n` 四文件。

### S-4（中，对应 A-2/C-1）把"下游上游选择"与"端口未监听清理"收敛到 base.sh

- **做法**：
  1. 在 `base.sh` 增加 `dns_upstream_port <exclude>`：按 `MODULE_DNS_MODE` 与 `isRun`+`is_port_listening` 返回可用的本地 DNS 端口（排除调用方自身），`update/agh.sh` 与 `update/mihomo.sh` 改成调用它，各自只保留"公共 DNS 兜底"与日志差异。
  2. `watchdog.sh` 的 `case 2` 分支改为显式调用 `dns.sh disable`（语义与日志一致），不再依赖 `enable` 的空端口副作用；`dns.sh enable` 保持现有行为不变。
- **文件清单**：`scripts/base.sh`、`scripts/update/agh.sh`、`scripts/update/mihomo.sh`、`scripts/watchdog.sh`。
- **验证方式**：① `tools/test_dns_entry.py` 扩一个 `dns_upstream_port` 用例矩阵（模式×存活×排除自身），断言与改造前两个 update 脚本的取值表一致；② 真机或 mock：`SERVICE_PATH/sd.sh stop` 后跑 `update/agh.sh`，断言上游回退到 `127.0.0.1:1053`；③ `watchdog` 里人为清空端口，日志出现"移除重定向"且 `iptables -t nat -L REDIRECT_DNS` 为空。

### S-5（中，对应 A-3）根 `service.sh` 改为调用 `ensure_module_links`

- **做法**：删除根 `service.sh` 第 31-36 行的手写 `ln -s`，改为 `source` 后调用 `ensure_module_links`（此时 `base.sh` 已 source，函数可用）；`fix_symlink`（manual.sh）保留，但注释指向 base.sh 为唯一规则源。
- **文件清单**：`service.sh`。
- **验证方式**：① `tools/test_module_links.py` 增设一个用例：在临时目录跑"绝对目标悬空链"场景，断言 `ensure_module_links` 删除重建后 `-e` 为真；② 真机软重启后 `ls -l bin/smartdns` 目标为 `../etc/SmartDNS/smartdns`；③ `mksh -n service.sh`。

### S-6（中，对应 C-3）TTL 边界从服务端下发，WebUI 不再写死

- **做法**：`setting_api.sh get` 增加一行 `SMARTDNS_TTL_FLOOR=<常量>` / `SMARTDNS_TTL_CEIL=<常量>`（只读输出，不写配置）；`main.js` 的 `isTtl` 分支改为读 `lastSettingBounds`（`loadSettings` 时从同一份输出取），取不到时退回 60/86400 并在控制台警告。
- **文件清单**：`scripts/setting_api.sh`（`get_all` 尾部追加）、`webroot/js/main.js`。
- **验证方式**：① `setting_api.sh get | grep SMARTDNS_TTL_` 有两行；② WebUI 输入 30 时提示"必须是 60-86400"且文案来自下发值；③ 把 `base.sh` 的下限改成 120 → 刷新设置页后 WebUI 立即按 120 校验（无需改 JS）。

### S-7（中，对应 C-4）WebUI 保存改为"一次 apply 兜底 + 失败明确告知部分已保存"

- **做法**（不改服务端事务模型，最小改动）：`saveSettings` 在任一 `setarr` 失败后**仍调用一次 `apply`**，并用"配置已部分保存并应用，数组项保存失败: …"的文案区分；或者在服务端新增 `setall`（一次事务写完标量+数组）——若选后者，`set_arr` 的校验逻辑可直接复用。
- **文件清单**：`webroot/js/main.js`；若选服务端方案则加 `scripts/setting_api.sh`。
- **验证方式**：① 构造 `SUB_URL` 含 `"` 的保存 → 观察提示为"部分保存"；② 读 `setting.conf` 断言标量已落盘、`SUB_URL` 未变；③ 服务进程按新标量重启（`isRun` 时间戳变化）。

### S-8（中，对应 G-1）扩展版本门禁，检查"文档/配置真值"一致性

- **做法**：`tools/check_version_sync.py` 增加两项：
  1. `smartdns.conf` 的 `smartdns-ui.password` 与 `README.md`「默认密码」段落必须同时提到同一个值（`root` 或 `sam123456`），不一致 exit 1；
  2. `module.prop` 的 `description` 在发版时必须不是占位值 `模块未启动`（可加 `--allow-placeholder` 例外，供开发期使用）。
- **文件清单**：`tools/check_version_sync.py`、`.github/workflows/check.yml`（无需新步骤，沿用现有 `run`）。
- **验证方式**：① 故意把 README 写成 sam123456 → 脚本 exit 1 并指出两处值；② 恢复后 exit 0；③ CI 绿。

### S-9（中，对应 E-1）为出厂 crontab 增加显式说明与"默认不预置高危任务"

- **做法**：二选一（推荐 A）：
  - A. 把 `etc/crontabs/root` 的三条任务保留但全部注释（`# 0 4 * * * ...`），`setting.conf` 的 `CRONTAB_ENABLE` 注释补一行「启用后按 `etc/crontabs/root` 执行；出厂自带的三条（每日自动更新组件、每日重启、每周 hosts）默认注释，需要时在工具页取消注释」；README「定时执行」补同样说明。
  - B. 保留预置任务，但在 WebUI 定时任务卡片顶部加一行红色提示「包含每日自动更新与重启」。
- **文件清单**：`etc/crontabs/root`、`setting.conf`、`README.md`（方案 A）；或 `webroot/index.html`（方案 B）。
- **验证方式**：① `python tools/test_cron_validate.py` 不回归（用例覆盖注释行）；② 真机开启「定时执行」后 `crontab -l`（或 `crontab get`）只看到注释；③ `settings_api cron set` 清空仍可用。

### S-10（低，对应 E-2/G-3）工程收尾项合并

- **做法**：
  1. `pack_module.py` 的 `SKIP_DIRS` 增加 `docs`（保留 README/AGENTS），让审计报告不随包；若确实要随包，则在 `README.md` 里写明。
  2. 把 `module.prop` 的 `description` 换成非占位文案（与 S-8 的第 2 项联动）。
  3. 本报告（`docs/AUDIT-REPORT-2026-10-25-3.md`）随下次文档提交入库。
- **文件清单**：`tools/pack_module.py`、`module.prop`。
- **验证方式**：① `python tools/pack_module.py --check --no-write` 通过；② 生成的 zip 内 `docs/` 不存在（`python tools/pack_module.py && unzip -l dist/SAM.zip | grep docs` 为空）；③ `git status` 只剩 `dist/`（已忽略）。

### S-11（低，对应 A-4/C-2/C-5/C-6/C-7/T-2/T-3/R-2/R-3）后续批次

按"一次一个主题"分批，避免与已发布版本混在一起：

| 项 | 做法摘要 | 文件 |
|---|---|---|
| A-4 | `inotify/module.sh` 的 remove 分支改为调用 `manual.sh uninstall`（复用单一路径） | `scripts/inotify/module.sh`、`scripts/manual.sh` |
| C-2 | `mountControls` 失败时回写相反的 `HOST_ENABLE`，或先 mount 成功再改配置 | `webroot/js/main.js` |
| C-5 | `block_ad` 只在真正处理时自增；`lsattr -d`/`ad_exclude` 加引号 | `scripts/ad.sh` |
| C-6 | `add_smart_conf` 统一用当前文件快照定位 | `scripts/update/mihomo.sh` |
| C-7 | `sd/agh/mihomo.sh` 的 `start/stop` 改为 0=成功/1=失败，调用方相应调整 | `scripts/service/*.sh`、`scripts/service.sh`、`scripts/watchdog.sh` |
| T-2 | 新增 `test_setting_transaction.py`（set/setarr 事务、端口批量校验）与 `test_manual_repair.py`（repair 三级选择序，用临时目录） | `tools/`、`.github/workflows/check.yml` |
| T-3 | `test_module_links.py` 增加根 `service.sh` 用例（依赖 S-5 先落地） | `tools/test_module_links.py` |
| R-2 | `test_dns_entry.py` 增加 `check_dns_chain` 的参数级断言（mock `ipt_run` 记录 argv） | `tools/test_dns_entry.py` |
| A-5 | `main.js` 拆分（可选，收益/风险比自行评估；本轮不建议与新功能同批） | `webroot/js/*`、`webroot/index.html` |

## 四、优先级与并行性

| 优先级 | 建议 | 依赖 | 并行性 |
|---|---|---|---|
| P0 | S-2（ad 测试可信化） | 无 | 与 S-3/S-5 可并行（只碰 tools 与 AGENTS 一处） |
| P1 | S-3（mihomo 判定收敛） | 无 | 与 S-4 **串行**（都碰 webui/watchdog 行为面），与 S-2 可并行 |
| P1 | S-4（上游选择 + enable 语义） | 建议在 S-3 之后（同碰 watchdog） | 串行于 S-3 |
| P1 | S-5（根 service.sh 软链） | 无 | 与 S-2/S-3 可并行（只碰 service.sh） |
| P1 | S-8（门禁扩展） | 无（S-1 已完成，直接以 root/root 为真值） | 独立 |
| P2 | S-6（TTL 边界下发） | 无 | 与 S-2/S-5/S-8 可并行（碰 setting_api + main.js） |
| P2 | S-7（保存事务体验） | 无 | 与 S-6 共享 `main.js` → 串行或合并提交 |
| P2 | S-9（crontab 说明） | 无 | 独立 |
| P3 | S-10（收尾：docs 分包 + description） | 依赖 S-8 | 收尾执行 |
| P3 | S-11（后续批次） | 按表内依赖 | 表内各项文件不重叠，可并行 |
| — | S-1（凭据文案） | **已由 `63c30a0` 完成** | 仅保留验收，无工作量 |

**推荐顺序**：S-2 → S-3 → S-4 → S-5 → S-8 → S-9 → S-6 → S-7 → S-10 → S-11。
每组完成后按项目惯例跑全量门禁：`python tools/pack_module.py --check --no-write`、`python tools/check_version_sync.py`、8 套件、`node --check webroot/js/*.js`、`git diff --check`，并同步 `changelog.md` 与 `AGENTS.md` 状态段。

## 五、审计边界说明

- **未在真机（Android + mksh + busybox）执行任何用例**；所有结论来自静态阅读与本机（Windows + MSYS `sh`）实测。标注"真机"的验证步骤需在设备上确认。
- **AGH bcrypt 哈希未验证明文**：本机无 `bcrypt` 模块（`pip install` 会污染环境，本轮不做）。注意 `etc/AdGuardHome/AdGuardHome.yaml`（运行时初始配置）与 `AdGuardHome.template.yaml` 的哈希**不同是正常的**——bcrypt 随机盐会让同一密码产生不同哈希，不能据此判定"两者密码不一致"。若要确认，用 `htpasswd -bnBC 12 "" root` 重新生成一份并写入两处，或真机用 root/root 登录验证。
- 未审查 `etc/` 下第三方二进制（AdGuardHome/SmartDNS/mihomo 本体）与其自带 `wwwroot`/`webui` 资源（zashboard、SmartDNS 前端）；`etc/mihomo/base.yaml` 仅审查了与本报告结论相关的段结构。
- 本轮只产出本报告，**未改动任何代码、配置或脚本**；`docs/AUDIT-REPORT-2026-10-25-3.md` 是唯一新增文件。
- 第二轮报告的 S-1/S-2/S-4/S-5/S-6/S-7/S-8 本轮复核为**已实施且有效**（`dns_entry_port` 唯一、`backup.sh restore` 清残留、`check_version_sync` 在 CI、AGENTS 门禁清单已补、锁阻塞用例按 shell 能力门控、watchdog 纯逻辑 20 项）；S-3 只完成 `setting.sh` 内部收敛（C-3）、S-9 只完成 2/6 处（A-1）。
