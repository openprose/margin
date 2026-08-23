#include "MarginPrivateSupport.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>

typedef int (*SLSMainConnectionIDFunction)(void);
typedef CFArrayRef (*SLSCopyManagedDisplaySpacesFunction)(int);
typedef CFArrayRef (*SLSCopySpacesForWindowsFunction)(int, int, CFArrayRef);
typedef CFStringRef (*SLSSpaceCopyNameFunction)(int, uint64_t);
typedef int (*SLSSpaceGetTypeFunction)(int, uint64_t);
typedef int64_t (*SLSPerformBridgedOperationFunction)(void *);

static SLSMainConnectionIDFunction main_connection_id;
static SLSCopyManagedDisplaySpacesFunction copy_managed_display_spaces;
static SLSCopySpacesForWindowsFunction copy_spaces_for_windows;
static SLSSpaceCopyNameFunction copy_space_name;
static SLSSpaceGetTypeFunction get_space_type;
static SLSPerformBridgedOperationFunction perform_bridged_operation;
static bool support_available;

// SkyLight keeps the Tahoe bridge entry point local rather than exporting it
// through dlsym. Resolve that one address from the loaded Mach-O image while
// looking up every other private API dynamically. This fail-closed technique
// is adapted from yabai's Tahoe implementation; see NOTICE for attribution.
static void *find_local_symbol(
    const struct mach_header_64 *header,
    intptr_t slide,
    const char *target
) {
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const uint8_t *cursor = (const uint8_t *)header + sizeof(*header);

    for (uint32_t index = 0; index < header->ncmds; index++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname)) == 0) {
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        }
        cursor += command->cmdsize;
    }

    if (linkedit == NULL || symtab == NULL) return NULL;
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols =
        (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strings = (const char *)(linkedit_base + symtab->stroff);

    for (uint32_t index = 0; index < symtab->nsyms; index++) {
        uint32_t string_index = symbols[index].n_un.n_strx;
        if (string_index == 0 || string_index >= symtab->strsize) continue;
        if (strcmp(strings + string_index, target) == 0) {
            return (void *)((uintptr_t)slide + symbols[index].n_value);
        }
    }
    return NULL;
}

static void load_support(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path =
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
        void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
        if (handle == NULL) return;

        main_connection_id = (SLSMainConnectionIDFunction)dlsym(
            handle, "SLSMainConnectionID"
        );
        copy_managed_display_spaces = (SLSCopyManagedDisplaySpacesFunction)dlsym(
            handle, "SLSCopyManagedDisplaySpaces"
        );
        copy_spaces_for_windows = (SLSCopySpacesForWindowsFunction)dlsym(
            handle, "SLSCopySpacesForWindows"
        );
        copy_space_name = (SLSSpaceCopyNameFunction)dlsym(handle, "SLSSpaceCopyName");
        get_space_type = (SLSSpaceGetTypeFunction)dlsym(handle, "SLSSpaceGetType");

        for (uint32_t index = 0; index < _dyld_image_count(); index++) {
            const char *image_name = _dyld_get_image_name(index);
            if (image_name == NULL || strcmp(image_name, path) != 0) continue;
            const struct mach_header *candidate = _dyld_get_image_header(index);
            if (candidate == NULL || candidate->magic != MH_MAGIC_64) break;
            perform_bridged_operation = (SLSPerformBridgedOperationFunction)find_local_symbol(
                (const struct mach_header_64 *)candidate,
                _dyld_get_image_vmaddr_slide(index),
                "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
            );
            break;
        }

        Class operation_class = objc_getClass(
            "SLSBridgedMoveWindowsToManagedSpaceOperation"
        );
        SEL initializer = sel_registerName("initWithWindows:spaceID:");
        support_available = main_connection_id != NULL
            && copy_managed_display_spaces != NULL
            && copy_spaces_for_windows != NULL
            && copy_space_name != NULL
            && get_space_type != NULL
            && perform_bridged_operation != NULL
            && operation_class != Nil
            && class_getInstanceMethod(operation_class, initializer) != NULL;
    });
}

static CFArrayRef copy_window_id_array(const uint32_t *window_ids, size_t count) {
    if (window_ids == NULL || count == 0) return NULL;
    CFMutableArrayRef result = CFArrayCreateMutable(
        kCFAllocatorDefault,
        (CFIndex)count,
        &kCFTypeArrayCallBacks
    );
    if (result == NULL) return NULL;

    for (size_t index = 0; index < count; index++) {
        uint32_t value = window_ids[index];
        CFNumberRef number = CFNumberCreate(
            kCFAllocatorDefault,
            kCFNumberSInt32Type,
            &value
        );
        if (number == NULL) {
            CFRelease(result);
            return NULL;
        }
        CFArrayAppendValue(result, number);
        CFRelease(number);
    }
    return result;
}

bool MarginNativeSpacesAvailable(void) {
    load_support();
    return support_available;
}

CFArrayRef MarginNativeSpacesCopyManagedDisplaySpaces(void) {
    load_support();
    if (!support_available) return NULL;
    return copy_managed_display_spaces(main_connection_id());
}

CFArrayRef MarginNativeSpacesCopySpacesForWindows(
    const uint32_t *window_ids,
    size_t window_count
) {
    load_support();
    if (!support_available) return NULL;
    CFArrayRef windows = copy_window_id_array(window_ids, window_count);
    if (windows == NULL) return NULL;
    CFArrayRef spaces = copy_spaces_for_windows(main_connection_id(), 0x7, windows);
    CFRelease(windows);
    return spaces;
}

CFStringRef MarginNativeSpacesCopyName(uint64_t space_id) {
    load_support();
    if (!support_available) return NULL;
    return copy_space_name(main_connection_id(), space_id);
}

int MarginNativeSpacesGetType(uint64_t space_id) {
    load_support();
    if (!support_available) return -1;
    return get_space_type(main_connection_id(), space_id);
}

bool MarginNativeSpacesMoveWindows(
    const uint32_t *window_ids,
    size_t window_count,
    uint64_t space_id
) {
    load_support();
    if (!support_available || window_ids == NULL || window_count == 0) return false;
    CFArrayRef windows = copy_window_id_array(window_ids, window_count);
    if (windows == NULL) return false;

    Class operation_class = objc_getClass(
        "SLSBridgedMoveWindowsToManagedSpaceOperation"
    );
    SEL allocate = sel_registerName("alloc");
    SEL initialize = sel_registerName("initWithWindows:spaceID:");
    SEL release = sel_registerName("release");
    id operation = ((id (*)(id, SEL))objc_msgSend)((id)operation_class, allocate);
    operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(
        operation,
        initialize,
        (id)windows,
        space_id
    );
    if (operation == nil) {
        CFRelease(windows);
        return false;
    }

    perform_bridged_operation((void *)operation);
    ((void (*)(id, SEL))objc_msgSend)(operation, release);
    CFRelease(windows);
    return true;
}
