# VeraSD-IFS-ProDOS

Build: `node src/verasd-prodos/verasd.mjs` or `npm run build:prodos`. The boot disk `VeraSD-IFS-ProDOS.po` is written to the project root.

Boot the project-root `VeraSD-IFS-ProDOS.po`, configure the VERA SD image as the project-root `VeraSD-IFS-ProDOS.img`, then enter:

```text
BRUN VERASD.SYSTEM
CATALOG /VERASD
```

The installer is a BIN file despite its .SYSTEM suffix. VERA slots 2 and 4 are detected.

The new SD image is a raw 32 MiB ProDOS image, equivalent to a raw ProDOS HDV. Its volume has 65,535 blocks (512 bytes each); block 65,535 and any extra physical capacity are inaccessible. Existing raw ProDOS volumes use the block count from their volume header. MBR/GPT partitions and FAT32 are not supported by this product.

The build preserves an existing SD image. `node src/verasd-prodos/verasd.mjs --reset-sd` explicitly recreates it and deletes its files: close AppleWin before doing this.

## Residency

The driver body lives in language-card bank 2 at $D400. A common-memory bridge at $FF00 switches banks and accesses ProDOS buffers in bank 1. The native /RAM device is removed from the device list because the bridge replaces its driver; auxiliary /RAM data itself is not erased. The installer refuses an unexpected /RAM driver vector. Interrupt code at $FF9B and above is preserved.

This replaces the former $9000 implementation, which Copy II Plus overwrote after BYE. No BASIC memory reservation is needed. BYE does not uninstall this driver. Reboot restores the ordinary ProDOS environment; reinstallation in the same session is not supported.

SDHC block addressing and SDSC byte addressing are supported. SPI runs at the slow setting, with bounded response and busy waits. Driver status reports the ProDOS volume size; out-of-range access is rejected before sending an SD command. This is a resident ProDOS block driver, not a FAT32 filesystem translator.

## Validation

`npm run test:prodos` (or `python src/verasd-prodos/test_driver.py` and `python src/verasd-prodos/test_install.py`): 19 assembled-driver cases and five installer cases covering bank-1 buffers, SDHC/SDSC addressing, block bounds, errors, status, stack, zero page, interrupt and decimal flags, missing VERA, rollback, and third-party RAM-vector refusal.

AppleWin ProDOS 2.4.3: installation and CATALOG show 65,535 blocks. After BYE, Copy II Plus 8.4 from slot 6 drive 2 catalogs slot 2 drive 1 and copies VERASD.SYSTEM from the boot disk to SD. Host-side extraction verifies all 2,392 bytes match verasd.bin. Real SD hardware has not been tested.

FAT32 is maintained in the sibling tool repository at
[`../verasd-fat32/FAT32-README.md`](../verasd-fat32/FAT32-README.md); the
original design notes remain in [FAT32-PLAN.md](FAT32-PLAN.md).
