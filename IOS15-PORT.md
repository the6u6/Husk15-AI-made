# The iOS 15 port

Husk's app target used to need **iOS 16.0**. It now needs **iOS 15.0**.

Nothing about the translation layer, QEMU, or the JIT changed. The whole of the
16.0 floor was the SwiftUI the app is written in, exactly as `project.yml` said
before this change:

> 16.0: the lowest the app builds at as written (its SwiftUI is iOS 16)

This file records what was changed, why, and how to check the result. It is
written for the person building this, on a Mac, with Xcode — because that
person is the only one who can compile any of it.

---

## 1. Why 15.0 and not 16.0, and what sets the floor

The app cannot deploy lower than the newest native thing it embeds. dyld
refuses to load a dylib or framework whose `LC_BUILD_VERSION` `minos` exceeds
the running OS, so an embedded binary above the app's floor is a silent
launch-time failure, not a warning.

The good news is that Husk's native side was **already below 16.0**. It was
built at 15.5 while the app shipped at 16.0 — the ANGLE build script even said
so in a comment. So the floor was the app alone, and it was 0.5 above what the
natives already supported for no reason.

To reach 15.0 all three had to come down together:

| Component | Was | Now | Where |
|---|---|---|---|
| App target | 16.0 | **15.0** | `src/app/project.yml`, `Husk.xcodeproj/project.pbxproj` |
| QEMU + deps | 15.5 | **15.0** | `scripts/build_ios.sh` (`SDKMINVER`) |
| ANGLE | 15.5 | **15.0** | `scripts/build_angle_ios.sh` |
| rppairing | 15.5 | **15.0** | `scripts/build_rppairing_ios.sh` |
| MoltenVK | 1.4.2's own floor | unchanged | `make ios`; already well below 15.0 |

**Change these together or not at all.** Setting the app to 15.0 while ANGLE
stays at 15.5 leaves a phone on 15.0–15.4 unable to load
`libANGLE-shared.dylib`, which kills the GL stack at `qemu_egl_init_dpy_cocoa`
— the same failure `project.yml` already documents for a missing ANGLE.

### 15.0 is exactly Apple's floor, and stays that way

Worth stating because it decides how long this port stays buildable. From
Apple's Xcode support table:

| | Xcode 26.6 | Xcode 27 |
|---|---|---|
| iOS deployment targets | **15** to 26 | **15** to 27 |
| tvOS / watchOS / visionOS / macOS / DriverKit | 15 / 8 / 1 / 11 / 20 | 15 / 9 / 1 / 12 / 21 |

iOS is the one floor Xcode 27 did **not** raise. Everything else moved; iOS
stayed at 15. So 15.0 is not merely tolerated here, it is the officially
supported minimum — today and on the next Xcode. The only diagnostic it earns
is `The iOS deployment target is set to 15.0, but the range of supported
deployment target versions is 15.0 to 27.x`, which is a warning about being at
the edge, not an error.

Choosing 15.5 (what the ANGLE script was already built to) would work today and
need revisiting at the next floor change. 15.0 needs no revisiting.

Also worth knowing, since a newer Xcode is a natural next step. Three Xcode 27
breakages were checked against this tree:

- **`-ld_classic` / `-ld64`.** Xcode 27 removed ld64; `-ld64` fails the link
  with `ld: library 'd64' not found`. Husk passes neither — the only mention in
  the repo is prose in `integrate_husk.sh:586` describing what meson generates.
- **`ARCHS_STANDARD` silently dropping x86_64.** Only at a macOS 27.0 or
  DriverKit 27.0 target. `project.yml` sets `ARCHS: arm64` outright anyway.
- **The new `@State` macro.** This is the one to watch, because it keys off the
  *compiler* rather than the deployment target. An initializer that assigns a
  `@State` property already carrying a declaration-site value, before the other
  stored properties, stops compiling (`variable 'self.x' used before all stored
  properties are initialized`). No struct in `src/app` has that shape.

### If ANGLE refuses to go to 15.0

