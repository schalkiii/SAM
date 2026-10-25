# SAM 项目审计报告（2026-10-25 第五轮）

> 审计对象：`D:\workspace\SAM`（SmartDNS + AdGuardHome + Mihomo 三合一 Magisk/KernelSU 模块）
> 审计基线：HEAD `c61b375`（v20261025.9 已发布；工作区干净）。审计开始后按本轮建议实施修复。
> 与第四轮（`AUDIT-REPORT-2026-10-25-4.md`）的关系：第四轮 S-4-1~S-4-5 与 H-1~H-5 均已关闭，
> 本轮**只登记新增/残留项**，不重复已关闭条目。

> **执行状态（2026-10-25）**：P0/P1 项已实施并验证。十一套件由 371/340 增至
> **392 项（CI/mksh）/ 361 项（Windows 本机）**；新增覆盖集中在组件下载降级、
> WebUI DNS 规则快检、watchdog 拓扑刷新与常驻脚本信号处理。
> P2/P3 项保留为建议，未在本轮改动。

## 一、现状描述（可观察事实）

### 规模

| 项 | 数值 |
|---|---|
| Shell 脚本 | 33 个（`scripts/**` 29 + 根目录 4），7,311 行 |
| WebUI | `index.html` + `main.js`（985 行）+ `kernelsu.js`（132 行）+ `styles.css`，无构建步骤 |
| Python 工具 | 13 个：`pack_module.py`、`check_version_sync.py`、11 个测试套件 |
| 测试 | 十一套件 **371 项**（CI/mksh），Windows 本机 340 项；本轮增至 392/361 |
| 配置键 | `setting.conf` 27 个 + `get` 下发的 2 个只读边界字段 |
| 文档 | README、AGENTS、changelog、5 份审计报告、1 份广告屏蔽设计文档 |

### 本周期内的收敛（事实）

- DNS 入口与下游上游仍分别只有 `base.sh` 的 `dns_entry_port` / `dns_chain_upstream` 两处实现。
- SmartDNS 软链只有 `ensure_module_links` 一套规则；`manual.sh` 因激活阶段 base.sh 不可用而独立实现同规则。
- `mihomo_expected` 仍是唯一「是否该运行 Mihomo」判定。
- 配置语法自检统一走 `SETTING_SYNTAX_SHELL`（优先 mksh）。
- hosts 下载已走 `fetch_url`（curl → wget），候选源 ghfast.top 优先，出厂 `etc/hosts` 预置最新规则。

### 质量水平

- 静态门禁：`pack --check --no-write`、`check_version_sync`（6 项）、`node --check`、`git diff --check`、33 脚本 mksh 语法检查全过。
- 测试基线：Windows 361 / CI 392 全绿；锁阻塞、软链行为与不可执行位用例按环境门控。
- 文档：README/AGENTS/changelog 与代码同版本（20261025.9），发布资产已按 tag 构建并校验。

## 二、问题清单（按七个维度）

### 维度 1 文档一致性 — 结论：发现 3 处（均已修）

#### D-5-1（中）备份开关说明仍指向已废弃的单文件路径

- **位置**：`setting.conf` 的 `BACKUP_CONF` 注释；`webroot/index.html` 第 367 行设置项说明。
- **描述**：文案仍写「保存到 `/data/adb/SAM-backup/Mihomo配置.yaml`」，实际备份早已改为
  `/data/adb/SAM-backup/<时间>/` 的全量快照（含设置、三服务配置、黑白名单、hosts、定时任务、广告清单）。
  用户会按旧路径找备份，也会误以为只备份 Mihomo。
- **影响范围**：用户排障与恢复操作；配置项的「注释即文档」承诺失效。
- **严重程度**：中（误导用户）。

#### D-5-2（低）AGENTS 仍写 `setting_api.sh` 用 `sh -n` 自检

- **位置**：`AGENTS.md` 第 30 行。
- **描述**：实现已改为 `SETTING_SYNTAX_SHELL`（优先 mksh），且第四轮已同步 `setting.sh` / `setting_api.sh`
  注释，规则文件这一处漏改。维护者会按旧描述去错误位置修改。
