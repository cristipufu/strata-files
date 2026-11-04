#import <PDFKit/PDFKit.h>
#import <NativeReaders.h>
NS_ASSUME_NONNULL_BEGIN
@interface STReaderTestDocument : PDFDocument
@property(nonatomic) NSUInteger availablePages;
@property(nonatomic, copy) NSString *providedTitle;
@property(nonatomic) BOOL failsText;
@property(nonatomic) BOOL scanned;
@property(nonatomic) BOOL failsThumbnail;
@property(nonatomic, readonly) NSUInteger textReads;
@end
@interface STReaderTestImage : STImageReader
@property(nonatomic, readonly) NSUInteger reads;
@end
FOUNDATION_EXPORT NSError *_Nullable STTestRichTextException(void);
FOUNDATION_EXPORT NSError *_Nullable STTestXMLException(void);
FOUNDATION_EXPORT NSError *_Nullable STTestXMLBoundary(void (NS_NOESCAPE ^operation)(NSXMLParser *parser));
FOUNDATION_EXPORT NSError *_Nullable STTestImageOpenException(void);
FOUNDATION_EXPORT NSError *_Nullable STTestImageMetadataException(void);
FOUNDATION_EXPORT NSData *_Nullable STTestImageFileRead(int descriptor, off_t capturedSize, off_t position,
                                                      NSUInteger requested, NSError **error);
NS_ASSUME_NONNULL_END
