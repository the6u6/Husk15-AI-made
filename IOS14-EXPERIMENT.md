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
  `dependencies:` entry removed; `postBuildScripts` (Embed StikJIT) removed
- `scripts/build_ios.sh`, `scripts/build_angle_ios.sh`,
  `scripts/build_rppairing_ios.sh` -- 15.0 -> 14.0

Swift:

- `src/app/Husk/Compat14.swift` -- **new**. The iOS 15 stand-ins: background,
  overlay, and the three button styles.
- **27 existing Swift files** edited for the section 4 sweep:
  `AppDetailView`, `AppIcon`, `BootScreen`, `ContentView`, `CrashReport`,
  `DiscoverTab`, `DownloadsTab`, `FilesTab`, `GameStatus`, `HuskKeyboard`,
  `IncomingFiles`, `ItemPages`, `JITCard`, `JITSetupView`, `Launcher`,
  `OnboardingView`, `SettingsTab`, `Showcase`, `TechnicalDetails`,
  `TLAppSettings`, `TLUnityView`, `Theme`, `TranslationLayer`, `WhatsNew`,
  `HuskDownloadsWidget/DownloadsWidget`, `Play/GoogleSignInSheet`,
  `Play/StoreView`.
  `Compat15.swift` is untouched and still required: iOS 14 lacks everything
  iOS 16 and 17 added as well.
- `.github/workflows/build.yml` -- the `validate` job's banned-API list extended
  to cover the iOS 15 families, and `Compat14.swift` excluded alongside
  `Compat15.swift`.

## 7. If you continue

In order, because each step can end it cheaply:

1. `WEBKIT_COMMIT` for a 2024-era WebKit, then `build_angle_ios.sh` on a macOS
   14 Mac. **This is the experiment**; everything else is downstream. If ANGLE
   fails you do not get a build error, you get a *slow* one -- no EGL/GLES, so
   the software renderer. "It works but everything crawls" means this failed
   quietly.
2. If ANGLE builds, regenerate the project and build the app target. Expect
   deprecation warnings (fine, and documented in `Compat14.swift`) plus some
   genuine availability errors from APIs neither section 4 nor the checker knew
   about. That compiler output is the real inventory; it is better than any
   grep of mine.
3. Then decide about Built-in JIT. Removing it costs the on-device pairing flow
   (`JITPairing.swift`, `JITSetup.swift`, `JITCard`, `SettingsTab`) -- real
   surface area to delete for a feature that could never load at 14.0 anyway.
   Or leave it out and let StikDebug, TrollStore or a jailbreak carry JIT,
   which is what a 14.x user would have regardless.

Section 2 still applies to all of it: the only GitHub-hosted image that can run
Xcode 15.4 is `macos-14`, unsupported from 2026-11-02. These builds have to
happen on a local or self-hosted macOS 14 machine.