- **严重程度**：低（维护陷阱）。

#### D-5-3（低）默认凭据的可视文案有 6 处，规则只列 4 处

- **位置**：`README.md`、`AGENTS.md`、`scripts/update/desc.sh`、`customize.sh` 安装提示、
  `webroot/index.html` 服务页两处。
- **描述**：AGENTS 的「面板凭据只有两处真身」只列了 README + desc.sh，漏了安装提示与 WebUI；
  `check_version_sync.py` 也只比对 README/AGENTS 与 `smartdns.conf`。改默认密码时后两处极易漏改，
  而 v20261025.7 已发生过同类漂移。
- **严重程度**：低（已把清单补进 AGENTS；门禁扩展见 S-5-9，未实施）。

### 维度 2 文档缺漏 — 结论：发现 2 处（1 处已补，1 处待补）

#### E-5-1（低）常驻脚本的信号语义没有写成约束

- **位置**：`scripts/wifi.monitor.sh`（以及 `ad.sh` / `update.sh` / `update/mihomo.sh` 的 trap）。
- **描述**：「trap 处理器返回后 shell 会继续执行」是 mksh 的既定行为；项目里没有任何文档说明
  「HUP/INT/TERM 的 trap 必须显式 exit」，后续新增常驻脚本很容易复制错误模板。
- **严重程度**：低（本轮已在 AGENTS 增补一条约束）。

#### E-5-2（低）README「组件安全更新」未说明缺 curl 的降级

- **位置**：`README.md` 的「组件安全更新」条目。
- **描述**：组件更新已统一走 `fetch_url`/`fetch_file`，缺 curl 时退回 wget；README 仍只写
  「下载有超时」，用户无法据此判断精简 ROM 是否可用。
- **严重程度**：低（本轮已补一句）。

### 维度 3 架构优化点 — 结论：发现 2 项（均处理）

#### A-5-1（中）watchdog 只按 53 入口判断拓扑变化，会漏掉链内恢复

- **位置**：`scripts/watchdog.sh` 的 `current_dns_entry` / `need_chain_refresh`。
- **描述**：`need_chain_refresh` 原先只在「53 入口字符串变化」时置位。以下场景入口不变，
  但下游上游选择已经改变：
  - 模式 1（AGH→Mihomo→SmartDNS）：AGH 一直在跑（入口 `AdGuardHome:5300`），Mihomo 掉线后被拉起。
    Mihomo 掉线期间 AGH 的上游退到 SmartDNS；恢复后本应改回 Mihomo，但入口没变，AGH 继续直连 SmartDNS，
    查询绕过 Mihomo 的策略。
  - 模式 2（Mihomo→AGH→SmartDNS）：Mihomo 一直在跑，AGH 恢复；Mihomo 的上游本应从 SmartDNS 改回 AGH，
    否则广告过滤被绕过。
  - 末端 SmartDNS 恢复：上游本应从公共 DNS 改回本机 SmartDNS，缓存与测速选优才会重新生效。
- **影响范围**：服务恢复后 DNS 行为与配置不符，且不会自愈，直到下一次入口变化。
- **严重程度**：中（功能偏差，用户可见但不易定位）。

#### A-5-2（低）WebUI 的 DNS 规则快检是 `dns.sh check_dns_chain` 的子集，已发生漂移

- **位置**：`scripts/webui.sh` 的 `check_dns_rule`。
- **描述**：为避免每次刷新都 source base.sh，WebUI 用直接 iptables 查询替代 `dns.sh check`。
  但快检只校验链存在 + udp/tcp 重定向，**没有校验 OUTPUT 跳转**；链在但跳转缺失时界面显示「正常」，
  查询实际不会进入链。`check_dns_chain` 一直有这项校验，两份实现已经漂移。
- **严重程度**：低（显示误报，会导致排障方向错误）。

### 维度 4 代码写法 — 结论：发现 8 项（6 项已修，2 项保留建议）

#### C-5-1（高）`wifi.monitor.sh` 的 trap 吞掉信号，监控无法被禁用

