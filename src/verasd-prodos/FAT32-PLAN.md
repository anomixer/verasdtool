# VeraSD-IFS-FAT32.po design plan

Status: first native client implemented; see
[`../verasd-fat32/FAT32-README.md`](../verasd-fat32/FAT32-README.md) for tested capabilities and remaining work. Mount, root catalog, file streaming
and preallocated-file overwrite work in AppleWin on a 128 MiB FAT32 image.
Allocation, general file creation/deletion and resident MLI integration remain
planned.

## Product boundary

VeraSD-IFS-ProDOS.po exposes raw ProDOS blocks. ProDOS cannot interpret FAT32 merely by replacing its block driver. VeraSD-IFS-FAT32.po needs a FAT32 filesystem implementation and its own file interface.

Recommended first delivery: a ProDOS-bootable FAT32 browser and file-copy utility with a native 32-bit file API. This can use SD volumes larger than 32 MiB and exchange files with ordinary ProDOS devices. An optional later MLI adapter can support a defined subset of BASIC.SYSTEM file operations.

Unmodified Copy II Plus accesses ProDOS directory blocks directly. An MLI adapter cannot make those operations interpret FAT32 or remove their block-address limit. A synthetic ProDOS block view would retain the 32MB limit and is not the proposed solution.

## Implementation stages

1. Extract the proven bounded SPI/SD backend. Use full 32-bit sector numbers and separate physical capacity from filesystem capacity. Support SDHC and checked SDSC byte-address conversion.
2. Mount a FAT32 superfloppy or one explicitly selected MBR FAT32 partition. Validate BPB, sector size, reserved area, FAT count, active FAT, root cluster, cluster size, and all computed boundaries. Begin with 512-byte sectors; reject unsupported layouts. GPT is deferred.
3. Implement directory traversal, short 8.3 names, cluster-chain lookup and sector caching. Read files first; reject malformed or cyclic chains and reserved/out-of-volume cluster references.
4. Add create, overwrite, append, rename, delete and subdirectories. Respect FAT mirroring/active-FAT flags, maintain allocation metadata and FSInfo, flush data before publishing final directory sizes, and report short writes accurately. FAT32 is not journaled: interruption recovery must be tested.
5. Deliver the browser/copy utility on VeraSD-IFS-FAT32.po. Display FAT32 capacity and file sizes using 32-bit values.
6. Add an optional MLI adapter only after the native API is stable. Define supported calls, path aliases, metadata mapping, open-file state and error mapping. ProDOS MLI EOF fields are 24-bit; files at or above 16 MiB need the native API rather than pretending standard ProDOS calls represent them.

Long filenames are a later extension; the first version presents existing short aliases and creates 8.3 names. Apple II file types/auxiliary addresses need an explicit metadata convention when copied to FAT32.

## Memory and lifecycle

The FAT32 engine will not fit the current small bank-2 block-driver area. Budget code, caches and open-file records before assembly: consider auxiliary memory with a small common-memory bridge, keeping ProDOS kernel, selector, IRQ and application memory safe. Specify installation, BYE behavior and re-entry explicitly. A standalone browser avoids promising residency under every third-party application.

## Automated acceptance

Use disposable FAT32 test images, never reformat the repository's sd.img/sdcard.img or user SD images. Test both raw FAT32 and MBR layouts, multiple cluster sizes, a volume larger than 32 MiB, fragmented files, directories and files crossing cluster/sector boundaries. Compare extracted bytes against host-generated patterns.

For the native API, test files larger than 16 MiB and data beyond the first 32 MiB of the volume. Validate create/append/delete and allocation consistency with an independent FAT32 checker. Inject read/write failures and interrupted updates; verify explicit errors and recoverable on-disk state. Finally run browser/copy workflows in the VERA AppleWin fork and test real SD hardware.

ProDOS product regression must continue to pass independently. Shared SD code does not imply shared filesystem limits.
