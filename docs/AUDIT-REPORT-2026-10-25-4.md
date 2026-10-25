# SAM 项目审计报告（2026-10-25 第四轮）

> 审计对象：`D:\workspace\SAM`（SmartDNS + AdGuardHome + Mihomo 三合一 Magisk/KernelSU 模块）
> 审计基线：HEAD `a1461a9`（v20261025.8，第三轮审计修复 + 语法自检修复已提交；CI 全绿）
> 本报告只记录发现与建议；执行状态见文末。与第三轮（`AUDIT-REPORT-2026-10-25-3.md`）的关系：
> 第三轮 S-2~S-10 与 S-11 代码项均已实施，本轮**只登记新增/残留项**，不重复已关闭条目。

> **执行状态（2026-10-25 深夜更新）**：S-4-1~S-4-5 已全部实施，随 v20261025.9 发布。
> 另有用户反馈的 hosts 抓取问题已作为 H-1~H-5 补入本报告并修复。
> 落地结果：十一套件 371 项（CI/mksh；Windows 本机 340 项），CI 全绿；`manual.sh` 首次有了自动化覆盖。
> 本轮同时修正上一版文档的测试计数笔误（九套件实为 335/307，此前写成 344/325）。

## 一、现状描述（可观察事实）

### 规模

| 项 | 数值 |
|---|---|
| Shell 脚本 | 33 个（`scripts/**` 29 + 根目录 4），约 7,250 行 |
| WebUI | `index.html` + `main.js`（约 1,110 行）+ `kernelsu.js` + `styles.css`，无构建步骤 |
| Python 工具 | 13 个：`pack_module.py`、`check_version_sync.py`、11 个测试套件 |
| 测试 | 九套件 **335 项**（CI/mksh），Windows 本机 307 项；CI `module-check` 全绿（H-5 后为十一套件 371/340） |
| 配置键 | `setting.conf` 27 个 + `get` 下发的 2 个只读边界字段 |

### 本周期内的收敛（事实）

- DNS 判定只剩两处实现且职责清晰：`dns_entry_port`（53 入口）与 `dns_chain_upstream`（下游上游，防回头成环）。
- SmartDNS 软链只剩 `ensure_module_links` 一套规则（开机/启动/激活三处复用）。
- `mihomo_expected` 已是唯一"是否该运行 Mihomo"的判定，5 处内联全部关闭。
- 配置语法自检统一走 `setting_syntax_shell`（优先 mksh），CI/dash 误判已消除。

### 质量水平

- 静态门禁：`pack --check`、`check_version_sync`（6 项）、`node --check`、`git diff --check`、33 脚本语法检查全过。
- 测试基线：Windows 307 / CI 335 全绿；锁阻塞与软链行为用例按环境门控。
- 文档：README/AGENTS/changelog 与代码同版本（20261025.8），发布资产已按 tag 构建。

## 二、问题清单（按七个维度）

### 维度 1 文档一致性 — 结论：发现 2 处本轮改动留下的注释不同步

#### D-4-1（低）`setting.sh` / `setting_api.sh` 的说明仍写 "sh -n 自检"

- **位置**：`scripts/setting.sh` 第 75 行注释（「下面的 sh -n 预检直接失败」）；`scripts/setting_api.sh` 第 8 行头部注释（「写后先 sh -n 自检」）。
- **描述**：实现已改为 `setting_syntax_shell`（优先 mksh），注释仍指向旧的 `sh -n`，后续维护者会按注释去改错误的位置。
- **影响范围**：文档与实现不一致，属维护陷阱。
- **严重程度**：低。

#### D-4-2（低）`manual.sh` 的模块结构校验仍直接调用 `sh -n`

- **位置**：`scripts/manual.sh` 第 146-147 行（`validate_module_dir` 校验 `scripts/service.sh`、`scripts/manual.sh`）。
- **描述**：`scripts/service.sh` 含数组展开（`${#BLACKLIST_WIFI[@]}`），在 `/bin/sh` 为 dash 的环境里 `sh -n` 会报 "Bad substitution"，导致结构校验误判为失败。设备上 `/system/bin/sh` 是 mksh，实际不受影响；但这是全项目唯一没跟 `setting_syntax_shell` 对齐的语法检查点。
- **影响范围**：在 dash 环境（开发机/CI/某些容器）执行 `manual.sh activate|repair` 会被误拒；`manual.sh` 刻意不 source base.sh，所以没有现成的统一入口。
- **严重程度**：低。

### 维度 2 文档缺漏 — 结论：本维度未发现新增缺漏

