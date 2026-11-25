#import "InventoryPackageValidator.h"
#import <CommonCrypto/CommonDigest.h>
#import <zlib.h>

static const NSUInteger InventoryMaximumPackageBytes = 64 * 1024 * 1024;
static const uint64_t InventoryMaximumExpandedBytes = 128 * 1024 * 1024;
static NSString * const InventoryAppPrefix = @"Payload/SkincareInventory.app/";

static BOOL InventoryPackageFailure(NSError **error, NSString *reason) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"InventoryPackageValidation" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"更新包无法通过安全校验，已停止安装。",
            NSDebugDescriptionErrorKey: reason
        }];
    }
    return NO;
}

static uint16_t InventoryZIP16(const uint8_t *bytes) {
    return (uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8);
}

static uint32_t InventoryZIP32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static BOOL InventoryZIPRange(NSUInteger start, NSUInteger count, NSUInteger limit) {
    return start <= limit && count <= limit - start;
}

static BOOL InventoryVersion(NSString *text, BOOL buildNumber) {
    if (![text isKindOfClass:NSString.class] || text.length == 0 || text.length > 40) return NO;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"."];
    if (buildNumber ? (parts.count < 1 || parts.count > 3) : parts.count != 3) return NO;
    NSUInteger index = 0;
    for (NSString *part in parts) {
        if (part.length == 0 || part.length > 9 || (part.length > 1 && [part hasPrefix:@"0"])) return NO;
        uint64_t number = 0;
        for (NSUInteger character = 0; character < part.length; character++) {
            unichar digit = [part characterAtIndex:character];
            if (digit < '0' || digit > '9') return NO;
            number = number * 10 + digit - '0';
        }
        if ((!buildNumber && number > 1000000) || (buildNumber && index == 0 && number == 0)) return NO;
        index++;
    }
    return YES;
}

/// Only metadata emitted by our ZIP producer is accepted. In particular, ZIP64,
/// Unicode alternate paths and UNIX fields carrying a link target cannot change
/// how another ZIP reader interprets a name that we checked here.
static BOOL InventoryZIPExtras(const uint8_t *bytes, NSUInteger count, BOOL local) {
    NSUInteger offset = 0;
    while (offset < count) {
        if (!InventoryZIPRange(offset, 4, count)) return NO;
        uint16_t kind = InventoryZIP16(bytes + offset);
        uint16_t length = InventoryZIP16(bytes + offset + 2);
        offset += 4;
        if (!InventoryZIPRange(offset, length, count)) return NO;
        switch (kind) {
            case 0x5855: // Info-ZIP UNIX timestamps, with local uid/gid only.
                if (length != (local ? 12 : 8)) return NO;
                break;
            case 0x5455: // Extended timestamps; no alternate filename.
                if (length < 1 || length > 13 || (bytes[offset] & ~7U) != 0) return NO;
                break;
            case 0x7855: // Info-ZIP UNIX2 uid/gid.
                if (length != (local ? 4 : 0)) return NO;
                break;
            case 0x7875: // Info-ZIP UNIX3 variable-size uid/gid.
                if (length < 5 || length > 19 || bytes[offset] != 1) return NO;
                break;
            default:
                return NO;
        }
        offset += length;
    }
    return offset == count;
}

@interface InventoryZIPEntry : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *canonicalName;
@property(nonatomic) BOOL directory;
@property(nonatomic) uint16_t method;
@property(nonatomic) uint16_t flags;
@property(nonatomic) uint16_t version;
@property(nonatomic) uint32_t crc;
@property(nonatomic) uint32_t compressed;
@property(nonatomic) uint32_t expanded;
@property(nonatomic) NSUInteger localOffset;
@property(nonatomic) NSUInteger dataOffset;
@property(nonatomic) NSUInteger endOffset;
@end
@implementation InventoryZIPEntry
@end