WebKit's ANGLE xcconfigs may not accept a 15.0 floor. If the build fails there,
raise **both** ANGLE and `project.yml` to **15.5** and stop. 15.5 covers
15.5/15.6/15.7/15.8, which is essentially every iOS 15 phone actually in use.
Do not ship an app at 15.0 with ANGLE at 15.5.

---

## 2. JIT is not the problem here

Both the translation layer and Emulation need writable-and-executable memory,
and on iOS 15 **that is easier, not harder**, than on the versions Husk was
built for:

- **No TXM.** `docs/02-jit-substrate.md` is explicit that on iOS 26/27 the
  only workable path is the debugger-writes-`0x69`-into-every-16-KiB-page
  trick, because Apple's Trusted Execution Monitor removed the older
  page-protection scheme. iOS 15 predates TXM entirely, so the pre-TXM
  behaviour is the default one and `docs/02-jit-substrate.md`'s own note that
  the older trick "is not a fallback we can keep in our back pocket" simply
  does not apply.
- **TrollStore's checkm8 range covers iOS 15.0–15.8.x**, and TrollStore keeps
  Husk's `dynamic-codesigning` entitlement, so `Allow JIT in Apps` is a
  one-tap path on the same IPA.
- **Dopamine** supports iOS 15.0 upward on the devices that can run it.
- **StikDebug** works as before.

`src/ios-jit/husk-tl-codewrite.c`, `husk-brk.S` and the translation layer were
not touched. Their only availability guards are `__builtin_available(iOS 26.0,
*)`, which are already correct.

---

## 3. What the Live Activity and the JIT helper do

The two app extensions keep their own, higher floors, and were not changed:

| Target | Floor | Why | Behaviour on iOS 15 |
|---|---|---|---|
| `HuskDownloadsWidget` | 16.1 | Live Activities are iOS 16.1 | Plugin is not registered; no download progress on the Lock Screen. The in-app download list is unaffected. |
| `HuskJITHelper` | 26.0 | Built-in StikJIT | Never loads. Fall back to StikDebug / TrollStore / jailbreak, which `JITSetupView` already offers. |

An embedded extension with a floor **above** the host app is legal — pluginkit
simply never registers it below its own version. This is already how Husk ships
a 26.0 helper inside a 16.0 app.

Their code was already correct:

- `Shared/HuskDownloadActivity.swift` is `#if canImport(ActivityKit)` **and**
  `@available(iOS 16.1, *)`.
- `Downloads.swift` guards every call site with `#available(iOS 16.1, *)`.

So downloads and JIT setup need no code changes to keep working.

---

## 4. The compatibility layer

Every iOS 16/17-only API the app used now goes through one shim, in a new file:

### `src/app/Husk/Compat15.swift` (new)

| Shim | Replaces | Needs | Call sites |
|---|---|---|---|
| `HuskNavStack<T, Root, Page>` | `NavigationView(path:)` + `.navigationDestination(for:)` + `NavigationLink(value:)` | 16.0 | 4 stacks, 8 links |
| `HuskLabeledContent` | `LabeledContent` | 16.0 | 16 |
| `huskDetent(_:)` / `huskDragIndicator()` | `.presentationDetents` / `.presentationDragIndicator` | 16.0 | 4 |
| `Animation.huskSnappy` | `Animation.snappy` | 17.0 | 8 |
| `huskAnimation(_:value:)` | `.animation(_:value:)` | 17.0 | 9 |
| `HuskShareButton` | `ShareLink(item:)` | 16.0 | 1 |

**The file is registered in the checked-in `project.pbxproj`**, in all four
places a Swift file has to appear (build file, file reference, group, sources
phase). This matters because `scripts/package_ipa.sh` only runs `xcodegen` *if
it is installed*:

```sh
if command -v xcodegen >/dev/null 2>&1; then
    (cd "$HUSK_ROOT/src/app" && xcodegen generate --quiet)
else
    echo "==> xcodegen not installed; using the checked-in project as-is" >&2
fi
```

