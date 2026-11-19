#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQAuthGateViewController : UIViewController
@property (nonatomic, copy, nullable) void (^onAuthenticated)(NSURL *_Nullable pendingURL);
@property (nonatomic, copy, nullable) NSURL *pendingURL;
@end

NS_ASSUME_NONNULL_END