/* Development SPICE server: spice-server's animated test display plus
 * keyboard / mouse / tablet interfaces that print every event, so client
 * input handling can be checked without a VM.
 *
 *   test-input-server            client mouse mode (tablet + agent)
 *   test-input-server server     server mouse mode (relative mouse only)
 *
 * Listens on port 5912, no password. Based on test-display-no-ssl.c (LGPL-2.1+).
 */
#include <config.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "test-display-base.h"

static SpiceCoreInterface *core;
static SpiceTimer *ping_timer;

static void pinger(SPICE_GNUC_UNUSED void *opaque) { core->timer_start(ping_timer, 100); }

static void kbd_push(SPICE_GNUC_UNUSED SpiceKbdInstance *sin, uint8_t frag)
{
    printf("KEY 0x%02x\n", frag);
    fflush(stdout);
}
static uint8_t kbd_leds(SPICE_GNUC_UNUSED SpiceKbdInstance *sin) { return 0; }

static const SpiceKbdInterface kbd_iface = {
    .base = { .type = SPICE_INTERFACE_KEYBOARD, .description = "test keyboard",
              .major_version = SPICE_INTERFACE_KEYBOARD_MAJOR, .minor_version = SPICE_INTERFACE_KEYBOARD_MINOR },
    .push_scan_freg = kbd_push,
    .get_leds = kbd_leds,
};
static SpiceKbdInstance kbd = { .base = { .sif = &kbd_iface.base } };

static void mouse_motion(SPICE_GNUC_UNUSED SpiceMouseInstance *sin, int dx, int dy, int dz, uint32_t b)
{
    printf("MOTION %d %d %d buttons=%u\n", dx, dy, dz, b);
    fflush(stdout);
}
static void mouse_buttons(SPICE_GNUC_UNUSED SpiceMouseInstance *sin, uint32_t b)
{
    printf("MBUTTONS %u\n", b);
    fflush(stdout);
}
static const SpiceMouseInterface mouse_iface = {
    .base = { .type = SPICE_INTERFACE_MOUSE, .description = "test mouse",
              .major_version = SPICE_INTERFACE_MOUSE_MAJOR, .minor_version = SPICE_INTERFACE_MOUSE_MINOR },
    .motion = mouse_motion,
    .buttons = mouse_buttons,
};
static SpiceMouseInstance mouse = { .base = { .sif = &mouse_iface.base } };

static void tablet_size(SPICE_GNUC_UNUSED SpiceTabletInstance *t, int w, int h) { printf("TABLET_SIZE %dx%d\n", w, h); fflush(stdout); }
static void tablet_position(SPICE_GNUC_UNUSED SpiceTabletInstance *t, int x, int y, uint32_t b)
{
    printf("POSITION %d %d buttons=%u\n", x, y, b);
    fflush(stdout);
}
static void tablet_wheel(SPICE_GNUC_UNUSED SpiceTabletInstance *t, int w, uint32_t b) { printf("WHEEL %d\n", w); fflush(stdout); }
static void tablet_buttons(SPICE_GNUC_UNUSED SpiceTabletInstance *t, uint32_t b) { printf("TBUTTONS %u\n", b); fflush(stdout); }
static const SpiceTabletInterface tablet_iface = {
    .base = { .type = SPICE_INTERFACE_TABLET, .description = "test tablet",
              .major_version = SPICE_INTERFACE_TABLET_MAJOR, .minor_version = SPICE_INTERFACE_TABLET_MINOR },
    .set_logical_size = tablet_size,
    .position = tablet_position,
    .wheel = tablet_wheel,
    .buttons = tablet_buttons,
};
static SpiceTabletInstance tablet = { .base = { .sif = &tablet_iface.base } };

static const CommandType commands[] = { SIMPLE_DRAW, SIMPLE_UPDATE };

int main(int argc, char **argv)
{
    gboolean server_mode = argc > 1 && strcmp(argv[1], "server") == 0;
    Test *test;

    core = basic_event_loop_init();
    test = test_new(core);
    test_add_display_interface(test);
    spice_server_add_interface(test->server, &kbd.base);
    spice_server_add_interface(test->server, &mouse.base);
    if (!server_mode) {
        spice_server_add_interface(test->server, &tablet.base);
        test_add_agent_interface(test->server);
    }
    test_set_simple_command_list(test, commands, G_N_ELEMENTS(commands));
    ping_timer = core->timer_add(pinger, NULL);
    core->timer_start(ping_timer, 100);
    printf("listening on 5912 (%s mouse mode)\n", server_mode ? "server" : "client");
    fflush(stdout);
    basic_event_loop_mainloop();
    test_destroy(test);
    return 0;
}
