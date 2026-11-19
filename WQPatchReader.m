#import "WQPatchReader.h"
#import "WQAccess.h"
#import "WQUI.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <CommonCrypto/CommonDigest.h>

// CommonCrypto implements this GCM SPI, but the iOS SDK omits its declaration.
extern CCCryptorStatus CCCryptorGCMOneshotDecrypt(CCAlgorithm algorithm, const void *key, size_t keyLength,
    const void *iv, size_t ivLength, const void *aad, size_t aadLength,
    const void *ciphertext, size_t ciphertextLength, void *plaintext,
    const void *tag, size_t tagLength);

static const NSUInteger WQPatchReaderMaximumPackageBytes = 512u * 1024u * 1024u;
static const NSUInteger WQPatchReaderMaximumEntries = 100000;
static const NSUInteger WQPatchReaderTextPreviewLimit = 4u * 1024u * 1024u;
static const uint8_t WQPatchReaderMagic[] = { '3', '1', '0', '5', 'P', 'A', 'T', 'C', 'H', 0 };

@interface WQPatchReaderEntry : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic, strong) NSData *data;
@property (nonatomic) BOOL directory;
@end
@implementation WQPatchReaderEntry
@end

@interface WQPatchReaderPackage : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *packageID;
@property (nonatomic) NSInteger schemaVersion;
@property (nonatomic) BOOL passwordProtected;
@property (nonatomic, copy) NSArray<WQPatchReaderEntry *> *entries;
+ (nullable instancetype)decode:(NSData *)data password:(nullable NSString *)password error:(NSString **)error;
@end

