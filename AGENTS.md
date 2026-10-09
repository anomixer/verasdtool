# AGENTS.md

This file is a working guide for coding agents and contributors working on
**VeraSDTool** — a toolkit containing a PC-Tools-style 6502 hex sector editor
and a FAT32 formatter for the Commander X16 **VERA expansion card**'s SD/MMC
SPI. It captures the architecture and the
hard-won debugging lessons so future work doesn't re-trace the same mistakes.

> verasdedit was split out of the **AppleWin** repo (Apple II emulator for
> Windows) into its own repository. It is a *guest* 6502 program that is run by
> AppleWin; it is not part of AppleWin's C++ codebase and has no build
> dependency on it. The VERA SD SPI *emulation* it exercises lives in AppleWin's
> `source\VERACard\` — see that repo for emulator-side details.

## What this is

- A 6502 hex sector editor that reads **any LBA** of an SD card image directly
  over the **VERA SD/MMC SPI**. The VERA base is **auto-detected (slot 2
  `$C200`, else slot 4 `$C400`)** at entry; SPI data/status are then `base+$1E` /
  `base+$1F`.
- Displays offset 0–511 as **hex + ASCII** in two pages (256 bytes / 16 rows).
- Runs on the Apple II (AppleWin) with the VERA card in **slot 2 or slot 4**,
  plus a mounted SD card image.
- Also has an **editor mode** (`E`) that writes a sector back via CMD24.
- Ships as a ready-to-boot **ProDOS disk image** (`verasdedit.po`, 143360 bytes).
- Boot volume names are `VERASDEDIT`, `VERASDFORMAT`, `VERASDIFSPRODOS`, and `VERASDIFSFAT32`; each builder writes the name in uppercase to the ProDOS volume-directory header. ProDOS volume names cannot contain hyphens.

## Repository layout

| Path | Description |
|------|-------------|
| src/verasdedit/ | VeraSDEdit assembly source, startup BASIC, and its Node build module |
| src/verasdformat/ | VeraSDFormat assembly source, startup BASIC, and its Node build module |
| assets/ProDOS_2_4_3.po | Shared ProDOS 2.4.3 base disk image |
| src/prodos-volume-name.mjs | Shared ProDOS volume-name writer used by each boot-disk builder |
| asm6502.mjs / applebasic.mjs | Shared vendored assembler and Applesoft compiler |
| build.bat | Root builder: verasdedit, verasdformat, fat32, prodos, or all |
| verasdedit.po / verasdformat.po | Ready-to-boot build outputs at repository root |

## Build

Self-contained — only **Node.js** (ESM) is required externally; all deps are
vendored in the repo.

```powershell
build.bat verasdedit              # Windows
node src/verasdedit/verasdedit.mjs # any platform
```

The script:
1. Assembles `src/verasdedit/verasdedit.asm` (load `$2000`) → `VERASDEDIT.BIN`.
2. Compiles `src/verasdedit/startup.bas` → `STARTUP`.
3. Packs both onto a ProDOS 2.4.3 image (from `assets/ProDOS_2_4_3.po`), freeing
   existing user files and keeping only PRODOS + BASIC.SYSTEM.

Successful output (current sizes):

```
Created ...\verasdedit.po (143360 bytes)
  VERASDEDIT.BIN: 4491 bytes (load $2000)
  STARTUP: 783 bytes
