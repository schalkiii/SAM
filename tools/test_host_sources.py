#!/usr/bin/env python3
"""hosts 抓取回归测试（update/host.sh + base.sh 的下载/等网工具）

用户反馈"GitHub/FCM host 一直获取不到"。已定位的三类原因都在这里锁死:
  1. 设备不一定带 curl —— 原实现直接调 curl，缺工具时所有源都会"看起来失败"
  2. 开机 10 秒后网络常未就绪 —— 一次性拉取全源失败，规则被拖到下次启动
  3. 直连 raw 在国内移动网络被墙/污染 —— 代理源必须排在前面且真的被逐个尝试

测试从脚本原样抽取 fetch_url / fetch_file / wait_network / get_host
(不复制实现)，用 driver 内函数覆盖 curl/wget/is_network_ready，
断言降级与校验逻辑。组件更新(update.sh)与 hosts 属于同一失败类:
设备缺 curl 时两者都必须能退回 wget。

用法:
    python tools/test_host_sources.py            # 跑全部用例
    python tools/test_host_sources.py -v         # 打印每个用例细节
"""

import os
import argparse
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

DRIVER_HEADER = '''#!/bin/sh
HOSTS_FILE="${TEST_HOSTS_FILE}"
log(){ :; }
remount_hosts(){ return 0; }
sleep(){ :; }

has_cmd(){
    case "${1}" in
        curl) [ "${TEST_HAS_CURL:-1}" = "1" ] ;;
        wget) [ "${TEST_HAS_WGET:-0}" = "1" ] ;;
        *) return 1 ;;
    esac
}
curl(){
    # fetch_url 走 stdout；fetch_file 走 -o <文件>
    test_curl_out=""
    test_curl_prev=""
    for test_curl_arg in "$@"; do
        [ "${test_curl_prev}" = "-o" ] && test_curl_out="${test_curl_arg}"
        test_curl_prev="${test_curl_arg}"
    done
    for test_curl_arg in "$@"; do
        case "${test_curl_arg}" in
            *"${TEST_OK_MATCH:-__none__}"*)
                if [ -n "${test_curl_out}" ]; then
                    cat "${TEST_OK_BODY}" > "${test_curl_out}" 2>/dev/null
                else
                    cat "${TEST_OK_BODY}" 2>/dev/null
                fi
                return 0
                ;;
        esac
    done
    return 22
}
wget(){
    # fetch_url 走 stdout；fetch_file 走 -O <文件>
    test_wget_out=""
    test_wget_prev=""
    for test_wget_arg in "$@"; do
        [ "${test_wget_prev}" = "-O" ] && test_wget_out="${test_wget_arg}"
        test_wget_prev="${test_wget_arg}"
    done
    for test_wget_arg in "$@"; do
        case "${test_wget_arg}" in
            *"${TEST_OK_MATCH:-__none__}"*)
                # fetch_url 用 -O - 表示 stdout，不能把 "-" 当成文件名
                if [ -n "${test_wget_out}" ] && [ "${test_wget_out}" != "-" ]; then
                    cat "${TEST_OK_BODY}" > "${test_wget_out}" 2>/dev/null
                else
                    cat "${TEST_OK_BODY}" 2>/dev/null
                fi
                return 0
                ;;
        esac
    done
    return 22
}
is_network_ready(){
    test_probe_count=$(( ${test_probe_count:-0} + 1 ))
    [ "${test_probe_count}" -ge "${TEST_READY_AFTER:-1}" ]
}
'''


def shell_name():
    return shutil.which('mksh') or shutil.which('sh') or 'sh'


def extract_function(script_path, func_name):
    """从脚本中原样抽取函数体(测试真实实现)"""
    lines = script_path.read_text(encoding='utf-8').splitlines()
    start = next((i for i, l in enumerate(lines) if l.startswith(f'{func_name}(){{')), None)
    if start is None:
        raise SystemExit(f'在 {script_path} 中找不到 {func_name}(){{')
    end = next((j for j in range(start + 1, len(lines)) if lines[j] == '}'), None)
    if end is None:
        raise SystemExit(f'{func_name} 函数体没有闭合的 }}')
    return '\n'.join(lines[start:end + 1])