- **位置**：`scripts/wifi.monitor.sh` 第 7 行（原 `trap ... EXIT HUP INT TERM`）。
- **描述**：mksh/dash 实测：只设置 trap 而不 `exit` 时，收到 TERM 后处理器返回、循环继续。
  `webui.sh kill_monitor` 先 `kill`（返回 0）就不会再 `kill -9`，于是 WebUI「禁用监控」提示成功，
  进程仍在运行。由于实例锁也被这段逻辑持有，重启监控同样无效。
- **验证证据**：`mksh -c 'trap "echo caught" TERM; (sleep .2; kill -TERM $$) & sleep 1; echo alive'`
  输出 `caught` 后仍输出 `alive`；dash 行为相同。
- **严重程度**：高（用户操作完全失效，且无日志提示）。

#### C-5-2（高）`update.sh` 仍直接调用 curl，缺 curl 的设备无法更新组件

- **位置**：`scripts/update.sh` 的 `get_download_url`（API）、`download_file`（二进制）、
  `verify_download_checksum`（.sha256）。
- **描述**：hosts 抓取已因同类问题改为 `fetch_url`，但组件更新这条路径漏改。部分 ROM 只有
  busybox wget；此时 API 拿不到、下载失败、校验文件也拿不到，三个组件全部更新失败，
  日志只会显示「下载失败」，与网络状况无关。
- **影响范围**：精简 ROM / 临时 root 环境下的全部组件更新。
- **严重程度**：高（与 H-1 同一根因，说明只修了用户报告的那一个文件）。

#### C-5-3（中）`webui.sh check_dns_rule` 未校验 OUTPUT 跳转

- 同 A-5-2，合并修复。
- **严重程度**：中（显示「正常」而查询不经过模块）。

#### C-5-4（低）`is_network_ready` 的 HTTPS 探测会被证书校验误判

- **位置**：`scripts/base.sh` 的 `is_network_ready`。
- **描述**：用 `https://223.5.5.5/` 探测连通性，但没有 `-k`。按 IP 访问时若证书缺少 IP SAN，
  curl 会因校验失败返回非零，把「网络已就绪」误判成未就绪；随后虽然还有 ping 兜底，
  但 ICMP 被限制的网络会白等 60 秒。
- **严重程度**：低（有 ping 兜底，但会拖慢首次 hosts 更新）。

#### C-5-5（低）`ad.sh` / `update.sh` / `update/mihomo.sh` 复制了同一个 trap 模板

- **位置**：三处 `trap ... EXIT HUP INT TERM`。
- **描述**：与 C-5-1 同源。短任务被信号打断时，处理器返回后脚本继续改名/写配置/替换二进制，
  可能留下半完成状态。三个脚本都应采用「EXIT 释放/清理 + 信号处理器显式退出」。
- **严重程度**：低（触发概率低，但后果是半完成状态）。

#### C-5-6（低）`customize.sh` 向不存在的目录复制，失败被静默吞掉

- **位置**：`customize.sh` 的 SmartDNS `data/`、Mihomo `proxy_provider/`、`rule_provider/` 复制。
- **描述**：新包不一定带这些目录（如 `etc/SmartDNS/data` 在仓库里就不存在），
  `cp -R src/. dest` 在 dest 不存在时失败，且没有 `||` 提示，用户数据（缓存/提供者）静默丢失。
  AGH 分支已经先 `mkdir -p`，另外三处没有。
- **严重程度**：低（多为缓存，提供者丢失影响更大）。

#### C-5-7（低，保留）`manual.sh install_zip` 的保留范围与解压校验

- **位置**：`scripts/manual.sh` 的 `install_zip`。
- **描述**：只保留 `setting.conf`、黑白名单、`hosts`、`AdGuardHome.yaml` 与三个数据目录，
  未保留 `etc/crontabs/root` 与 `etc/mihomo/rule_provider`；用户自定义定时任务与规则提供者在
  免重启安装后会回到出厂状态（备份里有，但不会自动还原）。另外 `unzip -o` 没有拒绝
  `../` 成员，恶意 zip 可越界写文件（本地 root 操作，风险有限）。
- **建议**：保留清单补齐 crontabs/rule_provider；解压前用 `unzip -l` 校验成员名（与
  `safe_tar_extract` 同口径）。