```

Copy `verasdedit.po` to `Release\` and boot it in AppleWin.

## Running it (AppleWin)

1. Install the **VERA card in Slot 2 or Slot 4**, mount an SD card image via
   the VERA card's "Configure..." dialog.
2. **Boot order gotcha**: if a hard disk is configured in Slot 7 (registry
   `Slot 7\Last Harddisk Image 1`, commonly `x16-hero-vera.hdv`), it boots first
   and the editor never appears. Clear that registry value before launching:
   ```powershell
   reg delete "HKCU\Software\AppleWin\Configuration\Slot 7" /v "Last Harddisk Image 1" /f
   ```
   then boot with `-d1 verasdedit.po -power-on -m`.
3. `src/verasdedit/startup.bas` prints the banner, **detects the VERA card (slot 2 then slot
   4)** via PEEK/POKE, then `BRUN`s the editor. If neither slot has a VERA card
   it prints `No VERA Card Detected on Slot 2 or 4!` and ends. The editor then
   re-detects the slot itself and reads LBA `800` (FAT32 boot sector).

## Keys

| Key | Action |
|-----|--------|
| `SPACE` | Toggle page (PAGE 1 ↔ PAGE 2) |
| `N` / `P` | Next LBA / previous LBA (`N` wraps from the last sector to 0; `P` wraps from 0 to the last sector, Total−1) |
| `R` | Reload current LBA |
| `L` | Select LBA — type 1–8 hex digits + `RETURN` to load, `DEL` backspace, `ESC` cancel |
| `E` | Enter editor mode |
| `Q` | Return to ProDOS (BYE/RTS): restores ZP + IRQ vector, switches to 40-col, **HOME-clears the screen**, then returns |

> Command keys accept **both cases** (`N`/`n`, `P`/`p`, `R`/`r`, `L`/`l`,
> `E`/`e`, `Q`/`q`, and in the editor `I`/`i`, `J`/`j`, `K`/`k`, `M`/`m`) — the
> key is case-normalised by `NORMKEY` before command comparisons. Only editor
> *data* input (hex nibbles / printable ASCII) stays case-sensitive, so
> lowercase ASCII can still be typed as data.
>
> In the *editor*, hex digits do nothing — LBA entry only happens inside the
> `[L]` select submode. Nibble edits only happen in the editor.

### Editor mode

The editor has two states: **navigate** (default, on entry) and **edit**
(press `E`). In navigate, `IJKM` move the cursor and `TAB` toggles field; in
edit, `0-F`/printable chars modify the byte under the cursor (so `IJKL` and
`E` are typed as data, not cursor movement / a toggle). `W` writes **only** in
navigate state — in edit state it's a printable char typed as data (the
`W`-write check sits after the EDITING check, so it never fires while editing).
`CR` (Enter) exits edit back to navigate.

| Key | Action |
|-----|--------|
| `I` / `M` | Cursor up / down one row (byte ±16) — navigate state only |
| `J` / `K` | Cursor left / right (hex moves per nibble) — navigate state only |
| `TAB` | Toggle hex field ↔ ASCII field |
| `E` | Navigate state: enter edit state |
| `CR` | Edit state: stop editing, **accept** the edit, return to navigate |
| `ESC` | Edit state: **discard** the edit (re-read sector from SD), return to navigate; navigate state: leave editor to editor |
| `0–9 A–F` | Edit state, hex field: set nibble under cursor, advance (incl. `E`) |
| (printable) | Edit state, ASCII field: set byte under cursor, advance (incl. `IJKL`) |
| `W` | Write whole 512-byte sector back via CMD24 (both `W`/`w`; shown in the navigate banner) |

The navigate banner shows `[W]=write`; the edit banner shows no `W` hint. `Q`
returns to ProDOS via the `BYE`/RTS convention (the BRUN return address), not
the Applesoft warm-start `$3D2`. `QUIT` restores ZP `$50-$81` (saved at entry
to `ZPBACKUP` at `$3200`), restores the IRQ vector, switches to 40-col, forces
`RAMWRTOFF` and calls ROM `HOME` (`$FC58`) so the `]` prompt lands on a clear
screen.

`W` write detection: `WRITE_SECTOR` reads the SD **data-response token** after
the 512-byte write — `0x05` (accepted) → success, `0x0D` (rejected) → the SD
is **write-protected / read-only**, and the editor shows `SD Write Protected!`
(a generic failure still shows `SD Write failed!`). The emulator's VERA SD
returns `0x0D` whenever `VERASD::WriteBlock` fails — e.g. the image was opened
read-only (`rb` fallback when `r+b` fails) — so a read-only image is detected
on write. Write protection is only checked when `W` is pressed (no proactive
probe). `WRITE_SECTOR` returns A: 0 = success, 1 = generic fail, 2 = protected.
A **successful write clears status row 22** (`EL_WOK` → `GOTO_ROW 22` +
`CLEAR_LINE`) so a stale `SD Write Protected!` / `SD Write failed!` from an
earlier attempt doesn't linger beside the fresh `Saved (clean)` indicator.

**SD image change protection**: before writing, `EL_WRITE` calls
`CHECK_SD_UNCHANGED`, which re-reads the current LBA (CMD17) into `SWAPBUF`
(`$3800`/`$3900`) and compares it byte-for-byte against `ORIGBUF`. If they
differ, the SD image was swapped/changed since the sector was loaded, and the
editor shows `SD Card Changed. Force Write (y/n)?` — `Y` forces the write
(you know the card changed and want to write anyway), `N` aborts without
touching the new card's LBA. This stops the old card's buffered sector from
being written to a different image's LBA.

**Write-fail re-init retry**: swapping/re-attaching the SD resets the emulator's
SPI state (`ResetSpiState` → `m_selected=false, m_is_initialized=false`), so a
raw CMD24 right after a swap fails (R1 reads `0xFF` → generic fail). `EL_WR_GO`
now retries a generic failure (A=1) once after re-running `SD_INIT` (re-select +
CMD0/8/55/41/16); only a second failure shows `SD Write failed!`. Write-protect
(A=2, token `0x0D`) is not retried — a genuinely rejected write won't be fixed
by re-init.

Edited bytes show **inverse**, the cursor cell **flashes** — `PUTCH` supports
three display modes (`ZP_DISPMODE`: 0=normal `|0x80`, 1=inverse `&0x3F`,
2=flash `&0x3F|0x40`; the 80-col flash bit is bit6 with bit7 clear). A 32-byte
dirty bitmap (`$3310`, 1 bit per byte) tracks edits; `W` clears it.

A **changed byte shows inverse** (both nibbles) until written — and a byte only
counts as changed if its value actually differs from the **original** (the
last-loaded sector, kept in `ORIGBUF` at `$3400`). Editing a byte back to its
original value (e.g. `00` → `00`, or reverting `05` → `00`) clears its dirty bit
and it renders normal again, so typing through untouched bytes never shows
inverse. The **cursor cell always flashes** — in the hex field the nibble under
the cursor (`ZP_NIBPOS`) flashes, and in the ASCII field the cursor char flashes,
**even on a changed (inverse) byte**, so you can always tell where the cursor is
(`ASCII_DISPMODE` sets flash for the cursor byte + ASCII field without an
`IS_DIRTY` branch). The *other* nibble of a changed cursor byte stays inverse,
and changed non-cursor bytes render fully inverse. After `W` clears the dirty
bitmap and refreshes `ORIGBUF` (the written bytes become the new original).

In the hex field the cursor flashes **only the nibble under it** (`ZP_NIB`:
0=high/left, 1=low/right; `ZP_NIBPOS` selects which nibble is being drawn).
Typing a hex digit edits that nibble and advances high→low→next byte, so both
nibbles of a byte are editable; `ZP_NIB` is reset to 0 (high) on entering edit
mode.

## Debugging lessons (ordered by importance)

1. **Assembler `CPX`/`CPY` addressing-mode bug — root cause of LBA input
   failures.** The vendored `asm6502.mjs` used to emit **immediate** (`E0`/`C0`)
   for *every* `CPX`/`CPY`, never zero-page (`E4`/`C4`). So `CPX ZP_IBUFIDX`
   compared X to the *address value* (114) instead of the memory contents,
   making the LBA-input parse loop run the wrong number of times: typing `800`
   sent LBA `FF00FF00` (out of range) → "SD Read failed!", and `LBA>` drew
   garbage. **Fixed**: `CPX`/`CPY` now pick immediate for `#imm`, zero-page for
   a ZP label/`$XX`, absolute otherwise. **If you re-vendor `asm6502.mjs`, keep
   this fix.** Verified: `CPY ZP_IBUFIDX` → `C4 72`, `CPX ZP_IBUFIDX` → `E4 72`.
