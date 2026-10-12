/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The JIT substrate, gone.
 *
 * src/ios-jit/husk-ios-jit.c implements these, and it is compiled into the
 * QEMU library rather than into the app -- see project.yml, where the app
 * target's sources are the two translation-layer trees, Husk/, Shared/ and the
 * pairing Rust library. When QEMU came out of Husk its cross-build went with
 * it, so nothing in this repository defines them any more.
 *
 * HuskBridge.h is the bridging header, so every Swift call site still resolves
 * at compile time and then fails at link. These definitions exist only to
 * satisfy the linker, which is why every one of them answers "no": there is no
 * trap handler to install, no region to claim, and no route by which this
 * process can map executable memory, because the thing that did that was
 * removed.
 *
 * That is not a stub standing in for a feature -- it is the honest answer, and
 * JITBootstrap reads it: JITBootstrap.ready is false, so nothing that needs
 * executable memory starts. StikDebug pairing still works, because that is
 * HuskRPPairing.h and a Rust library the build still compiles.
 *
 * HuskBridge.h is included rather than the signatures repeated, so these cannot
 * drift from the declarations the Swift side compiles against.
 */
#include "HuskBridge.h"

#include <stddef.h>

void husk_ios_jit_install_trap_handler(void) { }

/* Claim the JIT region. There is no region without the emulator's mapping. */
bool husk_ios_jit_prewarm(size_t bytes) { (void)bytes; return false; }

bool husk_ios_jit_is_available(void) { return false; }

/* Whether a plain MAP_JIT mapping executes here. Measured, not predicted --
   and the measurement is now simply no. */
bool husk_ios_jit_mapjit_works(void) { return false; }

/* Which route this process would take to executable memory: the trap handler
   first, a MAP_JIT mapping second. With neither, NULL -- which is what
   JITBootstrap reads to decide it has no way to get executable memory. */
const char *husk_ios_jit_self_route(void) { return NULL; }

void husk_ios_jit_detach(void) { }

void husk_ios_jit_log_footprint(const char *tag) { (void)tag; }

size_t husk_ios_available_memory(void) { return 0; }