- 第三轮 E-1（crontab 高危任务）与 E-2（docs 随包）已解决：三条任务默认注释且 README/setting.conf/AGENTS 均有说明；`pack_module.py` 已跳过 `docs/`。
- `docs/` 下现有 4 份审计报告 + 1 份设计文档，README 未做索引；属可选补充，不计为问题。

### 维度 3 架构优化点 — 结论：发现 1 项残留、1 项待评估

#### A-4-1（低）服务脚本退出码语义仍是反的（第三轮 C-7 未实施项）

- **位置**：`scripts/service/sd.sh`（第 8-17 行）、`scripts/service/agh.sh`（第 16-25 行）、`scripts/service/mihomo.sh`（第 8-22 行）、`scripts/service/crontabs.sh`（第 8-17 行）。
- **描述**：`start` 在"未启用/已运行"这类正常态返回 1，真正启动失败时却落到函数末尾返回 0；`stop` 在"未运行"返回 1、kill 失败也只记日志。任何新调用方想用 rc 判断结果都会得到相反结论。当前所有调用方都忽略 rc（改查 `isRun`），所以没有现实故障。
- **影响范围**：`service.sh` / `watchdog.sh` / `setting_api.sh` 之外的任何新增调用点都可能踩到；也让"给服务脚本补单元测试"缺少可断言的结果。
- **严重程度**：低（语义陷阱）。

#### A-4-2（低）`main.js` 仍是单文件约 1,110 行

- **位置**：`webroot/js/main.js`。
- **描述**：状态/设置/工具/日志/定时任务/导航混在一个文件。第三轮评估"拆分收益/风险比待定"，本轮复核结论不变：WebUI 无构建步骤，拆分只能靠多个 `<script type="module">`，而现有测试只有 `node --check`（不查逻辑），拆分后的回归风险高于可读性收益。
- **建议**：保持现状，仅在新增功能时按现有分区注释追加；不做一次性拆分。
- **严重程度**：低（不登记为待修项）。

### 维度 4 代码写法 — 结论：发现 2 项可优化点

#### C-4-1（中）`$(setting_syntax_shell)` 在每次写入自检时多开一层子 shell

- **位置**：`scripts/setting_api.sh` 第 209 行；`scripts/setting.sh` 第 89、318 行。
- **描述**：WebUI 一次「保存并应用」会调 `set` 传 27 个标量，`set_scalar` → `replace_line` 每个键都执行一次 `"$(setting_syntax_shell)" -n`。`$( )` 本身是一次子 shell fork，再加一次解释器 fork，等于每个键两次 fork；解释器探测（`command -v mksh`，mksh 内建）每次都重算。
- **优化**：把解释器名在 `setting.sh` 加载期算一次存进变量（`SETTING_SYNTAX_SHELL`），三处直接引用变量，省掉每次的子 shell 与探测。行为不变。
- **严重程度**：中（影响每次保存的耗时，属可量化的热点）。

#### C-4-2（低）`replace_line` 对同一份文件重复做全量 `awk` + 语法解析

- **位置**：`scripts/setting_api.sh` 第 181-213 行。
- **描述**：27 个键 = 27 次全文件 `awk` + 27 次全文件语法解析。可合并为"一次 awk 替换多键 + 一次自检"，但需要把 `set` 的循环改成批量替换，事务语义与失败回滚都要重写。
- **结论**：**不建议本轮实施**。单次保存是低频人工操作，收益（约几十毫秒）远小于改动风险；记录为已知取舍。
- **严重程度**：低。

### 维度 5 测试覆盖率 — 结论：`manual.sh` 仍是唯一无覆盖的编排脚本

#### T-4-1（中）`manual.sh` 的结构校验/目录选择无自动化覆盖

- **位置**：`scripts/manual.sh` 的 `detect_source` / `validate_module_dir` / `clear_module_markers`；第三轮 T-2 已登记，本轮仍未补。
- **描述**：这三个函数决定"激活用哪个目录、包是否可激活、会不会被下次重启删掉"，是免重启激活路径的判定核心，目前只靠人工验证。
- **影响范围**：`repair`/`activate` 的回归只能靠真机；一旦 `validate_module_dir` 的必需文件清单与打包清单漂移，激活会被误拒或误放行。
- **严重程度**：中。

#### T-4-2（低）变异验证仍无记录

- **位置**：九套件。
- **描述**：仅 v20261025.3 对 `restore` 的 `-f` 守卫做过一次"改坏实现必须变红"的验证。本周期新增的 `dns_chain_upstream`、`setting_syntax_shell` 都没有做。
- **严重程度**：低。