static NSData *wq_patch_sha256(NSData *data)
{
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    const uint8_t *bytes = data.bytes;
    for (NSUInteger offset = 0; offset < data.length;) {
        CC_LONG amount = (CC_LONG)MIN((NSUInteger)UINT32_MAX, data.length - offset);
        CC_SHA256_Update(&context, bytes + offset, amount);
        offset += amount;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static void wq_patch_set_error(NSString **error, NSString *message)
{
    if (error) *error = message;
}

static NSData *wq_patch_gcm_open(NSData *combined, NSData *key, NSData *aad)
{
    if (combined.length < 28 || key.length != 32) return nil;
    NSData *nonce = [combined subdataWithRange:NSMakeRange(0, 12)];
    NSData *tag = [combined subdataWithRange:NSMakeRange(combined.length - 16, 16)];
    NSData *ciphertext = [combined subdataWithRange:NSMakeRange(12, combined.length - 28)];
    NSMutableData *plaintext = [NSMutableData dataWithLength:ciphertext.length];
    CCCryptorStatus status = CCCryptorGCMOneshotDecrypt(
        kCCAlgorithmAES, key.bytes, key.length, nonce.bytes, nonce.length,
        aad.bytes, aad.length, ciphertext.bytes, ciphertext.length,
        plaintext.mutableBytes, tag.bytes, tag.length);
    return status == kCCSuccess ? plaintext : nil;
}

static NSData *wq_patch_password_key(NSString *password, NSData *salt, NSUInteger iterations)
{
    NSData *passwordData = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (salt.length != 16 || iterations < 100000 || iterations > 1000000 || passwordData.length > 1024) return nil;
    NSMutableData *key = [NSMutableData dataWithLength:32];
    int status = CCKeyDerivationPBKDF(kCCPBKDF2, passwordData.bytes, passwordData.length,
                                      salt.bytes, salt.length, kCCPRFHmacAlgSHA256,
                                      (uint32_t)iterations, key.mutableBytes, key.length);
    return status == kCCSuccess ? key : nil;
}

static BOOL wq_patch_safe_relative_path(NSString *path)
{
    if (!path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@"//"] ||
        [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 4096) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqualToString:@"."] || [part isEqualToString:@".."] ||
            [part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    return YES;
}

static BOOL wq_patch_valid_bundle(NSString *bundle)
{
    if (!bundle.length || bundle.length > 255 || [bundle containsString:@"/"] || [bundle containsString:@"\\"]) return NO;
    NSArray<NSString *> *parts = [bundle componentsSeparatedByString:@"."];
    if (parts.count < 2) return NO;
    for (NSString *part in parts) {
        if (!part.length || [part hasPrefix:@"-"] || [part hasSuffix:@"-"]) return NO;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
        if ([part rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return NO;
    }
    return YES;
}

static NSArray<NSString *> *wq_patch_bundled_paths(NSString *root)
{
    NSMutableArray<NSString *> *paths = [NSMutableArray new];
    for (NSString *relative in [NSFileManager.defaultManager subpathsAtPath:root] ?: @[]) {
        if ([relative.pathExtension caseInsensitiveCompare:@"3105"] != NSOrderedSame) continue;
        NSString *path = [root stringByAppendingPathComponent:relative];
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) [paths addObject:path];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a localizedStandardCompare:b];
    }];
    return paths;
}

@implementation WQPatchReaderPackage

+ (instancetype)decode:(NSData *)data password:(NSString *)password error:(NSString **)error
{
    if (data.length > WQPatchReaderMaximumPackageBytes || data.length <= sizeof(WQPatchReaderMagic) ||
        memcmp(data.bytes, WQPatchReaderMagic, sizeof(WQPatchReaderMagic)) != 0) {
        wq_patch_set_error(error, @"This is not a supported .3105 patch package.");
        return nil;
    }
    NSData *body = [data subdataWithRange:NSMakeRange(sizeof(WQPatchReaderMagic), data.length - sizeof(WQPatchReaderMagic))];
    NSDictionary *envelope = [NSPropertyListSerialization propertyListWithData:body options:0 format:nil error:nil];
    if (![envelope isKindOfClass:NSDictionary.class]) {
        wq_patch_set_error(error, @"The patch package is damaged or incomplete.");
        return nil;
    }
    NSNumber *schema = envelope[@"schemaVersion"];
    NSString *packageID = envelope[@"packageID"];
    NSData *fingerprint = envelope[@"keyFingerprint"];
    NSData *encryptedPayload = envelope[@"encryptedPayload"];
    BOOL protected = [envelope[@"isPasswordProtected"] boolValue];
    if (![schema isKindOfClass:NSNumber.class] || schema.integerValue < 1 || schema.integerValue > 2 ||
        ![packageID isKindOfClass:NSString.class] ||
        ![fingerprint isKindOfClass:NSData.class] || fingerprint.length != 32 ||
        ![encryptedPayload isKindOfClass:NSData.class] || encryptedPayload.length < 28) {
        wq_patch_set_error(error, @"The patch package header is invalid or uses an unsupported version.");
        return nil;
    }
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:packageID];
    if (!uuid) {
        wq_patch_set_error(error, @"The patch package header is invalid.");
        return nil;
    }

    NSData *contentKey = nil;
    if (protected) {
        if (!password.length) {
            if (error) *error = @"This patch package requires a password.";
            return nil;
        }
        NSNumber *iterations = envelope[@"kdfIterations"];
        NSData *salt = envelope[@"kdfSalt"];
        NSData *wrappedKey = envelope[@"wrappedContentKey"];
        if (![iterations isKindOfClass:NSNumber.class] || ![salt isKindOfClass:NSData.class] ||
            ![wrappedKey isKindOfClass:NSData.class]) {
            wq_patch_set_error(error, @"The protected package header is invalid.");
            return nil;
        }
        NSData *wrappingKey = wq_patch_password_key(password, salt, iterations.unsignedIntegerValue);
        NSInteger aadVersion = [envelope[@"keyAADVersion"] respondsToSelector:@selector(integerValue)]
            ? [envelope[@"keyAADVersion"] integerValue] : schema.integerValue;
        NSString *aadText = [NSString stringWithFormat:@"3105PATCH/v%ld/key/%@", (long)aadVersion, uuid.UUIDString];
        contentKey = wrappingKey ? wq_patch_gcm_open(wrappedKey, wrappingKey, [aadText dataUsingEncoding:NSUTF8StringEncoding]) : nil;
    } else {
        contentKey = envelope[@"publicContentKey"];
    }
    if (![contentKey isKindOfClass:NSData.class] || contentKey.length != 32 ||
        ![wq_patch_sha256(contentKey) isEqualToData:fingerprint]) {
        wq_patch_set_error(error, protected ? @"The password is incorrect or the package is damaged." : @"The package key is invalid.");
        return nil;
    }
    NSString *payloadAAD = [NSString stringWithFormat:@"3105PATCH/v%ld/payload/%@", (long)schema.integerValue, uuid.UUIDString];
    NSData *payloadData = wq_patch_gcm_open(encryptedPayload, contentKey, [payloadAAD dataUsingEncoding:NSUTF8StringEncoding]);
    NSDictionary *payload = payloadData ? [NSPropertyListSerialization propertyListWithData:payloadData options:0 format:nil error:nil] : nil;
    NSDictionary *project = [payload isKindOfClass:NSDictionary.class] ? payload[@"project"] : nil;
    NSArray *rules = [project isKindOfClass:NSDictionary.class] ? project[@"rules"] : nil;
    NSArray *directories = [project isKindOfClass:NSDictionary.class] ? project[@"directories"] : nil;
    NSDictionary *digests = [payload isKindOfClass:NSDictionary.class] ? payload[@"replacementDigests"] : nil;
    NSString *projectID = [project isKindOfClass:NSDictionary.class] ? project[@"id"] : nil;
    NSString *name = [project isKindOfClass:NSDictionary.class] ? project[@"name"] : nil;
    if (![project isKindOfClass:NSDictionary.class] || ![rules isKindOfClass:NSArray.class] ||
        ![directories isKindOfClass:NSArray.class] || ![digests isKindOfClass:NSDictionary.class] ||
        ![projectID isKindOfClass:NSString.class] || ![[[NSUUID alloc] initWithUUIDString:projectID] isEqual:uuid] ||
        ![name isKindOfClass:NSString.class] || rules.count + directories.count > WQPatchReaderMaximumEntries ||
        digests.count != rules.count) {
        wq_patch_set_error(error, @"The package payload is invalid or failed authentication.");
        return nil;
    }

    NSMutableArray<WQPatchReaderEntry *> *entries = [NSMutableArray new];
    NSMutableSet<NSString *> *targets = [NSMutableSet new];
    for (id directoryValue in directories) {
        if (![directoryValue isKindOfClass:NSDictionary.class]) {
            wq_patch_set_error(error, @"The package contains an invalid folder entry.");
            return nil;
        }
        NSDictionary *directory = directoryValue;
        NSString *bundle = directory[@"bundleID"], *path = directory[@"relativePath"];
        NSString *target = [NSString stringWithFormat:@"%@\n%@", bundle ?: @"", path ?: @""];
        if (![bundle isKindOfClass:NSString.class] ||
            ![path isKindOfClass:NSString.class] || !wq_patch_valid_bundle(bundle) || !wq_patch_safe_relative_path(path) ||
            [targets containsObject:target]) {
            wq_patch_set_error(error, @"The package contains an invalid or duplicate target path.");
            return nil;
        }
        [targets addObject:target];
        WQPatchReaderEntry *entry = [WQPatchReaderEntry new];
        entry.bundleID = bundle; entry.relativePath = path; entry.directory = YES;
        [entries addObject:entry];
    }
    for (id ruleValue in rules) {
        if (![ruleValue isKindOfClass:NSDictionary.class]) {
            wq_patch_set_error(error, @"The package contains an invalid replacement entry.");
            return nil;
        }
        NSDictionary *rule = ruleValue;
        NSString *bundle = rule[@"bundleID"], *path = rule[@"relativePath"];
        NSString *filename = rule[@"replacementFilename"];
        NSString *ruleID = rule[@"id"];
        NSData *replacement = rule[@"replacementData"];
        NSData *digest = [ruleID isKindOfClass:NSString.class] ? digests[ruleID] : nil;
        NSString *target = [NSString stringWithFormat:@"%@\n%@", bundle ?: @"", path ?: @""];
        if (![bundle isKindOfClass:NSString.class] ||
            ![path isKindOfClass:NSString.class] || ![filename isKindOfClass:NSString.class] || !filename.length ||
            [filename containsString:@"/"] || [filename containsString:@"\\"] ||
            ![replacement isKindOfClass:NSData.class] || ![digest isKindOfClass:NSData.class] ||
            !wq_patch_valid_bundle(bundle) || !wq_patch_safe_relative_path(path) ||
            [targets containsObject:target] || ![wq_patch_sha256(replacement) isEqualToData:digest]) {
            wq_patch_set_error(error, @"The package contains an invalid, duplicate, or damaged replacement.");
            return nil;
        }
        [targets addObject:target];
        WQPatchReaderEntry *entry = [WQPatchReaderEntry new];
        entry.bundleID = bundle; entry.relativePath = path; entry.filename = filename; entry.data = replacement;
        [entries addObject:entry];
    }
    [entries sortUsingComparator:^NSComparisonResult(WQPatchReaderEntry *a, WQPatchReaderEntry *b) {
        NSString *left = [NSString stringWithFormat:@"%@/%@", a.bundleID, a.relativePath];
        NSString *right = [NSString stringWithFormat:@"%@/%@", b.bundleID, b.relativePath];
        return [left localizedStandardCompare:right];
    }];
    WQPatchReaderPackage *result = [WQPatchReaderPackage new];
    result.name = name; result.packageID = uuid.UUIDString; result.schemaVersion = schema.integerValue;
    result.passwordProtected = protected; result.entries = entries;
    return result;
}

