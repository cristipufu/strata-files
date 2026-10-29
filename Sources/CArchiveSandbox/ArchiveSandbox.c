#include "CArchiveSandbox.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Security/SecTask.h>

/* A worker signed without the entitlement would parse untrusted archives unconfined: it refuses instead. The service
 * checks itself the same way before it starts one. */
int strata_archive_sandboxed(void) {
    SecTaskRef task = SecTaskCreateFromSelf(NULL);
    if (!task) return 0;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.app-sandbox"), NULL);
    CFRelease(task);
    const int granted = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    return granted;
}
