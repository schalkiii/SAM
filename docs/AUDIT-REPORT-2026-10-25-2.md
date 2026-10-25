# SAM 项目审计报告（2026-10-25 晚，第二轮）

> 审计对象：`D:\workspace\SAM`（SmartDNS + AdGuardHome + Mihomo 三合一 Magisk/KernelSU 模块）
> 审计基线：commit `3b3f24f`（v20261025.3 发布 + neat-freak 文档收尾后）
> 本报告只记录发现与建议，**未修改任何代码**；每条建议可直接交给执行 Agent 开工。
> 与同日第一轮报告（`AUDIT-REPORT-2026-10-25.md`，基线 `f143eea`）的关系：该报告的 S-2 已实施、
> B-1 已解决，其余开放项在本报告重新编号为 S-1/S-3~S-8（编号不沿用旧报告，避免混淆）。

## 一、现状描述（可观察事实）

### 规模

| 项 | 数值 |
|---|---|
| Shell 脚本 | 29 个（`scripts/**`），共 7,337 行；根目录 4 个入口（customize/uninstall/action/service.sh）共 409 行 |
| WebUI | `webroot/index.html` + `main.js` + `kernelsu.js` 共 1,686 行 |
| Python 工具 | `tools/` 共 1,745 行（`pack_module.py` + 5 个测试文件） |
| 随包二进制/资源 | `etc/` 下约 48MB，发布 zip 约 130MB |
| 单文件最大 | `scripts/ad.sh` 909 行、`scripts/setting_api.sh` 577 行、`scripts/manual.sh` 577 行、`scripts/watchdog.sh` 502 行、`scripts/diagnose.sh` 462 行 |
| Git | 单分支 main，22 个 tag（最新 v20261025.3），本地/远端 tag 完全一致；CI `module-check` 全绿 |
| 版本卫生 | changelog 22 个版本节与 22 个 tag 一一对应（另 `2026.09.07` 为首版，早于 tag 约定）；`module.prop`/`update.json`/changelog 版本号当前一致（20261025.3） |

### 结构

- `scripts/` 分层：`base.sh`（共享函数/锁/网络刷新）→ `service.sh` + `service/{sd,agh,mihomo,crontabs}.sh` → `update/*.sh`（配置生成）→ `iptables/*.sh`（规则）→ `setting*.sh`（配置读写）→ `watchdog.sh`（守护循环）→ `ad.sh`（广告屏蔽）。
- 锁体系（目录锁，实现于 `base.sh` 的 `sam_lock_acquire`，PID 陈旧检测）：`service`/`setting`/`ad`/`update`/`watchdog_instance`/`network_refresh`/`host_update`/`wifi_monitor_instance`。
- setting 锁持有者矩阵（v20261025.3 起）：`setting_api.sh` 的 `set`/`setarr`/`apply`/`cron set` + `backup.sh restore` 的文件写入期；读路径不持锁（依赖原子写）。该矩阵已写入 AGENTS.md。
- 测试：5 个套件共 **137 项断言**（`test_ad_sh.py` 27 / `test_cron_validate.py` 29 / `test_tar_guard.py` 18 / `test_owner_probe.py` 20 / `test_backup_semantics.py` 43），全部由 CI 执行；CI 安装 mksh，测试跑在设备同款 shell 下。测试模式统一为「从脚本抽取真实函数或搭临时模块目录 + 记录型 stub」，不复制实现。

### 质量水平（事实）

- 门禁：`pack_module.py --check --no-write`（必需文件清单 + LF/BOM + 语法）、`mksh -n` 29 脚本、`node --check` ×2、5 套件 137 项断言、`git diff --check`，全部由 CI 或本地脚本化，本轮审计时全部通过。
- 文档：README/AGENTS.md/changelog 与代码在 v20261025.3 周期同步（neat-freak 收尾刚修正 AGENTS.md 一处退役符号残留）；同日第一轮审计报告已补执行状态行。
- 代码无 TODO/FIXME/调试残留；`.gitattributes` 强制 LF；`dist/` 与 `.workbuddy/` 已 gitignore。

## 二、问题清单（按审计维度组织）

### 维度 1 文档一致性 — 结论：一致（本轮刚修正一处）

