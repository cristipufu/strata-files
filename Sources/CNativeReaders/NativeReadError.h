#import <Foundation/Foundation.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN
static inline NSError *STNativeReadFailure(NSString *operation, NSException *exception) {
    os_log_error(OS_LOG_DEFAULT, "Strata native reader stopped during %{public}@: %{private}@", operation, exception.reason);
    return [NSError errorWithDomain:@"StrataNativeRead" code:1 userInfo:@{
        NSLocalizedDescriptionKey: exception.reason ?: exception.name, @"operation": operation, @"exceptionName": exception.name
    }];
}
NS_ASSUME_NONNULL_END
