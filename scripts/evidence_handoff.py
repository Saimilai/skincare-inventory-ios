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
SCHEMA_VERSION = 2
BASELINE_CASES = {
    "native": {
        "SkincareInventoryTests/testOnlyExactHTTPSOriginIsTrusted()",
        "SkincareInventoryTests/testJSONBytesAndChineseFilenameSurviveValidation()",
        "SkincareInventoryTests/testSpreadsheetBytesSurviveValidation()",
        "SkincareInventoryTests/testRejectsPathsMismatchedTypesAndMalformedFiles()",
        "SkincareInventoryTests/testRejectsOversizedExport()",
        "SkincareInventoryTests/testNetworkFailureShowsErrorAndRetryPreservesPersistentStore()",
        "SkincareInventoryTests/testTerminatedWebContentProcessShowsRecoveryAndAllowsRetry()",
    },
    "ui": {
        "SkincareInventoryUITests/testPersistentStorageSurvivesRelaunchAndBackground()",
        "SkincareInventoryUITests/testConfirmAndPromptCompletionAndCancellation()",
        "SkincareInventoryUITests/testJSONSharingCancelReturnsAbortAndDoesNotReopen()",
        "SkincareInventoryUITests/testJSONAndExcelBlobDownloadsReachSystemShare()",
        "SkincareInventoryUITests/testRealImportValidationAndCancellation()",
        "SkincareInventoryUITests/testWebsiteLayoutWithoutTestOverlay()",
    },
}


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


def parse_project(source):
    """Read the OpenStep plist without depending on macOS's plutil."""
    tokens = re.findall(
        r'//[^\r\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+',
        source, re.DOTALL,
    )
    tokens = [item for item in tokens if not item.startswith(("//", "/*"))]
    index = 0

    def take(expected=None):
        nonlocal index
        if index >= len(tokens):
            raise ValueError("Truncated Xcode project.")
        token = tokens[index]
        index += 1
        if expected is not None and token != expected:
            raise ValueError("Unexpected Xcode project token: " + token)
        return token

    def value():
        token = take()
        if token == "{":
            result = {}
            while index < len(tokens) and tokens[index] != "}":
                key = take()
                if key.startswith('"'):
                    key = json.loads(key)
                take("=")
                if key in result:
                    raise ValueError("Duplicated Xcode project key: " + key)
                result[key] = value()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while index < len(tokens) and tokens[index] != ")":
                result.append(value())
                if index < len(tokens) and tokens[index] != ")":
                    take(",")
            take(")")
            return result
        if token in "})=;,":
            raise ValueError("Invalid Xcode project scalar.")
        return json.loads(token) if token.startswith('"') else token

    project = value()
    if index != len(tokens) or not isinstance(project, dict):
        raise ValueError("Invalid Xcode project document.")
    return project


def swift_test_cases(source):
    # Mask comments and string contents before balancing class bodies. This
    # intentionally rejects unsupported test declarations rather than omitting
    # them from the expected suite and silently accepting a partial run.
    masked = re.sub(
        r'//[^\r\n]*|/\*.*?\*/|""".*?"""|"(?:\\.|[^"\\])*"',
        lambda match: "".join("\n" if ch == "\n" else " " for ch in match[0]),
        source, flags=re.DOTALL,
    )
    all_methods = list(re.finditer(r"\bfunc\s+(test\w*)\s*\(", masked))
    cases = set()
    methods_found = 0
    for declaration in re.finditer(r"\bclass\s+(\w+)\s*:\s*XCTestCase\s*\{", masked):
        start = declaration.end()
        cursor, depth = start, 1
        while cursor < len(masked) and depth:
            depth += (masked[cursor] == "{") - (masked[cursor] == "}")
            cursor += 1
        if depth:
            raise ValueError("Unbalanced XCTestCase class body.")
        body = masked[start:cursor - 1]
        for method in re.finditer(r"\bfunc\s+(test\w*)\s*\(", body):
            if not re.match(r"\s*\)", body[method.end():]):
                raise ValueError("XCTest methods must have no parameters.")
            identifier = declaration[1] + "/" + method[1] + "()"
            if identifier in cases:
                raise ValueError("Duplicated Swift test method: " + identifier)
            cases.add(identifier)
            methods_found += 1
    if methods_found != len(all_methods):
        raise ValueError("A test method is outside a supported XCTestCase declaration.")
    return cases


