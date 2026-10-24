#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SAM 模块打包工具

为什么不用 Compress-Archive / 右键压缩:
  1. 不会把 CRLF 转成 LF —— 设备上的 mksh 会把行尾的 \\r 当成内容，
     出现 "改完配置服务就起不来" 这类诡异问题
  2. 不会写 Unix 权限位 —— 脚本丢了 +x，模块管理器执行时直接失败
  3. 不做任何校验 —— 打包漏文件、混进 BOM 都发现不了

本脚本会按顺序完成:
  文本文件转 LF 且去 BOM -> 设置权限 -> 打包 -> 回读校验(条目/CRC/行尾/大小)
  -> shell 语法检查(sh -n / mksh -n，存在才跑)

用法:
  python tools/pack_module.py                     # 打包到 dist/SAM.zip
  python tools/pack_module.py -o SAM-custom.zip   # 指定输出
  python tools/pack_module.py --check             # 只检查不打包
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile

# 需要按文本处理并强制 LF 的后缀
TEXT_SUFFIXES = {
    ".sh", ".prop", ".conf", ".cfg", ".yaml", ".yml", ".md",
    ".json", ".txt", ".html", ".htm", ".css", ".js", ".xml", ".ini", ".py",
}

# 没有文本后缀但也必须保证 LF 的文件
TEXT_NAMES = {
    "etc/crontabs/root",
    "META-INF/com/google/android/update-binary",
    "META-INF/com/google/android/updater-script",
}

# 需要 0755 的路径前缀
EXEC_PREFIXES = ("bin/",)

# 第三方前端资源: 属于构建产物，不做 LF 规范化，避免无意义的整文件 diff
VENDOR_PREFIXES = ("etc/SmartDNS/wwwroot/", "etc/mihomo/webui/")

# 跳过目录 / 文件
SKIP_DIRS = {".git", ".github", ".idea", ".vscode", ".workbuddy", "__pycache__", "dist", "tools"}
SKIP_FILES = {".gitignore", ".gitattributes", ".DS_Store", "Thumbs.db"}

UTF8_BOM = b"\xef\xbb\xbf"


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []

    def error(self, message):
        self.errors.append(message)

    def warn(self, message):
        self.warnings.append(message)


def collect_files(source_dir):
    """收集需要打包的文件，返回相对路径列表(使用 / 分隔)"""
    result = []
    for root, dirs, files in os.walk(source_dir):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name in SKIP_FILES:
                continue
            absolute = os.path.join(root, name)
            relative = os.path.relpath(absolute, source_dir).replace(os.sep, "/")
            result.append(relative)
    return result


def is_vendor(relative):
    return relative.startswith(VENDOR_PREFIXES)


def is_text_file(relative):
    if is_vendor(relative):
        return False
    if relative in TEXT_NAMES:
        return True
    suffix = os.path.splitext(relative)[1].lower()
    return suffix in TEXT_SUFFIXES


def normalize_bytes(raw):
    """去 BOM + CRLF 转 LF，返回规范化后的字节"""
    if raw.startswith(UTF8_BOM):
        raw = raw[len(UTF8_BOM):]
    return raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")


def normalize_text(path, report):
    """就地规范化源文件，返回是否有改动"""
    with open(path, "rb") as handle:
        original = handle.read()

    normalized = normalize_bytes(original)

    if normalized != original:
        with open(path, "wb") as handle:
            handle.write(normalized)
        return True
    return False


def check_eol(path, relative, report):
    with open(path, "rb") as handle:
        raw = handle.read()
    if b"\r" in raw:
        report.error("行尾仍含 CR，设备上会解析异常: {}".format(relative))


