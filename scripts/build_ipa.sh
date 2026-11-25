#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS and Xcode. Windows can edit the source, but cannot run this script." >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}"
app_version="${APP_VERSION:-1.0.0}"
build_number="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
if [[ ! "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "APP_VERSION must be x.y.z; BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Required Xcode 16.4 developer directory is missing: $DEVELOPER_DIR" >&2
  exit 1
fi
if [[ -e build/TestResults.xcresult ]]; then
  echo "A prior build/TestResults.xcresult exists. Use a clean checkout or a separate build directory." >&2
  exit 1
fi

artifact_dir="$project_root/build/artifacts"
log_dir="$project_root/build/logs"
mkdir -p "$artifact_dir" "$log_dir"
ipa_path="$artifact_dir/SkincareInventory-${app_version}-TrollStore.ipa"
result_bundle="$project_root/build/TestResults.xcresult"
evidence_dir="$artifact_dir/simulator-evidence"
simulator_boot_pid=""
package_dir=""
build_phase="toolchain checks"

print_failure_diagnostics() {
  echo "::error::IPA build failed during: $build_phase"
  if [[ -s "$log_dir/simulator-tests.log" ]]; then
    echo "Recent simulator test failures:"
    grep -Ei 'error:|failed|failure|XCTAssert|timed out|cancelled' "$log_dir/simulator-tests.log" | tail -n 12 || true
  fi
  if [[ -d "$result_bundle" ]]; then
    mkdir -p "$evidence_dir"
    if xcrun xcresulttool get test-results summary --path "$result_bundle" --compact \
      > "$evidence_dir/failure-summary.json" 2> "$log_dir/failure-summary.log"; then
      python3 - "$evidence_dir/failure-summary.json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
keys = ("result", "testResults", "totalTestCount", "passedTests", "failedTests", "skippedTests")
compact = {key: summary[key] for key in keys if key in summary}
if summary.get("testFailures"):
    compact["testFailures"] = summary["testFailures"][:3]
print(json.dumps(compact, ensure_ascii=False, indent=2))
PY
    else
      echo "The interrupted xcresult bundle has no readable test summary."
    fi
  fi
}

finish_build() {
  local exit_status=$?
  trap - EXIT
  set +e
  if [[ "$exit_status" -ne 0 ]]; then
    print_failure_diagnostics
  fi
  if [[ -n "$simulator_boot_pid" ]] && kill -0 "$simulator_boot_pid" 2>/dev/null; then
    kill "$simulator_boot_pid" 2>/dev/null
  fi
  if [[ -n "$package_dir" && "$package_dir" == "$project_root"/build/package.* ]]; then
    rm -rf -- "$package_dir"
  fi
  exit "$exit_status"
}
trap finish_build EXIT

echo "Checking Xcode, Node and Python"
xcodebuild -version | tee "$log_dir/toolchain.log"
if ! xcodebuild -version | head -n 1 | grep -Fxq "Xcode 16.4"; then
  echo "The selected toolchain must be Xcode 16.4." >&2
  exit 1
fi
node --version | tee -a "$log_dir/toolchain.log"
python3 --version | tee -a "$log_dir/toolchain.log"

build_phase="simulator selection"
echo "Selecting an available iOS 18.5 iPhone simulator"
simulator_udid="$(python3 - <<'PY'
import json
import subprocess
import sys

inventory = json.loads(subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
))
devices = [
    device
    for runtime, items in inventory["devices"].items()
    if runtime.endswith("iOS-18-5")
    for device in items
    if device.get("isAvailable") and device.get("name", "").startswith("iPhone")
]
if not devices:
    sys.exit("No available iOS 18.5 iPhone simulator. Do not silently substitute another runtime.")
print(sorted(devices, key=lambda item: (item["name"], item["udid"]))[0]["udid"])
PY
)"
printf '%s\n' "$simulator_udid" | tee "$log_dir/simulator-udid.log"
echo "Starting simulator migration while scripts and test targets build"
(
  xcrun simctl bootstatus "$simulator_udid" -b 2>&1 | tee "$log_dir/simulator-boot.log"
) &
simulator_boot_pid=$!

build_phase="web compatibility tests"
echo "Running web compatibility tests"
node --test Tests/web-compatibility.test.js 2>&1 | tee "$log_dir/web-tests.log"