def suite_inventory():
    project = parse_project((ROOT / "SkincareInventory.xcodeproj/project.pbxproj").read_text(
        encoding="utf-8"))
    objects = project["objects"]
    main_group = objects[project["rootObject"]]["mainGroup"]
    parents = {}
    for object_id, item in objects.items():
        if item.get("isa") == "PBXGroup":
            for child in item.get("children", []):
                if child in parents:
                    raise ValueError("An Xcode file/group has more than one parent.")
                parents[child] = object_id

    def resolve(object_id, ancestors=()):
        if object_id in ancestors:
            raise ValueError("Cyclic Xcode group references.")
        if object_id == main_group:
            base = ROOT
        else:
            item = objects[object_id]
            tree = item.get("sourceTree", "<group>")
            if tree == "SOURCE_ROOT":
                base = ROOT
            elif tree == "<group>" and object_id in parents:
                base = resolve(parents[object_id], (*ancestors, object_id))
            else:
                raise ValueError("Test source has no supported local group path.")
        path = (base / objects[object_id].get("path", "")).resolve()
        try:
            path.relative_to(ROOT.resolve())
        except ValueError as exc:
            raise ValueError("Test source escapes the checked-out project.") from exc
        return path

    kinds = {
        "com.apple.product-type.bundle.unit-test": "native",
        "com.apple.product-type.bundle.ui-testing": "ui",
    }
    inventory = {"native": [], "ui": []}
    registered_files = set()
    target_counts = {"native": 0, "ui": 0}
    for target in objects.values():
        kind = kinds.get(target.get("productType"))
        if target.get("isa") != "PBXNativeTarget" or kind is None:
            continue
        target_counts[kind] += 1
        cases = set()
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for file_id in phase.get("files", []):
                reference = objects[objects[file_id]["fileRef"]]
                if not reference.get("path", "").endswith(".swift"):
                    continue
                path = resolve(objects[file_id]["fileRef"])
                if path in registered_files:
                    raise ValueError("A Swift source is registered more than once in test targets.")
                registered_files.add(path)
                source_cases = swift_test_cases(path.read_text(encoding="utf-8"))
                if cases.intersection(source_cases):
                    raise ValueError("Duplicated test identifiers across Swift files.")
                cases.update(source_cases)
        if not BASELINE_CASES[kind].issubset(cases):
            raise ValueError("The original seven native and six UI test cases must remain registered.")
        inventory[kind] = sorted(cases)
    if target_counts != {"native": 1, "ui": 1}:
        raise ValueError("Expected exactly one native and one UI test target.")
    # Catch a newly authored XCTestCase file that was accidentally omitted from
    # the build phase; counting registered sources alone cannot detect that.
    for path in ROOT.rglob("*.swift"):
        relative = path.relative_to(ROOT)
        if relative.parts[0] in ("build", ".git"):
            continue
        source = path.read_text(encoding="utf-8")
        if re.search(r"\bclass\s+\w+\s*:\s*XCTestCase\b", source):
            if swift_test_cases(source) and path.resolve() not in registered_files:
                raise ValueError("An XCTestCase source is not registered in a test target: " + str(relative))
    return inventory


def suite_counts():
    inventory = suite_inventory()
    return len(inventory["native"]), len(inventory["ui"])


def check_summary(summary, tests):
    inventory = suite_inventory()
    native, ui = len(inventory["native"]), len(inventory["ui"])
    if (
        summary.get("passedTests") != native + ui
        or summary.get("failedTests") != 0
        or summary.get("skippedTests") != 0
    ):
        raise ValueError("The xcresult summary must confirm all registered tests passed, no failures or skips.")
    actual = []

    def visit(value):
        if isinstance(value, dict):
            if value.get("nodeType") == "Test Case":
                if value.get("result") != "Passed" or not isinstance(value.get("nodeIdentifier"), str):
                    raise ValueError("A simulator test case did not pass.")
                actual.append(value["nodeIdentifier"])
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(tests)
    expected = set(inventory["native"] + inventory["ui"])
    if len(actual) != len(set(actual)) or set(actual) != expected:
        raise ValueError("The xcresult test cases must exactly match the registered Swift test inventory.")
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
    native, ui = check_summary(read_json(EVIDENCE / "summary.json"), read_json(EVIDENCE / "tests.json"))
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
        "schema_version": SCHEMA_VERSION,
        "created_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "native_tests_passed": native,
        "ui_tests_passed": ui,
        "test_inventory": suite_inventory(),
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
    print("Prepared evidence: {native} native, {ui} UI; Node {node}, Python {python}.".format(
        native=native, ui=ui, node=scripts["node"]["tests"], python=scripts["python"]["tests"]))


