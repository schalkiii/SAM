#!/usr/bin/env python3
"""update.sh safe_tar_extract 安全校验回归测试

从 scripts/update.sh 中抽取真实的 safe_tar_extract 函数(不复制实现)，
在临时目录里构造各类归档，验证：
  - 正常嵌套归档能解压且内容正确
  - 含符号链接 / 硬链接成员的归档被拒绝
  - 成员名含 ../ 穿越或绝对路径的归档被拒绝
  - 成员数超过 20000 或体积超过 1GiB 的归档被拒绝
  - 非 tar 垃圾内容被拒绝
  - 被拒绝时目标目录不落盘任何成员

用法:
    python tools/test_tar_guard.py            # 跑全部用例
    python tools/test_tar_guard.py -v         # 打印每个用例细节
"""

import argparse
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# 与 update.sh safe_tar_extract 保持一致的上限
MAX_MEMBERS = 20000
MAX_TOTAL_BYTES = 1073741824

DRIVER_HEADER = '''#!/bin/sh
TMP_PATH="{tmp}"
log(){{ echo "LOG: $*"; }}
'''

DRIVER_FOOTER = '''
safe_tar_extract "$1" "$2"
'''


def extract_function(script_path, func_name):
    """从脚本中原样抽取函数体(测试真实实现，改动/重命名会立刻失败)"""
    text = script_path.read_text(encoding='utf-8')
    lines = text.splitlines()
    start = None
    for i, line in enumerate(lines):
        if line.startswith(f'{func_name}(){{'):
            start = i
            break
    if start is None:
        raise SystemExit(f'在 {script_path} 中找不到 {func_name}(){{')
    end = None
    for j in range(start + 1, len(lines)):
        if lines[j] == '}':
            end = j
            break
    if end is None:
        raise SystemExit(f'{func_name} 函数体没有闭合')
    return '\n'.join(lines[start:end + 1]) + '\n'


def build_driver(base):
    func_src = extract_function(REPO / 'scripts' / 'update.sh', 'safe_tar_extract')
    driver = base / 'driver.sh'
    driver.write_text(
        DRIVER_HEADER.format(tmp=base.as_posix()) + func_src + DRIVER_FOOTER,
        encoding='utf-8', newline='\n')
    driver.chmod(0o755)
    return driver


def run_extract(driver, base, tar_path):
    out_dir = base / 'out'
    shutil.rmtree(out_dir, ignore_errors=True)
    out_dir.mkdir(parents=True)
    # 用相对路径调用: Windows 上 tar 会把 "C:/..." 当成 host:path 远程规格，
    # 只有 MSYS bash 才会做路径转换，Python 直接 spawn 的 sh 不会
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run(
        [shell, driver.name, tar_path.name, 'out'],
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
    ), out_dir


def write_tar(base, name, builder):
    path = base / name
    with tarfile.open(path, 'w:gz') as tf:
        builder(tf)
    return path


def add_normal(tf):
    data = b'hello-sam'
    for member in ('pkg/bin/tool', 'pkg/etc/tool.conf', 'pkg/README'):
        ti = tarfile.TarInfo(member)
        ti.size = len(data)
        tf.addfile(ti, io.BytesIO(data))


def add_symlink(tf):
    ti = tarfile.TarInfo('pkg/evil-link')
    ti.type = tarfile.SYMTYPE
    ti.linkname = '/data/adb/modules/SAM/scripts/base.sh'
    tf.addfile(ti)


def add_hardlink(tf):
    ti = tarfile.TarInfo('pkg/evil-hard')
    ti.type = tarfile.LNKTYPE
    ti.linkname = 'pkg/bin/tool'
    tf.addfile(ti)


def add_dotdot(tf):
    data = b'escape'
    ti = tarfile.TarInfo('../escape.txt')
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))


def add_absolute(tf):
    data = b'abs'
    ti = tarfile.TarInfo('/tmp/sam_absolute_evil')
    ti.size = len(data)
    tf.addfile(ti, io.BytesIO(data))