- ~~AGENTS.md 广告屏蔽条目仍描述已废弃的 `.samhold.prev.*` 方案~~ → neat-freak 收尾已改为现役行为（跳过屏蔽提示 recovery），并同步设计文档 §14。
- 同日第一轮审计报告的快照事实（「tag 50 个」「测试仅 ad.sh」）已过时 → 已在报告头补执行状态行，本体保持快照。
- 当前未发现其他文档与代码矛盾。

### 维度 2 文档缺漏 — 发现 E-2、E-3

- **E-2（低）AGENTS.md 门禁清单缺 4 个新测试文件**。位置：`AGENTS.md` 第 12 行只写「广告屏蔽回归测试：`python tools/test_ad_sh.py`」。
  影响：后续 Agent 改 `backup.sh`/`setting_api.sh`/`update.sh`/`dns.sh` 后不知道要跑对应回归，新测试形同虚设。
- **E-3（低）测试编写模式无文档**。5 个测试文件共用一套模式（driver 搭临时模块目录 / 从脚本抽取真实函数 / Checker 类 / 记录型 stub），但无一处说明。影响：写第六个测试时要么重新发明轮子，要么破坏既有约定。

### 维度 3 架构优化点 — 发现 A-1（本报告最高优先级）

- **A-1（高）DNS 入口选择链三处重复实现，判定口径已有差异**。
  - 位置：`scripts/iptables/dns.sh` `select_dns_port()`（27–49 行）、`scripts/watchdog.sh` `current_dns_entry()`（145 行起）、`scripts/webui.sh` `resolve_dns_entry()`（179 行起）。
  - 描述：同一套「按 `MODULE_DNS_MODE` 决定 Mihomo→AGH→SmartDNS（模式 2）或 AGH→Mihomo→SmartDNS（模式 1）逐级回退」写了三遍，靠注释保证一致。三处判定口径确有差别：dns.sh/watchdog 用 `isRun` + 设置项端口（`SMARTDNS_PORT` 等），webui 用 allstatus 状态字符串（`mihomo_running`/`agh_running`）+ `smartdns_port()`（从 smartdns.conf 的 bind 行解析的实际端口），且 webui 多一个直通模式分支。
  - 影响：改回退顺序/加服务时漏改一处 → 重定向规则指向已死端口（整机 DNS 黑洞）或监控页入口显示与真实不符。此类故障在 v20261024.18 真实发生过（`is_port_listening` 语义改动引发 SmartDNS 计数为零、查询全走 AGH）。
  - 本项自第一轮审计（S-1）起仍未解决。

### 维度 4 代码写法 — 发现 D-1、D-2、B-2、C-2

- **D-1（低-中）restore 原子替换的临时文件在进程被杀时残留，且残留会被 crond 当 crontab 加载**。
  - 位置：`scripts/backup.sh` `restore_backup()`（v20261025.3 新增的 `${restore_target}.restore.$$` 临时文件）。
  - 描述：`cp` 完成后、`mv` 前进程被 kill（或设备重启），临时文件残留。若残留的是 `etc/crontabs/root.restore.<pid>`：`service/crontabs.sh` 用 `busybox crond -c "$MODULE_PATH/etc/crontabs/"` 启动，**busybox crond 会加载该目录下所有文件为 crontab（文件名作用户名）**，残留文件里是刚 cp 进去的有效 cron 行 → 这些定时任务会被重复执行。
  - 影响：窗口很小（cp 后即 mv，文件仅几 KB），后果是定时任务重复执行（如每日备份跑两遍），无数据损坏。但残留文件永久存在，直到下次 restore 同 pid（几乎不可能）。
- **D-2（低）restore 目标选择在锁外，「双重 restore 幂等」语义未记录**。
  - 位置：`scripts/backup.sh` `restore_backup()`（`latest_backup` 选取在 `sam_lock_acquire` 之前）。
  - 描述：两个 restore 并发时都选取各自启动时的最新完整备份、都恢复同一目标——这是合理的幂等语义（比「第二个把第一个冲掉」好），但代码与文档均无说明。后续维护者可能误以为是疏漏而把选取挪进锁里，反而修出「后一个恢复前一个的快照=撤销前一次恢复」的语义。
  - 影响：维护陷阱，非现实缺陷。
