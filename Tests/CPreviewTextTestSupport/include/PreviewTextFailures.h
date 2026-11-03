#import <PreviewTextView.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, STPreviewFailurePoint) {
    STPreviewFailureNone,
    STPreviewFailureHighlighting,
    STPreviewFailureRuler,
    STPreviewFailureCentering,
    STPreviewFailureInvalidation
};

/// Each fixture arms only its own native object, after normal document installation.
@interface STFailingPreviewLayoutManager : NSLayoutManager
@property(nonatomic) STPreviewFailurePoint failurePoint;
@property(nonatomic, readonly) NSUInteger failures;
@property(nonatomic, readonly) NSUInteger glyphQueries;
@end

@interface STFailingPreviewTableCell : NSTextTableBlock
@property(nonatomic) BOOL failsFitting;
@end

@interface STFailingPreviewTextContainer : NSTextContainer
@property(nonatomic) BOOL failsSizing;
@end

@interface STFailingPreviewStorage : NSTextStorage
@property(nonatomic) BOOL failsEditing;
@end

FOUNDATION_EXPORT NSError *_Nullable STTestInlineMarkdownFailure(void);

NS_ASSUME_NONNULL_END
