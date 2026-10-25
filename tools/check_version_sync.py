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
  5. README.md / AGENTS.md 声明的默认密码 == smartdns.conf 的 smartdns-ui.password
  6. desc.sh / customize.sh / WebUI 服务页的凭据文案 == smartdns.conf 的 user/password
  7. module.prop 的 description 不能是占位值「模块未启动」

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


def first_backticked(text, keyword):
    """取 keyword 之后第一个反引号包裹的值(同一行内)"""
    match = re.search(keyword + r'[^`\n]*`([^`]+)`', text)
    return match.group(1) if match else ''


def credential_pairs(text, pattern):
    """按 pattern 提取 (账号, 密码) 并去重；提取不到时返回空列表"""
    return sorted(set(re.findall(pattern, text)))


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

    # 默认凭据必须与配置真身一致: v20261025.7 曾出现 README 摘要写 sam123456、
    # 实际 smartdns.conf 是 root 的矛盾，只校验版本号的门禁完全放行，
    # 用户照着文档登录必然失败。这里把它变成确定性检查。
    smartdns_conf = REPO / 'etc' / 'SmartDNS' / 'smartdns.conf'
    conf_text = smartdns_conf.read_text(encoding='utf-8') if smartdns_conf.is_file() else ''
    conf_match = re.search(r'^smartdns-ui\.password\s+(\S+)', conf_text, re.M)
    conf_password = conf_match.group(1) if conf_match else ''
    if not conf_password:
        failures.append('无法从 etc/SmartDNS/smartdns.conf 读取 smartdns-ui.password')
    conf_user_match = re.search(r'^smartdns-ui\.user\s+(\S+)', conf_text, re.M)
    conf_user = conf_user_match.group(1) if conf_user_match else ''
    if not conf_user:
        failures.append('无法从 etc/SmartDNS/smartdns.conf 读取 smartdns-ui.user')

    readme_path = REPO / 'README.md'
    readme_password = first_backticked(readme_path.read_text(encoding='utf-8'), '默认密码') \
        if readme_path.is_file() else ''
    agents_path = REPO / 'AGENTS.md'
    agents_password = first_backticked(agents_path.read_text(encoding='utf-8'), '默认密码') \
        if agents_path.is_file() else ''

    check('README 默认密码与 SmartDNS 配置一致', readme_password, conf_password,
          actual_label='README', expected_label='smartdns.conf')
    check('AGENTS 默认密码与 SmartDNS 配置一致', agents_password, conf_password,
          actual_label='AGENTS', expected_label='smartdns.conf')

    # 凭据的可视文案不止 README/AGENTS: 模块描述、安装提示与 WebUI 服务页
    # 也会告诉用户账号密码。v20261025.7 已发生过文档与配置不一致，这里把
    # 其余三个可视面也纳入门禁，避免只改了文档却漏掉界面文案。
    expected_pairs = [(conf_user, conf_password)]
    desc_text = (REPO / 'scripts' / 'update' / 'desc.sh').read_text(encoding='utf-8') \
        if (REPO / 'scripts' / 'update' / 'desc.sh').is_file() else ''
    desc_pairs = credential_pairs(desc_text, r'面板账号:\s*([^\s/（(]+)\s*/\s*([^\s（(]+)')
    check('desc.sh 面板凭据与 SmartDNS 配置一致', desc_pairs, expected_pairs,
          actual_label='desc.sh', expected_label='smartdns.conf')

    customize_text = (REPO / 'customize.sh').read_text(encoding='utf-8') \
        if (REPO / 'customize.sh').is_file() else ''
    customize_pairs = credential_pairs(
        customize_text, r'账号:\s*([^\s|]+)\s*\|\s*密码:\s*([^\s)]+)')
    check('customize.sh 安装提示凭据与 SmartDNS 配置一致', customize_pairs, expected_pairs,
          actual_label='customize.sh', expected_label='smartdns.conf')

    webui_path = REPO / 'webroot' / 'index.html'
    webui_text = webui_path.read_text(encoding='utf-8') if webui_path.is_file() else ''
    webui_pairs = credential_pairs(
        webui_text, r'默认账号\s*([^\s/（(]+)\s*/\s*([^\s（(]+)')
    check('WebUI 服务页凭据与 SmartDNS 配置一致', webui_pairs, expected_pairs,
          actual_label='webroot/index.html', expected_label='smartdns.conf')

    # 发版包里的 module.prop 不能是占位描述: 首次启动前模块列表显示的就是它
    description = props.get('description', '').strip()
    if description == '模块未启动':
        failures.append('module.prop 的 description 仍是占位值「模块未启动」，发版前请写成正式文案')

    if failures:
        print(f'[x] 版本/文档一致性检查失败（检查 {checks} 项）:')
        for item in failures:
            print(f'    - {item}')
        return 1

    print(f'[√] 版本/文档一致性通过: {prop_version} / {prop_code}（检查 {checks} 项）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
