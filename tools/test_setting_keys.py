#!/usr/bin/env python3
"""配置键五处一致性静态测试

AGENTS 要求：新增配置键必须同步五处，否则会出现「WebUI 能改但服务读不到」
或「升级后键丢失」。五处分别是：
  1. setting.conf 真身
  2. setting.sh 的 setting_default 默认值
  3. setting_api.sh 的分类列表（BOOL/PORT/TTL/TEXT/ENUM/ARRAY）与 get_all
  4. customize.sh 的升级迁移列表
  5. webroot/index.html 的 data-key

本测试只做静态解析（不需要设备路径，也不启动服务），断言五处的键集合完全一致，
且没有重复键；任一键只加在一处都会立刻变红。

用法:
    python tools/test_setting_keys.py            # 跑全部用例
    python tools/test_setting_keys.py -v         # 打印每个用例细节
"""

import argparse
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent


def read(path):
    return path.read_text(encoding='utf-8')


def extract_function(text, name):
    """抽取 name(){ ... } 的函数体（顶层函数，右花括号在行首）"""
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(f'{name}(){{')), None)
    if start is None:
        raise SystemExit(f'找不到函数 {name}(){{')
    end = next((i for i in range(start + 1, len(lines)) if lines[i] == '}'), None)
    if end is None:
        raise SystemExit(f'{name} 函数体没有闭合的 }}')
    return '\n'.join(lines[start:end + 1])


def setting_conf_keys():
    text = read(REPO / 'setting.conf')
    return re.findall(r'^([A-Z][A-Z0-9_]*)=', text, re.M)


def setting_default_keys():
    text = read(REPO / 'scripts' / 'setting.sh')
    body = extract_function(text, 'setting_default')
    return re.findall(r'^\s+([A-Z][A-Z0-9_]*)=', body, re.M)


def setting_api_groups():
    text = read(REPO / 'scripts' / 'setting_api.sh')
    groups = {}
    for name in ('BOOL_KEYS', 'PORT_KEYS', 'TTL_KEYS', 'TEXT_KEYS', 'ENUM_KEYS', 'ARRAY_KEYS'):
        match = re.search(rf'^{name}="([^"]*)"', text, re.M)
        groups[name] = match.group(1).split() if match else []
    return text, groups


def customize_keys():
    text = read(REPO / 'customize.sh')
    return re.findall(r'modify_setting .* "([A-Z][A-Z0-9_]*)"\s*$', text, re.M)


def webui_keys():
    text = read(REPO / 'webroot' / 'index.html')
    return re.findall(r'data-key="([A-Z][A-Z0-9_]*)"', text)


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
            missing = sorted(set(expected) - set(actual)) if isinstance(actual, list) else []
            extra = sorted(set(actual) - set(expected)) if isinstance(actual, list) else []
            detail = ''
            if missing:
                detail += f'\n        缺少: {missing}'
            if extra:
                detail += f'\n        多出: {extra}'
            print(f'  FAIL  {name}\n        期望: {expected!r}\n        实际: {actual!r}{detail}')

    def report(self):
        print()
        print(f'通过 {self.passed} 项, 失败 {self.failed} 项')
        return 0 if self.failed == 0 else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    c = Checker(verbose=args.verbose)

    conf_keys = setting_conf_keys()
    conf_unique = sorted(set(conf_keys))

    print(f'[1] setting.conf: {len(conf_keys)} 个键')
    c.check('配置键非空', bool(conf_keys), True)
    c.check('配置键无重复', len(conf_keys), len(conf_unique))

    print('[2] setting.sh 默认值')
    default_keys = sorted(set(setting_default_keys()))
    c.check('默认值覆盖全部配置键', default_keys, conf_unique)

    print('[3] setting_api.sh 分类列表与 get_all')
    api_text, groups = setting_api_groups()
    api_keys = sorted({key for values in groups.values() for key in values})
    c.check('分类列表覆盖全部配置键', api_keys, conf_unique)
    get_all_body = extract_function(api_text, 'get_all')
    for group_name in ('BOOL_KEYS', 'PORT_KEYS', 'TTL_KEYS', 'TEXT_KEYS', 'ENUM_KEYS', 'ARRAY_KEYS'):
        c.check(f'get_all 使用 {group_name}', f'${{{group_name}}}' in get_all_body, True)
    c.check('get_all 下发 TTL 下限', 'SMARTDNS_TTL_FLOOR' in get_all_body, True)
    c.check('get_all 下发 TTL 上限', 'SMARTDNS_TTL_CEIL' in get_all_body, True)

    print('[4] customize.sh 升级迁移列表')
    migrate_keys = sorted(set(customize_keys()))
    c.check('迁移列表覆盖全部配置键', migrate_keys, conf_unique)

    print('[5] WebUI data-key')
    html_keys = webui_keys()
    c.check('data-key 无重复', len(html_keys), len(set(html_keys)))
    c.check('data-key 覆盖全部配置键', sorted(set(html_keys)), conf_unique)

    return c.report()


if __name__ == '__main__':
    sys.exit(main())
