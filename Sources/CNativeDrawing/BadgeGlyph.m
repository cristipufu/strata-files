#import "NativeDrawing.h"
#import <math.h>

static const CGFloat STBadgeFontSize = 10;
static const CGFloat STBadgeBaselineAdjustment = 0.25;
static const NSUInteger STMaximumGlyphPixels = 512;
static const NSUInteger STMaximumGlyphTextLength = 64;
static const CGFloat STMinimumGlyphScale = 1;
static const CGFloat STMaximumGlyphScale = 8;

static BOOL STValidGlyphInput(NSString *text, NSColor *color, NSSize size, CGFloat scale) {
    CGFloat width = ceil(size.width * scale), height = ceil(size.height * scale);
    return [text isKindOfClass:NSString.class] && text.length > 0 && text.length <= STMaximumGlyphTextLength &&
        [color isKindOfClass:NSColor.class] && isfinite(size.width) && size.width > 0 &&
        isfinite(size.height) && size.height > 0 && isfinite(scale) &&
        scale >= STMinimumGlyphScale && scale <= STMaximumGlyphScale &&
        isfinite(width) && width > 0 && width <= STMaximumGlyphPixels &&
        isfinite(height) && height > 0 && height <= STMaximumGlyphPixels;
}

static NSError *STGlyphFailure(NSString *operation, NSException *exception) {
    NSMutableDictionary *details = [@{NSLocalizedDescriptionKey: @"Badge text could not be rendered",
                                      @"operation": operation} mutableCopy];
    if (exception) {
        details[@"exceptionName"] = exception.name;
        if (exception.reason) details[@"exceptionReason"] = exception.reason;
    }
    return [NSError errorWithDomain:@"StrataNativeDrawing" code:1 userInfo:details];
}

@interface STBadgeGlyph ()
- (instancetype)initWithImage:(CGImageRef)image;
+ (nullable NSFont *)badgeFont;
+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color;
+ (nullable instancetype)imageForText:(NSString *)text color:(NSColor *)color size:(NSSize)size
                              bitmap:(NSBitmapImageRep *)bitmap operation:(NSString *__strong *)operation;
@end

@implementation STBadgeGlyph {
    CGImageRef _image;
}

- (instancetype)initWithImage:(CGImageRef)image {
    if ((self = [super init])) _image = CGImageRetain(image);
    return self;
}

- (void)dealloc { if (_image) CGImageRelease(_image); }
- (CGImageRef)image { return _image; }

+ (NSFont *)badgeFont {
    // AppKit can fail to recreate this font after its last owner leaves an autorelease pool.
    static NSFont *font;
    @synchronized (STBadgeGlyph.class) {
        if (!font) font = [NSFont monospacedSystemFontOfSize:STBadgeFontSize weight:NSFontWeightBold];
        return font;
    }
}

+ (NSAttributedString *)makeText:(NSString *)text color:(NSColor *)color {
    NSFont *font = [self badgeFont];
    if (!font) return nil;
    return [[NSAttributedString alloc] initWithString:text
                                         attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
}

+ (instancetype)renderText:(NSString *)text color:(NSColor *)color size:(NSSize)size
                     scale:(CGFloat)scale error:(NSError **)error {
    NSString *operation = @"glyph setup";
    @try {
        if (!STValidGlyphInput(text, color, size, scale)) {
            if (error) *error = STGlyphFailure(operation, nil);
            return nil;
        }
        NSInteger width = (NSInteger)ceil(size.width * scale), height = (NSInteger)ceil(size.height * scale);
        // Keep each Core Graphics owner alive until the returned image has been retained.
        __attribute__((objc_precise_lifetime)) NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:nil pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0];
        __attribute__((objc_precise_lifetime)) NSGraphicsContext *graphics = bitmap
            ? [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap] : nil;
        CGContextRef context = graphics.CGContext;
        if (!context) {
            if (error) *error = STGlyphFailure(operation, nil);
            return nil;
        }
        CGContextClearRect(context, CGRectMake(0, 0, width, height));
        CGContextScaleCTM(context, scale, scale);
        CGContextTranslateCTM(context, 0, size.height);
        CGContextScaleCTM(context, 1, -1);
        NSGraphicsContext *flipped = [NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
        if (!flipped) {
            if (error) *error = STGlyphFailure(operation, nil);
            return nil;
        }
        NSGraphicsContext *previous = NSGraphicsContext.currentContext;
        STBadgeGlyph *glyph;
        @try {
            NSGraphicsContext.currentContext = flipped;
            glyph = [self imageForText:text color:color size:size bitmap:bitmap operation:&operation];
        } @finally {
            NSGraphicsContext.currentContext = previous;
        }
        if (!glyph && error) *error = STGlyphFailure(operation, nil);
        return glyph;
    } @catch (NSException *exception) {
        if (error) *error = STGlyphFailure(operation, exception);
        return nil;
    }
}

+ (instancetype)imageForText:(NSString *)text color:(NSColor *)color size:(NSSize)size
                     bitmap:(NSBitmapImageRep *)bitmap operation:(NSString *__strong *)operation {
    NSAttributedString *label = [self makeText:text color:color];
    if (![label isKindOfClass:NSAttributedString.class] || !label.length) return nil;
    NSFont *font = [label attribute:NSFontAttributeName atIndex:0 effectiveRange:nil];
    if (![font isKindOfClass:NSFont.class]) return nil;

    *operation = @"glyph measurement";
    NSSize measured = label.size;
    CGFloat ascender = font.ascender, descender = font.descender, capHeight = font.capHeight;
    if (!isfinite(measured.width) || measured.width < 0 || !isfinite(measured.height) || measured.height < 0 ||
        !isfinite(ascender) || !isfinite(descender) || !isfinite(capHeight)) return nil;

    CGFloat capOffset = (ascender - capHeight) - (measured.height - ascender + descender) / 2;
    NSPoint origin = NSMakePoint((size.width - measured.width) / 2,
        (size.height - measured.height) / 2 - capOffset / 2 + STBadgeBaselineAdjustment);
    if (!isfinite(origin.x) || !isfinite(origin.y)) return nil;
    *operation = @"glyph drawing";
    [label drawAtPoint:origin];
    CGImageRef image = bitmap.CGImage;
    return image ? [[self alloc] initWithImage:image] : nil;
}

@end
