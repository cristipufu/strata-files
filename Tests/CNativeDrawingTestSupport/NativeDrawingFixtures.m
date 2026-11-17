#import "NativeDrawingFixtures.h"

@interface STBadgeGlyph (FixtureConstruction)
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color;
@end

@interface STFailingBadgeText : NSAttributedString
@property(nonatomic) BOOL failsMeasurement;
@end

@implementation STFailingBadgeText {
    NSAttributedString *_text;
}
- (instancetype)init {
    if ((self = [super init])) {
        _text = [[NSAttributedString alloc] initWithString:@"M" attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.whiteColor
        }];
    }
    return self;
}
- (NSString *)string { return _text.string; }
- (NSDictionary *)attributesAtIndex:(NSUInteger)index effectiveRange:(NSRangePointer)range {
    return [_text attributesAtIndex:index effectiveRange:range];
}
- (NSSize)size {
    if (_failsMeasurement) [NSException raise:NSInvalidArgumentException format:@"Controlled badge measurement failure"];
    return _text.size;
}
- (void)drawAtPoint:(NSPoint)point {
    [NSException raise:NSInvalidArgumentException format:@"Controlled badge drawing failure"];
}
@end

@interface STSetupFailureGlyph : STBadgeGlyph @end
@implementation STSetupFailureGlyph
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    [NSException raise:NSInvalidArgumentException format:@"Controlled badge font setup failure"];
    return nil;
}
@end

@interface STMissingFontGlyph : STBadgeGlyph @end
@implementation STMissingFontGlyph
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    return [[NSAttributedString alloc] initWithString:text];
}
@end

@interface STInvalidFontGlyph : STBadgeGlyph @end
@implementation STInvalidFontGlyph
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    return [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: NSNull.null}];
}
@end

@interface STMeasurementFailureGlyph : STBadgeGlyph @end
@implementation STMeasurementFailureGlyph
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    STFailingBadgeText *label = [STFailingBadgeText new];
    label.failsMeasurement = YES;
    return label;
}
@end

@interface STDrawingFailureGlyph : STBadgeGlyph @end
@implementation STDrawingFailureGlyph
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    return [STFailingBadgeText new];
}
@end

NSError *STTestBadgeGlyphFailure(STBadgeFailurePoint point, BOOL *contextRestored, BOOL *returnedImage) {
    NSGraphicsContext *previous = NSGraphicsContext.currentContext;
    *returnedImage = NO;
    NSError *error = nil;
    @try {
        Class renderer = STSetupFailureGlyph.class;
        switch (point) {
            case STBadgeFailureSetup: break;
            case STBadgeFailureMissingFont: renderer = STMissingFontGlyph.class; break;
            case STBadgeFailureInvalidFont: renderer = STInvalidFontGlyph.class; break;
            case STBadgeFailureMeasurement: renderer = STMeasurementFailureGlyph.class; break;
            case STBadgeFailureDrawing: renderer = STDrawingFailureGlyph.class; break;
        }
        STBadgeGlyph *glyph = [renderer renderText:@"M" color:NSColor.whiteColor size:NSMakeSize(15, 14) scale:2 error:&error];
        *returnedImage = glyph != nil;
    } @catch (NSException *exception) {
        error = [NSError errorWithDomain:@"TestNativeExceptionEscaped" code:1 userInfo:nil];
    }
    *contextRestored = NSGraphicsContext.currentContext == previous;
    return error ?: [NSError errorWithDomain:@"TestNativeFailureMissing" code:1 userInfo:nil];
}

BOOL STBadgeFontSurvivesTextRelease(void) {
    @try {
        __weak NSFont *font;
        @autoreleasepool {
            NSAttributedString *text = [STBadgeGlyph makeText:@"M" color:NSColor.whiteColor];
            font = [text attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
        }
        return font != nil;
    } @catch (NSException *exception) {
        return NO;
    }
}

BOOL STReadViewIsFlipped(NSView *view) { return view.isFlipped; }
BOOL STReadViewIsOpaque(NSView *view) { return view.isOpaque; }
NSRect STConvertViewRect(NSView *view, NSRect rect) { return [view convertRect:rect toView:nil]; }
BOOL STDrawingProbeIsMainThread(void) { return NSThread.isMainThread; }

NSError *STDrawLegacyBadgeText(NSString *text, NSColor *color, NSRect tile) {
    @try {
        NSFont *font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];
        NSAttributedString *label = [[NSAttributedString alloc] initWithString:text
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
        NSSize size = label.size;
        CGFloat capOffset = (font.ascender - font.capHeight) - (size.height - font.ascender + font.descender) / 2;
        [label drawAtPoint:NSMakePoint(NSMidX(tile) - size.width / 2, NSMidY(tile) - size.height / 2 - capOffset / 2 + 0.25)];
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"TestLegacyBadgeRenderingFailed" code:1 userInfo:nil];
    }
}
