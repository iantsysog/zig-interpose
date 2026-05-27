#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <objc/message.h>
#include <objc/runtime.h>

#include "interpose.h"

typedef struct zi_objc_helper_result_t {
    void *state;
    void *owner;
    void *object;
    void *object_original_class;
    void *selector;
    const char *types;
    void *original;
    void *replacement;
    uintptr_t conflict_key;
} zi_objc_helper_result_t;

typedef struct zi_dynamic_state_t {
    void *object;
    Class original_class;
    Class dynamic_class;
    Class perceived_class;
    SEL selector;
    IMP original_imp;
    IMP replacement_imp;
    const char *types;
} zi_dynamic_state_t;

static const char *ZIInterposeSubclassPrefix = "ZIInterpose_";

static Class zi_runtime_class(id object) {
    return object_getClass(object);
}

static Class zi_perceived_class(id object) {
    return ((Class (*)(id, SEL))objc_msgSend)(object, sel_registerName("class"));
}

static const char *zi_strdup(const char *value) {
    if (value == NULL) return NULL;
    size_t len = strlen(value) + 1;
    char *copy = malloc(len);
    if (copy == NULL) return NULL;
    memcpy(copy, value, len);
    return copy;
}

static int zi_class_has_selector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods == NULL) return 0;
    int found = 0;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = 1;
            break;
        }
    }
    free(methods);
    return found;
}

static Class zi_get_class_decoy(id self, SEL _cmd) {
    (void)_cmd;
    Class stored = (Class)objc_getAssociatedObject((id)object_getClass(self), "zi_perceived_class");
    return stored != Nil ? stored : object_getClass(self);
}

static void zi_replace_get_class(Class cls, Class perceived) {
    objc_setAssociatedObject((id)cls, "zi_perceived_class", perceived, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject((id)object_getClass(cls), "zi_perceived_class", perceived, OBJC_ASSOCIATION_ASSIGN);
    class_replaceMethod(cls, sel_registerName("class"), (IMP)zi_get_class_decoy, "#@:");
    class_replaceMethod(object_getClass(cls), sel_registerName("class"), (IMP)zi_get_class_decoy, "#@:");
}

static Class zi_get_or_create_subclass(id object, Class actual_class, Class perceived_class) {
    const char *actual_name = class_getName(actual_class);
    if (actual_name != NULL && strncmp(actual_name, ZIInterposeSubclassPrefix, strlen(ZIInterposeSubclassPrefix)) == 0) {
        return actual_class;
    }

    char subclass_name[512];
    snprintf(subclass_name, sizeof(subclass_name), "%s%s_%p", ZIInterposeSubclassPrefix, class_getName(perceived_class), object);

    Class subclass = objc_getClass(subclass_name);
    if (subclass != Nil) return subclass;

    subclass = objc_allocateClassPair(actual_class, subclass_name, 0);
    if (subclass == Nil) return Nil;
    zi_replace_get_class(subclass, perceived_class);
    objc_registerClassPair(subclass);
    return subclass;
}

zi_status_t zi_objc_dynamic_subclass_install(const zi_objc_object_replace_spec_t *spec, zi_objc_helper_result_t *out_result) {
    if (spec == NULL || out_result == NULL) return ZI_INVALID_ARGUMENT;
    if (spec->object == NULL || spec->replacement == NULL || spec->selector_name == NULL) return ZI_INVALID_ARGUMENT;

    id object = (id)spec->object;
    Class actual_class = zi_runtime_class(object);
    Class perceived_class = zi_perceived_class(object);
    if (actual_class == Nil || perceived_class == Nil) return ZI_NOT_FOUND;
    if (actual_class != perceived_class && (spec->flags & ZI_OBJC_ALLOW_KVO_CLASS_MISMATCH) == 0) return ZI_CONFLICT;

    SEL selector = sel_registerName(spec->selector_name);
    Method method = class_getInstanceMethod(actual_class, selector);
    if (method == NULL) return ZI_NOT_FOUND;

    const char *types = method_getTypeEncoding(method);
    IMP original = class_getMethodImplementation(actual_class, selector);
    if (original == NULL) return ZI_NOT_FOUND;

    Class dynamic_class = zi_get_or_create_subclass(object, actual_class, perceived_class);
    if (dynamic_class == Nil) return ZI_OUT_OF_MEMORY;

    if (zi_class_has_selector(dynamic_class, selector)) {
        class_replaceMethod(dynamic_class, selector, spec->replacement, types);
    } else if (!class_addMethod(dynamic_class, selector, spec->replacement, types)) {
        return ZI_CONFLICT;
    }

    object_setClass(object, dynamic_class);

    zi_dynamic_state_t *state = calloc(1, sizeof(*state));
    if (state == NULL) return ZI_OUT_OF_MEMORY;
    state->object = spec->object;
    state->original_class = actual_class;
    state->dynamic_class = dynamic_class;
    state->perceived_class = perceived_class;
    state->selector = selector;
    state->original_imp = original;
    state->replacement_imp = spec->replacement;
    state->types = zi_strdup(types);
    if (state->types == NULL) {
        free(state);
        return ZI_OUT_OF_MEMORY;
    }

    out_result->state = state;
    out_result->owner = dynamic_class;
    out_result->object = spec->object;
    out_result->object_original_class = actual_class;
    out_result->selector = selector;
    out_result->types = state->types;
    out_result->original = original;
    out_result->replacement = spec->replacement;
    out_result->conflict_key = ((uintptr_t)spec->object) ^ (((uintptr_t)(void *)selector) << 1);
    return ZI_OK;
}

zi_status_t zi_objc_dynamic_subclass_apply(void *opaque_state) {
    if (opaque_state == NULL) return ZI_INVALID_ARGUMENT;
    zi_dynamic_state_t *state = opaque_state;
    if (object_getClass((id)state->object) != state->original_class) return ZI_CONFLICT;
    object_setClass((id)state->object, state->dynamic_class);
    return ZI_OK;
}

zi_status_t zi_objc_dynamic_subclass_restore(void *opaque_state) {
    if (opaque_state == NULL) return ZI_INVALID_ARGUMENT;
    zi_dynamic_state_t *state = opaque_state;
    object_setClass((id)state->object, state->original_class);
    return ZI_OK;
}

void zi_objc_dynamic_subclass_free(void *opaque_state) {
    if (opaque_state == NULL) return;
    zi_dynamic_state_t *state = opaque_state;
    free((void *)state->types);
    free(state);
}
