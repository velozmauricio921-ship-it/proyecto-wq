#import "WQAuthGate.h"
#import "WQTheme.h"
#import "WQUI.h"
#import <Security/Security.h>
#import <math.h>

static NSString *const kWQAuthRememberKey = @"WQKeyAuthRememberLicense";
static NSString *const kWQAuthLicenseService = @"cz.kolbi.wqfiles.keyauth.license";
static NSString *const kWQAuthLicenseAccount = @"license";
static NSString *const kWQAuthBaseURL = @"https://keyauth.win/api/1.2/";

typedef void (^WQAuthCompletion)(BOOL valid, NSString *message, BOOL definitiveFailure);

static NSString *wq_auth_config(NSString *key)
{
    id value = NSBundle.mainBundle.infoDictionary[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static BOOL wq_auth_is_configured(void)
{
    return wq_auth_config(@"WQKeyAuthAppName").length &&
        wq_auth_config(@"WQKeyAuthOwnerID").length && wq_auth_config(@"WQKeyAuthSecret").length;
}

static NSString *wq_auth_hardware_id(void)
{
    NSString *identifier = UIDevice.currentDevice.identifierForVendor.UUIDString;
    if (identifier.length) return identifier;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *saved = [defaults stringForKey:@"WQKeyAuthHardwareID"];
    if (saved.length) return saved;
    saved = NSUUID.UUID.UUIDString;
    [defaults setObject:saved forKey:@"WQKeyAuthHardwareID"];
    return saved;
}

static NSString *wq_auth_saved_license(void)
{
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWQAuthLicenseService,
        (__bridge id)kSecAttrAccount: kWQAuthLicenseAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess || !result) return @"";
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static BOOL wq_auth_store_license(NSString *license)
{
    NSData *data = [license dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWQAuthLicenseService,
        (__bridge id)kSecAttrAccount: kWQAuthLicenseAccount,
    };
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        [item addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}

static void wq_auth_delete_license(void)
{
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kWQAuthLicenseService,
        (__bridge id)kSecAttrAccount: kWQAuthLicenseAccount,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}

static NSURL *wq_auth_url(NSArray<NSURLQueryItem *> *items)
{
    NSURLComponents *components = [NSURLComponents componentsWithString:kWQAuthBaseURL];
    if (!components) return nil;
    components.queryItems = items;
    return components.URL;
}

static NSDate *wq_auth_expiry(id value)
{
    if ([value isKindOfClass:NSNumber.class]) {
        double number = [value doubleValue];
        if (number > 1000000000000.0) return [NSDate dateWithTimeIntervalSince1970:number / 1000.0];
        if (number > 1500000000.0) return [NSDate dateWithTimeIntervalSince1970:number];
        return [NSDate dateWithTimeIntervalSinceNow:number > 0 && number <= 31 ? number * 86400.0 : number];
    }
    if (![value isKindOfClass:NSString.class] || ![value length]) return nil;
    NSString *text = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double number = 0;
    if ([scanner scanDouble:&number] && scanner.isAtEnd) return wq_auth_expiry(@(number));
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new];
    iso.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [iso dateFromString:text];
    if (!date) {
        iso.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [iso dateFromString:text];
    }
    if (date) return date;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    for (NSString *format in @[@"yyyy-MM-dd HH:mm:ss", @"yyyy-MM-dd", @"dd/MM/yyyy", @"dd-MM-yyyy"]) {
        formatter.dateFormat = format;
        date = [formatter dateFromString:text];
        if (date) return date;
    }
    return nil;
}

static NSDate *wq_auth_timeleft(id value)
{
    double seconds = 0;
    if ([value isKindOfClass:NSNumber.class]) {
        seconds = [value doubleValue];
    } else if ([value isKindOfClass:NSString.class]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        if (![scanner scanDouble:&seconds] || !scanner.isAtEnd) return nil;
    } else {
        return nil;
    }
    return isfinite(seconds) ? [NSDate dateWithTimeIntervalSinceNow:seconds] : nil;
}

static NSDictionary *wq_auth_json(NSData *data)
{
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

static NSString *wq_auth_string(id value)
{
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return @"";
}

static void wq_auth_validate(NSString *license, WQAuthCompletion completion)
{
    NSString *appName = wq_auth_config(@"WQKeyAuthAppName");
    NSString *ownerID = wq_auth_config(@"WQKeyAuthOwnerID");
    NSString *secret = wq_auth_config(@"WQKeyAuthSecret");
    if (!appName.length || !ownerID.length || !secret.length) {
        completion(NO, @"KeyAuth no está configurado para esta compilación.", YES);
        return;
    }
    NSString *cleanLicense = [license stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!cleanLicense.length) {
        completion(NO, @"Ingresa tu licencia.", YES);
        return;
    }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 20;
    configuration.HTTPCookieStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSArray<NSURLQueryItem *> *initItems = @[
        [NSURLQueryItem queryItemWithName:@"type" value:@"init"],
        [NSURLQueryItem queryItemWithName:@"name" value:appName],
        [NSURLQueryItem queryItemWithName:@"ownerid" value:ownerID],
        [NSURLQueryItem queryItemWithName:@"secret" value:secret],
        [NSURLQueryItem queryItemWithName:@"version" value:@"1.0"],
    ];
    NSURL *initURL = wq_auth_url(initItems);
    if (!initURL) {
        [session finishTasksAndInvalidate];
        completion(NO, @"La configuración de KeyAuth no es válida.", YES);
        return;
    }
    NSMutableURLRequest *initRequest = [NSMutableURLRequest requestWithURL:initURL];
    initRequest.HTTPMethod = @"GET";
    [initRequest setValue:@"KeyAuth" forHTTPHeaderField:@"User-Agent"];
    [[session dataTaskWithRequest:initRequest completionHandler:^(NSData *initData, NSURLResponse *initResponse, NSError *initError) {
        NSDictionary *initJSON = initData ? wq_auth_json(initData) : nil;
        NSHTTPURLResponse *httpInit = [initResponse isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)initResponse : nil;
        NSNumber *initSuccess = initJSON[@"success"];
        NSString *sessionID = [initJSON[@"sessionid"] isKindOfClass:NSString.class] ? initJSON[@"sessionid"] : nil;
        if (initError || !httpInit || httpInit.statusCode < 200 || httpInit.statusCode >= 300 ||
            ![initSuccess isKindOfClass:NSNumber.class] || !initSuccess.boolValue || !sessionID.length) {
            [session finishTasksAndInvalidate];
            completion(NO, @"No se pudo iniciar una sesión con KeyAuth. Revisa tu conexión e inténtalo de nuevo.", NO);
            return;
        }
        NSArray<NSURLQueryItem *> *licenseItems = @[
            [NSURLQueryItem queryItemWithName:@"type" value:@"license"],
            [NSURLQueryItem queryItemWithName:@"key" value:cleanLicense],
            [NSURLQueryItem queryItemWithName:@"hwid" value:wq_auth_hardware_id()],
            [NSURLQueryItem queryItemWithName:@"sessionid" value:sessionID],
            [NSURLQueryItem queryItemWithName:@"name" value:appName],
            [NSURLQueryItem queryItemWithName:@"ownerid" value:ownerID],
        ];
        NSURL *licenseURL = wq_auth_url(licenseItems);
        if (!licenseURL) {
            [session finishTasksAndInvalidate];
            completion(NO, @"La configuración de KeyAuth no es válida.", YES);
            return;
        }
        NSMutableURLRequest *licenseRequest = [NSMutableURLRequest requestWithURL:licenseURL];
        licenseRequest.HTTPMethod = @"GET";
        [licenseRequest setValue:@"KeyAuth" forHTTPHeaderField:@"User-Agent"];
        [[session dataTaskWithRequest:licenseRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [session finishTasksAndInvalidate];
            NSDictionary *json = data ? wq_auth_json(data) : nil;
            NSNumber *success = json[@"success"];
            if (error || ![response isKindOfClass:NSHTTPURLResponse.class] ||
                ((NSHTTPURLResponse *)response).statusCode < 200 || ((NSHTTPURLResponse *)response).statusCode >= 300) {
                completion(NO, @"No se pudo conectar con KeyAuth. Inténtalo de nuevo.", NO);
                return;
            }
            if (![success isKindOfClass:NSNumber.class] || !success.boolValue) {
                NSString *message = [json[@"message"] isKindOfClass:NSString.class] ? json[@"message"] : @"Licencia inválida o expirada.";
                completion(NO, message, YES);
                return;
            }
            NSDictionary *info = [json[@"info"] isKindOfClass:NSDictionary.class] ? json[@"info"] : nil;
            NSArray *subscriptions = [info[@"subscriptions"] isKindOfClass:NSArray.class] ? info[@"subscriptions"] : nil;
            NSDictionary *firstSubscription = [subscriptions.firstObject isKindOfClass:NSDictionary.class] ? subscriptions.firstObject : nil;
            id rawHWID = json[@"hwid"] ?: info[@"hwid"];
            NSString *serverHWID = [rawHWID isKindOfClass:NSString.class] ? rawHWID : @"";
            if (serverHWID.length && ![serverHWID isEqualToString:wq_auth_hardware_id()]) {
                completion(NO, @"La licencia está vinculada a otro dispositivo.", YES);
                return;
            }
            id rawExpiry = json[@"expiry"] ?: firstSubscription[@"expiry"];
            NSDate *expiry = wq_auth_expiry(rawExpiry);
            if (!expiry) expiry = wq_auth_timeleft(firstSubscription[@"timeleft"]);
            if (expiry && expiry.timeIntervalSinceNow <= 0) {
                completion(NO, @"La licencia expiró.", YES);
                return;
            }
            NSString *status = [[@[wq_auth_string(json[@"status"]), wq_auth_string(json[@"result"]),
                                   wq_auth_string(json[@"message"]), wq_auth_string(json[@"error"])]
                                  componentsJoinedByString:@" "] lowercaseString];
            for (NSString *word in @[@"expired", @"invalid", @"revoked", @"banned", @"denied", @"already used", @"already in use"]) {
                if ([status containsString:word]) {
                    completion(NO, @"La licencia no está activa.", YES);
                    return;
                }
            }
            completion(YES, @"", NO);
        }] resume];
    }] resume];
}

@interface WQAuthGateViewController ()
@end

@implementation WQAuthGateViewController {
    UITextField *_licenseField;
    UISwitch *_rememberSwitch;
    UIButton *_continueButton;
    UIActivityIndicatorView *_spinner;
    UILabel *_statusLabel;
    BOOL _validating;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"BAIJ STORE MOD";
    wq_prism_install_background(self);
    self.view.backgroundColor = UIColor.clearColor;
    self.view.tintColor = wq_theme_accent();
    [self buildInterface];
    BOOL configured = wq_auth_is_configured();
    _licenseField.enabled = configured;
    _continueButton.enabled = configured;
    if (!configured) {
        _statusLabel.text = @"KeyAuth no está configurado para esta compilación.";
        _statusLabel.textColor = UIColor.systemRedColor;
        return;
    }
    BOOL remember = [NSUserDefaults.standardUserDefaults boolForKey:kWQAuthRememberKey];
    _rememberSwitch.on = remember;
    NSString *saved = remember ? wq_auth_saved_license() : @"";
    _licenseField.text = saved;
    if (saved.length) [self validateLicense:saved automatic:YES];
}

- (void)buildInterface
{
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 22;

    UIView *brandTile = [UIView new];
    brandTile.translatesAutoresizingMaskIntoConstraints = NO;
    brandTile.backgroundColor = wq_theme_accent();
    brandTile.layer.cornerRadius = 17;
    brandTile.layer.cornerCurve = kCACornerCurveContinuous;
    brandTile.clipsToBounds = YES;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"key.horizontal.fill"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.whiteColor;
    [brandTile addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [brandTile.widthAnchor constraintEqualToConstant:58], [brandTile.heightAnchor constraintEqualToConstant:58],
        [icon.centerXAnchor constraintEqualToAnchor:brandTile.centerXAnchor], [icon.centerYAnchor constraintEqualToAnchor:brandTile.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:28], [icon.heightAnchor constraintEqualToConstant:28],
    ]];
    UIView *brandRow = [UIView new];
    brandRow.translatesAutoresizingMaskIntoConstraints = NO;
    [brandRow addSubview:brandTile];
    [NSLayoutConstraint activateConstraints:@[
        [brandRow.heightAnchor constraintEqualToConstant:58],
        [brandTile.centerXAnchor constraintEqualToAnchor:brandRow.centerXAnchor],
        [brandTile.centerYAnchor constraintEqualToAnchor:brandRow.centerYAnchor],
    ]];
    UILabel *title = [UILabel new];
    title.text = @"BAIJ STORE MOD";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    UILabel *message = [UILabel new];
    message.text = @"Inicia sesión con tu licencia de KeyAuth para continuar.";
    message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    message.textColor = UIColor.secondaryLabelColor;
    message.numberOfLines = 0;
    message.textAlignment = NSTextAlignmentCenter;
    _licenseField = [UITextField new];
    _licenseField.borderStyle = UITextBorderStyleRoundedRect;
    _licenseField.placeholder = @"Licencia";
    _licenseField.backgroundColor = UIColor.tertiarySystemBackgroundColor;
    _licenseField.layer.cornerRadius = 12;
    _licenseField.layer.cornerCurve = kCACornerCurveContinuous;
    _licenseField.clipsToBounds = YES;
    _licenseField.autocorrectionType = UITextAutocorrectionTypeNo;
    _licenseField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _licenseField.returnKeyType = UIReturnKeyGo;
    [_licenseField addTarget:self action:@selector(submit) forControlEvents:UIControlEventEditingDidEndOnExit];
    [_licenseField.heightAnchor constraintEqualToConstant:50].active = YES;

    UIButtonConfiguration *button = [UIButtonConfiguration filledButtonConfiguration];
    button.title = @"Continuar";
    button.image = [UIImage systemImageNamed:@"arrow.right"];
    button.imagePlacement = NSDirectionalRectEdgeTrailing;
    button.imagePadding = 8;
    button.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    button.baseBackgroundColor = wq_theme_accent();
    _continueButton = [UIButton buttonWithConfiguration:button primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        [self submit];
    }]];
    [_continueButton.heightAnchor constraintEqualToConstant:50].active = YES;
    _continueButton.accessibilityHint = @"Valida la licencia con KeyAuth";

    _rememberSwitch = [UISwitch new];
    UILabel *rememberLabel = [UILabel new];
    rememberLabel.text = @"Recordar licencia en este dispositivo";
    rememberLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    rememberLabel.numberOfLines = 0;
    UIStackView *rememberRow = [[UIStackView alloc] initWithArrangedSubviews:@[rememberLabel, _rememberSwitch]];
    rememberRow.axis = UILayoutConstraintAxisHorizontal;
    rememberRow.alignment = UIStackViewAlignmentCenter;
    rememberRow.spacing = 12;

    UIStackView *progressRow = [[UIStackView alloc] initWithFrame:CGRectZero];
    progressRow.axis = UILayoutConstraintAxisVertical;
    progressRow.alignment = UIStackViewAlignmentCenter;
    progressRow.spacing = 8;
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.numberOfLines = 0;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    [progressRow addArrangedSubview:_spinner];
    [progressRow addArrangedSubview:_statusLabel];

    UIStackView *form = [[UIStackView alloc] initWithArrangedSubviews:@[_licenseField, _continueButton, rememberRow, progressRow]];
    form.axis = UILayoutConstraintAxisVertical;
    form.alignment = UIStackViewAlignmentFill;
    form.spacing = 16;

    UIView *surface = [UIView new];
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    surface.layer.cornerRadius = 24;
    surface.layer.cornerCurve = kCACornerCurveContinuous;
    surface.clipsToBounds = YES;
    surface.layer.borderWidth = 1;
    surface.layer.borderColor = UIColor.separatorColor.CGColor;
    surface.backgroundColor = wq_theme_card() ?: [UIColor colorWithWhite:0.5 alpha:0.05];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    [surface addSubview:blur];
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:surface.topAnchor], [blur.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor], [blur.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor],
    ]];
    [surface addSubview:form];
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [form.topAnchor constraintEqualToAnchor:surface.topAnchor constant:22],
        [form.bottomAnchor constraintEqualToAnchor:surface.bottomAnchor constant:-22],
        [form.leadingAnchor constraintEqualToAnchor:surface.leadingAnchor constant:20],
        [form.trailingAnchor constraintEqualToAnchor:surface.trailingAnchor constant:-20],
    ]];

    [stack addArrangedSubview:brandRow];
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:message];
    [stack addArrangedSubview:surface];
    [scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:32],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:22],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-22],
        [stack.centerXAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerXAnchor],
        [stack.widthAnchor constraintGreaterThanOrEqualToConstant:260],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:520],
    ]];
}

