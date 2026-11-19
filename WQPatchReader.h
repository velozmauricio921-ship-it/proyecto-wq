#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WQPatchReaderViewController : UITableViewController
- (instancetype)init;
- (instancetype)initWithPath:(NSString *)path;
- (instancetype)initWithURL:(NSURL *)url;
@end

NS_ASSUME_NONNULL_END