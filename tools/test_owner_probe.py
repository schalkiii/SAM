#!/usr/bin/env python3
"""dns.sh owner_supported 能力探测回归测试

从 scripts/iptables/dns.sh 中抽取真实的 owner_supported 函数(不复制实现)，
用可编程的 mock iptables 可执行文件驱动，验证：
  - 内核支持 xt_owner 时返回 0 并缓存 "1"，探针链被清理
  - 内核不支持 -m owner 时返回 1 并缓存 "0"，只记一轮日志
  - 上次探测被打断留下残留链时，先清理再重试，不被误判成"不支持"
  - 缓存命中后不再重复探测(守护循环每 10 秒调用一次，不能每轮建链)
  - 缓存 "0" 幂等：不重复探测、不重复刷日志

注意: mksh 中 ${fn}(fn 为函数名)展开为空，函数不走变量命名空间，
所以 mock 必须是可执行文件、通过 iptables_w 变量注入——与 dns.sh 真实用法一致。

用法:
    python tools/test_owner_probe.py            # 跑全部用例
    python tools/test_owner_probe.py -v         # 打印每个用例细节
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

MOCK_IPTABLES = r'''#!/bin/sh
# mock iptables: 记录调用日志，用状态文件模拟 nat 链存在性
LOG="${MOCK_TMP}/calls.log"
STATE="${MOCK_TMP}/chain.state"
echo "iptables $*" >> "${LOG}"
op=""; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -N) op="N" ;;
    -A) op="A" ;;
    -F) op="F" ;;
    -X) op="X" ;;
    SAM_OWNER_PROBE) target="probe" ;;
  esac
  shift
done
[ "${target}" = "probe" ] || exit 0
case "${op}" in
  N)
    # residue 模式模拟"残留链导致 -N 失败"
    if [ -f "${STATE}" ] && [ "${MOCK_MODE}" = "residue" ]; then exit 1; fi
    echo exists > "${STATE}"; exit 0 ;;
  A)
    # nomatch 模式模拟"内核没有 xt_owner，-m owner 插入失败"
    [ "${MOCK_MODE}" = "nomatch" ] && exit 1
    exit 0 ;;
  F) exit 0 ;;
  X) rm -f "${STATE}"; exit 0 ;;
esac
exit 0
'''

DRIVER_HEADER = '''#!/bin/sh
TMP_PATH="${{SAM_TEST_TMP:-/tmp}}"
iptables_w="{mock} -w 100"
log(){{ echo "LOG: $*"; }}
'''

DRIVER_FOOTER = '''
owner_supported
exit $?
'''


def extract_function(script_path, func_name):
    """从脚本中原样抽取函数体(测试真实实现，改动/重命名会立刻失败)"""
    lines = script_path.read_text(encoding='utf-8').splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith(f'{func_name}(){{')), None)
    if start is None:
        raise SystemExit(f'在 {script_path} 中找不到 {func_name}(){{')
    end = next((j for j in range(start + 1, len(lines)) if lines[j] == '}'), None)
    if end is None:
        raise SystemExit(f'{func_name} 函数体没有闭合')
    return '\n'.join(lines[start:end + 1]) + '\n'


def build(base):
    mock_dir = base / 'mockbin'
    mock_dir.mkdir(parents=True)
    mock = mock_dir / 'iptables'
    mock.write_text(MOCK_IPTABLES, encoding='utf-8', newline='\n')
    mock.chmod(0o755)

    driver = base / 'driver.sh'
    driver.write_text(
        DRIVER_HEADER.format(mock=mock.as_posix())
        + extract_function(REPO / 'scripts' / 'iptables' / 'dns.sh', 'owner_supported')
        + DRIVER_FOOTER,
        encoding='utf-8', newline='\n')
    driver.chmod(0o755)
    return driver, mock


def new_scenario(base, name):
    """每个场景独立临时目录: 缓存与调用日志互不污染"""
    d = base / name
    d.mkdir(parents=True)
    return d


def run(driver, scenario_dir, mode):
    env = dict(os.environ)
    env['SAM_TEST_TMP'] = scenario_dir.as_posix()
    env['MOCK_TMP'] = scenario_dir.as_posix()
    env['MOCK_MODE'] = mode
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run(
        [shell, driver.as_posix()],
        capture_output=True, text=True, encoding='utf-8', errors='replace', env=env,
    )


def calls(scenario_dir):
    log = scenario_dir / 'calls.log'
    if not log.exists():
        return []
    return [l for l in log.read_text(encoding='utf-8').splitlines() if l.strip()]


def probe_calls(scenario_dir):
    return [l for l in calls(scenario_dir) if 'SAM_OWNER_PROBE' in l]


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_owner_test_'))
    try:
        driver, _mock = build(base)
        c = Checker(verbose=args.verbose)

        # ---- 场景1: 内核支持 ----
        s1 = new_scenario(base, 'support')
        r = run(driver, s1, 'support')
        c.check('支持时退出码', r.returncode, 0)
        c.check('支持时缓存=1', (s1 / 'owner.supported').read_text(encoding='utf-8').strip(), '1')
        c.check('支持时探针链已清理', (s1 / 'chain.state').exists(), False)
        c.check('支持时恰好 N/A/F/X 四次调用', len(probe_calls(s1)), 4)
        c.check('支持时无错误日志', 'LOG:' in r.stdout, False)

        # ---- 场景2: 内核不支持 -m owner ----
        s2 = new_scenario(base, 'nomatch')
        r = run(driver, s2, 'nomatch')
        c.check('不支持时退出码', r.returncode, 1)
        c.check('不支持时缓存=0', (s2 / 'owner.supported').read_text(encoding='utf-8').strip(), '0')
        c.check('不支持时探针链已清理', (s2 / 'chain.state').exists(), False)
        c.check('不支持时恰好四次调用', len(probe_calls(s2)), 4)
        c.check('不支持时记一条错误日志', r.stdout.count('内核不支持 -m owner'), 1)

        # ---- 场景3: 残留探针链(上次探测被打断) ----
        s3 = new_scenario(base, 'residue')
        (s3 / 'chain.state').write_text('exists\n', encoding='utf-8')
        r = run(driver, s3, 'residue')
        c.check('残留链时退出码', r.returncode, 0)
        c.check('残留链清理后缓存=1', (s3 / 'owner.supported').read_text(encoding='utf-8').strip(), '1')
        c.check('残留链最终被清理', (s3 / 'chain.state').exists(), False)
        # 失败N + F + X + 重试N + A + F + X = 7 次
        c.check('残留链时清理后重试(7 次调用)', len(probe_calls(s3)), 7)
        c.check('残留链时不误报不支持', '内核不支持' in r.stdout, False)

        # ---- 场景4: 缓存命中不重复探测 ----
        s4 = new_scenario(base, 'cache')
        run(driver, s4, 'support')
        first = len(probe_calls(s4))
        r = run(driver, s4, 'support')
        c.check('缓存命中后零新增调用', len(probe_calls(s4)) - first, 0)
        c.check('缓存命中退出码', r.returncode, 0)

        # ---- 场景5: 缓存 0 幂等 ----
        s5 = new_scenario(base, 'idem')
        run(driver, s5, 'nomatch')
        first = len(probe_calls(s5))
        r = run(driver, s5, 'nomatch')
        c.check('缓存0后零新增调用', len(probe_calls(s5)) - first, 0)
        c.check('缓存0退出码', r.returncode, 1)
        c.check('缓存0不重复刷日志', r.stdout.count('内核不支持'), 0)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
