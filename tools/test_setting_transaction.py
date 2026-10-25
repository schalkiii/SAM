#!/usr/bin/env python3
"""setting_api.sh set / setarr 事务语义回归测试

WebUI 的「保存并应用」先调 `set`(全部标量)再逐项 `setarr`(数组)，
服务端各自是一个独立事务。本测试锁定这些契约:
  - 单键合法值正确写入，注释与顺序保持不变
  - 批量中任一键非法时整批拒绝，原文件一个字节都不动(原子性)
  - 端口冲突按同一批的最终候选值校验: 同批写相同端口 / 写 3721 被拒，
    单独改一个端口则放行
  - 值未变化时不重写文件(避免 mtime 抖动触发守护循环重载)
  - setarr 写入/去重/非法字符拒绝，失败不动原文件
  - get 下发 TTL 校验边界(SMARTDNS_TTL_FLOOR/CEIL)，且边界键只读不可写
  - 未知键被拒绝

用法:
    python tools/test_setting_transaction.py            # 跑全部用例
    python tools/test_setting_transaction.py -v         # 打印每个用例细节
"""

import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent


def build_env(base):
    """搭出可运行的 setting_api.sh 副本(路径指向临时目录)"""
    mod = base / 'mod'
    (mod / 'scripts').mkdir(parents=True)
    (mod / 'tmp').mkdir(parents=True)

    for name in ('base.sh', 'config.sh', 'setting.sh', 'setting_api.sh'):
        shutil.copy(REPO / 'scripts' / name, mod / 'scripts' / name)

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
    d = d.replace('source "/data/adb/modules/SAM/scripts/base.sh"',
                  f'source "{mod_posix}/scripts/base.sh"')
    # 锁等待压到 2 秒: 本套件不测锁竞争，别为等锁白等 30 秒
    d = d.replace('sam_lock_acquire "setting" 30', 'sam_lock_acquire "setting" 2')
    p.write_text(d, encoding='utf-8', newline='\n')

    # 用仓库真实 setting.conf: 注释、键顺序与设备上一致，才能验证"只改目标行"
    shutil.copy(REPO / 'setting.conf', mod / 'setting.conf')
    return mod


def run_api(mod, base, args):
    shell = shutil.which('mksh') or shutil.which('sh') or 'sh'
    return subprocess.run(
        [shell, (mod / 'scripts' / 'setting_api.sh').as_posix()] + args,
        capture_output=True, text=True, encoding='utf-8', errors='replace',
        cwd=base.as_posix(),
    )


def read_conf(mod):
    return (mod / 'setting.conf').read_text(encoding='utf-8')


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

    base = pathlib.Path(tempfile.mkdtemp(prefix='sam_setting_test_'))
    try:
        mod = build_env(base)
        c = Checker(verbose=args.verbose)
        original = read_conf(mod)

        print('[1] 单键合法写入，注释与顺序不变')
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=3600'])
        conf = read_conf(mod)
        c.check('TTL 写入退出码', r.returncode, 0)
        c.check('TTL 行已替换', 'SMARTDNS_TTL_MIN=3600' in conf, True)
        c.check('旧 TTL 行不存在', 'SMARTDNS_TTL_MIN=600' in conf, False)
        c.check('注释行数量不变',
                conf.count('# '), original.count('# '))
        c.check('其它键保持原值', 'AGH_DNS_PORT=5300' in conf, True)

        print('[2] 未知键拒绝且不改文件')
        before = read_conf(mod)
        r = run_api(mod, base, ['set', 'NOT_A_KEY=1'])
        c.check('未知键拒绝退出码', r.returncode != 0, True)
        c.check('未知键提示', '不支持的设置项' in (r.stderr + r.stdout), True)
        c.check('未知键不动文件', read_conf(mod), before)

        print('[3] 枚举/文本非法值整批拒绝(原子性)')
        r = run_api(mod, base, ['set', 'MODULE_DNS_MODE=1', 'MODULE_DNS_MODE=3'])
        c.check('枚举非法拒绝退出码', r.returncode != 0, True)
        c.check('整批不落盘(枚举)',
                'MODULE_DNS_MODE=2' in read_conf(mod), True)
        r = run_api(mod, base, ['set', 'TUN_DEVICE=bad-device'])
        c.check('TUN_DEVICE 非法拒绝', r.returncode != 0, True)
        c.check('TUN_DEVICE 未变', 'TUN_DEVICE=Meta' in read_conf(mod), True)

        print('[4] 端口按同批最终候选值校验')
        before = read_conf(mod)
        r = run_api(mod, base, ['set', 'AGH_DNS_PORT=5353', 'MIHOMO_DNS_PORT=5353'])
        c.check('同批端口相同拒绝', r.returncode != 0, True)
        c.check('端口冲突不动文件', read_conf(mod), before)
        r = run_api(mod, base, ['set', 'AGH_DNS_PORT=3721'])
        c.check('占用 SmartDNS 端口拒绝', r.returncode != 0, True)
        r = run_api(mod, base, ['set', 'AGH_DNS_PORT=5353'])
        c.check('单独改端口放行', r.returncode, 0)
        c.check('新端口已写入', 'AGH_DNS_PORT=5353' in read_conf(mod), True)
        run_api(mod, base, ['set', 'AGH_DNS_PORT=5300'])

        print('[5] 值未变化时不重写文件')
        before = read_conf(mod)
        r = run_api(mod, base, ['set', 'AGH_DNS_PORT=5300', 'SMARTDNS_ENABLE=true'])
        c.check('未变化仍返回成功', r.returncode, 0)
        c.check('未变化不写文件', read_conf(mod), before)

        print('[6] setarr 写入/去重/非法字符')
        r = run_api(mod, base, ['setarr', 'SUB_URL',
                                'https://a.example/sub', 'https://b.example/sub'])
        conf = read_conf(mod)
        c.check('数组写入退出码', r.returncode, 0)
        c.check('数组行包含两个元素',
                'SUB_URL=("https://a.example/sub" "https://b.example/sub")' in conf, True)
        before = read_conf(mod)
        r = run_api(mod, base, ['setarr', 'SUB_URL',
                                'https://a.example/sub', 'https://b.example/sub'])
        c.check('相同数组跳过写入', read_conf(mod), before)
        r = run_api(mod, base, ['setarr', 'SUB_URL', 'https://x.example/"><script>'])
        c.check('数组含引号拒绝', r.returncode != 0, True)
        c.check('非法数组不动文件', read_conf(mod), before)

        print('[7] get 下发 TTL 边界，边界键只读')
        r = run_api(mod, base, ['get'])
        c.check('get 含 TTL 下限', 'SMARTDNS_TTL_FLOOR=60' in r.stdout, True)
        c.check('get 含 TTL 上限', 'SMARTDNS_TTL_CEIL=86400' in r.stdout, True)
        before = read_conf(mod)
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_FLOOR=30'])
        c.check('边界键不可写', r.returncode != 0, True)
        c.check('边界键写入不改文件', read_conf(mod), before)

        print('[8] TTL 越界拒绝与加载期校验同源')
        before = read_conf(mod)
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=30'])
        c.check('TTL 低于下限拒绝', r.returncode != 0, True)
        c.check('TTL 越界提示带范围', '60-86400' in (r.stderr + r.stdout), True)
        c.check('TTL 越界不动文件', read_conf(mod), before)
        r = run_api(mod, base, ['set', 'SMARTDNS_TTL_MIN=600'])

        return c.report()
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