def build_defs():
    base = REPO / 'scripts' / 'base.sh'
    host = REPO / 'scripts' / 'update' / 'host.sh'
    parts = [
        DRIVER_HEADER,
        extract_function(base, 'fetch_url'),
        extract_function(base, 'fetch_file'),
        extract_function(base, 'wait_network'),
        extract_function(host, 'get_host'),
    ]
    return '\n'.join(parts) + '\n'


def run_shell(base, script, extra_env=None):
    env = dict(os.environ)
    env.pop('TEST_OK_MATCH', None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [shell_name(), '-c', script],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(), env=env,
    )


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_host_test_'))
    try:
        defs = build_defs()
        c = Checker(verbose=args.verbose)
        hosts_file = base / 'hosts'
        hosts_file.write_text('127.0.0.1 localhost\n', encoding='utf-8')

        good_body = base / 'good.hosts'
        good_body.write_text('1.2.3.4 github.com\n5.6.7.8 api.github.com\n', encoding='utf-8')
        bad_body = base / 'bad.hosts'
        bad_body.write_text('<html>proxy error</html>\n', encoding='utf-8')
        new_body = base / 'new.hosts'
        new_body.write_text('9.9.9.9 github.com\n', encoding='utf-8')

        print('[1] fetch_url: curl 优先，缺 curl 退回 wget，都没有则失败')
        r = run_shell(base, defs + '\nfetch_url https://a.example/ok\n',
                      {'TEST_HAS_CURL': '1', 'TEST_OK_MATCH': 'ok', 'TEST_OK_BODY': good_body.as_posix()})
        c.check('curl 可用时用 curl', r.stdout.strip(), '1.2.3.4 github.com\n5.6.7.8 api.github.com')
        r = run_shell(base, defs + '\nfetch_url https://a.example/ok\n',
                      {'TEST_HAS_CURL': '0', 'TEST_HAS_WGET': '1',
                       'TEST_OK_MATCH': 'ok', 'TEST_OK_BODY': good_body.as_posix()})
        c.check('缺 curl 时退回 wget', r.returncode, 0)
        c.check('wget 拿到同样内容', '1.2.3.4 github.com' in r.stdout, True)
        r = run_shell(base, defs + '\nfetch_url https://a.example/ok\n',
                      {'TEST_HAS_CURL': '0', 'TEST_HAS_WGET': '0'})
        c.check('两个工具都没有 -> 失败', r.returncode != 0, True)

        print('[2] wait_network: 等到就绪立即返回，超时返回失败')
        r = run_shell(base, defs + '\nwait_network 20 && echo READY\n',
                      {'TEST_READY_AFTER': '2'})
        c.check('第 2 次探测就绪 -> 返回 0', 'READY' in r.stdout, True)
        r = run_shell(base, defs + '\nwait_network 5 || echo TIMEOUT\n',
                      {'TEST_READY_AFTER': '99'})
        c.check('始终未就绪 -> 返回 1', 'TIMEOUT' in r.stdout, True)

        print('[3] get_host: 降级与校验')
        script = defs + f'\nget_host GitHub https://bad.example/hosts https://ghfast.top/https://raw.githubusercontent.com/x/hosts\n'
        r = run_shell(base, script, {'TEST_HOSTS_FILE': hosts_file.as_posix(),
                                     'TEST_OK_MATCH': 'ghfast.top',
                                     'TEST_OK_BODY': good_body.as_posix()})
        content = hosts_file.read_text(encoding='utf-8')
        c.check('首个源失败后采用第二个', r.returncode, 0)
        c.check('section 标记写入', '# start > GitHub' in content and '# GitHub < end' in content, True)
        c.check('内容已写入', '1.2.3.4 github.com' in content, True)

        print('[4] get_host: HTML 错误页必须被拒绝')
        hosts_file.write_text('127.0.0.1 localhost\n', encoding='utf-8')
        r = run_shell(base, script, {'TEST_HOSTS_FILE': hosts_file.as_posix(),
                                     'TEST_OK_MATCH': 'bad.example',
                                     'TEST_OK_BODY': bad_body.as_posix()})
        content = hosts_file.read_text(encoding='utf-8')
        c.check('只拿到 HTML -> 失败', r.returncode != 0, True)
        c.check('失败不改原文件', content, '127.0.0.1 localhost\n')

        print('[5] get_host: 全源失败保留旧规则')
        before = hosts_file.read_text(encoding='utf-8')
        r = run_shell(base, script, {'TEST_HOSTS_FILE': hosts_file.as_posix()})
        c.check('全部失败 -> 返回 1', r.returncode != 0, True)
        c.check('旧内容原样保留', hosts_file.read_text(encoding='utf-8'), before)

        print('[6] get_host: 重复更新替换旧 section')
        run_shell(base, script, {'TEST_HOSTS_FILE': hosts_file.as_posix(),
                                 'TEST_OK_MATCH': 'ghfast.top',
                                 'TEST_OK_BODY': good_body.as_posix()})
        r = run_shell(base, script, {'TEST_HOSTS_FILE': hosts_file.as_posix(),
                                     'TEST_OK_MATCH': 'ghfast.top',
                                     'TEST_OK_BODY': new_body.as_posix()})
        content = hosts_file.read_text(encoding='utf-8')
        c.check('替换成功', '9.9.9.9 github.com' in content, True)
        c.check('旧 IP 已移除', '1.2.3.4 github.com' in content, False)
        c.check('section 不重复', content.count('# start > GitHub'), 1)

        print('[7] fetch_file: 组件下载同样 curl -> wget -> 失败')
        download_curl = base / 'download_curl.bin'
        r = run_shell(base, defs + f'\nfetch_file https://a.example/bin "{download_curl.as_posix()}" 30\n',
                      {'TEST_HAS_CURL': '1', 'TEST_OK_MATCH': 'bin',
                       'TEST_OK_BODY': good_body.as_posix()})
        c.check('curl 下载到文件', download_curl.is_file() and
                download_curl.read_text(encoding='utf-8').startswith('1.2.3.4 github.com'), True)
        download_wget = base / 'download_wget.bin'
        r = run_shell(base, defs + f'\nfetch_file https://a.example/bin "{download_wget.as_posix()}" 30\n',
                      {'TEST_HAS_CURL': '0', 'TEST_HAS_WGET': '1', 'TEST_OK_MATCH': 'bin',
                       'TEST_OK_BODY': good_body.as_posix()})
        c.check('缺 curl 时用 wget 下载到文件', download_wget.is_file(), True)
        download_none = base / 'download_none.bin'
        r = run_shell(base, defs + f'\nfetch_file https://a.example/bin "{download_none.as_posix()}" 30\n',
                      {'TEST_HAS_CURL': '0', 'TEST_HAS_WGET': '0'})
        c.check('两个工具都没有 -> 失败且不产出文件',
                r.returncode != 0 and not download_none.exists(), True)

        print('[8] 静态: 候选源顺序与下载实现')
        host_script = (REPO / 'scripts' / 'update' / 'host.sh').read_text(encoding='utf-8')
        github_block = host_script.split('GITHUB_HOST_SOURCES="', 1)[1].split('"', 1)[0]
        fcm_block = host_script.split('FCM_HOST_SOURCES="', 1)[1].split('"', 1)[0]
        c.check('GitHub 首个源是 ghfast.top',
                github_block.strip().splitlines()[0].startswith('https://ghfast.top/'), True)
        c.check('FCM 首个源是 ghfast.top',
                fcm_block.strip().splitlines()[0].startswith('https://ghfast.top/'), True)
        c.check('host.sh 不再直接调用 curl', 'curl -m' in host_script, False)
        c.check('host.sh 统一下载走 fetch_url', 'fetch_url "${i}"' in host_script, True)

        # 组件更新与 hosts 是同一类失败: 设备缺 curl 时 update.sh 也必须能降级。
        # 这里锁定"脚本里不再出现裸 curl 调用"，防止以后又加回去
        update_script = (REPO / 'scripts' / 'update.sh').read_text(encoding='utf-8')
        c.check('update.sh 不再直接调用 curl',
                bool(re.search(r'^\s*curl\b', update_script, re.M)), False)
        c.check('update.sh 的 API 请求走 fetch_url',
                'api_content=$(fetch_url "${api_url}" 15)' in update_script, True)
        c.check('update.sh 的二进制下载走 fetch_file',
                'fetch_file "${download_url}" "${save_file}" 300' in update_script, True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
