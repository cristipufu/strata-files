#import "NativeReadersInternal.h"
#import "NativeReadError.h"
#import "NativeBitmap.h"
#import "NativeImageFile.h"
#import <ImageIO/ImageIO.h>

@interface STImageMetadata ()
@property(nonatomic) NSInteger width, height, orientation;
@property(nonatomic, copy) NSString *typeIdentifier;
@property(nonatomic, nullable, copy) NSString *captureDate, *captureOffset, *cameraModel, *cameraMake, *lensModel;
@property(nonatomic, nullable, copy) NSNumber *exposureTime, *aperture, *iso;
@end
@implementation STImageMetadata
@end

static NSInteger STImageDimension(id value) {
    if (![value isKindOfClass:NSNumber.class]) return 0;
    double number = [value doubleValue];
    return isfinite(number) && number > 0 && number < (double)NSIntegerMax && floor(number) == number ? (NSInteger)number : 0;
}

static NSString *STMetadataString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] <= 1024 ? value : nil;
}

static NSNumber *STPositiveMetadataNumber(id value) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFNumberGetTypeID()) return nil;
    double number = [value doubleValue];
    return isfinite(number) && number > 0 ? value : nil;
}
static const NSUInteger STMaximumImageSide = 4096;

static STImageMetadata *STReadImageMetadata(CGImageSourceRef source) {
    CFStringRef type = CGImageSourceGetType(source);
    if (!type) return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    STImageMetadata *result = [STImageMetadata new];
    result.typeIdentifier = (__bridge NSString *)type;
    result.width = STImageDimension(properties[(__bridge NSString *)kCGImagePropertyPixelWidth]);
    result.height = STImageDimension(properties[(__bridge NSString *)kCGImagePropertyPixelHeight]);
    result.orientation = STImageDimension(properties[(__bridge NSString *)kCGImagePropertyOrientation]);
    id exif = properties[(__bridge NSString *)kCGImagePropertyExifDictionary];
    id tiff = properties[(__bridge NSString *)kCGImagePropertyTIFFDictionary];
    if ([exif isKindOfClass:NSDictionary.class]) {
        result.captureDate = STMetadataString(exif[(__bridge NSString *)kCGImagePropertyExifDateTimeOriginal])
            ?: STMetadataString(exif[(__bridge NSString *)kCGImagePropertyExifDateTimeDigitized]);
        result.captureOffset = STMetadataString(exif[(__bridge NSString *)kCGImagePropertyExifOffsetTimeOriginal]);
        result.lensModel = STMetadataString(exif[(__bridge NSString *)kCGImagePropertyExifLensModel]);
        result.exposureTime = STPositiveMetadataNumber(exif[(__bridge NSString *)kCGImagePropertyExifExposureTime]);
        result.aperture = STPositiveMetadataNumber(exif[(__bridge NSString *)kCGImagePropertyExifFNumber]);
        id ratings = exif[(__bridge NSString *)kCGImagePropertyExifISOSpeedRatings];
        id rating = [ratings isKindOfClass:NSArray.class] ? ([ratings count] ? ratings[0] : nil) : ratings;
        result.iso = STPositiveMetadataNumber(rating);
    }
    if ([tiff isKindOfClass:NSDictionary.class]) {
        result.cameraModel = STMetadataString(tiff[(__bridge NSString *)kCGImagePropertyTIFFModel]);
        result.cameraMake = STMetadataString(tiff[(__bridge NSString *)kCGImagePropertyTIFFMake]);
    }
    return result;
}

@implementation STImageReader {
    CGImageSourceRef _source;
    STImageMetadata *_metadata;
    NSError *_failure;
}
- (STImageMetadata *)metadata { return _metadata; }
- (NSError *)failure { return _failure; }
- (void)dealloc { if (_source) CFRelease(_source); }
- (void)stopWithError:(NSError *)error {
    if (_failure) return;
    _failure = error;
    if (_source) { CFRelease(_source); _source = NULL; }
}

