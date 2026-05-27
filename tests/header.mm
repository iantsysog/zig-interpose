#include "interpose.h"

__attribute__((objc_root_class))
@interface ZiObjcxxHeaderFixture
@end

@implementation ZiObjcxxHeaderFixture
@end

int main() {
    static_assert(sizeof(zi_runtime_t) == sizeof(void *));
    static_assert(sizeof(zi_hook_t) == sizeof(void *));
    zi_entry_frame_t entry = {};
    zi_return_frame_t ret = {};
    zi_install_options_t options = {};
    options.size = sizeof(options);
    return entry.size == 0 || ret.size == 0 || options.size == 0 ? 1 : 0;
}
