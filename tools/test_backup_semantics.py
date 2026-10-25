#!/usr/bin/env python3
"""backup.sh 备份语义回归测试

验证配置备份的完整性与可回退语义：
  - BACKUP_CONF=true 时 save 生成带 .complete 完成标记的备份，list 能列出
  - BACKUP_CONF=false 时 save 直接跳过，不产生目录
  - 没有 .complete 的半截备份: list 标注 (未完成)，restore 不会选中它
  - restore 先选目标再拍快照: 还原后模块文件回到旧版本，
    且刚拍的当前配置快照存在但不是恢复来源(不会把自己恢复成自己)
  - 模块目录外的 /data/adb/SAM-ad-hold.list 进 extra/ 并按原路径恢复
  - 轮转只数已完成备份，最多保留 5 份
  - save 失败(备份根目录不可建)时不写标记、不轮转
  - restore 前的安全快照不受 BACKUP_CONF=false 限制
  - restore 持配置锁覆盖文件写入期(与 WebUI set/cron set 互斥)，
    成功与失败路径都释放；文件写入为同目录临时文件 + mv 的原子替换，
    正常与失败路径都不留临时残留

用法:
    python tools/test_backup_semantics.py            # 跑全部用例
    python tools/test_backup_semantics.py -v         # 打印每个用例细节
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent

MODULE_FILES = [
    'setting.conf',
    'etc/AdGuardHome/AdGuardHome.yaml',
    'etc/SmartDNS/smartdns.conf',
    'etc/mihomo/config.yaml',
    'etc/app_blacklist.prop',
    'etc/app_whitelist.prop',
    'etc/hosts',
    'etc/crontabs/root',
]
MODULE_DIRS = [
    'etc/AdGuardHome/data',
    'etc/SmartDNS/data',
    'etc/mihomo/proxy_provider',
    'etc/mihomo/rule_provider',
]


def build_env(base, backup_conf='true'):
    """搭出可运行的 backup.sh 副本(路径全部指向临时目录)"""
    mod = base / 'mod'
    (mod / 'scripts').mkdir(parents=True)
    (mod / 'tmp').mkdir(parents=True)

    for f in MODULE_FILES:
        full = mod / f
        full.parent.mkdir(parents=True, exist_ok=True)
        full.write_text(f'v1-{f}\n', encoding='utf-8', newline='\n')
    for d in MODULE_DIRS:
        (mod / d).mkdir(parents=True, exist_ok=True)
        (mod / d / 'keep.bin').write_text(f'v1-{d}\n', encoding='utf-8', newline='\n')

    (mod / 'setting.conf').write_text(
        f'SMARTDNS_ENABLE=true\nBACKUP_CONF={backup_conf}\n', encoding='utf-8', newline='\n')

    for f in ('base.sh', 'config.sh', 'setting.sh', 'backup.sh'):
        shutil.copy(REPO / 'scripts' / f, mod / 'scripts' / f)

    mod_posix = mod.as_posix()
    base_posix = base.as_posix()

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

    p = mod / 'scripts' / 'backup.sh'
    d = p.read_text(encoding='utf-8')
    d = d.replace('source "/data/adb/modules/SAM/scripts/base.sh"', f'source "{mod_posix}/scripts/base.sh"')
    d = d.replace('BACKUP_ROOT="/data/adb/SAM-backup"', f'BACKUP_ROOT="{base_posix}/SAM-backup"')
    d = d.replace('BACKUP_EXTRA_FILES="/data/adb/SAM-ad-hold.list"',
                  f'BACKUP_EXTRA_FILES="{base_posix}/SAM-ad-hold.list"')
    p.write_text(d, encoding='utf-8', newline='\n')

    return mod


def run_backup(mod, base, args):
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run(
        [shell, (mod / 'scripts' / 'backup.sh').as_posix()] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
    )


def stub_lock(mod):
    """在 base.sh 副本末尾追加记录型锁 stub

    shell 里后定义的函数覆盖先定义的，追加在末尾即可透明替换真实实现。
    记录 acquire/release 调用序列到 ${TMP_PATH}/lock.calls。
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


def leftover_temps(root):
    """收集原子替换可能遗留的临时文件(模块内与备份根目录外都要查)"""
    return sorted(p.name for p in root.rglob('*.restore.*'))


def force_remove(path):
    """删掉路径上的 whatever: rmtree 对文件会抛 NotADirectoryError"""
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink(missing_ok=True)


def completed_dirs(base):
    root = base / 'SAM-backup'
    if not root.is_dir():
        return []
    return sorted(d.name for d in root.iterdir()
                  if d.is_dir() and (d / '.complete').exists())


