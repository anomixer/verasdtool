# VeraSD-IFS-FAT32 — first working stage

This build provides a native Apple II FAT32 file client booted from ProDOS.
It mounts a 128 MiB test SD volume, catalogs short names, reads files, and
overwrites a preallocated 1,024-byte test file. SD sector addresses and file
sizes use 32 bits. It is not yet a resident ProDOS MLI filesystem adapter.

## Build and run

```powershell
node src/verasd-fat32/fat32-build.mjs
python src/verasd-fat32/fat32-fixture.py
python src/verasd-fat32/test_fat32.py
```

The build writes `VeraSD-IFS-FAT32.po` to the project root with ProDOS volume
name `VERASDIFSFAT32`. The fixture command
creates the root-level `VeraSD-IFS-FAT32.img` only when absent; it refuses to
replace existing data. The checker reads that same image. It is a disposable raw FAT32 volume, 128 MiB,
512-byte sectors, two FATs and one sector per cluster. The read and write test
files have fragmented cluster chains located beyond the first 32 MiB.

Boot `VeraSD-IFS-FAT32.po` with that VERA SD image, then:

```text
BRUN FAT32.SYSTEM
```

The ProDOS `STARTUP` BAS file introduces `FAT32.SYSTEM` and its commands. The
FAT32 client screen shows `VeraSD FAT32 Native File Client v1.03`, followed by
`by anomixer 2026` and a blank line.

Commands:

- **C**: list root directory short names.
- **R**: enter an uppercase 8.3 filename, e.g. `HIGH.BIN`; stream the file,
  display its size, first eight bytes and sum16 checksum.
- **W**, then **Y**: overwrite existing `TESTNOW.BIN` with 1,024 bytes of the
  pattern 00–FF repeated four times. Other sizes and read-only files are refused.
- **Q**: return to BASIC.

The program detects VERA in slot 2 or 4. It runs at $2000 and owns its main
memory while active; launch it from a fresh BASIC session. It does not register
a ProDOS disk device, and ordinary BASIC CATALOG or Copy II Plus cannot use it
as a FAT32 drive. BYE leaves this standalone client, unlike the resident ProDOS
block driver.

## Implementation

`fat32.asm` contains the client, BPB/partition validation, checked raw-sector
interface, root listing and read/write commands. `fat32-build.mjs` assembles
the vendored `sd-protocol.inc`, `fat-filesystem-core.inc` and
`fat-filesystem-data.inc` modules into an independent binary. Generated
`fat32.generated.asm` and `fat32.labels.json` are useful for debugging; edit
the sources rather than the generated assembly.

The 512-byte sector read loop stores directly into its RAM buffer and polls SPI
inline, while preserving the caller's X register and the bounded BUSY timeout.
The SPI clock is unchanged. The effect on catalog and file-read time has not
yet been measured on hardware.

Supported mount layouts: raw FAT32 or the first FAT32 MBR partition, 512-byte
sectors, one or two FAT copies, power-of-two cluster sizes below 128 sectors.
An explicitly active FAT is honored. Bounds, bad clusters, truncated chains,
cyclic chains and SPI failures produce errors. Cycle detection uses constant
storage and does not impose a 32MB file limit.

The initial write operation modifies existing file data only. It does not yet
allocate clusters, change size, update timestamps, create/delete files, handle
subdirectories or long filenames, or copy files between ProDOS and FAT32.
Those remain implementation stages in `FAT32-PLAN.md`. Real SD hardware and
complete reads of files larger than 16 MiB remain untested.

## Verified results (2026-09-27)

- 25 assembled-client tests: raw/MBR layouts, SDHC/SDSC, cluster sizes 1/2,
  fragmented read/write beyond 32 MiB, invalid BPB, volume bounds, interactive
  commands, corrupt/cyclic/truncated chains, and write rejection.
- AppleWin: mounts 262,144 sectors; C lists HELLO.TXT, HIGH.BIN, TESTNOW.BIN.
- Reads HIGH.BIN: size $00000400, first bytes 00–07, sum16 $FE00.
- Writes TESTNOW.BIN to LBAs 94,126 and 94,131; reads back with the same size,
  first bytes and checksum. Host extraction compares all 1,024 bytes exactly.
- Independent `pyfatfs` extraction verifies both files and identical FAT copies:
`python src/verasd-fat32/check_fat32_image.py` (requires `pip install pyfatfs`). This
  checks file content and FAT mirrors; it is not a full filesystem repair scan.
- Existing ProDOS driver/installer tests remain passing (24 cases).

Generated AppleWin screenshots were removed during workspace cleanup. The
build, assembled-client tests and image checker can reproduce the verification.
AppleWin's VERA SD image and slot-6 boot image are configured for the FAT32
test product; switch both to use the ProDOS product.