Without the pbxproj entries, building without xcodegen would compile every
other file and silently omit the shim, and the app would not link.

---

## 5. Every change, and what it costs

### 5.1 `NavigationStack` → `NavigationView` (15 sites, 10 files)

`NavigationView` still works on iOS 16/17; it is soft-deprecated, not removed.
A one-word substitution that behaves identically everywhere.

### 5.2 Path-based navigation → `HuskNavStack` (the real work)

`NavigationView(path:)` and `.navigationDestination(for:)` are both iOS 16,
and iOS 15's `NavigationView` has no path at all. Four stacks were converted:

| File | Stack | Driven from |
|---|---|---|
| `Launcher.swift` (HomeView) | `$router.home` | tap only |
| `Launcher.swift` (LibraryScreen) | `$router.library` | tap, **and** `Router.resumeSwitch()` at launch |
| `FilesTab.swift` | `$router.files` | tap, **and** `Router.openFiles(at:)` |
| `JITSetupView.swift` | local `[Step]` | `path.append(...)` only |

`HuskNavStack` keeps the `Router`'s `[T]` shape and reads it as a binding, so
`resumeSwitch()` and `openFiles(at:)` keep working untouched — `openFiles`
still lands you inside an app's own folder on the first frame.

Husk never stacks deeper than one level (a tile opens a page, Back returns),
so "head of the path or nothing" plus a Back toolbar item is the same flow.

**Costs:**
- The system push animation is gone; the page swaps in place. A Back button in
  the toolbar replaces the system's chevron.
- `FilesTab`'s directory rows are now `Button`s rather than `NavigationLink`s,
  so the disclosure affordance is an explicit `chevron.right` added by hand.
  They no longer slide.

### 5.3 `NavigationLink(value:)` → `libraryDestination(_:)` (8 links)

`libraryDestinations()` was a `.navigationDestination(for: LibraryRoute.self)`
modifier; it is now `libraryDestination(_ route:)` returning the page, handed
straight to `NavigationLink(destination:)`.

### 5.4 JIT setup flow → `step: Step?` (JITSetupView)

The flow never popped one step at a time — every `path.append` pushed onto a
stack whose only other entry was `choose`, and Back returned to `choose`. So a
single optional is the same flow with a different shape, and the toolbar gained
a Back item shown when `step != nil`.

### 5.5 `LabeledContent` → `HuskLabeledContent` (16 sites)

A label leading, value trailing, with SwiftUI's own three initialisers copied
across — including the parameter **order** (`value` before `label`) and the
`StringProtocol` / `LocalizedStringKey` overload pair. That pair is load-bearing:
`HuskLabeledContent("Size", value: someString)` does not resolve without it.

One cosmetic difference: SwiftUI's version compresses the label when the value
is long; this one gives the label `maxWidth: .infinity`. Rows are two lines
taller in a few places.

### 5.6 `.presentationDetents` / `.presentationDragIndicator` (4 sites)

No-ops below iOS 16. All four call sites asked for a sheet at its natural
height (`.medium`, `.height(300)`, `.height(340)`), so nothing changes
visually.

### 5.7 `.persistentSystemOverlays(.hidden)` — **removed** (3 sites)

This cannot be emulated. Hiding the home indicator persistently is iOS 16, and
on iOS 15 the system decides: it auto-hides during touch and while scrolling.
This is the one genuine cosmetic regression, in the three fullscreen game
surfaces (`ContentView`, `TLUnityView`, `TranslationLayer`).

### 5.8 `.toolbar(.hidden/.visible, for: .navigationBar)` → `.navigationBarHidden(...)` (3 sites)

`navigationBarHidden(_:)` is iOS 13 and works identically, deprecated on 16+.

### 5.9 `Animation.snappy` → `huskSnappy` (8 sites)

`spring(duration:bounce:)` has existed since iOS 13. Apple's `snappy` is a
spring at `duration: 0.5, bounce: 0.15`; the `_duration:` variant reuses the
caller's duration.