- **B-2（低）TTL 默认值 600 在 `scripts/setting.sh` 四处重复**：第 28 行（默认值）、224 行（`setting_fix_number`）、246 行（越界上界回退）、251 行（低于下界回退）。
  - 影响：调整默认 TTL 时漏改一处 → 回退值与默认值不一致，难以排查。
- **C-2（低）`webroot/js/main.js` 1,011 行单文件**（33 个函数混叠：状态轮询/设置表单/广告屏蔽/定时任务/日志/工具）。
  - 影响：改一个卡片容易波及其他；无模块边界。拆分的收益/风险比需先评估（浏览器无构建步骤，拆分=加 script 标签或模块化改造）。

### 维度 5 测试覆盖率 — 覆盖缺口清单

已覆盖（函数级，共 137 项断言）：`ad.sh`（block/recovery 往返）、`setting_api.sh`（cron 校验+锁接线）、`update.sh`（`safe_tar_extract`）、`iptables/dns.sh`（`owner_supported`）、`backup.sh`（save/list/restore 语义+锁+原子替换）。

**无自动化覆盖的关键模块**（按行数/风险排序）：

| 模块 | 行数 | 风险点 |
|---|---|---|
| `scripts/watchdog.sh` | 502 | 守护状态机（退避/恢复/拓扑门控）最复杂，无任何测试 |
| `scripts/manual.sh` | 577 | 激活/卸载/repair 编排，不可逆操作集中 |
| `scripts/diagnose.sh` | 462 | 诊断采集，输出被 WebUI 直接展示 |
| `scripts/service.sh` + `service/*.sh` | ~450 | 启停编排与锁等待 |
| `scripts/update/*.sh`（8 个） | ~1,300 | 配置生成，错一个字段服务起不来 |
| `scripts/iptables/{ip,mihomo}.sh` | ~300 | 规则管理，误删=DNS 黑洞 |
| `scripts/webui.sh` | ~250 | allstatus 采集（读路径，展示失真风险） |
| `base.sh` 的 `is_port_listening`/`smartdns_port` | — | 被三处 DNS 链路依赖，仅经 mock 间接接触 |

### 维度 6 测试严谨性 — 结论：整体严谨，两处局限

- 现有用例断言具体（文件内容/退出码/日志条数/mock 调用次数），有变异验证先例（v20261025.3 对 `-f` 守卫做过「去掉守卫→用例失败」的验证）。
- **局限 1**：锁竞争「活进程持锁→阻塞→超时拒绝」路径无覆盖。原因：本机 PortableGit `sh.EXE` 的 `kill -0` 看不到任何进程（实测 pid 1 都报 No such process），共享测试文件无法在本机稳定复现；当前以「stub 接线 + 真实锁无残留 + 陈旧锁恢复」组合覆盖。CI 上 mksh 的 `kill -0` 正常但未被利用。
- **局限 2**：测试在开发机走 `sh`（Git Bash）、CI 走 mksh，**从未在设备真实环境（Android mksh + busybox 工具集）跑过**；busybox 与 GNU 工具的行为差异（如 sed/awk 边角）只能靠设备侧冒烟测试发现。

### 维度 7 工程规范 — 发现 E-1

- **E-1（中）版本号三处手工同步，无自动校验**。位置：`module.prop`（version/versionCode）、`update.json`（version/versionCode/zipUrl）、`changelog.md`（版本节）。
  - 描述：每次发版需人工同步三处，漏一处 → 设备 OTA 拿到旧版号不升级，或 zipUrl 指向不存在的资产。当前一致（20261025.3），但无任何门禁保证。
  - 影响：发版流程的人为单点，历史上靠人工核对（本轮三连发未出错）。
- 其余规范良好：CI 装 mksh 使测试跑在设备同款 shell；`--no-write` 校验不污染仓库；tag/changelog 一一对应；`.gitattributes` LF 强制。

## 三、改进建议

### S-1（高，对应 A-1）抽取单一 DNS 入口选择函数

