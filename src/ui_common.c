#include "ui.h"

#include "globals.h"
#include "os.h"

void io_seproxyhal_display(const bagl_element_t *element);

void io_seproxyhal_display(const bagl_element_t *element) {
    return io_seproxyhal_display_default((bagl_element_t *)element);
}

void ui_init(void) {
    UX_INIT();
}

void register_ui_callback(uint32_t which, string_generation_callback cb, const void *data) {
    if (which >= MAX_SCREEN_COUNT) THROW(EXC_MEMORY_ERROR);
    global.ui.prompt.callbacks[which] = cb;
    global.ui.prompt.callback_data[which] = data;
}

__attribute__((noreturn))
bool exit_app(void) {
#ifdef BAKING_APP
    require_pin();
#endif
    BEGIN_TRY_L(exit) {
        TRY_L(exit) {
            os_sched_exit(-1);
        }
        FINALLY_L(exit) {
        }
    }
    END_TRY_L(exit);

    THROW(0); // Suppress warning
}
