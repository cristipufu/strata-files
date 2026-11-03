#import "NativeImageFile.h"
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

size_t STReadImageFileAtPosition(void *context, void *buffer, off_t position, size_t requested) {
    STImageFile *file = context;
    if (position < 0 || position > file->size) { atomic_store(&file->error, EINVAL); return 0; }
    size_t count = MIN(requested, (size_t)(file->size - position)), read = 0;
    const size_t chunkSize = 64 * 1024;
    while (read < count) {
        ssize_t received = pread(file->descriptor, (char *)buffer + read, MIN(chunkSize, count - read), position + (off_t)read);
        if (received > 0) { read += received; continue; }
        if (received < 0 && errno == EINTR) continue;
        atomic_store(&file->error, received < 0 ? errno : EIO);
        break;
    }
    return read;
}

static void STReleaseImageFile(void *context) {
    STImageFile *file = context;
    close(file->descriptor);
    free(file);
}

CGImageSourceRef STCreateFileImageSource(NSURL *url, STImageFile **file, CGDataProviderRef *retainedProvider, NSError **error) {
    *file = NULL;
    *retainedProvider = NULL;
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return NULL; }
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) {
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return NULL;
    }
    STImageFile *owner = calloc(1, sizeof(STImageFile));
    if (!owner) { close(fd); if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil]; return NULL; }
    owner->descriptor = fd; owner->size = info.st_size; atomic_init(&owner->error, 0);
    CGDataProviderDirectCallbacks callbacks = {0, NULL, NULL, STReadImageFileAtPosition, STReleaseImageFile};
    CGDataProviderRef provider = CGDataProviderCreateDirect(owner, info.st_size, &callbacks);
    if (!provider) { STReleaseImageFile(owner); if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOMEM userInfo:nil]; return NULL; }
    @try {
        CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider,
            (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
        if (source) { *file = owner; *retainedProvider = provider; provider = NULL; }
        else if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:nil];
        return source;
    } @finally { if (provider) CGDataProviderRelease(provider); }
}