2. **Display init gotcha (garbled/inverse screen).** After switching to
   80-column text (`$C00D`), the guest must also set **80STORE OFF (`$C000`)**
   and **PAGE2 OFF (`$C054`)** so the display reads PAGE1 (`$0400`, where the
   guest writes). Forgetting these shows a garbled/inverse screen even though
   memory is correct — because the 80-col display reads PAGE1 vs PAGE2 per the
   PAGE2 soft-switch (`$C054`/`$C055`), which is independent of the write-routing
   RAMWRT soft-switch.
3. **SCRATCH / sector-buffer banking — and keep SCRATCH above the code.** `$0200–$BFFF`
   is subject to RAMWRT(write)/RAMRD(read) soft-switches. `PUTCH` toggles the bank
   per char, which leaks into other memory writes. The guest must explicitly
   `STA RAMWRTOFF` before writing SCRATCH or the sector buffer (`SECTOR0`/`SECTOR1`),
   and `RAMRDOFF` before reading them, or data silently lands in the wrong bank
   (e.g. ASCII column garbled, or a reloaded sector not updating the display).
   **SCRATCH must also sit strictly above the code** — it's a 16-byte work area
   for the ASCII column, and the code grows up through `$2E00` as features are
   added. When SCRATCH was `$2E00` and the program grew to 3587 bytes
   (`$2000`–`$2E02`), `DRAW_DATA`'s `STA SCRATCH,Y` overwrote the trailing
   `JMP EDIT_LOOP` with sector data → the guest executed garbage and hit a `BRK`
   at `$2E02` after any byte edit. SCRATCH was moved up again when the TOTAL
   (CMD9/CSD) feature was added, and the sector buffers were relocated when the
   `P`-wrap (`PREV_LBA`) feature pushed the code past `$3000`. Current layout
   (code 4491 bytes, end `$318B`): SCRATCH `$3300`, DIRTYMAP `$3310`, TOTBUFF/CSD
   `$3330`–`$3336`, NEXTTMP `$3337`, ZPBACKUP `$3200`, ORIGBUF `$3400`, sector
   buffers `SECTOR0`=`$3600`/`SECTOR1`=`$3700`, SWAPBUF `$3800`/`$3900` (the
   SD-changed check's re-read buffer). **The code must never overlap the
   lowest buffer, ZPBACKUP (`$3200`)** — re-check that code end (`load + length`)
   stays below it when adding code.
4. **Subroutine A-clobber pitfall.** `HEX_DISPMODE`/`ASCII_DISPMODE` use A as a
   temp and clobber the byte being printed; reload the buffer byte after calling
   them, or the hex column shows garbage.
5. **SD write persistence.** When writing a sector back, the emulator's
   `VERASD::WriteBlock` must `fflush` after `fwrite`, or a hard kill loses the
   write (stdio buffer never flushed). (Emulator-side, but the guest depends on
   it.)
6. **Assembler silently drops `label,Y` on `AND`/`ORA` — root cause of the
   "8-byte inverse" bug.** The vendored `asm6502.mjs` `AND`/`ORA` handlers only
   support `#imm`, `$zp`, and absolute — they have **no indexed-`Y` mode**, but
   6502 `AND`/`ORA` have *no* indexed-`Y` mode anyway (only indexed-`X`).
   Writing `AND BIT_TABLE,Y` was silently assembled as **`AND $0000`** (the
   label *and* the `,Y` were both dropped, `resolveVal` returned `NaN` →
   address 0). The zero page at `$0000` held `$FF`, so `SET_DIRTY_BIT`'s
   `ORA $0000` ORed `$FF` into the dirty-map byte (all 8 bits set → 8
   neighbouring bytes all rendered inverse), and `IS_DIRTY`'s `AND $0000`
   (identity on `$FF`) read them all as dirty — hence editing ONE byte made
   the whole `00-07`/`08-0F` group inverse. **Fixed**: compute the bit mask by
   shifting in a `BITMASK` routine (`LDA #1; CPY #0; BEQ done; ASL A; DEY;
   JMP`) instead of a table lookup, so `AND`/`ORA` never take an indexed-Y
   operand. **If you re-vendor `asm6502.mjs`, keep this in mind** — and never
   write `AND/ORA/EOR label,Y` (invalid 6502); use indexed-`X` or compute the
   mask by shifting. Verified by disassembling the binary: `AND BIT_TABLE,Y`
   had become `2D 00 00` (`AND $0000`), now `AND $5A`.
7. **`SPI_READ_A` must read the SPI DATA register, not STATUS — slot-4 SD read
   failures.** The original `SPI_READ_A` did `LDA VERA_SPI_ST` (STATUS) after
   writing `$FF` to the data register, so it returned the *status* byte, not the
   shifted-in SD byte — reads came back wrong (the guest reported "SD Read
   failed!" even on a valid card, and slot 4 never worked). **Fixed**: write
   `$FF` to the SPI DATA register and read the byte back from **DATA**
   (`LDY #$00; LDA (ZP_SPIDATLO),Y`), polling STATUS only in `SPI_WAIT`. The SPI
   registers are addressed dynamically via `ZP_SPIDATLO/HI` = base+`$1E` and
   `ZP_SPISTLO/HI` = base+`$1F` (slot 2 `$C21E`, slot 4 `$C41E`).
8. **Quit-to-ProDOS needs ZP restore + a forced bank before ROM `HOME`.** After
   the BRUN `RTS`, ProDOS/Applesoft resumes startup.bas, but the program leaves
   ZP `$50-$81` clobbered — that alone can crash the return. `QUIT` now
   restores ZP `$50-$81` from `ZPBACKUP` (`$3200`, saved at entry) and restores
   the IRQ vector before returning. The screen-clear also failed on `SD read
   failed` (the error path left the RAMWRT/RAMRD soft-switches on AUX), so `QUIT`
   must `STA RAMWRTOFF` (write MAIN) *before* `JSR $FC58` (ROM HOME) — otherwise
   HOME clears the wrong bank and the `]` prompt is buried in old text.

## 80-column display model (Apple IIe)

- 80-column text **interleaves AUX/MAIN per column** — each 40-address
  text-page cell renders AUX(left)+MAIN(right) (`NTSC.cpp updateScreenText80`:
  `bits=(main<<7)|aux`). So even columns→AUX, odd columns→MAIN, cell offset =
  column>>1. `PUTCH` must swap banks per char.
- Display row R's cell base = `$0400 + (R&7)*$80 + (R/8)*$28`.

## Testing

- **Offline assembler check**: `node -e "..."` to confirm `CPX`/`CPY` emit
  `E4`/`C4` (zero-page) for ZP labels, not `E0`/`C0`.
- **Interactive (headless)**: launch AppleWin with the editor disk, confirm the
  process stays alive and the 80-col text page can be reconstructed from
  `MemGetMainPtr`/`MemGetAuxPtr`. In a headless environment `FindWindow`/
  `PrintWindow` return handle 0, so screenshots don't work — use a text-page
  dump diagnostic instead. `MemGetAuxPtr` has a cache artifact; some chars are
  garbled when rebuilding the frame.

---

# verasdformat — FAT32 SD formatter

A second guest program in this repo: formats a VERA-attached SD image to
FAT32 for Apple II use by CMDR-DOS and A2VERA. **Pure 6502 only** (user
requirement — no 65c02 instructions). Source `src/verasdformat/verasdformat.asm` (~3800 lines),
build `node src/verasdformat/verasdformat.mjs` → `VERASDFORMAT` + `STARTUP` on the ProDOS base
→ `verasdformat.po` (143360 bytes).

## Scope (user decisions — do not over-build)

- **CATALOG SD** only needs to list root-directory **8.3 filenames + file
  sizes** ("先只做出能列根目錄 8.3 的檔名和檔案大小就好, 怕你做太詳細").
  Mirror `C:\dev\a2vera\a2vera\sd_diag.asm` (`list_root` lines 374–471) and
  the FAT32 helpers in `C:\dev\a2vera\a2vera\vera_sd.inc`: `fat_mount`
  (line 964: MBR+VBR → secs/clus, fat_begin_lba, clus_begin_lba, root_clus),
  `clus_to_lba` (1119), `fat_next_cluster` (1175), `sd_read_block` (503).
- **No super floppy.** FORMAT = build MBR partition table first (type `$0C`,
  start LBA 2048), then format that partition as FAT32.
- Main menu: **1) CATALOG SD, 2) FORMAT SD, 3) VERIFY SD, 0) EXIT**.