def add_too_many(tf):
    data = b'x'
    for i in range(MAX_MEMBERS + 1):
        ti = tarfile.TarInfo(f'pkg/f{i}')
        ti.size = 1
        tf.addfile(ti, io.BytesIO(data))


class _ZeroStream(io.RawIOBase):
    """只读零流: 按需产出任意长度全零数据，不在内存/磁盘落地"""

    def __init__(self, size):
        self.remaining = size

    def readable(self):
        return True

    def readinto(self, b):
        chunk = min(len(b), self.remaining, 1 << 20)
        if chunk <= 0:
            return 0
        b[:chunk] = b'\0' * chunk
        self.remaining -= chunk
        return chunk


def add_too_big(tf):
    # 稀疏大成员: 逻辑体积超上限，压缩后归档仍然很小
    ti = tarfile.TarInfo('pkg/huge.bin')
    ti.size = MAX_TOTAL_BYTES + 1
    tf.addfile(ti, io.BufferedReader(_ZeroStream(ti.size)))


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_tar_test_'))
    try:
        driver = build_driver(base)
        c = Checker(verbose=args.verbose)

        # 正常归档
        tar_ok = write_tar(base, 'ok.tar.gz', add_normal)
        r, out = run_extract(driver, base, tar_ok)
        c.check('正常归档退出码', r.returncode, 0)
        c.check('正常归档内容', (out / 'pkg' / 'bin' / 'tool').read_bytes(), b'hello-sam')

        # 符号链接
        tar_sym = write_tar(base, 'symlink.tar.gz', add_symlink)
        r, out = run_extract(driver, base, tar_sym)
        c.check('符号链接拒绝', r.returncode, 1)
        c.check('符号链接拒绝原因', '链接成员' in (r.stdout + r.stderr), True)
        c.check('符号链接不落盘', list(out.rglob('*')), [])

        # 硬链接
        tar_hard = write_tar(base, 'hardlink.tar.gz', add_hardlink)
        r, out = run_extract(driver, base, tar_hard)
        c.check('硬链接拒绝', r.returncode, 1)
        c.check('硬链接不落盘', list(out.rglob('*')), [])

        # ../ 穿越
        tar_dotdot = write_tar(base, 'dotdot.tar.gz', add_dotdot)
        r, out = run_extract(driver, base, tar_dotdot)
        c.check('.. 穿越拒绝', r.returncode, 1)
        c.check('.. 穿越拒绝原因', '穿越' in (r.stdout + r.stderr), True)
        c.check('.. 穿越不落盘', list(out.rglob('*')), [])
        c.check('.. 穿越不逃出目录', (base / 'escape.txt').exists(), False)

        # 绝对路径
        tar_abs = write_tar(base, 'abs.tar.gz', add_absolute)
        r, out = run_extract(driver, base, tar_abs)
        c.check('绝对路径拒绝', r.returncode, 1)
        c.check('绝对路径拒绝原因', '绝对路径' in (r.stdout + r.stderr), True)

        # 成员数超限
        tar_many = write_tar(base, 'many.tar.gz', add_too_many)
        r, out = run_extract(driver, base, tar_many)
        c.check('成员数超限拒绝', r.returncode, 1)
        c.check('成员数超限原因', '超限' in (r.stdout + r.stderr), True)

        # 体积超限
        tar_big = write_tar(base, 'big.tar.gz', add_too_big)
        r, out = run_extract(driver, base, tar_big)
        c.check('体积超限拒绝', r.returncode, 1)
        c.check('体积超限原因', '超限' in (r.stdout + r.stderr), True)

        # 垃圾内容
        junk = base / 'junk.tar.gz'
        junk.write_bytes(b'this is not a tar archive at all')
        r, out = run_extract(driver, base, junk)
        c.check('垃圾内容拒绝', r.returncode, 1)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
