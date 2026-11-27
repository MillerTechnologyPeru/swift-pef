#ifndef PEF_RESOURCE_IO_H
#define PEF_RESOURCE_IO_H
#include <stddef.h>
#include <stdint.h>
/// Returns byte count or -1; error receives errno on failure.
intptr_t pef_read_resource_xattr(const char *path, void *buffer, size_t capacity, int32_t *error);
#endif
