# Peepo - watchOS Kernel R/W + Process Memory Dumping

> *Here's a little baby - One, two, three - Sits in her high chair - What does she see? PEEPO!*

Named after the children's book *Peepo!*. App artwork done by my niece H. McLaren.

**⚠️ This currently only supports the Apple Watch Series 4 (Watch4,1 / T8006) on watchOS 10.6.1. Any other watch model or watchOS version will not work and will panic/reboot the device - the exploit and all offsets are hardcoded to this exact build.**

Security-research project: a watchOS app (`Peepo Watch App`) that exploits a
kernel bug to gain arbitrary kernel read/write on an **Apple Watch Series 4
(Watch4,1 / T8006 / watchOS 10.6.1 / xnu-10063.144.1, arm64_32 userland)**, then
uses that primitive to enumerate live processes and **dump another process's
memory** to the app container - viewable on-watch or pullable to a host.

<!-- IMAGES: add screenshots here (home screen, WIN, process list, hex viewer). -->

---

## Table of contents
- [What it does](#what-it-does)
- [Setup (run it on your own watch)](#setup-run-it-on-your-own-watch)
- [On-watch UI](#on-watch-ui)
- [Pulling dumps off the watch](#pulling-dumps-off-the-watch)  ← **file extraction**
- [Dump file format & MachO extraction](#dump-file-format--macho-extraction)
- [How it works](#how-it-works)
- [Key offsets & constants](#key-offsets--constants)
- [Build & deploy](#build--deploy)
- [Source map](#source-map)

---

## What it does

```
DATASWORD ──► darksword_run()  ──►  "=== WIN ==="  (kernel R/W + base/slide)
                                         │
                                         ▼
                                  PROCESS DUMP screen
                                         │
                  ┌──────────────────────┼───────────────────────┐
                  ▼                       ▼                        ▼
          peepo_list_processes    tap a process →          VIEW HEX (on-watch
          (kernel proc walk)      peepo_dump_process()     xxd of the dump)
                                  → <name>_<pid>.bin
```

Confirmed working: full kernel R/W, ~276-process enumeration, and complete
memory dumps of live processes (e.g. `LegacyProfilesSu` 237 MB,
`MTLCompilerServi` 250 MB, `WhatsAppWatchApp` 256 MB+).

---

## Setup (run it on your own watch)

> **This only runs on an Apple Watch Series 4 (Watch4,1 / T8006) on watchOS
> 10.6.1.** On any other model or OS version the exploit's hardcoded offsets are
> wrong and it will **panic and reboot** the watch rather than fail cleanly.
> There is no downgrade path (watchOS is OTA-only, out of signing window), so if
> your S4 isn't already on 10.6.1, this is a read-only writeup for you.

### 0. Check compatibility first
On the watch: **Settings → General → About** - confirm **Model = Watch4,1** (or
"Series 4") and **watchOS Version = 10.6.1**. If either differs, stop here.

### 1. Prerequisites
- A **Mac with Xcode** (the watchOS SDK + `devicectl`).
- An **Apple Developer account** signed into Xcode. A **free "Personal Team"
  works** for running on your own watch (see *Signing & account notes*).
- An **iPhone paired to the watch**, both with **Developer Mode enabled**
  (Settings → Privacy & Security → Developer Mode), and the watch trusted by
  Xcode for development.

### 2. Make it yours
The committed project is intentionally **teamless** - set signing to your own
account. Open `Peepo.xcodeproj` in Xcode and, for **both** the app and the Watch
App target (Signing & Capabilities):
1. **Signing Team** - select your team; let Xcode manage signing automatically.
2. **Bundle identifier** - change `com.datalocaltmp.Peepo*` to your own if Xcode
   can't register the existing one under your team (e.g. `com.<you>.Peepo`).
3. **HealthKit (Workout Processing)** - leave this capability enabled. The app
   starts a HealthKit workout session purely to stay alive (avoid suspension)
   during the run, and `WKBackgroundModes = workout-processing` depends on it.

Then grab your watch's UDID for the command line:
```sh
xcrun devicectl list devices         # copy your watch's identifier
```
Use it wherever the docs say `DEV=…` (the repo's value is a placeholder).

### 3. Signing & account notes
- **A free account is enough.** A free "Personal Team" (just an Apple ID added in
  Xcode → Settings → Accounts) can sign and run this on your own watch, HealthKit
  included - this project was built/run on one.
- **If signing fails on the HealthKit entitlement** (rare, account-dependent): as
  a fallback you can strip `WorkoutManager`, the `com.apple.developer.healthkit`
  entitlement, and the `workout-processing` background mode - the app then runs
  without HealthKit but may get suspended mid-run.
- **Find your Team ID** (for the CLI `DEVELOPMENT_TEAM=…`): Xcode → Settings →
  Accounts → your team → 10-char ID, or run `security find-identity -v`.

### 4. Build, install, run
See [Build & deploy](#build--deploy) for exact commands. In short: build,
`devicectl … install`, launch, tap **DATASWORD**, wait for `=== WIN ===`.

### 5. Expect reboots
The R/W primitive is one-shot per launch, and **force-quitting or reinstalling
the app usually panics + reboots the watch** - that's normal here; it recovers.
Dumping an incompatible page also panics. None of this is persistent.

---

## On-watch UI

**Home screen**
- **DATASWORD** - runs the exploit; streams a live console; ends at `=== WIN ===`.
- **📄 list dumps** - lists every `*.bin` dump in the app container with sizes.
- **🗑 delete dumps** - deletes all `*.bin` files to free space (incl. `kc.bin`).

**After WIN (PROCESS DUMP screen)**
- Console of the exploit log, with a floating **PROCESS DUMP** button.
- Tapping it opens the **process list** (name-only rows). Tap a process to dump
  it → `<name>_<pid>.bin` in the app's `Documents/`.
- After a dump, **VIEW HEX ▸** appears - an on-watch xxd view
  (`offset · hex · ASCII`, first 64 KB) with an **✕** to close. No host needed.

---

## Pulling dumps off the watch

Dumps are written to the app's **Documents** container. Use Apple's `devicectl`
(ships with Xcode). Two constants:

```sh
DEV=<YOUR-WATCH-UDID>          # the Apple Watch (devicectl list devices)
BUNDLE=com.datalocaltmp.Peepo.watchkitapp         # the app's bundle id
```

### 1. List what's in the container

```sh
xcrun devicectl device info files \
  --device "$DEV" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --subdirectory Documents
```

Example output:

```
Name                       Size       Modification date
LegacyProfilesSu_325.bin   236.9 MB   ...
MTLCompilerServi_248.bin   250.5 MB   ...
kc.bin                     41.3 MB    ...   # kernelcache dump (if taken)
dumpdbg.log                10 KB      ...   # only present when DUMP_DEBUG=1
```

> ⚠️ **This listing times out while the app is actively running** (darksword
> holds kernel R/W and starves the file service over the tunnel). Run it when the
> app is **not** running - e.g. right after a reboot, or before relaunching.
> *Single-file copies (below) work even while the app runs.*

### 2. Pull a file

```sh
xcrun devicectl device copy from \
  --device "$DEV" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source Documents/LegacyProfilesSu_325.bin \
  --destination ./LegacyProfilesSu_325.bin
```

### 3. Pull the whole Documents directory

```sh
mkdir -p ./peepo_docs
xcrun devicectl device copy from --device "$DEV" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents --destination ./peepo_docs
```

(Same caveat: do it while the app isn't running, or it may time out.)

### File naming

Dump files are named **`<last-16-chars-of-process-name>_<pid>.bin`** (non-alnum
chars → `_`). The process *name* (not the truncated display) drives the
filename, and **pids change every boot**, so always list first rather than
guessing. Other files you may see:

| File | What | When |
|---|---|---|
| `<name>_<pid>.bin` | a process memory dump | after PROCESS DUMP |
| `kc.bin` | live kernelcache dump | if the (currently hidden) DUMP KERNEL path is used |
| `dumpdbg.log` | durable, panic-surviving step/PT-walk trace | only when `DUMP_DEBUG=1` |

---

## Dump file format & MachO extraction

A `.bin` dump is a flat sequence of fixed records, one per **mapped 16 KB page**
(unmapped/un-resident pages are skipped):

```
record = [ u64 little-endian virtual address ][ 16384 bytes of page data ]
record size = 8 + 0x4000 = 16392 bytes
```

Only **resident** pages are captured (demand-paged code that was never executed
translates to PA 0 and is skipped), and only pages inside the readable physmap
window are read. The dump is capped at **1 GB** per process.

Because VAs are preserved, you can recover MachO images (the main executable and
resident dyld-shared-cache slices) by scanning for the mach header magic. Quick
host-side parser/extractor:

```python
import struct, sys

REC = 8 + 0x4000
data = open(sys.argv[1], "rb").read()
n = len(data) // REC
print(f"{len(data)} bytes, {n} pages")

for i in range(n):
    off = i * REC
    va  = struct.unpack_from("<Q", data, off)[0]
    page = data[off+8 : off+8+0x4000]
    if page[:4] in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):  # MH_MAGIC_64 / FAT
        print(f"  MachO @ va {va:#x}")
        # carve: open(f"img_{va:x}.bin","wb").write(<contiguous pages from va>)
```

(`cf fa ed fe` = little-endian `MH_MAGIC_64`.) On-watch, the same data is
viewable directly via **VIEW HEX** without pulling anything.

---

## How it works

### 1. darksword - kernel R/W

A physical-use-after-free (PUAF) attack that races `pwritev()`'s copy against a
`mach_vm_map(… OVERWRITE …)` page remap.

- `pcObject` is allocated from **`PurpleGfxMem`** (GPU device memory) via
  `IOSurfaceCreate({IOSurfaceMemoryRegion: "PurpleGfxMem"})`. These pages are
  **device memory, not managed DRAM**, so the kernel's physical-copy path does
  **not** trip the `pmap_map_cpu_windows_copy_internal: attempted to map a
  managed page` panic (guarded by `pa_valid()`). This was the key watch-port fix.
- `free_thread` remaps `pcAddress` with one atomic
  `mach_vm_map(VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, …)`.
- "Race landed" = `pwritev` returns `-1` (EFAULT) **plus** a `randomMarker`
  sentinel mismatch: search pages are pre-filled with `randomMarker`; a page
  reclaimed by the kernel as a socket inpcb reads back kernel data instead.
- `pe_v1` sprays ~22k ICMPv6 sockets to reclaim freed pages, finds an inpcb of
  ours, and corrupts its `in6p_icmp6filt` pointer → a 0x20-byte arbitrary kernel
  R/W via `get/setsockopt(ICMP6_FILTER)` (`early_kread64`/`early_kwrite`).

**Base + slide:** `controlSocketPcb → socket → so_proto → pr_input` leaks a
PAC-signed kernel text pointer. The watch's `__xpaci` is a no-op, so strip
explicitly - **the PAC sits in the top 32 bits**, real text is the low 32:
`textPtr = (raw & 0xffffffff) | (protoPtr & 0xffffffff00000000)`. Scan down 16 KB
pages for the `MH_FILESET` mach header → `kernel_base`;
`kernel_slide = kernel_base - 0xfffffff007004000`.

STEP 6 bumps both sockets' `so_count` ("leak forever") so the R/W stays valid for
the inspection code after the run.

### 2. Process enumeration

Userland enumeration is sandbox-blocked, so we walk the kernel proc list.

The anchor is obtained offset-free via **`leak_current_proc()`**: spray ~10-20k
`kqueue()` fds (each `kqfile` stores `kq_p = current_proc`), read the reclaimed
pages back through the physical-read race **while `free_thread` is alive**, and
take the kernel pointer that *repeats* across the page. From `current_proc`, walk
`proc.p_list` both directions; the proc-name field offset is **self-calibrated**
at runtime by searching the struct for our own executable name.

### 3. Process memory dump

`peepo_dump_process(proc, name)` walks
`proc → task → vm_map → pmap`, then for each `vm_map` entry translates every
16 KB page and writes it out.

- `task = proc + 0x740`; `map = strip(*(task+0x28))`; `pmap = strip(*(map+0x40))`
  (`vm_map->pmap` is PAC-signed, data key A, discriminator `0x250c`).
- **3-level 16 KB page-table walk** (39-bit user VA): L1 (8-entry root) → L2
  (2048) → L3 (2048): `l1i=(va>>36)&7`, `l2i=(va>>25)&0x7ff`, `l3i=(va>>14)&0x7ff`.
- **Physmap slide is global**: derived from *our own* validated process's pmap
  (`physmap_off = tte - ttep`), not the target's (a target's `ttep` can be
  inconsistent). `physmap_kva = pa + physmap_off`.
- **PAC strip** forces bit 39: `(v & 0x7fffffffff) | 0xffffff8000000000` - the
  central bug that, when missing, mangled every signed pointer.

**The carveout gate.** `early_kread` is fault-unsafe - reading a physical page
not covered by the physmap **panics** (reboots the watch). Live traces showed the
low DRAM carveout (iBoot/SEP/TZ, `0x8_00000000 .. gPhysBase`) is *not* in the
physmap: pages at `0x801…`/`0x802…` panic, while `gPhysBase ≤ 0x8_06e68cc0` reads
fine. So the dumper gates reads to a safe window
**`[0x8_07000000, 0x8_40000000)`** and skips anything outside it. (TODO: read the
kernel's exact `gPhysBase`/`gPhysSize` to close the small gap below the gate.)

Panicking runs are diagnosable only with `DUMP_DEBUG=1`, which mirrors every step
to `dumpdbg.log` using `F_FULLFSYNC` (plain `fsync` does **not** survive a kernel
panic on this device - the FS cache is effectively volatile across a panic).

---

## Key offsets & constants (watchOS 10.6.1 / T8006)

| Thing | Value | Notes |
|---|---|---|
| unslid kernel base | `0xfffffff007004000` | for `kernel_slide` |
| `proc.p_list.le_next` / `le_prev` | `+0x0` / `+0x8` | proc list walk |
| `proc.p_pid` | `+0x60` | |
| `proc → task` gap (`proc_struct_size`) | `0x740` | validated on this build (kfd's `0x778` was wrong here) |
| `task->map` | `+0x28` | |
| `vm_map->pmap` | `+0x40` | PAC-signed (data key A, disc `0x250c`) |
| `pmap->tte` / `pmap->ttep` | `+0x0` / `+0x8` | virtual / physical root TT |
| proc name field | self-calibrated (`gNameOff`) | searches struct for exe name |
| PAGE_SIZE | `0x4000` (16 KB) | `DS_PAGE_SHIFT = 14` |
| readable physmap window | `[0x807000000, 0x840000000)` | DRAM minus low carveout |
| dump cap | 1 GB / process | |

All offsets were **validated against the live kernel** (the on-device kernelcache
is the source of truth for this build, not a generic reference). A kernelcache
dump (`kc.bin`) can be taken for cross-checking with `blacktop/ipsw`.

---

## Build & deploy

watchOS app, target/scheme `Peepo Watch App`, builds for `arm64_32`.

The committed project has **no signing team** (scrubbed). Either open it in Xcode
once and pick your team under *Signing & Capabilities*, or pass your Team ID on
the command line (`xcrun devicectl list devices` gives your watch UDID; your Team
ID is in Xcode → Settings → Accounts, or `security find-identity -v`).

```sh
DEV=<YOUR-WATCH-UDID>
TEAM=<YOUR-TEAM-ID>
BUNDLE=com.datalocaltmp.Peepo.watchkitapp
APP="$HOME/Library/Developer/Xcode/DerivedData/Peepo-*/Build/Products/Debug-watchos/Peepo Watch App.app"

xcodebuild -scheme "Peepo Watch App" -destination "generic/platform=watchOS" \
  DEVELOPMENT_TEAM="$TEAM" build
xcrun devicectl device install app --device "$DEV" $APP
xcrun devicectl device process launch --device "$DEV" "$BUNDLE"
```

Conventions / gotchas:
- **Rotate `buildTag`** (4-char hex in `ContentView.swift`) before every redeploy
  so the running build is visually confirmable on-watch.
- **Force-quit Peepo before reinstalling.** While the app runs it holds kernel
  R/W; `install` then times out (`NSPOSIXErrorDomain 60` / `IXRemoteErrorDomain
  6`). Force-quitting (or any reinstall) usually **panics + reboots** the watch -
  that's expected; it recovers.
- The R/W primitive is one-shot per app launch (no persistence).
- `DUMP_DEBUG` (in `darksword.m`) defaults to `0` (lean dumps). Set to `1` to get
  the durable `dumpdbg.log` panic trace back while debugging.

### Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Signing for "…" requires a development team` | No team set. Pick yours in Xcode → Signing & Capabilities, or pass `DEVELOPMENT_TEAM=<id>` to `xcodebuild`. |
| Build fails on the **HealthKit** entitlement | Rare/account-dependent - see the fallback (strip HealthKit) in *Signing & account notes*. |
| `install` times out (`NSPOSIXErrorDomain 60` / `IXRemoteErrorDomain 6`) | The app is running and holding kernel R/W. **Force-quit Peepo** on the watch, then reinstall. |
| Watch **panics/reboots** on launch or on a dump | Almost always the wrong device/OS (must be Watch4,1 @ 10.6.1), or a dump hit memory outside the readable physmap. Expected; it recovers. |
| `devicectl device info files` (listing dumps) times out | The app is running. List **after a reboot / before relaunching**; single-file `copy from` still works while running. |
| App quietly dies mid-run | Workout session didn't keep it alive - confirm the HealthKit/Workout capability is enabled and granted. |

---

## Source map

| File | Role |
|---|---|
| `Peepo Watch App/darksword.m` | exploit + kernel R/W + proc walk + process dump + PT walk |
| `Peepo Watch App/darksword.h` | public API (`darksword_run`, `peepo_list_processes`, `peepo_dump_process`, `peepo_last_dump_path`, …) |
| `Peepo Watch App/ContentView.swift` | UI: home, console, PROCESS DUMP, process list, hex viewer, list/delete dumps, build tag |
| `Peepo Watch App/ConsoleView.swift` / `ConsoleBridge.swift` / `ConsoleBuffer.swift` | on-watch console + `console_log` bridge |
| `Peepo Watch App/kern_panic.c` / `.h` | console-logging plumbing (`printf` → console) |
| `Peepo Watch App/WorkoutManager.swift` | keeps the app alive (HealthKit workout session) during the run |

---

## Credits & shout-outs

- **opa334** and **htimesnine** - for the *darksword* kernel n-day this project
  is built on. None of this exists without their work.
- **tihmstar** - for [jelbrekTime](https://github.com/tihmstar/jelbrekTime), the
  Apple Watch Series 3 jailbreak, and a great reference for watchOS exploitation.