def manifest():
    provenance = read_json(EVIDENCE / "provenance.json")
    check_context(provenance)
    archive_path = ARTIFACTS / "simulator-evidence.zip"
    write_json(ARTIFACTS / "handoff-manifest.json", {
        **context(),
        "schema_version": SCHEMA_VERSION,
        "evidence_file": archive_path.name,
        "evidence_sha256": hashlib.sha256(archive_path.read_bytes()).hexdigest(),
        "evidence_bytes": archive_path.stat().st_size,
        "native_tests_passed": len(suite_inventory()["native"]),
        "ui_tests_passed": len(suite_inventory()["ui"]),
        "test_inventory": suite_inventory(),
        "script_tests": provenance["script_tests"],
    })


def verify():
    handoff = read_json(ARTIFACTS / "handoff-manifest.json")
    check_context(handoff)
    if handoff.get("schema_version") != SCHEMA_VERSION or handoff.get("evidence_file") != "simulator-evidence.zip":
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
        inventory = suite_inventory()
        if provenance.get("schema_version") != SCHEMA_VERSION or any(
            value.get("test_inventory") != inventory for value in (provenance, handoff)
        ):
            raise ValueError("The evidence test inventory differs from this checkout's registered tests.")
        native, ui = check_summary(json.loads(content("summary.json").decode("utf-8")),
                                   json.loads(content("tests.json").decode("utf-8")))
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
        "# 库存 IPA 验证报告", "",
        "- App 版本：{}（构建 {}）".format(metadata["app_version"], metadata["build_number"]),
        "- 新增 App 更新检查、下载校验、原生确认覆盖更新及系统文件交接入口；保留键盘安全区域适配。",
        "- 源码提交：{}".format(metadata["source_commit"]),
        "- 测试与打包运行 ID：{}".format(metadata["run_id"]),
        "- Xcode：16.4；设备架构：arm64；最低系统：iOS 14.0。",
        "- Node 网页兼容测试：{} 项通过；Python 单元测试：{} 项通过。".format(
            evidence["script_tests"]["node"]["tests"], evidence["script_tests"]["python"]["tests"]),
        "- iOS 18.5 模拟器：{} 项原生单元测试、{} 项 UI 测试通过，无失败、无跳过。".format(
            evidence["native_tests_passed"], evidence["ui_tests_passed"]),
        "- 已注册 XCTest 源码与 xcresult 具体测试名称逐一核对，完整清单见 provenance.json。",
        "- 模拟器截图、xcresult 摘要、脚本日志：simulator-evidence.zip；{} 张截图。".format(len(evidence["screenshots"])),
        "- IPA 结构、Info.plist、Mach-O 最低系统、ad hoc 签名及已审权限清单：通过。",
        "- IPA SHA-256：{}".format(package["sha256"]),
        "- 加载网站：https://skincare-k-test-20261115.pages.dev/", "",
        "断网提示与重试通过模拟原生网络错误回调验证；未实际切断网络后再联网。",
        "JSON 已测试真实导出 Blob、清空与恢复，并打开/取消系统分享面板；恢复测试直接调用原网页 onchange，未验证保存文件后通过系统选择器导入的完整往返。",
        "XLSX 已用真实网页生成并解包核对 B2/I2/W2；未在外部 Excel/WPS 打开，也未验证网盘上传。",
        "原生覆盖更新的实现路径：下载并校验 IPA 后，在 App 内由用户确认安装，无需切到巨魔界面。仅当已安装的官方 TrollStore 2.1.1 安装助手，其版本、文件大小和 SHA-256 均与精确固定的已审版本匹配时启用；安装会关闭旧版库存，之后需从桌面重开并核对版本。",
        "其他巨魔版本、非标准安装位置或无法确认环境时，停用原生安装，保留系统 Open In 文件菜单，将已校验 IPA 交给巨魔覆盖安装。",
        "模拟器不执行安装助手或 root 安装。更新服务使用 URLProtocol 模拟 HTTP 响应；更新界面使用调试桩验证检查、返回与库存保留；权限清单核对不能替代真实设备运行验证。",
        "真实设备上的完整 IPA 下载、原生覆盖安装、旧进程关闭后安装子进程能否继续完成，以及相同数据容器和库存能否保留，均待用户巨魔设备实测。系统 Open In 交给巨魔的完整升级流程同样尚未实机验证。",
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
