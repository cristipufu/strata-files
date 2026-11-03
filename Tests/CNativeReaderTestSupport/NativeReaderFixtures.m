#import "NativeReaderFixtures.h"

@interface STReaderTestPage : PDFPage
@property(nonatomic, weak) STReaderTestDocument *owner;
@end
@interface STReaderTestDocument ()
@property(nonatomic) NSUInteger textReads;
@end
@implementation STReaderTestDocument
- (instancetype)init { if ((self = [super init])) _availablePages = 3; return self; }
- (NSUInteger)pageCount { return self.availablePages; }
- (BOOL)isLocked { return NO; }
- (NSDictionary *)documentAttributes { return @{ PDFDocumentTitleAttribute: self.providedTitle ?: @"Fixture" }; }
- (PDFPage *)pageAtIndex:(NSUInteger)index {
    if (index >= self.availablePages) return nil;
    STReaderTestPage *page = [STReaderTestPage new];
    page.owner = self;
    return page;
}
@end
@implementation STReaderTestPage
- (NSString *)string {
    self.owner.textReads++;
    if (self.owner.failsText) [NSException raise:NSInternalInconsistencyException format:@"Controlled PDF text failure"];
    return self.owner.scanned ? @"" : @"中文 😀 é page";
}
- (NSRect)boundsForBox:(PDFDisplayBox)box {
    if (self.owner.failsThumbnail) [NSException raise:NSInternalInconsistencyException format:@"Controlled PDF thumbnail failure"];
    return NSMakeRect(0, 0, 100, 100);
}
@end

@interface STReaderFailingData : NSData
@end
@implementation STReaderFailingData
- (NSUInteger)length { [NSException raise:NSInternalInconsistencyException format:@"Controlled rich text read failure"]; return 0; }
- (const void *)bytes { static const char byte = '{'; return &byte; }
@end

NSError *STTestRichTextException(void) {
    @try {
        NSError *error;
        [STDocumentReader richData:[STReaderFailingData new] type:NSRTFTextDocumentType maxCharacters:100 error:&error];
        return error;
    } @catch (NSException *exception) {
        // A broken production boundary reports a test failure, without unwinding Swift or terminating the process.
        return [NSError errorWithDomain:@"TestNativeExceptionEscaped" code:1 userInfo:nil];
    }
}
