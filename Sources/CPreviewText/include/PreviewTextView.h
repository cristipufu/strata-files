#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSTextStorage *_Nullable STCreatePreviewTextStorage(NSAttributedString *document);

/// Native operations catch locally, before an exception can unwind a Swift caller.
@interface STPreviewTextBuilder : NSObject
+ (nullable NSAttributedString *)inlineMarkdown:(NSString *)markdown baseURL:(NSURL *)baseURL error:(NSError **)error;
+ (nullable NSNumber *)widthOfString:(NSAttributedString *)string error:(NSError **)error;
+ (nullable NSNumber *)wordCountInString:(NSString *)string error:(NSError **)error;
+ (BOOL)fitTable:(NSTextTable *)table cells:(NSArray<NSTextTableBlock *> *)cells
         widths:(NSArray<NSNumber *> *)widths available:(CGFloat)available error:(NSError **)error
    NS_SWIFT_NAME(fitTable(_:cells:widths:available:));
@end

/// A failed document renderer is retired; its owner replaces it after the current drawing pass.
@interface STPreviewTextView : NSTextView
@property(nonatomic, readonly, nullable) NSError *renderingError;
@property(nonatomic, copy, nullable) void (^renderingFailed)(NSError *error);
- (BOOL)useTextStorage:(NSTextStorage *)storage allowingNonContiguousLayout:(BOOL)allows;
- (BOOL)applyWrapping:(BOOL)wraps;
- (void)retireWithError:(NSError *)error;
- (BOOL)resizeAttachments:(NSArray<NSTextAttachment *> *)attachments width:(CGFloat)width NS_SWIFT_NAME(resizeAttachments(_:width:));
- (BOOL)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)replacement;
- (BOOL)replaceRanges:(NSArray<NSValue *> *)ranges withStrings:(NSArray<NSAttributedString *> *)strings
    NS_SWIFT_NAME(replaceRanges(_:with:));
- (BOOL)writePlainText:(NSString *)text toPasteboard:(NSPasteboard *)pasteboard NS_SWIFT_NAME(writePlainText(_:to:));
- (BOOL)highlightRanges:(NSArray<NSValue *> *)ranges clearingRange:(NSRange)whole;
- (BOOL)revealRange:(NSRange)range;
- (void)centerCharacterAtIndex:(NSUInteger)index;
@end

@interface STPreviewLineLabel : NSObject
@property(nonatomic, readonly) NSInteger number;
@property(nonatomic, readonly) CGFloat baseline;
@end

@interface STPreviewLineNumberRuler : NSRulerView
- (nullable instancetype)initWithTextView:(STPreviewTextView *)textView lineStarts:(NSArray<NSNumber *> *)lineStarts
                highlightedLine:(nullable NSNumber *)highlightedLine;
- (NSArray<STPreviewLineLabel *> *)labelsInRect:(NSRect)visibleRect NS_SWIFT_NAME(labels(in:));
@end

NS_ASSUME_NONNULL_END
