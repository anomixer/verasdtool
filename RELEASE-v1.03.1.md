# v1.03.1 — Apple2TS ProDOS mount and FAT32 geometry fixes

Bugfix rebuild of the v1.03 disk images. The in-app version labels remain
**v1.03**; this release only replaces the affected `verasdformat.po` and
`VeraSD-IFS-ProDOS.po` images and republishes the complete set.

## What changed

### VeraSD-IFS-ProDOS now mounts on Apple2TS

Apple2TS exposes a ProDOS slot-2 device entry (`$2D`) before the resident
VERA driver is installed. The old installer treated that entry as a duplicate
slot and refused to install. The driver now replaces the matching slot entry
with the VERA unit (`$20`) and restores the previous entry and vector if
`ON_LINE` fails. `STARTUP` also always installs the driver before checking SD
availability.

Verified in Apple2TS: `VERASD INSTALLED`, `SD Card Detected`, and
`CATALOG SD Card` work. AppleWin still works.

### VeraSDFormat: 128 MB no longer reports "too small"

The fixed-point FAT-size loop accepted the smaller value during convergence.
It now accepts the larger value and recomputes the cluster count and data
start. A 128 MB card gets `FATSz=1016`, `SPC=2`, `RSVD=32`, `Clusters=129016`,
`DataLBA=4112`.

### Corrected reserved-sector geometry

The formatter's `K_32` constant held decimal 20 instead of the 32 reserved
sectors written in the BPB. This made the layout and FSInfo internally
inconsistent: a 128 MB card showed `129872` clusters, data at LBA `4100`, and
`129021` free clusters. It now uses 32, producing `129016` clusters, data at
LBA `4112`, and `129015` free clusters. The same fix corrects the 100 MB
layout to `100568` clusters at LBA `3664` and `100567` free clusters.

## Downloads

- `verasdedit.po` — VeraSDEdit hex sector editor (unchanged in this rebuild).
- `verasdformat.po` — **updated** FAT32 formatter.
- `VeraSD-IFS-ProDOS.po` — **updated** resident ProDOS block driver.
- `VeraSD-IFS-FAT32.po` — standalone FAT32 file client (unchanged).
- `VeraSD-IFS-ProDOS.img.zip` — optional 32 MiB ProDOS/A2Desktop test volume.
- `VeraSD-IFS-FAT32.img.zip` — optional 128 MiB FAT32 fixture.

The two `.img.zip` files are SD volumes to mount alongside the corresponding
boot disk; they are not boot disks.

## Verification

- `test:prodos`: 20 driver cases and 4 installer cases pass, including
  third-party driver refusal.
- `test:fat32`: 25 cases pass.
- Apple2TS: ProDOS catalog works; 100 MB and 128 MB formats pass with matching
  BPB, FSInfo, and root-directory placement.
- AppleWin: ProDOS catalog works; 128 MB format passes with the same BPB and
  FSInfo. AppleWin did not show the "too small" message, but the old build
  also wrote an inconsistent FSInfo/layout on 128 MB.

## Upgrade notes

Replace the boot disk(s) you use and reboot so a resident driver is reloaded.
Formatting a card erases its contents; back up anything you need first. Cards
formatted with an earlier formatter build should be reformatted.

## Asset SHA-256

```text
97fa11194cff66dc6f4f845cd37224ca4691ebcba362296bbc4959d1ed8c268b  verasdedit.po
ef2489082bb98a31fdf1d1db09fe1337728f3bd195c80129ad142dd3beaaff8b  verasdformat.po
75e6fc21b5f79aa050b56779b755e9978c53544476cedabc9008c3da95577379  VeraSD-IFS-ProDOS.po
0d62193ff65a7ee4e450ca86a2924306e3d89237e799cbbf9690e95b39ba6740  VeraSD-IFS-FAT32.po
9fedbcb5e8df8519964df3fb0c3733024058a701b0d9dae5f627d127cf89eae5  VeraSD-IFS-ProDOS.img.zip
2f2401c372757067fdb919f1fc6e588ff787689f9049110e985762338af7e520  VeraSD-IFS-FAT32.img.zip
```
