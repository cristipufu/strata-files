#import "NativeReaderFixtures.h"
#import "../../Sources/CNativeReaders/NativeImageFile.h"

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

@implementation STReaderTestImage
- (CGImageRef)copyThumbnailWithMaximumSide:(NSUInteger)side {
    _reads++;
    [NSException raise:NSInternalInconsistencyException format:@"Controlled image thumbnail failure"];
    return NULL;
}
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

NSError *STTestImageOpenException(void) {
    @try {
        NSError *error;
        [STImageReader openData:[STReaderFailingData new] byteLimit:100 pixelLimit:100 frameLimit:1 error:&error];
        return error;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"TestNativeExceptionEscaped" code:1 userInfo:nil];
    }
}

NSError *STTestImageMetadataException(void) {
    @try {
        NSError *error;
        [STImageReader metadataFromData:[STReaderFailingData new] error:&error];
        return error;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"TestNativeExceptionEscaped" code:1 userInfo:nil];
    }
}

NSData *STTestImageFileRead(int descriptor, off_t capturedSize, off_t position, NSUInteger requested, NSError **error) {
    STImageFile file = {.descriptor = descriptor, .size = capturedSize};
    atomic_init(&file.error, 0);
    NSMutableData *data = [NSMutableData dataWithLength:MIN(requested, 1024)];
    data.length = STReadImageFileAtPosition(&file, data.mutableBytes, position, data.length);
    if (atomic_load(&file.error)) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:atomic_load(&file.error) userInfo:nil];
        return nil;
    }
    return data;
}
