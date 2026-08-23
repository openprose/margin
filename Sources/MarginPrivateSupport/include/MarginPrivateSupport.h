#ifndef MARGIN_PRIVATE_SUPPORT_H
#define MARGIN_PRIVATE_SUPPORT_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool MarginNativeSpacesAvailable(void);
CFArrayRef MarginNativeSpacesCopyManagedDisplaySpaces(void) CF_RETURNS_RETAINED;
CFArrayRef MarginNativeSpacesCopySpacesForWindows(
    const uint32_t *window_ids,
    size_t window_count
) CF_RETURNS_RETAINED;
CFStringRef MarginNativeSpacesCopyName(uint64_t space_id) CF_RETURNS_RETAINED;
int MarginNativeSpacesGetType(uint64_t space_id);
bool MarginNativeSpacesMoveWindows(
    const uint32_t *window_ids,
    size_t window_count,
    uint64_t space_id
);

#ifdef __cplusplus
}
#endif

#endif