def check_shell_syntax(path, relative, report):
    """优先用 mksh(与设备一致)，没有就用 bash；返回实际使用的解释器"""
    interpreter = None
    for candidate in ("mksh", "bash", "sh"):
        if shutil.which(candidate):
            interpreter = candidate
            break

    if interpreter is None:
        report.warn("未找到 shell，跳过语法检查: {}".format(relative))
        return None

    # 通过 stdin 传脚本，避免 Windows 下把 D:\... 传给 MSYS 解释器时反斜杠被吃掉
    try:
        with open(path, "rb") as handle:
            completed = subprocess.run(
                [interpreter, "-n"],
                stdin=handle,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
    except OSError as error:
        report.warn("无法执行 {} 检查 {}: {}".format(interpreter, relative, error))
        return interpreter

    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", "replace").strip().splitlines()
        report.error("语法错误 [{}] {}: {}".format(interpreter, relative, detail[0] if detail else "未知错误"))

    return interpreter


def file_mode(relative):
    if relative == "META-INF/com/google/android/update-binary":
        return 0o755
    if relative.endswith(".sh") or relative.startswith(EXEC_PREFIXES):
        return 0o755
    return 0o644


def build_zip(source_dir, target_zip, files, report, no_write=False):
    """打包时对文本用 deflate、二进制用 store，兼顾体积与速度"""
    with zipfile.ZipFile(target_zip, "w") as archive:
        for relative in files:
            absolute = os.path.join(source_dir, relative)
            suffix = os.path.splitext(relative)[1].lower()
            compression = zipfile.ZIP_DEFLATED if (is_text_file(relative) or suffix in TEXT_SUFFIXES) else zipfile.ZIP_STORED

            info = zipfile.ZipInfo(relative)
            info.external_attr = (file_mode(relative) & 0xFFFF) << 16
            info.compress_type = compression
            info.create_system = 3  # Unix，确保权限位被识别

            with open(absolute, "rb") as handle:
                content = handle.read()

            # no-write: 只把规范化结果写进压缩包，不改源文件
            if no_write and is_text_file(relative):
                content = normalize_bytes(content)

            archive.writestr(info, content)

        if archive.testzip() is not None:
            report.error("打包后 CRC 校验失败")


def verify_zip(source_dir, target_zip, files, report, no_write=False):
    """回读校验: 条目齐全、内容一致、行尾干净"""
    with zipfile.ZipFile(target_zip, "r") as archive:
        names = set(archive.namelist())

        missing = [f for f in files if f not in names]
        if missing:
            report.error("压缩包缺少条目: {}".format(", ".join(missing[:5])))

        for relative in files:
            if relative not in names:
                continue

            packed = archive.read(relative)
            with open(os.path.join(source_dir, relative), "rb") as handle:
                source = handle.read()

            expected = normalize_bytes(source) if (no_write and is_text_file(relative)) else source
            if packed != expected:
                report.error("内容与源文件不一致: {}".format(relative))

            if is_text_file(relative) and b"\r" in packed:
                report.error("压缩包内仍含 CR: {}".format(relative))


def main():
    parser = argparse.ArgumentParser(description="打包并校验 SAM 模块")
    parser.add_argument("-s", "--source", default=".", help="仓库根目录(默认当前目录)")
    parser.add_argument("-o", "--output", default=None, help="输出 zip 路径(默认 dist/SAM.zip)")
    parser.add_argument("--check", action="store_true", help="只做检查，不生成 zip")
    parser.add_argument("--no-write", action="store_true", help="只把 LF 结果写进 zip，不改仓库里的源文件")
    args = parser.parse_args()

    source_dir = os.path.abspath(args.source)
    if not os.path.isfile(os.path.join(source_dir, "module.prop")):
        print("[×] 在 {} 下没找到 module.prop，确认这是模块根目录".format(source_dir))
        return 1

    report = Report()
    files = collect_files(source_dir)
    print("[1/4] 收集文件: {} 个".format(len(files)))

    # 1. 文本规范化
    changed = []
    for relative in files:
        if not is_text_file(relative):
            continue
        absolute = os.path.join(source_dir, relative)
        if args.no_write:
            # 不写源文件，只记录哪些文件"本来需要转换"
            with open(absolute, "rb") as handle:
                raw = handle.read()
            if normalize_bytes(raw) != raw:
                changed.append(relative)
            # --check --no-write 时也必须发现 CRLF，否则 CI 会放过坏文件
            check_eol(absolute, relative, report)
        else:
            if normalize_text(absolute, report):
                changed.append(relative)
            check_eol(absolute, relative, report)

    action = "需要转换(未写入)" if args.no_write else "已转为 LF/去 BOM"
    print("[2/4] 文本规范化: {} 个文件{}".format(len(changed), action))
    for relative in changed[:10]:
        print("      - {}".format(relative))
    if len(changed) > 10:
        print("      ... 其余 {} 个".format(len(changed) - 10))

    # 2. 语法检查
    shell_files = [f for f in files if f.endswith(".sh")]
    interpreters = set()
    for relative in shell_files:
        used = check_shell_syntax(os.path.join(source_dir, relative), relative, report)
        if used:
            interpreters.add(used)
    if interpreters and "mksh" not in interpreters:
        report.warn("语法检查用的是 {}；设备上是 mksh，建议在 WSL 下用 mksh -n 复检一次".format("/".join(sorted(interpreters))))
    print("[3/4] 语法检查: {} 个 shell 脚本".format(len(shell_files)))

    if args.check:
        print("[4/4] 仅检查模式，未生成 zip")
    else:
        output = args.output or os.path.join(source_dir, "dist", "SAM.zip")
        output = os.path.abspath(output)
        os.makedirs(os.path.dirname(output), exist_ok=True)

        build_zip(source_dir, output, files, report, args.no_write)
        verify_zip(source_dir, output, files, report, args.no_write)

        digest = hashlib.sha256()
        with open(output, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)

        print("[4/4] 已生成: {}".format(output))
        print("      大小: {:.2f} MB".format(os.path.getsize(output) / 1024 / 1024))
        print("      SHA256: {}".format(digest.hexdigest()))

    # 汇总
    if report.warnings:
        print("\n[!] 提示:")
        for message in report.warnings:
            print("    - {}".format(message))

    if report.errors:
        print("\n[×] 发现问题:")
        for message in report.errors:
            print("    - {}".format(message))
        return 1

    print("\n[√] 校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
