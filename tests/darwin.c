#include "interpose.h"

static zi_entry_action_t entry_callback(zi_entry_frame_t *frame) {
    frame->return_value.kind = ZI_RETURN_KIND_INTEGER;
    frame->return_value.integer[0] = 7;
    return ZI_ENTRY_ACTION_SKIP_ORIGINAL;
}

int main(void) {
    zi_runtime_t runtime = 0;
    zi_hook_t hook = 0;
    int target = 1;
    int replacement = 2;
    zi_exec_site_t site = {0};
    zi_replace_site_spec_t replace = {0};
    zi_instrument_site_spec_t instrument = {0};
    zi_objc_object_replace_spec_t objc_replace = {0};

    if (zi_runtime_open(&runtime) != ZI_OK) return 1;

    site.size = sizeof(site);
    site.address = &target;
    replace.size = sizeof(replace);
    replace.site = site;
    replace.replacement = &replacement;
    replace.options.size = sizeof(replace.options);
    replace.options.flags = ZI_INSTALL_ALLOW_RACY_PATCH;
    (void)zi_install_replace_site(runtime, &replace, &hook);

    instrument.size = sizeof(instrument);
    instrument.site = site;
    instrument.entry_callback = entry_callback;
    instrument.options.size = sizeof(instrument.options);
    (void)zi_install_instrument_site(runtime, &instrument, &hook);

    objc_replace.size = sizeof(objc_replace);
    objc_replace.object = &target;
    objc_replace.selector_name = "description";
    objc_replace.replacement = &replacement;
    objc_replace.options.size = sizeof(objc_replace.options);
    (void)zi_install_objc_object_replace(runtime, &objc_replace, &hook);

    return zi_runtime_close(runtime) == ZI_OK ? 0 : 2;
}