- (void)submit
{
    [self validateLicense:_licenseField.text ?: @"" automatic:NO];
}

- (void)validateLicense:(NSString *)license automatic:(BOOL)automatic
{
    if (_validating) return;
    _validating = YES;
    _continueButton.enabled = NO;
    _licenseField.enabled = NO;
    _rememberSwitch.enabled = NO;
    _statusLabel.text = @"Validando licencia con KeyAuth…";
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    [_spinner startAnimating];
    __weak typeof(self) weakSelf = self;
    wq_auth_validate(license, ^(BOOL valid, NSString *message, BOOL definitiveFailure) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WQAuthGateViewController *screen = weakSelf;
            if (!screen) return;
            screen->_validating = NO;
            [screen->_spinner stopAnimating];
            screen->_continueButton.enabled = YES;
            screen->_licenseField.enabled = YES;
            screen->_rememberSwitch.enabled = YES;
            if (!valid) {
                NSString *saved = wq_auth_saved_license();
                NSString *cleanLicense = [license stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (definitiveFailure && (automatic || [saved isEqualToString:cleanLicense])) {
                    wq_auth_delete_license();
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kWQAuthRememberKey];
                    screen->_rememberSwitch.on = NO;
                }
                screen->_statusLabel.text = message;
                screen->_statusLabel.textColor = UIColor.systemRedColor;
                return;
            }
            BOOL remember = screen->_rememberSwitch.isOn;
            [NSUserDefaults.standardUserDefaults setBool:remember forKey:kWQAuthRememberKey];
            if (remember) wq_auth_store_license([license stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
            else wq_auth_delete_license();
            void (^authenticated)(NSURL *) = screen.onAuthenticated;
            NSURL *pendingURL = screen.pendingURL;
            if (authenticated) authenticated(pendingURL);
        });
    });
}

@end
