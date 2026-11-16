#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Font creation, measurement and drawing finish before a glyph can reach the view's graphics context.
@interface STBadgeGlyph : NSObject
@property(nonatomic, readonly) CGImageRef image;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (nullable instancetype)renderText:(NSString *)text color:(NSColor *)color size:(NSSize)size
                             scale:(CGFloat)scale error:(NSError **)error
    NS_SWIFT_NAME(render(_:color:size:scale:));
@end

NS_ASSUME_NONNULL_END