def all_dirs(base):
    root = base / 'SAM-backup'
    if not root.is_dir():
        return []
    return sorted(d.name for d in root.iterdir() if d.is_dir())


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_backup_test_'))
    try:
        c = Checker(verbose=args.verbose)
        mod = build_env(base)
        hold_list = base / 'SAM-ad-hold.list'

        # ---- 用例1: 正常 save ----
        hold_list.write_text('/data/data/com.test/files/ad\n', encoding='utf-8', newline='\n')
        r = run_backup(mod, base, ['save'])
        c.check('save 退出码', r.returncode, 0)
        c.check('save 后有一份完整备份', len(completed_dirs(base)), 1)
        first_backup = completed_dirs(base)[0]
        c.check('备份含完成标记', (base / 'SAM-backup' / first_backup / '.complete').exists(), True)
        c.check('备份含 setting.conf',
                (base / 'SAM-backup' / first_backup / 'setting.conf').read_text(encoding='utf-8'),
                'SMARTDNS_ENABLE=true\nBACKUP_CONF=true\n')
        c.check('extra 清单已备份',
                (base / 'SAM-backup' / first_backup / 'extra' / 'SAM-ad-hold.list').exists(), True)
        r = run_backup(mod, base, ['list'])
        c.check('list 显示该备份', first_backup in r.stdout, True)

        # ---- 用例2: BACKUP_CONF=false 不备份 ----
        mod_off = build_env(base / 'off', backup_conf='false')
        r = run_backup(mod_off, base / 'off', ['save'])
        c.check('关闭备份时退出码', r.returncode, 0)
        c.check('关闭备份时无目录', all_dirs(base / 'off'), [])
        c.check('关闭备份时有提示', '已关闭卸载备份' in r.stdout, True)

        # ---- 用例3: 半截备份不参与 restore; list 的未完成展示契约 ----
        stale = base / 'SAM-backup' / '20990101-000000.99999'
        stale.mkdir(parents=True)
        (stale / 'setting.conf').write_text('半截备份\n', encoding='utf-8', newline='\n')
        r = run_backup(mod, base, ['restore'])
        c.check('restore 跳过半截备份选完整备份', first_backup in r.stdout, True)
        c.check('restore 不选半截备份', '20990101-000000.99999' in r.stdout, False)
        r = run_backup(mod, base, ['list'])
        c.check('有完整备份时只列完整', first_backup in r.stdout, True)
        c.check('有完整备份时不列半截', '20990101' in r.stdout, False)
        # 无完整备份时, list 把未完成的列出来供排查
        only_stale = base / 'only_stale'
        mod_stale = build_env(only_stale)
        run_backup(mod_stale, only_stale, ['save'])  # BACKUP_CONF=true 会生成完整备份, 先删掉标记
        for d in (only_stale / 'SAM-backup').iterdir():
            if d.is_dir():
                (d / '.complete').unlink()
        r = run_backup(mod_stale, only_stale, ['list'])
        c.check('无完整备份时列出未完成', '(未完成)' in r.stdout, True)
        r = run_backup(mod_stale, only_stale, ['restore'])
        c.check('无完整备份时 restore 拒绝', r.returncode, 1)
        c.check('无完整备份时 restore 提示', '暂无备份可恢复' in r.stdout, True)

        # ---- 用例4: restore 先选目标再拍快照 ----
        # 用例3 的 restore 已拍下一份 v1 快照(snapshot3)，它是当前最新的完整备份。
        # 本轮把模块文件改成 v2 后再 restore: 来源必须是 snapshot3(选目标在先)，
        # 而不是本轮刚拍的 v2 快照——否则说明顺序被颠倒，还原会把自己恢复成自己。
        snapshot3 = completed_dirs(base)[-1]
        c.check('用例3 restore 后产生 v1 快照', snapshot3 != first_backup, True)
        time.sleep(1.1)  # 让新快照时间戳晚于 snapshot3，保证排序确定
        for f in MODULE_FILES:
            (mod / f).write_text(f'v2-{f}\n', encoding='utf-8', newline='\n')
        r = run_backup(mod, base, ['restore'])
        c.check('restore 退出码', r.returncode, 0)
        c.check('restore 来源是选目标时的最新完整备份', snapshot3 in r.stdout, True)
        c.check('restore 后模块文件回到 v1',
                (mod / 'etc' / 'SmartDNS' / 'smartdns.conf').read_text(encoding='utf-8'),
                'v1-etc/SmartDNS/smartdns.conf\n')
        c.check('restore 后数据目录回到 v1',
                (mod / 'etc' / 'SmartDNS' / 'data' / 'keep.bin').read_text(encoding='utf-8'),
                'v1-etc/SmartDNS/data\n')
        c.check('restore 后 extra 清单写回原路径',
                hold_list.read_text(encoding='utf-8'),
                '/data/data/com.test/files/ad\n')
        snapshot = completed_dirs(base)[-1]
        c.check('本轮快照是最新完整备份', snapshot != snapshot3, True)
        c.check('本轮快照内容是 v2',
                (base / 'SAM-backup' / snapshot / 'etc' / 'SmartDNS' / 'smartdns.conf')
                .read_text(encoding='utf-8'),
                'v2-etc/SmartDNS/smartdns.conf\n')

        # ---- 用例5: 轮转只保留 5 份完整备份 ----
        for i in range(6):
            run_backup(mod, base, ['save'])
            time.sleep(0.05)
        c.check('轮转后完整备份数', len(completed_dirs(base)), 5)
        c.check('半截备份不被轮转删掉', stale.is_dir(), True)

        # ---- 用例6: save 失败不写标记不轮转 ----
        root = base / 'SAM-backup'
        shutil.move(str(root), str(base / 'SAM-backup.bak'))
        (root).write_text('not a directory\n', encoding='utf-8')
        before = completed_dirs(base)
        r = run_backup(mod, base, ['save'])
        c.check('备份根目录异常时 save 失败', r.returncode, 1)
        c.check('失败时不写新完整备份', completed_dirs(base), before)
        root.unlink()
        shutil.move(str(base / 'SAM-backup.bak'), str(root))

        # ---- 用例7: restore 前快照不受 BACKUP_CONF=false 限制 ----
        mod_off2 = build_env(base / 'off2', backup_conf='false')
        run_backup(mod_off2, base / 'off2', ['save'])  # 开关关闭, 无备份
        # 手工造一份完整备份, 让 restore 有目标
        fake = base / 'off2' / 'SAM-backup' / '20260101-000000.1'
        fake.mkdir(parents=True)
        (fake / '.complete').write_text('x\n', encoding='utf-8')
        (fake / 'etc').mkdir(parents=True)
        (fake / 'etc' / 'hosts').write_text('restored-hosts\n', encoding='utf-8', newline='\n')
        r = run_backup(mod_off2, base / 'off2', ['restore'])
        c.check('关闭备份时 restore 仍可用', r.returncode, 0)
        c.check('restore 内容正确',
                (mod_off2 / 'etc' / 'hosts').read_text(encoding='utf-8'), 'restored-hosts\n')
        c.check('restore 前仍自动拍快照', len(completed_dirs(base / 'off2')), 2)

        # ---- 用例8: restore 持配置锁 + 文件原子替换 ----
        off2 = base / 'off2'
        lock_dir = mod_off2 / 'tmp' / '.setting.lock'

        # 8a 真实锁: 正常结束后锁目录不得残留(漏 release 会堵死后续 WebUI 写操作)，
        # 且原子替换的临时文件全部清零
        r = run_backup(mod_off2, off2, ['restore'])
        c.check('restore 退出码(锁用例)', r.returncode, 0)
        c.check('restore 后锁目录不残留', lock_dir.exists(), False)
        c.check('restore 后模块内无临时残留', leftover_temps(mod_off2), [])
        c.check('restore 后 extra 无临时残留', leftover_temps(off2), [])

        # 8b 记录型 stub: 验证 acquire/release 调用序列(锁的接线)
        stub_lock(mod_off2)
        clear_lock_calls(mod_off2)
        r = run_backup(mod_off2, off2, ['restore'])
        c.check('restore 取锁并释放', lock_calls(mod_off2),
                ['acquire:setting', 'release:setting'])
        c.check('restore 后仍无临时残留', leftover_temps(mod_off2), [])

        # 8c 写入失败也放锁: 把 etc/crontabs 占成文件，mkdir -p 与 cp 双双失败
        # (不能把目标本身占成目录: POSIX mv 对目录目标是"移入"而非报错)——
        # 漏放锁的话后续 WebUI 保存全被堵到 30 秒超时
        force_remove(mod_off2 / 'etc' / 'crontabs')
        (mod_off2 / 'etc' / 'crontabs').write_text('not a dir\n', encoding='utf-8')
        clear_lock_calls(mod_off2)
        r = run_backup(mod_off2, off2, ['restore'])
        c.check('restore 失败退出码', r.returncode, 1)
        c.check('restore 失败提示', '未完整完成' in r.stdout, True)
        c.check('restore 失败路径也释放锁', lock_calls(mod_off2),
                ['acquire:setting', 'release:setting'])
        c.check('restore 失败后无临时残留', leftover_temps(mod_off2), [])

        # 8d mv 守卫: 目标被占成目录时 mv 按 POSIX 把临时文件"移入"目录并返回
        # 成功，-f 守卫必须把这种假成功判失败(临时文件会被移进目录，故不查残留)
        force_remove(mod_off2 / 'etc' / 'crontabs')
        (mod_off2 / 'etc' / 'crontabs').mkdir()
        (mod_off2 / 'etc' / 'crontabs' / 'root').write_text(
            'current-cron\n', encoding='utf-8', newline='\n')
        force_remove(mod_off2 / 'etc' / 'hosts')
        (mod_off2 / 'etc' / 'hosts').mkdir()
        clear_lock_calls(mod_off2)
        r = run_backup(mod_off2, off2, ['restore'])
        c.check('mv 守卫: 目标为目录判失败', r.returncode, 1)
        c.check('mv 守卫: 失败路径释放锁', lock_calls(mod_off2),
                ['acquire:setting', 'release:setting'])

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
