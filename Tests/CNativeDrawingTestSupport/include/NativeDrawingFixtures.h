#import <NativeDrawing.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, STBadgeFailurePoint) {
    STBadgeFailureSetup,
    STBadgeFailureMissingFont,
    STBadgeFailureInvalidFont,
    STBadgeFailureMeasurement,
    STBadgeFailureDrawing,
};

FOUNDATION_EXPORT NSError *STTestBadgeGlyphFailure(STBadgeFailurePoint point, BOOL *contextRestored, BOOL *returnedImage);
FOUNDATION_EXPORT BOOL STReadViewIsFlipped(NSView *view);
FOUNDATION_EXPORT BOOL STReadViewIsOpaque(NSView *view);
FOUNDATION_EXPORT NSRect STConvertViewRect(NSView *view, NSRect rect);
FOUNDATION_EXPORT BOOL STDrawingProbeIsMainThread(void);
FOUNDATION_EXPORT NSError *_Nullable STDrawLegacyBadgeText(NSString *text, NSColor *color, NSRect tile);

NS_ASSUME_NONNULL_END
