# 2026.10.21.2
- 新增 WebUI「工具」页：15 个按钮覆盖脚本命令
  - 模块: `manual.sh activate / resume / status`
  - 备份: `backup.sh save / list / restore`
  - 广告与 Hosts: `ad.sh block / recovery / list`、`update/host.sh update`
  - 高级: `iptables/dns.sh enable`、`update/agh.sh`、`update/mihomo.sh`、`update/desc.sh`
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