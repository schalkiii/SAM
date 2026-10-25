# SAM 项目审计报告（2026-10-25）

> 审计对象：`D:\workspace\SAM`（SmartDNS + AdGuardHome + Mihomo 三合一 Magisk/KernelSU 模块）
> 审计基线：commit `f143eea`（v20261025.1 发布后）
> 本报告只记录发现与建议，**未修改任何代码**；每条建议可直接交给执行 Agent 开工。

> **执行状态（2026-10-25 晚更新，报告本体保持审计时快照）**：
> S-2 已实施并于 v20261025.2/v20261025.3 发布——新增 `test_cron_validate.py`/`test_tar_guard.py`/`test_owner_probe.py`/`test_backup_semantics.py` 四个文件，连同 `test_ad_sh.py` 共 5 个套件 137 项断言由 CI 全量执行；期间另修复两个真实缺陷（backup.sh sed 闭合分隔符、restore 无锁非原子写入）。S-1/S-3~S-7 仍待办；最新 Release 为 v20261025.3。

## 一、现状描述（可观察事实）

### 规模

| 项 | 数值 |
|---|---|
| Shell 脚本 | 33 个，共 7,304 行（`scripts/**` + 根目录 `customize.sh`/`uninstall.sh`/`action.sh`） |
| WebUI | `webroot/index.html` 529 行 + `main.js` 1,011 行（33 个函数）+ `kernelsu.js` 146 行 |
| Python 工具 | `tools/pack_module.py` 372 行 + `tools/test_ad_sh.py` 299 行 |
| 随包二进制/资源 | `etc/AdGuardHome` 7.8MB、`etc/SmartDNS` 19MB、`etc/mihomo` 21MB（发布 zip 约 130MB） |
| 单文件最大 | `scripts/ad.sh` 909 行、`webroot/js/main.js` 1,011 行、`scripts/setting_api.sh` 570 行、`scripts/watchdog.sh` 502 行 |
| 文档 | README.md、AGENTS.md、changelog.md、docs/ad-block-hold-design.md |
| Git | 单分支 main，tag 50 个（最新 v20261025.1），CI `module-check` 全绿 |

### 结构

- `scripts/` 按职责分层：`base.sh`（共享函数/锁/网络刷新）→ `service.sh`（启停编排）+ `service/{sd,agh,mihomo,crontabs}.sh`（单服务）→ `update/*.sh`（配置生成）→ `iptables/*.sh`（规则）→ `setting*.sh`（配置读写）→ `watchdog.sh`（守护循环）。
- 三服务协作：SmartDNS（UDP/TCP 3721）、AdGuardHome（面板 3000 / DNS 5300）、Mihomo（DNS 1053 / 面板 9090）；DNS 劫持经 nat 链 `REDIRECT_DNS`，入口按 `MODULE_DNS_MODE` 逐级回退。
- 锁体系：`service`/`setting`/`ad`/`update`/`watchdog_instance`/`network_refresh`/`host_update`/`wifi_monitor_instance`，目录锁实现于 `base.sh`。
- 测试：仅 `tools/test_ad_sh.py`（27 项，覆盖广告屏蔽 block/recovery 往返、通配符、exclude、幂等），由 CI 执行。

### 质量水平（事实）

- 门禁齐备：`pack_module.py --check --no-write`（必需文件 40 项 + LF/BOM + bash 语法）、`mksh -n` 33 脚本、`node --check` ×2、`test_ad_sh.py` 27 项、`git diff --check`，全部由 CI 或本地脚本化。
- 文档与代码在 v20261025.1 发布周期内做过三轮对齐（README/AGENTS/changelog/设计文档均已同步至现役行为）。
- 代码无 TODO/FIXME 残留；`.gitattributes` 强制 LF 入库；`dist/` 与 `.workbuddy/` 已 gitignore。

## 二、问题清单

### A-1（高）DNS 入口选择链三处重复实现

- **位置**：`scripts/iptables/dns.sh` `select_dns_port()`（27–49 行）、`scripts/watchdog.sh` `current_dns_entry()`（145 行起）、`scripts/webui.sh` `resolve_dns_entry()`（约 175 行起）。
- **描述**：同一条「按 `MODULE_DNS_MODE` 决定 Mihomo→AGH→SmartDNS（模式 2）或 AGH→Mihomo→SmartDNS（模式 1）逐级回退」的链路被写了三遍。watchdog 版本注释自称「与 dns.sh select_dns_port 同序」，靠注释而不是代码保证一致；webui 版用状态标志（`agh_running` 等）而非 `isRun`，判定口径已有细微差别。
- **影响范围**：改回退顺序/加服务时漏改一处 → 重定向规则指向已死端口（整机 DNS 黑洞）或监控页入口显示与真实不符；此类故障在 v20261024.18 已真实发生过（`is_port_listening` 语义改动引发 SmartDNS 计数为零）。
- **严重程度**：高。

