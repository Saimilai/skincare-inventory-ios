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

echo "Checking Xcode, Node and Python"
xcodebuild -version | tee "$log_dir/toolchain.log"
if ! xcodebuild -version | head -n 1 | grep -Fxq "Xcode 16.4"; then
  echo "The selected toolchain must be Xcode 16.4." >&2
  exit 1
fi
node --version | tee -a "$log_dir/toolchain.log"
python3 --version | tee -a "$log_dir/toolchain.log"

echo "Running web compatibility tests"
node --test Tests/web-compatibility.test.js 2>&1 | tee "$log_dir/web-tests.log"

python_test_status="not configured"
if compgen -G "Tests/test_*.py" >/dev/null; then
  echo "Running Python unit tests"
  python3 -m unittest discover -s Tests -p 'test_*.py' -v 2>&1 | tee "$log_dir/python-tests.log"
  python_test_status="passed"
fi

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
xcrun simctl bootstatus "$simulator_udid" -b 2>&1 | tee "$log_dir/simulator-boot.log"

echo "Running simulator UI tests"
xcodebuild test \
  -project SkincareInventory.xcodeproj \
  -scheme SkincareInventory \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=${simulator_udid}" \
  -derivedDataPath build/DerivedDataSimulator \
  -resultBundlePath build/TestResults.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  IPHONEOS_DEPLOYMENT_TARGET=14.0 \
  MARKETING_VERSION="$app_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  2>&1 | tee "$log_dir/simulator-tests.log"

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

echo "Applying ad hoc signatures for TrollStore to replace"
if [[ -d "$app_path/Frameworks" ]]; then
  while IFS= read -r -d '' embedded_code; do
    /usr/bin/codesign --force --sign - --timestamp=none "$embedded_code"
  done < <(find "$app_path/Frameworks" -mindepth 1 -maxdepth 1 \
    \( -type f -name '*.dylib' -o -type d -name '*.framework' \) -print0)
fi
/usr/bin/codesign --force --sign - --timestamp=none "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1 | tee "$log_dir/codesign.log"

echo "Packaging the IPA"
package_dir="$(mktemp -d "$project_root/build/package.XXXXXX")"
trap '[[ -n "${package_dir:-}" ]] && [[ "$package_dir" == "$project_root"/build/package.* ]] && rm -rf -- "$package_dir"' EXIT
mkdir "$package_dir/Payload"
/usr/bin/ditto "$app_path" "$package_dir/Payload/SkincareInventory.app"
(
  cd "$package_dir"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent Payload "$ipa_path"
)

echo "Verifying package structure, Mach-O metadata and code signatures"
python3 scripts/verify_ipa.py "$ipa_path" \
  --bundle-id io.github.saimilai.skincareinventory \
  --version "$app_version" \
  --build "$build_number" \
  --report "$artifact_dir/validation.json" \
  2>&1 | tee "$log_dir/package-verification.log"
export APP_VERSION="$app_version" BUILD_NUMBER="$build_number" PYTHON_TEST_STATUS="$python_test_status"
export SIMULATOR_UDID="$simulator_udid" ARTIFACT_DIR="$artifact_dir"
python3 - <<'PY'
import json
import os
import pathlib
import subprocess

artifacts = pathlib.Path(os.environ["ARTIFACT_DIR"])
report = json.loads((artifacts / "validation.json").read_text(encoding="utf-8"))
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
    "- iOS 18.5 模拟器 UI 测试：通过；设备 UDID：{}。".format(os.environ["SIMULATOR_UDID"]),
    "- IPA 结构、Info.plist、Mach-O 最低系统和 ad hoc 签名：通过。",
    "- IPA SHA-256：{}".format(report["sha256"]),
    "- 加载网站：https://skincare-k-test-20261115.pages.dev/",
    "",
    "此报告验证云端构建产物和模拟器行为。尚未在用户真实 iPhone / TrollStore 上验证安装、启动、备份分享及覆盖更新的数据保留。",
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
  /usr/bin/shasum -a 256 "$(basename "$ipa_path")" validation.json test-report.md > SHA256SUMS.txt
)
echo "Built and verified: $ipa_path"
