#import "PreviewTextView.h"
#import <os/log.h>
#import <math.h>

NSTextStorage *STCreatePreviewTextStorage(NSAttributedString *document) {
    @try {
        return [[NSTextStorage alloc] initWithAttributedString:document];
    } @catch (NSException *exception) {
        os_log_error(OS_LOG_DEFAULT, "Strata text storage rejected: %{private}@", exception.reason);
        return nil;
    }
}

@implementation STPreviewTextView {
    NSError *_renderingError;
}

- (NSError *)renderingError { return _renderingError; }

- (void)retireWithError:(NSError *)error {
    if (_renderingError) return;
    _renderingError = error;
    os_log_error(OS_LOG_DEFAULT, "Strata text preview stopped: %{private}@", error);
    void (^handler)(NSError *) = self.renderingFailed;
    self.renderingFailed = nil;
    __weak STPreviewTextView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf && handler) handler(error);
    });
}

- (void)retireAfterException:(NSException *)exception {
    [self retireWithError:[NSError errorWithDomain:@"StrataTextPreview" code:1 userInfo:@{
        NSLocalizedDescriptionKey: exception.reason ?: exception.name,
        @"exceptionName": exception.name
    }]];
}

- (BOOL)useTextStorage:(NSTextStorage *)storage {
    if (_renderingError) return NO;
    @try {
        [self.layoutManager replaceTextStorage:storage];
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception];
        return NO;
    }
}

- (void)layout {
    if (_renderingError) return;
    @try {
        [super layout];
    } @catch (NSException *exception) {
        [self retireAfterException:exception];
    }
}

- (void)setFrameSize:(NSSize)size {
    if (_renderingError) return;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 0 || size.height < 0) {
        [self retireWithError:[NSError errorWithDomain:@"StrataTextPreview" code:2 userInfo:nil]];
        return;
    }
    @try {
        [super setFrameSize:size];
    } @catch (NSException *exception) {
        [self retireAfterException:exception];
    }
}

- (void)drawRect:(NSRect)rect {
    if (_renderingError) return;
    @try {
        [super drawRect:rect];
    } @catch (NSException *exception) {
        [self retireAfterException:exception];
    }
}

@end