## Memory layout (current — code end must stay below ZPBACKUP)

Program loads `$2000`, currently **8565 bytes, ending at `$4165`**. Code is
well below `ZPBACKUP=$9400`; the formatter uses the upper Apple II memory for
its buffers and scratch space.

- ZP: `ZP_CURSOR=$58`, `ZP_LBA0-3=$50-$53`, `ZP_TEMP=$5A`/`ZP_TEMP2=$5B`,
  `ZP_BUFLO=$5E`/`ZP_BUFPG=$5F`, `ZP_SPIDATLO=$6F`/`ZP_SPISTLO=$71`,
  `ZP_ERR=$75`, `ZP_PTR2=$78`/`ZP_PTR2HI=$79`, `ZP_PTR3=$7A`/`ZP_PTR3HI=$7B`,
  `ZP_SCR0-3=$7C-$7F`.
- Scratch: `ZPBACKUP=$9400` (48 bytes, ZP `$50–$7F`), **`VARS=$9450`**
  (all VARS variables on page `$94`), `MATHSB=$94B8`, catalog workspace
  `$94C0–$94E3`, `WRKBUF=$8000`, `TMPBUF=$8200`, and `FMTBUF=$8400–$93FF`.
- VARS offsets: `V_TOTAL=+0($3F50)`, `V_CSIZE=+4`, `V_PART=+8`,
  `V_PSIZE=+$0C`, `V_FATSZ=+$10`, `V_CLUST=+$14`, `V_DATA=+$18`,
  `V_ARG=+$1C`, `V_REM=+$20($3F70)`, `V_TMP1=+$24($3F74)`,
  `V_TMP2=+$28($3F78)`, `V_TMP3=+$2C($3F7C)`, `V_TMP4=+$30($3F80)`,
  `V_SPC=+$34`, `V_CSDV2=+$38`, `V_DIGBUF=+$58($3FA8)`.

