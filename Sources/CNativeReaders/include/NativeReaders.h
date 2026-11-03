#import <AppKit/AppKit.h>
@class PDFDocument;

NS_ASSUME_NONNULL_BEGIN

@interface STDecodedImage : NSObject
@property(nonatomic, readonly) CGImageRef image;
@end

@interface STExtractedDocument : NSObject
@property(nonatomic, readonly, copy) NSString *text;
@property(nonatomic, readonly, nullable, copy) NSString *title;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *pageStarts;
@property(nonatomic, readonly) NSInteger pageCount;
@property(nonatomic, readonly) BOOL truncated;
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *scannedPageIndexes;
@end

@interface STDocumentReader : NSObject
+ (nullable STExtractedDocument *)richData:(NSData *)data type:(NSAttributedStringDocumentType)type
    maxCharacters:(NSUInteger)maxCharacters error:(NSError **)error
    NS_SWIFT_NAME(richText(_:type:maxCharacters:));
+ (nullable STExtractedDocument *)richDirectory:(NSURL *)url type:(NSAttributedStringDocumentType)type
    maxCharacters:(NSUInteger)maxCharacters error:(NSError **)error
    NS_SWIFT_NAME(richText(_:type:maxCharacters:));
@end

@interface STPDFReader : NSObject
@property(nonatomic, readonly, nullable) NSError *failure;
+ (nullable instancetype)openData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(open(_:));
+ (nullable instancetype)openDocument:(PDFDocument *)document error:(NSError **)error NS_SWIFT_NAME(open(_:));
- (nullable STExtractedDocument *)readWithMaxCharacters:(NSUInteger)limit maxPages:(NSUInteger)maxPages
    cancelled:(BOOL (^)(void))cancelled error:(NSError **)error NS_SWIFT_NAME(read(maxCharacters:maxPages:cancelled:));
- (nullable STDecodedImage *)imageForPage:(NSUInteger)index error:(NSError **)error NS_SWIFT_NAME(image(forPage:));
@end

NS_ASSUME_NONNULL_END
