#import "InventorySelfUpdate.h"
#import "InventoryPackageValidator.h"
#import <CommonCrypto/CommonDigest.h>
#import <TargetConditionals.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString * const InventoryBundleID = @"io.github.saimilai.skincareinventory";
// Exact helper from opa334/TrollStore release 2.1.1, TrollStore.tar. See
// docs/SELF-UPDATE.md for its immutable source and archive verification evidence.
static NSString * const ReviewedHelperSHA256 = @"3634607f8165fb41c6844cb0b7608f38ee1f51c2e96e353ed13d4c76a28aa1bd";
static const NSUInteger ReviewedHelperSize = 4086819;
static const NSUInteger MaximumPackageSize = 64 * 1024 * 1024;

typedef int (*PersonaFunction)(const posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*PersonaIDFunction)(const posix_spawnattr_t *, uid_t);

static NSString *digest(NSData *data) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *value = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) {
        [value appendFormat:@"%02x", bytes[index]];
    }
    return value;
}

static BOOL regularFile(NSString *path, NSUInteger size) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode)
        && info.st_size >= 0 && (NSUInteger)info.st_size == size;
}

static NSString *canonical(NSURL *url) {
    return url.URLByStandardizingPath.URLByResolvingSymlinksInPath.path;
}

static NSString *findReviewedHelper(NSString **reason) {
#if TARGET_OS_SIMULATOR
    if (reason) *reason = @"模拟器不支持安装更新，请在巨魔设备上使用。";
    return nil;
#else
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:InventoryBundleID]) {
        if (reason) *reason = @"应用标识无法确认，已停用原地更新。";
        return nil;
    }
    // Preserve the existing data-container based home. A build accidentally
    // registered as a non-container app must not attempt a self update.
    NSString *home = canonical([NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES]);
    NSString *dataRoot = @"/private/var/mobile/Containers/Data/Application/";
    NSString *homeID = [home hasPrefix:dataRoot] ? [home substringFromIndex:dataRoot.length] : nil;
    if (!homeID || ![[NSUUID alloc] initWithUUIDString:homeID]) {
        if (reason) *reason = @"无法确认原库存数据容器，请使用巨魔覆盖安装并核对库存。";
        return nil;
    }
    PersonaFunction persona = (PersonaFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    PersonaIDFunction uid = (PersonaIDFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    PersonaIDFunction gid = (PersonaIDFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!persona || !uid || !gid) {
        if (reason) *reason = @"此系统暂不支持 App 内原地更新，可使用巨魔覆盖安装。";
        return nil;
    }

    @try {
        Class proxyClass = NSClassFromString(@"LSApplicationProxy");
        if (!proxyClass) {
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
            proxyClass = NSClassFromString(@"LSApplicationProxy");
        }
        SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (!proxyClass || ![proxyClass respondsToSelector:selector]) {
            if (reason) *reason = @"无法定位巨魔安装助手，可使用巨魔覆盖安装。";
            return nil;
        }
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, selector, @"com.opa334.TrollStore");
        SEL bundleSelector = NSSelectorFromString(@"bundleURL");
        NSURL *bundleURL = [proxy respondsToSelector:bundleSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(proxy, bundleSelector) : nil;
        if (![bundleURL isKindOfClass:NSURL.class] || !bundleURL.isFileURL) {
            if (reason) *reason = @"未找到兼容的巨魔，可使用巨魔覆盖安装。";
            return nil;
        }
        NSString *bundle = canonical(bundleURL);
        NSString *root = @"/private/var/containers/Bundle/Application/";
        NSArray<NSString *> *parts = [bundle hasPrefix:root]
            ? [[bundle substringFromIndex:root.length] componentsSeparatedByString:@"/"] : @[];
        if (parts.count != 2 || ![[NSUUID alloc] initWithUUIDString:parts[0]]
            || ![parts[1] isEqualToString:@"TrollStore.app"]) {
            if (reason) *reason = @"巨魔安装位置暂不兼容，可使用文件交接更新。";
            return nil;
        }
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqual:@"com.opa334.TrollStore"]
            || ![info[@"CFBundleVersion"] isEqual:@"2.1.1"]) {
            if (reason) *reason = @"当前巨魔版本尚未通过原地更新适配，可使用文件交接更新。";
            return nil;
        }
        NSString *helper = [bundle stringByAppendingPathComponent:@"trollstorehelper"];
        if (!regularFile(helper, ReviewedHelperSize) || access(helper.fileSystemRepresentation, X_OK) != 0) {
            if (reason) *reason = @"巨魔安装助手无法验证，可使用巨魔覆盖安装。";
            return nil;
        }
        NSData *helperData = [NSData dataWithContentsOfFile:helper options:0 error:nil];
        if (helperData.length != ReviewedHelperSize || ![digest(helperData) isEqual:ReviewedHelperSHA256]
            || !regularFile(helper, ReviewedHelperSize)) {
            if (reason) *reason = @"巨魔安装助手与已适配的官方版本不匹配，可使用文件交接更新。";
            return nil;
        }
        return helper;
    } @catch (__unused NSException *exception) {
        if (reason) *reason = @"无法确认巨魔安装环境，可使用巨魔覆盖安装。";
        return nil;
    }
#endif
}

NSString *InventorySelfUpdateUnavailableReason(void) {
    NSString *reason = nil;
    findReviewedHelper(&reason);
    return reason;
}

