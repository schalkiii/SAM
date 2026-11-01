#!/usr/bin/env python3
"""Hosts DNS 重写回归测试（scripts/update/agh_hosts.sh）

新增 HOST_METHOD=dns 后，etc/hosts 不再生效于 bind-mount，而是转成
AdGuardHome 本地过滤器。这个测试锁死三件事:
  1. hosts 行转 $dnsrewrite 规则: IPv4/IPv6、多 IP、非法行、localhost 保留域
  2. 生成文件原子且幂等: 内容不变时不重写
  3. AGH filters 段只追加一次，且不会破坏原配置

用法:
    python tools/test_hosts_dns.py
    python tools/test_hosts_dns.py -v
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

DRIVER_HEADER = '''#!/bin/sh
HOSTS_FILE="${TEST_HOSTS_FILE}"
HOSTS_FILTER_FILE="${TEST_FILTER_FILE}"
HOSTS_FILTER_NAME="SAM Hosts (DNS)"
HOSTS_FILTER_ID=900000001
AGH_CONF="${TEST_AGH_CONF}"
TMP_PATH="${TEST_TMP_PATH}"
log(){ :; }
sanitize_config(){ return 0; }
'''


def extract_function(script_path, func_name):
    lines = script_path.read_text(encoding='utf-8').splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(f'{func_name}(){{')), None)
    if start is None:
        raise SystemExit(f'找不到函数 {func_name}(){{')
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == '}'), None)
    if end is None:
        raise SystemExit(f'{func_name} 函数体没有闭合的 }}')
    return '\n'.join(lines[start:end + 1])


def build_defs():
    script = REPO / 'scripts' / 'update' / 'agh_hosts.sh'
    return '\n'.join([
        DRIVER_HEADER,
        extract_function(script, 'hosts_generate_rules'),
        extract_function(script, 'write_filter_file'),
        extract_function(script, 'ensure_filter_entry'),
    ]) + '\n'


def run_shell(base, script, extra_env=None):
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run([shell, '-c', script], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', cwd=base.as_posix(), env=env)


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_hosts_dns_'))
    try:
        defs = build_defs()
        c = Checker(verbose=args.verbose)
        tmp = base / 'tmp'
        tmp.mkdir()
        hosts = base / 'hosts'
        hosts.write_text('''127.0.0.1 localhost
::1 ip6-localhost
# comment

13.107.42.16 github.com
140.82.113.3 github.com
2408:4001:f00::1f9 github.com
1.2.3.4 api.github.com extra.example.com
badline
999.1.1.1 invalid.example.com
''', encoding='utf-8')
        filt = base / 'sam-hosts.txt'
        conf = base / 'AdGuardHome.yaml'
        conf.write_text('''dns:
  port: 5300
filters:
  - enabled: true
    url: https://example.com/list.txt
    name: Existing
    id: 1
http:
  address: 127.0.0.1:3000
''', encoding='utf-8')
        env = {
            'TEST_HOSTS_FILE': hosts.as_posix(),
            'TEST_FILTER_FILE': filt.as_posix(),
            'TEST_AGH_CONF': conf.as_posix(),
            'TEST_TMP_PATH': tmp.as_posix(),
        }

        print('[1] hosts_generate_rules: 转成 $dnsrewrite')
        r = run_shell(base, defs + '\nhosts_generate_rules\n', env)
        rules = r.stdout
        c.check('IPv4 多 IP 保留', '||github.com^$dnsrewrite=NOERROR;A;13.107.42.16' in rules and '||github.com^$dnsrewrite=NOERROR;A;140.82.113.3' in rules, True)
        c.check('IPv6 转 AAAA', '||github.com^$dnsrewrite=NOERROR;AAAA;2408:4001:f00::1f9' in rules, True)
        c.check('一行多域名展开', '||api.github.com^$dnsrewrite=NOERROR;A;1.2.3.4' in rules and '||extra.example.com^$dnsrewrite=NOERROR;A;1.2.3.4' in rules, True)
        c.check('localhost 被跳过', 'localhost' not in rules, True)
        c.check('非法 IP/行被跳过', 'badline' not in rules and 'invalid.example.com' not in rules, True)

        print('[2] write_filter_file: 幂等')
        r = run_shell(base, defs + '\nwrite_filter_file; first=$(cat "$HOSTS_FILTER_FILE"); write_filter_file; [ "$first" = "$(cat "$HOSTS_FILTER_FILE")" ] && echo SAME\n', env)
        c.check('重复生成内容一致', 'SAME' in r.stdout, True)
        c.check('生成文件含规则', '||github.com^$dnsrewrite=' in filt.read_text(encoding='utf-8'), True)

        print('[3] ensure_filter_entry: 只追加一次')
        before = conf.read_text(encoding='utf-8')
        r = run_shell(base, defs + '\nensure_filter_entry && echo OK\n', env)
        after1 = conf.read_text(encoding='utf-8')
        c.check('首次写入成功', 'OK' in r.stdout, True)
        c.check('保留原过滤器', 'https://example.com/list.txt' in after1, True)
        c.check('新增本地过滤器', filt.as_posix() in after1, True)
        c.check('本地过滤器 id 写入', 'id: 900000001' in after1, True)
        r = run_shell(base, defs + '\nensure_filter_entry && echo OK\n', env)
        after2 = conf.read_text(encoding='utf-8')
        c.check('二次写入幂等', after2, after1)
        c.check('原文件确实变化过', after1 != before, True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
