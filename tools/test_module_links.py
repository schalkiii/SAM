#!/usr/bin/env python3
"""模块软链回归测试（SmartDNS 启动的前置条件）

背景: SmartDNS 是 musl 二进制，ELF 解释器写成相对路径 "lib/ld-musl-aarch64.so.1"，
必须靠三条软链才能执行:
    bin/smartdns                          PATH 查找(service_exec 按裸名调用)
    etc/SmartDNS/lib/ld-musl-aarch64.so.1 解释器 -> libc.so
    etc/SmartDNS/lib/ld-linux.so          解释器兼容名

真实故障(2026-10-25): 免重启更新先在 modules_update 建链、再 mv 到 modules，
绝对目标随 mv 失效变成悬空链；而"链接是否已存在"的守卫(-L)会一直跳过它，
于是 SmartDNS 永远起不来，日志只有 setuidgid: can't execute 'smartdns'。

本测试从 base.sh 抽取真实的 repair_module_link / ensure_module_links，用真实
文件树与真实 ln 驱动，锁定: 相对目标、悬空链重建、幂等、bin 目录自建、缺目标报错。
不支持 symlink 的文件系统上跳过(MSYS 默认行为可配置)。

用法:
    python tools/test_module_links.py            # 跑全部用例
    python tools/test_module_links.py -v         # 打印每个用例细节
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

LINKS = {
    'bin/smartdns': '../etc/SmartDNS/smartdns',
    'etc/SmartDNS/lib/ld-musl-aarch64.so.1': 'libc.so',
    'etc/SmartDNS/lib/ld-linux.so': 'ld-musl-aarch64.so.1',
}


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


def build_defs():
    """拼出 driver 公共头部: 路径变量 + log stub + 两个真实函数"""
    parts = [
        'MODULE_PATH=mod',
        'BIN_PATH=$MODULE_PATH/bin',
        'SMARTDNS_PATH=$MODULE_PATH/etc/SmartDNS',
        'SMARTDNS_BIN=smartdns',
        'LOG_FILE=$MODULE_PATH/tmp/module.log',
        'log(){ printf "[%s] %s\\n" "$1" "$2" >> "$LOG_FILE"; }',
        extract_function(REPO / 'scripts' / 'base.sh', 'repair_module_link'),
        extract_function(REPO / 'scripts' / 'base.sh', 'ensure_module_links'),
    ]
    return '\n'.join(parts) + '\n'


def shell_name():
    return shutil.which('mksh') or shutil.which('sh') or 'sh'


def run_shell(base, script):
    return subprocess.run(
        [shell_name(), '-c', script],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
    )


def make_tree(base):
    """搭模块目录骨架(真实文件，供 ln 指向)"""
    mod = base / 'mod'
    (mod / 'bin').mkdir(parents=True)
    (mod / 'tmp').mkdir()
    (mod / 'etc' / 'SmartDNS' / 'lib').mkdir(parents=True)
    (mod / 'bin' / 'AdGuardHome').write_text('x\n', encoding='utf-8')
    sd = mod / 'etc' / 'SmartDNS' / 'smartdns'
    sd.write_text('x\n', encoding='utf-8')
    sd.chmod(0o755)
    (mod / 'etc' / 'SmartDNS' / 'lib' / 'libc.so').write_text('x\n', encoding='utf-8')
    return mod


def link_state(mod, rel):
    """返回 (是否可用, 目标路径)

    目标统一成正斜杠: Windows 的 readlink 返回反斜杠，语义与 Linux 相同
    """
    path = mod / rel
    if not path.is_symlink():
        return (False, None)
    target = str(path.readlink()).replace('\\', '/')
    return (path.exists(), target)


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_links_test_'))
    try:
        defs = build_defs()
        c = Checker(verbose=args.verbose)

        # ---- 场景6(静态): 开机脚本必须复用 ensure_module_links ----
        # 开机路径曾自己用绝对目标建链、且只看 -L 就跳过悬空链，与 base.sh 的
        # "相对目标 + 悬空重建"规则相反(v20261025.5 修的正是这类故障)。
        # 这条断言不依赖文件系统能力，任何平台都会执行
        boot_script = (REPO / 'service.sh').read_text(encoding='utf-8')
        c.check('[开机脚本] 调用 ensure_module_links', 'ensure_module_links' in boot_script, True)
        c.check('[开机脚本] 不再自建软链(无重复实现)', 'ln -s' in boot_script, False)

        # 能力门控: 有些文件系统/环境里 ln -s 会退化成拷贝，那测不出软链语义
        probe = run_shell(base, 'mkdir -p probe && ln -s tgt probe/l && [ -L probe/l ] && echo LINK')
        if 'LINK' not in probe.stdout:
            print('  SKIP  当前文件系统不支持 symlink，跳过软链行为用例(静态断言仍已执行)')
            return c.report()

        # ---- 场景1: 全新目录，三条链按相对目标创建 ----
        mod = make_tree(base)
        r = run_shell(base, defs + 'ensure_module_links\n')
        c.check('ensure_module_links 无输出错误', r.returncode, 0)
        for rel, expected_target in LINKS.items():
            ok, target = link_state(mod, rel)
            c.check(f'[新建] {rel} 可用', ok, True)
            c.check(f'[新建] {rel} 目标为相对路径', target, expected_target)

        # ---- 场景2: 绝对悬空链(更新后 mv 的真实后果)必须重建 ----
        for rel in LINKS:
            (mod / rel).unlink()
        (mod / 'bin' / 'smartdns').symlink_to('/data/adb/modules_update/SAM/etc/SmartDNS/smartdns')
        (mod / 'etc' / 'SmartDNS' / 'lib' / 'ld-musl-aarch64.so.1').symlink_to(
            '/data/adb/modules_update/SAM/etc/SmartDNS/lib/libc.so')
        (mod / 'etc' / 'SmartDNS' / 'lib' / 'ld-linux.so').symlink_to(
            '/data/adb/modules_update/SAM/etc/SmartDNS/lib/ld-musl-aarch64.so.1')
        ok_before, _ = link_state(mod, 'bin/smartdns')
        c.check('[悬空] 修复前不可用', ok_before, False)
        run_shell(base, defs + 'ensure_module_links\n')
        for rel, expected_target in LINKS.items():
            ok, target = link_state(mod, rel)
            c.check(f'[悬空] {rel} 已重建为可用', ok, True)
            c.check(f'[悬空] {rel} 目标为相对路径', target, expected_target)

        # ---- 场景3: 幂等，重复调用不改变既有链 ----
        targets_before = {rel: link_state(mod, rel)[1] for rel in LINKS}
        run_shell(base, defs + 'ensure_module_links\n')
        targets_after = {rel: link_state(mod, rel)[1] for rel in LINKS}
        c.check('重复调用不重建已有链', targets_after, targets_before)

        # ---- 场景4: bin 目录被更新流程整体替换后自行补建 ----
        shutil.rmtree(mod / 'bin')
        run_shell(base, defs + 'ensure_module_links\n')
        c.check('[bin 缺失] 目录被重建', (mod / 'bin').is_dir(), True)
        ok, target = link_state(mod, 'bin/smartdns')
        c.check('[bin 缺失] bin/smartdns 可用', ok, True)
        c.check('[bin 缺失] bin/smartdns 目标', target, LINKS['bin/smartdns'])

        # ---- 场景5: 目标二进制不存在时写 ERROR，不静默失败 ----
        (mod / 'etc' / 'SmartDNS' / 'smartdns').unlink()
        (mod / 'bin' / 'smartdns').unlink()
        run_shell(base, defs + 'ensure_module_links\n')
        log_text = (mod / 'tmp' / 'module.log').read_text(encoding='utf-8')
        c.check('目标缺失时记录 ERROR', '软链悬空' in log_text, True)
        c.check('ERROR 带出链接路径', 'bin/smartdns' in log_text, True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
