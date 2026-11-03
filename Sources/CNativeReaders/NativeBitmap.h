#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <math.h>

// The returned bitmap owns its pixels; no PDF or image provider is left to decode later in a UI or OCR call.
static inline CGImageRef _Nullable STCopyReadBitmap(CGImageRef _Nonnull image, size_t maximumSide) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!width || !height || !maximumSide) return nil;
    double scale = MIN(1, (double)maximumSide / MAX(width, height));
    width = MAX(1, (size_t)floor(width * scale));
    height = MAX(1, (size_t)floor(height * scale));
    CGColorSpaceRef colors = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!colors) return nil;
    CGContextRef context;
    @try { context = CGBitmapContextCreate(nil, width, height, 8, width * 4, colors, kCGImageAlphaPremultipliedLast); }
    @finally { CGColorSpaceRelease(colors); }
    if (!context) return nil;
    @try {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        return CGBitmapContextCreateImage(context);
    } @finally {
        CGContextRelease(context);
    }
}
