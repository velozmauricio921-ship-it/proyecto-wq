#import "WQPatchAccessBridge.h"
#import "WQAccess.h"
#import "WQLaunchServices.h"
#import <errno.h>
#import <sys/stat.h>

static NSString *WQPatchCanonicalPath(NSString *path)
{
    NSString *canonical = path.stringByStandardizingPath;
    if ([canonical isEqualToString:@"/var"] || [canonical hasPrefix:@"/var/"]) {
        canonical = [@"/private" stringByAppendingString:canonical];
    }
    return canonical;
}

static BOOL WQPatchIsApplicationDataContainer(NSString *path)
{
    NSString *canonical = WQPatchCanonicalPath(path);
    NSString *applicationRoot = @"/private/var/mobile/Containers/Data/Application";
    NSUUID *containerUUID = [[NSUUID alloc] initWithUUIDString:canonical.lastPathComponent];
    if (![canonical.stringByDeletingLastPathComponent isEqualToString:applicationRoot] ||
        !containerUUID) {
        return NO;
    }
    struct stat metadata;
    return lstat(canonical.fileSystemRepresentation, &metadata) == 0 && S_ISDIR(metadata.st_mode);
}

NSString *WQPatchResolveApplicationContainer(NSString *bundleID)
{
    if (!bundleID.length) return nil;
    for (NSString *candidate in wq_ls_container_paths(nil) ?: @[]) {
        NSString *canonical = WQPatchCanonicalPath(candidate);
        if (!WQPatchIsApplicationDataContainer(canonical)) continue;
        NSString *resolvedID = wq_bundle_id_for_container(candidate) ?: wq_container_label(candidate);
        if (![resolvedID isEqualToString:bundleID]) continue;
        if (!wq_grant(canonical) || !WQPatchIsApplicationDataContainer(canonical)) return nil;
        return canonical;
    }
    return nil;
}

BOOL WQPatchAuthorizePath(NSString *path)
{
    NSString *canonical = WQPatchCanonicalPath(path);
    struct stat metadata;
    if (lstat(canonical.fileSystemRepresentation, &metadata) == 0) {
        if (S_ISLNK(metadata.st_mode)) return NO;
        if (S_ISDIR(metadata.st_mode)) return wq_grant(canonical);
        if (S_ISREG(metadata.st_mode)) {
            return wq_grant(canonical) || wq_grant(canonical.stringByDeletingLastPathComponent);
        }
        return NO;
    }
    if (errno != ENOENT) return NO;

    NSString *parent = canonical.stringByDeletingLastPathComponent;
    if (lstat(parent.fileSystemRepresentation, &metadata) != 0 || !S_ISDIR(metadata.st_mode)) return NO;
    return wq_grant(parent);
}

NSData *WQPatchContainerIdentity(NSString *path, NSString *bundleID)
{
    NSString *canonical = WQPatchCanonicalPath(path);
    struct stat metadata;
    if (lstat(canonical.fileSystemRepresentation, &metadata) != 0 ||
        !S_ISDIR(metadata.st_mode)) {
        return nil;
    }

    NSString *label = wq_container_label(canonical);
    NSDictionary *identity = @{
        @"bundleID": bundleID ?: @"",
        @"containerLabel": label ?: @"",
        @"containerUUID": canonical.lastPathComponent ?: @"",
        @"canonicalPath": canonical ?: @"",
        @"device": @(metadata.st_dev),
        @"inode": @(metadata.st_ino),
        @"type": @((metadata.st_mode & S_IFMT))
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:identity
                                                  options:NSJSONWritingSortedKeys
                                                    error:&error];
    return error ? nil : data;
}