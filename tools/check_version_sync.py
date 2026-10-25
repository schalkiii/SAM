#!/usr/bin/env python3
"""版本号一致性校验(CI 门禁)

发版要同时改三处: module.prop(version/versionCode)、update.json(version/
versionCode/zipUrl)、changelog(版本节)。漏一处就会出故障——版号没跟上则设备
OTA 认为无需升级，zipUrl 没跟上则下载 404。这个脚本把「三处必须对齐」变成
确定性检查，由 CI 每次 push 执行。

校验项:
  1. module.prop 的 version      == update.json 的 version
  2. module.prop 的 versionCode  == update.json 的 versionCode
  3. update.json 的 zipUrl 资产名 == SAM_<version>_release.zip
  4. changelog 存在该版本的节(version 20261025.3 对应 "# 2026.10.25.3")

用法:
    python tools/check_version_sync.py        # 校验并在失败时 exit 1
    python tools/check_version_sync.py -v     # 打印每一项的检查过程
"""

import argparse
import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent


def read_module_prop(path):
    """解析 module.prop 的 key=value 行"""
    props = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if sep:
            props[key.strip()] = value.strip()
    return props


def changelog_header(version):
    """把 20261025.3 转成 changelog 的版本节形态 "# 2026.10.25.3"

    不支持解析的版本号返回 None(由调用方报错，不猜格式)
    """
    m = re.match(r'^(\d{4})(\d{2})(\d{2})(?:\.(\d+))?$', version)
    if not m:
        return None
    year, month, day, serial = m.groups()
    header = f'# {year}.{month}.{day}'
    return f'{header}.{serial}' if serial else header


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    failures = []
    checks = 0

    def check(name, actual, expected, actual_label='实际', expected_label='期望'):
        nonlocal checks
        checks += 1
        if actual == expected:
            if args.verbose:
                print(f'  OK    {name}: {actual}')
            return
        failures.append(f'{name}\n        {expected_label}: {expected!r}\n        {actual_label}: {actual!r}')

    prop_path = REPO / 'module.prop'
    update_path = REPO / 'update.json'
    changelog_path = REPO / 'changelog.md'

    for path in (prop_path, update_path, changelog_path):
        if not path.is_file():
            print(f'[x] 缺少文件: {path.name}')
            return 1

    props = read_module_prop(prop_path)
    try:
        update = json.loads(update_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError as exc:
        print(f'[x] update.json 不是合法 JSON: {exc}')
        return 1

    prop_version = props.get('version', '')
    prop_code = props.get('versionCode', '')
    update_version = str(update.get('version', ''))
    update_code = str(update.get('versionCode', ''))
    zip_url = str(update.get('zipUrl', ''))

    check('module.prop 与 update.json 版本一致', prop_version, update_version,
          actual_label='module.prop', expected_label='update.json')
    check('module.prop 与 update.json versionCode 一致', prop_code, update_code,
          actual_label='module.prop', expected_label='update.json')

    if not prop_code.isdigit():
        failures.append(f'versionCode 必须是数字\n        实际: {prop_code!r}')

    expected_asset = f'SAM_{prop_version}_release.zip'
    check('zipUrl 指向本版本的资产', zip_url.rsplit('/', 1)[-1], expected_asset)

    expected_header = changelog_header(prop_version)
    if expected_header is None:
        failures.append(f'版本号无法解析为 YYYYMMDD[.N]: {prop_version!r}')
    else:
        changelog_text = changelog_path.read_text(encoding='utf-8')
        has_section = any(line.strip() == expected_header
                          for line in changelog_text.splitlines())
        check(f'changelog 存在版本节 {expected_header}', has_section, True)

    if failures:
        print(f'[x] 版本号不一致（检查 {checks} 项）:')
        for item in failures:
            print(f'    - {item}')
        return 1

    print(f'[√] 版本号三处一致: {prop_version} / {prop_code}（检查 {checks} 项）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
