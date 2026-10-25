#!/usr/bin/env python3
"""manual.sh 免重启激活的判定逻辑回归测试

manual.sh 的 activate / repair 决定"用哪个目录激活、包能不能激活、会不会被
下次重启删掉"，是整条免重启链路里唯一不可逆的判定，此前只靠人工验证。
本测试从脚本原样抽取三个纯判定函数(不复制实现):
  - detect_source:        待激活目录优先于 active，都不存在时输出空
  - validate_module_dir:  必需文件/可执行位/脚本语法缺一不可
  - clear_module_markers: 删掉 update/remove/disable/skip_mount 标记

测试用最小假模块目录；service.sh 里刻意放一段数组展开，验证语法自检走的是
mksh(GNU bash 也可以)，而不是把数组判成语法错误的 dash。

用法:
    python tools/test_manual_repair.py            # 跑全部用例
    python tools/test_manual_repair.py -v         # 打印每个用例细节
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# service.sh 用数组展开: dash 会报 Bad substitution，mksh/bash 正常
VALID_SERVICE_SH = '#!/system/bin/sh\n[ "${#BLACKLIST[@]}" -ge 0 ]\n'
VALID_MANUAL_SH = '#!/system/bin/sh\necho manual\n'
BAD_SH = '#!/system/bin/sh\nif [\n'

DRIVER_HEADER = '''#!/bin/sh
MODULE_ID="SAM"
UPDATE_DIR="${TEST_UPDATE_DIR}"
ACTIVE_DIR="${TEST_ACTIVE_DIR}"
MANUAL_SYNTAX_SHELL="sh"
command -v mksh > /dev/null 2>&1 && MANUAL_SYNTAX_SHELL="mksh"
'''


def shell_name():
    return shutil.which('mksh') or shutil.which('sh') or 'sh'


def run_shell(base, script):
    return subprocess.run(
        [shell_name(), '-c', script],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
    )


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
    manual = REPO / 'scripts' / 'manual.sh'
    parts = [
        DRIVER_HEADER,
        extract_function(manual, 'detect_source'),
        extract_function(manual, 'validate_module_dir'),
        extract_function(manual, 'clear_module_markers'),
    ]
    return '\n'.join(parts) + '\n'


def make_module_dir(path):
    """搭一个结构完整的最小模块目录"""
    (path / 'scripts').mkdir(parents=True)
    (path / 'bin').mkdir()
    (path / 'etc' / 'SmartDNS').mkdir(parents=True)
    (path / 'module.prop').write_text('id=SAM\nversion=test\n', encoding='utf-8')
    (path / 'scripts' / 'service.sh').write_text(VALID_SERVICE_SH, encoding='utf-8')
    (path / 'scripts' / 'manual.sh').write_text(VALID_MANUAL_SH, encoding='utf-8')
    (path / 'scripts' / 'base.sh').write_text('#!/system/bin/sh\n', encoding='utf-8')
    # 用带 shebang 的文本当假二进制: MSYS(Git Bash) 只把有 shebang 的无扩展名
    # 文件认作可执行，纯文本 'x' 即使 chmod 755 也会让 [ -x ] 为假
    for executable in ('bin/AdGuardHome', 'bin/mihomo', 'etc/SmartDNS/smartdns'):
        (path / executable).write_text('#!/bin/sh\n', encoding='utf-8')
    return path


def mark_executable(base, path, executable=True):
    """用 sh 的 chmod 设置可执行位: Python 的 os.chmod 在 Windows 上不动 POSIX 位"""
    mode = '755' if executable else '644'
    run_shell(base, f'chmod {mode} {path.as_posix()}')


def exec_bit_honored(base):
    """sh 的 [ -x ] 是否尊重 chmod 644

    MSYS(Git Bash) 会把带 shebang 的无扩展名文件一律当作可执行，chmod 644
    也测不出来；这种环境跳过"不可执行位"用例，CI(dash/mksh) 正常执行
    """
    probe = base / 'exec_probe.sh'
    probe.write_text('#!/bin/sh\n', encoding='utf-8')
    run_shell(base, f'chmod 644 {probe.as_posix()}')
    r = run_shell(base, f'[ -x {probe.as_posix()} ] && echo X || echo NO')
    return r.stdout.strip() == 'NO'


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


def validate(base, defs, update_dir, active_dir, path):
    env_script = defs.replace('${TEST_UPDATE_DIR}', update_dir) \
                      .replace('${TEST_ACTIVE_DIR}', active_dir)
    return run_shell(base, env_script + f'\nvalidate_module_dir {path.as_posix()}\n').returncode


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_manual_test_'))
    try:
        defs = build_defs()
        c = Checker(verbose=args.verbose)

        update_dir = make_module_dir(base / 'update_mod')
        active_dir = make_module_dir(base / 'active_mod')
        for executable in ('bin/AdGuardHome', 'bin/mihomo', 'etc/SmartDNS/smartdns'):
            mark_executable(base, active_dir / executable)
            mark_executable(base, update_dir / executable)

        update_posix = update_dir.as_posix()
        active_posix = active_dir.as_posix()

        print('[1] detect_source: 待激活目录优先')
        env_script = defs.replace('${TEST_UPDATE_DIR}', update_posix) \
                          .replace('${TEST_ACTIVE_DIR}', active_posix)
        r = run_shell(base, env_script + '\ndetect_source\n')
        c.check('两个目录都在 -> 待激活目录', r.stdout.strip(), update_posix)
        shutil.rmtree(update_dir)
        r = run_shell(base, env_script + '\ndetect_source\n')
        c.check('只有 active -> active 目录', r.stdout.strip(), active_posix)
        shutil.rmtree(active_dir)
        r = run_shell(base, env_script + '\ndetect_source\n')
        c.check('都不存在 -> 空', r.stdout.strip(), '')

        print('[2] validate_module_dir: 结构完整才放行')
        full_dir = make_module_dir(base / 'full_mod')
        for executable in ('bin/AdGuardHome', 'bin/mihomo', 'etc/SmartDNS/smartdns'):
            mark_executable(base, full_dir / executable)
        c.check('结构完整 -> 通过', validate(base, defs, '', '', full_dir), 0)

        (full_dir / 'module.prop').unlink()
        c.check('缺 module.prop -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        (full_dir / 'module.prop').write_text('id=SAM\n', encoding='utf-8')

        (full_dir / 'scripts' / 'manual.sh').unlink()
        c.check('缺 scripts/manual.sh -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        (full_dir / 'scripts' / 'manual.sh').write_text(VALID_MANUAL_SH, encoding='utf-8')

        (full_dir / 'scripts' / 'base.sh').unlink()
        c.check('缺 scripts/base.sh -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        (full_dir / 'scripts' / 'base.sh').write_text('#!/system/bin/sh\n', encoding='utf-8')

        mark_executable(base, full_dir / 'bin' / 'AdGuardHome', executable=False)
        mark_executable(base, full_dir / 'etc' / 'SmartDNS' / 'smartdns', executable=False)
        mark_executable(base, full_dir / 'bin' / 'mihomo', executable=False)
        if exec_bit_honored(base):
            c.check('AdGuardHome 无可执行位 -> 拒绝', validate(base, defs, '', '', full_dir), 1)
            c.check('smartdns 无可执行位 -> 拒绝', validate(base, defs, '', '', full_dir), 1)
            c.check('mihomo 无可执行位 -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        else:
            print('  SKIP  chmod 644 后 [ -x ] 仍为真(MSYS shebang 规则)，跳过不可执行位用例')
        mark_executable(base, full_dir / 'bin' / 'AdGuardHome')
        mark_executable(base, full_dir / 'etc' / 'SmartDNS' / 'smartdns')
        mark_executable(base, full_dir / 'bin' / 'mihomo')

        (full_dir / 'scripts' / 'service.sh').write_text(BAD_SH, encoding='utf-8')
        c.check('service.sh 语法坏 -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        (full_dir / 'scripts' / 'service.sh').write_text(VALID_SERVICE_SH, encoding='utf-8')

        (full_dir / 'scripts' / 'manual.sh').write_text(BAD_SH, encoding='utf-8')
        c.check('manual.sh 语法坏 -> 拒绝', validate(base, defs, '', '', full_dir), 1)
        (full_dir / 'scripts' / 'manual.sh').write_text(VALID_MANUAL_SH, encoding='utf-8')

        c.check('恢复后 -> 再次通过', validate(base, defs, '', '', full_dir), 0)

        print('[3] clear_module_markers: 只删标记，不动其它文件')
        for marker in ('update', 'remove', 'disable', 'skip_mount'):
            (full_dir / marker).write_text('', encoding='utf-8')
        (full_dir / 'module.prop').write_text('id=SAM\n', encoding='utf-8')
        r = run_shell(base, defs + f'\nclear_module_markers {full_dir.as_posix()}\n')
        c.check('清理命令退出码', r.returncode, 0)
        c.check('四个标记全部删除',
                [m for m in ('update', 'remove', 'disable', 'skip_mount') if (full_dir / m).exists()], [])
        c.check('module.prop 保留', (full_dir / 'module.prop').is_file(), True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
