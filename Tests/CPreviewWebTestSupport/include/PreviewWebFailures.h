#import <PreviewWebTask.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, STWebFailurePoint) {
    STWebFailureNone, STWebFailureResponse, STWebFailureData, STWebFailureCompletion, STWebFailureFailure
};

NS_SWIFT_UI_ACTOR
@interface STFailingWebSchemeTask : NSObject <WKURLSchemeTask>
@property(nonatomic) STWebFailurePoint failurePoint;
@property(nonatomic, copy, nullable) void (^eventOccurred)(void);
@property(nonatomic, readonly) NSArray<NSString *> *events;
@end
NS_ASSUME_NONNULL_END
