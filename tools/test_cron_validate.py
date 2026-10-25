#!/usr/bin/env python3
"""setting_api.sh cron 读写回归测试

验证 WebUI「定时任务」卡片背后的 cron get / cron set 接口：
  - 合法行(标准五字段、范围/步长/列表、@shortcut、注释、空行)被接受
  - 非法行(字段不足、时间字段含 shell 字符、命令伪装成时间字段)被拒绝
  - 批量中有一行非法时整批拒绝，且不碰原文件(原子性)
  - 不带任何行调用 set = 清空全部定时任务
  - 文件不存在时 get 输出占位提示
  - 配置锁: cron set 与 set/setarr/apply 同一互斥语义(成功/失败路径都取锁并释放、
    陈旧锁自动恢复、get 读路径不取锁)

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
    # 锁等待超时从 30s 压到 2s: 超时值不是被测行为(锁的接线才是)，
    # 否则「持锁拒绝」用例要白等 30 秒
    d = d.replace('sam_lock_acquire "setting" 30', 'sam_lock_acquire "setting" 2')
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


def stub_lock(mod):
    """在 base.sh 副本末尾追加记录型锁 stub

    shell 里后定义的函数覆盖先定义的，所以追加在末尾即可透明替换真实实现，
    不用动 base.sh 原有代码。记录 acquire/release 的调用序列到
    ${TMP_PATH}/lock.calls，用来验证 setting_api.sh 的锁接线。
    """
    p = mod / 'scripts' / 'base.sh'
    with p.open('a', encoding='utf-8') as f:
        f.write(
            '\n# 测试 stub: 记录锁调用序列，覆盖上面的真实实现\n'
            'sam_lock_acquire(){ printf "acquire:%s\\n" "${1}" >> "${TMP_PATH}/lock.calls"; return 0; }\n'
            'sam_lock_release(){ printf "release:%s\\n" "${1}" >> "${TMP_PATH}/lock.calls"; return 0; }\n'
        )


def lock_calls(mod):
    calls_file = mod / 'tmp' / 'lock.calls'
    if not calls_file.exists():
        return []
    return calls_file.read_text(encoding='utf-8').splitlines()


def clear_lock_calls(mod):
    (mod / 'tmp' / 'lock.calls').unlink(missing_ok=True)


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

        # ---- 配置锁: cron set 与 set/setarr/apply 同一互斥语义 ----
        lock_dir = mod / 'tmp' / '.setting.lock'

        # 成功路径: 写完后锁必须释放，否则后续 WebUI 写操作全部堵死
        r = run_api(mod, base, ['cron', 'set', '0 7 * * * /bin/echo seven'])
        c.check('cron set 成功退出码', r.returncode, 0)
        c.check('cron set 成功后释放锁', lock_dir.exists(), False)
        c.check('cron set 写入内容', cron_file.read_text(encoding='utf-8'),
                '0 7 * * * /bin/echo seven\n')

        # 陈旧锁(持锁进程已死): 按 sam_lock_acquire 既有语义自动清理后成功
        lock_dir.mkdir()
        (lock_dir / 'pid').write_text('999999999\n', encoding='utf-8')
        r = run_api(mod, base, ['cron', 'set', '0 9 * * * /bin/echo nine'])
        c.check('陈旧锁自动恢复后成功', r.returncode, 0)
        c.check('陈旧锁恢复后释放', lock_dir.exists(), False)

        # ---- 锁接线: 记录型 stub 覆盖真实锁实现，验证取锁/放锁调用序列 ----
        # 真实锁的阻塞竞争由 base.sh 的 sam_lock_acquire 负责(set/setarr/apply
        # 早已依赖)，且依赖 kill -0 的跨进程 PID 可见性——本机 PortableGit 的
        # sh.EXE 连 kill -0 1 都看不到(实测 No such process)，无法在本机稳定
        # 复现「活进程持锁」；真机 mksh 与 CI dash 均正常。
        # 这里锁定 setting_api.sh 自己负责的部分: 哪个子命令取锁、是否都放了锁。
        stub_lock(mod)

        clear_lock_calls(mod)
        r = run_api(mod, base, ['cron', 'set', '0 10 * * * /bin/echo ten'])
        c.check('cron set 取锁并释放', lock_calls(mod),
                ['acquire:setting', 'release:setting'])

        # 失败路径(整批拒绝)也必须放锁: 少一次 release，后续写操作堵死 30 秒
        clear_lock_calls(mod)
        r = run_api(mod, base, ['cron', 'set', '0 11 * * * /bin/echo eleven', '坏行'])
        c.check('cron set 失败退出码', r.returncode != 0, True)
        c.check('cron set 失败路径释放锁', lock_calls(mod),
                ['acquire:setting', 'release:setting'])
        c.check('cron set 失败不碰原文件', cron_file.read_text(encoding='utf-8'),
                '0 10 * * * /bin/echo ten\n')

        # get 是读路径，不应取锁
        clear_lock_calls(mod)
        r = run_api(mod, base, ['cron', 'get'])
        c.check('cron get 不取锁', lock_calls(mod), [])

        # ---- TTL 边界: 写入校验与 setting.sh 加载期校验同源 ----
        # 范围常量在 setting.sh 的 SMARTDNS_TTL_FLOOR/CEIL，这里锁定两端行为，
        # 防止出现"保存时放行、加载时被回退"的矛盾
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=5'])
        c.check('TTL 低于下限被拒', r.returncode != 0, True)
        c.check('TTL 拒绝提示含取值非法', '取值非法' in (r.stderr + r.stdout), True)
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=100000'])
        c.check('TTL 超上限被拒', r.returncode != 0, True)
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=300'])
        c.check('TTL 合法值接受', r.returncode, 0)
        c.check('TTL 合法值已写入',
                'SMARTDNS_TTL_MIN=300' in (mod / 'setting.conf').read_text(encoding='utf-8'), True)

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