python_test_status="not configured"
if compgen -G "Tests/test_*.py" >/dev/null; then
  build_phase="Python unit tests"
  echo "Running Python unit tests"
  python3 -m unittest discover -s Tests -p 'test_*.py' -v 2>&1 | tee "$log_dir/python-tests.log"
  python_test_status="passed"
fi

build_phase="simulator build-for-testing"
echo "Building simulator test targets during cold startup"
xcodebuild build-for-testing \
  -project SkincareInventory.xcodeproj \
  -scheme SkincareInventory \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath build/DerivedDataSimulator \
  CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=14.0 \
  MARKETING_VERSION="$app_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee "$log_dir/simulator-build.log"

build_phase="simulator startup"
echo "Waiting for the already-starting simulator"
wait "$simulator_boot_pid"
simulator_boot_pid=""

build_phase="native and UI simulator tests"
echo "Running native and UI tests on a single simulator, without recompiling"
xcodebuild test-without-building \
  -project SkincareInventory.xcodeproj \
  -scheme SkincareInventory \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath build/DerivedDataSimulator \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -maximum-concurrent-test-simulator-destinations 1 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 180 \
  CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=14.0 \
  MARKETING_VERSION="$app_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee "$log_dir/simulator-tests.log"

build_phase="simulator evidence export"
echo "Exporting simulator screenshots and test summaries"
mkdir -p "$evidence_dir"
xcrun xcresulttool get test-results summary --path "$result_bundle" \
  > "$evidence_dir/summary.json"
xcrun xcresulttool get test-results tests --path "$result_bundle" \
  > "$evidence_dir/tests.json"
xcrun xcresulttool export attachments --path "$result_bundle" \
  --output-path "$evidence_dir/attachments" \
  2>&1 | tee "$log_dir/simulator-evidence.log"
export EVIDENCE_DIR="$evidence_dir" SIMULATOR_UDID="$simulator_udid"
python3 - <<'PY'
import json
import os
import pathlib
import re

evidence = pathlib.Path(os.environ["EVIDENCE_DIR"])
summary = json.loads((evidence / "summary.json").read_text(encoding="utf-8"))
native_count = len(re.findall(r"^\s*func test\w+\(", pathlib.Path(
    "SkincareInventoryTests/SkincareInventoryTests.swift").read_text(encoding="utf-8"), re.MULTILINE))
ui_count = len(re.findall(r"^\s*func test\w+\(", pathlib.Path(
    "SkincareInventoryUITests/SkincareInventoryUITests.swift").read_text(encoding="utf-8"), re.MULTILINE))
if (native_count, ui_count) != (7, 6):
    raise SystemExit("Expected seven native tests and six UI tests; update the evidence contract when changing the suite.")
if summary.get("passedTests") != native_count + ui_count or summary.get("failedTests") != 0 or summary.get("skippedTests") != 0:
    raise SystemExit("The xcresult summary does not confirm all 13 native/UI tests passed without skips.")
screenshots = [path.relative_to(evidence).as_posix() for path in evidence.rglob("*")
               if path.is_file() and path.suffix.lower() == ".png"]
if not screenshots:
    raise SystemExit("The successful simulator run did not export its kept screenshot attachment.")
