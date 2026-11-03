#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <stdatomic.h>

typedef struct {
    int descriptor;
    off_t size;
    atomic_int error;
} STImageFile;

size_t STReadImageFileAtPosition(void *_Nonnull context, void *_Nonnull buffer, off_t position, size_t requested);

CGImageSourceRef _Nullable STCreateFileImageSource(NSURL *_Nonnull url, STImageFile *_Nullable *_Nonnull file,
                                                   CGDataProviderRef _Nullable *_Nonnull retainedProvider,
                                                   NSError *_Nullable *_Nullable error);
