/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The libqemu bridge, gone.
 *
 * Every prototype in HuskBridge.h used to be satisfied by
 * libqemu-aarch64-softmmu.dylib. That dependency and its cross-build were
 * removed when QEMU was taken out of Husk -- it never worked well enough on iOS
 * to be worth carrying, and iOS already has an emulator. Nothing in this
 * repository defines those 33 symbols now, and HuskBridge.h is the bridging
 * header, so every Swift call site resolves at compile time and then fails at
 * link time.
 *
 * These definitions exist only to satisfy the linker. HuskBridge.h is included
 * rather than the signatures repeated, so they cannot drift from it.
 *
 * Three behaviours, because the symbols are not all the same kind of thing:
 *
 *   1. qemu_init / qemu_main_loop / qemu_cleanup -- the launch path. They
 *      abort. A silent return would be worse: QemuRunner would read
 *      qemu_init() returning as "the machine started", carry on setting up a
 *      display, and come straight back out of a qemu_main_loop() that returns
 *      at once. A launch would then hang on a guest screen that never appears,
 *      with nothing in the log to say why. Aborting names the cause on stderr
 *      and in the crash report.
 *
 *   2. The display/audio/snapshot bridge -- husk_display_*, husk_audio_*,
 *      husk_snapshot_*, husk_balloon_*. These return safe defaults rather than
 *      aborting, because HuskMetalView, HuskGLView, HuskKeyboard and
 *      HuskAudio call them per frame, not per launch. Aborting here would crash
 *      the app constantly for code that only ever mattered once a VM was
 *      running -- which, since qemu_init() aborts, can no longer happen.
 *
 *   3. The built-in JIT bridge -- husk_ios_jit_*, husk_ios_available_memory.
 *      Safe defaults too, and "unavailable" is the honest answer: the built-in
 *      JIT was already removed from the build as its own target, so this path
 *      was dead before the dylib was. JITBootstrap, SettingsTab and HuskLog
 *      read these, and what they want from a missing one is false.
 *
 * These are stubs, not a fallback. The real fix is to delete QemuRunner.swift,
 * GuestImage.swift and GuestManifest.swift along with the display, audio and
 * JIT-bridge call sites that reach them. docs/00-architecture.md still
 * describes the dylib as though it were linked.
 */
#include "HuskBridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- 1. launch */

static void husk_vm_absent(const char *fn);

static void husk_vm_absent(const char *fn)
{
	fprintf(stderr,
	        "\n"
	        "Husk: %s() was called, but the virtual machine is not in this build.\n"
	        "\n"
	        "  QEMU was linked as libqemu-aarch64-softmmu.dylib. That dependency and\n"
	        "  its cross-build were removed; these symbols have no definition left.\n"
	        "  QemuRunner.swift still calls them, so this is a link-time stub that\n"
	        "  aborts rather than pretending the machine started.\n"
	        "\n"
	        "  Nothing here is a bug in the emulator code. Running Android is not\n"
	        "  supported in this build.\n"
	        "\n",
	        fn);
	fflush(NULL);
	abort();
}

void qemu_init(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	husk_vm_absent("qemu_init");
}

void qemu_main_loop(void)
{
	husk_vm_absent("qemu_main_loop");
}

void qemu_cleanup(void)
{
	husk_vm_absent("qemu_cleanup");
}

/* ------------------------------------------------- 2. display / audio / VM io */

void     husk_display_init(void) { }
bool     husk_display_lock_frame(HuskFrameInfo *out) { if (out) memset(out, 0, sizeof(*out)); return false; }
void     husk_display_unlock_frame(void) { }
uint64_t husk_display_sequence(void) { return 0; }
void     husk_display_send_pointer(int32_t x, int32_t y, bool button_down) { (void)x; (void)y; (void)button_down; }
bool     husk_display_send_key(const char *qcode_name, bool down) { (void)qcode_name; (void)down; return false; }
void     husk_display_request_update(void) { }
void     husk_display_set_ui_size(int32_t width, int32_t height) { (void)width; (void)height; }
void     husk_display_guest_size(int32_t *width, int32_t *height) { if (width) *width = 0; if (height) *height = 0; }

bool     husk_display_gl_early(void) { return false; }
bool     husk_display_gl_create(void *native_layer, int32_t width, int32_t height) { (void)native_layer; (void)width; (void)height; return false; }
bool     husk_display_gl_probe(void) { return false; }
bool     husk_display_gl_bind(void) { return false; }
uint64_t husk_display_gl_frames(void) { return 0; }
void     husk_display_gl_set_metal_presenter(husk_metal_present_fn fn) { (void)fn; }

int32_t  husk_audio_pull(int16_t *dst, int32_t frames) { (void)dst; (void)frames; return 0; }
bool     husk_audio_active(void) { return false; }
uint64_t husk_audio_frames_in(void) { return 0; }
uint64_t husk_audio_underruns(void) { return 0; }

bool     husk_snapshot_load_at_startup(void) { return false; }
void     husk_snapshot_save(void (*cb)(bool ok, const char *what)) { if (cb) cb(false, "snapshots are not available in this build"); }
void     husk_balloon_set_bytes(int64_t target_bytes) { (void)target_bytes; }

/* ------------------------------------------------------ 3. the built-in JIT */

void        husk_ios_jit_install_trap_handler(void) { }
bool        husk_ios_jit_prewarm(size_t bytes) { (void)bytes; return false; }
bool        husk_ios_jit_is_available(void) { return false; }
bool        husk_ios_jit_mapjit_works(void) { return false; }
const char *husk_ios_jit_self_route(void) { return NULL; }
void        husk_ios_jit_detach(void) { }
void        husk_ios_jit_log_footprint(const char *tag) { (void)tag; }
size_t      husk_ios_available_memory(void) { return 0; }