### A-2（高）自动化测试仅覆盖 ad.sh 一个模块

- **位置**：`tools/` 仅有 `test_ad_sh.py`。
- **描述**：`dns.sh`（owner 探测/规则收敛）、`watchdog.sh`（拓扑门控/cksum 门控）、`backup.sh`（完成标记/快照顺序）、`setting_api.sh`（`cron` 时间字段校验/事务提交）、`update.sh`（tar 链接与穿越校验/锁）、`manual.sh`（repair 选择序）均无自动化用例。本轮多处关键修复（如 cron 校验、tar 校验）只有一次性手工验证，未沉淀为回归。
- **影响范围**：后续任何改动回归依赖人工记忆；CI 绿灯不代表这些模块行为未变。
- **严重程度**：高。

### B-1（中）sd.sh 四个配置同步块同构重复

- **位置**：`scripts/service/sd.sh` start() 内 `response-mode`/`speed-check-mode`/`dualstack-ip-selection`/`rr-ttl-min` 四段（约 50–79 行）。
- **描述**：四段都是「grep 现值 → 与目标比较 → `sed -i` 替换 → log」的同一模式，共约 30 行。新增一个 SmartDNS 配置项需再复制一段。
- **影响范围**：维护成本与复制出错风险（本轮 `bind-tcp` 同步就是第五段同构代码，且其 `sed a` 多行插入 bug 正是这类复制衍生的）。
- **严重程度**：中。

### B-2（中）TTL 边界值三处硬编码

- **位置**：`scripts/setting.sh`（244–252 行，60/86400）、`scripts/setting_api.sh` set_scalar（约 250 行，60/86400）、`webroot/js/main.js` saveSettings（约 456 行，60/86400）。
- **描述**：同一约束（60 ≤ TTL ≤ 86400）在三层各写一遍。三层校验是有意的纵深防御，但边界常量没有单一来源。
- **影响范围**：将来调边界（如下限改 120）漏改一处 → WebUI 放过服务端拒绝的值或反之，用户看到「保存成功但配置没变」。
- **严重程度**：中。

### B-3（中）直通模式动作两处重复

- **位置**：`scripts/setting_api.sh` `apply_bypass_only()` 与 `scripts/watchdog.sh` 主循环 bypass 分支（421–436 行）。
- **描述**：「开直通 = `dns.sh disable` + 停 Mihomo + 删 mihomo 规则；关直通 = `dns.sh enable` + 按条件起 Mihomo」这套动作在两处各实现一遍，靠最终状态收敛（watchdog 每轮校正）保证正确。
- **影响范围**：一侧增加动作（如将来直通还要停 AGH）漏改另一侧 → 依赖 5 秒后的 watchdog 兜底，存在至多一个循环周期的不一致窗口。
- **严重程度**：中。

### C-1（低）`is_port_listening` ss/netstat 双路径重复

- **位置**：`scripts/base.sh` is_port_listening（335 行起）。
- **描述**：`ss` 与 `netstat` 两条分支逻辑完全相同（本轮刚修过 AND→OR 语义，两处都改了）。
- **影响范围**：同类语义修复必须改两遍（本轮已因此出现「改了一处漏一处」的风险，实际两处都改了）。
- **严重程度**：低。

### C-2（低）main.js 单文件职责混叠

- **位置**：`webroot/js/main.js`（1,011 行 / 33 函数）。
- **描述**：状态轮询、设置表单、工具按钮、日志、广告范围、定时任务、导航全部在一个文件；`initToolButtons` 已出现按 `dataset` 分流的专门回调（cron）。
- **影响范围**：改动相互可见性差，无构建步骤保护，回归只能靠 `node --check`（不查逻辑）。
- **严重程度**：低。

### C-3（低）diagnose.sh 与 webui.sh allstatus 采集项重复

- **位置**：`scripts/diagnose.sh` 与 `scripts/webui.sh` get_all_status。
- **描述**：两者都采集服务/端口/配置校验/防火墙/DNS/MTU 类信息，输出格式不同（kv 行 vs KEY=VALUE）。
- **影响范围**：新增采集项要改两处；低。
- **严重程度**：低。