- **严重程度**：低。

#### C-5-8（低，保留）`ad.sh cleanup_removed` 文件分支没有 `.samnew` 保护

- **位置**：`scripts/ad.sh` 第 679 行附近。
- **描述**：目录分支在「非空则保留」上有保护，文件分支直接 `rm -f`。正常情况下 `chattr +i`
  或 `chmod 600 root` 已阻止 App 写入，只有两者都失败时才可能删到新内容。
- **建议**：与目录分支对齐，`-s` 时先改名 `.samnew`。
- **严重程度**：低。

### 维度 5 测试覆盖率 — 结论：发现 4 项缺口（3 项已补）

#### T-5-1（中）组件下载降级没有覆盖

- **位置**：`tools/test_host_sources.py`。
- **描述**：H-5 只覆盖了 `host.sh` 的 `fetch_url`，`fetch_file` 与 `update.sh` 的调用完全没测，
  所以 C-5-2 在上一轮测试全绿的情况下存活。
- **严重程度**：中。

#### T-5-2（中）常驻脚本的信号处理没有覆盖

- **位置**：`tools/test_watchdog_logic.py`（原只测健康判定/配置阻塞）。
- **描述**：C-5-1 这种「trap 不 exit」的错误无法靠功能测试发现，需要结构断言或自投信号测试。
- **严重程度**：中。

#### T-5-3（中，保留）27 个配置键的跨文件一致性没有自动检查

- **位置**：`setting.conf` / `setting.sh` / `setting_api.sh` / `customize.sh` / `webroot/index.html`。
- **描述**：AGENTS 要求「新增键同步五处」，但只能靠人工。当前 27 键 × 5 处目前一致，
  缺一个能防止下次漏改的静态测试。
- **建议**：新增 `test_setting_keys.py`：解析 `setting.conf` 的键，断言 `setting_api.sh` 的
  分类列表与 `get_all` 覆盖、`customize.sh` 迁移列表覆盖、WebUI `data-key` 覆盖；
  同时断言反向没有多余键。
- **严重程度**：中（历史上测试计数与文档已多次漂移）。

#### T-5-4（中）WebUI 的 DNS 规则快检没有覆盖

- **位置**：`tools/test_dns_entry.py`。
- **描述**：`check_dns_rule` 的 5 个分支（正常/链缺失/udp/tcp/OUTPUT 跳转）没有任何断言，
  A-5-2 的漂移因此未被发现。
- **严重程度**：中。

### 维度 6 测试严谨性 — 结论：发现 2 项

#### R-5-1（中）测试按「报告的文件」而不是「失败类型」布防

- **位置**：第四轮 H-5 与 `test_host_sources.py`。
- **描述**：用户报告 hosts 失败，测试只锁了 `host.sh` 不再直接调 curl；同类的 `update.sh`
  仍然直接调 curl，测试全绿。本轮改为对共享 helper 做行为测试，并静态禁止脚本内裸 `curl`。
- **严重程度**：中（测试给了虚假的安全感）。

#### R-5-2（低）测试计数仍靠人工维护

- **位置**：README / AGENTS / changelog。
- **描述**：本轮把 371/340 更新为 392/361，并已用 Windows 与 WSL 双环境实测核对；
  但计数仍无自动生成机制，历史上已两次写错。
- **建议**：长期可让 CI 汇总各套件「通过 N 项」并生成 badge/文档片段；本轮不做。
- **严重程度**：低。

### 维度 7 工程规范 — 结论：未发现新增问题

- CI 绿色；`pack --check` 不含 `docs/`、`tools/`、`dist/`；版本三处 + 凭据/描述门禁齐备。
- `pack_module.py` 的文本规范化不覆盖 LICENSE 与第三方前端资源，属已知取舍：设备执行不受影响，
  一次性转 LF 会产生大量 vendor diff，保持现状。
- CI 仍不产出发布 zip（发版资产由本地构建），属已知取舍。
- `docs/` 下已有 5 份审计报告，未做索引；历史留档，不计为问题。

## 三、改进建议与落地结果

### S-5-1（高，对应 C-5-1/C-5-5）信号 trap 显式退出（已实施）

