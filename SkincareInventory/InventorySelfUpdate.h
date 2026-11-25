#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Call on a background queue. A nil result means the installed helper matches
/// the reviewed official release; it does not prove device execution succeeded.
FOUNDATION_EXPORT NSString * _Nullable InventorySelfUpdateUnavailableReason(void);

/// Fixed self-update operation only. Waits for the child off the main thread.
/// A successful self-update terminates the old app, so it normally cannot return
/// to the old UI. A returned message describes a failure, never an install URL.
FOUNDATION_EXPORT NSString * _Nullable InventoryPerformSelfUpdate(
    NSURL *sourceURL, NSString *version, NSString *sha256, NSUInteger size
);

NS_ASSUME_NONNULL_END