### 维度 6 测试严谨性 — 结论：环境差距已缩小，仍留 1 项

#### R-4-1（低）Windows 本机仍跑不到软链行为与锁阻塞用例

- **位置**：`test_module_links`（本机仅静态 2 项）、`test_cron_validate` / `test_backup_semantics`（锁阻塞跳过）。
- **描述**：本周期已用 WSL 的 mksh 复跑九套件（344 项全绿），证明 CI 结论可在本地复现；但日常工作流仍以 Windows 为准，`SKIP` 行容易被忽略。
- **建议**：保持 `SKIP` 文案明确（已写"静态断言仍已执行"），并在 AGENTS 里写明"发布前用 WSL 复跑一次"。
- **严重程度**：低。

### 维度 7 工程规范 — 结论：本维度未发现新增问题

- CI 绿色；`pack --check` 不含 `docs/`；版本三处 + 凭据/描述门禁齐备。
- 可选改进（不计为问题）：CI 不产出发布 zip，发版资产由本地构建；如需可复现发布，可在 CI 增加 artifact 上传。

## 三、改进建议

### S-4-1（中，对应 C-4-1）语法解释器改为加载期缓存

- **做法**：`scripts/setting.sh` 顶部定义 `SETTING_SYNTAX_SHELL="sh"`，加载时 `command -v mksh >/dev/null 2>&1 && SETTING_SYNTAX_SHELL=mksh`；`setting.sh` 的 `load_setting`/`setting_salvage` 与 `setting_api.sh` 的 `replace_line` 直接引用 `${SETTING_SYNTAX_SHELL}`，删除 `$(setting_syntax_shell)` 子 shell 调用。
- **文件清单**：`scripts/setting.sh`、`scripts/setting_api.sh`。
- **验证方式**：① WSL(mksh) 与 Windows 各跑 `test_setting_transaction`（31 项）、`test_cron_validate`（34/38 项）；② `python tools/test_dns_entry.py` 不回归；③ `pack --check`。

### S-4-2（低，对应 D-4-1/D-4-2）注释与 `manual.sh` 语法检查对齐

- **做法**：改 `setting.sh` 第 75 行与 `setting_api.sh` 头部的 `sh -n` 措辞为 `setting_syntax_shell`；`manual.sh` 在文件顶部按同一规则探测一次解释器（不 source base.sh，保持独立），`validate_module_dir` 使用它。
- **文件清单**：`scripts/setting.sh`、`scripts/setting_api.sh`、`scripts/manual.sh`。
- **验证方式**：`grep -n "sh -n" scripts/` 只剩说明性文字；WSL 下构造含数组的 `scripts/service.sh` 副本，断言 `validate_module_dir` 通过。

### S-4-3（中，对应 A-4-1）服务脚本退出码语义修正

- **做法**：四个 `service/*.sh` 的 `start`/`stop` 改为"正常态返回 0、真实失败返回 1"：
  - `start`：未启用/已运行 → 0；配置非法、二进制缺失、进程未起来 → 1；
  - `stop`：未在运行 → 0；kill 失败 → 1。
  调用方（`service.sh`、`watchdog.sh`、`setting_api.sh`、`agh_reset.sh`）目前均忽略子脚本 rc，无需改动；`service.sh` 自身的健康判定继续用 `isRun`。
- **文件清单**：`scripts/service/{sd,agh,mihomo,crontabs}.sh`。
- **验证方式**：`pack --check`（语法）；真机 `sd.sh stop` 连续两次断言退出码 0；`mihomo.sh start`（未启用）断言 0；人为重命名二进制后 `sd.sh start` 断言 1。

### S-4-4（中，对应 T-4-1）新增 `tools/test_manual_repair.py`

- **做法**：沿用"抽取真实函数"模式，覆盖：
  - `detect_source`：update 存在优先于 active；都不存在输出空；
  - `validate_module_dir`：缺 `module.prop`/脚本/二进制、脚本语法坏、齐全六种组合；
  - `clear_module_markers`：`update`/`remove`/`disable`/`skip_mount` 全删、其它文件不动。
  测试用最小假脚本（无数组），避免依赖 dash/mksh 差异。
- **文件清单**：新增 `tools/test_manual_repair.py`；`.github/workflows/check.yml` 加一步。
- **验证方式**：新套件全绿；故意删掉 `validate_module_dir` 的 `-x` 检查 → 用例必须红；WSL 复跑。

### S-4-5（低，对应 R-4-1/T-4-2）流程性建议

