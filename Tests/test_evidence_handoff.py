"""Reject partial or substituted simulator evidence before publishing an IPA."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "skincare_evidence_handoff", PROJECT_ROOT / "scripts/evidence_handoff.py"
)
handoff = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(handoff)


def openstep(value):
    if isinstance(value, dict):
        return "{ " + " ".join(openstep(k) + " = " + openstep(v) + ";" for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "(" + ",".join(openstep(item) for item in value) + ")"
    return json.dumps(value)


class EvidenceHandoffTests(unittest.TestCase):
    def setUp(self):
        scratch = PROJECT_ROOT / "build/evidence-tests"
        scratch.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="case-", dir=scratch)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.artifacts = self.root / "build/artifacts"
        self.evidence = self.artifacts / "simulator-evidence"
        self.logs = self.root / "build/logs"
        self.context = {
            "source_commit": "1" * 40, "run_id": "123", "run_attempt": "2",
            "app_version": "1.0.1", "build_number": "9",
        }
        for name, value in (("ROOT", self.root), ("ARTIFACTS", self.artifacts),
                            ("EVIDENCE", self.evidence), ("LOGS", self.logs)):
            patch = mock.patch.object(handoff, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(handoff, "context", return_value=self.context)
        patch.start()
        self.addCleanup(patch.stop)
        self.objects = {
            "project": {"mainGroup": "root"},
            "root": {"isa": "PBXGroup", "children": ["native-group", "ui-group"]},
            "native-group": {"isa": "PBXGroup", "path": "SkincareInventoryTests",
                             "sourceTree": "<group>", "children": ["native-ref"]},
            "ui-group": {"isa": "PBXGroup", "path": "SkincareInventoryUITests",
                         "sourceTree": "<group>", "children": ["ui-ref"]},
            "native-ref": {"isa": "PBXFileReference", "path": "SkincareInventoryTests.swift",
                           "sourceTree": "<group>"},
            "ui-ref": {"isa": "PBXFileReference", "path": "SkincareInventoryUITests.swift",
                       "sourceTree": "<group>"},
            "native-build": {"isa": "PBXBuildFile", "fileRef": "native-ref"},
            "ui-build": {"isa": "PBXBuildFile", "fileRef": "ui-ref"},
            "native-sources": {"isa": "PBXSourcesBuildPhase", "files": ["native-build"]},
            "ui-sources": {"isa": "PBXSourcesBuildPhase", "files": ["ui-build"]},
            "native-target": {"isa": "PBXNativeTarget", "buildPhases": ["native-sources"],
                              "productType": "com.apple.product-type.bundle.unit-test"},
            "ui-target": {"isa": "PBXNativeTarget", "buildPhases": ["ui-sources"],
                          "productType": "com.apple.product-type.bundle.ui-testing"},
        }
        for kind, directory in (("native", "SkincareInventoryTests"), ("ui", "SkincareInventoryUITests")):
            methods = sorted(case.split("/")[1][:-2] for case in handoff.BASELINE_CASES[kind])
            source = "import XCTest\nfinal class " + directory + ": XCTestCase {\n"
            source += "\n".join("    func " + name + "() {}" for name in methods) + "\n}\n"
            self.write(directory + "/" + directory + ".swift", source)
        self.write_project()

    def write(self, relative, contents):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def write_project(self):
        return self.write("SkincareInventory.xcodeproj/project.pbxproj", "// !$*UTF8*$!\n" + openstep({
            "objects": self.objects, "rootObject": "project",
        }))

    def add_update_tests(self, register=True):
        self.write("SkincareInventoryTests/AppUpdateServiceTests.swift", """
