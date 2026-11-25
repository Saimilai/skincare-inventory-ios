#!/usr/bin/env python3
"""Verify this project's IPA without requiring third-party Python packages."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


REQUIRED_UPDATE_ENTITLEMENTS = {
    "platform-application": True,
    "com.apple.private.security.no-sandbox": True,
    "com.apple.private.persona-mgmt": True,
    "com.apple.private.security.storage.AppDataContainers": True,
}
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",  # 32-bit, either byte order
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",  # 64-bit, either byte order
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # FAT/universal
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",  # FAT64/universal
}


class VerificationError(ValueError):
    """An IPA does not match the expected device application."""


def _version_tuple(value: str) -> tuple[int, int, int]:
    if not isinstance(value, str):
        raise VerificationError(f"Invalid system version: {value!r}")
    try:
        pieces = tuple(int(piece) for piece in value.split("."))
    except (TypeError, ValueError) as exc:
        raise VerificationError(f"Invalid system version: {value!r}") from exc
    if not 1 <= len(pieces) <= 3 or any(piece < 0 for piece in pieces):
        raise VerificationError(f"Invalid system version: {value!r}")
    return (pieces + (0, 0, 0))[:3]


def _packed_version(value: int) -> str:
    return f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"


def parse_macho(data: bytes) -> dict:
    """Read a thin arm64 iOS Mach-O executable and its deployment metadata."""
    if len(data) < 32:
        raise VerificationError("The executable is too small for a Mach-O header.")
    fields = struct.unpack_from("<IiiIIIII", data)
    magic, cpu_type, cpu_subtype, file_type, command_count, command_bytes, _, _ = fields
    if magic != 0xFEEDFACF:
        raise VerificationError("Expected a thin, little-endian 64-bit Mach-O executable.")
    if cpu_type != 0x0100000C or (cpu_subtype & 0x00FFFFFF) != 0:
        raise VerificationError("Expected standard arm64, not a simulator or arm64e executable.")
    if file_type != 2:
        raise VerificationError("The main Mach-O file is not an executable (MH_EXECUTE).")
    command_end = 32 + command_bytes
    if command_end > len(data) or command_count > command_bytes // 8:
        raise VerificationError("The Mach-O load command table is truncated.")

    offset = 32
    versions = []
    sdks = []
    has_signature = False
    for _ in range(command_count):
        if offset + 8 > command_end:
            raise VerificationError("Truncated Mach-O load command.")
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or size % 4 or offset + size > command_end:
            raise VerificationError("Invalid Mach-O load command size.")
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise VerificationError("LC_BUILD_VERSION is truncated.")
            _, _, target_platform, minimum, sdk, tool_count = struct.unpack_from(
                "<IIIIII", data, offset
            )
            if target_platform != 2:
                raise VerificationError("The executable targets a platform other than device iOS.")
            if size < 24 + tool_count * 8:
                raise VerificationError("The Mach-O build tool table is truncated.")
            versions.append(_packed_version(minimum))
            sdks.append(_packed_version(sdk))
        elif command == 0x25:  # LC_VERSION_MIN_IPHONEOS
            if size < 16:
                raise VerificationError("LC_VERSION_MIN_IPHONEOS is truncated.")
            _, _, minimum, sdk = struct.unpack_from("<IIII", data, offset)
            versions.append(_packed_version(minimum))
            sdks.append(_packed_version(sdk))
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            if size < 16:
                raise VerificationError("LC_CODE_SIGNATURE is truncated.")
            _, _, signature_offset, signature_size = struct.unpack_from("<IIII", data, offset)
            if not signature_size or signature_offset < command_end:
                raise VerificationError("Invalid embedded code signature location.")
            if signature_offset + signature_size > len(data):
                raise VerificationError("The embedded code signature extends beyond the executable.")
            has_signature = True
        offset += size
    if offset != command_end:
        raise VerificationError("The Mach-O load command byte count is inconsistent.")
    if not versions or len(set(versions)) != 1:
        raise VerificationError("The Mach-O iOS minimum version is missing or inconsistent.")
    return {
        "architecture": "arm64",
        "platform": "iOS",
        "minimum_ios": versions[0],
        "sdk": sdks[0],
        "embedded_code_signature": has_signature,
        "load_commands": command_count,
    }


def _checked_members(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    members = {}
    total_size = 0
    for member in archive.infolist():
        name = member.filename
        parts = name.rstrip("/").split("/")
        if (
            name.startswith(("/", "\\"))
            or "\\" in name
            or any(part in ("", ".", "..") for part in parts)
            or parts[0] != "Payload"
        ):
            raise VerificationError(f"Unexpected or unsafe ZIP path: {name!r}")
        if name in members:
            raise VerificationError(f"Duplicate ZIP entry: {name!r}")
        mode = member.external_attr >> 16
        if stat.S_ISLNK(mode):
            raise VerificationError(f"Symbolic links are not expected in this app: {name!r}")
        if member.flag_bits & 1:
            raise VerificationError("Encrypted ZIP entries are not supported.")
        total_size += member.file_size
        if total_size > 256 * 1024 * 1024:
            raise VerificationError("The uncompressed IPA exceeds this app's 256 MiB verification limit.")
        members[name] = member
    if not members:
        raise VerificationError("The IPA archive is empty.")
    return members


def validate_update_entitlements(value, bundle_id):
    """Require the reviewed update capability without changing container identity."""
    if not isinstance(value, dict):
        raise VerificationError("The executable entitlements must be a dictionary.")
    expected = {**REQUIRED_UPDATE_ENTITLEMENTS, "application-identifier": bundle_id}
    if set(value) != set(expected):
        raise VerificationError("The executable entitlements differ from the reviewed update allowlist.")
    if value.get("application-identifier") != bundle_id or any(
        value.get(key) is not True for key in REQUIRED_UPDATE_ENTITLEMENTS
    ):
        raise VerificationError("The executable update entitlements or application identifier are incorrect.")
    return value


def _verify_signature(archive: zipfile.ZipFile, members: dict, app_folder: str,
                      bundle_id: str) -> dict:
    if platform.system() != "Darwin":
        raise VerificationError("Formal signature verification requires macOS codesign.")
    with tempfile.TemporaryDirectory(prefix="skincare-ipa-check-") as temporary:
        root = Path(temporary)
        # Paths and entry types were checked before extracting anything.
        for name, member in members.items():
            target = root.joinpath(*name.rstrip("/").split("/"))
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, target.open("wb") as destination:
                    while chunk := source.read(1024 * 1024):
                        destination.write(chunk)
                os.chmod(target, (member.external_attr >> 16) & 0o777)
        app_path = root / app_folder
        verified = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        details = subprocess.run(
            ["/usr/bin/codesign", "--display", "--verbose=4", str(app_path)],
            capture_output=True,
            text=True,
            check=False,
        )
        verification_output = (verified.stdout + verified.stderr).strip()
        detail_output = (details.stdout + details.stderr).strip()
        if verified.returncode or details.returncode:
            raise VerificationError("codesign verification failed:\n" + verification_output + "\n" + detail_output)
        if "Signature=adhoc" not in detail_output:
            raise VerificationError("The package should have an ad hoc signature for TrollStore to replace.")
        dumped = subprocess.run(
            ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app_path)],
            capture_output=True,
            check=False,
        )
        if dumped.returncode:
            raise VerificationError("codesign could not export the executable entitlements.")
        try:
            entitlements = plistlib.loads(dumped.stdout)
        except (plistlib.InvalidFileException, ValueError, TypeError) as exc:
            raise VerificationError("codesign exported malformed or missing executable entitlements.") from exc
        validate_update_entitlements(entitlements, bundle_id)
        return {
            "status": "passed",
            "type": "ad hoc",
            "verification_output": verification_output,
            "signature_details": detail_output,
            "entitlements_status": "passed",
            "entitlements": entitlements,
            "self_update_execution_on_device": "not tested",
        }


def inspect_ipa(
    ipa_path: str | Path,
    expected_bundle_id: str = "io.github.saimilai.skincareinventory",
    expected_version: str = "1.0.1",
    expected_build: str | None = None,
    verify_signature: bool = True,
) -> dict:
    """Inspect the archive; tests may explicitly opt out of macOS signature execution."""
    path = Path(ipa_path)
    if not path.is_file():
        raise VerificationError(f"IPA not found: {path}")
    with zipfile.ZipFile(path) as archive:
        members = _checked_members(archive)
        app_folders = {
            "/".join(name.rstrip("/").split("/")[:2])
            for name in members
            if len(name.rstrip("/").split("/")) >= 2
            and name.rstrip("/").split("/")[1].endswith(".app")
        }
        if len(app_folders) != 1:
            raise VerificationError("Expected exactly one app directly inside Payload/.")
        app_folder = app_folders.pop()
        if any(
            name.rstrip("/") != "Payload"
            and name.rstrip("/") != app_folder
            and not name.startswith(app_folder + "/")
            for name in members
        ):
            raise VerificationError("Unexpected content outside the main app.")
        plist_name = app_folder + "/Info.plist"
        if plist_name not in members:
            raise VerificationError("The main app has no Info.plist.")
        try:
            info = plistlib.loads(archive.read(plist_name))
        except (plistlib.InvalidFileException, ValueError, TypeError) as exc:
            raise VerificationError("Cannot parse the app's Info.plist.") from exc
        if not isinstance(info, dict):
            raise VerificationError("Info.plist must contain a dictionary.")
        if any(key.startswith("TSRoot") for key in info):
            raise VerificationError("This app must not declare embedded TrollStore root helper binaries.")
        if info.get("CFBundlePackageType") != "APPL":
            raise VerificationError("CFBundlePackageType must be APPL.")
        if info.get("CFBundleIdentifier") != expected_bundle_id:
            raise VerificationError("The bundle identifier does not match this project.")
        if info.get("CFBundleShortVersionString") != expected_version:
            raise VerificationError("The app version does not match the release version.")
        build = info.get("CFBundleVersion", "")
        if (
            not isinstance(build, str)
            or not re.fullmatch(r"[1-9][0-9]*", build)
            or (expected_build is not None and build != str(expected_build))
        ):
            raise VerificationError("The app build number is missing or incorrect.")
        minimum = info.get("MinimumOSVersion", "")
        if _version_tuple(minimum) != (14, 0, 0):
            raise VerificationError("Info.plist must declare iOS 14.0 as its minimum.")
        if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
            raise VerificationError("The IPA must contain an iPhoneOS device app.")
        device_families = info.get("UIDeviceFamily")
        if not isinstance(device_families, list) or 1 not in device_families:
            raise VerificationError("The app must support iPhone.")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable:
            raise VerificationError("Invalid CFBundleExecutable name.")
        executable_name = app_folder + "/" + executable
        if executable_name not in members:
            raise VerificationError("The declared app executable is missing.")
        if not (members[executable_name].external_attr >> 16) & stat.S_IXUSR:
            raise VerificationError("The executable permission was not preserved in the IPA.")
        for name, member in members.items():
            if not member.is_dir() and name != executable_name:
                with archive.open(member) as source:
                    magic = source.read(4)
                if magic in MACHO_MAGICS:
                    raise VerificationError("Unexpected additional Mach-O code/root helper in this app: " + name)
        macho = parse_macho(archive.read(executable_name))
        if _version_tuple(macho["minimum_ios"]) != _version_tuple(minimum):
            raise VerificationError("Info.plist and Mach-O minimum iOS versions disagree.")
        if not macho["embedded_code_signature"]:
            raise VerificationError("The main executable has no embedded code signature.")
        if app_folder + "/_CodeSignature/CodeResources" not in members:
            raise VerificationError("The app resource seal is missing.")
        signature = (
            _verify_signature(archive, members, app_folder, expected_bundle_id)
            if verify_signature
            else {
                "status": "not_run", "entitlements_status": "not_run",
                "reason": "Static test explicitly disabled macOS codesign and entitlement verification.",
                "self_update_execution_on_device": "not tested",
            }
        )
    return {
        "status": "passed" if verify_signature else "static_checks_passed",
        "verified_at_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "file": path.name,
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "app_folder": app_folder,
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": build,
        "minimum_ios": minimum,
        "macho": macho,
        "package_code": {"mach_o_binaries": [executable_name], "embedded_root_helpers": False},
        "signature": signature,
        "real_trollstore_device": "not tested",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--bundle-id", default="io.github.saimilai.skincareinventory")
    parser.add_argument("--version", default="1.0.1")
    parser.add_argument("--build")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        report = inspect_ipa(args.ipa, args.bundle_id, args.version, args.build)
    except (VerificationError, OSError, zipfile.BadZipFile, subprocess.SubprocessError) as exc:
        report = {
            "status": "failed",
            "file": args.ipa.name,
            "error": str(exc),
            "real_trollstore_device": "not tested",
        }
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(report["error"], file=sys.stderr)
        return 1
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