provenance = {
    "source_commit": os.environ.get("GITHUB_SHA", "local"),
    "native_tests_passed": native_count,
    "ui_tests_passed": ui_count,
    "simulator_udid": os.environ["SIMULATOR_UDID"],
    "xcode": "16.4",
    "runtime": "iOS 18.5",
    "screenshots": screenshots,
    "real_network_disconnect_and_reconnect": "not tested; native error callbacks were simulated",
    "real_trollstore_device": "not tested",
    "cloud_drive_upload": "not tested",
}
(evidence / "provenance.json").write_text(
    json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print("Verified simulator evidence: 7 native tests, 6 UI tests, {} screenshot(s).".format(len(screenshots)))
PY
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent \
  "$evidence_dir" "$artifact_dir/simulator-evidence.zip"

build_phase="arm64 release build"
echo "Building the arm64 device app"
xcodebuild build \
  -project SkincareInventory.xcodeproj \
  -scheme SkincareInventory \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedDataDevice \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  IPHONEOS_DEPLOYMENT_TARGET=14.0 \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  ENABLE_BITCODE=NO \
  MARKETING_VERSION="$app_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee "$log_dir/device-build.log"

app_path="$project_root/build/DerivedDataDevice/Build/Products/Release-iphoneos/SkincareInventory.app"
if [[ ! -d "$app_path" ]]; then
  echo "Expected app product was not produced: $app_path" >&2
  exit 1
fi

build_phase="ad hoc signing"
echo "Applying ad hoc signatures for TrollStore to replace"
if [[ -d "$app_path/Frameworks" ]]; then
  while IFS= read -r -d '' embedded_code; do
    /usr/bin/codesign --force --sign - --timestamp=none "$embedded_code"
  done < <(find "$app_path/Frameworks" -mindepth 1 -maxdepth 1 \
    \( -type f -name '*.dylib' -o -type d -name '*.framework' \) -print0)
fi
/usr/bin/codesign --force --sign - --timestamp=none "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1 | tee "$log_dir/codesign.log"

build_phase="IPA packaging"
echo "Packaging the IPA"
package_dir="$(mktemp -d "$project_root/build/package.XXXXXX")"
mkdir "$package_dir/Payload"
/usr/bin/ditto "$app_path" "$package_dir/Payload/SkincareInventory.app"
(
  cd "$package_dir"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent Payload "$ipa_path"
)

build_phase="IPA verification"
echo "Verifying package structure, Mach-O metadata and code signatures"
python3 scripts/verify_ipa.py "$ipa_path" \
  --bundle-id io.github.saimilai.skincareinventory \
  --version "$app_version" \
  --build "$build_number" \
  --report "$artifact_dir/validation.json" \
  2>&1 | tee "$log_dir/package-verification.log"
export APP_VERSION="$app_version" BUILD_NUMBER="$build_number" PYTHON_TEST_STATUS="$python_test_status"
export SIMULATOR_UDID="$simulator_udid" ARTIFACT_DIR="$artifact_dir"
build_phase="validation report"
python3 - <<'PY'
import json
import os
import pathlib
import subprocess

artifacts = pathlib.Path(os.environ["ARTIFACT_DIR"])
report = json.loads((artifacts / "validation.json").read_text(encoding="utf-8"))
evidence = json.loads((artifacts / "simulator-evidence" / "provenance.json").read_text(encoding="utf-8"))
commit = os.environ.get("GITHUB_SHA")
if not commit:
    try:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        commit = "local source (no Git commit)"
run_url = ""
if os.environ.get("GITHUB_REPOSITORY") and os.environ.get("GITHUB_RUN_ID"):
    run_url = "https://github.com/{}/actions/runs/{}".format(
        os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_RUN_ID"]
    )
lines = [
    "# 库存手记 IPA 验证报告",
    "",
    "- App 版本：{}（构建 {}）".format(os.environ["APP_VERSION"], os.environ["BUILD_NUMBER"]),
    "- 源码提交：{}".format(commit),
    "- Xcode：16.4；设备架构：arm64；最低系统：iOS 14.0。",
    "- 网页兼容测试：通过。",
    "- Python 单元测试：{}。".format(os.environ["PYTHON_TEST_STATUS"]),
    "- iOS 18.5 模拟器：{} 项原生单元测试、{} 项 UI 测试通过，无跳过；设备 UDID：{}。".format(
        evidence["native_tests_passed"], evidence["ui_tests_passed"], os.environ["SIMULATOR_UDID"]),
    "- 模拟器截图及 xcresult 摘要：simulator-evidence.zip；{} 张截图。".format(len(evidence["screenshots"])),
    "- IPA 结构、Info.plist、Mach-O 最低系统和 ad hoc 签名：通过。",
    "- IPA SHA-256：{}".format(report["sha256"]),
    "- 加载网站：https://skincare-k-test-20261115.pages.dev/",
    "",
    "断网提示与重试通过模拟原生网络错误回调验证；未实际切断网络后再联网。JSON/XLSX 桥接字节和系统分享界面已测试，未验证网盘上传成功。",
    "尚未在用户真实 iPhone / TrollStore 上验证安装、启动、备份分享及覆盖更新的数据保留。",
    "模拟器测试使用虚构库存；构建和安装包不含用户真实库存。",
    "",
    "安装后从原网页导出 JSON，再通过 App 导入。App 和 Safari 的本地库存独立，不能自动同步。",
]
if run_url:
    lines.extend(["", "完整构建与测试日志：{}".format(run_url)])
(artifacts / "test-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
(
  cd "$artifact_dir"
  /usr/bin/shasum -a 256 "$(basename "$ipa_path")" validation.json test-report.md simulator-evidence.zip > SHA256SUMS.txt
)
build_phase="complete"
echo "Built and verified: $ipa_path"