## Assembler gotchas (asm6502.mjs, verified in this project)

- **No indexed-Y on `AND`/`ORA`/`EOR`/`CMP`/`SBC`/`ADC`** — only immediate /
  absolute. A `label,Y` operand is **silently dropped and assembled as `$0000`**.
  (Same family of bug as verasdedit lesson 6.)
- **Char literals `#'x'` are NOT parsed** — they resolve to `#0`. Use hex bytes
  (`#$20`, `#$30`, …). All char literals in this file were already converted.
- `CPX`/`CPY` pick ZP for `$XX`/ZP labels, absolute otherwise (fixed handler).
- `STA abs,Y` and `STA (zp),Y` are supported and verified. `ROR A`→$6A,
  `ASL A`→$0A, `LSR A`→$4A, `ROL A`→$2A all verified correct.
- **`SEC`/`CLC` are `$38`/`$18` in this assembler** (lines 90–91) — the
  correct 6502 opcodes. A binary pattern search that assumes `SEC`=`$EA`
  (NOP) finds nothing and falsely suggests an assembler bug; verify by
  assembling a small test file, not by guessing opcodes.
- **Indexed-X with a ZP label emits the absolute form**: `STA V_CSIZE,X` →
  `9D 54 3F` (3 bytes) even though the label is on page $3F — only `$XX`
  *literal* operands get the 2-byte ZP form. Functionally correct; just don't
  expect the short form when grepping the binary.
- **PowerShell quoting**: double-quoted inline `node -e "..."` commands mangle
  `$XX` hex tokens (PS expands them as variables → labels resolve to $0000,
  immediates lost). Write isolated assembler tests to a `.mjs` file and run
  `node file.mjs` instead.

## Debugging lessons (verasdformat-specific)

1. **`PRINT_NIB` hex-letter off-by-one.** After `CMP #$3A`, the carry makes
   `ADC #$07` produce `$08` — letters printed one high (5A→"5B"). Fixed to
   `ADC #$06`.
2. **`ZP_PTR2HI`/`ZP_PTR3HI` clobbered by SD routines** → garbage digits in
   decimal output. Fix: pin `LDA #$94 / STA ZP_PTR2HI / STA ZP_PTR3HI` at the
   start of every routine that dereferences them (`PRINT_DEC32W`,
   `COMPUTE_GEOMETRY`, …) — all VARS live on page `$94`.
3. **Unbounded `PDW_LOOP` hung** — now bounded by a counter in `ZP_SCR3`
   (max $20 digits).
4. **RAMWRT bank leak from `PUTCH` — root cause of the garbled capacity line.**
   `PUTCH` toggles RAMWRT per column (even→AUX, odd→MAIN); reads always come
   from MAIN (RAMRD is never switched). So any store into VARS/WRKBUF after a
   display call lands in whichever bank the last column left — decimal digits
   garbled (`V_DIGBUF` written to AUX), `V_TMP1` dump garbage, MiB=2.
   **Fix: force `LDA #$00 / STA RAMWRTOFF` at the start of every routine that
   writes `$3F50–$4FFF` after display calls** (`PRINT_DEC32W`, `SHR32`,
   `SHL_TOTAL`, `DIV32`, the `SCL_CP` copy in `SHOW_CAP_LINE`,
   `COMPUTE_GEOMETRY`). `SD_READ_SECTOR`/`SD_WRITE_SECTOR`/templates already
   do this. (Same class as verasdedit lesson 3.)
5. **CSD stream is PERFECT — the capacity bug is a byte-order error in the
   +1 block (root cause found, fix not yet applied).** Verified via the
   emulator's own SPI log (see Test workflow): after the CMD9 frame
   (`49 00 00 00 00 FF`) the guest receives exactly the 21-byte CSD with no
   R1 prefix — for the 100 MB test card: `ff ff 00 ff fe 40 0e 00 32 5b 59
   00 | 00 00 C7 | 7f 80 0a 40 00 01`, i.e. b12/b13/b14 = `00 00 C7` →
   c_size=199 → total should be **204800 sectors**. `GST_LOOP` stores the
   raw stream into `WRKBUF[0..20]` and row 4 dumps it as 42 hex chars.
   **The bug:** `GET_SD_TOTAL`'s +1 block builds
   `V_TOTAL = [V_CSIZE+2, V_CSIZE+1, V_CSIZE, $00] + 1` — but `V_CSIZE[0]`
   (CSD byte 12) is the *most* significant c_size byte, so this puts c_size
   MSB-first bytes in **reverse** order: with the verified stream it yields
   `$C7000001`, and ×1024 → `$00000400` = 1024 sectors (0 MiB). Correct
   build: `V_TOTAL = [$00, V_CSIZE, V_CSIZE+1, V_CSIZE+2] + 1` (= c_size+1,
   top byte stays 0 since c_size < 2^18) → `$000000C8` → ×1024 =
   **$00032000 = 204800** ✓. (The earlier "observed $00040C00" came from an
   older build with different code — superseded.) Emulator protocol
   reference: `VERASD.cpp` `SetResponseCSD` (static 21-byte CSD,
   c_size=(FileSizeBytes()>>19)-1 into bytes 12/13/14), `HandleByte`
   (response starts on the first $FF after the 6-byte frame; no R1 for
   CMD9), `SpiWrite/SpiStep/SpiRead` (write arms a byte, clock step
   completes it — `SyncSPI` runs before every IO read/write — read returns
   the last completed byte).

