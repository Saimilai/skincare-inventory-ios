"""Exercise the IPA validator with device-shaped binary fixtures, without an SDK."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import warnings
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "skincare_verify_ipa", PROJECT_ROOT / "scripts" / "verify_ipa.py"
)
verify_ipa = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verify_ipa)


def device_executable(
    *,
    target_platform=2,
    minimum=14 << 16,
    sdk=(18 << 16) | (5 << 8),
    cpu_type=0x0100000C,
    cpu_subtype=0,
    signature=True,
    legacy_version=False,
):
    # Include an unrelated command and the Xcode 16.4 linker-tool tuple, so the
    # parser is tested against variable command sizes rather than just two tags.
    commands = [struct.pack("<II16s", 0x1B, 24, bytes(16))]
    if legacy_version:
        commands.append(struct.pack("<IIII", 0x25, 16, minimum, sdk))
    else:
        commands.append(
            struct.pack(
                "<IIIIIIII", 0x32, 32, target_platform, minimum, sdk, 1, 3, 0x04570200
            )
        )
    if signature:
        signature_offset = 32 + sum(len(command) for command in commands) + 16
        commands.append(struct.pack("<IIII", 0x1D, 16, signature_offset, 32))
    command_bytes = b"".join(commands)
    header = struct.pack(
        "<IiiIIIII",
        0xFEEDFACF,
        cpu_type,
        cpu_subtype,
        2,
        len(commands),
        len(command_bytes),
        0,
        0,
    )
    return header + command_bytes + (bytes(32) if signature else b"")


class IPAValidationTests(unittest.TestCase):
    def setUp(self):
        fixture_root = PROJECT_ROOT / "build" / "validator-tests"
        fixture_root.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="case-", dir=fixture_root)
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.ipa = self.directory / "fixture.ipa"

    def make_ipa(
        self,
        *,
        info_overrides=None,
        executable=None,
        executable_mode=0o755,
        app_name="SkincareInventory.app",
        executable_name="SkincareInventory",
        extra_entries=(),
        binary_plist=True,
        include_seal=True,
        malformed_plist=False,
    ):
        info = {
            "CFBundlePackageType": "APPL",
            "CFBundleIdentifier": "io.github.saimilai.skincareinventory",
            "CFBundleShortVersionString": "1.0.1",
            "CFBundleVersion": "27",
            "MinimumOSVersion": "14.0",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
            "UIDeviceFamily": [1, 2],
            "CFBundleExecutable": executable_name,
            # Processed Xcode metadata is informational and may change.
            "DTXcode": "1640",
            "DTSDKName": "iphoneos18.5",
            "DTPlatformVersion": "18.5",
            "BuildMachineOSBuild": "24F74",
        }
        info.update(info_overrides or {})
        prefix = "Payload/" + app_name
        with zipfile.ZipFile(self.ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Payload/", b"")
            archive.writestr(prefix + "/", b"")
            plist_data = (
                b"not a plist"
                if malformed_plist
                else plistlib.dumps(info, fmt=plistlib.FMT_BINARY if binary_plist else plistlib.FMT_XML)
            )
            archive.writestr(prefix + "/Info.plist", plist_data)
            entry = zipfile.ZipInfo(prefix + "/" + executable_name)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | executable_mode) << 16
            archive.writestr(entry, executable if executable is not None else device_executable())
            if include_seal:
                archive.writestr(prefix + "/_CodeSignature/CodeResources", b"unit-test seal")
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                for name, contents in extra_entries:
                    archive.writestr(name, contents)
        return self.ipa

    def inspect(self, **kwargs):
        return verify_ipa.inspect_ipa(self.ipa, expected_build="27", verify_signature=False, **kwargs)

    def test_xcode_164_device_metadata_and_binary_plist_are_accepted(self):
        self.make_ipa()
        report = self.inspect()
        self.assertEqual(report["status"], "static_checks_passed")
        self.assertEqual(report["build"], "27")
        self.assertEqual(report["minimum_ios"], "14.0")
        self.assertEqual(report["macho"]["minimum_ios"], "14.0.0")
        self.assertEqual(report["macho"]["sdk"], "18.5.0")
        self.assertTrue(report["macho"]["embedded_code_signature"])
        self.assertEqual(report["signature"]["status"], "not_run")
        self.assertEqual(report["sha256"], hashlib.sha256(self.ipa.read_bytes()).hexdigest())

    def test_app_and_executable_names_and_unrelated_sdk_metadata_can_change(self):
        self.make_ipa(
            app_name="库存手记.app",
            executable_name="InventoryClient",
            info_overrides={"DTSDKName": "iphoneos19.0", "DTXcode": "1700"},
            executable=device_executable(sdk=19 << 16),
            binary_plist=False,
        )
        report = self.inspect()
        self.assertEqual(report["app_folder"], "Payload/库存手记.app")
        self.assertEqual(report["macho"]["sdk"], "19.0.0")

    def test_legacy_iphoneos_minimum_version_command_is_accepted(self):
        self.make_ipa(executable=device_executable(legacy_version=True))
        self.assertEqual(self.inspect()["macho"]["minimum_ios"], "14.0.0")

    def test_invalid_build_values_are_rejected_after_re_fullmatch(self):
        for value in (None, 27, "", "0", "-1", "27x", "1.0"):
            with self.subTest(value=value):
                self.make_ipa(info_overrides={"CFBundleVersion": value} if value is not None else {"CFBundleVersion": ""})
                with self.assertRaisesRegex(verify_ipa.VerificationError, "build number"):
                    self.inspect()

    def test_mismatched_expected_build_is_rejected(self):
        self.make_ipa()
        with self.assertRaisesRegex(verify_ipa.VerificationError, "build number"):
            verify_ipa.inspect_ipa(self.ipa, expected_build="28", verify_signature=False)

    def test_wrong_bundle_identifier_and_release_version_are_rejected(self):
        for field, value, message in (
            ("CFBundleIdentifier", "other.app", "bundle identifier"),
            ("CFBundleShortVersionString", "2.0.0", "release version"),
        ):
            with self.subTest(field=field):
                self.make_ipa(info_overrides={field: value})
                with self.assertRaisesRegex(verify_ipa.VerificationError, message):
                    self.inspect()

    def test_simulator_macho_is_rejected_even_with_device_plist(self):
        self.make_ipa(executable=device_executable(target_platform=7))
        with self.assertRaisesRegex(verify_ipa.VerificationError, "platform other than device"):
            self.inspect()

    def test_simulator_plist_is_rejected_even_with_arm64_device_macho(self):
        self.make_ipa(info_overrides={"CFBundleSupportedPlatforms": ["iPhoneSimulator"]})
        with self.assertRaisesRegex(verify_ipa.VerificationError, "iPhoneOS device"):
            self.inspect()

    def test_arm64e_and_x86_executables_are_rejected(self):
        for options in ({"cpu_subtype": 2}, {"cpu_type": 0x01000007}):
            with self.subTest(options=options):
                self.make_ipa(executable=device_executable(**options))
                with self.assertRaisesRegex(verify_ipa.VerificationError, "standard arm64"):
                    self.inspect()

    def test_disagreeing_macho_and_plist_minimum_versions_are_rejected(self):
        self.make_ipa(executable=device_executable(minimum=15 << 16))
        with self.assertRaisesRegex(verify_ipa.VerificationError, "versions disagree"):
            self.inspect()

    def test_wrong_or_non_string_minimum_plist_versions_are_rejected(self):
        for value in ("15.0", 14, "invalid"):
            with self.subTest(value=value):
                self.make_ipa(info_overrides={"MinimumOSVersion": value})
                with self.assertRaises(verify_ipa.VerificationError):
                    self.inspect()

    def test_execute_permissions_and_resource_seal_are_required(self):
        self.make_ipa(executable_mode=0o644)
        with self.assertRaisesRegex(verify_ipa.VerificationError, "permission"):
            self.inspect()
        self.make_ipa(include_seal=False)
        with self.assertRaisesRegex(verify_ipa.VerificationError, "resource seal"):
            self.inspect()

    def test_missing_or_truncated_embedded_signature_is_rejected(self):
        self.make_ipa(executable=device_executable(signature=False))
        with self.assertRaisesRegex(verify_ipa.VerificationError, "no embedded"):
            self.inspect()
        self.make_ipa(executable=device_executable()[:-1])
        with self.assertRaisesRegex(verify_ipa.VerificationError, "extends beyond"):
            self.inspect()

    def test_truncated_or_invalid_macho_commands_are_rejected(self):
        executable = bytearray(device_executable())
        struct.pack_into("<I", executable, 36, 4)
        for data in (b"short", bytes(executable), device_executable()[:40]):
            with self.subTest(length=len(data)):
                self.make_ipa(executable=data)
                with self.assertRaises(verify_ipa.VerificationError):
                    self.inspect()

    def test_zip_path_traversal_and_second_app_are_rejected(self):
        for name in ("Payload/../escape", "/Payload/absolute", "Payload/Second.app/Info.plist"):
            with self.subTest(name=name):
                self.make_ipa(extra_entries=[(name, b"unexpected")])
                with self.assertRaises(verify_ipa.VerificationError):
                    self.inspect()

    def test_duplicate_members_and_symlinks_are_rejected(self):
        self.make_ipa(extra_entries=[("Payload/SkincareInventory.app/Info.plist", b"duplicate")])
        with self.assertRaisesRegex(verify_ipa.VerificationError, "Duplicate"):
            self.inspect()
        symlink = zipfile.ZipInfo("Payload/SkincareInventory.app/unsafe-link")
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.make_ipa(extra_entries=[(symlink, b"/outside")])
        with self.assertRaisesRegex(verify_ipa.VerificationError, "Symbolic links"):
            self.inspect()

    def test_malformed_plist_is_reported_as_verification_error(self):
        self.make_ipa(malformed_plist=True)
        with self.assertRaisesRegex(verify_ipa.VerificationError, "Info.plist"):
            self.inspect()

    def test_formal_signature_verification_cannot_run_on_windows(self):
        self.make_ipa()
        with mock.patch.object(verify_ipa.platform, "system", return_value="Windows"):
            with self.assertRaisesRegex(verify_ipa.VerificationError, "requires macOS"):
                verify_ipa.inspect_ipa(self.ipa)

    def signature_results(self, entitlements=None, *, raw=None, dump_status=0):
        value = entitlements if entitlements is not None else {
            **verify_ipa.REQUIRED_UPDATE_ENTITLEMENTS,
            "application-identifier": "io.github.saimilai.skincareinventory",
        }
        payload = plistlib.dumps(value) if raw is None else raw
        return [
            subprocess.CompletedProcess([], 0, "", "valid on disk\nsatisfies its Designated Requirement"),
            subprocess.CompletedProcess([], 0, "", "Signature=adhoc\nIdentifier=io.github.saimilai.skincareinventory"),
            subprocess.CompletedProcess([], dump_status, payload, b"Executable=/temporary/SkincareInventory"),
        ]

    def inspect_with_codesign_mock(self, responses):
        with mock.patch.object(verify_ipa.platform, "system", return_value="Darwin"), \
             mock.patch.object(verify_ipa.subprocess, "run", side_effect=responses):
            return verify_ipa.inspect_ipa(self.ipa, expected_build="27")

    def test_signed_update_entitlements_are_exported_and_verified(self):
        self.make_ipa()
        report = self.inspect_with_codesign_mock(self.signature_results())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["signature"]["entitlements_status"], "passed")
        self.assertTrue(report["signature"]["entitlements"]["com.apple.private.persona-mgmt"])
        self.assertEqual(report["signature"]["self_update_execution_on_device"], "not tested")
        self.assertFalse(report["package_code"]["embedded_root_helpers"])
        self.assertEqual(len(report["package_code"]["mach_o_binaries"]), 1)

    def test_signing_source_entitlements_match_reviewed_allowlist(self):
        value = plistlib.loads((PROJECT_ROOT / "SkincareInventory/Update.entitlements").read_bytes())
        self.assertEqual(verify_ipa.validate_update_entitlements(
            value, "io.github.saimilai.skincareinventory"), value)

    def test_missing_or_non_boolean_update_permissions_are_rejected(self):
        self.make_ipa()
        expected = {**verify_ipa.REQUIRED_UPDATE_ENTITLEMENTS,
                    "application-identifier": "io.github.saimilai.skincareinventory"}
        for key in verify_ipa.REQUIRED_UPDATE_ENTITLEMENTS:
            for bad_value in (None, False, 1, "true"):
                with self.subTest(key=key, value=bad_value):
                    value = expected.copy()
                    if bad_value is None:
                        del value[key]
                    else:
                        value[key] = bad_value
                    with self.assertRaisesRegex(verify_ipa.VerificationError, "entitlements"):
                        self.inspect_with_codesign_mock(self.signature_results(value))

    def test_no_container_and_unreviewed_privileges_are_rejected(self):
        self.make_ipa()
        expected = {**verify_ipa.REQUIRED_UPDATE_ENTITLEMENTS,
                    "application-identifier": "io.github.saimilai.skincareinventory"}
        for key, flag in (
            ("com.apple.private.security.no-container", True),
            ("com.apple.private.security.container-required", False),
            ("com.apple.private.MobileContainerManager.allowed", True),
            ("com.apple.private.security.storage.AppBundles", True),
            ("com.apple.security.exception.files.absolute-path.read-write", ["/"]),
        ):
            with self.subTest(key=key), self.assertRaisesRegex(verify_ipa.VerificationError, "allowlist"):
                self.inspect_with_codesign_mock(self.signature_results({**expected, key: flag}))

    def test_wrong_signed_application_identifier_is_rejected(self):
        self.make_ipa()
        for identifier in ("other.app", "TEAM.io.github.saimilai.skincareinventory", ""):
            with self.subTest(identifier=identifier), self.assertRaisesRegex(
                verify_ipa.VerificationError, "application identifier"
            ):
                self.inspect_with_codesign_mock(self.signature_results({
                    **verify_ipa.REQUIRED_UPDATE_ENTITLEMENTS, "application-identifier": identifier,
                }))

    def test_missing_malformed_or_non_dictionary_codesign_entitlements_are_rejected(self):
        self.make_ipa()
        for payload in (b"", b"not a plist", plistlib.dumps(["unexpected"]),
                        b"codesign warning\n" + plistlib.dumps({})):
            with self.subTest(payload=payload[:20]), self.assertRaisesRegex(
                verify_ipa.VerificationError, "entitlements"
            ):
                self.inspect_with_codesign_mock(self.signature_results(raw=payload))
        with self.assertRaisesRegex(verify_ipa.VerificationError, "could not export"):
            self.inspect_with_codesign_mock(self.signature_results(dump_status=1))

    def test_trollstore_root_binary_declarations_are_rejected(self):
        for key in ("TSRootBinaries", "TSRootExecutables", "TSRootBinary"):
            with self.subTest(key=key):
                self.make_ipa(info_overrides={key: ["RootHelper"]})
                with self.assertRaisesRegex(verify_ipa.VerificationError, "embedded TrollStore root helper"):
                    self.inspect()

    def test_second_macho_is_rejected_regardless_of_filename_or_architecture(self):
        for magic in verify_ipa.MACHO_MAGICS:
            with self.subTest(magic=magic.hex()):
                self.make_ipa(extra_entries=[("Payload/SkincareInventory.app/Assets/hidden.png", magic + bytes(32))])
                with self.assertRaisesRegex(verify_ipa.VerificationError, "additional Mach-O"):
                    self.inspect()

    def test_non_code_assets_are_accepted_without_claiming_entitlements_checked(self):
        self.make_ipa(extra_entries=[
            ("Payload/SkincareInventory.app/Assets.car", b"ASSETDATA\x00fixture"),
            ("Payload/SkincareInventory.app/AppIcon60x60@2x.png", b"\x89PNG\r\n\x1a\nfixture"),
            ("Payload/SkincareInventory.app/WebCompatibility.js", b"(function () {})();"),
        ])
        report = self.inspect()
        self.assertEqual(report["signature"]["entitlements_status"], "not_run")
        self.assertEqual(report["signature"]["self_update_execution_on_device"], "not tested")
        self.assertFalse(report["package_code"]["embedded_root_helpers"])

    def test_cli_persists_failure_report_and_returns_nonzero(self):
        self.make_ipa(info_overrides={"CFBundleIdentifier": "wrong.app"})
        report_path = self.directory / "validation.json"
        arguments = ["verify_ipa.py", str(self.ipa), "--report", str(report_path)]
        with mock.patch.object(verify_ipa.sys, "argv", arguments), contextlib.redirect_stderr(io.StringIO()):
            exit_code = verify_ipa.main()
        self.assertEqual(exit_code, 1)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "failed")
        self.assertIn("bundle identifier", report["error"])


if __name__ == "__main__":
    unittest.main()