+ (instancetype)openData:(NSData *)data byteLimit:(NSUInteger)bytes pixelLimit:(NSUInteger)pixels
    frameLimit:(NSUInteger)frames error:(NSError **)error {
    CGImageSourceRef source = NULL;
    @try {
        if (data.length > bytes || !pixels || !frames) { if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadTooLargeError userInfo:nil]; return nil; }
        source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
        if (!source) { if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil]; return nil; }
        STImageMetadata *metadata = STReadImageMetadata(source);
        size_t count = CGImageSourceGetCount(source);
        if (!metadata || !count || count > frames || metadata.width <= 0 || metadata.height <= 0 || (NSUInteger)metadata.width > pixels / (NSUInteger)metadata.height) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
            return nil;
        }
        STImageReader *reader = [self new];
        reader->_metadata = metadata; reader->_source = source; source = NULL;
        return reader;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"image opening", exception);
        return nil;
    } @finally { if (source) CFRelease(source); }
}

+ (STImageMetadata *)metadataFromData:(NSData *)data error:(NSError **)error {
    CGImageSourceRef source = NULL;
    @try {
        source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
        STImageMetadata *metadata = source ? STReadImageMetadata(source) : nil;
        if (!metadata && error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return metadata;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"image metadata", exception);
        return nil;
    } @finally { if (source) CFRelease(source); }
}

+ (STImageMetadata *)metadataAtURL:(NSURL *)url error:(NSError **)error {
    CGImageSourceRef source = NULL;
    CGDataProviderRef provider = NULL;
    @try {
        STImageFile *file = NULL;
        source = STCreateFileImageSource(url, &file, &provider, error);
        if (!source) return nil;
        STImageMetadata *metadata = STReadImageMetadata(source);
        if (atomic_load(&file->error)) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:atomic_load(&file->error) userInfo:nil]; return nil; }
        if (!metadata && error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return metadata;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"image file metadata", exception);
        return nil;
    } @finally { if (source) CFRelease(source); if (provider) CGDataProviderRelease(provider); }
}

- (CGImageRef)copyThumbnailWithMaximumSide:(NSUInteger)side {
    return CGImageSourceCreateThumbnailAtIndex(_source, 0, (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(side)});
}

- (STDecodedImage *)thumbnailWithMaximumSide:(NSUInteger)side error:(NSError **)error {
    if (_failure) { if (error) *error = _failure; return nil; }
    @try {
        side = MIN(STMaximumImageSide, MAX(1, side));
        CGImageRef image = [self copyThumbnailWithMaximumSide:side];
        if (!image) { [self stopWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil]]; if (error) *error = _failure; return nil; }
        @try {
            CGImageRef bitmap = STCopyReadBitmap(image, side);
            if (!bitmap) { [self stopWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil]]; if (error) *error = _failure; return nil; }
            @try { return [[STDecodedImage alloc] initWithImage:bitmap]; }
            @finally { CGImageRelease(bitmap); }
        } @finally { CGImageRelease(image); }
    } @catch (NSException *exception) {
        [self stopWithError:STNativeReadFailure(@"image thumbnail", exception)];
        if (error) *error = _failure;
        return nil;
    }
}
@end

@implementation STDecodedImage {
    CGImageRef _image;
}
- (instancetype)initWithImage:(CGImageRef)image {
    if ((self = [super init])) _image = CGImageRetain(image);
    return self;
}
- (CGImageRef)image { return _image; }
- (void)dealloc { if (_image) CGImageRelease(_image); }

- (NSData *)encodedAsJPEG:(BOOL)jpeg maximumBytes:(NSUInteger)maximumBytes error:(NSError **)error {
    CGImageDestinationRef writer = NULL;
    @try {
        NSMutableData *data = [NSMutableData new];
        writer = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, jpeg ? CFSTR("public.jpeg") : CFSTR("public.png"), 1, NULL);
        if (!writer) { if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil]; return nil; }
        CGImageDestinationAddImage(writer, self.image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.85});
        if (!CGImageDestinationFinalize(writer) || data.length > maximumBytes) {
            if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadTooLargeError userInfo:nil];
            return nil;
        }
        return data;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"preview image encoding", exception);
        return nil;
    } @finally { if (writer) CFRelease(writer); }
}
@end
