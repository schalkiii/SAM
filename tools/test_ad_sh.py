#!/usr/bin/env python3
"""ad.sh 回归测试

在临时目录里搭一套假的 App 数据目录，验证广告屏蔽的可逆语义：
  - 屏蔽后原位置是空目录/空文件，内容改名到了 <路径>.samhold
  - 恢复后内容原样还原，备份目录与清单都被清干净
  - 通配符路径正确展开，且不会误伤已有的备份目录
  - 排除列表里的路径不参与屏蔽
  - 连续屏蔽两次是幂等的
  - 旧版本遗留的「锁定空目录」能被正常清理

设备上 chattr 只支持 immutable(i) 属性，Windows 上的 Git Bash 也不支持，
所以这里用 stub 版的 lsattr/chattr：以 .locked 标记文件模拟 immutable。

用法:
    python tools/test_ad_sh.py            # 跑全部用例
    python tools/test_ad_sh.py -v         # 打印每个用例细节
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent

# 用例定义: (App 名, 相对路径, 类型)
#   dir  = 广告缓存目录
#   file = shared_prefs 之类的配置文件
#   glob = 含通配符的目录
CASES = [
    ('测试AppA', 'test/A/files/ad', 'dir'),
    ('测试AppA', 'test/A/files/ad_prefs.xml', 'file'),
    ('测试AppB', 'test/B/cache/splash', 'dir'),
    ('测试AppC', 'test/C/cache/res_*', 'glob'),
    ('测试AppD', 'test/D/files/ads', 'dir'),
]

# 模拟 exclude：真机上是 /data/system/ifw
EXCLUDE_CASE = 'test/D/files/ads'

STUB_LSATTR = r'''#!/bin/sh
# stub: 用 .locked 标记文件模拟 immutable 属性
for arg in "$@"; do
  case "$arg" in -*) continue;; esac
  path="$arg"
  lock1="$(dirname "$path")/.$(basename "$path").locked"
  lock2="$path/.locked"
  if [ -f "$lock1" ] || [ -f "$lock2" ]; then
    echo "----i------e-- $path"
  else
    echo "-------------- $path"
  fi
done
'''

STUB_CHATTR = r'''#!/bin/sh
# stub: 用 .locked 标记文件模拟 immutable
mode=""
path=""
for arg in "$@"; do
  case "$arg" in
    +i) mode="lock" ;;
    -i) mode="unlock" ;;
    -*) ;;
    *) path="$arg" ;;
  esac
done
[ -z "$path" ] && exit 0
if [ -d "$path" ]; then
  case "$mode" in
    lock) touch "$path/.locked" ;;
    unlock) rm -f "$path/.locked" ;;
  esac
else
  case "$mode" in
    lock) touch "$(dirname "$path")/.$(basename "$path").locked" ;;
    unlock) rm -f "$(dirname "$path")/.$(basename "$path").locked" ;;
  esac
fi
'''


def make_stubs(stub_dir):
    stub_dir.mkdir(parents=True, exist_ok=True)
    for name, body in (('lsattr', STUB_LSATTR), ('chattr', STUB_CHATTR)):
        p = stub_dir / name
        p.write_text(body, encoding='utf-8', newline='\n')
        p.chmod(0o755)


def build_env(base):
    """搭出可运行的 ad.sh 副本 + 测试数据"""
    mod = base / 'mod'
    (mod / 'scripts').mkdir(parents=True)
    (mod / 'tmp').mkdir(parents=True)

    test_root = base / 'data'
    for app, rel, kind in CASES:
        if kind == 'glob':
            parent = (test_root / rel).parent
            parent.mkdir(parents=True, exist_ok=True)
            for suffix in ('001', '002'):
                d = parent / rel.split('/')[-1].replace('*', suffix)
                d.mkdir(parents=True, exist_ok=True)
                (d / 'ad.jpg').write_text('glob-content', encoding='utf-8')
        else:
            full = test_root / rel
            if kind == 'dir':
                full.mkdir(parents=True, exist_ok=True)
                (full / 'ad.jpg').write_text('ad-content', encoding='utf-8')
                (full / 'ad2.jpg').write_text('ad-content-2', encoding='utf-8')
            else:
                full.parent.mkdir(parents=True, exist_ok=True)
                full.write_text('important-config', encoding='utf-8')

    for f in ('base.sh', 'setting.sh', 'config.sh', 'ad.sh'):
        shutil.copy(REPO / 'scripts' / f, mod / 'scripts' / f)

    mod_posix = mod.as_posix()
    base_posix = base.as_posix()

    p = mod / 'scripts' / 'base.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('MODULE_PATH="/data/adb/modules/SAM"', f'MODULE_PATH="{mod_posix}"')
    d = d.replace('source "/data/adb/modules/SAM/scripts/base.sh"', f'source "{mod_posix}/scripts/base.sh"')
    d = d.replace('source "${MODULE_PATH}/scripts/setting.sh"', f'source "{mod_posix}/scripts/setting.sh"')
    d = d.replace('load_setting "${MODULE_PATH}/setting.conf"', f'load_setting "{mod_posix}/setting.conf"')
    p.write_text(d, encoding='utf-8', newline='\n')

    p = mod / 'scripts' / 'config.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('MODULE_PATH="/data/adb/modules/SAM"', f'MODULE_PATH="{mod_posix}"')
    p.write_text(d, encoding='utf-8', newline='\n')

    lines = ['ad_path=(']
    for app, rel, kind in CASES:
        lines.append(f'# {app}')
        lines.append(f'"{(test_root / rel).as_posix()}"')
    lines.append(')')
    newarray = '\n'.join(lines) + '\n'

    p = mod / 'scripts' / 'ad.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('source "/data/adb/modules/SAM/scripts/base.sh"', f'source "{mod_posix}/scripts/base.sh"')
    d = d.replace('HOLD_LIST="${AD_HOLD_LIST}"', f'HOLD_LIST="{base_posix}/SAM-ad-hold.list"')
    d = d.replace('"/data/system/ifw"', f'"{(test_root / EXCLUDE_CASE).as_posix()}"')
    d = re.sub(r'ad_path=\(.*?\n\)\n', lambda m: newarray, d, count=1, flags=re.S)
    p.write_text(d, encoding='utf-8', newline='\n')

    return mod, test_root


def run_ad(mod, base, args, stub_dir):
    env = dict(os.environ)
    env['PATH'] = f'{stub_dir.as_posix()}{os.pathsep}{env.get("PATH", "")}'
    # 设备上是 mksh；Linux 的 sh 可能是 dash，不支持 ad.sh 里用到的 let
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    result = subprocess.run(
        [shell, (mod / 'scripts' / 'ad.sh').as_posix()] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        env=env, cwd=base.as_posix(),
    )
    return result


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_ad_test_'))
    try:
        stub_dir = base / 'stub'
        make_stubs(stub_dir)
        mod, test_root = build_env(base)
        c = Checker(args.verbose)

        print('[1] 屏蔽后: 内容改名保留, 原位置清空')
        run_ad(mod, base, ['block'], stub_dir)
        c.check('目录内容移到 .samhold',
                (test_root / 'test/A/files/ad.samhold/ad.jpg').read_text(encoding='utf-8'),
                'ad-content')
        c.check('配置文件内容移到 .samhold',
                (test_root / 'test/A/files/ad_prefs.xml.samhold').read_text(encoding='utf-8'),
                'important-config')
        c.check('原位置目录为空',
                [x for x in (test_root / 'test/A/files/ad').iterdir() if x.name != '.locked'],
                [])
        c.check('通配符展开 res_001', (test_root / 'test/C/cache/res_001.samhold').is_dir(), True)
        c.check('通配符展开 res_002', (test_root / 'test/C/cache/res_002.samhold').is_dir(), True)
        c.check('exclude 路径未动', (test_root / 'test/D/files/ads/ad.jpg').is_file(), True)
        c.check('exclude 路径未改名', (test_root / 'test/D/files/ads.samhold').exists(), False)
        manifest = base / 'SAM-ad-hold.list'
        c.check('清单不含 exclude 路径', 'files/ads' in manifest.read_text(encoding='utf-8'), False)

        print('[2] 连续屏蔽两次: 幂等')
        run_ad(mod, base, ['block'], stub_dir)
        c.check('清单条数不变', len(manifest.read_text(encoding='utf-8').strip().split('\n')), 5)
        c.check('没有 .samhold.samhold',
                list(test_root.rglob('*.samhold.samhold')), [])

        print('[3] 恢复: 内容原样还原, 备份与清单清干净')
        run_ad(mod, base, ['recovery'], stub_dir)
        c.check('目录内容还原',
                (test_root / 'test/A/files/ad/ad.jpg').read_text(encoding='utf-8'),
                'ad-content')
        c.check('配置文件内容还原',
                (test_root / 'test/A/files/ad_prefs.xml').read_text(encoding='utf-8'),
                'important-config')
        c.check('res_001 还原',
                (test_root / 'test/C/cache/res_001/ad.jpg').read_text(encoding='utf-8'),
                'glob-content')
        c.check('res_002 还原',
                (test_root / 'test/C/cache/res_002/ad.jpg').read_text(encoding='utf-8'),
                'glob-content')
        c.check('清单已清空', manifest.read_text(encoding='utf-8').strip(), '')
        c.check('没有残留 .samhold', list(test_root.rglob('*.samhold')), [])

        print('[4] 旧版本遗留的锁定空目录能被清理')
        legacy = test_root / 'test/B/cache/splash'
        shutil.rmtree(legacy)
        legacy.mkdir(parents=True)
        (legacy / '.locked').write_text('', encoding='utf-8')
        run_ad(mod, base, ['recovery'], stub_dir)
        c.check('旧空壳被清理', legacy.exists(), False)
        c.check('其它路径不受影响', (test_root / 'test/A/files/ad/ad.jpg').is_file(), True)

        print('[5] 屏蔽期间 App 又写入: 新内容不丢')
        run_ad(mod, base, ['block'], stub_dir)
        (test_root / 'test/A/files/ad/new.txt').write_text('app-new', encoding='utf-8')
        (test_root / 'test/A/files/ad_prefs.xml').write_text('app-new-pref', encoding='utf-8')
        run_ad(mod, base, ['recovery'], stub_dir)
        c.check('原数据回填',
                (test_root / 'test/A/files/ad/ad.jpg').read_text(encoding='utf-8'),
                'ad-content')
        c.check('新写内容存到 .samnew',
                (test_root / 'test/A/files/ad.samnew/new.txt').read_text(encoding='utf-8'),
                'app-new')
        c.check('文件原数据回填',
                (test_root / 'test/A/files/ad_prefs.xml').read_text(encoding='utf-8'),
                'important-config')
        c.check('文件新写内容存到 .samnew',
                (test_root / 'test/A/files/ad_prefs.xml.samnew').read_text(encoding='utf-8'),
                'app-new-pref')

        print('[6] 备份丢失(App 被卸载)时恢复不报错')
        run_ad(mod, base, ['block'], stub_dir)
        shutil.rmtree(test_root / 'test/A/files/ad.samhold', ignore_errors=True)
        result = run_ad(mod, base, ['recovery'], stub_dir)
        c.check('命令退出码为 0', result.returncode, 0)

        print('[7] list 输出格式')
        run_ad(mod, base, ['block'], stub_dir)
        result = run_ad(mod, base, ['list'], stub_dir)
        # stdout 前面会混入 base.sh 的提示行(如"未找到设置文件"), 只取表格行
        lines = [x for x in result.stdout.strip().split('\n')
                 if x.startswith('APP|') or x.count('|') == 3]
        c.check('表头正确', lines[0] if lines else '', 'APP|路径|状态|备份(KB)')
        c.check('每个条目 4 段', all(len(x.split('|')) == 4 for x in lines[1:]), True)
        c.check('有备份的标为已锁定(有备份)',
                any('已锁定(有备份)' in x for x in lines[1:]), True)

        print('[8] hold 输出占用总量')
        result = run_ad(mod, base, ['hold'], stub_dir)
        c.check('输出含合计行', '合计' in result.stdout, True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