6. **RAMRDOFF / RAMRDON softswitch address inversion — root cause of BRK crashes in Option 2 & 3.**
   Apple IIe softswitches define `$C002` = `RAMRDOFF` (Read enable MAIN memory $0200-$BFFF)
   and `$C003` = `RAMRDON` (Read enable AUX memory $0200-$BFFF). In `src/verasdformat/verasdformat.asm`,
   they were mistakenly inverted (`RAMRDON = $C002`, `RAMRDOFF = $C003`). Every routine that
   called `STA RAMRDOFF` (`CMP512`, `BUILD_ZEROS`, `SD_WRITE_SECTOR`) actually switched the
   6502 to fetch instructions from uninitialized AUX RAM (holding `$00`), immediately executing
   an actual `BRK` instruction at `$2901`, `$291E`, or `$2924`. Monitor broke with `*2924-` /
   `*291E-` (seen by user as `?91e` / `?901` due to the flashing cursor over the first digit).
   **Fixed**: `RAMRDOFF = $C002`, `RAMRDON = $C003`.
7. **`V_ZEROMODE` bank leak in `MM_FORMAT`.** `SHOW_CHOICES` left `RAMWRT` on AUX.
   `MM_FORMAT` stored `$00` to `V_ZEROMODE` into AUX RAM, leaving MAIN RAM holding random
   non-zero bytes. This caused `REQUIRE_CONFIRM` to display "Wipes card" and `RF_STAGE0` to
   trigger stage 0 (zeroing card) instead of quick formatting.
   **Fixed**: added `STA RAMWRTOFF` before `STA V_ZEROMODE` in `MM_FORMAT`.
8. **`SHOW_LAYOUT` pointer high bytes and `REQUIRE_CONFIRM` input cleanup.**
   `SHOW_LAYOUT` did 32-bit math (`V_PART + V_PSIZE - 1`) without setting `ZP_PTR2HI`/`ZP_PTR3HI`
   to page `$94`, resulting in reading garbage pages and calculating "768" instead of "204799".
   Fixed: `SHOW_LAYOUT` now pins `ZP_PTR2HI`/`ZP_PTR3HI` to page `$94` and enforces `RAMWRTOFF`.
   `REQUIRE_CONFIRM` now also clears `ZP_IBUF` with zeroes and pads with 8 spaces to prevent
   residual `@` character artifacts.
