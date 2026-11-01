#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSTextStorage *_Nullable STCreatePreviewTextStorage(NSAttributedString *document);

/// A failed document renderer is retired; its owner replaces it after the current drawing pass.
@interface STPreviewTextView : NSTextView
@property(nonatomic, readonly, nullable) NSError *renderingError;
@property(nonatomic, copy, nullable) void (^renderingFailed)(NSError *error);
- (BOOL)useTextStorage:(NSTextStorage *)storage;
@end

NS_ASSUME_NONNULL_END
