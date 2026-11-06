#import "PreviewWebTask.h"
#import <os/log.h>

@implementation STWebResourceTask {
    id<WKURLSchemeTask> _task;
    BOOL _receiving;
    NSError *_failure;
}

- (instancetype)initWithTask:(id<WKURLSchemeTask>)task {
    if ((self = [super init])) _task = task;
    return self;
}

- (NSError *)failure { return _failure; }

- (void)retire:(NSException *)exception during:(NSString *)operation {
    [self stop];
    _failure = [NSError errorWithDomain:@"StrataWebPreview" code:1 userInfo:@{
        @"operation": operation, @"exceptionName": exception.name,
        NSLocalizedDescriptionKey: exception.reason ?: exception.name
    }];
    os_log_error(OS_LOG_DEFAULT, "Strata web preview stopped during %{public}@: %{private}@", operation, _failure);
}

- (BOOL)receiveResponse:(NSURLResponse *)response {
    if (!_task || _receiving) return NO;
    id<WKURLSchemeTask> task = _task;
    _receiving = YES;
    @try {
        [task didReceiveResponse:response];
        return _task != nil;
    } @catch (NSException *exception) {
        [self retire:exception during:@"resource response"];
        return NO;
    }
}

- (BOOL)receiveData:(NSData *)data {
    if (!_task || !_receiving) return NO;
    id<WKURLSchemeTask> task = _task;
    @try {
        [task didReceiveData:data];
        return _task != nil;
    } @catch (NSException *exception) {
        [self retire:exception during:@"resource data"];
        return NO;
    }
}

- (BOOL)finish {
    if (!_task || !_receiving) return NO;
    id<WKURLSchemeTask> task = _task;
    [self stop];
    @try {
        [task didFinish];
        return YES;
    } @catch (NSException *exception) {
        [self retire:exception during:@"resource completion"];
        return NO;
    }
}

- (void)fail:(NSError *)error {
    id<WKURLSchemeTask> task = _task;
    [self stop];
    if (!task) return;
    @try {
        [task didFailWithError:error];
    } @catch (NSException *exception) {
        [self retire:exception during:@"resource failure"];
    }
}

- (void)stop { _task = nil; _receiving = NO; }
@end
