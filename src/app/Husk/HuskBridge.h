/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The app's view of the C it calls: the JIT substrate, on-device pairing, and
 * the translation layer.
 *
 * This is SWIFT_OBJC_BRIDGING_HEADER, so it cannot be deleted -- it is how Swift
 * sees C at all. It used to also declare QEMU's API and Husk's display, input,
 * GL, audio, snapshot and balloon bridges. The emulator is gone: QEMU never ran
 * on the iOS versions this targets, and Husk's own reason for existing is the
 * translation layer, which runs the app on the phone.
 *
 * The JIT declarations must stay in step with src/ios-jit/husk-ios-jit.h, and
 * the translation-layer ones with their own headers.
 */
#ifndef HUSK_BRIDGE_H
#define HUSK_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

/* --- Husk's JIT substrate ------------------------------------------------------ */
void husk_ios_jit_install_trap_handler(void);
/* Claim the JIT region while StikDebug is still attached. Pass the same size
   QEMU would have asked for (tb-size). */
bool husk_ios_jit_prewarm(size_t bytes);
bool husk_ios_jit_is_available(void);
/* Whether a plain MAP_JIT mapping executes in this process -- the second of the
   two routes to executable memory, measured rather than predicted. */
bool husk_ios_jit_mapjit_works(void);
const char *husk_ios_jit_self_route(void);
void husk_ios_jit_detach(void);
void husk_ios_jit_log_footprint(const char *tag);
size_t husk_ios_available_memory(void);

/* --- On-device pairing for Built-in StikJIT (JITPairing.swift) --------------- */
#include "HuskRPPairing.h"

/* --- The translation layer --------------------------------------------------- */
/* Compiled into the app itself: see docs/04-translation-layer.md for why. */
#include "../../translation-layer/husk-tl.h"
#include "../../translation-layer-next/husk-tl-unity-app.h"

#endif /* HUSK_BRIDGE_H */
