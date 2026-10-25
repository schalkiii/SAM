#!/usr/bin/env python3
"""watchdog 纯逻辑回归测试

守护循环每 5 秒跑一轮，其中三个判定函数一旦判错后果明确:
  - any_dns_service:   有没有任何 DNS 服务在跑(决定是否临时清规则)
  - all_services_running: 是否所有启用服务都健康
      ——这是"服务恢复后刷新网络"的门。判宽了会在还有服务起不来时
        反复断开 WiFi(刷新→无网→再刷新)，判严了恢复后网络不刷新
  - agh_config_blocked: AGH 配置是否仍处于上次校验失败的状态
      ——用 cksum 而不是 mtime，否则 update/agh.sh 每次重写配置都会
        触发"校验失败→5 秒后重试"的死循环

从 watchdog.sh 抽取真实函数(不复制实现)，mock isRun，用真实文件与
真实 cksum 驱动。不启动守护循环本身。另含两类结构断言:
  - ensure_service 在服务恢复时置 need_chain_refresh(入口不变也要重写上游)
  - 常驻/长任务脚本的信号 trap 必须显式 exit，否则 kill 停不掉

用法:
    python tools/test_watchdog_logic.py            # 跑全部用例
    python tools/test_watchdog_logic.py -v         # 打印每个用例细节
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

DRIVER_HEADER = '''#!/bin/sh
SMARTDNS_BIN="/mod/bin/smartdns"
AGH_BIN="/mod/bin/agh"
MIHOMO_BIN="/mod/bin/mihomo"
SMARTDNS_ENABLE="${TEST_SD_ENABLE:-false}"
AGH_ENABLE="${TEST_AGH_ENABLE:-false}"
MIHOMO_ENABLE="${TEST_MIHOMO_ENABLE:-false}"
BYPASS_ENABLE="${TEST_BYPASS:-false}"
TMP_PATH="${TEST_TMP}"
AGH_CONF="${TEST_AGH_CONF}"
SUB_URL=(${TEST_SUB_URLS})

isRun(){
  case "${1}" in
    */smartdns) [ "${TEST_SD_RUN:-0}" = "1" ] ;;
    */agh) [ "${TEST_AGH_RUN:-0}" = "1" ] ;;
    */mihomo) [ "${TEST_MIHOMO_RUN:-0}" = "1" ] ;;
    *) return 1 ;;
  esac
}
'''

DRIVER_FOOTER = '''
any_dns_service; echo "any=$?"
all_services_running; echo "all=$?"
agh_config_blocked; echo "blocked=$?"
'''


def extract_function(script_path, func_name):
    """从脚本中原样抽取函数体(测试真实实现，改动/重命名会立刻失败)"""
    lines = script_path.read_text(encoding='utf-8').splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith(f'{func_name}(){{')), None)
    if start is None:
        raise SystemExit(f'在 {script_path} 中找不到 {func_name}(){{')
    end = next((j for j in range(start + 1, len(lines)) if lines[j] == '}'), None)
    if end is None:
        raise SystemExit(f'{func_name} 函数体没有闭合的 }}')
    return '\n'.join(lines[start:end + 1])


def build_driver(base):
    parts = [DRIVER_HEADER]
    # 被测函数 → 定义所在脚本(all_services_running 依赖 base.sh 的 mihomo_expected)
    sources = [
        (REPO / 'scripts' / 'base.sh', 'mihomo_expected'),
        (REPO / 'scripts' / 'watchdog.sh', 'any_dns_service'),
        (REPO / 'scripts' / 'watchdog.sh', 'all_services_running'),
        (REPO / 'scripts' / 'watchdog.sh', 'agh_config_blocked'),
    ]
    for script_path, func_name in sources:
        parts.append(extract_function(script_path, func_name))
    parts.append(DRIVER_FOOTER)
    driver = base / 'driver.sh'
    driver.write_text('\n\n'.join(parts) + '\n', encoding='utf-8', newline='\n')
    return driver


def build_diag_driver(base):
    """搭 diag_conclusion 的 driver：函数体原样抽取，参数按位置传入"""
    parts = [extract_function(REPO / 'scripts' / 'diagnose.sh', 'diag_conclusion')]
    parts.append('diag_conclusion "$@"\n')
    driver = base / 'diag_driver.sh'
    driver.write_text('\n\n'.join(parts) + '\n', encoding='utf-8', newline='\n')
    return driver


def run_diag(driver, base, args):
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    r = subprocess.run(
        [shell, driver.name] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(), env=dict(os.environ), timeout=10,
    )
    if r.returncode != 0:
        raise SystemExit(f'diag driver 执行失败: {r.stderr}')
    return r.stdout


def run_case(driver, base, env):
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    r = subprocess.run(
        [shell, driver.name],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(), env=env,
    )
    if r.returncode != 0:
        raise SystemExit(f'driver 执行失败: {r.stderr}')
    out = {}
    for line in r.stdout.splitlines():
        key, _, value = line.rpartition('=')
        if key:
            out[key] = value
    return out


class Checker:
    def __init__(self, verbose=False):
        self.passed = 0
        self.failed = 0
        self.verbose = verbose

    def check(self, name, actual, expected):
        if actual == expected:
            self.passed += 1
            if self.verbose:
                print(f'  PASS  {name}')
        else:
            self.failed += 1
            print(f'  FAIL  {name}\n        期望: {expected!r}\n        实际: {actual!r}')

    def report(self):
        print()
        print(f'通过 {self.passed} 项, 失败 {self.failed} 项')
        return 0 if self.failed == 0 else 1


def make_env(base, **overrides):
    """构造 driver 环境: 继承系统环境(保留 shell 需要的变量)，按需覆盖"""
    import os
    tmp_dir = base / 'tmp'
    tmp_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update({
        'TEST_TMP': tmp_dir.as_posix(),
        'TEST_AGH_CONF': (base / 'AdGuardHome.yaml').as_posix(),
        'TEST_SUB_URLS': '',
    })
    env.update({k: str(v) for k, v in overrides.items()})
    return env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_watchdog_test_'))
    try:
        driver = build_driver(base)
        c = Checker(verbose=args.verbose)
        agh_conf = base / 'AdGuardHome.yaml'
        bad_marker = base / 'tmp' / 'agh.config.bad'

        # ---- any_dns_service: 任一服务在跑即可 ----
        out = run_case(driver, base, make_env(base))
        c.check('any_dns_service 全挂', out.get('any'), '1')
        out = run_case(driver, base, make_env(base, TEST_SD_RUN=1))
        c.check('any_dns_service 只有 SmartDNS', out.get('any'), '0')
        out = run_case(driver, base, make_env(base, TEST_AGH_RUN=1))
        c.check('any_dns_service 只有 AGH', out.get('any'), '0')
        out = run_case(driver, base, make_env(base, TEST_MIHOMO_RUN=1))
        c.check('any_dns_service 只有 Mihomo', out.get('any'), '0')

        # ---- all_services_running: 启用 + 运行 的矩阵 ----
        # 全关: 没有任何服务需要健康，返回 0(可刷新)
        out = run_case(driver, base, make_env(base))
        c.check('all_services 全未启用', out.get('all'), '0')
        # 启用但没跑: 返回 1(不刷新，避免反复断网)
        out = run_case(driver, base, make_env(base, TEST_SD_ENABLE='true'))
        c.check('all_services SmartDNS 启用未运行', out.get('all'), '1')
        out = run_case(driver, base, make_env(base, TEST_SD_ENABLE='true', TEST_SD_RUN=1))
        c.check('all_services SmartDNS 启用且运行', out.get('all'), '0')
        out = run_case(driver, base, make_env(base, TEST_AGH_ENABLE='true'))
        c.check('all_services AGH 启用未运行', out.get('all'), '1')
        # 未启用的服务即使没跑也不算异常
        out = run_case(driver, base, make_env(base, TEST_AGH_ENABLE='false', TEST_AGH_RUN=0))
        c.check('all_services 未启用的 AGH 不参与判定', out.get('all'), '0')
        # Mihomo 没有订阅地址时不参与判定(没配置就不该被要求运行)
        out = run_case(driver, base, make_env(base, TEST_MIHOMO_ENABLE='true', TEST_SUB_URLS=''))
        c.check('all_services Mihomo 无订阅不参与判定', out.get('all'), '0')
        # 有订阅且启用但没跑: 异常
        out = run_case(driver, base,
                       make_env(base, TEST_MIHOMO_ENABLE='true', TEST_SUB_URLS='url1'))
        c.check('all_services Mihomo 有订阅未运行', out.get('all'), '1')
        out = run_case(driver, base,
                       make_env(base, TEST_MIHOMO_ENABLE='true', TEST_SUB_URLS='url1 url2',
                                TEST_MIHOMO_RUN=1))
        c.check('all_services Mihomo 有订阅且运行', out.get('all'), '0')
        # 直通模式要暂停 Mihomo，即使有订阅也不要求它运行
        out = run_case(driver, base,
                       make_env(base, TEST_MIHOMO_ENABLE='true', TEST_SUB_URLS='url1',
                                TEST_BYPASS='true'))
        c.check('all_services 直通模式不要求 Mihomo', out.get('all'), '0')

        # ---- agh_config_blocked: cksum 判等，内容变化才解除 ----
        # 无失败标记: 不阻塞
        agh_conf.write_text('config-v1\n', encoding='utf-8', newline='\n')
        out = run_case(driver, base, make_env(base))
        c.check('无失败标记不阻塞', out.get('blocked'), '1')
        # 配置缺失: 不阻塞(启动流程会自行处理缺文件)
        bad_marker.write_text('1 2\n', encoding='utf-8')
        out = run_case(driver, base, make_env(base, TEST_AGH_CONF=(base / 'nope.yaml').as_posix()))
        c.check('配置缺失时不阻塞', out.get('blocked'), '1')
        # 标记的 cksum 与当前配置一致: 阻塞(不再每 5 秒重试)
        # 用 cwd + 相对文件名算 cksum: MSYS 下传原生反斜杠路径会被当成字面名
        stamp = subprocess.run(['bash', '-c', 'cksum AdGuardHome.yaml'],
                               cwd=base.as_posix(), capture_output=True, text=True).stdout.split()
        bad_marker.write_text(f'{stamp[0]} {stamp[1]}\n', encoding='utf-8')
        out = run_case(driver, base, make_env(base))
        c.check('内容未变时保持阻塞', out.get('blocked'), '0')
        c.check('阻塞时不删标记', bad_marker.exists(), True)
        # 配置内容变了: 解除阻塞并删掉标记(允许再试一次)
        agh_conf.write_text('config-v2-changed\n', encoding='utf-8', newline='\n')
        out = run_case(driver, base, make_env(base))
        c.check('内容变化后解除阻塞', out.get('blocked'), '1')
        c.check('解除阻塞时清掉标记', bad_marker.exists(), False)
        # 空标记文件: -s 不成立，视为无标记
        bad_marker.write_text('', encoding='utf-8')
        out = run_case(driver, base, make_env(base))
        c.check('空标记文件不阻塞', out.get('blocked'), '1')

        # ---- 拓扑刷新: 服务恢复也必须触发下游上游重写 ----
        # 只看 53 入口会漏掉"模式 1 下 AGH 一直在跑、Mihomo 恢复"这类情况:
        # 入口没变，但 AGH 的上游应从 SmartDNS 改回 Mihomo
        ensure_body = extract_function(REPO / 'scripts' / 'watchdog.sh', 'ensure_service')
        c.check('ensure_service 三类服务恢复都触发链路刷新',
                ensure_body.count('need_chain_refresh=1'), 3)

        # ---- 信号: 常驻/长任务脚本必须能真的被 kill 停掉 ----
        # 只写 trap ... HUP INT TERM 而不 exit 时，处理器返回后循环继续，
        # WebUI「禁用监控」会看起来成功但进程仍在(已实测 mksh)
        trap_files = [
            REPO / 'scripts' / 'wifi.monitor.sh',
            REPO / 'scripts' / 'ad.sh',
            REPO / 'scripts' / 'update.sh',
            REPO / 'scripts' / 'update' / 'mihomo.sh',
        ]
        for trap_file in trap_files:
            signal_traps = [line for line in trap_file.read_text(encoding='utf-8').splitlines()
                            if line.strip().startswith('trap ') and 'HUP INT TERM' in line]
            c.check(f'{trap_file.name} 的信号 trap 显式 exit',
                    bool(signal_traps) and all('exit' in line for line in signal_traps), True)

        # 动态验证 wifi.monitor 的信号处理: 放真实 trap 行 + 桩函数，自投 TERM
        monitor_text = (REPO / 'scripts' / 'wifi.monitor.sh').read_text(encoding='utf-8')
        monitor_trap = next(line for line in monitor_text.splitlines()
                            if line.strip().startswith('trap ') and 'HUP INT TERM' in line)
        signal_script = base / 'signal_driver.sh'
        signal_script.write_text(
            '#!/bin/sh\n'
            'sam_lock_release(){ :; }\n'
            'release_ad_lock(){ :; }\n'
            'release_update_lock(){ :; }\n'
            'mihomo_cleanup(){ :; }\n'
            f'{monitor_trap}\n'
            '( sleep 0.1; kill -TERM $$ ) &\n'
            'sleep 1\n'
            'echo ALIVE\n',
            encoding='utf-8', newline='\n')
        shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
        signal_run = subprocess.run([shell, signal_script.name], cwd=base.as_posix(),
                                    capture_output=True, text=True, encoding='utf-8',
                                    errors='replace', timeout=10)
        c.check('wifi.monitor 收到 TERM 后退出', 'ALIVE' in signal_run.stdout, False)
        c.check('wifi.monitor 信号退出码为 0', signal_run.returncode, 0)

        # ---- 自动停止结论: 当前状态 + boot_count 优先于历史 stop requested ----
        # 用户实际日志: 2 小时前有 stop requested，但服务后来已 start complete；
        # 当前 state=running、watchdog 心跳 310s 前、全部服务不在——旧实现却
        # 因历史 stop requested 判成"模块主动停止"，把排查方向带偏
        print('[6] 自动停止结论')
        diag_driver = build_diag_driver(base)

        def diag_case(label, args, expected):
            c.check(label, expected in run_diag(diag_driver, base, args), True)

        diag_case('软重启: boot_count 变化',
                  ['running', '3', '1', '310', 'changed', '0', '', '0'],
                  '系统框架已重启')
        diag_case('整组清理: boot_count 未变',
                  ['running', '3', '1', '310', 'same', '0', '', '0'],
                  '整组清理')
        diag_case('boot_count 读取失败',
                  ['running', '3', '1', '310', 'unknown', '0', '', '0'],
                  '无法确认系统是否重启')
        diag_case('state=stopped 判模块停止',
                  ['stopped', '0', '0', '', 'same', '0', '', '0'],
                  '模块主动停止')
        diag_case('state=stopped-by-wifi 判 WiFi 黑名单',
                  ['stopped-by-wifi', '0', '0', '', 'same', '0', '', '2'],
                  'WiFi 黑名单')
        diag_case('启动失败优先',
                  ['running', '3', '1', '310', 'same', '2', '', '0'],
                  '启动失败')
        diag_case('进程级击杀优先',
                  ['running', '3', '1', '310', 'same', '0', '1', '0'],
                  '进程级击杀')
        diag_case('watchdog 死但服务仍在跑',
                  ['running', '0', '1', '310', 'same', '0', '', '0'],
                  '失去守护')
        diag_case('证据不足',
                  ['running', '3', '0', '30', 'same', '0', '', '0'],
                  '没有足够证据')

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
