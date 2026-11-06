#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_UI_ACTOR
@interface STWebResourceTask : NSObject
@property(nonatomic, readonly, nullable) NSError *failure;
- (instancetype)initWithTask:(id<WKURLSchemeTask>)task;
- (BOOL)receiveResponse:(NSURLResponse *)response NS_SWIFT_NAME(receive(_:));
- (BOOL)receiveData:(NSData *)data NS_SWIFT_NAME(receive(_:));
- (BOOL)finish;
- (void)fail:(NSError *)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
