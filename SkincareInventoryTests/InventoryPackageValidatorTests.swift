import Foundation
import XCTest
@testable import SkincareInventory

final class InventoryPackageValidatorTests: XCTestCase {
    private let prefix = "Payload/SkincareInventory.app/"

    private struct Entry {
        var name: String
        var data: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var attributes: UInt32 = UInt32(0o100644) << 16
        var localName: String? = nil
        var localMethod: UInt16? = nil
        var checksum: UInt32? = nil
        var extra = Data()
    }

    private func metadata() -> [String: Any] {
        ["CFBundleIdentifier": "io.github.saimilai.skincareinventory",
         "CFBundleExecutable": "SkincareInventory", "CFBundleShortVersionString": "1.0.1",
         "CFBundleVersion": "12", "CFBundlePackageType": "APPL"]
    }

    private func entries(metadata: [String: Any]? = nil, format: PropertyListSerialization.PropertyListFormat = .binary) throws -> [Entry] {
        let plist = try PropertyListSerialization.data(fromPropertyList: metadata ?? self.metadata(), format: format, options: 0)
        return [
            Entry(name: "Payload/", data: Data(), attributes: UInt32(0o40755) << 16 | 0x10),
            Entry(name: prefix, data: Data(), attributes: UInt32(0o40755) << 16 | 0x10),
            Entry(name: prefix + "Info.plist", data: plist),
            Entry(name: prefix + "SkincareInventory", data: Data([0xcf, 0xfa, 0xed, 0xfe, 1, 2, 3, 4]), attributes: UInt32(0o100755) << 16)
        ]
    }

