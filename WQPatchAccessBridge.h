#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSString *_Nullable WQPatchResolveApplicationContainer(NSString *bundleID);
BOOL WQPatchAuthorizePath(NSString *path);
NSData *_Nullable WQPatchContainerIdentity(NSString *path, NSString *bundleID);
void WQPatchTrace(NSString *operationID, NSString *stage, NSString *result, double durationMilliseconds);

NS_ASSUME_NONNULL_END