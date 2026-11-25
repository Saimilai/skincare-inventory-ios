#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$project_root"
build_mode="${1:-${MODE:-all}}"
case "$build_mode" in
  test|build|all) ;;
  *) echo "Usage: MODE=test|build|all bash scripts/build_ipa.sh [test|build|all]" >&2; exit 1 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This build requires macOS and Xcode." >&2
  exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_16.4.app/Contents/Developer}"
export APP_VERSION="${APP_VERSION:-1.0.0}"
export BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "APP_VERSION must be x.y.z; BUILD_NUMBER must be a positive integer." >&2
  exit 1
fi
if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Required Xcode 16.4 is missing: $DEVELOPER_DIR" >&2
  exit 1
fi

artifact_dir="$project_root/build/artifacts"
log_dir="$project_root/build/logs"
evidence_dir="$artifact_dir/simulator-evidence"
result_bundle="$project_root/build/TestResults.xcresult"
ipa_path="$artifact_dir/SkincareInventory-${APP_VERSION}-TrollStore.ipa"
package_dir=""
build_phase="toolchain checks"
mkdir -p "$artifact_dir" "$log_dir"

print_failure_diagnostics() {
  echo "::error::IPA $build_mode failed during: $build_phase"
  if [[ -s "$log_dir/simulator-tests.log" ]]; then
    grep -Ei 'error:|failed|failure|XCTAssert|timed out|cancelled|SpringBoard|NSPOSIXError' \
      "$log_dir/simulator-tests.log" | tail -n 12 || true
  fi
  if [[ -d "$result_bundle" ]]; then
    if xcrun xcresulttool get test-results summary --path "$result_bundle" --compact \
      > "$log_dir/failure-summary.json" 2> "$log_dir/failure-summary.log"; then
      python3 - "$log_dir/failure-summary.json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
compact = {key: summary[key] for key in (
    "result", "testResults", "totalTestCount", "passedTests", "failedTests", "skippedTests"
) if key in summary}
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
  if [[ "$exit_status" -ne 0 ]]; then print_failure_diagnostics; fi
  if [[ -n "$package_dir" && "$package_dir" == "$project_root"/build/package.* ]]; then
    rm -rf -- "$package_dir"
  fi
  exit "$exit_status"
}
trap finish_build EXIT

xcodebuild -version | tee "$log_dir/toolchain.log"
if ! xcodebuild -version | head -n 1 | grep -Fxq "Xcode 16.4"; then
  echo "The selected toolchain must be Xcode 16.4." >&2
  exit 1
fi
python3 --version | tee -a "$log_dir/toolchain.log"

run_tests() {
  if [[ -e "$result_bundle" ]]; then
    echo "A prior TestResults.xcresult exists. Use a clean checkout." >&2
    return 1
  fi
  build_phase="web compatibility tests"
  node --version | tee -a "$log_dir/toolchain.log"
  node --test Tests/web-compatibility.test.js 2>&1 | tee "$log_dir/web-tests.log"
  build_phase="Python unit tests"
  python3 -m unittest discover -s Tests -p 'test_*.py' -v 2>&1 | tee "$log_dir/python-tests.log"

  build_phase="serial simulator startup"
  echo "Selecting and fully booting iOS 18.5 before compiling"
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
    sys.exit("No available iOS 18.5 iPhone simulator.")
print(sorted(devices, key=lambda item: (item["name"], item["udid"]))[0]["udid"])
PY
)"
  export SIMULATOR_UDID="$simulator_udid"
  printf '%s\n' "$simulator_udid" | tee "$log_dir/simulator-udid.log"
  xcrun simctl bootstatus "$simulator_udid" -b 2>&1 | tee "$log_dir/simulator-boot.log"

  build_phase="native and UI simulator tests"
  xcodebuild test \
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
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    2>&1 | tee "$log_dir/simulator-tests.log"

  build_phase="simulator evidence export"
  mkdir -p "$evidence_dir"
  xcrun xcresulttool get test-results summary --path "$result_bundle" > "$evidence_dir/summary.json"
  xcrun xcresulttool get test-results tests --path "$result_bundle" > "$evidence_dir/tests.json"
  xcrun xcresulttool export attachments --path "$result_bundle" \
    --output-path "$evidence_dir/attachments" 2>&1 | tee "$log_dir/simulator-evidence.log"
  python3 scripts/evidence_handoff.py prepare
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent \
    "$evidence_dir" "$artifact_dir/simulator-evidence.zip"
  python3 scripts/evidence_handoff.py manifest
  python3 scripts/evidence_handoff.py verify
  echo "Test handoff ready: simulator-evidence.zip and handoff-manifest.json"
}

build_package() {
  build_phase="same-run test evidence verification"
  python3 scripts/evidence_handoff.py verify

  build_phase="arm64 release build"
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
    MARKETING_VERSION="$APP_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    2>&1 | tee "$log_dir/device-build.log"

  app_path="$project_root/build/DerivedDataDevice/Build/Products/Release-iphoneos/SkincareInventory.app"
  if [[ ! -d "$app_path" ]]; then
    echo "Expected app was not produced: $app_path" >&2
    return 1
  fi
  build_phase="ad hoc signing"
  if [[ -d "$app_path/Frameworks" ]]; then
    while IFS= read -r -d '' embedded_code; do
      /usr/bin/codesign --force --sign - --timestamp=none "$embedded_code"
    done < <(find "$app_path/Frameworks" -mindepth 1 -maxdepth 1 \
      \( -type f -name '*.dylib' -o -type d -name '*.framework' \) -print0)
  fi
  /usr/bin/codesign --force --sign - --timestamp=none "$app_path"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path" 2>&1 | tee "$log_dir/codesign.log"

  build_phase="IPA packaging"
  package_dir="$(mktemp -d "$project_root/build/package.XXXXXX")"
  mkdir "$package_dir/Payload"
  /usr/bin/ditto "$app_path" "$package_dir/Payload/SkincareInventory.app"
  (
    cd "$package_dir"
    /usr/bin/ditto -c -k --norsrc --noextattr --keepParent Payload "$ipa_path"
  )
  build_phase="IPA verification"
  python3 scripts/verify_ipa.py "$ipa_path" \
    --bundle-id io.github.saimilai.skincareinventory \
    --version "$APP_VERSION" \
    --build "$BUILD_NUMBER" \
    --report "$artifact_dir/validation.json" \
    2>&1 | tee "$log_dir/package-verification.log"
  build_phase="validation report"
  python3 scripts/evidence_handoff.py report
  build_phase="source archive"
  git archive --format=zip --prefix="skincare-inventory-ios-${APP_VERSION}/" \
    --output="$artifact_dir/SkincareInventory-${APP_VERSION}-source.zip" HEAD
  (
    cd "$artifact_dir"
    /usr/bin/shasum -a 256 "$(basename "$ipa_path")" "SkincareInventory-${APP_VERSION}-source.zip" \
      validation.json test-report.md simulator-evidence.zip > SHA256SUMS.txt
  )
  echo "Built and verified: $ipa_path"
}

if [[ "$build_mode" == test || "$build_mode" == all ]]; then run_tests; fi
if [[ "$build_mode" == build || "$build_mode" == all ]]; then build_package; fi
build_phase="complete"
