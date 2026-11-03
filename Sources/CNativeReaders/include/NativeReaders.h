#import <AppKit/AppKit.h>
@class PDFDocument;

NS_ASSUME_NONNULL_BEGIN

@interface STDecodedImage : NSObject
@property(nonatomic, readonly) CGImageRef image;
- (nullable NSData *)encodedAsJPEG:(BOOL)jpeg maximumBytes:(NSUInteger)maximumBytes error:(NSError **)error
    NS_SWIFT_NAME(encoded(jpeg:maximumBytes:));
@end

@interface STImageMetadata : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) NSInteger orientation;
@property(nonatomic, readonly, copy) NSString *typeIdentifier;
@property(nonatomic, readonly, nullable, copy) NSString *captureDate;
@property(nonatomic, readonly, nullable, copy) NSString *captureOffset;
@property(nonatomic, readonly, nullable, copy) NSString *cameraModel;
@property(nonatomic, readonly, nullable, copy) NSString *cameraMake;
@property(nonatomic, readonly, nullable, copy) NSString *lensModel;
@property(nonatomic, readonly, nullable, copy) NSNumber *exposureTime;
@property(nonatomic, readonly, nullable, copy) NSNumber *aperture;
@property(nonatomic, readonly, nullable, copy) NSNumber *iso;
@end

@interface STImageReader : NSObject
@property(nonatomic, readonly) STImageMetadata *metadata;
@property(nonatomic, readonly, nullable) NSError *failure;
+ (nullable instancetype)openData:(NSData *)data byteLimit:(NSUInteger)byteLimit pixelLimit:(NSUInteger)pixelLimit
    frameLimit:(NSUInteger)frameLimit error:(NSError **)error NS_SWIFT_NAME(open(_:byteLimit:pixelLimit:frameLimit:));
+ (nullable STImageMetadata *)metadataFromData:(NSData *)data error:(NSError **)error NS_SWIFT_NAME(metadata(from:));
+ (nullable STImageMetadata *)metadataAtURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(metadata(at:));
- (nullable STDecodedImage *)thumbnailWithMaximumSide:(NSUInteger)maximumSide error:(NSError **)error
    NS_SWIFT_NAME(thumbnail(maximumSide:));
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
