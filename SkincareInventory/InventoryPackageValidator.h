#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Validates only these immutable bytes. Does not read paths, extract files,
/// access inventory, contact a network service or invoke an installer.
FOUNDATION_EXPORT BOOL InventoryValidateUpdateData(
    NSData *data,
    NSString *expectedVersion,
    NSString *expectedSHA256,
    NSUInteger expectedSize,
    NSError * _Nullable * _Nullable error
);

NS_ASSUME_NONNULL_END
