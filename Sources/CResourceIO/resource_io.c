#include "resource_io.h"
#include <errno.h>
#if defined(__APPLE__) || defined(__linux__)
#include <sys/xattr.h>
#endif

intptr_t pef_read_resource_xattr(const char *path, void *buffer, size_t capacity, int32_t *error) {
#if defined(__APPLE__)
    ssize_t result = getxattr(path, "com.apple.ResourceFork", buffer, capacity, 0, 0);
#elif defined(__linux__)
    ssize_t result = getxattr(path, "user.com.apple.ResourceFork", buffer, capacity);
#else
    *error = ENOTSUP;
    return -1;
#endif
#if defined(__APPLE__) || defined(__linux__)
    *error = result < 0 ? errno : 0;
    return result;
#endif
}