@end

@interface WQPatchReaderContentViewController : UIViewController
- (instancetype)initWithEntry:(WQPatchReaderEntry *)entry;
@end

@implementation WQPatchReaderContentViewController {
    WQPatchReaderEntry *_entry;
    UITextView *_textView;
    UIImageView *_imageView;
}

- (instancetype)initWithEntry:(WQPatchReaderEntry *)entry
{
    if ((self = [super initWithNibName:nil bundle:nil])) { _entry = entry; self.title = entry.filename; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    NSData *data = _entry.data;
    UIImage *image = [UIImage imageWithData:data];
    if (image) {
        _imageView = [UIImageView new];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.image = image;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.view addSubview:_imageView];
        UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_imageView.topAnchor constraintEqualToAnchor:guide.topAnchor], [_imageView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
            [_imageView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor], [_imageView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        ]];
        self.navigationItem.prompt = [NSString stringWithFormat:@"%@ · %@ bytes · read only", _entry.relativePath, @(data.length)];
        return;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text && ![text containsString:@"\0"]) {
        if (text.length > WQPatchReaderTextPreviewLimit)
            text = [[text substringToIndex:WQPatchReaderTextPreviewLimit] stringByAppendingString:@"\n\nOnly the beginning is shown.\n"];
        _textView.text = text;
    } else {
        NSUInteger length = MIN(data.length, 64 * 1024);
        const uint8_t *bytes = data.bytes;
        NSMutableString *dump = [NSMutableString new];
        for (NSUInteger offset = 0; offset < length; offset += 16) {
            [dump appendFormat:@"%08lx  ", (unsigned long)offset];
            for (NSUInteger i = 0; i < 16; i++)
                if (offset + i < length) [dump appendFormat:@"%02x ", bytes[offset + i]];
                else [dump appendString:@"   "];
            [dump appendString:@"\n"];
        }
        if (data.length > length) [dump appendString:@"\nOnly the beginning is shown.\n"];
        _textView.text = dump;
    }
    [self.view addSubview:_textView];
    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:guide.topAnchor], [_textView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor], [_textView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
    ]];
    self.navigationItem.prompt = [NSString stringWithFormat:@"%@ · %@ bytes · read only", _entry.relativePath, @(data.length)];
}