static NSString *InventoryZIPName(const uint8_t *bytes, NSUInteger count, BOOL *directory) {
    if (count == 0 || count > 4096) return nil;
    NSString *name = [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
    if (name == nil || [name hasPrefix:@"/"] || [name containsString:@"\\"] ||
        [name containsString:@":"] || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
        return nil;
    }
    *directory = [name hasSuffix:@"/"];
    if (![name hasPrefix:InventoryAppPrefix] && !([name isEqualToString:@"Payload/"] && *directory)) return nil;
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"/"];
    NSUInteger last = parts.count - (*directory ? 1 : 0);
    for (NSUInteger index = 0; index < last; index++) {
        NSString *part = parts[index];
        if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            (index > 1 && [[part lowercaseString] hasSuffix:@".app"])) return nil;
    }
    return name;
}

/// Inflate and CRC-check every entry, retaining only the bounded Info.plist.
/// The aggregate expanded-size limit prevents a validly hashed ZIP bomb from
/// consuming unbounded memory or CPU before the native installation boundary.
static BOOL InventoryZIPContents(NSData *archive, InventoryZIPEntry *entry, NSData **info) {
    const uint8_t *source = (const uint8_t *)archive.bytes + entry.dataOffset;
    uint32_t checksum = (uint32_t)crc32(0L, Z_NULL, 0);
    BOOL keep = [entry.name isEqualToString:[InventoryAppPrefix stringByAppendingString:@"Info.plist"]];
    if (keep && (entry.expanded == 0 || entry.expanded > 128 * 1024)) return NO;
    NSMutableData *retained = keep ? [NSMutableData dataWithCapacity:entry.expanded] : nil;
    if (entry.method == 0) {
        if (entry.compressed != entry.expanded) return NO;
        checksum = (uint32_t)crc32(checksum, source, entry.compressed);
        if (keep) [retained appendBytes:source length:entry.expanded];
    } else {
        z_stream stream = {0};
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return NO;
        stream.next_in = (Bytef *)source;
        stream.avail_in = entry.compressed;
        uint8_t output[64 * 1024];
        uint64_t total = 0;
        int status;
        BOOL valid = YES;
        do {
            stream.next_out = output;
            stream.avail_out = sizeof(output);
            uLong before = stream.total_in;
            status = inflate(&stream, Z_NO_FLUSH);
            NSUInteger produced = sizeof(output) - stream.avail_out;
            total += produced;
            if (total > entry.expanded || (status != Z_OK && status != Z_STREAM_END) ||
                (status == Z_OK && produced == 0 && stream.total_in == before)) {
                valid = NO;
                break;
            }
            checksum = (uint32_t)crc32(checksum, output, (uInt)produced);
            if (keep && produced != 0) [retained appendBytes:output length:produced];
        } while (status != Z_STREAM_END);
        valid = valid && status == Z_STREAM_END && total == entry.expanded &&
            stream.total_in == entry.compressed && stream.avail_in == 0;
        inflateEnd(&stream);
        if (!valid) return NO;
    }
    if (checksum != entry.crc) return NO;
    if (keep) *info = [retained copy];
    return YES;
}