- **做法**：AGENTS 的「怎么跑」补一句"发布前在 WSL 用 mksh 复跑九套件（`wsl -- python3 tools/test_*.py`）"；对 `dns_chain_upstream` 做一次"改坏必须变红"的手工变异验证并记入 changelog。
- **文件清单**：`AGENTS.md`、`changelog.md`。
- **验证方式**：文档通读；变异验证记录一行。

## 四、优先级与并行性

| 优先级 | 建议 | 依赖 | 并行性 |
|---|---|---|---|
| P0 | S-4-3（退出码语义） | 无 | 与 S-4-1/S-4-2 文件不重叠，可并行 |
| P1 | S-4-1（解释器缓存） | 与 S-4-2 同碰 setting 两文件 | 与 S-4-2 合并为一次提交 |
| P1 | S-4-2（注释/`manual.sh` 对齐） | 同上 | 与 S-4-1 合并 |
| P1 | S-4-4（manual 测试） | 建议在 S-4-3 之后（可与 rc 一起断言） | 独立文件 |
| P2 | S-4-5（流程记录） | 无 | 收尾 |

**推荐顺序**：S-4-3 → S-4-1 + S-4-2（同一提交）→ S-4-4 → S-4-5。
每组完成后跑：`pack --check`、`check_version_sync`、全部套件（Windows + WSL 各一遍）、`node --check`、`git diff --check`。

## 五、补充审计：hosts 抓取失败（用户反馈，2026-10-25）

用户反馈「FCM 和 GitHub host 一直是获取不到」。三个候选源在本机实测全部 200（ghfast 1.5s / raw 1.5s / jsdelivr 2.0s），说明**地址本身没问题**，失败发生在设备侧的执行条件。

#### H-1（高）设备缺 curl 时 hosts 抓取 100% 失败

- **位置**：`scripts/update/host.sh` 原第 39 行（`curl -m 15 -s -f ${i}`）。
- **描述**：下载只走 curl；精简 ROM 往往没有 curl（只有 busybox/toybox 的 wget）。此时三个候选源全部"不可用"，日志与真实网络状况无关。
- **修复**：`base.sh` 新增 `fetch_url`（curl → wget → busybox wget），`host.sh` 统一调用。

#### H-2（高）开机网络未就绪，一次性拉取全源失败且重试窗口太长

- **位置**：`scripts/service.sh` 第 115 行（延迟 10 秒）+ `host.sh` update 分支。
- **描述**：只延迟 10 秒且不判断网络就绪；WiFi/移动数据常在解锁后才连上，于是两条规则都失败。时间戳只在两条都成功时写入，重试要等下一次服务启动（可能数天）。
- **修复**：`base.sh` 新增 `is_network_ready`（IP 直连探测，绕开尚未就绪的 DNS）与 `wait_network`；`host.sh` 更新前 `wait_network 60`，未取全的规则 30 秒后补拉一次（最多两轮）。

#### H-3（中）直连 raw 排在代理前面，被墙时白等超时

- **位置**：`host.sh` 的 `GITHUB_HOST_SOURCES` / `FCM_HOST_SOURCES`。
- **描述**：raw.githubusercontent.com 在国内移动网络常被 RST/污染；原顺序先直连、且单源超时 15 秒。用户建议的 ghfast.top 本来就在第二位，但因 H-1/H-2 从未真正生效。
- **修复**：ghfast.top 提到首位；单源超时 15s → 10s。实测 ghfast 返回 200 且不跳转。

#### H-4（中）出厂 hosts 没有预置最新规则

- **位置**：`etc/hosts`。
- **描述**：新装或断网首启必须等联网后才拿到 GitHub/FCM 规则，此前文件里是旧数据。
- **修复**：已用 ghfast.top 拉取、按 `IP 域名` 严格校验后合并（GitHub 40 条 / FCM 24 条），随包分发。

#### H-5（低）抓取逻辑无自动化覆盖

- **修复**：新增 `tools/test_host_sources.py`（20 项）：curl/wget 降级、源顺序（ghfast 首位）、HTML 错误页拒绝、section 替换去重、全源失败保留原文件、`wait_network` 就绪/超时。

## 六、审计边界说明

- 未在真机（Android + mksh + busybox）执行；所有结论来自静态阅读与 Windows/WSL 双环境实测。
- 第三方二进制与 `etc/*/wwwroot|webui` 前端资源不在范围内。
- 第三轮遗留且本轮明确不实施：C-7（已在 S-4-3 落地）、A-5（`main.js` 拆分，结论：不做）、
  `replace_line` 批量合并（收益低、风险高，记录为已知取舍）。