### 5.10 `.animation(_:value:)` → `huskAnimation(_:value:)` (9 sites)

The one-argument `.animation(_:)` underneath still works (soft-deprecated since
iOS 15) and is the only form that needs no restructuring of the state mutation
it watches. **Expect deprecation warnings from these nine lines.** They differ
in animating on any animatable change rather than only when `value` changes,
which is invisible at every site here: a log tailing, a toast fading, a page
sliding. If you want them silent, the fix is to wrap the corresponding mutation
in `withAnimation` and drop the modifier.

### 5.11 `scrollTo(_:anchor:)` → `scrollTo(_)` (3 sites)

The `anchor:` parameter is iOS 17. Without it the scroll is minimal-to-visible
rather than pinned to the bottom, so **log tailing may not stick to the last
line** on iOS 15. If that matters, scroll to the last row's id inside a
`withAnimation` on the same tick that appends.

### 5.12 `ShareLink` → `HuskShareButton` (1 site)

`ShareLink` is iOS 16. It is rebuilt on `ShareSheet`, the
`UIActivityViewController` wrapper the app already had (`ContentView.swift`),
and presented as a plain `Button` so the `.buttonStyle(.borderedProminent)`
chained onto it keeps working.

---

## 6. What the compiler found, and what that says about the audit

The first two CI failures were the runner and VirGL's PyYAML. The third was the
app target, and it is worth recording because of *how* it failed.

Every iOS 16 API in the first sweep was caught by a pattern search. The build
then reported a second batch that the search had walked straight past, because
none of them share a name with the first:

| API | Needs | Sites | Replacement |
|---|---|---|---|
| `View.bold()` | 16.0 | 1 | `.fontWeight(.bold)` |
| `Color.gradient` | 16.0 | 2 | the flat colour |
| `scrollIndicators(_:axes:)` | 16.0 | 4 | `UIScrollView.appearance()` in `HuskApp.init` |
| `scrollDismissesKeyboard(_:)` | 16.0 | 1 | dropped |
| `defersSystemGestures(on:)` | 16.0 | 2 | dropped |
| `Locale.current.region` | 16.0 | 1 | `(Locale.current as NSLocale).countryCode` |
| `setNeedsUpdateOfSupportedInterfaceOrientations()` | 16.0 | 1 | `huskRequestGeometryUpdate` |
| `requestGeometryUpdate(_:errorHandler:)` | 16.0 | 1 | `huskRequestGeometryUpdate` |

A list built from what you already know about is worth having, and worth
growing, but it only ever catches what somebody thought to add. The
`validate` job's pattern now includes all of the above, so this class of miss is
a one-minute failure rather than a two-hour one.

### The two that are not cosmetic

**Scroll indicators.** There is no SwiftUI API below iOS 16 for hiding them, so
the four call sites lost their modifiers and the indicators came back — on the
library shelves and the game grids, which are the first screens anyone sees.
Rather than accept that, `HuskApp.init()` sets
`UIScrollView.appearance().showsVerticalScrollIndicator = false`. SwiftUI's
`ScrollView` is a `UIScrollView` and `List` is a `UICollectionView`, so this
reaches exactly the views that asked to be indicator-free and leaves every
`List` alone.

**Orientation.** `HuskOrientation.set` could not simply be availability-guarded
and dropped: on iOS 16 it uses `requestGeometryUpdate`, and below 16 there is
no equivalent call at all. The delegate method still returns the new mask, but
iOS 15 only re-reads it when something asks the device to rotate, so the
fallback is the long-standing `UIDevice.setValue(_:forKey: "orientation")` KVO
nudge. **This is the least principled thing in the port** — it is a KVC write
to a private key, not a documented API. It is what everyone used through iOS
15, and it is the only mechanism available, but it is the first place to look if
rotation misbehaves on an old device. The retry loop is deliberately *not*
mirrored: it exists to handle the refusal `requestGeometryUpdate` can return,
and there is no refusal to handle on the KVO path.