BOOL InventoryValidateUpdateData(NSData *data, NSString *expectedVersion,
                                 NSString *expectedSHA256, NSUInteger expectedSize,
                                 NSError **error) {
    if (error != NULL) *error = nil;
    if (![data isKindOfClass:NSData.class] || !InventoryVersion(expectedVersion, NO) ||
        ![expectedSHA256 isKindOfClass:NSString.class] || expectedSHA256.length != CC_SHA256_DIGEST_LENGTH * 2 ||
        expectedSize < 22 || expectedSize > InventoryMaximumPackageBytes || data.length != expectedSize) {
        return InventoryPackageFailure(error, @"Invalid package length or expected metadata");
    }
    NSString *expectedHash = [expectedSHA256 lowercaseString];
    for (NSUInteger index = 0; index < expectedHash.length; index++) {
        unichar character = [expectedHash characterAtIndex:index];
        if (!((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))) {
            return InventoryPackageFailure(error, @"Invalid SHA-256");
        }
    }
    NSData *archive = [data copy]; // Snapshots a mutable NSData supplied by a caller.
    if (archive.length != expectedSize) return InventoryPackageFailure(error, @"Package changed during snapshot");
    const uint8_t *bytes = archive.bytes;
    NSUInteger length = archive.length;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, (CC_LONG)length, digest);
    const char hex[] = "0123456789abcdef";
    const char *expected = expectedHash.UTF8String;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < CC_SHA256_DIGEST_LENGTH; index++) {
        difference |= hex[digest[index] >> 4] ^ expected[index * 2];
        difference |= hex[digest[index] & 15] ^ expected[index * 2 + 1];
    }
    if (difference != 0) return InventoryPackageFailure(error, @"SHA-256 mismatch");

    // Locate exactly one complete EOCD. Embedded, ambiguous end records, trailing
    // data, prepended self-extractors and arbitrary gaps are rejected below.
    NSUInteger endRecord = NSNotFound;
    NSUInteger scanStart = length > 22 + UINT16_MAX ? length - 22 - UINT16_MAX : 0;
    for (NSUInteger offset = scanStart; offset <= length - 22; offset++) {
        if (InventoryZIP32(bytes + offset) == 0x06054b50 &&
            InventoryZIPRange(offset + 22, InventoryZIP16(bytes + offset + 20), length) &&
            offset + 22 + InventoryZIP16(bytes + offset + 20) == length) {
            if (endRecord != NSNotFound) return InventoryPackageFailure(error, @"Ambiguous ZIP end records");
            endRecord = offset;
        }
    }
    if (endRecord == NSNotFound) return InventoryPackageFailure(error, @"Missing ZIP central directory");
    const uint8_t *end = bytes + endRecord;
    uint16_t entryCount = InventoryZIP16(end + 10);
    uint32_t centralSize = InventoryZIP32(end + 12);
    uint32_t centralOffset = InventoryZIP32(end + 16);
    if (InventoryZIP16(end + 4) != 0 || InventoryZIP16(end + 6) != 0 ||
        InventoryZIP16(end + 8) != entryCount || entryCount == 0 || entryCount == UINT16_MAX ||
        entryCount > 4096 || centralSize == UINT32_MAX || centralOffset == UINT32_MAX ||
        !InventoryZIPRange(centralOffset, centralSize, endRecord) || centralOffset + (NSUInteger)centralSize != endRecord) {
        return InventoryPackageFailure(error, @"Unsupported multi-disk, ZIP64 or inconsistent directory");
    }
    NSMutableArray<InventoryZIPEntry *> *entries = [NSMutableArray arrayWithCapacity:entryCount];
    NSMutableDictionary<NSString *, NSNumber *> *names = [NSMutableDictionary dictionary];
    NSUInteger cursor = centralOffset;
    uint64_t expandedTotal = 0;
    for (NSUInteger index = 0; index < entryCount; index++) {
        if (!InventoryZIPRange(cursor, 46, endRecord) || InventoryZIP32(bytes + cursor) != 0x02014b50) {
            return InventoryPackageFailure(error, @"Invalid ZIP central header");
        }
        const uint8_t *header = bytes + cursor;
        uint16_t nameLength = InventoryZIP16(header + 28);
        uint16_t extraLength = InventoryZIP16(header + 30);
        uint16_t commentLength = InventoryZIP16(header + 32);
        NSUInteger recordLength = 46 + (NSUInteger)nameLength + extraLength + commentLength;
        if (!InventoryZIPRange(cursor, recordLength, endRecord)) return InventoryPackageFailure(error, @"Truncated central entry");
        InventoryZIPEntry *entry = [InventoryZIPEntry new];
        BOOL isDirectory = NO;
        entry.name = InventoryZIPName(header + 46, nameLength, &isDirectory);
        if (entry.name == nil) return InventoryPackageFailure(error, @"Unsafe or foreign ZIP path");
        entry.directory = isDirectory;
        NSString *withoutSlash = isDirectory ? [entry.name substringToIndex:entry.name.length - 1] : entry.name;
        entry.canonicalName = [[withoutSlash precomposedStringWithCanonicalMapping] lowercaseString];
        if (names[entry.canonicalName] != nil) return InventoryPackageFailure(error, @"Duplicate ZIP path");
        names[entry.canonicalName] = @(isDirectory);
        entry.version = InventoryZIP16(header + 6);
        entry.flags = InventoryZIP16(header + 8);
        entry.method = InventoryZIP16(header + 10);
        entry.crc = InventoryZIP32(header + 16);
        entry.compressed = InventoryZIP32(header + 20);
        entry.expanded = InventoryZIP32(header + 24);
        entry.localOffset = InventoryZIP32(header + 42);
        uint32_t attributes = InventoryZIP32(header + 38);
        uint32_t unixType = (attributes >> 16) & 0170000;
        // Reject symlinks, special files, encryption and every unsupported flag.
        // Deflate compression-option bits 1/2, descriptors and UTF-8 are safe.
        if (entry.version > 20 || (entry.flags & ~0x080eU) != 0 ||
            (entry.method != 0 && entry.method != 8) ||
            (entry.method == 0 && (entry.flags & 6U) != 0) ||
            InventoryZIP16(header + 34) != 0 || entry.compressed == UINT32_MAX || entry.expanded == UINT32_MAX ||
            entry.localOffset == UINT32_MAX || entry.expanded > InventoryMaximumPackageBytes ||
            (unixType != 0 && unixType != 0100000 && unixType != 0040000) ||
            (unixType == 0040000 && !isDirectory) || (unixType == 0100000 && isDirectory) ||
            ((attributes & 0x10) != 0 && !isDirectory) ||
            (isDirectory && (entry.compressed != 0 || entry.expanded != 0 || entry.crc != 0 || (entry.flags & 8U) != 0)) ||
            !InventoryZIPExtras(header + 46 + nameLength, extraLength, NO)) {
            return InventoryPackageFailure(error, @"Unsupported ZIP metadata or special file");
        }
        expandedTotal += entry.expanded;
        if (expandedTotal > InventoryMaximumExpandedBytes) return InventoryPackageFailure(error, @"Expanded package exceeds limit");
        [entries addObject:entry];
        cursor += recordLength;
    }
    if (cursor != endRecord) return InventoryPackageFailure(error, @"Central directory length mismatch");
    for (InventoryZIPEntry *entry in entries) {
        // No file may also be used as a parent directory, even if the parent
        // entry appears after its children in the ZIP central directory.
        NSArray<NSString *> *parts = [entry.canonicalName componentsSeparatedByString:@"/"];
        for (NSUInteger component = 1; component < parts.count; component++) {
            NSString *parent = [[parts subarrayWithRange:NSMakeRange(0, component)] componentsJoinedByString:@"/"];
            NSNumber *parentIsDirectory = names[parent];
            if (parentIsDirectory != nil && !parentIsDirectory.boolValue) {
                return InventoryPackageFailure(error, @"File used as parent directory");
            }
        }
        if (!InventoryZIPRange(entry.localOffset, 30, centralOffset)) return InventoryPackageFailure(error, @"Invalid local header range");
        const uint8_t *local = bytes + entry.localOffset;
        uint16_t localNameLength = InventoryZIP16(local + 26);
        uint16_t localExtraLength = InventoryZIP16(local + 28);
        NSUInteger localHeaderLength = 30 + (NSUInteger)localNameLength + localExtraLength;
        if (InventoryZIP32(local) != 0x04034b50 || InventoryZIP16(local + 4) != entry.version ||
            InventoryZIP16(local + 6) != entry.flags || InventoryZIP16(local + 8) != entry.method ||
            !InventoryZIPRange(entry.localOffset, localHeaderLength, centralOffset)) {
            return InventoryPackageFailure(error, @"Local and central ZIP headers disagree");
        }
        NSData *nameData = [entry.name dataUsingEncoding:NSUTF8StringEncoding];
        if (nameData.length != localNameLength || memcmp(nameData.bytes, local + 30, localNameLength) != 0 ||
            !InventoryZIPExtras(local + 30 + localNameLength, localExtraLength, YES)) {
            return InventoryPackageFailure(error, @"Local name or extra metadata differs");
        }
        entry.dataOffset = entry.localOffset + localHeaderLength;
        if (!InventoryZIPRange(entry.dataOffset, entry.compressed, centralOffset)) return InventoryPackageFailure(error, @"Invalid compressed data range");
        entry.endOffset = entry.dataOffset + entry.compressed;
        uint32_t localCRC = InventoryZIP32(local + 14);
        uint32_t localCompressed = InventoryZIP32(local + 18);
        uint32_t localExpanded = InventoryZIP32(local + 22);
        if ((entry.flags & 8U) != 0) {
            if (!((localCRC == 0 && localCompressed == 0 && localExpanded == 0) ||
                  (localCRC == entry.crc && localCompressed == entry.compressed && localExpanded == entry.expanded))) {
                return InventoryPackageFailure(error, @"Invalid descriptor local sizes");
            }
            const uint8_t *descriptor = bytes + entry.endOffset;
            if (InventoryZIPRange(entry.endOffset, 16, centralOffset) && InventoryZIP32(descriptor) == 0x08074b50 &&
                InventoryZIP32(descriptor + 4) == entry.crc && InventoryZIP32(descriptor + 8) == entry.compressed &&
                InventoryZIP32(descriptor + 12) == entry.expanded) {
                entry.endOffset += 16;
            } else if (InventoryZIPRange(entry.endOffset, 12, centralOffset) && InventoryZIP32(descriptor) == entry.crc &&
                       InventoryZIP32(descriptor + 4) == entry.compressed && InventoryZIP32(descriptor + 8) == entry.expanded) {
                entry.endOffset += 12;
            } else { return InventoryPackageFailure(error, @"Invalid ZIP data descriptor"); }
        } else if (localCRC != entry.crc || localCompressed != entry.compressed || localExpanded != entry.expanded) {
            return InventoryPackageFailure(error, @"Local sizes disagree with central entry");
        }
    }
    NSArray<InventoryZIPEntry *> *ordered = [entries sortedArrayUsingComparator:^NSComparisonResult(InventoryZIPEntry *first, InventoryZIPEntry *second) {
        if (first.localOffset < second.localOffset) return NSOrderedAscending;
        if (first.localOffset > second.localOffset) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    cursor = 0;
    NSData *info = nil;
    BOOL executable = NO;
    for (InventoryZIPEntry *entry in ordered) {
        if (entry.localOffset != cursor || entry.endOffset < entry.dataOffset || entry.endOffset > centralOffset) {
            return InventoryPackageFailure(error, @"Overlapping, hidden or gapped ZIP entries");
        }
        cursor = entry.endOffset;
        if (!InventoryZIPContents(archive, entry, &info)) return InventoryPackageFailure(error, @"ZIP contents or CRC mismatch");
        if ([entry.name isEqualToString:[InventoryAppPrefix stringByAppendingString:@"SkincareInventory"]]) {
            executable = !entry.directory && entry.expanded > 0;
        }
    }
    if (cursor != centralOffset || info == nil || !executable) return InventoryPackageFailure(error, @"Required App files missing");
    id plist = [NSPropertyListSerialization propertyListWithData:info options:NSPropertyListImmutable format:NULL error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return InventoryPackageFailure(error, @"Invalid App Info.plist");
    NSDictionary *metadata = plist;
    if (![metadata[@"CFBundleIdentifier"] isEqual:@"io.github.saimilai.skincareinventory"] ||
        ![metadata[@"CFBundleExecutable"] isEqual:@"SkincareInventory"] ||
        ![metadata[@"CFBundleShortVersionString"] isEqual:expectedVersion] ||
        ![metadata[@"CFBundlePackageType"] isEqual:@"APPL"] || !InventoryVersion(metadata[@"CFBundleVersion"], YES)) {
        return InventoryPackageFailure(error, @"Package identity or version mismatch");
    }
    return YES;
}
