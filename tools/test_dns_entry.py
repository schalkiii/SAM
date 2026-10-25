#!/usr/bin/env python3
"""DNS 入口选择链一致性回归测试

背景: 「按 MODULE_DNS_MODE 逐级回退选 DNS 入口」曾有三份独立实现——
iptables/dns.sh select_dns_port、watchdog.sh current_dns_entry、
webui.sh resolve_dns_entry，靠注释保证一致(审计 A-1，v20261024.18 已因此
发生过整机 DNS 计数器归零故障)。现统一为 base.sh 的 dns_entry_port。

本测试从三个脚本抽取真实函数(不复制实现)，用 mock isRun/is_port_listening
驱动「模式 × 服务存活 × 端口监听」组合矩阵，断言:
  - 共享函数按模式正确回退，输出 "名称:端口" 或空
  - watchdog 消费方输出与共享函数一致(空时输出 none)
  - WebUI 消费方的标签/端口与共享函数一致(空时"未监听"，直通模式优先)
  - 三处结论永远一致(这是 A-1 的核心属性: 规则、监控、显示同一个入口)

用法:
    python tools/test_dns_entry.py            # 跑全部用例
    python tools/test_dns_entry.py -v         # 打印每个用例细节
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# 与 setting.sh 默认值一致; mock isRun 按 bin 路径后缀匹配
DRIVER_HEADER = '''#!/bin/sh
AGH_BIN="/mod/bin/AdGuardHome/AdGuardHome"
MIHOMO_BIN="/mod/bin/mihomo"
SMARTDNS_BIN="/mod/bin/smartdns"
AGH_DNS_PORT=5300
MIHOMO_DNS_PORT=1053
SMARTDNS_PORT=3721
MODULE_DNS_MODE="${TEST_DNS_MODE}"
BYPASS_ENABLE="${TEST_BYPASS:-false}"

isRun(){
  case "${1}" in
    *AdGuardHome*) [ "${TEST_AGH_RUN:-0}" = "1" ] ;;
    *mihomo*) [ "${TEST_MIHOMO_RUN:-0}" = "1" ] ;;
    *smartdns*) [ "${TEST_SMARTDNS_RUN:-0}" = "1" ] ;;
    *) return 1 ;;
  esac
}
is_port_listening(){
  case "${1}" in
    5300) [ "${TEST_AGH_LISTEN:-0}" = "1" ] ;;
    1053) [ "${TEST_MIHOMO_LISTEN:-0}" = "1" ] ;;
    3721) [ "${TEST_SMARTDNS_LISTEN:-0}" = "1" ] ;;
    *) return 1 ;;
  esac
}
'''

DRIVER_FOOTER = '''
echo "shared=$(dns_entry_port)"
echo "watchdog=$(current_dns_entry)"
resolve_dns_entry
echo "webui_label=${dns_entry_label}"
echo "webui_port=${dns_check_port}"
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
    """搭 driver: mock + 三个真实函数的抽取体"""
    parts = [DRIVER_HEADER]
    parts.append(extract_function(REPO / 'scripts' / 'base.sh', 'dns_entry_port'))
    parts.append(extract_function(REPO / 'scripts' / 'watchdog.sh', 'current_dns_entry'))
    parts.append(extract_function(REPO / 'scripts' / 'webui.sh', 'resolve_dns_entry'))
    parts.append(DRIVER_FOOTER)
    driver = base / 'driver.sh'
    driver.write_text('\n\n'.join(parts) + '\n', encoding='utf-8', newline='\n')
    return driver


def run_case(driver, base, env):
    full_env = dict(env)
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    r = subprocess.run(
        [shell, driver.name],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(), env=full_env,
    )
    if r.returncode != 0:
        raise SystemExit(f'driver 执行失败: {r.stderr}')
    out = {}
    for line in r.stdout.splitlines():
        key, _, value = line.partition('=')
        out[key] = value
    return out


def oracle(mode, agh_run, agh_listen, mihomo_run, mihomo_listen, sd_run, sd_listen):
    """独立算盘: 期望的入口(与实现无关的简单 if/elif，用于交叉验证)"""
    agh = '5300' if (agh_run and agh_listen) else ''
    mihomo = '1053' if (mihomo_run and mihomo_listen) else ''
    sd = '3721' if (sd_run and sd_listen) else ''
    if str(mode) == '2':
        chain = [('Mihomo', mihomo), ('AdGuardHome', agh)]
    else:
        chain = [('AdGuardHome', agh), ('Mihomo', mihomo)]
    for name, port in chain:
        if port:
            return f'{name}:{port}'
    if sd:
        return f'SmartDNS:{sd}'
    return ''


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


# 场景矩阵: (模式, agh_run, agh_listen, mihomo_run, mihomo_listen, sd_run, sd_listen)
# 只取有语义差别的组合(全因子 128 组绝大多数等价)，覆盖:
#   全挂 / 只有某一级 / 前两级都在(比模式) / 进程在但端口死 / 端口假监听但进程死
SCENARIOS = [
    # (标签, 参数...)
    ('全挂',            1, 0, 0, 0, 0, 0, 0),
    ('全挂(模式2)',     2, 0, 0, 0, 0, 0, 0),
    ('只有 SmartDNS',   1, 0, 0, 0, 0, 1, 1),
    ('只有 SmartDNS(2)',2, 0, 0, 0, 0, 1, 1),
    ('只有 AGH',        1, 1, 1, 0, 0, 0, 0),
    ('只有 Mihomo',     1, 0, 0, 1, 1, 0, 0),
    ('AGH+Mihomo 模式1', 1, 1, 1, 1, 1, 0, 0),
    ('AGH+Mihomo 模式2', 2, 1, 1, 1, 1, 0, 0),
    ('三者全在 模式1',   1, 1, 1, 1, 1, 1, 1),
    ('三者全在 模式2',   2, 1, 1, 1, 1, 1, 1),
    ('AGH进程在端口死',  1, 1, 0, 0, 0, 0, 0),
    ('AGH进程死端口活',  1, 0, 1, 0, 0, 0, 0),
    ('Mihomo进程在端口死回落AGH', 1, 1, 1, 1, 0, 0, 0),
    ('Mihomo进程死端口活不选它',  2, 0, 0, 0, 1, 0, 0),
    ('SmartDNS进程死端口活',     1, 0, 0, 0, 0, 0, 1),
    ('AGH+SmartDNS 模式2',       2, 1, 1, 0, 0, 1, 1),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_dns_entry_test_'))
    try:
        driver = build_driver(base)
        c = Checker(verbose=args.verbose)

        for label, mode, agh_run, agh_listen, mihomo_run, mihomo_listen, sd_run, sd_listen in SCENARIOS:
            env = {
                'TEST_DNS_MODE': str(mode),
                'TEST_AGH_RUN': str(agh_run), 'TEST_AGH_LISTEN': str(agh_listen),
                'TEST_MIHOMO_RUN': str(mihomo_run), 'TEST_MIHOMO_LISTEN': str(mihomo_listen),
                'TEST_SMARTDNS_RUN': str(sd_run), 'TEST_SMARTDNS_LISTEN': str(sd_listen),
            }
            out = run_case(driver, base, env)
            expected = oracle(mode, agh_run, agh_listen, mihomo_run, mihomo_listen, sd_run, sd_listen)
            c.check(f'[{label}] 共享函数回退正确', out.get('shared', '<缺失>'), expected)
            c.check(f'[{label}] watchdog 与共享一致', out.get('watchdog', '<缺失>'),
                    expected if expected else 'none')
            if expected:
                c.check(f'[{label}] webui 标签与共享一致', out.get('webui_label', '<缺失>'), expected)
                c.check(f'[{label}] webui 端口与共享一致', out.get('webui_port', '<缺失>'),
                        expected.split(':')[1])
            else:
                c.check(f'[{label}] webui 无入口显示未监听', out.get('webui_label', '<缺失>'), '未监听')
                c.check(f'[{label}] webui 无入口端口为空', out.get('webui_port', '<缺失>'), '')

        # 直通模式: WebUI 显示"直通模式"，不参与入口计算(其余两方不管直通)
        env = {
            'TEST_DNS_MODE': '1', 'TEST_BYPASS': 'true',
            'TEST_AGH_RUN': '1', 'TEST_AGH_LISTEN': '1',
            'TEST_MIHOMO_RUN': '0', 'TEST_MIHOMO_LISTEN': '0',
            'TEST_SMARTDNS_RUN': '0', 'TEST_SMARTDNS_LISTEN': '0',
        }
        out = run_case(driver, base, env)
        c.check('[直通模式] webui 显示直通模式', out.get('webui_label', '<缺失>'), '直通模式')
        c.check('[直通模式] webui 不报端口', out.get('webui_port', '<缺失>'), '')

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