9. **`RF_SHOW_LABEL` printed every stage label at the current cursor — all labels
   piled onto the row-17 progress line.** `STAGE_WRITE`'s `SHOW_PROGRESS` does
   `GOTO_ROW 17` and leaves the cursor at the end of the progress line, so the
   next stage's `RF_SHOW_LABEL` appended `  01. boot sector` … `  06. FAT 1,
   free space` onto that same row instead of each going on its own line. The
   screen looked like `164% sectors 160/ 783 06. FAT 1, free space` — the stage
   numbers interleaved with the percent via the 80-col AUX/MAIN interleave
   (read as `>100%`) and the labels run together (`spaceor`). Only the first
   label (MBR) ever sat on its own row. **Fixed**: `RF_SHOW_LABEL` now
   `GOTO_ROW (1 + V_STAGE)` before printing (GOTO_ROW clobbers `ZP_TEMP2`, so
   it runs *before* X is parked), giving each stage its own row 1..12.
10. **`V_VERERR` was a 1-byte counter printed as a 32-bit value — the count was
    garbage.** `V_VERERR = VARS+$37` sat directly before `V_CSDV2`/`V_SDSCBA`/
    `V_STAGE` (`+$38`/`+$39`/`+$3A`), and `SHOW_RESULT` printed it via
    `PRINT_DEC32W` (reads 4 bytes) while only byte 0 was zeroed/incremented.
    The high three bytes were live/garbage, so the reported error count was a
    random number (observed `FAIL - 535 errors`) instead of the true 0..8.
    **Fixed**: `V_VERERR` now owns 4 dedicated bytes (`$37-$3A`), `V_STAGE`/
    `V_RETRY` moved to `+$3B`/`+$3C`, the dead `V_CSDV2`/`V_SDSCBA` removed,
    and `VERIFY_ALL` zeroes `V_VERERR..+3`. Same class of bug as lesson 2 —
    a 32-bit print reading a value that overlaps unrelated state.
11. **`V_PCT` high bytes never zeroed.** `RF_ARM_PROGRESS` zeroed only
    `V_PCT`/`V_PCT+1` but `PRINT_DEC32W` reads 4 bytes, so `V_PCT+2`/`+3`
    leaked stale RAM into the printed percent. **Fixed**: zero `V_PCT..+3`.

## Current state

- **Working:**
  - VERA Slot auto-detection (Slot 2 `$C200`, Slot 4 `$C400`).
  - SD SPI bus initialization (CMD0, CMD8, CMD55, ACMD41, CMD16).
  - Accurate capacity detection via CMD9/CSD (204800 sectors / 100 MiB for test card).
  - Clean initial information screen: displays VERA slot, SPI clock, capacity, existing volume probe (MBR + VBR), and proposed FAT32 layout geometry.
  - Main menu: [1] Catalog SD, [2] Format SD, [3] Verify SD, [0] Exit.
  - Format confirmation screen: requires typing `FORMAT` + `RETURN`, `ESC` cancels.
  - FAT32 formatting engine: stage-table-driven generation of MBR (type $0C starting LBA 2048), VBR, FSInfo, backup sectors, FAT #1, FAT #2, and root directory cluster.
  - Verification engine: reads back metadata sectors via CMD17 and performs 512-byte comparison against templates.
  - Clean ProDOS return: restores zero-page `$50-$7F`, IRQ vector, returns to 40-col, HOME clears screen.
- **Recent fixes:**
  - Fixed softswitch inversion: `RAMRDOFF = $C002`, `RAMRDON = $C003`. Solved BRK crash (`*2901-`, `*291E-`, `*2924-`) during Format and Verify.
  - Fixed `V_ZEROMODE` RAMWRT bank leak in `MM_FORMAT`: ensures Option 2 defaults to quick format instead of zeroing card.
  - Fixed ending LBA calculation in `SHOW_LAYOUT` (`2048 - 204799`).
  - Fixed `@@@` ghost characters in confirmation prompt.
  - Fixed stage labels piling onto the progress row: `RF_SHOW_LABEL` now
    `GOTO_ROW (3 + V_STAGE)` so each stage (MBR / boot sector / FSInfo / FAT /
    root) sits on its own line below the title and progress heading.
  - Fixed garbage verify count: `V_VERERR` is a proper 4-byte counter (no
    longer overlapping `V_STAGE`/`V_RETRY`), and `V_PCT` high bytes are zeroed.
- **Working now:**
  - Catalog SD lists root 8.3 names, volume labels, directories, and file sizes.
  - Format clears the complete root directory cluster and verifies fixed FAT32 metadata.
  - FAT free-space and root-padding stages use CMD25 multi-block writes.
  - Format and Verify screens retain the title, separate stage rows, and wait for a key at the result.

## Test workflow

- Registry: `HKCU\Software\AppleWin\Configuration\Slot 2\SD Card Image` =
  `C:\dev\a2vera\sdcard.img` (104857600 bytes, MBR sig $55AA, part type $0C).
- Launch: `C:\dev\AppleWin\Release\AppleWin.exe -s2 vera -d1
  C:\dev\verasdedit\verasdformat.po -power-on`
- `verasdformat.png` is the tracked README screenshot; other emulator screenshots
  remain local test artifacts and are excluded by `.gitignore`. Do not add
  capture scripts or unrelated generated screenshots to the repository.
- **User requirement: `Stop-Process -Name AppleWin -Force` BEFORE each relaunch
  and AFTER the final screenshot** (duplicate instances cause problems).
- Close AppleWin before rebuilding `.po` (file lock). Never use `&&` in pwsh.
- The 80-col display interleaves AUX/MAIN per column — some on-screen garbling
  is expected; clean values (e.g. "00040C00") prove the pipeline works for
  those parts.
- **SPI ground truth via `-log`** (the primary verification channel now):
  launch AppleWin with an extra `-log` flag — Release builds then write every
  SPI transfer to `C:\dev\AppleWin\Release\VERA.log` (`VERASD SPI read -> $XX`
  / `VERASD SPI write $XX (selected=1 busy=0)`). Delete the log before a run;
  find the CMD9 frame with `Select-String 'write \$49'` and read the following
  `read ->` lines in order (21 reads = the CSD). This is how the CSD stream
  was verified byte-for-byte.
- Local screenshots can be inspected with the available image-viewing tool;
  use `VERA.log` (above) as the ground truth for SPI transfers.

## User context

Communicates in Traditional Chinese — reply in TC. Explicitly told to reference
`src/verasdedit/verasdedit.asm` (total sectors) and `a2vera/sd_diag.asm` (FAT32 root dir +
sector reads) instead of self-debugging, and that 8-bit→32-bit FAT32 math must
be handled carefully ("要用8-bit去算32-bit的fat32不容易").

## VeraSD FAT32 native client

Status recorded 2026-09-27: first functional standalone client is built and
tested. FAT32 support as a ProDOS-accessible filesystem is not finished.

- This project lives at `src/verasd-fat32/`. It is separate from the ProDOS raw block driver in `C:\dev\a2vera` and does not turn FAT32 into a ProDOS block volume.
- Source files moved from `C:\dev\a2vera\verasd` into `src/verasd-fat32/`. The generated `VeraSD-IFS-FAT32.po` and disposable `VeraSD-IFS-FAT32.img` live in the repository root. The runtime build uses this repository's `src/asm6502.mjs`, `assets/ProDOS_2_4_3.po`, and vendored FAT/SD source modules. Do not add a build-time dependency on the a2vera checkout.
- Build: `node src/verasd-fat32/fat32-build.mjs` or `build.bat fat32`. Test: `python src/verasd-fat32/test_fat32.py` / `npm run test:fat32`. Independent image extraction: `python src/verasd-fat32/check_fat32_image.py` (optional Python package `pyfatfs`).
- `python src/verasd-fat32/fat32-fixture.py` creates the repository-root 128 MiB `VeraSD-IFS-FAT32.img` only if absent. It deliberately refuses to overwrite an existing file. Never use reset/format commands against this image without preserving evidence; this is a disposable test volume, not the user's physical SD image.
- Implemented in `FAT32.SYSTEM`: standalone BRUN app, root 8.3 catalog, file read, and overwrite of preallocated 1024-byte TESTNOW.BIN. It does not register a ProDOS block/MLI device.
- The boot disk includes a compiled `STARTUP` BAS guide; keep `BASIC.SYSTEM` first and `STARTUP` second in the catalog. The app title is `VeraSD FAT32 Native File Client v1.03`, followed by `by anomixer 2026` and a blank line.
- Remaining: create files; allocate/free clusters; append and resize; delete and rename; update FAT copies, FSInfo and directory metadata; subdirectories and LFN; file exchange with ProDOS; and a defined MLI interface so BASIC can access FAT32. Copy II Plus directly parses ProDOS block structures, so it will not understand FAT32 unless it has an explicit FAT32-aware integration.
- The tested image has fragmented HIGH.BIN and TESTNOW.BIN beyond 32 MiB. AppleWin reads and writes them; host byte comparison and `pyfatfs` extraction verify content and matching FAT copies. `test_fat32.py` has 25 assembled-client cases. ProDOS regression scripts stay in a2vera and should also pass when the shared source is changed.
- AppleWin Slot 2 SD image and Slot 6 boot disk were updated to the moved paths under this repository. The emulator was stopped after validation as required by the AppleWin test workflow.
- Generated `.bin`, labels, expanded assembly, root-level `.po`, and root-level `.img` are ignored build/test outputs. Edit source `.asm`, `.mjs`, and vendored `.inc` modules. Keep README/AGENTS status clear that this is a first functional stage, not a complete FAT32 IFS.

## VeraSD ProDOS 8 driver

- ProDOS source project moved from `C:\dev\a2vera\verasd` to `src/verasd-prodos/`, including assembly, build scripts and simulator tests. Generated `VeraSD-IFS-ProDOS.po` and `VeraSD-IFS-ProDOS.img` live in the repository root. Keep ProDOS and FAT32 source products in separate directories.
- Build: `node src/verasd-prodos/verasd.mjs`, `build.bat prodos`, or `npm run build:prodos`. Regressions: `npm run test:prodos`. Paths use this repository's `src/asm6502.mjs` and `assets/ProDOS_2_4_3.po`.
- Boot image: project-root `VeraSD-IFS-ProDOS.po`. Raw 32 MiB SD image: project-root `VeraSD-IFS-ProDOS.img`, exposing 65,535 blocks. Build preserves existing image contents; `--reset-sd` deletes files. Never reset user data.
- ProDOS/FAT32 boot disk volume names are `VERASDIFSPRODOS` and `VERASDIFSFAT32`, written in uppercase by each `.po` builder.
- ProDOS disk builders stamp only their generated files' creation and modification date/time from the local build clock. Preserve timestamps on base files such as `BASIC.SYSTEM` and `PRODOS`.
- Architecture: language-card bank 2 body `$D400`, common bridge `$FF00`; ProDOS interrupt code at `$FF9B+` stays intact. Installation removes native `/RAM` from the ProDOS device list.
- Validated: 19 assembled-driver cases, installer initialization/rollback cases, IRQ vector check, AppleWin CATALOG with 65,535 blocks, and Copy II Plus 8.4 catalog/copy after BYE. Real SD hardware and physical AppleWin high-block writes remain untested.
- This block driver does not implement FAT32. Use `src/verasd-fat32/` for the separate native FAT32 client and its documented scope.

### VERASD.SYSTEM (type $FF, ProDOS SYS)

- `verasd_sys.asm` builds `VERASD.SYSTEM` (type `$FF`, aux `$2000`). `verasd.mjs` is the canonical builder and must assemble this SYS entry point so launchers such as Bitsy Bye can execute it.
- The boot disk also contains `VERASD.BIN` (type `$06`, aux `$2000`), assembled from `verasd.asm`. This BRUN entry returns to Applesoft BASIC after installing the resident driver.
- The boot disk contains `STARTUP` (type `$FC`, aux `$0801`), compiled from `src/verasd-prodos/startup.bas`; BASIC.SYSTEM auto-runs it. STARTUP detects VERA in slot 2/4, runs `BRUN VERASD.BIN` to initialize and bring the SD volume online, then shows the menu for `CATALOG,S2/S4` or `-DESKTOP.SYSTEM,S2/S4`. Keep BASIC.SYSTEM first and STARTUP second in the volume catalog.
- The BRUN installer writes `$A5` to `$1FF0` only after successful device registration and `ON_LINE`. STARTUP clears and checks this marker to report SD detection; if the unit is already listed, it skips duplicate installation. Keep the marker address/value synchronized between `verasd.asm` and `startup.bas` (`$1FF0` / decimal `8176`, `$A5` / decimal `165`).
- Exit path: MLI QUIT (`$65`) with param block `count=4, 4 bytes zero` at `$3420`. This is the standard SYS-file exit (same as `QUIT.SYSTEM`).
- After printing the result, the SYS entry waits about one second before calling MLI QUIT so the message remains visible in Bitsy Bye.
- BRUN path also works: the legacy installer detects VERA and SD, copies/registers the driver, writes the STARTUP success marker, then returns to BASIC with `RTS`.
- `verasd.asm` is the BRUN entry and ends with `RTS`; package it only as type `$06`, never as type `$FF`. Returning with RTS from a SYS launched by Bitsy Bye has no valid return address and falls through to `$0002 BRK`.
- Key lesson: `QUIT.SYSTEM` uses `JSR $BF00 / !byte $65 / !word param_block` where param block = `04 00 00 00 00` (count=4 + 4 reserved bytes).