- **做法**：
  - `wifi.monitor.sh`：拆成 `trap ... EXIT` 与 `trap '...; exit 0' HUP INT TERM`；
  - `ad.sh` / `update.sh` / `update/mihomo.sh`：同样拆成两行，信号处理器释放锁/清理临时文件后 `exit 1`。
- **文件清单**：`scripts/wifi.monitor.sh`、`scripts/ad.sh`、`scripts/update.sh`、`scripts/update/mihomo.sh`。
- **验证方式**：`test_watchdog_logic.py` 新增 7 项：4 个脚本的信号 trap 必须含 `exit` +
  动态自投 TERM 断言 `wifi.monitor` 不再输出 `ALIVE` 且退出码 0；真机 WebUI「禁用 WiFi 监控」后
  `pgrep -f wifi.monitor.sh` 应为空。

### S-5-2（高，对应 C-5-2）组件更新下载加 wget 降级（已实施）

- **做法**：`base.sh` 新增 `fetch_file`（curl → wget → busybox wget，落盘而非 stdout）；
  `update.sh` 的 API 改 `fetch_url`、二进制改 `fetch_file`、`.sha256` 改 `fetch_url` 重定向。
- **文件清单**：`scripts/base.sh`、`scripts/update.sh`。
- **验证方式**：`test_host_sources.py` 新增 6 项：`fetch_file` 的 curl/wget/无工具三态 +
  `update.sh` 无裸 `curl` 调用 + API/二进制走共享 helper；真机缺 curl 环境用 `update.sh` 跑一次
  （至少应看到「已是最新版本」或明确的下载失败原因，而不是全部源静默失败）。

### S-5-3（中，对应 C-5-3/A-5-2）WebUI 快检补 OUTPUT 跳转（已实施）

- **做法**：`check_dns_rule` 增加 `iptables -t nat -C OUTPUT -j REDIRECT_DNS`，
  与 `check_dns_chain` 的校验项对齐。
- **文件清单**：`scripts/webui.sh`、`tools/test_dns_entry.py`。
- **验证方式**：新增 8 项动态用例：全规则存在→正常、OUTPUT 缺失→异常且确实发起过该检查、
  chain/udp/tcp 缺失→异常、端口空→「端口未监听」、直通→「直通模式」。

### S-5-4（中，对应 A-5-1）watchdog 恢复也刷新链路（已实施）

- **做法**：`ensure_service` 三类服务成功拉起时置 `need_chain_refresh=1`；
  仍按配置 cksum 决定是否重启下游，内容不变不重启（保留缓存与统计）。
- **文件清单**：`scripts/watchdog.sh`、`tools/test_watchdog_logic.py`、`AGENTS.md`。
- **验证方式**：静态断言 `ensure_service` 三处恢复均置位；真机建议构造「模式 1 下杀 Mihomo，
  观察 AGH 配置的 upstream 是否从 SmartDNS 改回 127.0.0.1:1053」，且 AGH 仅在 cksum 变化时重启。

### S-5-5（低，对应 C-5-4）网络就绪探测加 `-k`（已实施）

- **做法**：`is_network_ready` 的 curl 加 `-k`，只判断连通性，不做证书校验；ping 兜底保留。
- **文件清单**：`scripts/base.sh`。
- **验证方式**：`test_host_sources.py` 现有 wait_network 用例不回归；真机断网/联网各一次，
  观察 hosts 更新是否仍能按 60 秒窗口等待。

### S-5-6（低，对应 D-5-1/D-5-2/E-5-1/E-5-2/C-5-6）文档与安装目录补齐（已实施）

- **做法**：
  - `setting.conf` / `webroot/index.html` 的备份说明改为 `<时间>/` 全量快照；
  - `AGENTS.md` 修正 `sh -n` 措辞、补凭据文案清单、补常驻脚本信号约束、补 watchdog 刷新条件；
  - `README.md` 的组件更新条目补「缺 curl 退回 wget」；
  - `customize.sh` 为 SmartDNS `data/` 与 Mihomo 两个 provider 目录补 `mkdir -p`。