@end

@implementation WQPatchReaderViewController {
    NSString *_sourcePath;
    NSURL *_sourceURL;
    NSString *_preloadedRoot;
    NSArray<NSString *> *_preloadedPaths;
    NSData *_packageData;
    WQPatchReaderPackage *_package;
    NSString *_status;
    BOOL _loading;
}

- (instancetype)init
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _preloadedRoot = [NSBundle.mainBundle.bundleURL.path stringByAppendingPathComponent:@"Preloaded"];
        _preloadedPaths = wq_patch_bundled_paths(_preloadedRoot);
    }
    return self;
}

- (instancetype)initWithPath:(NSString *)path
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _sourcePath = [path copy];
    return self;
}

- (instancetype)initWithURL:(NSURL *)url
{
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) _sourceURL = [url copy];
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Patches";
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
            target:self action:@selector(done)];
    if (_sourceURL) [self readURL:_sourceURL];
    else if (_sourcePath.length) [self readPath:_sourcePath];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)showPreloadedList
{
    _package = nil;
    _packageData = nil;
    _status = nil;
    _loading = NO;
    self.title = @"Patches";
    self.navigationItem.rightBarButtonItem = nil;
    [self.tableView reloadData];
}

- (void)readPath:(NSString *)path
{
    _loading = YES; _status = @"Reading patch package…"; [self.tableView reloadData];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(wq_io(), ^{
        struct stat st;
        NSString *error = nil;
        NSData *data = wq_stat(path, &st) && S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode) &&
            (unsigned long long)st.st_size <= WQPatchReaderMaximumPackageBytes
            ? wq_read(path, WQPatchReaderMaximumPackageBytes, &error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadedData:data error:error]; });
    });
}