NSString *InventoryPerformSelfUpdate(NSURL *sourceURL, NSString *version, NSString *sha256, NSUInteger size) {
    NSString *reason = nil;
    NSString *helper = findReviewedHelper(&reason);
    if (!helper) return reason ?: @"原地更新不可用。";
    NSString *current = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z" options:0 error:nil];
    if (![version isKindOfClass:NSString.class] || !current
        || [pattern numberOfMatchesInString:version options:0 range:NSMakeRange(0, version.length)] != 1
        || [current compare:version options:NSNumericSearch] != NSOrderedAscending
        || size == 0 || size > MaximumPackageSize || !sourceURL.isFileURL) {
        return @"更新包版本或大小无法验证，已停止安装。";
    }
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *cacheRoot = canonical([caches URLByAppendingPathComponent:@"InventoryUpdates" isDirectory:YES]);
    NSString *sourcePath = canonical(sourceURL);
    NSString *filename = [NSString stringWithFormat:@"SkincareInventory-%@-TrollStore.ipa", version];
    NSString *prefix = [cacheRoot stringByAppendingString:@"/"];
    NSArray<NSString *> *relative = [sourcePath hasPrefix:prefix]
        ? [[sourcePath substringFromIndex:prefix.length] componentsSeparatedByString:@"/"] : @[];
    if (relative.count != 2 || ![[NSUUID alloc] initWithUUIDString:relative[0]]
        || ![relative[1] isEqual:filename] || !regularFile(sourcePath, size)) {
        return @"更新文件位置无法验证，请在 App 中重新下载。";
    }

    // Snapshot the accepted regular file through a non-following descriptor,
    // validate its bytes, then install a separate immutable snapshot. No shell
    // is used and no path, command or bundle ID comes from webpage messages.
    int fd = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return @"无法读取更新文件，请重新下载。";
    struct stat sourceInfo;
    if (fstat(fd, &sourceInfo) != 0 || !S_ISREG(sourceInfo.st_mode)
        || sourceInfo.st_size < 0 || (NSUInteger)sourceInfo.st_size != size) {
        close(fd);
        return @"更新文件已变化，请重新下载。";
    }
    NSMutableData *snapshot = [NSMutableData dataWithCapacity:size];
    unsigned char buffer[65536];
    while (snapshot.length < size) {
        ssize_t count = read(fd, buffer, MIN(sizeof(buffer), size - snapshot.length));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        [snapshot appendBytes:buffer length:(NSUInteger)count];
    }
    unsigned char extra;
    ssize_t tail = read(fd, &extra, 1);
    close(fd);
    if (snapshot.length != size || tail != 0) return @"更新文件不完整，请重新下载。";
    NSError *error = nil;
    if (!InventoryValidateUpdateData(snapshot, version, sha256, size, &error)) {
        return error.localizedDescription ?: @"更新包身份校验失败，已停止安装。";
    }

    NSString *stagePath = [cacheRoot stringByAppendingPathComponent:[@"install-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if (![NSFileManager.defaultManager createDirectoryAtPath:stagePath withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:&error]) {
        return @"无法准备安装文件，请检查可用空间后重试。";
    }
    NSString *stagedFile = [stagePath stringByAppendingPathComponent:filename];
    if (![snapshot writeToFile:stagedFile options:NSDataWritingAtomic error:&error]
        || ![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0444}
            ofItemAtPath:stagedFile error:&error]) {
        [NSFileManager.defaultManager removeItemAtPath:stagePath error:nil];
        return @"无法保存安装文件，请检查可用空间后重试。";
    }
    // Recheck the local helper immediately before spawning the reviewed fixed
    // command. We intentionally do not support arbitrary installers or flags.
    NSString *checkedHelper = findReviewedHelper(&reason);
    if (![helper isEqual:checkedHelper]) {
        [NSFileManager.defaultManager removeItemAtPath:stagePath error:nil];
        return reason ?: @"巨魔安装助手已变化，请重试。";
    }

    PersonaFunction persona = (PersonaFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    PersonaIDFunction uid = (PersonaIDFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    PersonaIDFunction gid = (PersonaIDFunction)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    posix_spawnattr_t attributes;
    int spawnError = posix_spawnattr_init(&attributes);
    BOOL attributesReady = spawnError == 0;
    if (!spawnError) spawnError = persona(&attributes, 99, 1);
    if (!spawnError) spawnError = uid(&attributes, 0);
    if (!spawnError) spawnError = gid(&attributes, 0);
    pid_t child = -1;
    char *arguments[] = {(char *)helper.fileSystemRepresentation, "install", (char *)stagedFile.fileSystemRepresentation, NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/root", "TMPDIR=/var/tmp", NULL};
    if (!spawnError) spawnError = posix_spawn(&child, helper.fileSystemRepresentation, NULL,
                                             &attributes, arguments, environment);
    if (attributesReady) posix_spawnattr_destroy(&attributes);
    if (spawnError || child <= 0) {
        [NSFileManager.defaultManager removeItemAtPath:stagePath error:nil];
        return @"当前设备未允许原地安装，可改用巨魔文件交接覆盖更新。";
    }
    int status = 0;
    pid_t waited;
    // The helper owns the installation transaction. Waiting happens on a
    // background queue; do not kill it on an arbitrary timeout and risk
    // interrupting a partially completed app replacement.
    do { waited = waitpid(child, &status, 0); } while (waited == -1 && errno == EINTR);
    [NSFileManager.defaultManager removeItemAtPath:stagePath error:nil];
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        return @"原地安装未完成，请核对库存后重试，或改用巨魔文件交接。";
    }
    // The helper returning 0 is useful diagnostic evidence but is not itself a
    // post-relaunch version check. The UI verifies the version at next launch.
    return nil;
}
