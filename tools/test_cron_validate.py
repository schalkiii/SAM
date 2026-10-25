#!/usr/bin/env python3
"""setting_api.sh cron 读写回归测试

验证 WebUI「定时任务」卡片背后的 cron get / cron set 接口：
  - 合法行(标准五字段、范围/步长/列表、@shortcut、注释、空行)被接受
  - 非法行(字段不足、时间字段含 shell 字符、命令伪装成时间字段)被拒绝
  - 批量中有一行非法时整批拒绝，且不碰原文件(原子性)
  - 不带任何行调用 set = 清空全部定时任务
  - 文件不存在时 get 输出占位提示

用法:
    python tools/test_cron_validate.py            # 跑全部用例
    python tools/test_cron_validate.py -v         # 打印每个用例细节
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent


def build_env(base):
    """搭出可运行的 setting_api.sh 副本(路径全部指向临时目录)"""
    mod = base / 'mod'
    (mod / 'scripts').mkdir(parents=True)
    (mod / 'tmp').mkdir(parents=True)

    for f in ('base.sh', 'config.sh', 'setting.sh', 'setting_api.sh'):
        shutil.copy(REPO / 'scripts' / f, mod / 'scripts' / f)

    mod_posix = mod.as_posix()

    p = mod / 'scripts' / 'base.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('MODULE_PATH="/data/adb/modules/SAM"', f'MODULE_PATH="{mod_posix}"')
    d = d.replace('source "${MODULE_PATH}/scripts/config.sh"', f'source "{mod_posix}/scripts/config.sh"')
    d = d.replace('source "${MODULE_PATH}/scripts/setting.sh"', f'source "{mod_posix}/scripts/setting.sh"')
    d = d.replace('load_setting "${MODULE_PATH}/setting.conf"', f'load_setting "{mod_posix}/setting.conf"')
    p.write_text(d, encoding='utf-8', newline='\n')

    p = mod / 'scripts' / 'config.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('MODULE_PATH="/data/adb/modules/SAM"', f'MODULE_PATH="{mod_posix}"')
    p.write_text(d, encoding='utf-8', newline='\n')

    p = mod / 'scripts' / 'setting_api.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('source "/data/adb/modules/SAM/scripts/base.sh"', f'source "{mod_posix}/scripts/base.sh"')
    p.write_text(d, encoding='utf-8', newline='\n')

    # 最小 setting.conf: cron 路径不依赖具体设置项，但 load_setting 需要文件存在
    (mod / 'setting.conf').write_text('SMARTDNS_ENABLE=true\nBACKUP_CONF=true\n', encoding='utf-8', newline='\n')

    return mod


def run_api(mod, base, args):
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run(
        [shell, (mod / 'scripts' / 'setting_api.sh').as_posix()] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_cron_test_'))
    try:
        mod = build_env(base)
        cron_file = mod / 'etc' / 'crontabs' / 'root'
        c = Checker(verbose=args.verbose)

        # ---- 合法行 ----
        legal_lines = [
            '0 4 * * * /data/adb/modules/SAM/scripts/update.sh',
            '*/5 1-5 * * 1,3 /bin/echo weekday',
            '0 0 1 */2 * /bin/echo bimonthly',
            '@daily /data/adb/modules/SAM/scripts/backup.sh save',
            '# 注释行原样保留',
            '',
        ]
        r = run_api(mod, base, ['cron', 'set'] + legal_lines)
        c.check('合法批次保存退出码', r.returncode, 0)
        c.check('合法批次写入文件', cron_file.read_text(encoding='utf-8'),
                '\n'.join(legal_lines) + '\n')
        c.check('保存输出计数', '已保存 4 条定时任务' in r.stdout, True)

        # ---- get 往返 ----
        r = run_api(mod, base, ['cron', 'get'])
        c.check('get 往返一致', r.stdout, '\n'.join(legal_lines) + '\n')

        # ---- 单行非法: 字段不足 ----
        r = run_api(mod, base, ['cron', 'set', '0 4 * * *'])
        c.check('NF<6 拒绝退出码', r.returncode != 0, True)
        c.check('NF<6 拒绝提示', '格式非法' in (r.stderr + r.stdout), True)
        c.check('NF<6 不碰原文件', cron_file.read_text(encoding='utf-8'),
                '\n'.join(legal_lines) + '\n')

        # ---- 单行非法: 时间字段含 shell 元字符 ----
        r = run_api(mod, base, ['cron', 'set', '0;rm -rf 4 * * * /bin/echo x'])
        c.check('时间字段含分号拒绝', r.returncode != 0, True)

        # ---- 单行非法: 字母混进时间字段 ----
        r = run_api(mod, base, ['cron', 'set', 'a b c d e /bin/echo x'])
        c.check('字母时间字段拒绝', r.returncode != 0, True)

        # ---- 单行非法: @shortcut 不带命令 ----
        r = run_api(mod, base, ['cron', 'set', '@reboot'])
        c.check('裸 @reboot 拒绝', r.returncode != 0, True)

        # ---- 批量原子性: 一行坏整批拒 ----
        r = run_api(mod, base, ['cron', 'set',
                                '0 5 * * * /bin/echo ok',
                                'not a cron line at all'])
        c.check('批量含非法行拒绝', r.returncode != 0, True)
        c.check('批量拒绝后原文件不变', cron_file.read_text(encoding='utf-8'),
                '\n'.join(legal_lines) + '\n')

        # ---- 清空 ----
        r = run_api(mod, base, ['cron', 'set'])
        c.check('清空退出码', r.returncode, 0)
        c.check('清空后文件为空', cron_file.read_text(encoding='utf-8'), '')
        c.check('清空输出 0 条', '已保存 0 条定时任务' in r.stdout, True)

        # ---- 空行参数被接受(crond 忽略空行) ----
        r = run_api(mod, base, ['cron', 'set', '0 6 * * * /bin/echo six', ''])
        c.check('空行参数被接受', r.returncode, 0)
        c.check('空行原样写入', cron_file.read_text(encoding='utf-8'),
                '0 6 * * * /bin/echo six\n\n')

        # ---- 文件不存在时 get ----
        cron_file.unlink()
        r = run_api(mod, base, ['cron', 'get'])
        c.check('无文件时 get 占位', r.stdout.strip(), '(暂无定时任务)')

        # ---- 用法错误 ----
        r = run_api(mod, base, ['cron'])
        c.check('cron 无子命令报用法', r.returncode != 0, True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
