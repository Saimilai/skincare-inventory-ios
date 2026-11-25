#!/usr/bin/env python3
"""Prepare and verify the small, commit-bound handoff between CI jobs."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import zipfile


ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "build" / "artifacts"
EVIDENCE = ARTIFACTS / "simulator-evidence"
LOGS = ROOT / "build" / "logs"


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def context():
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    if os.environ.get("GITHUB_SHA", source) != source:
        raise ValueError("The checked-out source commit differs from GITHUB_SHA.")
    return {
        "source_commit": source,
        "run_id": os.environ.get("GITHUB_RUN_ID", "local"),
        "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
        "app_version": os.environ.get("APP_VERSION", "1.0.1"),
        "build_number": os.environ.get("BUILD_NUMBER", os.environ.get("GITHUB_RUN_NUMBER", "1")),
    }


def check_context(value):
    expected = context()
    if any(value.get(key) != item for key, item in expected.items()):
        raise ValueError("Test evidence must match this checkout, run ID, version and build number.")
    return expected


def suite_counts():
    files = ("SkincareInventoryTests/SkincareInventoryTests.swift",
             "SkincareInventoryUITests/SkincareInventoryUITests.swift")
    counts = tuple(len(re.findall(r"^\s*func test\w+\(", (ROOT / name).read_text(
        encoding="utf-8"), re.MULTILINE)) for name in files)
    if counts != (7, 6):
        raise ValueError("Expected seven native and six UI tests; update the evidence contract with the suite.")
    return counts


def check_summary(summary):
    native, ui = suite_counts()
    if (
        summary.get("passedTests") != native + ui
        or summary.get("failedTests") != 0
        or summary.get("skippedTests") != 0
    ):
        raise ValueError("The xcresult summary must confirm 13 passed tests, no failures and no skips.")
    return native, ui


def script_results(node_log, python_log):
    node_counts = {
        key: re.findall(r"^#\s*" + key + r"\s+(\d+)\s*$", node_log, re.MULTILINE)
        for key in ("tests", "pass", "fail", "cancelled", "skipped", "todo")
    }
    if any(not values for values in node_counts.values()):
        raise ValueError("The Node test log has no complete TAP summary.")
    counts = {key: int(values[-1]) for key, values in node_counts.items()}
    if counts["tests"] < 1 or counts["pass"] != counts["tests"] or any(
        counts[key] for key in ("fail", "cancelled", "skipped", "todo")
    ):
        raise ValueError("The Node log does not show all tests passed.")
    python_counts = re.findall(r"^Ran (\d+) tests? in ", python_log, re.MULTILINE)
    if not python_counts or int(python_counts[-1]) < 1 or not re.search(
        r"^OK\s*$", python_log, re.MULTILINE
    ) or re.search(r"^FAILED\b", python_log, re.MULTILINE):
        raise ValueError("The Python log does not show a passing unittest suite.")
    return {
        "node": {"status": "passed", "tests": counts["tests"]},
        "python": {"status": "passed", "tests": int(python_counts[-1])},
    }


def prepare():
    native, ui = check_summary(read_json(EVIDENCE / "summary.json"))
    screenshots = sorted(path.relative_to(EVIDENCE).as_posix() for path in EVIDENCE.rglob("*.png"))
    if not screenshots:
        raise ValueError("The successful simulator run exported no kept screenshot.")
    scripts_dir = EVIDENCE / "script-tests"
    scripts_dir.mkdir(parents=True, exist_ok=True)
    for filename in ("web-tests.log", "python-tests.log", "toolchain.log"):
        shutil.copyfile(LOGS / filename, scripts_dir / filename)
    scripts = script_results(
        (scripts_dir / "web-tests.log").read_text(encoding="utf-8"),
        (scripts_dir / "python-tests.log").read_text(encoding="utf-8"),
    )
    provenance = {
        **context(),
        "schema_version": 1,
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "native_tests_passed": native,
        "ui_tests_passed": ui,
        "script_tests": scripts,
        "simulator_udid": os.environ["SIMULATOR_UDID"],
        "xcode": "16.4",
        "runtime": "iOS 18.5",
        "screenshots": screenshots,
        "real_network_disconnect_and_reconnect": "not tested; native error callbacks were simulated",
        "real_trollstore_device": "not tested",
        "cloud_drive_upload": "not tested",
    }
    write_json(EVIDENCE / "provenance.json", provenance)
    print("Prepared evidence: 7 native, 6 UI; Node {node}, Python {python}.".format(
        node=scripts["node"]["tests"], python=scripts["python"]["tests"]))


def manifest():
    provenance = read_json(EVIDENCE / "provenance.json")
    check_context(provenance)
    archive_path = ARTIFACTS / "simulator-evidence.zip"
    write_json(ARTIFACTS / "handoff-manifest.json", {
        **context(),
        "schema_version": 1,
        "evidence_file": archive_path.name,
        "evidence_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "evidence_bytes": archive_path.stat().st_size,
        "native_tests_passed": 7,
        "ui_tests_passed": 6,
        "script_tests": provenance["script_tests"],
    })


def verify():
    handoff = read_json(ARTIFACTS / "handoff-manifest.json")
    check_context(handoff)
    if handoff.get("schema_version") != 1 or handoff.get("evidence_file") != "simulator-evidence.zip":
        raise ValueError("Unsupported handoff manifest.")
    archive_path = ARTIFACTS / "simulator-evidence.zip"
    if handoff.get("evidence_sha256") != hashlib.sha256(archive_path.read_bytes()).hexdigest():
        raise ValueError("The simulator evidence ZIP checksum does not match the manifest.")
    if handoff.get("evidence_bytes") != archive_path.stat().st_size:
        raise ValueError("The simulator evidence ZIP length does not match the manifest.")
    with zipfile.ZipFile(archive_path) as archive:
        members = {}
        total_bytes = 0
        for member in archive.infolist():
            name = member.filename
            parts = name.rstrip("/").split("/")
            if (
                not name.startswith("simulator-evidence/") or "\\" in name
                or any(part in ("", ".", "..") for part in parts)
                or stat.S_ISLNK(member.external_attr >> 16)
                or name in members or member.flag_bits & 1
            ):
                raise ValueError("Unsafe or duplicated evidence ZIP member: " + name)
            total_bytes += member.file_size
            if total_bytes > 64 * 1024 * 1024:
                raise ValueError("Evidence archive exceeds the 64 MiB transfer limit.")
            members[name] = member
        def content(relative):
            return archive.read("simulator-evidence/" + relative)
        provenance = json.loads(content("provenance.json").decode("utf-8"))
        check_context(provenance)
        native, ui = check_summary(json.loads(content("summary.json").decode("utf-8")))
        if provenance.get("native_tests_passed") != native or provenance.get("ui_tests_passed") != ui:
            raise ValueError("The provenance disagrees with the xcresult summary.")
        if handoff.get("native_tests_passed") != native or handoff.get("ui_tests_passed") != ui:
            raise ValueError("The handoff manifest disagrees with the xcresult summary.")
        scripts = script_results(content("script-tests/web-tests.log").decode("utf-8"),
                                 content("script-tests/python-tests.log").decode("utf-8"))
        if scripts != provenance.get("script_tests") or scripts != handoff.get("script_tests"):
            raise ValueError("Script test logs disagree with the recorded test results.")
        screenshots = provenance.get("screenshots")
        if not isinstance(screenshots, list) or not screenshots:
            raise ValueError("The evidence has no screenshot list.")
        for screenshot in screenshots:
            if not isinstance(screenshot, str) or not screenshot.lower().endswith(".png"):
                raise ValueError("Invalid screenshot in provenance.")
            if not content(screenshot).startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError("A screenshot is absent or is not a PNG.")
        if provenance.get("xcode") != "16.4" or provenance.get("runtime") != "iOS 18.5":
            raise ValueError("The evidence used a different toolchain or simulator runtime.")
        for name, member in members.items():
            destination = ARTIFACTS.joinpath(*name.rstrip("/").split("/"))
            if member.is_dir():
                destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.read(member))
    print("Verified same-run, same-source simulator and script-test evidence.")
    return provenance


def report():
    evidence = verify()
    package = read_json(ARTIFACTS / "validation.json")
    metadata = context()
    run_url = ""
    if os.environ.get("GITHUB_REPOSITORY") and os.environ.get("GITHUB_RUN_ID"):
        run_url = "https://github.com/{}/actions/runs/{}".format(
            os.environ["GITHUB_REPOSITORY"], metadata["run_id"])
    lines = [
        "# 库存手记 IPA 验证报告", "",
        "- App 版本：{}（构建 {}）".format(metadata["app_version"], metadata["build_number"]),
        "- 1.0.1 更新：修复表单录入时的键盘安全区域布局，避免操作区域被键盘遮挡。",
        "- 源码提交：{}".format(metadata["source_commit"]),
        "- 测试与打包运行 ID：{}".format(metadata["run_id"]),
        "- Xcode：16.4；设备架构：arm64；最低系统：iOS 14.0。",
        "- Node 网页兼容测试：{} 项通过；Python 单元测试：{} 项通过。".format(
            evidence["script_tests"]["node"]["tests"], evidence["script_tests"]["python"]["tests"]),
        "- iOS 18.5 模拟器：7 项原生单元测试、6 项 UI 测试通过，无失败、无跳过。",
        "- 模拟器截图、xcresult 摘要、脚本日志：simulator-evidence.zip；{} 张截图。".format(len(evidence["screenshots"])),
        "- IPA 结构、Info.plist、Mach-O 最低系统和 ad hoc 签名：通过。",
        "- IPA SHA-256：{}".format(package["sha256"]),
        "- 加载网站：https://skincare-k-test-20261115.pages.dev/", "",
        "断网提示与重试通过模拟原生网络错误回调验证；未实际切断网络后再联网。",
        "JSON 已测试真实导出 Blob、清空与恢复，并打开/取消系统分享面板；恢复测试直接调用原网页 onchange，未验证保存文件后通过系统选择器导入的完整往返。",
        "XLSX 已用真实网页生成并解包核对 B2/I2/W2；未在外部 Excel/WPS 打开，也未验证网盘上传。",
        "尚未在用户真实 iPhone / TrollStore 上验证安装、启动、备份分享及覆盖更新的数据保留。",
        "模拟器测试使用虚构库存；构建和安装包不含用户真实库存。", "",
        "安装后从原网页导出 JSON，再通过 App 导入。App 和 Safari 的本地库存独立，不能自动同步。",
    ]
    if run_url:
        lines += ["", "测试、打包与发布日志：{}".format(run_url)]
    (ARTIFACTS / "test-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "manifest", "verify", "report"))
    args = parser.parse_args()
    try:
        {"prepare": prepare, "manifest": manifest, "verify": verify, "report": report}[args.command]()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.SubprocessError) as exc:
        print("Evidence handoff rejected: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
