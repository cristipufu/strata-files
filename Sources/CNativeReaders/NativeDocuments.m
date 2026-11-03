#import "NativeReadersInternal.h"
#import "NativeReadError.h"
#import "NativeBitmap.h"
#import <PDFKit/PDFKit.h>
#import <math.h>

@interface STExtractedDocument ()
@property(nonatomic, copy) NSString *text;
@property(nonatomic, nullable, copy) NSString *title;
@property(nonatomic, copy) NSArray<NSNumber *> *pageStarts;
@property(nonatomic) NSInteger pageCount;
@property(nonatomic) BOOL truncated;
@property(nonatomic, copy) NSArray<NSNumber *> *scannedPageIndexes;
@end
@implementation STExtractedDocument
- (instancetype)init {
    if ((self = [super init])) { _text = @""; _pageStarts = @[]; _scannedPageIndexes = @[]; }
    return self;
}
@end

static NSString *STBoundedText(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text;
    NSUInteger end = limit ? [text rangeOfComposedCharacterSequenceAtIndex:limit].location : 0;
    return [text substringToIndex:end];
}

static STExtractedDocument *STRichText(NSAttributedString *string, NSDictionary *attributes, NSUInteger limit) {
    if (!string) return nil;
    STExtractedDocument *result = [STExtractedDocument new];
    result.text = STBoundedText(string.string, limit);
    result.truncated = result.text.length < string.length;
    id title = attributes[NSTitleDocumentAttribute];
    if ([title isKindOfClass:NSString.class]) result.title = title;
    return result;
}

static STDecodedImage *STPDFThumbnail(PDFPage *page) {
    NSRect bounds = [page boundsForBox:kPDFDisplayBoxMediaBox];
    if (!isfinite(bounds.size.width) || !isfinite(bounds.size.height) || bounds.size.width <= 0 || bounds.size.height <= 0) return nil;
    const CGFloat maximumSide = 2200;
    CGFloat scale = MIN(2, maximumSide / MAX(bounds.size.width, bounds.size.height));
    NSImage *thumbnail = [page thumbnailOfSize:NSMakeSize(bounds.size.width * scale, bounds.size.height * scale) forBox:kPDFDisplayBoxMediaBox];
    CGImageRef image = [thumbnail CGImageForProposedRect:nil context:nil hints:nil];
    if (!image) return nil;
    CGImageRef bitmap = STCopyReadBitmap(image, (size_t)maximumSide);
    if (!bitmap) return nil;
    @try { return [[STDecodedImage alloc] initWithImage:bitmap]; }
    @finally { CGImageRelease(bitmap); }
}

@implementation STDocumentReader
+ (STExtractedDocument *)richData:(NSData *)data type:(NSAttributedStringDocumentType)type
    maxCharacters:(NSUInteger)limit error:(NSError **)error {
    @try {
        NSDictionary *attributes;
        NSAttributedString *string = [[NSAttributedString alloc] initWithData:data options:@{NSDocumentTypeDocumentAttribute: type}
            documentAttributes:&attributes error:error];
        return STRichText(string, attributes, limit);
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"rich text extraction", exception);
        return nil;
    }
}

+ (STExtractedDocument *)richDirectory:(NSURL *)url type:(NSAttributedStringDocumentType)type
    maxCharacters:(NSUInteger)limit error:(NSError **)error {
    @try {
        NSDictionary *attributes;
        NSAttributedString *string = [[NSAttributedString alloc] initWithURL:url options:@{NSDocumentTypeDocumentAttribute: type}
            documentAttributes:&attributes error:error];
        return STRichText(string, attributes, limit);
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"rich text package extraction", exception);
        return nil;
    }
}

@end

@implementation STPDFReader {
    PDFDocument *_document;
    NSError *_failure;
    NSInteger _pageCount;
    NSString *_title;
}

- (NSError *)failure { return _failure; }

+ (instancetype)openData:(NSData *)data error:(NSError **)error {
    @try {
        PDFDocument *document = [[PDFDocument alloc] initWithData:data];
        if (document) return [self openDocument:document error:error];
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"PDF opening", exception);
    }
    return nil;
}

+ (instancetype)openDocument:(PDFDocument *)document error:(NSError **)error {
    @try {
        NSUInteger count = document.pageCount;
        if (document.isLocked || count > NSIntegerMax) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
            return nil;
        }
        STPDFReader *reader = [self new];
        reader->_document = document;
        reader->_pageCount = (NSInteger)count;
        id title = document.documentAttributes[PDFDocumentTitleAttribute];
        if ([title isKindOfClass:NSString.class]) reader->_title = [title copy];
        return reader;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"PDF metadata", exception);
        return nil;
    }
}

- (void)stopWithError:(NSError *)failure {
    if (_failure) return;
    _failure = failure;
    _document = nil;
}

- (BOOL)canRead:(NSError **)error {
    if (!_failure) return YES;
    if (error) *error = _failure;
    return NO;
}

- (BOOL)cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    if (!cancelled()) return NO;
    [self stopWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    if (error) *error = _failure;
    return YES;
}

- (STExtractedDocument *)readWithMaxCharacters:(NSUInteger)limit maxPages:(NSUInteger)maxPages
    cancelled:(BOOL (^)(void))cancelled error:(NSError **)error {
    if (![self canRead:error]) return nil;
    @try {
        if ([self cancelled:cancelled error:error]) return nil;
        STExtractedDocument *result = [STExtractedDocument new];
        result.pageCount = _pageCount;
        result.title = _title;
        NSUInteger count = MIN(maxPages, (NSUInteger)_pageCount);
        NSMutableString *text = [NSMutableString new];
        NSMutableArray<NSNumber *> *starts = [NSMutableArray new], *scanned = [NSMutableArray new];
        for (NSUInteger index = 0; index < count; index++) {
            if ([self cancelled:cancelled error:error]) return nil;
            @autoreleasepool {
                PDFPage *page = [_document pageAtIndex:index];
                if (!page) continue;
                [starts addObject:@(text.length)];
                NSString *pageText = page.string ?: @"";
                if (![pageText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) [scanned addObject:@(index)];
                NSString *bounded = STBoundedText(pageText, limit - text.length);
                [text appendString:bounded];
                if (text.length < limit) [text appendString:STBoundedText(@"\n\n", limit - text.length)];
                if (bounded.length < pageText.length || text.length >= limit) {
                    result.truncated = bounded.length < pageText.length || index + 1 < _pageCount;
                    break;
                }
            }
        }
        if ([self cancelled:cancelled error:error]) return nil;
        result.text = text;
        result.pageStarts = starts;
        result.scannedPageIndexes = scanned;
        result.truncated |= count < _pageCount;
        return result;
    } @catch (NSException *exception) {
        [self stopWithError:STNativeReadFailure(@"PDF text extraction", exception)];
        if (error) *error = _failure;
        return nil;
    }
}

- (STDecodedImage *)imageForPage:(NSUInteger)index error:(NSError **)error {
    if (![self canRead:error]) return nil;
    @try {
        if (index >= _pageCount) {
            [self stopWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil]];
            if (error) *error = _failure;
            return nil;
        }
        return STPDFThumbnail([_document pageAtIndex:index]);
    } @catch (NSException *exception) {
        [self stopWithError:STNativeReadFailure(@"PDF thumbnail", exception)];
        if (error) *error = _failure;
        return nil;
    }
}
@end