- **做法**：先在 `scripts/base.sh` 新增 `dns_entry_port()`：按 `MODULE_DNS_MODE` 与各服务 `isRun`+`is_port_listening` 结果回退，输出 `Name:port` 或空（none）。采用**先写 characterization 测试锁定当前三处行为，再重构**的顺序：① 新增 `tools/test_dns_entry.py`，mock `isRun`/`is_port_listening`（可执行文件 mock，沿用 owner 测试模式），对「模式×服务存活组合」矩阵断言三处消费方（iptables 规则入口、watchdog 拓扑判定、webui 显示）输出一致；② 将三处实现改为调用共享函数，各自只保留格式化/分支差异（webui 的直通分支、watchdog 的拓扑比对语义）；③ 测试全绿后删除三处旧实现。
- **文件清单**：`scripts/base.sh`（新增共享函数）、`scripts/iptables/dns.sh`、`scripts/watchdog.sh`、`scripts/webui.sh`、`tools/test_dns_entry.py`（新增）、`.github/workflows/check.yml`（加测试步骤）。
- **验证方式**：`test_dns_entry.py` 新增用例全过 + 既有 5 套件不回归 + `mksh -n` + pack `--check`；重点构造「 Mihomo 假死/AGH 假死/SmartDNS 假死」组合，断言三处输出与重构前一致。
- **优先级/并行**：高；独立执行（涉及文件与其他建议无重叠，但自身是单线程重构，勿与其他改动同批提交）。

### S-2（中，对应 D-1）restore 启动时清理 stale 临时文件

- **做法**：`restore_backup()` 取得锁后、拷贝循环前，对每个还原目标执行 `rm -f "${restore_target}.restore."*`（glob 无匹配时 `rm -f` 静默通过）；extra 文件同样处理。注释说明原因（crond 会加载目录内所有文件）。
- **文件清单**：`scripts/backup.sh`。
- **验证方式**：`test_backup_semantics.py` 加用例：预置 `etc/crontabs/root.restore.99999`（含有效 cron 行）→ restore → 断言残留被清、crontab 内容正确、无其他副作用。
- **优先级/并行**：中；与 S-3/S-4/S-5/S-6 可并行（文件不重叠）。

### S-3（低，对应 B-2）TTL 默认值单一来源

- **做法**：`scripts/setting.sh` 顶部定义 `SMARTDNS_TTL_DEFAULT=600`，第 28/224/246/251 四处引用它。
- **文件清单**：`scripts/setting.sh`。
- **验证方式**：`grep -n "600" scripts/setting.sh` 只剩定义处一行；`test_cron_validate.py`（加载 setting.sh 的 driver）不回归。
- **优先级/并行**：低；与 S-2/S-4/S-5/S-6 可并行。

### S-4（低，对应 D-2）记录双重 restore 幂等语义

- **做法**：在 `restore_backup()` 目标选取处补 2 行注释：目标选取有意在锁外——并发双重 restore 是幂等的（都恢复同一目标）；若移入锁内会变成「后一次恢复前一次的快照」。
- **文件清单**：`scripts/backup.sh`。
- **验证方式**：注释即交付；`mksh -n` 通过。
- **优先级/并行**：低；与 S-2 同文件 → **与 S-2 串行**（或合并为一次 backup.sh 改动）。

### S-5（中，对应 E-1）CI 版本一致性门禁

- **做法**：新增 `tools/check_version_sync.py`：① `module.prop` 的 version == `update.json` 的 version；② `module.prop` 的 versionCode == `update.json` 的 versionCode；③ `update.json` 的 zipUrl 资产名与 version 对应；④ changelog 存在与 version 对应的版本节（归一化 `YYYY.MM.DD[.N]` 与 `YYYYMMDD[.N]` 后比较）。任一不符 exit 1。`check.yml` 加步骤。
- **文件清单**：`tools/check_version_sync.py`（新增）、`.github/workflows/check.yml`。
- **验证方式**：CI 跑过；本地故意把 `update.json` 版本改旧 → 脚本报错 exit 1。
- **优先级/并行**：中；与 S-2/S-3/S-6 可并行。

### S-6（低，对应 E-2）AGENTS.md 补全门禁清单

