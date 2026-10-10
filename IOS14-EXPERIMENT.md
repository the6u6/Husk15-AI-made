# The iOS 14 experiment

**Status: prepared, not proven. Do not expect this to build.**

The working configuration is **iOS 15.0** and it runs — the translation layer
works on 15.3.1. This file records an attempt to go lower, what it costs, and the
two gates that have to clear before it is worth continuing.

`src/app/project.yml` has been switched to `iOS: "14.0"` as part of this. The
revert is listed in §5.

---

## 1. The toolchain, corrected

My first answer here was wrong and the correction matters, so it is worth being
precise. **Xcode 16 is not enough.** Apple's own table
(`developer.apple.com/support/xcode/`, fetched 2026-10-10):

| Xcode | iOS SDK | Deployment targets | Runs on | Swift |
|---|---|---|---|---|
| 26.x | 26.x | **iOS 15**–26.x | Sequoia 15.6+ | 6.2 |
| 16.4 | 18.5 | **iOS 15**–18 | Sequoia 15.3+ | 6.1 |
| 16.0 | 18 | **iOS 15**–18 | Sonoma 14.5+ | 6.0 |
| **15.4** | **17.5** | **iOS 12**–17.5 | **Sonoma 14.x** | **5.10** |
| 15.3 | 17.4 | iOS 12–17.4 | Sonoma 14.x | 5.10 |
| 15.2 | 17.2 | iOS 12–17.2 | Ventura 13.5 – Sonoma 14.x | 5.9 |
| 15.0.x | 17 | iOS 12–17 | Ventura 13.5 – Sonoma 14.x | 5.9 |

Xcode 16 already raised the minimum deployment target to iOS 15, alongside 26 and
27. So the newest toolchain that can express an iOS 14 target is **Xcode 15.x**,
and the newest of those is **15.4** — iOS 17.5 SDK, Swift 5.10.

Two things follow that are not obvious:

**Swift 6 never enters this.** 15.4 ships Swift 5.10, so the strict-concurrency
and `@State`-macro work that Xcode 27 would force does not apply here. That is a
genuine advantage of going this way round.

**`HuskJITHelper` has to go.** Its deployment target is 26.0, and Xcode refuses
a target above the installed SDK. No Xcode ships both an iOS 17.5 SDK and a 26.0
target, so the target cannot be built at all — not lowered, removed. Nothing
else links `StikJIT.framework`, so the `Embed StikJIT` phase went with it;
leaving it would put a framework carrying `MinimumOSVersion 17.4` into a 14.0 app.

`HuskDownloadsWidget` stays. Its 16.1 floor is below the iOS 17.5 SDK, so it
builds; it simply never loads on a device older than 16.1.

## 2. Gate one: the runner expires in 23 days

Xcode 15.4 lists **Sonoma 14.x** and nothing newer — not Sequoia. On GitHub that
means the `macos-14` runner image, and GitHub announced that macOS 14 images
begin deprecation on 2026-07-06 and are **fully unsupported from 2026-11-02**.

Today is 2026-10-10. That is 23 days.

So this experiment cannot live on a GitHub-hosted runner in the medium term.
The realistic options:

- Build it locally on a Mac running macOS 14 (Xcode 15.4 will not install on
  Sequoia per Apple's table).
- A self-hosted runner on macOS 14.
- Xcode 15.2, which Apple lists as running on Ventura 13.5 *through* Sonoma 14.x
  — still no macOS 15, so it does not dodge the problem, and it costs the 17.5
  SDK for the 17.2 one.

Note this cuts the other way from what it looks like: the 15.x path is the one
that is *short* of runway, and 15.0 is the one that keeps working.

**The workflow can now be told to build it.** `workflow_dispatch` takes
`runner-image: macos-14` and `xcode-version: 15.4`, and the preflight derives its
macOS requirement from the selected Xcode rather than hardcoding 26.2. The two
pairs are mutually exclusive and both are wrong on the other's image — Xcode 26
will not install below macOS 26.2, and Xcode 15.4 will not install above
Sonoma — so the preflight rejects a mismatched pair in one line instead of
letting it die inside ANGLE. That makes CI usable for this experiment for the
next 23 days and no longer.

## 3. Gate two: ANGLE probably will not build

`build_angle_ios.sh` sparse-clones WebKit's **`main`** branch — that is,
WebKit as of the day you run it. An iOS 14 build is pinned to a September 2024
Xcode by §1, so it would be compiling October 2026 WebKit with a two-year-old
toolchain. WebKit tracks the leading edge aggressively; that combination is
unlikely to compile.

The script already has the mechanism, added during the iOS 15 work:

```sh
WEBKIT_COMMIT=<sha> ./scripts/build_angle_ios.sh
```

Finding the sha is the problem. It needs to be a WebKit commit contemporary with
Xcode 15.4 (roughly September 2024), and it needs to be one whose ANGLE still
builds with this script's two-pass alias relink. **That cannot be determined
without building**, so it is the first thing to try and the thing most likely to
end the experiment:

```sh
WEBKIT_COMMIT=<2024-era sha> ./scripts/build_angle_ios.sh
```

Worth knowing if it does come down to that: ANGLE is what supplies EGL and
GLES. Without it there is no hardware GL, and the translation layer falls back
to the software renderer — so failing here does not fail the build, it quietly
makes everything slow.

### It fired, on 2026-10-10

```
==> building ANGLE for iOS arm64, pass 1 (log: build/logs/angle-build.log)
ANGLE build failed; last errors:
src/libANGLE/ResourceMap.h:463:9: error: static assertion failed due to requirement 'kNeedsLock'
```

**This gate is the one that decides the experiment, and it is a hard error.** The
existing Xcode 26 fix — `-Wno-error=thread-safety-attributes -Wno-error=thread-safety-analysis`
— is structurally incapable of helping. That flag demotes a *warning* to
non-fatal; `static_assert` is not a warning, so there is no flag that suppresses
it. The only remedies are an older tree or a patch.

### What the construct is, verified

`ResourceMap.h` has five `static_assert`s. The diagnostic names *only*
`kNeedsLock`, which identifies a bare `static_assert(kNeedsLock);` inside
`assignAboveCurrentFlatSize`, at **line 463 column 9** — confirmed against the
tree by fetching the file at WebKit `main`, where line 463 is exactly that
statement. The log and the tree are byte-identical.

It guards a lazily-allocated second flat resource array,
`std::atomic<ResourceType **> mAdditionalFlatResources`, published with a release
store and read acquire, so lock-free readers stay safe without growing the first
array. The guard is:

```cpp
if constexpr (kAdditionalFlatResourcesSize > 0) {
    static_assert(kNeedsLock);
```

### The actual cause: a Clang bug, not a configuration error

I had expected this to be "2026 WebKit against a 2024 compiler". The log says
something narrower and stranger.

`ANGLE_ENABLE_SHARE_CONTEXT_LOCK` is **not defined** — it appears in neither
`GCC_PREPROCESSOR_DEFINITIONS` nor the xcconfig, nor anywhere else in the build
log. So the `#else` branch of the class body is live, and there
`kAdditionalFlatResourcesSize` is the literal `0` and `kNeedsLock` is `false`.

The `if constexpr` condition is therefore the compile-time constant `0 > 0`.
The branch is a **discarded statement**, and a `static_assert(false)` inside a
discarded statement is well-formed and must not be diagnosed. Apple clang 15.4
diagnoses it anyway.

So this is a compiler defect, not something wrong with the tree or the flags.
The log confirms the rest of that: **163 of 177 translation units compiled, and
the only three `error:` lines in 1.6 MB are these.** Everything else is
warnings — 652 of them, all `SimpleMutex` capability warnings, all correctly
demoted to non-fatal by the existing `-Wno-error=thread-safety-*` pair, which is
working exactly as intended.

The bug only surfaces where `assignAboveCurrentFlatSize` is actually
instantiated, which is two files: `renderer/metal/mtl_utils.mm` and
`mtl_state_cache.mm`. Everywhere else the header is merely included.

### What to do: patch, not pin

This reverses the recommendation I made before reading the log. Rolling back two
years of WebKit to dodge one line in one header discards a tree that is 92%
compatible with this toolchain, and may trade this error for others in the
fourteen translation units that never got to compile.

Removing the line is behaviour-preserving here. Not only is the branch dead
under this configuration, the invariant it re-checks is **already asserted at
class scope** a few hundred lines earlier:

```cpp
static_assert(kAdditionalFlatResourcesSize == 0 || kNeedsLock,
              "kAdditionalFlatResourcesSize > 0 requires kNeedsLock ...");
```

The function-level assert is redundant. Nothing that can affect codegen is
removed.

`build_angle_ios.sh` now carries this as **`HUSK_CLANG15_PATCHES=1`**, off by
default so the working 15.0 / Xcode 26 build never touches the vendored tree.
The guard and the `sed` were tested against the real file: one line matched,
one line changed, and a second run is a no-op. **ANGLE built clean with it.**

```sh
HUSK_CLANG15_PATCHES=1 ./scripts/build_angle_ios.sh
```

**This has not been built.** It is a well-founded hypothesis from a complete log,
not a verified fix. If ANGLE then fails somewhere else, the rollback is the next
thing, and the pin is ready:

```
WEBKIT_COMMIT=1da41fe0a9805d4710519d5409492a557fbde951
```

Full 40 characters — `build_angle_ios.sh` fetches by name and a short sha does
not resolve. Neighbours from the same two days are `711a78ba787296a441d0805b854da8f602bfd66d`,
`5f8c05ccb28fbd0ab50b34be611409e4600eca70`, `d54de3189d86187a7d640e2f54f9f57cfc2ffb4c`.
No build has confirmed any of them.

## 3b. Gate three: virglrenderer, same root cause

ANGLE built. The run then died at `build_gpu_ios.sh`, 40 objects into 62:

```
../src/vrend/vrend_renderer.c:13026:4: error: expected expression
     char *llvmpipe_string = strstr(caps->v2.renderer, "llvmpipe");
```

Lines 13021 and 13026 of the pinned `utmapp/virglrenderer@482f9d8b` are:

```c
angle_done:          // a label
                     // blank
   /* glamor reject llvmpipe, ... */
   char *llvmpipe_string = strstr(...);   // a declaration, not a statement
```

In C17 and earlier a label must be followed by a statement, and a declaration is
not one. **C23 changed this** — WG14 **N2508**, "free positioning of labels and
empty statements" — and clang implemented it in **version 18**, listed under
*C23 Feature Support* in that release's notes. There is no backport note in 19,
20 or 21, so the allowance stays C23-only.

No `-std` rescues it either: virglrenderer's own `meson.build:30` pins
`c_std=gnu11`, and the compile line confirms `-std=gnu11`. Clang 15's
incomplete `-std=c2x` predates the feature too.

**This one is not a toolchain-version problem at all.** A label before a
declaration is invalid C11, so *any* conforming C11 compiler rejects it. It only
survives on newer toolchains because clang's implementation is more permissive
than the letter of `gnu11`. Which raises a question I cannot answer without a
Mac: your 15.0 / Xcode 26 build compiles this same commit with the same
`-std=gnu11`, so clang 21 evidently accepts it in that mode and the 18.x release
note describes only when the feature became *available*. Either way the fix is
the same and does not depend on resolving it.

The patch is one empty statement, which is a statement in every C version.
Deliberately **not** "hoist the declaration above the label": `goto angle_done`
at line 13015 already jumps past that declaration, so hoisting would leave
`llvmpipe_string` indeterminate on that path and turn the `if` on the next line
into a read of an uninitialised pointer. (That hazard is upstream's and predates
the patch — hoisting would deepen it, not hide it.) An empty statement changes
no control flow: both the `goto` and the fall-through arrive at the same place.

The same switch drives it, because it is the same problem twice:

```sh
HUSK_CLANG15_PATCHES=1 ./scripts/build_gpu_ios.sh
```

Guards and `sed` verified against the real pinned blob: one label matches, one
line changes, a second run is a no-op.

**Not yet built.** If this passes, QEMU, the guest, rppairing and the app are
still ahead — and the app is the one carrying all 323 rewritten call sites.

## 3c. Gate four: the project file format

With the native stack green, `package_ipa.sh` got as far as opening the app
project:

```
xcodebuild: error: Unable to read project 'Husk.xcodeproj' from folder .../src/app.
	Reason: The project 'Husk' cannot be opened because it is in a future Xcode
	project file format (77).
```

Not a Husk setting — **XcodeGen's default**. `options.projectFormat` defaults to
`xcode16_0`, which emits `objectVersion = 77` plus a `preferredProjectObjectVersion`
attribute. Xcode 15.4's ceiling is 63. XcodeGen's own mapping:

| `projectFormat` | `objectVersion` | `preferredProjectObjectVersion` |
|---|---|---|
| `xcode16_3` | 90 | 90 |
| `xcode16_0` *(default)* | **77** | 77 |
| `xcode15_3` | **63** | none |
| `xcode15_0` | 60 | none |
| `xcode14_0` | 56 | none |

`project.yml` now pins `projectFormat: xcode15_3`. **Unconditionally, not just
for this experiment**, because it is strictly the more portable choice: Xcode 26
opens an objectVersion 63 project without complaint, while a 77 project is
readable only by Xcode 16+. The one spec feature gated on `xcode16_0` is
`syncedFolder`, and this spec does not use it — every source is a plain group or
folder.

This is the fourth gate to fall to "the toolchain moved on and the checked-in
configuration did not", after ANGLE, virglrenderer, and the runner. Worth
noticing as a shape: nothing here is a Husk bug. Each was a correct,
up-to-date setting that a two-year-old toolchain could not read.

The `validate` job now regenerates and then asserts the resulting
`objectVersion` is ≤ 63 and that `preferredProjectObjectVersion` is gone, so the
next format bump fails in a minute on a PR rather than two hours into a build.

For the record, the feature the patch removes does not exist in a 2024 tree —
the bare assert, `mAdditionalFlatResources` and `kAdditionalFlatResourcesSize`
are all absent there — which is why the pin works if the patch does not.

### What I got wrong first

Under *either* setting of `ANGLE_ENABLE_SHARE_CONTEXT_LOCK` the assertion should
hold against current `main`: undefined, `kAdditionalFlatResourcesSize` is 0 and
the `if constexpr` discards the branch; defined, only `BufferID` has a non-zero
value and its `kNeedsLock` is true. So I expected a configuration problem and
wrote that a two-year rollback was the only route.

The log showed otherwise. The macro is undefined, the branch *is* discarded, and
Clang diagnoses it anyway — so the tree was never the problem, and the rollback
would have been treating a compiler defect as an incompatibility.

## 3a. Test the Swift sweep without ANGLE

`ci_build.sh` builds ANGLE at line 26 — before virglrenderer (33), QEMU (37), the
guest image (44), rppairing (52) and the app (56). **So the run above never
reached the app target, and all 323 rewritten call sites are still entirely
uncompiled.** That is now the largest unmeasured risk in the experiment, and it
does not depend on ANGLE at all: Swift compilation happens long before linking,
and none of the 323 sites touch the native libraries.

```sh
brew install xcodegen
cd src/app && xcodegen generate && cd ../..
xcodebuild -project src/app/Husk.xcodeproj -target Husk \
           -sdk iphoneos -configuration Release build 2>&1 | tee /tmp/sweep.log
```

This will fail — at the link step, on the missing `libqemu-aarch64-softmmu`,
`libhusk_rppairing` and `libANGLE-shared`, none of which exist yet. **Those are
expected and are not the result.** The result is every `error:` in the log that is
not a linker error: those are the genuine availability failures in the sweep, and
they are the authoritative inventory that no grep of mine can replace.

It costs minutes rather than the hours ANGLE does, and it is the cheapest way to
find out whether the backport is viable at all.

## 4. The Swift sweep -- done

### Round 2: what the compiler found that the sweep missed

The first sweep converted 323 sites from a pattern inventory. The app then
compiled far enough to produce an authoritative list, and it disagreed with the
inventory in three ways worth recording, because all three are ways a pattern
search goes wrong that look like success:

- **`.tint()` is not simply iOS 13.** `View` has two `tint` overloads:
  `tint(_: Color?)` is 13.0, and `tint(_: S?) where S: ShapeStyle` is 15.0. A
  leading-dot literal like `.tint(.white)` can only resolve through the second,
  because there is no `.white` on `Color?`. So 19 `.tint(` sites, 11 of them
  literals, were iOS 15 all along. §3's "`.tint(` was not touched: it is iOS 13"
  was wrong, and the compiler proved it.
- **`.overlay { }` with no arguments is iOS 15**, not only `.overlay(alignment:)`.
  Seven sites. The inventory had checked exactly this distinction for `.background`
  and not for `.overlay`.
- **`Compat15.swift` is compiled at the app's floor.** It stood in for iOS 16 and
  17 but was itself using `.foregroundStyle`, which is iOS 15. Excluding the
  shim file from the sweep was right for the banned-API grep and wrong for the
  compiler.

### Round 2 inventory, from the compiler's own output

| Family | Sites | Replacement |
|---|---|---|
| `Button(role:)` | 27 | role dropped; `.destructive` becomes `.foregroundColor(.red)` |
| `@Environment(\.dismiss)` + calls | 36 | `presentationMode`, iOS 13, same sheet |
| `Section("title")` | 11 | `Section(header: Text(...))` |
| `.textSelection(.enabled)` | 9 | **removed** -- no pre-15 equivalent |
| `BGContinuedProcessingTask` | 8 | **feature removed** -- see below |
| `.overlay { }` | 7 | `huskOverlay { }` |
| `AsyncImage` | 4 | `HuskAsyncImage` |
| `.textInputAutocapitalization` | 3 | `.autocapitalization` |
| `Date.formatted` / `FormatStyle` | 3 | `huskFormatDateTime` / `huskFormatDateStamp` |
| `.searchable` | 2 | `huskSearchBar` |
| `@FocusState` / `.focused` | 4 | `@State` + `onAppear` |
| `URLSession.download(for:)` | 2 | `huskDownload`, a continuation wrapper |
| `.interactiveDismissDisabled` | 1 | **removed** |
| `preferredFrameRateRange` | 1 | `#available(iOS 15.0, *)` |
| `shouldMonitorBackgroundEvents` | 1 | `#available(iOS 14.5, *)` |
| `alert` / `confirmationDialog` titles | 11 | `String(...)`, so the `StringProtocol` overload wins over the iOS 15 `LocalizedStringKey` one |

`BGContinuedProcessingTask` is **iOS 26.0**, not 16. The iOS 17.5 SDK an iOS 14
floor forces does not contain the symbol at all, so `#available` cannot rescue
it -- the compiler said "cannot find type in scope", not "only available in
iOS 26". Both call sites already degraded: `JITPairing` sets `backgroundLimited`
and warns, `Downloads` falls back to its Live Activity. So this removed a
progressive enhancement, and the fallbacks are now the only paths.

### What round 2 cost

Four self-inflicted errors, three of them mine and one a near-miss:

- `huskOverlay<A: Alignment>` -- **`Alignment` is a struct, not a protocol**, so
  the generic constraint did not compile at all, and the three call sites failed
  with "cannot infer contextual base" pointing at the arguments rather than the
  declaration.
- `.onAppear { load() }` where `load()` is async -- needs `Task { }`.
- `HuskAsyncPhase` first written as an enum, which would have meant rewriting
  four call sites that read `phase.image`; made a struct to match.
- **A round that wrote the masked source back instead of the real one**, blanking
  every string literal and comment in 14 files. Caught immediately by a residue
  check, restored from a backup taken moments earlier. Same mistake as round 1's
  colour rewrite; the mask is now search-only and splices into the source by
  offset.

Two more bugs in that helper, found only because a count came out zero:
`^` without `re.M` never matches except at offset 0, and the mask was blanking
the *quote characters*, so any pattern matching a string literal could never
match the mask at all -- which is why `Button(role:)` and `Section("title")`
reported 0 rather than 19 and 11.

### Still unexplained

`HuskBridgeFS.swift` alone produces ~40 `reference to captured var 'self' in
concurrently-executing code` errors, plus three type-checker timeouts and six
main-actor-isolation errors. **That file was never edited by any round here.** If
those were genuine, the 15.0 build would be failing too. The likeliest
explanation is that the iOS 26 SDK annotates closures `@Sendable` where 17.5 does
not, which turns a warning into an error; but that is a guess, and the Xcode 26
build log for the same file would settle it. Not addressed.

---

~330 call sites across 30 files used iOS 15.0 APIs. They compiled silently at
target 15.0; at 14.0 every one is an error. All of them are now rewritten.
**323 sites touched**, split by how faithful the replacement is:

| API | Sites | What replaced it |
|---|---|---|
| `.foregroundStyle` | 221 | `.foregroundColor` -- exact, but deprecated in modern SDKs |
| `background(_, in:)` | 41 | `huskBackground(_:in:)` -- exact |
| `Color(uiColor:)` | 30 | `Color(x)` -- exact, iOS 13 |
| `buttonStyle(.bordered*)` | 19 | `huskBorderedProminent` / `huskBordered` / `huskBorderless` -- approximate |
| `.task {}` / `.task(id:)` | 9 | `onAppear` + `onChange(of:)`, wrapped in `Task { }` where it was async |
| `.buttonBorderShape` | 6 | removed |
| `.overlay(alignment:)` | 4 | `huskOverlay(alignment:)`, a ZStack -- exact for `.center` |
| `.controlSize` | 3 | removed |
| `.submitLabel` | 2 | removed |
| `AnyShapeStyle` | 2 | wrapper removed; both branches were already `Color` |
| `.refreshable` | 2 | removed -- no pull-to-refresh below iOS 15 |
| `.symbolRenderingMode` | 1 | removed |
| `.onSubmit` | 1 | an explicit checkmark button beside the name field |
| `safeAreaInset` | 1 | the action bar overlaid, ScrollView padded past it |

`.tint(` was **not** touched. It is iOS 13, not 15, so it was never a problem;
an earlier count of this table included it by mistake.

### What the replacements cost

- **`.task` loses cancellation.** `.task(id:)` cancels the previous run when the
  id changes; `onAppear` + `onChange` starts a new one but lets the old
  `Task.sleep` finish. Where it mattered -- the auto-dismissing toast -- the
  outcome is guarded by re-checking the id. The two debounced search boxes now
  settle a fixed 200-350 ms after the last keystroke rather than as soon as
  typing stops. That is a real, if small, responsiveness change.
- **`huskOverlay` is a `ZStack`,** which sizes to the union of its children where
  an overlay does not. Safe at all four call sites because each overlays a view
  that already has a fixed frame or a fixed-size child. It is not a general
  substitute and should not be used on a view that does not.
- **The bordered button styles are approximated** with a tint fill and a rounded
  clip: right shape, roughly right colour, not the same rendering.
- **Pull-to-refresh is gone** from the Files list and the Play results list.
- **The JIT walkthrough's action bar** is an overlay with a hardcoded 116pt of
  bottom padding where `safeAreaInset` used to measure it. A page with
  unusually tall actions will not line up exactly.
- **`controlSize`, `buttonBorderShape`, `submitLabel` and `symbolRenderingMode`
  are simply gone.** No equivalent was worth writing.

`src/app/Husk/Compat14.swift` carries all of this in its header comment,
including the note that `.foregroundColor` and `.animation(_:)` are deprecated
in modern SDKs and will print warnings from Xcode 15.4. Those are expected.

### Verification

A check over the tree passes clean:

- **0** iOS 15/16/17 APIs outside `Compat14.swift` and `Compat15.swift`, across
  24 patterns
- **0** unbalanced files
- every `husk*` symbol used is defined somewhere in the tree
- 0 encoding problems (no BOMs, all valid UTF-8)
- the `validate` job's grep now covers all 24 patterns, and was itself run
  against the tree: 0 hits, 0 false positives, 0 misses against a list of
  samples that must be caught

**It is not a compiler.** It proves nothing in the banned list survives. It
cannot tell you that a replacement type-checks. Expect the build to surface
what it missed, most likely around the four structural rewrites above.

### Two CI guards this experiment broke

Both were found by running the job's own shell logic against the tree rather
than by reading it, and both are fixed:

- **The floor assertion was vacuous.** `project.yml`'s floor block opens with a
  comment explaining how to revert, and that comment quotes `iOS: "15.0"`. The
  job's `grep -m1 -oE 'iOS: "[0-9.]+"'` matched the comment rather than the
  setting below it, extracted 15.0, and checked 15.0 against 15.0 — passing while
  the file said 14.0. Comments are now stripped before the value is read.
- **The dyld invariant had a hole at exactly 14.0.** It asked "is anything above
  15.1?", so a QEMU or rppairing library left behind at 15.0 — just as fatal to a
  14.0 app, since dyld refuses a dylib whose minos exceeds the running OS —
  passed. It now reads each script's floor and compares it numerically against
  the app's, so it survives a floor change instead of encoding one.

The general lesson is the one the workflow file already carried: a guard only
helps if it is exercised against the change it is guarding. A guard that has
never been seen to fail is indistinguishable from one that cannot.

## 5. Reverting

To get back to the working 15.0 build:

1. `src/app/project.yml` — `iOS: "14.0"` → `iOS: "15.0"`
2. `scripts/build_ios.sh` — `SDKMINVER:-14.0` → `15.0`
3. `scripts/build_angle_ios.sh` — `IPHONEOS_DEPLOYMENT_TARGET="14.0"` → `"15.0"`
4. `scripts/build_rppairing_ios.sh` — `IPHONEOS_DEPLOYMENT_TARGET=14.0` → `15.0`
5. `src/app/project.yml` — restore the two blocks removed for this experiment:
   the `dependencies:` entry `- target: HuskJITHelper` under `Husk`, and the
   `HuskJITHelper` target. Both are in the project's git history; `project.yml`
   is the source of truth and `xcodegen generate` rewrites the `.pbxproj`, so
   only `project.yml` needs editing by hand.
6. Re-run the app's pre-build script check — `package_ipa.sh` validates the
   bundle and will refuse a stale one.

The checked-in `Husk.xcodeproj/project.pbxproj` still says 15.0 and 26.0. It is
a build artefact of `project.yml`; `package_ipa.sh` regenerates it when xcodegen
is installed. **If you build without xcodegen, the checked-in project wins and
none of the above takes effect** — which is also why `Compat15.swift` is
registered in it by hand.

## 6. What changed on disk for this experiment

Build configuration:

- `src/app/project.yml` -- floor 15.0 -> 14.0; `HuskJITHelper` target and its
  `dependencies:` entry removed; `postBuildScripts` (Embed StikJIT) removed;
  the libqemu dependency and the "Stage guest image" prebuild removed;
  `projectFormat` pinned to `xcode15_3` unconditionally
- `scripts/build_ios.sh`, `scripts/build_angle_ios.sh`,
  `scripts/build_rppairing_ios.sh` -- 15.0 -> 14.0
- `scripts/build_angle_ios.sh` -- the `HUSK_CLANG15_PATCHES` source patch for
  the discarded-branch Clang bug (section 3). One env var gates it.
- `scripts/build_gpu_ios.sh` -- the `HUSK_CLANG15_PATCHES` virglrenderer patch
  for label-before-declaration (C23 N2508, clang 18). One env var gates it.
- `scripts/ci_build.sh` -- the QEMU and guest-image stages removed
- `scripts/package_ipa.sh` -- the libqemu staleness check and guest-file
  validation removed

Swift:

- `src/app/Husk/Compat14.swift` -- **new**. The iOS 15 stand-ins: background,
  overlay, the three button styles, `HuskAsyncImage`, search bar, date
  formatting, `URLSession.huskDownload`, `huskDialog`, and the two `UIColor`
  values (`systemMintFallback`, `systemCyanFallback`) that are themselves iOS 15.
- **33 existing Swift files** edited for the sweeps. All paths below are
  relative to `src/app/`; the bare names are in `Husk/`:
  `Husk/AppDetailView`, `Husk/AppIcon`, `Husk/AppTheme`, `Husk/BootScreen`,
  `Husk/ContentView`, `Husk/CrashReport`, `Husk/DiscoverTab`, `Husk/Downloads`,
  `Husk/DownloadsTab`, `Husk/FilesTab`, `Husk/GameStatus`, `Husk/HuskBridgeFS`,
  `Husk/HuskKeyboard`, `Husk/IncomingFiles`, `Husk/ItemPages`, `Husk/JITCard`,
  `Husk/JITPairing`, `Husk/JITSetupView`, `Husk/Launcher`,
  `Husk/OnboardingView`, `Husk/SettingsTab`, `Husk/Showcase`,
  `Husk/TechnicalDetails`, `Husk/TLAppSettings`, `Husk/TLUnityView`,
  `Husk/Theme`, `Husk/TranslationLayer`, `Husk/VirtualPad`, `Husk/WhatsNew`,
  `Husk/Play/GoogleSignInSheet`, `Husk/Play/PlayAPI`, `Husk/Play/StoreView`,
  `HuskDownloadsWidget/DownloadsWidget`.
  `Husk/Compat15.swift` is untouched and still required: iOS 14 lacks
  everything iOS 16 and 17 added as well.
- `.github/workflows/build.yml` -- the `validate` job's banned-API list extended
  to cover the iOS 15 families, and `Compat14.swift` excluded alongside
  `Compat15.swift`; `workflow_dispatch` inputs added for `runner-image`,
  `xcode-version`, `clang15-patches` and `webkit-commit`; job-level env, cache
  key and a preflight guard added; `qemu` uninstall and the `guests/phase0`
  cache removed. **The defaults reproduce the working 15.0 build untouched** --
  `inputs` is empty on `push` and `release`, so those fall back to
  `macos-26`/`26.6` silently. Check the preflight's `::notice::trigger=` line to
  confirm which path a run took.

## 4a. Round 6: the last iOS 15 families

Xcode 15.4 on `macos-14`, `HUSK_CLANG15_PATCHES=1`, all four gates from
sections 3, 3b and 3c passing. First real compile of the tree: **~90 errors**.
The third round closed all but four families.

### The `HuskBridgeFS` concurrency cluster: 40 errors, all gone

The largest single block in the build. `Task.detached`'s body and
`MainActor.run`'s body are both `@Sendable`; the weak `[weak self]` capture
makes `self` a var, and a var may not be read from inside a `@Sendable` body.
The fix throughout is an immutable alias taken before the closure:

```swift
let huskSelf = self          // an immutable let, not a var capture
Task.detached { huskSelf?.load() }
```

An immutable alias is not a var capture, which is why this works where
`guard let self else { return }` was rejected earlier -- that inserts a `return`
and changes the inferred `Success` of a fire-and-forget `Task.detached`, which
cannot be checked without a compiler.

Eight aliases in `HuskBridgeFS`, two in `TLUnityView`, and snapshots for
`attempt`, `labels`, `found`, `rows`/`why`, `copies`.

**Why these fire only at 14.0 and not at 15.0 is still unexplained.**
`SWIFT_VERSION` is `5.0` in both configurations, and this diagnostic is normally
a warning in Swift 5. The Xcode 26 log for `HuskBridgeFS.swift` would settle
it. If the cause is toolchain-shaped rather than availability-shaped, the whole
40-site rewrite is churn the 15.0 build never needed -- so it is worth reading
that log before accepting the rewrite as *correct* rather than merely working.

### Dialogs: the family that resisted two attempts

`alert(_:isPresented:actions:message:)` and
`confirmationDialog(_:isPresented:titleVisibility:actions:message:)` are iOS 15.
Passing `String(...)` instead of a literal does **not** help: it does not change
which overload the compiler picks, and the build kept reporting 15.0 both times.
Apple's documentation only ever exposes the current signature, which is why the
titled pre-15 overloads were hard to find.

The one form that is unambiguously iOS 13 is `alert(isPresented:content:)`,
whose `content` returns an **`Alert` value** rather than a view. That is what
`huskDialog` wraps. Two consequences, both real:

- `Alert` has a primary and a secondary button and **no third**. A dialog with
  three actions cannot be expressed this way at all.
- A `confirmationDialog` rendered as an `Alert` is a centred dialog on iOS 14,
  not a sheet from the bottom. Hence the name: it is not that control rendered
  differently, and the name is meant to make that visible at each call site.

Eleven call sites converted. One behavioural accident worth noting: the
secondary button is `Alert.Button.cancel`, which dismisses by writing `false`
through `isPresented` rather than by running an action. Every converted site
already had a `set:` clause that did exactly what its old `role: .cancel` button
did -- `updates.dismiss()`, `showcase.asked()`, `guest.dismissUpdate()` -- so
the cancel paths are unchanged. That was luck, not design, and a twelfth site
with an inert `set:` would not be so lucky.

`SettingsTab`'s "Which saved machine?" has three actions. It became a sheet
(`SavedMachineChooser`) listing the two machines. A sheet is the better fit for
"which one?" anyway, and `Button(action:label:)` plus `.foregroundColor` are
both fine at 13.

### Three that were mine, and one that was not

- `Compat14.swift` changed `HuskAsyncPhase` to carry `Image` but the
  `.success(...)` call site still passed a `UIImage`; the replacement string had
  the wrong indentation and silently matched nothing.
- `HuskBridgeFS.swift:997` declared `let labelMap = labels` twice. The script
  that inserts it has **no idempotency guard**, and it ran twice -- once to
  apply, once inside a verification step. Scripts in `%TEMP%` that rewrite
  source need a guard for this reason, not just a good pattern.
- `UIColor.systemMint` and `.systemCyan` are **themselves iOS 15**. Substituting
  the UIColor palette for the SwiftUI one moved the problem rather than solving
  it; `systemTeal` and `systemIndigo` are iOS 13, which is why only two of the
  four errored. Now explicit values in `Compat14.swift`.
- `DownloadsTab` used `swipeActions`, which is iOS 15 and which no inventory
  here had caught -- it reached the compiler first. iOS 14 has no swipe actions;
  `contextMenu` is the closest affordance and the trade is long-press for swipe.

**`GameStatus.swift:77` is reconstructed and must be checked by eye.** Round 1
rewrote a line to `.foregroundColor(.white, result.color)`, and no SwiftUI
overload takes two foreground styles -- so whatever the original was, it was not
that. The pre-sweep text was gone before any backup existed. It is read as a
status ring: the neutral disc stays, so the mark reads against any icon
artwork, and the result colour becomes the ring around it. The reasoning is in a
comment at the site.

### One bug the brace walk caught

The `Close Husk` conversion's match pattern covered only the dialog header and
the `Button("Close Husk") {` line. Replacing that removed the Button's opening
brace while leaving its body, its closing brace, and the `} message: { ... }`
block -- which had by then become a duplicate of the `message:` argument already
in the `huskDialog` call. Net: one stray `}`.

It compiled nowhere near as many other conversion mistakes have, because a stray
brace often still balances by accident. What caught it was walking brace depth
per line and reporting the first line that dropped below the level it opened
at -- and confirming against the pre-round-2 snapshot that the imbalance was new
rather than inherited. Every other conversion matched the full block to the
closing brace of the message closure, which is why it was one and not four.

Two false positives worth recording so they are not re-investigated:
`Launcher.swift:455` matches "comma inside `foregroundColor`" because the comma
is inside `Color(red:green:blue:)`; `GameStatus.swift:79` because the comma is
in the reconstruction comment. And `verify_conc.py`'s FilesTab complaint is a
known over-broad check -- the `var`s it flags are local declarations *inside* a
`Task.detached` body, capturing nothing, and the snapshot is taken on the next
line.

### Also removed

`BGContinuedProcessingTask` is **iOS 26.0** and absent from the iOS 17.5 SDK
entirely, so no `#available` can rescue it. `Downloads.swift` lost 94 lines and
`JITPairing.swift` three functions; both had fallbacks already.

The VM build pipeline is gone: QEMU stages in `ci_build.sh`, the libqemu
dependency and guest-image prebuild in `project.yml`, guest validation in
`package_ipa.sh`, and the `qemu` uninstall plus `guests/phase0` cache in
`build.yml`. `AndroidHost` stays -- it is the shared package model the
translator uses, not VM code. Only `QemuRunner.swift` (99 KB),
`GuestImage.swift` (52 KB) and `GuestManifest.swift` (7 KB) are pure VM, and
their ~250 Swift references are still to be swept.

## 7. If you continue

1. **Push, and check what CI actually has.** The build that produced the round
   6 error list was compiling a stale `src/app/Husk/Play/`: `StoreView`,
   `PlayAPI` and `GoogleSignInSheet` all reported errors at lines this tree had
   already fixed. The line numbers prove it -- CI's `StoreView:29` is this
   tree's line 31, so it is three lines short and does not have the `searchable`
   conversion at all. Fix that before reading another error list.
2. **Delete the VM Swift.** `QemuRunner.swift`, `GuestImage.swift`,
   `GuestManifest.swift`, then sweep ~250 references across 20 files. Pure
   deletion, and unlike everything above every miss is a compile error with no
   mechanical rescue -- budget for reading each one.
3. **Decide about Built-in JIT.** Removing it costs the on-device pairing flow
   (`JITPairing.swift`, `JITSetup.swift`, `JITCard`, `SettingsTab`) -- real
   surface area to delete for a feature that could never load at 14.0 anyway.
   Or leave it out and let StikDebug, TrollStore or a jailbreak carry JIT,
   which is what a 14.x user would have regardless.
4. **Read the Xcode 26 log for `HuskBridgeFS.swift`** before shipping the
   concurrency rewrite. See 4a.

Section 2 still applies to all of it: the only GitHub-hosted image that can run
Xcode 15.4 is `macos-14`, unsupported from 2026-11-02. These builds have to
happen on a local or self-hosted macOS 14 machine.

Nothing in this experiment has been compiled on a machine with a Swift compiler
other than CI. Every check here is brace balance, regex residue, mask audits
and reading.

## 4b. Round 7: the compiler's second list

Same four gates, same toolchain. **24 errors**, down from ~90. Every one is now
addressed; the first four were mine and the rest were latent.

### The trailing-closure ordering bug

Four files failed with `consecutive statements on a line must be separated by
';'` at the line after a `huskDialog` call. The cause was my own signature:

```swift
func huskDialog(..., primaryAction: @escaping () -> Void, secondary: String)
```

**A trailing closure binds to the last parameter.** With `secondary:` declared
after the closure, the only spelling available was `} secondary: "Cancel"`,
which is not Swift. Three sites wrote exactly that; three more (ContentView)
passed `secondary:` on the line *after* a trailing closure. All six failed.

`secondary:` now comes before the closure, and there are two two-action
overloads: one where the secondary is a bare Cancel (`.cancel`, no action) and
one where it has a body (`.default` + action). They are distinguished by
`secondaryAction` having no default, so neither can match the other's calls.
The one-action overload was already correct -- its closure parameter is last --
which is why those five sites compiled.

The lesson is about the check, not the code: my verifier confirmed every label
present matched an overload, and it did. It never asked where the closure
parameter sat in the declaration order, which is the only thing that makes a
trailing closure legal. `order_check.py` now does.

### Main-actor isolation, five sites

`Downloads.bytes`, `HuskFilePicker.present`, and three `VirtualPad` members are
`@MainActor`, called from nonisolated contexts.

- `Downloads` is `@MainActor final class`; `bytes` is a pure formatter with no
  state, so `nonisolated static func bytes` is the honest fix rather than an
  isolation hop at five call sites.
- `HuskFilePicker` is a `@MainActor enum`; the `onChange` closure that calls
  `present` is not. A `Task { @MainActor in }` hop, which is free because
  `onChange` already fires on the main actor.
- `VirtualPad.update` writes members of `PadView`, which is `@MainActor`.
  `makeUIView` constructs a `PadView` on the line above without error, which
  is what proves `makeUIView` is already main-actor isolated -- and that is
  what makes annotating `update` safe rather than a new error.

### Two type-check timeouts

`SettingsTab` had two `Form` bodies the solver gave up on, and
`HuskBridgeFS.refreshMetadata` had a nine-term string concatenation chain.
Both are solver blow-ups, not errors.

The fix for both is the same shape: cut the expression into pieces the checker
solves independently. Ten `Section`s came out of the two `Form` bodies into
typed properties (`screenSection` ... `sideloadingSection`), and the shell
script became a multi-line literal. The script was diffed against the original
after whitespace normalisation -- newlines and semicolons are both command
separators in a shell, so the guest sees the same commands.

### Two that were not what they looked like

- `ApkMetadata.string(for:)` indexed `found[0]` on a non-optional array and the
  compiler still saw an optional. `guard let ... ?? found.first` states the
  intent and is correct either way.
- `HuskBridgeFS` used `.whitespaces` where the contextual base could not be
  inferred. `CharacterSet.whitespaces`.

### Stale CI, again

The build that produced this list was still compiling the pre-round-6 tree:
`AppDetailView:145` was reported at the exact columns of the old
`} secondary: "Cancel"` form, which this tree no longer contains. **Push before
reading another error list** -- the line numbers are the evidence, and they are
never wrong about it.

## 4c. Round 8: three expressions, one cause

Down to three errors, all in `SettingsTab.swift`, all the same diagnostic.
Extracting the `Section`s into properties the round before had not been enough,
because the blow-up was *inside* three of the properties.

Two shapes cause it:

1. **A ternary whose branches are each a chain of `+` over string literals.**
   `cond ? "a" + "b" : "c" + "d" + "e"` -- the checker resolves `+` across
   `String` and its literal protocols at every level, and the search space is
   the product of the levels.
2. **A nested ternary**, `a ? x : b ? y : z`, for the same reason.

Both were in `Text(...)` footers and `DetailRow(value:)` arguments. The fix is
to name the value with an explicit type -- `let text: String = ...` -- so every
`+` has exactly one applicable overload. Six expressions across the three
properties; nothing about the rendered text changes, and the literals were
re-read to confirm it.

One more of the same shape turned up in `resolutionSection` on the line after
the footer: `HuskLog.log("ui", v ? "on: " + "\(w)x\(h)" : "off")`, a ternary
whose branch is a `+` over an *interpolated* literal.