import XCTest
final class AppUpdateServiceTests: XCTestCase {
    func testNewerVersion() throws {}
    // func testCommentMustNotCount() {}
    /* func testBlockCommentMustNotCount() {} */
    func testCorruptDownload() { let diagnostic = "func testStringMustNotCount() {}" }
}
""")
        if register:
            self.objects["native-group"]["children"].append("update-ref")
            self.objects["native-sources"]["files"].append("update-build")
            self.objects["update-ref"] = {"isa": "PBXFileReference", "sourceTree": "<group>",
                                          "path": "AppUpdateServiceTests.swift"}
            self.objects["update-build"] = {"isa": "PBXBuildFile", "fileRef": "update-ref"}
            self.write_project()

    def results(self):
        inventory = handoff.suite_inventory()
        identifiers = inventory["native"] + inventory["ui"]
        summary = {"passedTests": len(identifiers), "failedTests": 0, "skippedTests": 0}
        tests = {"testNodes": [{"children": [
            {"nodeType": "Test Case", "nodeIdentifier": item, "result": "Passed"}
            for item in identifiers
        ]}]}
        return summary, tests

    def prepare_fixture(self):
        summary, tests = self.results()
        handoff.write_json(self.evidence / "summary.json", summary)
        handoff.write_json(self.evidence / "tests.json", tests)
        self.write("build/artifacts/simulator-evidence/attachments/safe-area.png", "")
        (self.evidence / "attachments/safe-area.png").write_bytes(b"\x89PNG\r\n\x1a\nfixture")
        self.write("build/logs/web-tests.log",
                   "# tests 20\n# pass 20\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n")
        self.write("build/logs/python-tests.log", "Ran 19 tests in 0.1s\n\nOK\n")
        self.write("build/logs/toolchain.log", "Xcode 16.4\nBuild version 16F6\n")
        with mock.patch.dict("os.environ", {"SIMULATOR_UDID": "fixture-device"}), contextlib.redirect_stdout(io.StringIO()):
            handoff.prepare()
        self.package_fixture()

    def package_fixture(self):
        with zipfile.ZipFile(self.artifacts / "simulator-evidence.zip", "w") as archive:
            for path in sorted(self.evidence.rglob("*")):
                if path.is_file():
                    archive.write(path, "simulator-evidence/" + path.relative_to(self.evidence).as_posix())
        handoff.manifest()

    def test_registered_update_tests_extend_complete_inventory(self):
        self.add_update_tests()
        self.assertEqual(handoff.suite_counts(), (9, 6))
        inventory = handoff.suite_inventory()
        self.assertIn("AppUpdateServiceTests/testNewerVersion()", inventory["native"])
        self.assertFalse(any("MustNotCount" in case for cases in inventory.values() for case in cases))

    def test_new_test_source_omitted_from_build_phase_is_rejected(self):
        self.add_update_tests(register=False)
        with self.assertRaisesRegex(ValueError, "not registered"):
            handoff.suite_inventory()

    def test_removing_original_case_is_rejected(self):
        path = self.root / "SkincareInventoryTests/SkincareInventoryTests.swift"
        path.write_text(path.read_text().replace("func testOnlyExactHTTPSOriginIsTrusted() {}", ""))
        with self.assertRaisesRegex(ValueError, "original seven native"):
            handoff.suite_inventory()

    def test_duplicate_class_method_across_files_is_rejected(self):
        self.add_update_tests()
        path = self.root / "SkincareInventoryTests/AppUpdateServiceTests.swift"
        path.write_text("class SkincareInventoryTests: XCTestCase { func testOnlyExactHTTPSOriginIsTrusted() {} }")
        with self.assertRaisesRegex(ValueError, "Duplicated test identifiers"):
            handoff.suite_inventory()

    def test_same_file_in_both_test_targets_is_rejected(self):
        self.objects["ui-sources"]["files"].append("native-build")
        self.write_project()
        with self.assertRaisesRegex(ValueError, "registered more than once"):
            handoff.suite_inventory()

    def test_source_path_outside_checkout_is_rejected(self):
        self.objects["native-ref"]["path"] = "../../../outside.swift"
        self.write_project()
        with self.assertRaisesRegex(ValueError, "escapes"):
            handoff.suite_inventory()

    def test_complete_individual_results_are_accepted(self):
        self.add_update_tests()
        self.assertEqual(handoff.check_summary(*self.results()), (9, 6))

    def test_substituted_case_with_same_total_is_rejected(self):
        summary, tests = self.results()
        tests["testNodes"][0]["children"][0]["nodeIdentifier"] = "SubstitutedTests/testUnrelated()"
        with self.assertRaisesRegex(ValueError, "exactly match"):
            handoff.check_summary(summary, tests)

    def test_duplicated_individual_result_is_rejected(self):
        summary, tests = self.results()
        children = tests["testNodes"][0]["children"]
        children[0] = children[1].copy()
        with self.assertRaisesRegex(ValueError, "exactly match"):
            handoff.check_summary(summary, tests)

    def test_summary_success_cannot_hide_failed_case(self):
        summary, tests = self.results()
        tests["testNodes"][0]["children"][0]["result"] = "Failed"
        with self.assertRaisesRegex(ValueError, "did not pass"):
            handoff.check_summary(summary, tests)

    def test_skips_are_rejected_even_when_all_cases_are_present(self):
        summary, tests = self.results()
        summary["skippedTests"] = 1
        with self.assertRaisesRegex(ValueError, "no failures or skips"):
            handoff.check_summary(summary, tests)

    def test_parameterized_or_extension_test_methods_fail_closed(self):
        for source in (
            "class A: XCTestCase { func testCase(value: Int) {} }",
            "extension A { func testCase() {} }",
        ):
            with self.subTest(source=source), self.assertRaises(ValueError):
                handoff.swift_test_cases(source)

    def test_same_run_archive_round_trip_records_complete_case_inventory(self):
        self.add_update_tests()
        self.prepare_fixture()
        with contextlib.redirect_stdout(io.StringIO()):
            provenance = handoff.verify()
        self.assertEqual(provenance["schema_version"], 2)
        self.assertEqual(provenance["test_inventory"], handoff.suite_inventory())
        self.assertEqual((provenance["native_tests_passed"], provenance["ui_tests_passed"]), (9, 6))

    def test_repacked_archive_with_reduced_provenance_inventory_is_rejected(self):
        self.prepare_fixture()
        provenance_path = self.evidence / "provenance.json"
        provenance = handoff.read_json(provenance_path)
        provenance["test_inventory"]["native"].pop()
        handoff.write_json(provenance_path, provenance)
        self.package_fixture()
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            handoff.verify()

    def test_repacked_archive_with_replaced_individual_results_is_rejected(self):
        self.prepare_fixture()
        tests_path = self.evidence / "tests.json"
        tests = handoff.read_json(tests_path)
        tests["testNodes"][0]["children"][0]["nodeIdentifier"] = "Other/testCase()"
        handoff.write_json(tests_path, tests)
        self.package_fixture()
        with self.assertRaisesRegex(ValueError, "exactly match"):
            handoff.verify()

    def test_evidence_from_other_run_attempt_is_rejected(self):
        self.prepare_fixture()
        manifest_path = self.artifacts / "handoff-manifest.json"
        manifest = handoff.read_json(manifest_path)
        manifest["run_attempt"] = "1"
        handoff.write_json(manifest_path, manifest)
        with self.assertRaisesRegex(ValueError, "this checkout"):
            handoff.verify()

    def test_release_report_keeps_dynamic_counts_and_device_install_limits(self):
        self.add_update_tests()
        self.prepare_fixture()
        handoff.write_json(self.artifacts / "validation.json", {"sha256": "2" * 64})
        with contextlib.redirect_stdout(io.StringIO()):
            handoff.report()
        report = (self.artifacts / "test-report.md").read_text(encoding="utf-8")
        self.assertIn("9 项原生单元测试、6 项 UI 测试通过", report)
        self.assertIn("官方 TrollStore 2.1.1", report)
        self.assertIn("版本、文件大小和 SHA-256", report)
        self.assertIn("系统 Open In 文件菜单", report)
        self.assertIn("模拟器不执行安装助手或 root 安装", report)
        self.assertIn("旧进程关闭后安装子进程能否继续完成", report)
        self.assertIn("相同数据容器和库存能否保留", report)
        self.assertIn("均待用户巨魔设备实测", report)


if __name__ == "__main__":
    unittest.main()