- **做法**：第 12 行附近列出全部 5 个测试文件及各自适用改动（改 ad.sh→test_ad_sh；改 backup.sh→test_backup_semantics；改 setting_api.sh→test_cron_validate；改 update.sh→test_tar_guard；改 dns.sh→test_owner_probe），并补一段测试编写模式说明（driver/抽取真实函数/Checker/stub，指向任一现有测试为范例）。
- **文件清单**：`AGENTS.md`。
- **验证方式**：通读无歧义；无需门禁。
- **优先级/并行**：低；与 S-2/S-3/S-5 可并行。

### S-7（低，对应维度 6 局限 1）按 shell 能力启用锁阻塞用例

- **做法**：在 `test_cron_validate.py`/`test_backup_semantics.py` 中探测 `kill -0 1` 是否成功（shell 能检测进程）：能则跑「活进程持锁→拒绝」用例，不能则跳过并打印原因（保持本机可跑、CI 上自动启用）。活进程用 `bash -c 'printf "%s" "$$" > pidfile; exec sleep 60'`（cwd+相对路径，规避 MSYS 路径 mangling 与内置 echo 挂起两个坑，经验已记入项目 memory）。
- **文件清单**：`tools/test_cron_validate.py`、`tools/test_backup_semantics.py`。
- **验证方式**：CI（mksh，`kill -0 1` 正常）日志出现锁阻塞用例 PASS；本机跳过且不失败。
- **优先级/并行**：低；与 S-2 共享 `test_backup_semantics.py` → **与 S-2/S-4 串行**。

### S-8（中，对应维度 5 覆盖缺口）watchdog 纯逻辑测试

- **做法**：新增 `tools/test_watchdog_logic.py`，从 `watchdog.sh` 抽取 `current_dns_entry()` 等纯函数（不启动守护循环），mock `isRun`/`is_port_listening`，覆盖：两种模式各自的后退链、全挂掉输出 none、同名端口恢复场景入口不变。退避/恢复判定若抽取代价高，可先只覆盖 `current_dns_entry`（与 S-1 共享被测逻辑，宜在 S-1 之后做，直接用抽取后的共享函数）。
- **文件清单**：`tools/test_watchdog_logic.py`（新增）、`.github/workflows/check.yml`。
- **验证方式**：新套件全过 + CI 纳入。
- **优先级/并行**：中；**建议在 S-1 之后执行**（S-1 完成后 `current_dns_entry` 变为共享函数的薄包装，测试直接覆盖共享函数）；文件上与新文件无冲突，但逻辑上有依赖。

## 四、优先级与并行性

**推荐顺序**：S-1 → S-2(+S-4 合并) / S-5 / S-6（并行组）→ S-8 → S-3 → S-7。

**并行标注**：

| 建议 | 优先级 | 并行性 |
|---|---|---|
| S-1（DNS 入口合一） | 高 | 独立；单独提交 |
| S-2（restore 清残留） | 中 | 与 S-3/S-5/S-6 可并行；与 S-4 合并、与 S-7 串行 |
| S-3（TTL 常量） | 低 | 与 S-2/S-5/S-6 可并行 |
| S-4（restore 语义注释） | 低 | 与 S-2 合并进同一次 backup.sh 改动 |
| S-5（版本一致性门禁） | 中 | 独立 |
| S-6（AGENTS.md 门禁清单） | 低 | 独立 |
| S-7（锁阻塞用例） | 低 | 与 S-2/S-4 串行（共享测试文件） |
| S-8（watchdog 测试） | 中 | 文件独立，但逻辑依赖 S-1，排在 S-1 后 |

**可并行组内文件无重叠已确认**：S-2/S-3/S-5/S-6 分别动 `backup.sh`/`setting.sh`/`tools+check.yml`/`AGENTS.md`，互不重叠。

## 五、审计边界说明

- 未审查：`etc/` 下第三方二进制（AdGuardHome/SmartDNS/mihomo 本体）与其自带配置模板；`webroot` 第三方 THIRD_PARTY_NOTICES。
- 未在设备实机运行任何用例（无设备接入）；设备行为差异仅通过 busybox 文档与历史冒烟记录推断。
- 本报告所有「已解决」判定均以 commit `3b3f24f` 的代码与 CI 记录为据。
