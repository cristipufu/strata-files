#import <Foundation/Foundation.h>
#import <os/log.h>

static inline NSError *_Nonnull STPreviewError(NSString *_Nonnull operation, NSException *_Nullable exception) {
    NSMutableDictionary *info = [@{ @"operation": operation } mutableCopy];
    if (exception) {
        info[NSLocalizedDescriptionKey] = exception.reason ?: exception.name;
        info[@"exceptionName"] = exception.name;
    }
    NSError *error = [NSError errorWithDomain:@"StrataTextPreview" code:exception ? 1 : 2 userInfo:info];
    os_log_error(OS_LOG_DEFAULT, "Strata text preview stopped during %{public}@: %{private}@", operation, error);
    return error;
}
