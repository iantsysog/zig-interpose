#include "interpose.h"

int main(void) {
    _Static_assert(sizeof(zi_runtime_t) == sizeof(void *));
    _Static_assert(sizeof(zi_hook_t) == sizeof(void *));
    _Static_assert(ZI_BUFFER_TOO_SMALL == 11);
    _Static_assert(ZI_MACHO_OFFSET_FILE == 1);

    zi_runtime_t runtime = 0;
    zi_hook_t hook = 0;
    zi_exec_site_t site = {0};
    zi_data_slot_t slot = {0};
    zi_patch_bytes_spec_t patch = {0};
    zi_replace_site_spec_t replace = {0};
    zi_instrument_site_spec_t instrument = {0};
    zi_replace_slot_spec_t replace_slot = {0};
    zi_objc_object_replace_spec_t objc_replace = {0};
    zi_symbol_query_t symbol = {0};
    zi_pattern_text_query_t pattern = {0};
    zi_debug_file_line_t debug = {0};

    if (zi_runtime_open(&runtime) != ZI_OK) return 1;
    site.size = sizeof(site);
    slot.size = sizeof(slot);
    patch.size = sizeof(patch);
    replace.size = sizeof(replace);
    instrument.size = sizeof(instrument);
    replace_slot.size = sizeof(replace_slot);
    objc_replace.size = sizeof(objc_replace);
    symbol.size = sizeof(symbol);
    pattern.size = sizeof(pattern);
    debug.size = sizeof(debug);
    (void)zi_resolve_symbol(runtime, &symbol, &site);
    (void)zi_resolve_pattern_text(runtime, &pattern, &site);
    (void)zi_install_patch_bytes(runtime, &patch, &hook);
    (void)zi_install_replace_site(runtime, &replace, &hook);
    (void)zi_install_instrument_site(runtime, &instrument, &hook);
    (void)zi_install_replace_slot(runtime, &replace_slot, &hook);
    (void)zi_install_objc_object_replace(runtime, &objc_replace, &hook);
    (void)zi_debug_lookup_file_line(runtime, &debug);
    return zi_runtime_close(runtime) == ZI_OK ? 0 : 2;
}