- (void)readURL:(NSURL *)url
{
    _loading = YES; _status = @"Reading patch package…"; [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        __block NSData *data = nil;
        NSError *readError = nil;
        [[NSFileCoordinator new] coordinateReadingItemAtURL:url options:0 error:&readError byAccessor:^(NSURL *readURL) {
            NSNumber *size = nil;
            NSNumber *regular = nil, *symbolicLink = nil;
            [readURL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            [readURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            [readURL getResourceValue:&symbolicLink forKey:NSURLIsSymbolicLinkKey error:nil];
            if (regular.boolValue && !symbolicLink.boolValue && size.unsignedLongLongValue <= WQPatchReaderMaximumPackageBytes)
                data = [NSData dataWithContentsOfURL:readURL options:NSDataReadingMappedIfSafe error:nil];
        }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        NSString *error = readError.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{ [self loadedData:data error:error]; });
    });
}

- (void)loadedData:(NSData *)data error:(NSString *)error
{
    _loading = NO;
    if (!data) {
        _status = error ?: @"The package could not be read.";
        _package = nil; _packageData = nil;
        self.navigationItem.rightBarButtonItem.enabled = YES;
        [self.tableView reloadData];
        return;
    }
    _packageData = data;
    [self decodeWithPassword:nil];
}

- (void)decodeWithPassword:(NSString *)password
{
    NSData *data = _packageData;
    _loading = YES; _status = @"Reading patch contents…"; [self.tableView reloadData];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        WQPatchReaderPackage *package = [WQPatchReaderPackage decode:data password:password error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_loading = NO;
            if (!package && [error containsString:@"requires a password"]) {
                self.navigationItem.rightBarButtonItem.enabled = YES;
                [self requestPassword];
                return;
            }
            self->_package = package;
            self->_status = package ? nil : (error ?: @"The patch package could not be decoded.");
            self.title = package.name ?: @"Patches";
            self.navigationItem.rightBarButtonItem.enabled = YES;
            [self.tableView reloadData];
        });
    });
}

