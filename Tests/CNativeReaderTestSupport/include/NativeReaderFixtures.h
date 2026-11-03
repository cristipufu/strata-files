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
FOUNDATION_EXPORT NSError *_Nullable STTestRichTextException(void);
NS_ASSUME_NONNULL_END
