#include "interpose.h"

__attribute__((objc_root_class))
@interface ZiHeaderFixture
@end

@implementation ZiHeaderFixture
@end

int main(void) {
    _Static_assert(sizeof(zi_runtime_t) == sizeof(void *));
    _Static_assert(sizeof(zi_hook_t) == sizeof(void *));
    zi_exec_site_t site = {0};
    zi_objc_method_query_t query = {0};
    zi_objc_object_replace_spec_t replace = {0};
    site.size = sizeof(site);
    query.size = sizeof(query);
    replace.size = sizeof(replace);
    return site.kind == ZI_TARGET_DATA_SLOT || query.is_class_method || replace.flags != 0 ? 1 : 0;
}
