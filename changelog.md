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