Both iOS 16 calls moved into `huskRequestGeometryUpdate` in `Compat15.swift`,
which lets the grep-based check assert that no iOS 16 API exists outside that
one file at all — including inside `#available` branches, which grep cannot see.

### One type-checker timeout that was not an availability problem

`ItemPages.swift` failed with "the compiler is unable to type-check this
expression in reasonable time" on the game page's footer. That is the type
checker failing to fold `Text("a " + "b " + "\(x)" + " c")` inside an
if/else-if chain inside a `ViewBuilder` — a known slow pattern, unrelated to the
deployment target, and it was probably already near the limit before the port
added inference load in the same file. The three sentences are now computed
`String`s and the chain is just `Text(geodeFooter)`.

---

## 7. Behaviour you should verify on device

Nothing here has been compiled. Check in roughly this order, because a failure
early on makes later checks meaningless.

1. **It builds.** No iOS 16 availability errors remain — that is the whole
   point. Expect the nine deprecation warnings from §5.10.
2. **It installs and launches** on the lowest version you have. If dyld
   complains about a dylib's minos, §1's "change these together" applies.
3. **The GL stack comes up.** Run a GL game (Subway Surfers, Geometry Dash).
   If it dies at `qemu_egl_init_dpy_cocoa`, ANGLE is above your phone's
   version — go back to §1.
4. **JIT turns on.** StikDebug, TrollStore, or a jailbreak. Then start a game.
5. **Navigation, all four stacks:** Home → a game page → Back; Library → same;
   "Open in Files" from an app's page → lands in that folder → into a
   subdirectory → Back; the JIT walkthrough → a step → Back.
6. **Resume switch still works:** close Husk from a game's page, reopen, and it
   should land on that game's page (this is `resumeSwitch()` driving
   `$router.library`).
7. **Downloads** still list and progress in-app. The Lock Screen Live Activity
   will not appear — expected.
8. **The home indicator** shows during games — expected, see §5.7.
9. **Logs tail** — see §5.11 if they don't stick.

---

## 8. Files touched

**New**
- `src/app/Husk/Compat15.swift`
- `.github/workflows/build.yml`

**Deployment targets**
- `src/app/project.yml` — app 16.0 → 15.0 (comment rewritten)
- `src/app/Husk.xcodeproj/project.pbxproj` — two app configs 16.0 → 15.0, plus
  four entries registering `Compat15.swift`
- `scripts/build_ios.sh` — `SDKMINVER` 15.5 → 15.0
- `scripts/build_angle_ios.sh` — 15.5 → 15.0 (comment rewritten with the
  dyld-minos warning)
- `scripts/build_rppairing_ios.sh` — 15.5 → 15.0
- `tools/update-altsource.py` — fallback floor 16.0 → 15.0

**Swift** (`src/app/Husk/`, plus `Play/`)
- `AppDetailView`, `BootScreen`, `ContentView`, `CrashReport`, `DiscoverTab`,
  `DownloadsTab`, `FilesTab`, `ItemPages`, `JITSetupView`, `Launcher`,
  `OnboardingView`, `SettingsTab`, `TechnicalDetails`, `Theme`, `TLAppSettings`,
  `TLUnityView`, `TranslationLayer`, `Play/GoogleSignInSheet`,
  `Play/StoreView`

**Docs**
- `README.md` — the floor, and a pointer here
- `docs/00-architecture.md`, `docs/03-phase0-runbook.md` — `minos 16.0` → `15.0`

---

## 9. `altsource.json` was deliberately left alone

Its newest two entries carry `"minOSVersion": "16.0"`. That is correct: those
IPAs genuinely require 16.0, and rewriting it would tell a sideloader that
Husk 1.0.1 runs on iOS 15, which it does not.

`tools/update-altsource.py` reads the floor out of `project.yml`, so the next
release you publish picks up 15.0 automatically:

```sh
python3 tools/update-altsource.py
```

If you want to distribute an iOS 15 build, publish it as a new version rather
than editing the historical entries.

---

## 10. CI, and what it took to get a green build