- (void)requestPassword
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Patch password"
        message:@"This package is password-protected. The password is used only to read it and is not saved."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.secureTextEntry = YES; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        self->_status = @"A password is required to read this package.";
        self.navigationItem.rightBarButtonItem.enabled = YES;
        [self.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Read" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self decodeWithPassword:alert.textFields.firstObject.text ?: @""];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return _package ? 2 : 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if (!_package) return (_loading || _sourcePath.length || _sourceURL || _packageData) ? 1 : MAX(1, (NSInteger)_preloadedPaths.count);
    return section == 0 ? 1 : (NSInteger)_package.entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (_package && section == 1) return @"Contents";
    return !_package && !_loading && !_sourcePath.length && !_sourceURL && !_packageData && _preloadedPaths.count ? @"Preloaded" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (!_package) {
        if (_loading) return nil;
        if (_sourcePath.length || _sourceURL || _packageData) return _status;
        return _preloadedPaths.count ? @"Bundled packages are read-only." : @"No preloaded .3105 packages are included.";
    }
    if (section == 0) {
        NSMutableOrderedSet<NSString *> *bundleIDs = [NSMutableOrderedSet new];
        for (WQPatchReaderEntry *entry in _package.entries) [bundleIDs addObject:entry.bundleID];
        NSString *bundleSummary = [bundleIDs.array componentsJoinedByString:@", "];
        NSUInteger fileCount = [_package.entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"directory == NO"]].count;
        NSUInteger directoryCount = [_package.entries filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"directory == YES"]].count;
        return [NSString stringWithFormat:@"%@\n%lu files · %lu folders · schema v%ld · read only",
                bundleSummary, (unsigned long)fileCount, (unsigned long)directoryCount, (long)_package.schemaVersion];
    }
    return @"Package contents are read-only. Nothing is applied or changed.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"patch-reader"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"patch-reader"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    if (!_package) {
        BOOL showingList = !_loading && !_sourcePath.length && !_sourceURL && !_packageData && _preloadedPaths.count;
        if (showingList) {
            NSString *path = _preloadedPaths[(NSUInteger)indexPath.row];
            NSString *relative = [path hasPrefix:[_preloadedRoot stringByAppendingString:@"/"]]
                ? [path substringFromIndex:_preloadedRoot.length + 1] : path.lastPathComponent;
            content.text = path.lastPathComponent;
            content.secondaryText = relative.stringByDeletingLastPathComponent;
            content.image = [UIImage systemImageNamed:@"doc.zipper"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        } else {
            content.text = _loading ? _status : @"No package open";
            content.secondaryText = _loading ? nil : _status;
            BOOL canRetry = !_loading && _packageData && [_status localizedCaseInsensitiveContainsString:@"password"];
            content.image = [UIImage systemImageNamed:_loading ? @"hourglass" : canRetry ? @"key" : @"doc.zipper"];
            cell.selectionStyle = canRetry ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        }
    } else if (indexPath.section == 0) {
        content.text = _package.name;
        content.secondaryText = _package.packageID;
        content.image = [UIImage systemImageNamed:_package.passwordProtected ? @"lock.doc" : @"doc.zipper"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        WQPatchReaderEntry *entry = _package.entries[(NSUInteger)indexPath.row];
        content.text = entry.directory ? entry.relativePath : (entry.filename.length ? entry.filename : entry.relativePath.lastPathComponent);
        content.secondaryText = [NSString stringWithFormat:@"%@ · %@", entry.bundleID, entry.relativePath];
        content.secondaryTextProperties.numberOfLines = 2;
        content.image = [UIImage systemImageNamed:entry.directory ? @"folder" : @"doc"];
        cell.accessoryType = entry.directory ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_package) {
        if (!_loading && !_sourcePath.length && !_sourceURL && !_packageData && (NSUInteger)indexPath.row < _preloadedPaths.count) {
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"list.bullet"]
                style:UIBarButtonItemStylePlain target:self action:@selector(showPreloadedList)];
            self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Preloaded Patches";
            [self readPath:_preloadedPaths[(NSUInteger)indexPath.row]];
            return;
        }
        if (!_loading && _packageData && [_status localizedCaseInsensitiveContainsString:@"password"]) [self requestPassword];
        return;
    }
    if (indexPath.section != 1) return;
    WQPatchReaderEntry *entry = _package.entries[(NSUInteger)indexPath.row];
    if (!entry.directory) [self.navigationController pushViewController:[[WQPatchReaderContentViewController alloc] initWithEntry:entry] animated:YES];
}

@end