## 三、改进建议

### S-1（对应 A-1）抽取单一 DNS 入口选择函数

- **做法**：在 `scripts/base.sh` 新增 `dns_entry_candidates()`（或 `resolve_dns_entry_core <mode>`），只做「按模式返回候选 服务名:端口 列表」，不碰 iptables、不读状态标志。三处调用方各自消费：
  - `dns.sh select_dns_port` 取第一个非空项并 set `DNS_PORT`/`DNS_ENTRY`；
  - `watchdog.sh current_dns_entry` 改为调用同一函数取第一项（无则 `none`）；
  - `webui.sh resolve_dns_entry` 改为调用同一函数，删掉 `mihomo_running`/`agh_running` 口径差异（统一用 `isRun` + `is_port_listening`）。
- **文件清单**：`scripts/base.sh`、`scripts/iptables/dns.sh`、`scripts/watchdog.sh`、`scripts/webui.sh`。
- **验证方式**：① `mksh -n` 四文件；② 写一次性 mock 测试（临时目录造假 `pidof`/`ss` 输出，或直接 source 后打桩 `isRun`/`is_port_listening`），对 mode=1/2 × 三种服务存活组合断言返回值一致；③ `pack_module.py --check --no-write`；④ 真机 WebUI 监控页入口显示与 `dns.sh check` 输出一致。

### S-2（对应 A-2）为关键模块补自动化测试

- **做法**：沿用 `test_ad_sh.py` 的模式（Python 驱动 + mksh 子进程 + 真实断言），在 `tools/` 新增：
  1. `test_cron_validate.py`——对 `setting_api.sh cron set` 喂合法/非法行（含 `*`、`@daily`、越界数字、NF<6、纯空白），断言写入/拒绝/原文件不动；
  2. `test_tar_guard.py`——构造含链接成员、`../` 穿越、绝对路径、超限体积的 tar.gz，断言 `safe_tar_extract` 拒绝；
  3. `test_owner_probe.py`——用假 `iptables_w`（指向 mock 可执行文件，注意 mksh 中 `${var}` 不会展开函数名）驱动 `owner_supported` 五场景（支持/不支持/残留链/缓存命中/幂等）；
  4. `test_backup_semantics.py`——对 `backup.sh` 断言 `.complete` 标记语义（半截备份不被 list/restore 选中）与 `restore` 先选目标再快照的顺序。
- **文件清单**：新增 `tools/test_cron_validate.py`、`tools/test_tar_guard.py`、`tools/test_owner_probe.py`、`tools/test_backup_semantics.py`；`.github/workflows/check.yml` 增加四个 `run` 步骤。
- **验证方式**：CI `module-check` 全绿且新用例在「故意改坏实现」时失败（变异测试思路：如把 cron 校验 `NF<6` 改成 `NF<5`，用例必须红）。

### S-3（对应 B-1）sd.sh 配置同步抽为 `sync_smartdns_conf`

- **做法**：新增 `sync_smartdns_conf <键> <目标值>`：`grep -m1 "^${键} "` 取现值 → 相等直接返回 → 否则 `sed -i "s|^${键} .*|${键} ${值}|"` → log。五处调用（含 `bind`/`bind-tcp` 的补行逻辑保留特判，因为补行不是替换）。注意保持「一致则完全不写文件」的现状（避免无意义 mtime 变化触发 watchdog 重载）。
- **文件清单**：`scripts/service/sd.sh`。
- **验证方式**：① 六用例同本轮 bind-tcp 实测（单条/多条/替换/无行/一致不动/注释不干扰）；② `mksh -n`；③ 真机启动日志无「改为」刷屏。

### S-4（对应 B-2）TTL 边界单一来源

- **做法**：在 `scripts/base.sh` 定义 `SMARTDNS_TTL_MIN_FLOOR=60` / `SMARTDNS_TTL_MAX=86400`，`setting.sh`/`setting_api.sh` 引用之；`main.js` 的 `isTtl` 分支改为从 `setting_api.sh get` 输出读取边界（或至少在 `saveSettings` 注释中标注三处同步义务，并在 `pack_module.py` 的 required 检查外增加一条 grep 断言）。
- **文件清单**：`scripts/base.sh`、`scripts/setting.sh`、`scripts/setting_api.sh`、`webroot/js/main.js`。
- **验证方式**：把 setting.conf 的 TTL 改成 30，启动后断言回退 600 且日志有 ERROR；WebUI 输入 30 断言前端即拒；`setting_api.sh set SMARTDNS_TTL_MIN=30` 断言服务端拒。