CI, added alongside the port. Two jobs:

**`validate`** — ~1 min, runs on every PR, needs no dependencies. It checks the
four things in this port that are easy to break and expensive to discover late:

1. every `.swift` file on disk is in the target. `project.yml` globs the
   directories, so a file is only absent from the checked-in `.pbxproj` when
   xcodegen is missing — which is exactly the "cannot find 'X' in scope" for a
   type that is plainly right there.
2. `project.yml`, both app configurations in the `.pbxproj`, and the two
   extensions agree on their floors.
3. **QEMU, ANGLE and rppairing are all at or below 15.0.** This is the
   important one: an embedded dylib built above the app's floor is a silent
   launch-time failure on the oldest supported version, and it is invisible
   everywhere else. The three must move together (§1).
4. no iOS 16/17-only API has crept back in outside `Compat15.swift`.

**`build`** — hours. Runs on push to `main`, on tags, and on demand. **No PR
trigger on purpose**: a cold run fetches WebKit for ANGLE, then builds QEMU,
MoltenVK with SPIRV-Cross and SPIRV-Tools, and the Rust pairing library. Not
something to spend on every pull request.

It needs no signing identity. `package_ipa.sh:64` builds with
`CODE_SIGNING_ALLOWED=NO` and `package_ipa.sh:182` ad-hoc signs with Husk's
entitlements — TrollStore keeps those, a sideloader replaces them. That is why
this is a good fit for CI: the entitlements that make Husk unusable on the App
Store are exactly the ones CI can grant for free.

### The runner has to be `macos-26`

The first CI attempt failed in ANGLE with four `-Wthread-safety` errors, which
looked like an upstream ANGLE problem. It was not; the log carried the real
cause one line earlier:

```
{ platform:macOS, arch:arm64e, variant:Mac Catalyst, name:My Mac,
  error:Xcode doesn't support My Mac's macOS 15.7.9 (24G830). }
```

**Xcode 26 requires macOS Tahoe 26.2 or later.** The `macos-15` image is macOS
15.7.9. `setup-xcode` will happily point `DEVELOPER_DIR` at an Xcode the host
cannot support. `build_ios.sh` survives that, because it only shells out to
`clang`; `build_angle_ios.sh` drives `xcodebuild archive`, which has to resolve
destinations, and that is where it surfaces.

So: **`macos-26`**, whose image is macOS 26.6.1 with Xcode 26.0.1–26.6. The
preflight step now refuses a host below 26.2 by name, so this fails in ten
seconds with the reason rather than forty minutes later inside ANGLE.

### ANGLE vs. a modern Clang

The errors themselves are real and separate:

```
src/common/SimpleMutex.h:107:17: error: 'acquire_capability' attribute requires
  arguments whose type is annotated with 'capability' attribute; type here is
  'std::mutex' [-Werror,-Wthread-safety-attributes]
```

ANGLE annotates its methods `void lock() ANGLE_ACQUIRE_CAPABILITY(mutex)` over
a `std::mutex`. Clang's thread-safety analysis requires such an argument to
carry the `capability` attribute, and `std::mutex` does not. Older Clang
accepted it; the one in Xcode 26 (LLVM 21) rejects it, and WebKit's ANGLE
xcconfig has `-Werror` on. `MutexOnStd` is the non-futex path, so this is
exactly the code Apple platforms compile — there is no way around it short of
pinning an old tree.

`build_angle_ios.sh` now passes `-Wno-error=thread-safety-attributes` and
`-Wno-error=thread-safety-analysis`. `-Wno-error=` rather than `-Wno-`, so the
warnings still print and a genuine threading mistake stays visible.

### WebKit's `main` is not pinned

`build_angle_ios.sh` sparse-clones WebKit's `main`, so the ANGLE source moves
under you and upstream drift arrives as a Clang diagnostic in a file nobody in
this repo has heard of. That is part of why this failure looked unrelated to
anything. `WEBKIT_COMMIT` now pins it:

```sh
WEBKIT_COMMIT=<sha> ./scripts/build_angle_ios.sh
```

Empty by default, so behaviour is unchanged until you have a green build to
record a sha from. **Do that** — it is the difference between a build that
breaks on someone else's schedule and one that does not.

### virglrenderer needs PyYAML that nothing installs

With ANGLE green, the next CI failure is one line:

```
src/gallium/meson.build:72:16: ERROR: /opt/homebrew/bin/python3 is missing
modules: yaml
```

`virglrenderer`'s meson.build does `find_installation('yaml')`, which runs
`import yaml` **in whichever python meson itself runs on** — not whatever
`python3` is first on `PATH`. `build_gpu_ios.sh:21-22` hardcodes
`/opt/homebrew/bin/meson`, whose shebang points into
`/opt/homebrew/opt/python@3.14`, and that interpreter does not ship PyYAML.

`brew install pyyaml` is **not** the fix. Homebrew has disabled that formula
because it no longer meets their criteria, so the command fails with
"No available formula". Apple's own python3 has no `yaml` either.

This is not an iOS 15 problem and not an Xcode problem. It is a gap that only
shows on a machine where nothing else has already pulled PyYAML in — which is
every fresh CI runner, and not the machine this was developed on.

`build_gpu_ios.sh` now resolves the interpreter from meson's shebang (not
`PATH`), builds a throwaway venv, installs PyYAML into it, and exposes it via
`PYTHONPATH`. `PYTHONPATH` rather than a `--user` install on purpose: user
site-packages are per-version (`~/Library/Python/3.14/...` versus `3.13/...`),
so a `--user` install into whichever `python3` happens to be on `PATH` does not
help the interpreter meson is actually built against. `PYTHONPATH` is
version-agnostic. If `import yaml` already works, the script does nothing.

### Two more things the first run taught us

- **`env -i` wiped `DEVELOPER_DIR`.** `angle_build` runs xcodebuild in a clean
  environment on purpose, but `setup-xcode` selects an Xcode *by exporting
  `DEVELOPER_DIR`*, so ANGLE was building with the image's default while the
  rest of Husk used the selected one. Now passed through explicitly.
- **`ncpu=3`** was the `macos-15` Intel line. Expect the cold build to be the
  slow part; `ci_build.sh` skips ANGLE, virglrenderer and MoltenVK when their
  outputs exist, and the cache covers the sysroot, so every run after the first
  is dramatically faster.

Xcode is pinned to **26.6**, not `latest-stable`. Xcode 27 exists on the
`macos-26` image as a public preview, and it changes three things that would
bite this tree (§1): ld64 is gone, `ARCHS_STANDARD` quietly narrows, and the
`@State` macro changes what compiles. Bumping to it should be a deliberate
commit.

Caching is deliberately partial. `build/stamps` is cached with the sysroot so
libffi/glib/pixman/libslirp skip, and ANGLE, virglrenderer and MoltenVK skip by
checking for their own output — but **QEMU's meson build directory is not
cached**, and a step deletes the `qemu` stamp after restoring, because that
stamp would skip the QEMU build whose output we deliberately did not keep.

Outputs are uploaded as artifacts, plus `build/logs/` — the build scripts log
to files, so a failure is otherwise just `[FAIL] qemu (see
build/logs/qemu.log)`. Publishing a GitHub release attaches both packages.

---

## 11. Things worth knowing before this goes upstream

- The `huskAnimation` shim trades a deprecation warning for a slight semantic
  difference (§5.10). It is the one shim here that is a compromise rather than
  an equivalent.
- `HuskNavStack` is single-level by design. If Husk ever wants a two-deep
  Library stack, this needs to become a real path model and the iOS 16
  `NavigationStack` is the better answer.
- `HuskLabeledContent`'s layout is close to but not identical with
  SwiftUI's (§5.5).
- The Live Activity, `ScrollViewReader` anchoring, and the persistent home
  indicator are all places where iOS 16 is doing real work, not just
  decoration. They are where this port's rough edges live.