- **文件清单**：`setting.conf`、`webroot/index.html`、`AGENTS.md`、`README.md`、`customize.sh`。
- **验证方式**：`pack --check`；`check_version_sync`；WebUI 设置页通读。

### S-5-7（中，对应 T-5-1/T-5-2/T-5-4）测试补强（已实施）

- **做法**：在既有套件内补 21 项断言，不新增套件（避免 CI 步骤与计数再次漂移）：
  - `test_host_sources.py`：20 → 26；
  - `test_dns_entry.py`：107 → 115；
  - `test_watchdog_logic.py`：20 → 27。
- **验证方式**：Windows 361 项、WSL/CI 392 项全绿；三个新分组在 `-v` 下逐项通过。

### S-5-8（中，保留）27 键跨文件一致性测试

- **做法**：见 T-5-3。新增 `tools/test_setting_keys.py`，并加入 CI。
- **文件清单**：新增测试文件、`.github/workflows/check.yml`、AGENTS/README/changelog 计数。
- **验证方式**：故意从 `customize.sh` 删一个键 → 用例必须变红。

### S-5-9（低，保留）凭据文案门禁扩展到全部可视面

- **做法**：`check_version_sync.py` 增加从 `desc.sh`、`customize.sh`、`webroot/index.html`
  提取账号/密码并与 `smartdns.conf` 比对。
- **文件清单**：`tools/check_version_sync.py`、`AGENTS.md`。
- **验证方式**：临时把 `desc.sh` 的密码改成别的值 → 门禁必须失败。

### S-5-10（低，保留）`manual.sh install_zip` 保留范围与 zip 成员校验

- **做法**：保留清单补 `etc/crontabs/root`、`etc/mihomo/rule_provider`；
  解压前用 `unzip -l` 拒绝以 `/` 开头或含 `..` 的成员。
- **文件清单**：`scripts/manual.sh`、`tools/test_manual_repair.py`。
- **验证方式**：构造含 `../evil` 成员的 zip → 安装必须中止；带自定义 crontab 的旧版 → 安装后保留。

## 四、优先级与并行性

| 优先级 | 建议 | 状态 | 依赖 / 并行性 |
|---|---|---|---|
| P0 | S-5-1 信号 trap | 已实施 | 与 S-5-2 文件不重叠，可并行 |
| P0 | S-5-2 组件下载降级 | 已实施 | 与 S-5-1 可并行 |
| P1 | S-5-3 WebUI 快检 | 已实施 | 独立于 S-5-1/S-5-2 |
| P1 | S-5-4 watchdog 链路刷新 | 已实施 | 与 S-5-3 文件不重叠，可并行 |
| P1 | S-5-5 网络探测 `-k` | 已实施 | 与 S-5-2 同碰 `base.sh`，串行 |
| P2 | S-5-6 文档/安装目录 | 已实施 | 独立 |
| P2 | S-5-7 测试补强 | 已实施 | 依赖 S-5-1~S-5-5 完成后一次跑 |
| P3 | S-5-8 配置键一致性测试 | 保留 | 独立，可与下轮任意项并行 |
| P3 | S-5-9 凭据门禁扩展 | 保留 | 独立 |
| P3 | S-5-10 免重启安装保护 | 保留 | 与 `manual.sh` 其他改动串行 |

**验证命令（每组完成后）**：
`python -X utf8 tools/pack_module.py --check --no-write`、
`python -X utf8 tools/check_version_sync.py`、
全部套件（Windows 361 / WSL 392）、`node --check webroot/js/main.js webroot/js/kernelsu.js`、
`git diff --check`。

## 五、审计边界说明

- 未在真机（Android + mksh + busybox）执行；结论来自静态阅读、Windows 本机与 WSL(mksh) 实测。
- 第三方二进制与 `etc/*/wwwroot|webui` 前端资源不在范围内。
- 第三方前端资源与 LICENSE 的 CRLF 保持现状（设备执行不受影响，整文件转 LF 只会制造无意义 diff）。
- 第四轮明确不实施且本轮维持结论：`main.js` 拆分、`setting_api.sh replace_line` 批量合并。
- 本轮未改动的保留项：C-5-7、C-5-8、T-5-3、S-5-8~S-5-10，均已在文中标注「保留」。