### S-5（对应 B-3）直通动作收敛到 `dns.sh`

- **做法**：在 `scripts/iptables/dns.sh` 新增 `bypass on|off` 子命令：on = 现有 disable 全套 + 停 Mihomo + 删 mihomo 规则；off = enable + 按 `MIHOMO_ENABLE`/订阅/运行态决定起 Mihomo。`setting_api.sh apply_bypass_only` 与 watchdog bypass 分支都改为调用它，各自只保留自己的附加动作（前者多一次 `refresh_network force` 与 toast 文案，后者多日志）。
- **文件清单**：`scripts/iptables/dns.sh`、`scripts/setting_api.sh`、`scripts/watchdog.sh`。
- **验证方式**：① 开→关直通往返后 `dns.sh check` 正常、AGH/SmartDNS PID 不变（缓存统计保留）、Mihomo 状态符合预期；② WebUI 连点两次直通开关无规则重复；③ `mksh -n` + pack check。

### S-6（对应 C-1）合并 is_port_listening 双路径

- **做法**：`ss` 分支抽 `_port_listen_via <list-udp-cmd> <list-tcp-cmd>`，netstat 分支复用；无 ss/netstat 时保持现有「按在监听处理」的降级。
- **文件清单**：`scripts/base.sh`。
- **验证方式**：WSL 下用 PATH 打桩分别提供假 `ss`/假 `netstat`/都不提供，对「仅 UDP / 仅 TCP / 都听 / 都不听」四种组合断言返回值。

### S-7（对应 C-2/C-3）低优先级结构整理

- **做法**（可选，不影响功能）：`main.js` 按「status.js / settings.js / tools.js / log.js」拆分为 ES module 或 concat 前的分文件（无构建步骤时用 `<script>` 顺序加载即可）；`diagnose.sh` 增加复用 `webui.sh` 的 KEY=VALUE 采集函数输出机器可读段。
- **文件清单**：`webroot/js/*`（拆分时同步 `webroot/index.html` 的 script 标签）、`scripts/diagnose.sh`、`scripts/webui.sh`。
- **验证方式**：`node --check` 每个新文件；WebUI 各页面功能手工过一遍；`diagnose.sh --watch 5` 输出不回归。

## 四、优先级与并行性

| 优先级 | 建议 | 依赖关系 | 可并行性 |
|---|---|---|---|
| P0 | S-2（补测试） | 无（先行，给后续改动建安全网） | 与 S-1/S-3/S-5 均可并行（文件不重叠：S-2 只动 tools/ 与 CI） |
| P0 | S-1（入口选择合一） | 建议在 S-2 的 `test_owner_probe` 同款 mock 手法就绪后做 | 与 S-3/S-5 **串行**（都碰 watchdog/dns.sh 的行为面，需分别回归） |
| P1 | S-5（直通动作收敛） | 依赖 S-1 完成（同改 dns.sh/watchdog） | 串行于 S-1 之后 |
| P1 | S-3（sd.sh 同步函数） | 无 | 与 S-1、S-2 可并行（只碰 sd.sh） |
| P1 | S-4（TTL 边界单一来源） | 无 | 与 S-1/S-2/S-3/S-5 可并行（碰 base/setting/main.js，与 S-1 的 base.sh 改动有文件级重叠，需合并） |
| P2 | S-6（is_port_listening 合并） | 无 | 与以上均可并行（只碰 base.sh 一个函数；若与 S-1/S-4 同批改 base.sh 需合并提交） |
| P2 | S-7（结构整理） | 无 | 独立 |

**建议执行顺序**：S-2 → S-1 → S-5 →（S-3 / S-4 / S-6 择一或并行）→ S-7。
每条完成后按项目惯例跑全量门禁（mksh -n 33、test_ad_sh 27、pack check、node --check、git diff --check）并同步 changelog。

## 五、审计边界说明

- 本审计未在真机（Android/mksh 环境）执行任何用例；所有结论来自静态阅读与 WSL mksh 语法级验证。标注「真机验证」的条目需在设备上确认。
- `etc/` 下第三方二进制与 webui 资源（zashboard 等）不在审计范围。
- 发布态（v20261025.1 Release/CI/update.json）已于 2026-10-25 验证为 live，不作为问题登记。