    private func u16(_ number: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: number))
        data.append(UInt8(truncatingIfNeeded: number >> 8))
    }

    private func u32(_ number: UInt32, to data: inout Data) {
        for shift in stride(from: 0, through: 24, by: 8) {
            data.append(UInt8(truncatingIfNeeded: number >> shift))
        }
    }

    private func crc(_ data: Data) -> UInt32 {
        var result: UInt32 = 0xffffffff
        for byte in data {
            result ^= UInt32(byte)
            for _ in 0..<8 { result = (result >> 1) ^ ((result & 1) == 1 ? 0xedb88320 : 0) }
        }
        return result ^ 0xffffffff
    }

    // One uncompressed DEFLATE block is still method 8 with a raw DEFLATE
    // stream, exercising inflate(-MAX_WBITS) without a third-party compressor.
    private func deflate(_ data: Data) -> Data {
        precondition(data.count < 65536)
        var result = Data([0x01])
        let count = UInt16(data.count)
        u16(count, to: &result)
        u16(~count, to: &result)
        result.append(data)
        return result
    }

    private func zip(_ entries: [Entry], disk: UInt16 = 0, gap: Bool = false) -> Data {
        var bytes = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(bytes.count)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let compressed = entry.method == 8 ? deflate(entry.data) : entry.data
            let checksum = entry.checksum ?? crc(entry.data)
            let descriptor = entry.flags & 8 != 0
            u32(0x04034b50, to: &bytes)
            u16(20, to: &bytes); u16(entry.flags, to: &bytes)
            u16(entry.localMethod ?? entry.method, to: &bytes)
            u16(0, to: &bytes); u16(0, to: &bytes)
            u32(descriptor ? 0 : checksum, to: &bytes)
            u32(descriptor ? 0 : UInt32(compressed.count), to: &bytes)
            u32(descriptor ? 0 : UInt32(entry.data.count), to: &bytes)
            u16(UInt16(localName.count), to: &bytes); u16(UInt16(entry.extra.count), to: &bytes)
            bytes.append(localName); bytes.append(entry.extra); bytes.append(compressed)
            if descriptor {
                u32(0x08074b50, to: &bytes); u32(checksum, to: &bytes)
                u32(UInt32(compressed.count), to: &bytes); u32(UInt32(entry.data.count), to: &bytes)
            }
            u32(0x02014b50, to: &central)
            u16(0x0314, to: &central); u16(20, to: &central)
            u16(entry.flags, to: &central); u16(entry.method, to: &central)
            u16(0, to: &central); u16(0, to: &central)
            u32(checksum, to: &central); u32(UInt32(compressed.count), to: &central)
            u32(UInt32(entry.data.count), to: &central)
            u16(UInt16(name.count), to: &central); u16(UInt16(entry.extra.count), to: &central)
            u16(0, to: &central); u16(0, to: &central); u16(0, to: &central)
            u32(entry.attributes, to: &central); u32(offset, to: &central)
            central.append(name); central.append(entry.extra)
        }
        if gap { bytes.append(contentsOf: [1, 2, 3, 4]) }
        let centralOffset = UInt32(bytes.count)
        bytes.append(central)
        u32(0x06054b50, to: &bytes)
        u16(disk, to: &bytes); u16(disk, to: &bytes)
        u16(UInt16(entries.count), to: &bytes); u16(UInt16(entries.count), to: &bytes)
        u32(UInt32(central.count), to: &bytes); u32(centralOffset, to: &bytes)
        u16(0, to: &bytes)
        return bytes
    }

    private func validate(_ data: Data, hash: String? = nil, version: String = "1.0.1", size: Int? = nil) -> (Bool, NSError?) {
        var error: NSError?
        let accepted = InventoryValidateUpdateData(
            data, version, hash ?? AppUpdateService.sha256(data), numericCast(size ?? data.count), &error
        )
        return (accepted, error)
    }

    private func reject(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let result = validate(data)
        XCTAssertFalse(result.0, "An unsafe package was accepted", file: file, line: line)
        XCTAssertNotNil(result.1, file: file, line: line)
    }

    func testAcceptsStoredAndRawDeflatePackagesWithDataDescriptors() throws {
        for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
            let ordinary = zip(try entries(format: format))
            XCTAssertTrue(validate(ordinary).0)
            XCTAssertNil(validate(ordinary).1)
            var compressed = try entries(format: format)
            compressed[2].method = 8; compressed[2].flags = 8
            compressed[3].method = 8; compressed[3].flags = 8
            XCTAssertTrue(validate(zip(compressed)).0)
        }
    }

    func testRejectsTamperedDigestWrongSizeAndMalformedExpectedMetadata() throws {
        let data = zip(try entries())
        XCTAssertFalse(validate(data, hash: String(repeating: "0", count: 64)).0)
        XCTAssertFalse(validate(data, size: data.count + 1).0)
        XCTAssertFalse(validate(data, hash: "not a hash").0)
        XCTAssertFalse(validate(data, version: "1.0.1-beta").0)
        XCTAssertFalse(validate(data, version: "1.0.2").0)
        XCTAssertFalse(validate(Data()).0)
        var changed = data
        changed[40] ^= 1
        XCTAssertFalse(validate(changed, hash: AppUpdateService.sha256(data)).0)
    }

    func testRejectsForeignBundleIdentityExecutableAndInvalidBuild() throws {
        let mutations: [(String, Any)] = [
            ("CFBundleIdentifier", "io.github.other.application"),
            ("CFBundleExecutable", "OtherApp"), ("CFBundleShortVersionString", "2.0.0"),
            ("CFBundlePackageType", "BNDL"), ("CFBundleVersion", "0"),
            ("CFBundleVersion", "1.0-beta"), ("CFBundleVersion", 12)
        ]
        for (key, value) in mutations {
            var metadata = self.metadata(); metadata[key] = value
            reject(zip(try entries(metadata: metadata)))
        }
        var missing = try entries(); missing.remove(at: 2)
        reject(zip(missing))
        missing = try entries(); missing.remove(at: 3)
        reject(zip(missing))
    }

    func testRejectsTraversalAbsoluteControlAndOtherAppPaths() throws {
        for path in [
            prefix + "../escape", prefix + "sub/../../escape", prefix + "./file",
            "/" + prefix + "file", prefix + "a\\file", prefix + "a\u{0}file",
            prefix + "double//file", "Payload/Other.app/file", prefix + "Embedded.app/file",
            "__MACOSX/file", prefix + "file:name"
        ] {
            var unsafe = try entries(); unsafe.append(Entry(name: path, data: Data([1])))
            reject(zip(unsafe))
        }
    }

    func testRejectsSymlinksDuplicatePathsAndFileDirectoryConflicts() throws {
        var unsafe = try entries()
        unsafe.append(Entry(name: prefix + "link", data: Data("/var/mobile".utf8), attributes: UInt32(0o120777) << 16))
        reject(zip(unsafe))
        unsafe = try entries(); unsafe.append(unsafe[2]); reject(zip(unsafe))
        unsafe = try entries(); unsafe.append(Entry(name: prefix + "info.plist", data: Data([1])))
        reject(zip(unsafe))
        unsafe = try entries()
        unsafe.append(Entry(name: prefix + "folder/item", data: Data([1])))
        unsafe.append(Entry(name: prefix + "folder", data: Data([2])))
        reject(zip(unsafe))
    }

    func testRejectsHeaderDisagreementEncryptionZIP64GapsAndMultidisk() throws {
        var unsafe = try entries(); unsafe[2].localName = prefix + "OtherFile!"
        reject(zip(unsafe))
        unsafe = try entries(); unsafe[2].localMethod = 8; reject(zip(unsafe))
        unsafe = try entries(); unsafe[2].flags = 1; reject(zip(unsafe))
        unsafe = try entries(); unsafe[2].extra = Data([1, 0, 0, 0]); reject(zip(unsafe))
        unsafe = try entries(); unsafe[2].extra = Data([0x75, 0x70, 0, 0]); reject(zip(unsafe))
        reject(zip(try entries(), disk: 1))
        reject(zip(try entries(), gap: true))
        var truncated = zip(try entries()); truncated.removeLast(); reject(truncated)
        var trailing = zip(try entries()); trailing.append(0); reject(trailing)
    }

    func testRejectsCRCDeflateCorruptionAndOversizedInfo() throws {
        var unsafe = try entries(); unsafe[2].checksum = 0; reject(zip(unsafe))
        unsafe = try entries(); unsafe[3].method = 8
        var damaged = zip(unsafe)
        let executableName = damaged.range(of: Data((prefix + "SkincareInventory").utf8))!
        // A reserved DEFLATE block type, with the new correct outer hash, must
        // fail inflate/CRC validation before any native installation call.
        damaged[executableName.upperBound] = 7
        reject(damaged)
        unsafe = try entries(); unsafe[2].data = Data(repeating: 32, count: 128 * 1024 + 1)
        reject(zip(unsafe))
        unsafe = try entries(); unsafe[2].data = Data("not a property list".utf8)
        reject(zip(unsafe))
    }
}
