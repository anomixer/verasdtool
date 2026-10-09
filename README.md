# VeraSDTool — VERA SD Toolkit

### VeraSDEdit — Hex sector editor

![VeraSDEdit](verasdedit.png)

Browse and edit any 512-byte sector on a VERA SD image, with hexadecimal and
ASCII views.

### VeraSDFormat — FAT32 formatter

![VeraSDFormat](verasdformat.png)

Create and verify a FAT32 partition on a VERA SD image for use by Apple II
software such as CMDR-DOS and A2VERA.

### VeraSD-IFS-ProDOS — ProDOS SD driver

![VeraSD-IFS-ProDOS running under Bitsy Bye](VeraSD-IFS-ProDOS.png)

Mount a raw ProDOS SD image as a resident ProDOS block device, accessible to
ProDOS programs after `BYE` and limited to the ProDOS 32 MiB volume size.

### VeraSD-IFS-FAT32 — WIP / Preliminary

![VeraSD-IFS-FAT32 running on Apple II](VeraSD-IFS-FAT32.png)

An experimental ProDOS-launched FAT32 test client. It currently catalogs,
reads, and performs a test write; it is not yet a real IFS driver.

<!-- English first, Traditional Chinese below -->

---

## Contents

- 🇬🇧 **English**
  - [Directory contents](#directory-contents)
  - [Dependencies](#dependencies)
  - [VeraSDEdit](#verasdedit)
  - [verasdformat (FAT32 Formatter)](#verasdformat)
  - [VeraSD-IFS-ProDOS](#verasd-ifs-prodos)
  - [VeraSD-IFS-FAT32 (WIP)](#verasd-ifs-fat32)
  - [Technical background](#technical-background)
  - [Note on the vendored assembler](#vendored-assembler)
- 🇹🇼 **繁體中文**
  - [目錄內容](#cn-directory-contents)
  - [依賴](#cn-dependencies)
  - [VeraSDEdit](#cn-verasdedit)
  - [verasdformat（FAT32 格式化工具）](#cn-verasdformat)
  - [VeraSD-IFS-ProDOS](#cn-prodos-driver)
  - [VeraSD-IFS-FAT32](#cn-fat32-client)
  - [技術背景](#cn-technical-background)
  - [組譯器版本備註](#cn-vendored-assembler)

---

<a id="directory-contents"></a>
### Directory contents (git-tracked)

| Path | Description |
|------|-------------|
| src/verasdedit/ | VeraSDEdit source, startup BASIC, and build module |
| src/verasdformat/ | VeraSDFormat source, startup BASIC, and build module |
| src/verasd-prodos/ | ProDOS SD block driver, installer, and tests |
| src/verasd-fat32/ | Preliminary FAT32 test client, source modules, and tests |
| assets/ProDOS_2_4_3.po | Shared ProDOS 2.4.3 base disk image |
| src/prodos-volume-name.mjs | Shared ProDOS boot-volume name writer used by all image builders |
| src/prodos-timestamp.mjs | Shared file-date writer used by all image builders |
| asm6502.mjs / applebasic.mjs | Shared vendored build dependencies |
| build.bat | Root builder for the four tools |
| VeraSD-IFS-ProDOS.po / `.img.zip` | ProDOS boot disk and packaged SD volume |
| VeraSD-IFS-FAT32.po / `.img.zip` | FAT32 boot disk and packaged test volume |
| verasdedit.png / verasdformat.png | VeraSDEdit / VeraSDFormat screenshots |
| VeraSD-IFS-ProDOS.png / VeraSD-IFS-FAT32.png | ProDOS / FAT32 screenshots |

Bootable `.po` disk images and the two `.img.zip` archives are tracked. Raw
`.img` files remain ignored so the tested SD images can be shared without
committing large unpacked images.
Each `.po` build stamps its generated files' ProDOS creation and modification
dates and times from the build machine's local clock; base files such as
`BASIC.SYSTEM` and `PRODOS` keep their original timestamps.

<a id="english"></a>
## 🇬🇧 English

**VeraSDTool** is a collection of four Apple II tools for inspecting, preparing,
and accessing SD card images through a Commander X16 VERA SD Card or an Apple II
VERA SD Card: VeraSDEdit, VeraSDFormat, VeraSD-IFS-ProDOS, and the preliminary
VeraSD-IFS-FAT32 client.

**VeraSDEdit** is the toolkit's PC-Tools-style **6502 hex sector editor**. It
runs on the Apple II (including AppleWin), reads any LBA sector over the VERA
SD/MMC SPI interface, and displays each 512-byte sector as hex and ASCII. The
VERA base is auto-detected in slot 2 (`$C200`) or slot 4 (`$C400`); its SPI
data/status registers are `base+$1E`/`base+$1F` (`$C21E`/`$C21F` in slot 2).
The display shows offsets 0–511 in two pages of 256 bytes each.

<a id="dependencies"></a>
### Dependencies (self-contained — buildable after `git clone`)

All build dependencies live **inside the repo**. The only external requirement
is **Node.js**:

| Dependency | Purpose | Location |
|-----------|---------|----------|
| **Node.js** | Run `src/verasdedit/verasdedit.mjs` (ESM `import` syntax) | https://nodejs.org (Node 12+, `.mjs` support) |
| **`asm6502.mjs`** | 6502 assembler (exports `assemble6502`) | `src/asm6502.mjs` (vendored) |
| **`applebasic.mjs`** | Applesoft BASIC compiler (exports `compileApplesoftBasic`) | `src/applebasic.mjs` (vendored) |
| **`ProDOS_2_4_3.po`** | ProDOS 2.4.3 base disk image (build base; the script frees existing user files, keeping only PRODOS+SYSTEM) | repo root `assets/ProDOS_2_4_3.po` (already in repo) |

`src/verasdedit/verasdedit.mjs` uses **relative paths**, so it is cross-platform:

```js
import { assemble6502 } from "../asm6502.mjs"
import { compileApplesoftBasic } from "../applebasic.mjs"
const basePoPath = path.join(__dirname, "..", "..", "assets", "ProDOS_2_4_3.po")
```

> To use your own toolchain / base disk, edit those lines.

<a id="verasdedit"></a>
<a id="build"></a>
### VeraSDEdit — Hex sector editor

VeraSDEdit is an Apple II sector browser and editor for VERA-attached SD cards.
It reads any 512-byte LBA, displays hex and ASCII, and can write edited sectors
back to the card. It is useful for inspecting partition tables, FAT32 metadata,
and raw disk contents.

- **Browse:** move through sectors with `N`/`P`, reload with `R`, or enter an LBA with `L`.
- **Edit:** change bytes in hex or ASCII, then write the complete sector with `W`.
- **Capacity:** reads the SD card's CSD and displays its total sector count; LBA entry is 32-bit.
- **Boot volume name:** `VERASDEDIT`.

#### Build

```powershell
# Windows:
build.bat verasdedit

# or manually (any platform):
node src/verasdedit/verasdedit.mjs
```

Successful output:

```
Created ...\verasdedit.po (143360 bytes)
  VERASDEDIT.BIN: 4491 bytes (load $2000)
  STARTUP: 783 bytes
```

Copy `verasdedit.po` to `Release\` and boot it in AppleWin.

<a id="usage"></a>
#### Usage (AppleWin)

1. Start AppleWin, install the **VERA card in Slot 2 or Slot 4**, and mount an
   **SD card image** via the VERA card's "Configure..." dialog.
2. **If a hard disk is configured in Slot 7**, it boots first and the editor
   won't appear. Clear `Slot 7 → Last Harddisk Image 1` in the registry
   (`HKCU\...\Configuration\Slot 7`) before booting.
3. Boot `verasdedit.po` as the disk (`-d1` on the command line, or mount via
   GUI then reset).
4. `src/verasdedit/startup.bas` prints the banner, **detects the VERA card (slot 2 then slot
   4)** via PEEK/POKE, then `BRUN`s the editor (if neither slot has one it prints
   `No VERA Card Detected on Slot 2 or 4!` and ends). The editor re-detects the
   slot itself and reads LBA `800` (FAT32 boot sector):

```
VeraSDEdit (Hex Sector Editor)  v1.01 by anomixer 2026
LBA=00000800  (TOTAL=000nnnnnn) PAGE 1
Offset 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F   ASCII Dump
------ -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --   ----------------
 0000  EB 58 90 43 4D 44 52 2D 44 4F 53 00 02 02 20 00   .X.CMDR-DOS... .
```

> `LBA=xxxxxxxx` is the current sector as 8 hex digits (32-bit — enough for the
> FAT32 2 TB ceiling). `(TOTAL=000nnnnnn)` is the SD image's **total sector count**
> (512-byte sectors), read from the card's CSD register via **CMD9 (SEND_CSD)** on
> startup — handy for knowing the FAT32 capacity boundary.

<a id="keys"></a>
#### Keys

| Key | Action |
|-----|--------|
| `SPACE` | Toggle page (PAGE 1 ↔ PAGE 2) |
| `N` | Next LBA (LBA+1; from the last sector it wraps to 0) |
| `P` | Previous LBA (LBA−1; from 0 it wraps to the last sector, Total−1) |
| `R` | Reload current LBA |
| `L` | **Select LBA** — type 1–8 hex digits + `RETURN` to load, `DEL` backspace, `ESC` cancel back to the editor |
| `E` | Enter **editor** mode (see below) |
| `Q` | Return to ProDOS (BYE/RTS): restores ZP + IRQ vector, switches to 40-col, **HOME-clears the screen**, then returns |

> Command keys accept **both cases** (`N`/`n`, `P`/`p`, `R`/`r`, `L`/`l`,
> `E`/`e`, `Q`/`q`, and in the editor `I`/`i`, `J`/`j`, `K`/`k`, `M`/`m`).
> Only editor *data* input (hex nibbles / printable ASCII) stays case-sensitive,
> so lowercase ASCII can still be typed as data.
>
> The editor keys are `SPACE`/`N`/`P`/`R`/`L`/`E`/`Q`. Hex digits do *nothing*
> in the editor — LBA entry only happens inside the `[L]` select mode (where
> `0-F` is typed as an LBA digit, not a nibble edit). Nibble edits only happen
> in the editor.

##### Editor mode

Press `E` to edit the current page. The cursor moves over the hex and ASCII
columns; **changed bytes are shown inverse** (both nibbles) until written. The
**cursor cell always flashes** — in the hex field the nibble under the cursor
flashes, and in the ASCII field the cursor char flashes, even on a changed
(inverse) byte, so you can always see where the cursor is. After `W` the byte
renders normal.

The editor has two states:
- **Navigate** (default, on entry): `I`/`M`/`J`/`K` move the cursor, `TAB`
  switches the hex ↔ ASCII field, `E` enters the edit state.
- **Edit** (press `E`): keys now *modify* the byte under the cursor — `0-F`
  sets a hex nibble, a printable char sets the ASCII byte (including `IJKL`
  and `W`, which are typed as data here, not cursor movement / not a write;
  `E` is also typed as a nibble/char here). `W` writes **only** in navigate
  state. Press `CR` (Enter) to go back to navigate, or `ESC` to leave the
  editor.

| Key | Action |
|-----|--------|
| `I` / `M` | Move cursor up / down one row (byte ±16) — navigate state only |
| `J` / `K` | Move cursor left / right (hex column moves per nibble) — navigate state only |
| `TAB` | Toggle between the hex field and the ASCII field |
| `E` | Navigate state: enter edit state |
| `CR` | Edit state: stop editing, **accept** the edit, return to navigate |
| `ESC` | Edit state: **discard** the edit (re-read sector from SD), return to navigate; navigate state: leave editor to editor |
| `0–9 A–F` | Edit state, hex field: set the nibble under the cursor, advance (incl. `E`) |
| (printable) | Edit state, ASCII field: set the byte under the cursor, advance (incl. `IJKL`) |
| `W` | Write the whole sector back to the SD card (CMD24) — both `W`/`w`, shown in the navigate banner (`[E]=edit [W]=write`) |

> In the hex field the cursor flashes **only the nibble under it** (left/right),
> even on a changed byte — the flash marks the nibble being edited. A byte
> renders **inverse** only if its value actually differs from the original
> (the last-loaded sector); editing a byte back to its original value (e.g.
> `00` → `00`, or reverting `05` → `00`) clears the inverse again, so typing
> through untouched bytes never shows inverse. The cursor cell always flashes
> (hex nibble / ASCII char) even on a changed byte, so you can see where the
> cursor is; the other nibble of a changed cursor byte stays inverse, and changed
> non-cursor bytes render fully inverse.
> Typing a hex digit edits that nibble and advances high→low→next byte, so **both
> nibbles** of a byte are editable; the cursor starts at the high (left) nibble
> on entering edit mode.
>
> `Q` returns to ProDOS via the `BYE`/RTS convention (the BRUN return address),
> *not* the Applesoft warm-start `$3D2`. It restores the ZP/IRQ vector, switches
> to 40-col, and **HOME-clears the screen** so the `]` prompt is on a clean line.

* `W` writes **all 512 bytes** of the current sector (both pages) back via
  CMD24 (WRITE_SINGLE_BLOCK) — the guest sends the token `0xFE` + 512 data
  bytes + 2 CRC bytes.
* After `W` the dirty indicator clears; `ESC` without `W` discards changes.

<a id="verasdformat"></a>
### verasdformat — FAT32 Formatter for VERA SD/MMC

A companion utility in this repository that formats a VERA-attached SD/MMC card image to **FAT32** for use on the Apple II with CMDR-DOS and A2VERA.

- **MBR + Partition**: Writes an MBR partition table (partition type `$0C`, FAT32 LBA) starting at LBA 2048.
- **FAT32 Volume**: Formats VBR, FSInfo, backup VBR/FSInfo, FAT #1, FAT #2, and initializes root cluster 2.
- **Root cleanup**: Clears every sector in the initial root directory cluster, preserving only the volume label.
- **Fast repeated writes**: FAT free-space and root-padding stages use CMD25 multi-block writes through the VERA SD emulator.
- **Menu Options**:
  - `[1] Catalog SD`: Lists root directory 8.3 filenames and file sizes.
  - `[2] Format SD`: Quick format. Requires typing `FORMAT` + `RETURN` to confirm; `ESC` aborts.
  - `[3] Verify SD`: Reads back all metadata sectors via CMD17 and validates byte-for-byte against generated templates.
  - `[0] Exit`: Clean exit back to ProDOS.

Format and verify keep their progress and per-sector results on screen; the final `PASS` or `FAIL - N errors` is appended below them. The format screen keeps the `VeraSDFormat` title, separates the progress heading from stage rows, and waits for a key after the final result.
- **Boot volume name:** `VERASDFORMAT`.
- **Build**:
  ```powershell
  build.bat verasdformat    # Windows one-click
  node src/verasdformat/verasdformat.mjs     # any platform
  ```
- **Running in AppleWin**:
  ```powershell
  AppleWin.exe -s2 vera -d1 C:\dev\verasdedit\verasdformat.po -power-on
  ```

<a id="verasd-ifs-prodos"></a>
### VeraSD-IFS-ProDOS — ProDOS 8 SD block driver

VeraSD-IFS-ProDOS makes a raw ProDOS SD image available as a normal ProDOS
block device. This is the version to use when ProDOS applications need to
catalog, read, or write files through the standard ProDOS volume interface.
The resident driver remains installed after `BYE`; Copy II Plus 8.4 can use the
volume after returning from the installer. The Bitsy Bye catalog screen is
shown above.

- **Volume limit:** exposes up to 65,535 512-byte blocks (about 32 MiB). A raw
  ProDOS image header determines the accessible volume size; extra SD capacity
  cannot be addressed. FAT32 and partition tables are not supported.
- **Hardware:** detects VERA in slot 2 or 4 and supports SDHC block addressing
  and SDSC byte addressing.
- **File type:** `VERASD.SYSTEM` is type `$FF` (SYS), so ProDOS launchers such as Bitsy Bye can execute it.
  After displaying the install result, it loads the next root-directory `.SYSTEM` file (for example `CLOCK.SYSTEM`, then `DESKTOP.SYSTEM`) whether installation succeeded or failed. Its temporary handoff helper runs at `$1000` and is not part of the resident driver. `QUIT.SYSTEM` is the final catalog entry, returning to Bitsy Bye after startup; MLI QUIT (`$65`) is used only when no next SYS can be loaded. The chain to A2Desktop was verified in AppleWin with the SD image mounted in slot 2 and with VERA present but no SD image.
- **BASIC entry:** `VERASD.BIN` is also included as type `$06` (BIN), load address `$2000`. From Applesoft BASIC, run `BRUN VERASD.BIN`; it installs the driver and returns to BASIC, where SD files can be accessed through ProDOS commands.
- **Startup menu:** `STARTUP` is a BAS file auto-run by `BASIC.SYSTEM`. It detects VERA in slot 2 or 4, initializes the SD card by running `VERASD.BIN`, then offers `CATALOG SD Card` or `Run A2Desktop` for the detected slot. The driver is already loaded before the menu appears. The catalog lists `BASIC.SYSTEM` first and `STARTUP` second, with `QUIT.SYSTEM` last.
- **Boot disk volume name:** `VERASDIFSPRODOS`.
- **Build**:
  ```powershell
  build.bat prodos                 # Windows
  npm run build:prodos             # any platform with Node.js
  node src/verasd-prodos/verasd.mjs
  ```
- **Running in AppleWin**:
  ```powershell
  if (-not (Test-Path VeraSD-IFS-ProDOS.img)) { Expand-Archive VeraSD-IFS-ProDOS.img.zip -DestinationPath . }
  # Select VeraSD-IFS-ProDOS.img in the VERA card's Configure dialog.
  AppleWin.exe -s2 vera -d1 C:\dev\verasdtool\VeraSD-IFS-ProDOS.po -power-on
  ```
  `BASIC.SYSTEM` auto-runs STARTUP, which detects the VERA slot, installs the
  driver, checks SD availability, and offers CATALOG or A2Desktop. To launch
  the SYS installer manually from the ProDOS prompt, run `-VERASD.SYSTEM`.
  The build preserves the SD image; `--reset-sd` recreates it as an empty
  ProDOS volume.
- **Tests:** `npm run test:prodos` runs the assembled-driver and installer
  regression suites (Python and `py65` required).
- The SYS build uses `src/verasd-prodos/verasd_sys.asm`; `verasd.asm` is the
  legacy BRUN entry point and ends with `RTS`, which is invalid when ProDOS
  launches it as a SYS file.
- After displaying its result, `VERASD.SYSTEM` waits about one second before
  handing off to the next `.SYSTEM`, regardless of installation result. MLI
  QUIT is the fallback when no next SYS can be loaded.
- `QUIT.SYSTEM` from the base ProDOS disk is retained and ordered last in the
  boot volume catalog so the SYS handoff chain returns to Bitsy Bye.

Source and detailed implementation notes: `src/verasd-prodos/README.md`.

<a id="verasd-ifs-fat32"></a>
### VeraSD-IFS-FAT32 (WIP / Preliminary) - standalone FAT32 test client

**Status: WIP / Preliminary. This is not a finished IFS driver.** VeraSD-IFS-FAT32
is a separate ProDOS-launched test application for FAT32 SD images larger than
the ProDOS 32 MiB block-volume limit. Its current functions are limited to
catalog, read, and a test write to an existing preallocated file. It is not a
ProDOS disk device: BASIC `CATALOG`, Copy II Plus, and other ProDOS file calls
cannot address the FAT32 volume directly.

- **Current commands:** `C` catalogs root 8.3 names; `R` reads a named file and
  displays its size, first bytes, and checksum; `W` followed by `Y` runs the
  test write against preallocated 1,024-byte `TESTNOW.BIN`; `Q` returns to BASIC.
- **Volume support:** raw FAT32 or the first FAT32 MBR partition, 512-byte
  sectors, with 32-bit sector addresses. The 128 MiB fixture exercises
  fragmented files located beyond 32 MiB.
- **Boot disk volume name:** `VERASDIFSFAT32`.
- **Build**:
  ```powershell
  build.bat fat32                   # Windows
  npm run build:fat32               # any platform with Node.js
  node src/verasd-fat32/fat32-build.mjs
  ```
- **Running in AppleWin**:
  ```powershell
  if (-not (Test-Path VeraSD-IFS-FAT32.img)) { Expand-Archive VeraSD-IFS-FAT32.img.zip -DestinationPath . }
  # Select VeraSD-IFS-FAT32.img in the VERA card's Configure dialog.
  AppleWin.exe -s2 vera -d1 C:\dev\verasdtool\VeraSD-IFS-FAT32.po -power-on
  ```
  `STARTUP` briefly describes `FAT32.SYSTEM` when BASIC.SYSTEM starts. At the
  ProDOS prompt, run `BRUN FAT32.SYSTEM`. For a fresh disposable test
  image instead, run `python src/verasd-fat32/fat32-fixture.py`; it refuses to
  overwrite an existing image.
- **Tests:** `npm run test:fat32` runs 25 assembled-client cases (Python and
  `py65` required). The optional `python src/verasd-fat32/check_fat32_image.py`
  independently checks fixture files and mirrored FAT copies (requires
  `pyfatfs`).
- **Not implemented yet:** file creation, allocation, append/resize, deletion,
  subdirectories, long names, and a ProDOS file interface.

Source and tested behavior: `src/verasd-fat32/FAT32-README.md`.

<a id="technical-background"></a>
### Technical background

- **80-column display**: Apple IIe 80-column interleaves **AUX/MAIN** — each
  40-address text-page cell renders AUX(left)+MAIN(right)
  (`NTSC.cpp updateScreenText80`: `bits=(main<<7)|aux`). So even columns→AUX,
  odd columns→MAIN, cell offset = column/2.
- **Display setup**: after switching to 80-column text (`$C00D`), the guest must
  also set **80STORE OFF (`$C000`)** and **PAGE2 OFF (`$C054`)** so the display
  reads PAGE1 (`$0400`, where the guest writes). Forgetting these shows a
  garbled/inverse screen even though memory is correct.
- **RAM banking trap**: `$0200–$BFFF` is subject to RAMWRT(write)/RAMRD(read)
  soft-switches. `PUTCH` toggles the bank per char, which leaks into other
  memory ops (SCRATCH, sector buffer), so the guest must explicitly set
  `RAMWRTOFF`/`RAMRDOFF` before touching non-text-page memory.
- Display/keyboard and SD SPI timing details: see `AGENTS.md` in this repo.

<a id="vendored-assembler"></a>
### Note on the vendored assembler

The vendored `asm6502.mjs` includes three fixes you must keep if you ever replace it:
- **"preserve internal spaces in ASC strings"** (from the veratest toolchain
  repo). Without it, multiple spaces in `ASC` strings (e.g. the `0F   ASCII`
  header gap) are collapsed to one and the columns misalign.
- **`CPX`/`CPY` addressing-mode fix**. `CPX`/`CPY` now emit the correct opcode
  for the operand: immediate (`E0`/`C0`) for `#imm`, **zero-page (`E4`/`C4`)**
  for a ZP label (e.g. `CPX ZP_IBUFIDX`), and absolute (`EC`/`CC`) otherwise.
  The old version always emitted immediate, so `CPX ZP_IBUFIDX` compared X to
  the *address value* (114) instead of the memory contents — breaking the LBA
  input parse (typing `800` failed) and drawing garbage after `LBA>`.
- **`AND`/`ORA` must never take an indexed-`Y` operand.** 6502 `AND`/`ORA` only
  support indexed-`X`; the assembler's `AND`/`ORA` handlers silently emitted
  `AND $0000`/`ORA $0000` for `label,Y` (dropping both the label and `,Y`,
  resolving to address 0). Because `$0000` held `$FF`, this ORed `$FF` into the
  dirty-map byte — the "8-byte inverse" bug where editing one byte made the
  whole `00-07`/`08-0F` group render inverse. Compute bit masks by shifting
  (see `BITMASK` in the source) instead of `label,Y` table lookups.

---

<a id="chinese"></a>
## 🇹🇼 繁體中文

（開場中英對照已在上方串接，此處直接列出詳細內容。）

<a id="cn-directory-contents"></a>
### 目錄內容（Git 追蹤）

| 路徑 | 說明 |
|------|------|
| `src/verasdedit/` | VeraSDEdit 原始碼、啟動 BASIC 與建置模組 |
| `src/verasdformat/` | VeraSDFormat 原始碼、啟動 BASIC 與建置模組 |
| `assets/ProDOS_2_4_3.po` | 共用的 ProDOS 2.4.3 基底磁片影像 |
| `asm6502.mjs` / `applebasic.mjs` | 共用的 vendored 建置依賴 |
| `build.bat` | Build VeraSDEdit, VeraSDFormat, ProDOS, FAT32, or all four |
| `verasdedit.po` / `verasdformat.po` | 可直接開機的建置輸出 |

| `src/verasd-prodos/` / `src/verasd-fat32/` | ProDOS driver and preliminary FAT32 client sources |
| Root `VeraSD-IFS-*.po` / `*.img` | Boot disks and SD image outputs |
| Four named PNG files in the project root | Screenshots of all four tools |

> Emulator captures and SD images are ignored; the four README tool screenshots are tracked.

<a id="cn-dependencies"></a>
### 依賴（已自包含，git clone 即可重建）

建置依賴**全部在 repo 內**，clone 後不需要另外準備（唯一外部需求是 Node.js）：

| 依賴 | 用途 | 位置 |
|------|------|------|
| **Node.js** | 執行 `src/verasdedit/verasdedit.mjs`（ESM `import` 語法） | https://nodejs.org （Node 12+，支援 `.mjs`） |
| **`asm6502.mjs`** | 6502 組譯器（匯出 `assemble6502`） | `src/asm6502.mjs`（已 vendored） |
| **`applebasic.mjs`** | Applesoft BASIC 編譯器（匯出 `compileApplesoftBasic`） | `src/applebasic.mjs`（已 vendored） |
| **`ProDOS_2_4_3.po`** | ProDOS 2.4.3 基底磁片影像（建置做底；腳本會清掉原有使用者檔，只留 PRODOS+SYSTEM） | repo 根 `assets/ProDOS_2_4_3.po`（已在 repo 內） |

`src/verasdedit/verasdedit.mjs` 全部用**相對路徑**，跨平台可用：

```js
import { assemble6502 } from "./asm6502.mjs"
import { compileApplesoftBasic } from "./applebasic.mjs"
const basePoPath = path.join(__dirname, "..", "bin", "ProDOS_2_4_3.po")
```

> 若想改用自己系統上的組譯工具/基底磁片，改這幾處即可。

<a id="cn-verasdedit"></a>
<a id="cn-build"></a>
### VeraSDEdit — Hex sector editor

VeraSDEdit 是在 Apple II 上執行的 VERA SD sector 瀏覽與編輯工具，可讀取任意
512-byte LBA、以 hex/ASCII 顯示內容，並將修改後的完整 sector 寫回 SD 卡。
適合檢查 partition table、FAT32 metadata 與 raw 磁碟內容。

- **瀏覽：** `N`/`P` 切換 sector、`R` 重新讀取、`L` 輸入 LBA。
- **編輯：** 可用 hex 或 ASCII 修改 byte，按 `W` 寫回整個 sector。
- **容量：** 讀取 SD 的 CSD 並顯示總 sector 數，LBA 輸入為 32-bit。
- **開機磁碟區名稱：** `VERASDEDIT`。

#### 建置

```powershell
# Windows（一鍵）：
build.bat verasdedit

# 或手動（任何平台）：
node src/verasdedit/verasdedit.mjs
```

成功輸出：

```
Created ...\verasdedit.po (143360 bytes)
  VERASDEDIT.BIN: 4491 bytes (load $2000)
  STARTUP: 783 bytes
```

把 `verasdedit.po` 複製到 `Release\` 並在 AppleWin 開機。

<a id="cn-usage"></a>
#### 使用方式（AppleWin）

1. 啟動 AppleWin，安裝 **VERA 卡到 Slot 2 或 Slot 4**，並在 VERA 卡的「Configure...」裡選好 **SD 卡影像**。
2. **若 Slot 7 有設硬碟**，它會先開機，editor 不會出現——開機前先清掉
   `HKCU\...\Configuration\Slot 7` 的 `Last Harddisk Image 1`。
3. 把 `verasdedit.po` 當磁片開機（`-d1` 指定，或 GUI 掛載後 reset）。
4. `src/verasdedit/startup.bas` 印 banner、**用 PEEK/POKE 偵測 VERA 卡（先 Slot 2 再 Slot 4）**，
   偵測到才 `BRUN` editor（兩槽都沒有就印 `No VERA Card Detected on Slot 2 or 4!`
   並結束）。editor 再自己偵測一次 slot，讀取 LBA `800`（FAT32 boot sector）：

```
VeraSDEdit (Hex Sector Editor)  v1.01 by anomixer 2026
LBA=00000800  (TOTAL=000nnnnnn) PAGE 1
Offset 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F   ASCII Dump
------ -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --   ----------------
 0000  EB 58 90 43 4D 44 52 2D 44 4F 53 00 02 02 20 00   .X.CMDR-DOS... .
```

> `LBA=xxxxxxxx` 是目前 sector，以 8 個 hex 位數顯示（32-bit——正好能涵蓋
> FAT32 的 2 TB 上限）。`(TOTAL=000nnnnnn)` 是 SD 影像的**總磁區數**
> （512-byte sector），開機時用 **CMD9（SEND_CSD）** 讀 CSD register 算出來，
> 方便知道 FAT32 容量邊界。

<a id="cn-keys"></a>
#### 鍵盤操作

| 按鍵 | 功能 |
|------|------|
| `SPACE` | 換頁（PAGE 1 ↔ PAGE 2） |
| `N` | 下一個 LBA（LBA+1；在最後一顆磁區時繞回 0） |
| `P` | 上一個 LBA（LBA−1；在 0 時繞回最後一顆磁區 Total−1） |
| `R` | 重新載入目前 LBA |
| `L` | **選擇 LBA**——輸入 1–8 個 hex digit + `RETURN` 載入，`DEL` 退格，`ESC` 取消回 editor |
| `E` | 進入**編輯模式**（見下） |
| `Q` | 回 ProDOS（BYE/RTS：還原 ZP + IRQ vector、切回 40 欄、**先 HOME 清屏**再回） |

> 指令鍵**大小寫皆可用**（`N`/`n`、`P`/`p`、`R`/`r`、`L`/`l`、`E`/`e`、
> `Q`/`q`，編輯器內 `I`/`i`、`J`/`j`、`K`/`k`、`M`/`m`）。只有編輯器**資料輸入**
> （hex nibble / 可印 ASCII）維持大小寫敏感，所以小寫 ASCII 仍可當資料輸入。
>
> editor 的按鍵是 `SPACE`/`N`/`P`/`R`/`L`/`E`/`Q`。hex digit 在 editor **無作用**
> ——LBA 輸入只在 `[L]` 選擇模式內發生（此時 `0-F` 是 LBA digit，不是改 nibble）。
> nibble 編輯只在編輯模式內。

##### 編輯模式

按 `E` 編輯目前頁面。游標可在 hex 與 ASCII 欄移動；**改過的 byte 會反白**
（兩個 nibble 都反白），直到寫入。**游標格一律閃爍**——hex 欄游標所在的
nibble 閃爍、ASCII 欄游標字元閃爍，即使該 byte 已改過（反白）也照樣閃，
方便看出游標位置。按 `W` 寫入後該 byte 恢復正常顯示。

編輯器有兩個狀態：
- **瀏覽**（進入時的預設）：`I`/`M`/`J`/`K` 移動游標，`TAB` 切換 hex ↔ ASCII 欄，
  `E` 切進編輯狀態。
- **編輯**（按 `E`）：按鍵現在會**修改**游標下的 byte——`0-F` 設定 hex nibble、
  可印字元設定 ASCII byte（含 `IJKL` 與 `W`，在這裡是當資料輸入，不是移動游標、
  也不是寫入；`E` 在此也當 nibble/字元輸入）。`W` **只在瀏覽狀態**寫入。按 `CR`
  （Enter）回瀏覽，或按 `ESC` 離開編輯器。

| 按鍵 | 功能 |
|------|------|
| `I` / `M` | 游標上 / 下移一列（byte ±16）——僅瀏覽狀態 |
| `J` / `K` | 游標左 / 右移（hex 欄以 nibble 為單位）——僅瀏覽狀態 |
| `TAB` | 切換 hex 欄 ↔ ASCII 欄 |
| `E` | 瀏覽狀態：進入編輯狀態 |
| `CR` | 編輯狀態：停止編輯、**接受**編輯，回瀏覽 |
| `ESC` | 編輯狀態：**丟棄**編輯（重讀 SD sector）、回瀏覽；瀏覽狀態：離開編輯器回 editor |
| `0–9 A–F` | 編輯狀態，hex 欄：設定游標下的 nibble 並前進（含 `E`） |
| （可印字元） | 編輯狀態，ASCII 欄：設定游標下的 byte 並前進（含 `IJKL`） |
| `W` | 把整個 sector 寫回 SD 卡（CMD24）——`W`/`w` 皆可，navigate banner 顯示（`[E]=edit [W]=write`） |

> hex 欄的游標只閃爍**游標所在的 nibble**（左/右）。打一個 hex digit 會改該
> nibble 並前進 high→low→下一個 byte，所以**一個 byte 的兩個 nibble 都可編輯**；
> 進入編輯模式時游標從左邊（high）nibble 開始。
>
> `Q` 以 ProDOS `BYE`/RTS 慣例（BRUN 的回傳位址）回 ProDOS，**不是**
> Applesoft warm-start `$3D2`。會先還原 ZP/IRQ vector、切回 40 欄，並
> **HOME 清屏**，讓 `]` 提示符出現在乾淨畫面。

* `W` 透過 CMD24（WRITE_SINGLE_BLOCK）把目前 sector 的**全部 512 bytes**
  （兩頁）寫回——guest 送 token `0xFE` + 512 bytes data + 2 bytes CRC。
* `W` 後 dirty 指示清除；未 `W` 就 `ESC` 則捨棄修改。

<a id="cn-verasdformat"></a>
### verasdformat — VERA SD/MMC FAT32 格式化工具

本儲存庫的第二個獨立工具，將 VERA 擴充卡上的 SD 卡影像格式化為相容 CMDR-DOS 與 A2VERA 的標準 **FAT32** 磁碟格式。

- **MBR 分割區**：建立 MBR 分割表，自 LBA 2048 起建立類型 `$0C`（FAT32 LBA）主要分割區。
- **FAT32 磁區結構**：依序寫入 VBR（開機磁區）、FSInfo、備份開機磁區、FAT #1、FAT #2，並初始化根目錄第 2 cluster。
- **功能選單**：
  - `[1] Catalog SD`：列出根目錄 8.3 格式檔名與檔案大小。
  - `[2] Format SD`：快速格式化。需手動鍵入 `FORMAT` 並按 `RETURN` 確認執行，按 `ESC` 隨時取消。
  - `[3] Verify SD`：透過 CMD17 逐一讀回所有中繼資料磁區，與樣板進行 512-byte 逐位元組比對驗證。
  - `[0] Exit`：還原零頁與中斷向量，乾淨返回 ProDOS。
- **開機磁碟區名稱：** `VERASDFORMAT`。
- **建置方式**：
  ```powershell
  build.bat verasdformat    # Windows 一鍵建置
  node src/verasdformat/verasdformat.mjs     # 跨平台建置
  ```
- **AppleWin 執行**：
  ```powershell
  AppleWin.exe -s2 vera -d1 C:\dev\verasdedit\verasdformat.po -power-on
  ```

<a id="cn-prodos-driver"></a>

ProDOS 開機磁片和 SD image (`VeraSD-IFS-ProDOS.po` / `VeraSD-IFS-ProDOS.img`) 都位於專案根目錄

### VeraSD ProDOS 8 區塊驅動

VeraSD-IFS-ProDOS 是常駐式 ProDOS 區塊驅動，將 raw ProDOS SD image 掛載成
ProDOS 可正常使用的磁碟卷冊。程式安裝後即使執行 `BYE`，磁碟裝置仍可供
ProDOS 程式和 Copy II Plus 使用；容量上限為 65,535 個 512-byte blocks（約 32 MiB）。

完整 ProDOS driver 專案位於 `src/verasd-prodos/`。使用
`build.bat prodos` 或 `npm run build:prodos` 建置，再以
`npm run test:prodos` 執行組譯後 driver 與 installer 回歸測試（需要 Python
與 py65）。開機 `VeraSD-IFS-ProDOS.po` 後執行 `BRUN VERASD.SYSTEM`。
開機磁碟區名稱為 `VERASDIFSPRODOS`；安裝訊息會停留約一秒再返回 Bitsy Bye。

SD image 是 32 MiB raw ProDOS volume，提供 65,535 個 512-byte blocks。
常駐 driver 使用 language card bank 2，已測試 ProDOS BASIC 和 BYE 後的
Copy II Plus 流程。建置會保留 image 中的檔案；`--reset-sd` 會重建空卷冊。

- **建置方式**：
  ```powershell
  build.bat prodos                         # Windows 一鍵建置
  node src/verasd-prodos/verasd.mjs        # 跨平台建置
  ```
- **AppleWin 執行**：
  ```powershell
  if (-not (Test-Path VeraSD-IFS-ProDOS.img)) { Expand-Archive VeraSD-IFS-ProDOS.img.zip -DestinationPath . }
  # 在 VERA Configure 中選取 VeraSD-IFS-ProDOS.img
  AppleWin.exe -s2 vera -d1 C:\dev\verasdtool\VeraSD-IFS-ProDOS.po -power-on
  ```
  開機 `VeraSD-IFS-ProDOS.po` 後，`BASIC.SYSTEM` 會自動執行 STARTUP：偵測 Slot 2/4 的 VERA、
  載入 driver 並確認 SD 上線，再提供 CATALOG 或啟動 A2Desktop 的選單。
  也可在 ProDOS 提示符手動執行 `-VERASD.SYSTEM`。

<a id="cn-fat32-client"></a>

FAT32 開機磁片和 SD image (`VeraSD-IFS-FAT32.po` / `VeraSD-IFS-FAT32.img`) 都位於專案根目錄

### VeraSD FAT32 原生用戶端

**WIP / Preliminary：目前只支援 catalog、read 與 test write，還不是真正的 IFS driver。**

VeraSD-IFS-FAT32 是從 ProDOS 啟動的獨立 FAT32 檔案工具，可處理超過 32 MiB
的 FAT32 SD image；目前不是 ProDOS IFS，BASIC `CATALOG` 和 Copy II Plus
不能把它當成 ProDOS 磁碟使用。現有功能包括列出根目錄 8.3 檔名、讀檔與覆寫
預先配置的測試檔。

`src/verasd-fat32/` 可建置獨立 ProDOS 開機磁片與 Apple II FAT32 檔案用戶端。
執行 `build.bat fat32` 或 `npm run build:fat32`。建置只使用本 repo 的組譯器、
ProDOS base image 與 FAT32/SD 原始碼模組，不依賴另一個 a2vera checkout。

用 `python src/verasd-fat32/fat32-fixture.py` 建立 128 MiB 測試 SD image；
若檔案已存在，程式會拒絕覆寫。將 image 掛載到 VERA、開機後執行
`BRUN FAT32.SYSTEM`。按 C 列根目錄、按 R 讀取 8.3 檔名、按 W 再按 Y
覆寫預先配置的 1,024-byte `TESTNOW.BIN`，按 Q 回 BASIC。
開機磁碟區名稱為 `VERASDIFSFAT32`。

目前程式能列目錄、讀檔及改寫預先配置的檔案，尚未登錄 ProDOS 磁碟裝置；
因此 BASIC CATALOG 和 Copy II Plus 還不能直接存取 FAT32。詳細功能與限制見
`src/verasd-fat32/FAT32-README.md`。執行 `npm run test:fat32` 需要 Python 與 py65。

- **建置方式**：
  ```powershell
  build.bat fat32                             # Windows 一鍵建置
  node src/verasd-fat32/fat32-build.mjs      # 跨平台建置
  ```
- **AppleWin 執行**：
  ```powershell
  if (-not (Test-Path VeraSD-IFS-FAT32.img)) { Expand-Archive VeraSD-IFS-FAT32.img.zip -DestinationPath . }
  # 在 VERA Configure 中選取 VeraSD-IFS-FAT32.img
  AppleWin.exe -s2 vera -d1 C:\dev\verasdtool\VeraSD-IFS-FAT32.po -power-on
  ```
  開機至 ProDOS 提示符後，執行 `BRUN FAT32.SYSTEM`。

<a id="cn-technical-background"></a>
### 技術背景

- **80-column 顯示**：Apple IIe 的 80 欄是**交錯 AUX/MAIN**——每個 40-address
  text-page cell 同時渲染 AUX(左)+MAIN(右)（`NTSC.cpp updateScreenText80`：
  `bits=(main<<7)|aux`）。所以偶數欄→AUX、奇數欄→MAIN，cell offset = 欄/2。
- **顯示初始化**：切到 80 欄文字（`$C00D`）後，guest 還要設
  **80STORE OFF（`$C000`）** 和 **PAGE2 OFF（`$C054`）**，讓顯示讀 PAGE1
  （`$0400`，也就是 guest 寫入的地方）。漏設會出現畫面反白/錯亂，即使記憶體
  內容是對的。
- **RAM banking 陷阱**：`$0200–$BFFF` 全受 RAMWRT（寫）/RAMRD（讀）soft-switch
  影響。PUTCH 每字元切 bank 會把 soft-switch 狀態帶到其他記憶體操作（SCRATCH、
  sector buffer），所以 guest 存取非 text-page 記憶體前都要顯式設
  `RAMWRTOFF`/`RAMRDOFF`。
- 顯示/鍵盤、SD SPI 時序等詳細說明見本 repo 的 `AGENTS.md`。

<a id="cn-vendored-assembler"></a>
### 組譯器版本備註

本目錄的 `asm6502.mjs` 已內含三個修正，日後更新組譯器務必保留：
- **「ASC 多空格保留」**（來源：veratest 工具 repo）。否則 header 多空格會被
  摺疊、顯示錯位。
- **`CPX`/`CPY` 定址模式修正**。`CPX`/`CPY` 現在依 operand 發正確 opcode：
  `#imm` → immediate（`E0`/`C0`）、**ZP label → zero-page（`E4`/`C4`）**（如
  `CPX ZP_IBUFIDX`）、否則 → absolute（`EC`/`CC`）。舊版一律發 immediate，所以
  `CPX ZP_IBUFIDX` 拿 X 去比**位址值 114** 而非記憶體內容，導致 LBA 輸入 parse
  失敗（打 `800` 讀取失敗）與 `LBA>` 後出現垃圾。
- **`AND`/`ORA` 不可用 indexed-`Y`**。6502 的 `AND`/`ORA` 只有 indexed-`X`；
  組譯器的 `AND`/`ORA` handler 對 `label,Y` 會靜默發出 `AND $0000`/`ORA $0000`
  （label 與 `,Y` 一起被丟掉、解析成位址 0）。因為 `$0000` 內容是 `$FF`，這會把
  dirty-map 那一格 OR 成 `$FF`——就是「改 1 個 byte → 00-07 整組反白」的 bug。
  請用位移算 bit mask（見原始碼 `BITMASK`），不要用 `label,Y` 查表。
