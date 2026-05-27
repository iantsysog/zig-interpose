#include "interpose.h"

static_assert(sizeof(zi_runtime_t) == sizeof(void *));
static_assert(sizeof(zi_hook_t) == sizeof(void *));
static_assert(ZI_SYMBOL_AMBIGUOUS == 13);

int main() {
    zi_runtime_t runtime = nullptr;
    zi_exec_site_t site = {};
    zi_data_slot_t slot = {};
    zi_symbol_query_t query = {};
    zi_swift_slot_query_t swift_query = {};
    (void)slot;
    if (zi_runtime_open(&runtime) != ZI_OK) {
        return 1;
    }
    query.size = sizeof(query);
    swift_query.size = sizeof(swift_query);
    swift_query.kind = ZI_SWIFT_LOOKUP_DEMANGLED_SYMBOL;
    (void)zi_resolve_symbol(runtime, &query, &site);
    (void)zi_resolve_swift_slot(runtime, &swift_query, &slot);
    return zi_runtime_close(runtime) == ZI_OK ? 0 : 2;
}
