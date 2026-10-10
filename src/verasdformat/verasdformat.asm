; =============================================================================
; VERASDFORMAT - FAT32 QUICK FORMATTER for the VERA SD/MMC slot (Apple II)
; =============================================================================
; Companion to VeraSDEdit. Where VeraSDEdit looks at one sector at a time,
; this writes a complete, mountable FAT32 volume over whatever the SD/MMC slot
; of the VERA card holds:
;
;     MBR (LBA 0) + VBR (boot sector) + FSInfo + backup VBR + backup FSInfo
;     + FAT #1 and FAT #2 (every sector written, so no orphan of the old file
;     system stays reachable) + the root directory cluster
;
; FIELD VALUES are copied from volumes that Commander X16 CMDR-DOS and the
; A2VERA 6502 FAT32 reader mount happily: OEM "CMDR-DOS", media $F8, 32
; reserved sectors, 2 FATs, root cluster 2, FSInfo sector 1, backup VBR
; sector 6, "FAT32   " at $52, MBR partition type $0C starting at LBA 2048.
; The per-FAT size is derived the way CMDR-DOS's own formatter does it (round
; the needed size up to a multiple of 8 sectors), which reproduces the
; reference card exactly - 792 sectors per FAT, 100568 clusters on a 100 MB
; image. README.md carries the byte-by-byte comparison.
;
; KEYS
;   [F] format            quick format, about a minute on a 100 MB image
;   [Z] zero then format  write $00 to EVERY sector of the card first. This
;                         really does destroy the old data and it is slow,
;                         roughly a minute per 1.4 MB on a 1.02 MHz Apple II
;   [Q] quit              leave without touching the card
;
; Nothing is written until the word FORMAT has been typed, and afterwards the
; tool re-reads every metadata sector and byte-compares it with what it wrote,
; so the closing PASS means the card really holds the new layout.
;
; SPI CLOCK (real A2VERA hardware). SPI_CTRL (base+$1F) bit1 picks the transfer
; clock: 1 = about 390 kHz, 0 = 12.5 MHz. Formatting runs on the slow clock by
; default: on a 1.02 MHz Apple II the 6502 is the bottleneck either way, so
; slow costs little, and on real hardware slow is the setting that works in
; every slot. BUSY polling is bounded and a timeout is sticky.
;
; ASSEMBLER NOTES (the vendored asm6502.mjs is quirky - see AGENTS.md):
;   no indexed AND/ORA/EOR, no CMP with an indexed operand, no indexed
;   LDX/LDY, no (zp,X) addressing, and forward branches are range-checked at
;   +/-127, so long hops must be written as JMP. Offsets in expressions have to
;   be hex (LABEL+$1BE): the addend is parsed with parseInt without a radix,
;   so LABEL+30 would mean decimal 30.
;
; ProDOS binary: VERASDFORMAT (type $06, load $2000), launched with BRUN.
; =============================================================================

* = $2000

; -----------------------------------------------------------------------------
; Zero page. Everything lives in $50-$7F, is saved to ZPBACKUP on entry and
; restored on exit, so ProDOS and Applesoft pick up exactly where they were.
; -----------------------------------------------------------------------------
ZP_LBA0      = $50          ; LBA of the current SD command, LSB..MSB
ZP_LBA1      = $51
ZP_LBA2      = $52
ZP_LBA3      = $53
ZP_SDCLK     = $54          ; SPI_CTRL bits (bit0 CS set, bit1 = clock select)
ZP_COL       = $55          ; 80-column cursor column, 0-79
ZP_PTR       = $56          ; string pointer low
ZP_PTRHI     = $57          ; string pointer high
ZP_CURSOR    = $58          ; screen row base address low
ZP_CURSORHI  = $59
ZP_TEMP      = $5A
ZP_TEMP2     = $5B
ZP_ROW       = $5C          ; text row the cursor is on, 0-23
ZP_STGIDX    = $5D          ; preserved stage table index X
ZP_KEY       = $60
ZP_DISPMODE  = $61          ; PUTCH mode: 0 normal, 1 inverse, 2 flash
ZP_IBUF      = $62          ; confirmation-word input, 10 bytes ($62-$6B)
ZP_IBUFLEN   = $6C
ZP_VERALO    = $6D          ; detected VERA base low byte (always $00)
ZP_VERAHI    = $6E          ; $C2 (slot 2) or $C4 (slot 4)
ZP_SPIDATLO  = $6F          ; SPI DATA register address (base+$1E)
ZP_SPIDATHI  = $70
ZP_SPISTLO   = $71          ; SPI STATUS register address (base+$1F)
ZP_SPISTHI   = $72
ZP_IRQLO     = $73          ; saved IRQ vector
ZP_IRQHI     = $74
ZP_ERR       = $75          ; non-zero = SD error
ZP_ABORT     = $76          ; non-zero = user pressed ESC
ZP_SPIFLT    = $77          ; sticky SPI BUSY timeout (bit7)
ZP_PTR2      = $78          ; 32-bit operand pointer A (destination)
ZP_PTR2HI    = $79
ZP_PTR3      = $7A          ; 32-bit operand pointer B (source)
ZP_PTR3HI    = $7B
ZP_SCR0      = $7C          ; scratch for the 32-bit helpers
ZP_SCR1      = $7D
ZP_SCR2      = $7E
ZP_SCR3      = $7F
ZP_CRC       = $5D          ; CRC byte for the next SD command frame
ZP_BUFLO     = $5E          ; indirect SD buffer address, low byte (always $00)
ZP_BUFPG     = $5F          ; ...and high byte: $80 = WRKBUF, $82 = TMPBUF

; -----------------------------------------------------------------------------
; Page-2 storage. Every 32-bit value is little-endian.
; The code occupies $2000-$7FFF.  The formatter has the full 48K Apple II
; RAM available, so sector buffers and scratch live high in RAM ($8000-$95FF)
; instead of constraining the program to a needlessly tiny 8K window.
; -----------------------------------------------------------------------------
ZPBACKUP     = $9400        ; 48 bytes: ZP $50-$7F

; VARS must keep every ZP_PTR2-accessed variable on ONE page: VARS+$30 is the
; highest one (V_TMP4), so VARS = $9450 keeps VARS..VARS+$30 on page $94.
VARS         = $9450
V_TOTAL      = VARS         ; card capacity in 512-byte sectors (from the CSD)
V_CSIZE      = VARS+4       ; raw C_SIZE field of the CSD
V_PART       = VARS+8       ; partition start LBA
V_PSIZE      = VARS+$0C     ; partition size in sectors
V_FATSZ      = VARS+$10     ; sectors per FAT (BPB_FATSz32)
V_CLUST      = VARS+$14     ; number of data clusters
V_DATA       = VARS+$18     ; data area start, volume-relative
V_ARG        = VARS+$1C     ; SD command argument, MSB first (V_ARG0..V_ARG3)
V_REM        = VARS+$20     ; DIV32 remainder
V_TMP1       = VARS+$24     ; DIV32 dividend/quotient, general scratch
V_TMP2       = VARS+$28     ; DIV32 divisor
V_TMP3       = VARS+$2C     ; general scratch
V_TMP4       = VARS+$30     ; general scratch, survives DIV32
V_SPC        = VARS+$34     ; sectors per cluster (1, 2, 8, 16, 32 or 64)
V_SPCSH      = VARS+$35     ; log2(V_SPC)
V_ZEROMODE   = VARS+$36     ; $01 = overwrite the whole card with $00 first
V_VERERR     = VARS+$37     ; verify: number of sectors that did not match (4 bytes)
V_STAGE      = VARS+$3B     ; stage number, shown on the stage line
V_RETRY      = VARS+$3C     ; retry counter for the SD init commands
V_DONE       = VARS+$40     ; progress: sectors written in this stage
V_PCTTOT     = VARS+$44     ; progress: sectors in this stage
V_PCTSTEP    = VARS+$48     ; progress: width of one percent, in sectors
V_PCTNEXT    = VARS+$4C     ; progress: count where the next percent lands
V_PCT        = VARS+$50     ; progress: last percent printed
V_DIGBUF     = VARS+$58     ; 12 bytes: digits while printing decimal
MATHSB       = $94B8        ; 4 bytes: byte-wise scratch for the 32-bit helpers

; CATALOG SD workspace - reads an existing FAT32 volume and lists the root
; directory. All of it lives on page $44.
CA_FATBG     = $94C0        ; FAT32: first FAT LBA (4 bytes LE)
CA_CLUSBG    = $94C4        ; FAT32: first data cluster LBA (4)
CA_ROOTC     = $94C8        ; FAT32: root directory cluster (4)
CA_CURC      = $94CC        ; cluster being walked (4)
CA_CURLBA    = $94D0        ; LBA of that cluster (4)
CA_SECTS     = $94D4        ; sectors left in the current cluster (1)
CA_WANT      = $94D5        ; wanted FAT sector LBA (4)
CA_TMP       = $94D9        ; generic 32-bit scratch (4)
CA_FSZ       = $94DD        ; file size (4)
CA_SPC       = $94E1        ; sectors per cluster (1)
CA_ENTRY     = $94E2        ; current directory entry (2)

WRKBUF       = $8000        ; 512-byte sector image that gets written
TMPBUF       = $8200        ; 512-byte sector read back for verification
FMTBUF       = $8400        ; formatter staging space through $93FF

; -----------------------------------------------------------------------------
; FAT32 layout constants - what the reference volumes carry
; -----------------------------------------------------------------------------
PART_LBA     = 2048         ; partition start (1 MB aligned)
RSVD_SECS    = 32           ; BPB_ResvdSecCnt
NUM_FATS     = 2            ; BPB_NumFATs
ROOT_CLUS    = 2            ; BPB_RootClus
FSINFO_SEC   = 1            ; BPB_FSInfo
BKVBR_SEC    = 6            ; BPB_BkBootSec
MIN_CLUST    = 65525        ; below this it is FAT16 territory, not FAT32

; Stage-table encodings: how many sectors a stage writes, and where it starts
CK_ONE       = 0            ; one sector
CK_TOTAL     = 1            ; the whole card
CK_FATSZ_M1  = 2            ; sectors per FAT, minus its first sector
CK_SPC_M1    = 3            ; sectors per cluster, minus the first one
LK_ZERO      = 0            ; LBA 0
LK_PART      = 1            ; V_PART + argument
LK_DATA      = 2            ; V_PART + data area + argument
FL_FATSZ     = $80          ; then add V_FATSZ (steps FAT #1 over to FAT #2)

; -----------------------------------------------------------------------------
; Apple II hardware
; -----------------------------------------------------------------------------
RAMRDOFF     = $C002        ; reads of $0200-$BFFF come from MAIN
RAMRDON      = $C003        ; reads of $0200-$BFFF come from AUX
RAMWRTOFF    = $C004        ; writes of $0200-$BFFF go to MAIN
RAMWRTON     = $C005        ; writes of $0200-$BFFF go to AUX
COL80ON      = $C00D
STORE80OFF   = $C000        ; WRITE only - reading $C000 is the keyboard
PAGE2OFF     = $C054
TEXTON       = $C051
KBD          = $C000
KBDSTRB      = $C010
HOME_ROM     = $FC58        ; Apple IIe ROM HOME

ESC_KEY      = $1B
CR_KEY       = $0D
BS_KEY       = $08

; =============================================================================
; ENTRY
; =============================================================================
START:
    SEI                     ; keep VERA/ProDOS IRQs out of the way
    JSR SAVE_ZP             ; ProDOS/Applesoft zero page, restored by QUIT
    LDA $FFFE               ; save the IRQ vector, replace it with RTI
    STA ZP_IRQLO
    LDA $FFFF
    STA ZP_IRQHI
    LDA #<NOIRQ
    STA $FFFE
    LDA #>NOIRQ
    STA $FFFF
    ; text, 80 columns, 80STORE off, PAGE2 off (AGENTS.md lesson 2)
    LDA #$00
    STA TEXTON
    STA COL80ON
    STA STORE80OFF
    STA PAGE2OFF
    LDA #$03                ; SPI chip select on, compatible slow clock (bit1)
    STA ZP_SDCLK
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME
    LDX #<MSG_TITLE
    LDY #>MSG_TITLE
    JSR PSTR
    LDX #<MSG_VERS
    LDY #>MSG_VERS
    JSR PSTR
    JSR DETECT_SLOTS        ; prints a message and stops if there is no VERA
    JSR SETUP_SPI_PTRS
    JSR VERA_DISABLE_IRQ_VID
    JSR SHOW_VERA_LINE
    ; ZP_ERR is a ProDOS/Applesoft zero-page byte with an arbitrary value at
    ; entry. Clear it now, or the stale value makes the check below report a
    ; false "SD card did not respond" even after a successful init.
    LDA #$00
    STA ZP_ERR
    ; The 32-bit helpers (DIV32/SHR32/etc.) set only the low pointer byte and
    ; rely on the high byte. VARS sits on page $94; preset the high bytes now so
    ; the capacity display's arithmetic reads the right page.
    LDA #$94
    STA ZP_PTR2HI
    STA ZP_PTR3HI
    JSR SD_INIT
    LDA ZP_ERR
    BNE SD_FAIL_TR
    JSR GET_SD_TOTAL
    LDA ZP_ERR
    BNE SD_FAIL_TR
    JSR SHOW_CAP_LINE
    JSR COMPUTE_GEOMETRY
    LDA ZP_ERR
    BNE SD_SMALL_TR
    JSR PROBE_EXISTING
    JSR SHOW_LAYOUT
    LDA #$15                ; row 21
    JSR GOTO_ROW
    LDX #<MSG_PRESSKEY
    LDY #>MSG_PRESSKEY
    JSR PSTR
    JSR READ_KEY_ANY
    JMP MAIN_MENU
SD_FAIL_TR:
    JMP SHOW_SDFAIL
SD_SMALL_TR:
    JMP SHOW_SMALL
; MAIN_MENU - [1] catalog, [2] format, [3] verify, [0] exit.
MAIN_MENU:
    JSR SHOW_CHOICES
MM_KEY:
    JSR READ_KEY_W
    CMP #$31                ; 1
    BEQ MM_CATALOG
    CMP #$32                ; 2
    BEQ MM_FORMAT
    CMP #$33                ; 3
    BEQ MM_VERIFY
    CMP #$30                ; 0
    BEQ MM_QUIT
    JMP MM_KEY
MM_CATALOG:
    JSR CATALOG_SD
    JSR READ_KEY_ANY
    JMP MAIN_MENU
MM_FORMAT:
    LDA #$00
    STA RAMWRTOFF
    STA V_ZEROMODE
    JSR FORMAT_ENTRY
    JMP MAIN_MENU
MM_VERIFY:
    JSR VERIFY_ENTRY
    JMP MAIN_MENU
MM_QUIT:
    JMP QUIT
; FORMAT_ENTRY - the confirm + write + verify sequence for one format run.
FORMAT_ENTRY:
    JSR REQUIRE_CONFIRM
    LDA ZP_ABORT
    BNE FE_DONE
    JSR RUN_FORMAT
    LDA ZP_ABORT
    BEQ FE_NO_ABORT
    JMP SHOW_ABORT
FE_NO_ABORT:
    LDA ZP_ERR
    BEQ FE_FORMAT_WRITTEN
    JMP SHOW_WRITEFAIL
FE_FORMAT_WRITTEN:
    JSR CLEAR_ROOT_DIR
    LDA ZP_ERR
    BEQ FE_ROOT_WRITTEN
    JMP SHOW_WRITEFAIL
FE_ROOT_WRITTEN:
    JSR VERIFY_ALL
    JSR SHOW_RESULT
FE_DONE:
    RTS

; CLEAR_ROOT_DIR - explicitly rebuild the complete root directory cluster.
; The first sector keeps only the volume label; every remaining sector is zero.
; Each write is read back and compared before moving on, so a completed format
; cannot claim success while stale root entries remain on the card.
CLEAR_ROOT_DIR:
    ; Re-mount the VBR we just wrote and use the exact same root-LBA path as
    ; CATALOG.  Format and catalog therefore cannot disagree about which
    ; cluster is the root directory.
    JSR CA_MOUNT
    LDA ZP_ERR
    BNE CRD_DONE
    LDA CA_ROOTC
    STA CA_CURC
    LDA CA_ROOTC+1
    STA CA_CURC+1
    LDA CA_ROOTC+2
    STA CA_CURC+2
    LDA CA_ROOTC+3
    STA CA_CURC+3
    JSR CA_CLUS_LBA
    LDA CA_CURLBA
    STA ZP_LBA0
    LDA CA_CURLBA+1
    STA ZP_LBA1
    LDA CA_CURLBA+2
    STA ZP_LBA2
    LDA CA_CURLBA+3
    STA ZP_LBA3
    JSR BUILD_ROOT
    LDA CA_SPC
    STA ZP_TEMP2
CRD_WRITE:
    JSR SD_WRITE_SECTOR
    LDA ZP_ERR
    BNE CRD_DONE
    LDA #$82
    STA ZP_BUFPG
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE CRD_DONE
    JSR CMP512
    LDA ZP_ERR
    BNE CRD_DONE
    DEC ZP_TEMP2
    BEQ CRD_DONE
    JSR INC_LBA
    JSR BUILD_ZEROS
    JMP CRD_WRITE
CRD_DONE:
    RTS
; VERIFY_ENTRY - read every metadata sector back and report.
VERIFY_ENTRY:
    JSR VERIFY_ALL
    JSR SHOW_RESULT
    RTS
; A forward branch out of the program is not encodable, so the exits hop
; through this trampoline and only the long hop is a JMP.
START_LEAVE:
    JMP QUIT
SHOW_ABORT:
    LDX #<MSG_ABORTED
    LDY #>MSG_ABORTED
    JSR PSTR
    LDX #<MSG_ANYKEY
    LDY #>MSG_ANYKEY
    JSR PSTR
    JSR READ_KEY_ANY
    RTS
SHOW_WRITEFAIL:
    LDA #$10                ; row 16, below title and all stage rows
    JSR GOTO_ROW
    LDX #<MSG_WRITEFAIL
    LDY #>MSG_WRITEFAIL
    JSR PSTR
    JSR READ_KEY_ANY
    RTS

; =============================================================================
; CATALOG_SD - read the existing FAT32 volume and list the root directory.
; For each non-deleted, non-long-name, non-volume-label entry it prints the
; 8.3 name and the file size. This is the only read-only FAT32 code in the
; program; the format path writes a fresh volume and never reads it back until
; VERIFY_ALL.
; =============================================================================
CATALOG_SD:
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME
    LDX #<MSG_CATTITLE
    LDY #>MSG_CATTITLE
    JSR PSTR
    LDX #<MSG_CATHEAD
    LDY #>MSG_CATHEAD
    JSR PSTR
    JSR CA_MOUNT
    LDA ZP_ERR
    BNE CA_FAIL
    JSR CA_SCAN
    LDX #<MSG_CATDONE
    LDY #>MSG_CATDONE
    JSR PSTR
    LDX #<MSG_PRESSKEY
    LDY #>MSG_PRESSKEY
    JSR PSTR
    RTS
CA_FAIL:
    LDX #<MSG_CATFAIL
    LDY #>MSG_CATFAIL
    JSR PSTR
    RTS

; CA_MOUNT - read the MBR (LBA 0) and the partition's VBR, and compute the FAT32
; layout. ZP_ERR = 0 on success.
CA_ME:
    LDA #$01
    STA ZP_ERR
    RTS
CA_MOUNT:
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    LDA #$80
    STA ZP_BUFPG
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE CA_ME
    ; partition entry 0: type @ $1BE+4 must be $0C, start LBA @ $1BE+8
    LDA WRKBUF+$1C2
    CMP #$0C
    BEQ CA_PART
CA_SUPER:
    ; superfloppy: LBA 0 is already the VBR; use partition start zero
    LDY #$03
    LDA #$00
CAS_ZERO:
    STA V_PART,Y
    DEY
    BPL CAS_ZERO
    JMP CAM_READ_VBR
CA_PART:
    LDA WRKBUF+$1C6
    STA V_PART
    LDA WRKBUF+$1C7
    STA V_PART+1
    LDA WRKBUF+$1C8
    STA V_PART+2
    LDA WRKBUF+$1C9
    STA V_PART+3
    ; read the VBR at V_PART
CAM_READ_VBR:
    LDY #$03
CAM_L:
    LDA V_PART,Y
    STA ZP_LBA0,Y
    DEY
    BPL CAM_L
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE CA_ME
    ; sectors per cluster @ $0D
    LDA WRKBUF+$0D
    STA CA_SPC
    BEQ CA_ME
    ; fat_begin_lba = V_PART + RsvdSecCnt(@$0E, 2 LE)
    CLC
    LDA V_PART
    ADC WRKBUF+$0E
    STA CA_FATBG
    LDA V_PART+1
    ADC WRKBUF+$0F
    STA CA_FATBG+1
    LDA V_PART+2
    ADC #$00
    STA CA_FATBG+2
    LDA V_PART+3
    ADC #$00
    STA CA_FATBG+3
    ; clus_begin_lba = fat_begin_lba + NumFATs(@$10) * FATSz32(@$24, 4 LE)
    ; NumFATs is 2 on this volume; the loop below handles either.
    LDA CA_FATBG
    STA CA_CLUSBG
    LDA CA_FATBG+1
    STA CA_CLUSBG+1
    LDA CA_FATBG+2
    STA CA_CLUSBG+2
    LDA CA_FATBG+3
    STA CA_CLUSBG+3
    LDA #$94
    STA ZP_PTR2HI        ; CA_* workspace lives on page $44
    LDX WRKBUF+$10
CAM_ADD:
    CLC
    LDA CA_CLUSBG
    ADC WRKBUF+$24
    STA CA_CLUSBG
    LDA CA_CLUSBG+1
    ADC WRKBUF+$25
    STA CA_CLUSBG+1
    LDA CA_CLUSBG+2
    ADC WRKBUF+$26
    STA CA_CLUSBG+2
    LDA CA_CLUSBG+3
    ADC WRKBUF+$27
    STA CA_CLUSBG+3
    DEX
    BNE CAM_ADD
    ; root_clus @ $2C (4 LE)
    LDA WRKBUF+$2C
    STA CA_ROOTC
    LDA WRKBUF+$2D
    STA CA_ROOTC+1
    LDA WRKBUF+$2E
    STA CA_ROOTC+2
    LDA WRKBUF+$2F
    STA CA_ROOTC+3
    RTS
; CA_CLUS_LBA - CA_CURC -> CA_CURLBA = CA_CLUSBG + (CA_CURC - 2) << log2(CA_SPC)
CA_CLUS_LBA:
    SEC
    LDA CA_CURC
    SBC #$02
    STA CA_TMP
    LDA CA_CURC+1
    SBC #$00
    STA CA_TMP+1
    LDA CA_CURC+2
    SBC #$00
    STA CA_TMP+2
    LDA CA_CURC+3
    SBC #$00
    STA CA_TMP+3
    ; X = log2(CA_SPC)
    LDX #$00
    LDA CA_SPC
CCL_C:
    CMP #$01
    BEQ CCL_D
    LSR A
    INX
    JMP CCL_C
CCL_D:
    CPX #$00
    BEQ CCL_S
CCL_SH:
    ASL CA_TMP
    ROL CA_TMP+1
    ROL CA_TMP+2
    ROL CA_TMP+3
    DEX
    BNE CCL_SH
CCL_S:
    CLC
    LDA CA_CLUSBG
    ADC CA_TMP
    STA CA_CURLBA
    LDA CA_CLUSBG+1
    ADC CA_TMP+1
    STA CA_CURLBA+1
    LDA CA_CLUSBG+2
    ADC CA_TMP+2
    STA CA_CURLBA+2
    LDA CA_CLUSBG+3
    ADC CA_TMP+3
    STA CA_CURLBA+3
    RTS

; CA_NEXTCLUS - CA_CURC = FAT[CA_CURC]. Carry set = end of chain.
; Reads the FAT sector through WRKBUF. Only the low 28 bits of the FAT32 entry
; are kept (the top nibble is the 0xF0000000 marker).
CA_NEXTCLUS:
    ; CA_TMP = CA_CURC >> 7 (FAT sector offset = cluster / 128)
    LDA CA_CURC
    STA CA_TMP
    LDA CA_CURC+1
    STA CA_TMP+1
    LDA CA_CURC+2
    STA CA_TMP+2
    LDA CA_CURC+3
    STA CA_TMP+3
    LDX #$07
CNC_SR:
    LSR CA_TMP+3
    ROR CA_TMP+2
    ROR CA_TMP+1
    ROR CA_TMP
    DEX
    BNE CNC_SR
    ; CA_WANT = CA_FATBG + CA_TMP
    CLC
    LDA CA_FATBG
    ADC CA_TMP
    STA CA_WANT
    LDA CA_FATBG+1
    ADC CA_TMP+1
    STA CA_WANT+1
    LDA CA_FATBG+2
    ADC CA_TMP+2
    STA CA_WANT+2
    LDA CA_FATBG+3
    ADC CA_TMP+3
    STA CA_WANT+3
    ; read the FAT sector
    LDA #<CA_WANT
    STA ZP_PTR2
    LDY #$03
CNC_L:
    LDA (ZP_PTR2),Y
    STA ZP_LBA0,Y
    DEY
    BPL CNC_L
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE CNC_END
    ; entry offset = (CA_CURC & 0x7F) * 4. The FAT32 entry can sit past $FF in
    ; the sector, so point ZP_PTR2 at WRKBUF+offset and index with Y, which
    ; crosses the page into the second half of the buffer automatically.
    LDA CA_CURC
    AND #$7F
    STA CA_TMP
    LDA #$00
    STA CA_TMP+1
    ASL CA_TMP
    ROL CA_TMP+1
    ASL CA_TMP
    ROL CA_TMP+1
    CLC
    LDA #<WRKBUF
    ADC CA_TMP
    STA ZP_PTR2
    LDA #>WRKBUF
    ADC CA_TMP+1
    STA ZP_PTR2HI
    LDY #$00
    LDA (ZP_PTR2),Y
    STA CA_CURC
    INY
    LDA (ZP_PTR2),Y
    STA CA_CURC+1
    INY
    LDA (ZP_PTR2),Y
    AND #$0F
    STA CA_CURC+2
    INY
    LDA (ZP_PTR2),Y
    AND #$0F
    STA CA_CURC+3
    ; end of chain: value >= 0x0FFFFFF8
    LDA CA_CURC+3
    CMP #$0F
    BEQ CNC_EOF
    CLC
    RTS
CNC_EOF:
    SEC
    RTS
CNC_END:
    SEC
    RTS

; CA_SCAN - walk the root directory from CA_ROOTC and list every entry.
CA_SCAN:
    ; CA_CURC = CA_ROOTC
    LDA CA_ROOTC
    STA CA_CURC
    LDA CA_ROOTC+1
    STA CA_CURC+1
    LDA CA_ROOTC+2
    STA CA_CURC+2
    LDA CA_ROOTC+3
    STA CA_CURC+3
CAS_CLUS:
    JSR CA_CLUS_LBA
    LDA CA_SPC
    STA CA_SECTS
CAS_SEC:
    ; read CA_CURLBA into WRKBUF
    LDA #<CA_CURLBA
    STA ZP_PTR2
    LDA #$94
    STA ZP_PTR2HI
    LDY #$03
CAS_L:
    LDA (ZP_PTR2),Y
    STA ZP_LBA0,Y
    DEY
    BPL CAS_L
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BEQ CAS_SECOK
    JMP CAS_END
CAS_SECOK:
    ; 16 entries per sector, each 32 bytes
    LDA #$00
    STA CA_ENTRY
    STA CA_ENTRY+1
CAS_E:
    ; Build a 16-bit pointer to this 32-byte directory entry.  Absolute,Y
    ; would wrap after entry 7 because WRKBUF spans two pages.
    LDA #<WRKBUF
    CLC
    ADC CA_ENTRY
    STA ZP_PTR2
    LDA #>WRKBUF
    ADC CA_ENTRY+1
    STA ZP_PTR2HI
    LDY #$00
    LDA (ZP_PTR2),Y
    BNE CAS_NONZERO          ; $00 = end of directory
    JMP CAS_EOF
CAS_NONZERO:
    CMP #$E5
    BEQ CAS_NEXT             ; deleted
    CMP #$2E
    BEQ CAS_NEXT             ; "." / ".."
    LDY #$0B
    LDA (ZP_PTR2),Y          ; attribute byte
    STA CA_TMP
    CMP #$0F
    BEQ CAS_NEXT             ; long filename entry
    LDA CA_TMP
    AND #$08
    BNE CAS_VOL
    LDA CA_TMP
    AND #$10
    BNE CAS_DIR
    ; print the size (offset $1C, 4 LE)
    LDY #$1C
    LDA (ZP_PTR2),Y
    STA CA_FSZ
    INY
    LDA (ZP_PTR2),Y
    STA CA_FSZ+1
    INY
    LDA (ZP_PTR2),Y
    STA CA_FSZ+2
    INY
    LDA (ZP_PTR2),Y
    STA CA_FSZ+3
    ; print the 8.3 name, then separate it from the decimal size
    JSR CA_PRINTNAME
    LDA #$20
    JSR PUTCH
    JSR CA_PRINTSIZE
    JMP CAS_NEXT
CAS_VOL:
    JSR CA_PRINTNAME
    LDA #$20
    JSR PUTCH
    LDX #<MSG_CATVOL
    LDY #>MSG_CATVOL
    JSR PSTR
    JSR ROW_ADVANCE
    JMP CAS_NEXT
CAS_DIR:
    JSR CA_PRINTNAME
    LDA #$20
    JSR PUTCH
    LDX #<MSG_CATDIR
    LDY #>MSG_CATDIR
    JSR PSTR
    JSR ROW_ADVANCE
CAS_NEXT:
    ; advance to the next entry (CA_ENTRY += 32)
    LDA CA_ENTRY
    CLC
    ADC #$20
    STA CA_ENTRY
    BCC CAS_NOK
    INC CA_ENTRY+1
CAS_NOK:
    LDA CA_ENTRY+1
    CMP #$02
    BEQ CAS_SECN
    JMP CAS_E
CAS_SECN:
    ; next sector within the cluster
    INC CA_CURLBA
    BNE CAS_NB
    INC CA_CURLBA+1
    BNE CAS_NB
    INC CA_CURLBA+2
    BNE CAS_NB
    INC CA_CURLBA+3
CAS_NB:
    DEC CA_SECTS
    BEQ CAS_CLUSN
    JMP CAS_SEC
CAS_CLUSN:
    ; next cluster in the root's chain
    JSR CA_NEXTCLUS
    BCC CAS_NOTEND
    JMP CAS_END
CAS_NOTEND:
    JMP CAS_CLUS
CAS_EOF:
CAS_END:
    RTS

; CA_PRINTNAME - print the 11-byte name at WRKBUF+CA_ENTRY (8.3, padded).
CA_PRINTNAME:
    LDY #$00
CPN_L:
    LDA (ZP_PTR2),Y
    CMP #$20
    BCC CPN_SKIP             ; control char: skip
    JSR PUTCH
CPN_SKIP:
    INY
    CPY #$08
    BNE CPN_CONT
    LDA #$20                ; separate the 8-byte base name from the extension
    JSR PUTCH
CPN_CONT:
    CPY #$0B
    BNE CPN_L
    RTS

; CA_PRINTSIZE - print CA_FSZ as decimal, right-aligned to 7 digits.
CA_PRINTSIZE:
    LDA #<CA_FSZ
    STA ZP_PTR2
    LDA #$07
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    JSR ROW_ADVANCE
    RTS
SHOW_SDFAIL:
    LDX #<MSG_SDFAIL
    LDY #>MSG_SDFAIL
    JSR PSTR
    JSR READ_KEY_ANY
    JMP QUIT
SHOW_SMALL:
    LDX #<MSG_SMALL
    LDY #>MSG_SMALL
    JSR PSTR
    JSR READ_KEY_ANY
    JMP QUIT

NOIRQ:
    RTI

; =============================================================================
; REQUIRE_CONFIRM - the word FORMAT must be typed, then RETURN. ESC aborts.
; A wrong word only clears the input, so nothing can fire on stray keypresses.
; =============================================================================
REQUIRE_CONFIRM:
    LDA #$00
    STA RAMWRTOFF
    STA ZP_IBUFLEN
    STA ZP_ABORT
    STA ZP_DISPMODE
    TAX
RC_CLR:
    STA ZP_IBUF,X
    INX
    CPX #$0A
    BNE RC_CLR
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME
    LDX #<MSG_WARN1
    LDY #>MSG_WARN1
    JSR PSTR
    LDA V_ZEROMODE
    BEQ RC_QUICKWARN
    LDX #<MSG_WARNZERO
    LDY #>MSG_WARNZERO
    JSR PSTR
    JMP RC_TARGET
RC_QUICKWARN:
    LDX #<MSG_WARNQUICK
    LDY #>MSG_WARNQUICK
    JSR PSTR
RC_TARGET:
    JSR SHOW_TARGET
    LDX #<MSG_ESCCANCEL
    LDY #>MSG_ESCCANCEL
    JSR PSTR
RC_LOOP:
    LDA #$0B                ; Row 11
    JSR GOTO_ROW
    LDX #<MSG_TYPEFMT
    LDY #>MSG_TYPEFMT
    JSR PSTR
    LDY #$00
RC_DRAW:
    CPY ZP_IBUFLEN
    BEQ RC_DRAWPAD
    LDA ZP_IBUF,Y
    JSR PUTCH
    INY
    JMP RC_DRAW
RC_DRAWPAD:
    CPY #$08
    BCS RC_KEY
    LDA #$20
    JSR PUTCH
    INY
    JMP RC_DRAWPAD
RC_KEY:
    JSR READ_KEY_W
    CMP #ESC_KEY
    BEQ RC_ESC
    CMP #BS_KEY
    BEQ RC_BS
    CMP #$7F
    BEQ RC_BS
    CMP #CR_KEY
    BEQ RC_ENTER
    LDX ZP_IBUFLEN
    CPX #$06                ; FORMAT is six characters
    BCS RC_KEY
    STA ZP_IBUF,X
    INC ZP_IBUFLEN
    JMP RC_LOOP
RC_BS:
    LDA ZP_IBUFLEN
    BEQ RC_KEY
    DEC ZP_IBUFLEN
    JMP RC_LOOP
RC_ESC:
    LDA #$01
    STA ZP_ABORT
    RTS
RC_ENTER:
    LDA ZP_IBUFLEN
    CMP #$06
    BNE RC_NOPE
    LDX #$00
RC_CMP:
    LDA ZP_IBUF,X
    CMP FMT_WORD,X
    BNE RC_NOPE
    INX
    CPX #$06
    BNE RC_CMP
    CLC
    RTS
RC_NOPE:
    LDA #$00
    STA ZP_IBUFLEN
    JMP RC_LOOP

; =============================================================================
; RUN_FORMAT - the stage table drives everything, so the whole layout is one
; declarative list and ESC is tested once per stage. Each entry is eight bytes:
;
;   +0 label address (low, high)     +4 how many sectors (CK_*)
;   +2 template builder (low, high)  +5 where it starts (LK_*)
;                                    +6 start offset within that
;                                    +7 flags (FL_FATSZ steps to FAT #2)
;
; The builder is called through a self-modifying JSR because the assembler has
; no indirect JSR. Patching writes into our own code, so RAMWRTOFF is asserted
; first: with the AUX bank selected the patch would land where the 6502 is not
; executing from and the old target would keep running.
; =============================================================================
RUN_FORMAT:
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME
    LDX #<MSG_TITLE
    LDY #>MSG_TITLE
    JSR PSTR
    LDX #<MSG_WORKING
    LDY #>MSG_WORKING
    JSR PSTR
    LDA #$00
    STA RAMWRTOFF           ; PUTCH may have left RAMWRT on AUX; force MAIN
    STA V_STAGE
    LDX #$00
RF_LOOP:
    LDA ZP_ABORT
    BNE RF_DONE
    CPX #$00
    BEQ RF_STAGE0         ; the zero-fill stage is optional
RF_RUN:
    LDA #$00
    STA RAMWRTOFF           ; guarantee MAIN for ZP_STGIDX and VARS writes below
    STX ZP_STGIDX
    JSR RF_SET_COUNT
    LDX ZP_STGIDX
    JSR RF_SET_LBA
    LDX ZP_STGIDX
    JSR RF_SHOW_LABEL
    LDX ZP_STGIDX
    JSR RF_ARM_PROGRESS
    JSR DRAW_PROGRESS       ; show 0% and the total before the first write
    LDA #$00
    STA RAMWRTOFF         ; write MAIN - our code lives in MAIN
    LDX ZP_STGIDX
    LDA RF_TAB+2,X
    STA TPLJSR+1
    LDA RF_TAB+3,X
    STA TPLJSR+2
    JSR TPLJSR
    JSR STAGE_WRITE
    LDA ZP_ERR
    BNE RF_DONE             ; stop instead of verifying an incomplete format
    INC V_STAGE
    LDX ZP_STGIDX
RF_ADVANCE:
    TXA
    CLC
    ADC #$08
    TAX
    CPX #$60                ; 12 stages * 8 bytes = 96 ($60)
    BNE RF_LOOP
RF_DONE:
    RTS
; Stage 0 is the optional whole-card zero fill. Skipping it must not burn a
; stage number, otherwise the log starts at 01 for what the screen calls 00.
RF_STAGE0:
    LDA V_ZEROMODE
    BEQ RF_SKIPONLY
    JMP RF_RUN
RF_SKIPONLY:
    LDA ZP_ABORT
    BNE RF_DONE
    JMP RF_ADVANCE

TPLJSR:
    JSR TPL_STUB          ; operand patched per stage
TPL_STUB:
    RTS

; Set V_PCTTOT from the count kind
RF_SET_COUNT:
    LDA RF_TAB+4,X
    BEQ RF_C_ONE
    CMP #$01
    BEQ RF_C_TOTAL
    CMP #$02
    BEQ RF_C_FATSZ
    JMP RF_C_SPC
RF_C_ONE:
    LDA #$01
    STA V_PCTTOT
    LDA #$00
    STA V_PCTTOT+1
    STA V_PCTTOT+2
    STA V_PCTTOT+3
    RTS
RF_C_TOTAL:
    LDY #$03
RF_CT_L:
    LDA V_TOTAL,Y
    STA V_PCTTOT,Y
    DEY
    BPL RF_CT_L
    RTS
RF_C_FATSZ:
    SEC
    LDA V_FATSZ
    SBC #$01
    STA V_PCTTOT
    LDA V_FATSZ+1
    SBC #$00
    STA V_PCTTOT+1
    LDA V_FATSZ+2
    SBC #$00
    STA V_PCTTOT+2
    LDA V_FATSZ+3
    SBC #$00
    STA V_PCTTOT+3
    RTS
RF_C_SPC:
    LDA V_SPC
    SEC
    SBC #$01
    STA V_PCTTOT
    LDA #$00
    SBC #$00
    STA V_PCTTOT+1
    STA V_PCTTOT+2
    STA V_PCTTOT+3
    RTS

; Set ZP_LBA from the start kind, its offset, and the FAT #2 flag
RF_SET_LBA:
    LDA RF_TAB+5,X
    BEQ RF_L_ZERO
    CMP #$01
    BEQ RF_L_PART
    JMP RF_L_DATA
RF_L_ZERO:
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    JMP RF_L_FLAG
RF_L_PART:
    TXA
    CLC
    ADC #$06
    TAY
    LDA RF_TAB,Y
    TAY
    TYA
    CLC
    ADC V_PART
    STA ZP_LBA0
    LDA V_PART+1
    ADC #$00
    STA ZP_LBA1
    LDA V_PART+2
    ADC #$00
    STA ZP_LBA2
    LDA V_PART+3
    ADC #$00
    STA ZP_LBA3
    JMP RF_L_FLAG
RF_L_DATA:
    TXA
    CLC
    ADC #$06
    TAY
    LDA RF_TAB,Y
    TAY
    TYA
    CLC
    ADC V_PART
    ADC V_DATA
    STA ZP_LBA0
    LDA V_PART+1
    ADC V_DATA+1
    STA ZP_LBA1
    LDA V_PART+2
    ADC V_DATA+2
    STA ZP_LBA2
    LDA V_PART+3
    ADC V_DATA+3
    STA ZP_LBA3
RF_L_FLAG:
    LDA RF_TAB+7,X
    BPL RF_L_DONE         ; FL_FATSZ not set
    CLC
    LDA ZP_LBA0
    ADC V_FATSZ
    STA ZP_LBA0
    LDA ZP_LBA1
    ADC V_FATSZ+1
    STA ZP_LBA1
    LDA ZP_LBA2
    ADC V_FATSZ+2
    STA ZP_LBA2
    LDA ZP_LBA3
    ADC V_FATSZ+3
    STA ZP_LBA3
RF_L_DONE:
    RTS

; Print "  NN label" for the current table entry. PUTCH clobbers X, so the
; table index is parked while anything is printed.
RF_SHOW_LABEL:
    ; Each stage gets its own row: row = 3 + V_STAGE. Rows 0-2 hold the title,
    ; blank separator, and progress heading. Progress goes on the
    ; same row at column 40. GOTO_ROW clobbers ZP_TEMP2, so it runs before X
    ; is parked.
    LDA V_STAGE
    CLC
    ADC #$03
    JSR GOTO_ROW
    STX ZP_TEMP2
    LDA #$20
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    LDA V_STAGE
    JSR PRINT_HEX2
    LDA #$2E
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    LDX ZP_TEMP2
    LDA RF_TAB+0,X
    STA ZP_PTR
    LDA RF_TAB+1,X
    STA ZP_PTRHI
    JSR PRINT_STRING
    LDA #$00
    STA RAMWRTOFF           ; PUTCH may have left RAMWRT on AUX; force MAIN
    RTS

; Arm the progress counter for V_PCTTOT sectors
RF_ARM_PROGRESS:
    LDA #$00
    STA RAMWRTOFF           ; force MAIN before any VARS write
    STA V_DONE
    STA V_DONE+1
    STA V_DONE+2
    STA V_DONE+3
    STA V_PCT
    STA V_PCT+1
    STA V_PCT+2
    STA V_PCT+3
    ; step = ceil(total/100) but never zero, so a one-sector stage still ticks
    LDY #$03
RAP_CP:
    LDA V_PCTTOT,Y
    STA V_TMP1,Y
    DEY
    BPL RAP_CP
    LDA #<K_100
    STA ZP_PTR3
    LDA #>K_100
    STA ZP_PTR3HI
    LDY #$00
RAP_D:
    LDA (ZP_PTR3),Y
    STA V_TMP2,Y
    INY
    CPY #$04
    BNE RAP_D
    JSR DIV32               ; V_TMP1 = total/100, V_REM = remainder
    LDA V_REM
    ORA V_REM+1
    ORA V_REM+2
    ORA V_REM+3
    BEQ RAP_NOROUND
    JSR INC_TMP1            ; round up so 100% is never reached late
RAP_NOROUND:
    LDA V_TMP1
    ORA V_TMP1+1
    ORA V_TMP1+2
    ORA V_TMP1+3
    BNE RAP_HAVE
    INC V_TMP1
RAP_HAVE:
    LDY #$03
RAP_STEP:
    LDA V_TMP1,Y
    STA V_PCTSTEP,Y
    STA V_PCTNEXT,Y
    DEY
    BPL RAP_STEP
    RTS

INC_TMP1:
    INC V_TMP1
    BNE IT1_OUT
    INC V_TMP1+1
    BNE IT1_OUT
    INC V_TMP1+2
    BNE IT1_OUT
    INC V_TMP1+3
IT1_OUT:
    RTS

; =============================================================================
; STAGE_WRITE - write WRKBUF V_PCTTOT times starting at ZP_LBA. Use CMD24 for
; every sector: Apple2TS supports CMD24 but not CMD25, and the extra command
; frame is small beside a 512-byte transfer. ESC stops between sectors.
; =============================================================================
STAGE_WRITE:
STW_NEXT:
    LDA #$00
    STA RAMWRTOFF           ; SHOW_PROGRESS/PUTCH may have left RAMWRT on AUX
    LDA #<V_DONE
    STA ZP_PTR2
    LDA #<V_PCTTOT
    STA ZP_PTR3
    JSR CMP32
    BCS STW_DONE            ; V_DONE >= V_PCTTOT
    JSR CHECK_ESC
    LDA ZP_ABORT
    BNE STW_DONE
    JSR SD_WRITE_SECTOR
    LDA ZP_ERR
    BNE STW_DONE
    JSR INC_LBA
    JSR INC_DONE
    JSR SHOW_PROGRESS
    JMP STW_NEXT
STW_DONE:
    RTS

INC_DONE:
    INC V_DONE
    BNE INCD_OUT
    INC V_DONE+1
    BNE INCD_OUT
    INC V_DONE+2
    BNE INCD_OUT
    INC V_DONE+3
INCD_OUT:
    RTS

INC_LBA:
    INC ZP_LBA0
    BNE INCL_OUT
    INC ZP_LBA1
    BNE INCL_OUT
    INC ZP_LBA2
    BNE INCL_OUT
    INC ZP_LBA3
INCL_OUT:
    RTS

; Redraw progress only when the percentage changes. A DIV32 per sector would
; cost about as much as the write itself and double the format time.
SHOW_PROGRESS:
    ; Force an exhausted stage to exactly 100%, even when ceil(total/100)
    ; does not divide the sector count evenly.
    LDA #<V_DONE
    STA ZP_PTR2
    LDA #<V_PCTTOT
    STA ZP_PTR3
    JSR CMP32
    BCC SP_NOT_DONE
    LDA #$64
    STA V_PCT
    JMP DRAW_PROGRESS
SP_NOT_DONE:
    LDA #<V_DONE
    STA ZP_PTR2
    LDA #<V_PCTNEXT
    STA ZP_PTR3
    JSR CMP32
    BCC SP_OUT              ; not a full percent yet
    LDA #<V_PCTNEXT
    STA ZP_PTR2
    LDA #<V_PCTSTEP
    STA ZP_PTR3
    JSR ADD32               ; re-arm the threshold one percent further
    INC V_PCT
    BNE SP_DRAW
    INC V_PCT+1
SP_DRAW:
    JMP DRAW_PROGRESS
SP_OUT:
    RTS

; Draw the current stage's progress in the right half of its label row.
DRAW_PROGRESS:
    LDA V_STAGE
    CLC
    ADC #$03
    JSR GOTO_ROW
    LDA #$28                ; column 40: right half of the 80-column screen
    STA ZP_COL
    LDA #<V_PCT
    STA ZP_PTR2
    LDA #$03
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$25
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    LDX #<MSG_OF
    LDY #>MSG_OF
    JSR PSTR
    LDA #<V_DONE
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$2F
    JSR PUTCH
    LDA #<V_PCTTOT
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    ; every field is fixed width, so the line can never leave stale text
    LDA #$00
    STA RAMWRTOFF
    RTS

; =============================================================================
; VERIFY_ALL - rebuild each metadata template, read the sector back off the
; card and byte-compare it. Every mismatch bumps V_VERERR, and SHOW_RESULT
; reports the count. This is the part that turns "we issued writes" into
; "the card holds a FAT32 volume".
; =============================================================================
VERIFY_ALL:
    LDA #$00
    STA RAMWRTOFF           ; force MAIN before any VARS write (SHOW_CHOICES/PSTR may leave AUX)
    STA V_VERERR
    STA V_VERERR+1
    STA V_VERERR+2
    STA V_VERERR+3
    ; Leave the format stage rows intact and list verification below them.
    LDA #$0E                ; row 14: below the final root stage at row 13
    JSR GOTO_ROW
    LDX #<MSG_VERIFY
    LDY #>MSG_VERIFY
    JSR PSTR
    ; MBR at LBA 0
    JSR BUILD_MBR
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    LDA #<MSG_VI_MBR
    STA ZP_PTR
    LDA #>MSG_VI_MBR
    STA ZP_PTRHI
    JSR VERIFY_ONE
    ; VBR
    JSR BUILD_VBR
    LDA #$00
    JSR SET_LBA_FROM_PART
    LDA #<MSG_VI_VBR
    STA ZP_PTR
    LDA #>MSG_VI_VBR
    STA ZP_PTRHI
    JSR VERIFY_ONE
    ; FSInfo
    JSR BUILD_FSINFO
    LDA #FSINFO_SEC
    JSR SET_LBA_FROM_PART
    LDA #<MSG_VI_FSINFO
    STA ZP_PTR
    LDA #>MSG_VI_FSINFO
    STA ZP_PTRHI
    JSR VERIFY_ONE
    ; backup VBR
    JSR BUILD_VBR
    LDA #BKVBR_SEC
    JSR SET_LBA_FROM_PART
    LDA #<MSG_VI_BKVBR
    STA ZP_PTR
    LDA #>MSG_VI_BKVBR
    STA ZP_PTRHI
    JSR VERIFY_ONE
    ; backup FSInfo
    JSR BUILD_FSINFO
    LDA #BKVBR_SEC
    CLC
    ADC #FSINFO_SEC
    JSR SET_LBA_FROM_PART
    LDA #<MSG_VI_BKFSINFO
    STA ZP_PTR
    LDA #>MSG_VI_BKFSINFO
    STA ZP_PTRHI
    JSR VERIFY_ONE
    ; FAT #1/#2 and the root directory are mutable after formatting: creating
    ; files updates both FAT copies and root entries.  Do not compare them to
    ; the pristine empty templates here, or a valid populated card reports a
    ; false mismatch.  The fixed metadata above remains byte-for-byte checked.
    RTS

; VERIFY_ONE - ZP_PTR = label, ZP_LBA = sector, WRKBUF = what must be there
VERIFY_ONE:
    JSR PRINT_STRING
    LDA #$00
    STA RAMWRTOFF           ; PUTCH may have left RAMWRT on AUX; force MAIN
    LDA #$82
    STA ZP_BUFPG            ; read the sector back into TMPBUF
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE VO_BAD
    JSR CMP512
    LDA ZP_ERR
    BEQ VO_OK
    ; MBR legacy CHS bytes may be normalized by FAT32 tools, and FSInfo's
    ; free-count/next-free fields change when files are created.  Those are
    ; valid differences; the fixed metadata sectors remain strict compares.
    LDA ZP_PTR
    CMP #<MSG_VI_MBR
    BEQ VO_OK
    CMP #<MSG_VI_FSINFO
    BEQ VO_OK
    CMP #<MSG_VI_BKFSINFO
    BEQ VO_OK
    JMP VO_BAD
VO_OK:
    LDX #<MSG_OK
    LDY #>MSG_OK
    JSR PSTR
    RTS
VO_BAD:
    INC V_VERERR
    LDX #<MSG_MISMATCH
    LDY #>MSG_MISMATCH
    JSR PSTR
    RTS

; CMP512 - WRKBUF against TMPBUF. ZP_ERR = 0 when identical.
CMP512:
    LDA #$00
    STA ZP_ERR
    STA RAMRDOFF            ; both buffers live in MAIN
    STA RAMWRTOFF
    LDX #$00
CM5_P0:
    LDA WRKBUF,X
    CMP TMPBUF,X
    BNE CM5_DIFF
    INX
    BNE CM5_P0
    LDX #$00
CM5_P1:
    LDA WRKBUF+256,X
    CMP TMPBUF+256,X
    BNE CM5_DIFF
    INX
    BNE CM5_P1
    RTS
CM5_DIFF:
    LDA #$01
    STA ZP_ERR
    RTS

; =============================================================================
; TEMPLATES - each one fills WRKBUF with exactly 512 bytes
; =============================================================================
; BUILD_ZEROS - an all-zero sector
BUILD_ZEROS:
    LDA #$00
    STA RAMWRTOFF           ; the buffers are in MAIN, and PUTCH may have left
    STA RAMRDOFF            ; the banks pointed at AUX
    LDX #$00
BZ_L0:
    STA WRKBUF,X
    INX
    BNE BZ_L0
    LDX #$00
BZ_L1:
    STA WRKBUF+256,X
    INX
    BNE BZ_L1
    RTS

; BUILD_MBR - one partition, type $0C (FAT32 with INT 13h extensions), starting
; at LBA PART_LBA and running for V_PSIZE sectors.
;
; The two three-byte CHS fields are legacy. Nothing that mounts this volume
; reads them - CMDR-DOS and the A2VERA FAT32 reader take the start LBA from
; $1C6 and ignore CHS - and a cylinder/head/sector translation could not
; address a large card anyway, so they carry the usual LBA-era convention.
BUILD_MBR:
    JSR BUILD_ZEROS
    ; disk signature at $1D8: the capacity, so each card size is distinct
    LDY #$03
BM_SIG:
    LDA V_TOTAL,Y
    STA WRKBUF+$1D8,Y
    DEY
    BPL BM_SIG
    ; partition entry 1 at $1BE
    LDA #$00
    STA WRKBUF+$1BE         ; boot indicator - a data volume, not bootable
    STA WRKBUF+$1C1         ; start CHS cylinder low
    LDA #$21
    STA WRKBUF+$1C0         ; start CHS sector, the conventional 33
    LDA #$0C
    STA WRKBUF+$1C2         ; type $0C - FAT32 with INT 13h extensions
    LDA #$FE                ; end CHS: the "beyond CHS" marker
    STA WRKBUF+$1C3
    LDA #$FF
    STA WRKBUF+$1C4
    STA WRKBUF+$1C5
    ; start LBA at $1C6, sector count at $1CA
    LDY #$03
BM_LBA:
    LDA V_PART,Y
    STA WRKBUF+$1C6,Y
    LDA V_PSIZE,Y
    STA WRKBUF+$1CA,Y
    DEY
    BPL BM_LBA
    ; the 55 AA boot signature
    LDA #$55
    STA WRKBUF+$1FE
    LDA #$AA
    STA WRKBUF+$1FF
    RTS

; BUILD_VBR - the FAT32 volume boot record
BUILD_VBR:
    JSR BUILD_ZEROS
    LDA #$EB
    STA WRKBUF+$00          ; short jump past the parameter block
    LDA #$58
    STA WRKBUF+$01
    LDA #$90
    STA WRKBUF+$02
    LDX #$07                ; OEM name at $03
BV_OEM:
    LDA TXT_OEM,X
    STA WRKBUF+$03,X
    DEX
    BPL BV_OEM
    LDA #$00
    STA WRKBUF+$0B
    LDA #$02
    STA WRKBUF+$0C          ; bytes per sector = 512
    LDA V_SPC
    STA WRKBUF+$0D          ; sectors per cluster
    LDA #RSVD_SECS
    STA WRKBUF+$0E          ; reserved sectors
    LDA #NUM_FATS
    STA WRKBUF+$10          ; number of FATs
    LDA #$F8
    STA WRKBUF+$15          ; media descriptor - fixed media
    LDA #$20
    STA WRKBUF+$18          ; sectors per track, as the reference carries it
    LDA #$40
    STA WRKBUF+$1A          ; number of heads
    ; hidden sectors at $1C: the partition start, so the volume also reads
    ; correctly when the whole card is imaged
    LDY #$03
BV_HID:
    LDA V_PART,Y
    STA WRKBUF+$1C,Y
    DEY
    BPL BV_HID
    ; total sectors of the volume at $20 (NOT the whole card)
    LDY #$03
BV_TOT:
    LDA V_PSIZE,Y
    STA WRKBUF+$20,Y
    DEY
    BPL BV_TOT
    ; sectors per FAT at $24
    LDY #$03
BV_FAT:
    LDA V_FATSZ,Y
    STA WRKBUF+$24,Y
    DEY
    BPL BV_FAT
    ; $28 ext flags and $2A FS version stay zero: FAT 0 active, FATs mirrored
    LDA #ROOT_CLUS
    STA WRKBUF+$2C          ; root directory starts at cluster 2
    LDA #FSINFO_SEC
    STA WRKBUF+$30          ; FSInfo sector
    LDA #BKVBR_SEC
    STA WRKBUF+$32          ; backup boot sector
    LDA #$80
    STA WRKBUF+$40          ; drive number: the "hard disk" this volume is on
    LDA #$29
    STA WRKBUF+$42          ; boot signature: label, serial and create time follow
    LDY #$03                ; volume serial at $43
BV_VOL:
    LDA V_TOTAL,Y
    STA WRKBUF+$43,Y
    DEY
    BPL BV_VOL
    LDX #$0A                ; volume label at $47, 11 bytes
BV_LBL:
    LDA TXT_LABEL,X
    STA WRKBUF+$47,X
    DEX
    BPL BV_LBL
    LDX #$07                ; file system type at $52 - what every FAT32
BV_FS:                      ; reader checks before it believes the volume
    LDA TXT_FAT32,X
    STA WRKBUF+$52,X
    DEX
    BPL BV_FS
    LDA #$55
    STA WRKBUF+$1FE
    LDA #$AA
    STA WRKBUF+$1FF
    RTS

; BUILD_FSINFO - the FSInfo sector (volume sector 1)
BUILD_FSINFO:
    JSR BUILD_ZEROS
    LDA #$52                ; lead signature "RRaA"
    STA WRKBUF+$00
    STA WRKBUF+$01
    LDA #$61
    STA WRKBUF+$02
    LDA #$41
    STA WRKBUF+$03
    LDA #$72                ; structure signature at $1E4
    STA WRKBUF+$1E4
    STA WRKBUF+$1E5
    LDA #$41
    STA WRKBUF+$1E6
    LDA #$61
    STA WRKBUF+$1E7
    ; free cluster count at $1E8: all clusters except the root directory
    LDY #$03
BF_FREE:
    LDA V_CLUST,Y
    STA WRKBUF+$1E8,Y
    DEY
    BPL BF_FREE
    SEC
    LDA WRKBUF+$1E8
    SBC #$01
    STA WRKBUF+$1E8
    LDA WRKBUF+$1E9
    SBC #$00
    STA WRKBUF+$1E9
    LDA WRKBUF+$1EA
    SBC #$00
    STA WRKBUF+$1EA
    LDA WRKBUF+$1EB
    SBC #$00
    STA WRKBUF+$1EB
    LDA #$03                ; next free cluster hint at $1EC
    STA WRKBUF+$1EC
    LDA #$55                ; trail signature at $1FC
    STA WRKBUF+$1FE
    LDA #$AA
    STA WRKBUF+$1FF
    RTS

; BUILD_FAT0 - the first sector of a FAT: the media entry, the end-of-host
; entry, and the root directory cluster closed off as end-of-chain. Every
; other sector of both FATs is zero, which is what "free" means.
BUILD_FAT0:
    JSR BUILD_ZEROS
    LDA #$F8
    STA WRKBUF+$00          ; FAT[0] = F8 FF FF 0F - the media descriptor
    LDA #$FF
    STA WRKBUF+$01
    STA WRKBUF+$02
    STA WRKBUF+$03
    LDA #$FF
    STA WRKBUF+$04          ; FAT[1] = FF FF FF 0F - end of host
    STA WRKBUF+$05
    STA WRKBUF+$06
    LDA #$0F
    STA WRKBUF+$07
    LDA #$F8
    STA WRKBUF+$08          ; FAT[2] = F8 FF FF 0F - the root dir, end of chain
    LDA #$FF
    STA WRKBUF+$09
    STA WRKBUF+$0A
    LDA #$0F
    STA WRKBUF+$0B
    RTS

; BUILD_ROOT - the first sector of the root directory cluster: one volume label
; entry and nothing else, exactly like the reference volume and like a volume
; Windows formats. Dots entries are not part of FAT32.
BUILD_ROOT:
    JSR BUILD_ZEROS
    LDX #$0A
BR_LBL:
    LDA TXT_LABEL,X
    STA WRKBUF,X
    DEX
    BPL BR_LBL
    LDA #$08                ; attribute: volume label
    STA WRKBUF+$0B
    RTS

; =============================================================================
; SD / SPI LAYER
;
; The registers are addressed through ZP_SPIDATLO/HI (base+$1E) and
; ZP_SPISTLO/HI (base+$1F) with Y fixed at 0. Absolute addressing on $C2xx is
; shadowed by the slot ROM window, and indexed stores through a zero-page
; pointer do a dummy read first, which on the DATA register would consume a
; byte - so every access here is the (zp),Y form with Y = 0, never ,Y indexed.
;
; Protocol notes, all of them lessons the A2VERA firmware documents:
;   * 80 clocks with CS deasserted before anything else, or the card never
;     leaves idle state on power-up.
;   * CMD0 and CMD8 carry their real CRC7 ($95, $87); every other command uses
;     $FF because CRC checking is off in SPI mode by default.
;   * One dummy byte is clocked out before each command to cover Ncr, the
;     response latency.
;   * Response polling is bounded, and a timeout sets the sticky ZP_SPIFLT.
;     Without that bound a dead card stalls the machine for ~98 seconds.
;   * CMD17/CMD24 take an LBA, or a byte address on a standard-capacity card
;     (OCR CCS clear). See SD_ARG_FROM_LBA.
; =============================================================================
; SPI_SEND_A - clock A out. SPI_READ_A - clock out $FF and return the byte the
; card shifted in. Both wait for the controller to go idle, and every loop that
; calls them counts on X, never Y: these two use Y as their own register
; offset, so Y does not survive the call.
SPI_SEND_A:
    LDY #$00
    STA (ZP_SPIDATLO),Y
    JSR SPI_WAIT
    RTS

SPI_READ_A:
    LDA #$FF
    LDY #$00
    STA (ZP_SPIDATLO),Y
    JSR SPI_WAIT
    LDY #$00
    LDA (ZP_SPIDATLO),Y
    RTS

; SPI_WAIT - spin until BUSY (bit7 of STATUS) clears, exactly like the proven
; verasdedit layer. Unbounded: a real controller goes not-busy within a few
; cycles, and a bounded wait would time out on the emulator's first transfer
; if the status bit is ever seen set.
; Bounded: a card that never frees the line sets ZP_ERR instead of freezing the
; machine. The count is 16-bit and generous, so a normal controller (which goes
; not-busy within a few cycles) never trips it. ZP_SCR2/ZP_SCR3 are free here —
; they are only used by PRINT_DEC32W, which is not active during an SD transfer.
SPI_WAIT:
    LDY #$00
    LDA #$00
    STA ZP_SCR2
    STA ZP_SCR3
SW_LOOP:
    LDA (ZP_SPISTLO),Y
    AND #$80
    BEQ SW_DONE
    INC ZP_SCR2
    BNE SW_LOOP
    INC ZP_SCR3
    BNE SW_LOOP
    LDA #$01
    STA ZP_ERR
SW_DONE:
    RTS

; SD_CMD - A = command number, V_ARG = argument (MSB first), ZP_CRC = CRC byte.
; Returns the R1 response in A, or $FF if the card never answered.
SD_CMD:
    STA ZP_TEMP
    LDA #$40
    CLC
    ADC ZP_TEMP
    STA ZP_TEMP2            ; 0x40 + number, the first byte of the frame
    LDA ZP_TEMP2
    JSR SPI_SEND_A
    LDX #$00
SDC_ARG:
    LDA V_ARG,X
    JSR SPI_SEND_A
    INX
    CPX #$04
    BNE SDC_ARG
    LDA ZP_CRC
    JSR SPI_SEND_A
    LDX #$FF
SDC_POLL:
    JSR SPI_READ_A
    BPL SDC_GOT             ; an R1 always has bit7 clear
    DEX
    BNE SDC_POLL
    LDA #$80
    STA ZP_SPIFLT
    LDA #$FF
SDC_GOT:
    RTS

; V_ARG = 0
SD_ARG_ZERO:
    LDY #$03
SAZ_LOOP:
    LDA #$00
    STA V_ARG,Y
    DEY
    BPL SAZ_LOOP
    RTS

; V_ARG = A, for the small arguments this program uses
SD_ARG_IMM8:
    STA V_ARG+3
    LDA #$00
    STA V_ARG
    STA V_ARG+1
    STA V_ARG+2
    RTS

; V_ARG = the current LBA, scaled for the card's addressing mode. A standard
; capacity card (OCR CCS clear) expects a BYTE address; high capacity cards and
; the emulated card take the LBA as it stands.
SD_ARG_FROM_LBA:
    LDA ZP_LBA3
    STA V_ARG
    LDA ZP_LBA2
    STA V_ARG+1
    LDA ZP_LBA1
    STA V_ARG+2
    LDA ZP_LBA0
    STA V_ARG+3
    RTS


; SD_INIT - take the card from power-on to ready. This is the exact proven
; sequence from verasdedit: select the card, then CMD0/CMD8/CMD55/ACMD41/CMD16.
SD_INIT:
    LDA ZP_SDCLK            ; keep the clock shown on screen during SD commands
    LDY #$00
    STA (ZP_SPISTLO),Y
    ; CMD0: 40 00 00 00 00 95. Capture the R1 so a diagnostic can report whether
    ; the card actually answered (R1 = $01 means it did).
    LDA #$40
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$95
    JSR SPI_SEND_A
    JSR SPI_READ_A
    STA V_TMP1
    ; CMD8: 48 00 00 01 AA 87
    LDA #$48
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$01
    JSR SPI_SEND_A
    LDA #$AA
    JSR SPI_SEND_A
    LDA #$87
    JSR SPI_SEND_A
    JSR SPI_READ_A
    ; CMD55: 77 00 00 00 00 01
    LDA #$77
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$01
    JSR SPI_SEND_A
    JSR SPI_READ_A
    ; ACMD41: 69 00 00 00 00 FF
    LDA #$69
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A
    JSR SPI_READ_A
    STA V_TMP2                ; ACMD41 R1: $00 means the card left init
    ; CMD16: 50 00 00 02 00 FF
    LDA #$50
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$02
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A
    JSR SPI_READ_A
    RTS

; SD_READ_SECTOR - read ZP_LBA into the buffer ZP_BUFPG points at.
; ZP_ERR = 0 on success.
SD_READ_SECTOR:
    LDA #$00
    STA ZP_ERR
    STA RAMWRTOFF           ; the buffer lives in MAIN
    STA ZP_BUFLO
    JSR SD_ARG_FROM_LBA
    ; CMD17 READ_SINGLE_BLOCK: 51 (0x40+17) then the LBA, MSB first. V_ARG is
    ; MSB-first (V_ARG = ZP_LBA3), so send it down first.
    LDA #$51
    JSR SPI_SEND_A
    LDA V_ARG
    JSR SPI_SEND_A
    LDA V_ARG+1
    JSR SPI_SEND_A
    LDA V_ARG+2
    JSR SPI_SEND_A
    LDA V_ARG+3
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A          ; CRC
    ; First byte after the frame: the card sends R1 ($00) then the data token
    ; ($FE). Some cards send the data token directly. Tolerate either.
    JSR SPI_READ_A
    STA V_TMP3
    CMP #$FE
    BEQ SRS_DATA            ; already at the data token
    CMP #$00
    BNE SRS_FAIL
    JSR SPI_READ_A          ; data token
    CMP #$FE
    BNE SRS_FAIL
SRS_DATA:
    LDX #$00
SRS_L0:
    ; Stream the full sector with inline SPI polling. Keep SPI_WAIT's bounded
    ; timeout behavior: set ZP_ERR and continue reading the controller byte.
    LDA #$FF
    LDY #$00
    STA (ZP_SPIDATLO),Y
    LDA #$00
    STA ZP_SCR2
    STA ZP_SCR3
SRS_WAIT0:
    LDA (ZP_SPISTLO),Y
    BPL SRS_READY0
    INC ZP_SCR2
    BNE SRS_WAIT0
    INC ZP_SCR3
    BNE SRS_WAIT0
    LDA #$01
    STA ZP_ERR
SRS_READY0:
    LDA (ZP_SPIDATLO),Y
    STA ZP_TEMP
    TXA
    TAY
    LDA ZP_TEMP
    STA (ZP_BUFLO),Y
    INX
    BNE SRS_L0
    INC ZP_BUFPG            ; second half of the sector, the next page
    LDX #$00
SRS_L1:
    LDA #$FF
    LDY #$00
    STA (ZP_SPIDATLO),Y
    LDA #$00
    STA ZP_SCR2
    STA ZP_SCR3
SRS_WAIT1:
    LDA (ZP_SPISTLO),Y
    BPL SRS_READY1
    INC ZP_SCR2
    BNE SRS_WAIT1
    INC ZP_SCR3
    BNE SRS_WAIT1
    LDA #$01
    STA ZP_ERR
SRS_READY1:
    LDA (ZP_SPIDATLO),Y
    STA ZP_TEMP
    TXA
    TAY
    LDA ZP_TEMP
    STA (ZP_BUFLO),Y
    INX
    BNE SRS_L1
    DEC ZP_BUFPG            ; restore caller's ZP_BUFPG
    JSR SPI_READ_A          ; the two CRC bytes
    JSR SPI_READ_A
    RTS
SRS_FAIL:
    LDA #$01
    STA ZP_ERR
    RTS

; SD_WRITE_SECTOR - write WRKBUF to ZP_LBA and wait for the programming to
; finish. ZP_ERR = 0 on success.
SD_WRITE_SECTOR:
    LDA #$00
    STA ZP_ERR
    STA RAMRDOFF            ; WRKBUF is read from MAIN
    LDA #$00
    STA ZP_BUFLO
    JSR SD_ARG_FROM_LBA
    ; CMD24 WRITE_BLOCK: 58 (0x40+24) then the LBA, MSB first. V_ARG is
    ; MSB-first (V_ARG = ZP_LBA3), so send it down first.
    LDA #$58
    JSR SPI_SEND_A
    LDA V_ARG
    JSR SPI_SEND_A
    LDA V_ARG+1
    JSR SPI_SEND_A
    LDA V_ARG+2
    JSR SPI_SEND_A
    LDA V_ARG+3
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A          ; CRC
    JSR SPI_READ_A          ; R1
    CMP #$00
    BEQ SWS_DATA
    JMP SWS_FAIL
SWS_DATA:
    LDA #$FE                ; data token
    JSR SPI_SEND_A
    LDX #$00
SWS_L0:
    LDA WRKBUF,X
    LDY #$00
    STA (ZP_SPIDATLO),Y
    LDA #$00
    STA ZP_SCR2
    STA ZP_SCR3
SWS_WAIT0:
    LDA (ZP_SPISTLO),Y
    BPL SWS_READY0
    INC ZP_SCR2
    BNE SWS_WAIT0
    INC ZP_SCR3
    BNE SWS_WAIT0
    LDA #$01
    STA ZP_ERR
SWS_READY0:
    INX
    BNE SWS_L0
    LDX #$00
SWS_L1:
    LDA WRKBUF+256,X
    LDY #$00
    STA (ZP_SPIDATLO),Y
    LDA #$00
    STA ZP_SCR2
    STA ZP_SCR3
SWS_WAIT1:
    LDA (ZP_SPISTLO),Y
    BPL SWS_READY1
    INC ZP_SCR2
    BNE SWS_WAIT1
    INC ZP_SCR3
    BNE SWS_WAIT1
    LDA #$01
    STA ZP_ERR
SWS_READY1:
    INX
    BNE SWS_L1
    JSR SPI_SEND_A          ; the two CRC bytes
    JSR SPI_SEND_A
    JSR SPI_READ_A          ; data response token: $05 means accepted
    AND #$1F                ; only the lower five bits define the response
    CMP #$05
    BNE SWS_FAIL
    ; A card holds the line low while it programs the block. Bounded wait, so a
    ; card that never frees the line reports an error instead of hanging.
    LDA #$FF
    STA ZP_SCR0
    STA ZP_SCR1
SWS_BUSY:
    JSR SPI_READ_A
    CMP #$00
    BNE SWS_FREED
    DEC ZP_SCR0
    BNE SWS_BUSY
    DEC ZP_SCR1
    BNE SWS_BUSY
    JMP SWS_FAIL
SWS_FREED:
    JSR SPI_READ_A          ; flush the byte that freed the line
    RTS
SWS_FAIL:
    LDA #$01
    STA ZP_ERR
    RTS

; GET_SD_TOTAL - the capacity in 512-byte sectors, from CMD9 (SEND_CSD).
;   C_SIZE = ((b12 & mask) << 16) | (b13 << 8) | b14
; mask $3F on a version 1 CSD, $7F on version 2 (the structure version is bits
; 7:6 of byte 0), and total = (C_SIZE + 1) * 1024 sectors either way. All 21
; CSD bytes are consumed so nothing stale is left for the next command.
GET_SD_TOTAL:
    LDA #$00
    STA RAMWRTOFF
    STA ZP_ERR
    ; CMD9 SEND_CSD: 49 (0x40+9), argument 0
    LDA #$49
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A          ; CRC
    ; No R1/data-token check here: the proven verasdedit path reads the CSD
    ; bytes directly after the frame. Checking the R1 would reject a card whose
    ; response timing differs, and the emulator returns the 21-byte CSD right
    ; after the frame anyway.
    LDX #$00
GST_LOOP:
    JSR SPI_READ_A
    STA WRKBUF,X            ; keep the raw stream for the row-4 diagnostic
    CPX #$0C                ; byte 12 -> c_size high bits
    BNE GST_NOT12
    AND #$3F                ; top 6 bits of c_size
    STA V_CSIZE             ; high byte
    JMP GST_NEXT
GST_NOT12:
    CPX #$0D                ; byte 13 -> c_size mid byte
    BNE GST_NOT13
    STA V_CSIZE+1           ; mid byte
    JMP GST_NEXT
GST_NOT13:
    CPX #$0E                ; byte 14 -> c_size low byte
    BNE GST_NEXT
    STA V_CSIZE+2           ; low byte
GST_NEXT:
    INX
    CPX #$15                ; 21 bytes
    BNE GST_LOOP
    ; total = c_size + 1   (32-bit into V_TOTAL)
    LDA V_CSIZE+2           ; low byte
    CLC
    ADC #$01
    STA V_TOTAL
    LDA V_CSIZE+1           ; mid byte
    ADC #$00
    STA V_TOTAL+1
    LDA V_CSIZE             ; high byte
    ADC #$00
    STA V_TOTAL+2
    LDA #$00
    ADC #$00
    STA V_TOTAL+3
    LDA #$0A                ; times 1024
    JSR SHL_TOTAL
    CLC
    RTS
GST_FAIL:
    LDA #$01
    STA ZP_ERR
    RTS

SHL_TOTAL:
    ; Called only from GET_SD_TOTAL, which forces RAMWRTOFF and does no
    ; display in between — so the V_TOTAL stores below land in MAIN.
    STA ZP_TEMP
SHL_TL:
    ASL V_TOTAL
    ROL V_TOTAL+1
    ROL V_TOTAL+2
    ROL V_TOTAL+3
    DEC ZP_TEMP
    BNE SHL_TL
    RTS

; =============================================================================
; VERA CARD ACCESS
; =============================================================================
; DETECT_SLOTS - find the VERA card, slot 2 first, then slot 4. Sets ZP_VERA
; LO/HI to the base address. With no card anywhere it says so and leaves; a
; formatter that cannot reach the card must not sit there blinking.
DETECT_SLOTS:
    LDA #$C2
    STA ZP_VERAHI
    LDA #$00
    STA ZP_VERALO
    JSR DETECT_VERA
    BCS DS_DONE
    LDA #$C4
    STA ZP_VERAHI
    LDA #$00
    STA ZP_VERALO
    JSR DETECT_VERA
    BCS DS_DONE
    LDX #<MSG_NOVERA
    LDY #>MSG_NOVERA
    JSR PSTR
    JSR READ_KEY_ANY
    JMP QUIT
DS_DONE:
    RTS

; DETECT_VERA - probe the card at ZP_VERALO/HI. Carry set when it answers.
; Writes CTRL and checks the readback, then pushes two bytes through DATA0.
DETECT_VERA:
    LDA ZP_VERALO
    STA ZP_PTR
    LDA ZP_VERAHI
    STA ZP_PTRHI
    LDY #$05                ; CTRL
    LDA #$01
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    CMP #$01
    BNE DV_FAIL
    LDA #$00
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    BNE DV_FAIL
    LDY #$00                ; ADDR_L/M/H = 0
    LDA #$00
    STA (ZP_PTR),Y
    INY
    STA (ZP_PTR),Y
    INY
    STA (ZP_PTR),Y
    INY                     ; Y = $03, DATA0
    LDA #$DE
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    CMP #$DE
    BNE DV_FAIL
    LDA #$6F
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    CMP #$6F
    BNE DV_FAIL
    SEC
    RTS
DV_FAIL:
    CLC
    RTS

; VERA_DISABLE_IRQ_VID - IEN = 0 and DC_VID = 0, so no interrupt and no display
; DMA steals cycles or the SD lines in the middle of a transfer.
VERA_DISABLE_IRQ_VID:
    LDA ZP_VERALO
    STA ZP_PTR
    LDA ZP_VERAHI
    STA ZP_PTRHI
    LDY #$06
    LDA #$00
    STA (ZP_PTR),Y          ; IEN
    LDY #$09
    STA (ZP_PTR),Y          ; DC_VID
    RTS

; SETUP_SPI_PTRS - point ZP_SPIDAT at base+$1E and ZP_SPIST at base+$1F.
SETUP_SPI_PTRS:
    CLC
    LDA ZP_VERALO
    ADC #$1E
    STA ZP_SPIDATLO
    LDA ZP_VERAHI
    ADC #$00
    STA ZP_SPIDATHI
    CLC
    LDA ZP_VERALO
    ADC #$1F
    STA ZP_SPISTLO
    LDA ZP_VERAHI
    ADC #$00
    STA ZP_SPISTHI
    RTS

; =============================================================================
; 32-BIT ARITHMETIC
;
; The values are little-endian, four bytes each. The assembler gives ADC no
; (zp),Y operand and gives SBC and CMP no indexed operand at all, so these
; helpers always copy the source operand into MATHSB first and work from there.
; ZP_PTR2 selects the destination, ZP_PTR3 the source; the caller presets the
; high bytes once because every variable lives on page $3A.
; =============================================================================
; CP32 - (ZP_PTR2) = (ZP_PTR3)
CP32:
    LDY #$00
CP_L0:
    LDA (ZP_PTR3),Y
    STA (ZP_PTR2),Y
    INY
    CPY #$04
    BNE CP_L0
    RTS

; CLR32 - (ZP_PTR2) = 0
CLR32:
    LDA #$00
    LDY #$03
CL_L:
    STA (ZP_PTR2),Y
    DEY
    BPL CL_L
    RTS

; ADD32 - (ZP_PTR2) += (ZP_PTR3), carry out ignored (no geometry here reaches
; 4 GiB, and the sector counts are checked against the card size)
ADD32:
    CLC
    LDY #$00
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    ADC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    ADC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    ADC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    ADC MATHSB
    STA (ZP_PTR2),Y
    RTS

; SUB32 - (ZP_PTR2) -= (ZP_PTR3)
SUB32:
    SEC
    LDY #$00
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    SBC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    SBC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    SBC MATHSB
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR3),Y
    STA MATHSB
    LDA (ZP_PTR2),Y
    SBC MATHSB
    STA (ZP_PTR2),Y
    RTS

; CMP32 - compare (ZP_PTR2) with (ZP_PTR3). Carry set when the destination is
; greater or equal, zero flag set when equal - the usual unsigned ordering.
; The vendored assembler silently emits CMP $0000 for "CMP MATHSB,Y" (it has no
; indexed-Y CMP). Compare through a zero-page scratch instead: CMP zp is
; supported, and ZP_SCR0 is free here (the busy-wait that uses it is not active
; on the capacity/geometry path).
CMP32:
    LDA #$94
    STA ZP_PTR2HI
    STA ZP_PTR3HI
    LDY #$03
CM_C:
    LDA (ZP_PTR3),Y
    STA ZP_SCR0
    LDA (ZP_PTR2),Y
    CMP ZP_SCR0
    BNE CM_R
    DEY
    BPL CM_C
    LDA #$00
CM_R:
    RTS

; SHL32 - (ZP_PTR2) <<= A bits
SHL32:
    BEQ SHL_DONE
    STA ZP_TEMP
SHL_OUT:
    CLC
    LDY #$00
    LDA (ZP_PTR2),Y
    ROL A
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR2),Y
    ROL A
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR2),Y
    ROL A
    STA (ZP_PTR2),Y
    INY
    LDA (ZP_PTR2),Y
    ROL A
    STA (ZP_PTR2),Y
    DEC ZP_TEMP
    BNE SHL_OUT
SHL_DONE:
    RTS

; SHR32 - (ZP_PTR2) >>= A bits, logical
SHR32:
    BEQ SHR_DONE
    STA ZP_TEMP
SHR_OUT:
    CLC                     ; the top byte rotates the clear bit in, the rest
    LDY #$03                ; rotate it down through the value
SHR_B:
    LDA (ZP_PTR2),Y
    ROR A
    STA (ZP_PTR2),Y
    DEY
    BPL SHR_B
    DEC ZP_TEMP
    BNE SHR_OUT
SHR_DONE:
    RTS

DIV32:
    LDA #$00
    STA RAMWRTOFF         ; V_REM/V_TMP1 live in MAIN; A is $00 here, so the
                          ; bank switch costs nothing
    STA V_REM
    STA V_REM+1
    STA V_REM+2
    STA V_REM+3
    LDA #$20
    STA ZP_TEMP
DV_LOOP:
    ASL V_TMP1
    ROL V_TMP1+1
    ROL V_TMP1+2
    ROL V_TMP1+3
    ROL V_REM               ; the bit shifted out of the dividend joins the
    ROL V_REM+1             ; remainder
    ROL V_REM+2
    ROL V_REM+3
    LDA #<V_REM
    STA ZP_PTR2
    LDA #<V_TMP2
    STA ZP_PTR3
    JSR CMP32
    BCC DV_SHIFTNEXT        ; remainder still too small
    LDA #<V_REM
    STA ZP_PTR2
    LDA #<V_TMP2
    STA ZP_PTR3
    JSR SUB32
    INC V_TMP1              ; this bit of the quotient is one
DV_SHIFTNEXT:
    DEC ZP_TEMP
    BNE DV_LOOP
    RTS

; =============================================================================
; COMPUTE_GEOMETRY - partition size, sectors per cluster, sectors per FAT
;
; The partition is everything from LBA 2048 to the end of the card. Sectors per
; cluster follows the table CMDR-DOS formats with, and the per-FAT size is the
; same fixed-point CMDR-DOS uses:
;
;     f = 0
;     repeat  clusters = (partsize - 32 - 2f) / spc
;             n = (((clusters + 2) * 4 + 511) / 512) rounded up to a
;                 multiple of 8
;     until   n == f
;
; Rounding to a multiple of 8 matters: the reference 100 MB card needs 786
; sectors and gets 792, and reproducing that keeps the result byte-for-byte
; comparable with a volume CMDR-DOS made. On that card this yields spc 2,
; 100568 clusters, 792 sectors per FAT and data starting at volume sector 1616,
; which is exactly what the reference image holds.
;
; A volume with fewer than 65525 clusters is FAT16 territory and no reader will
; call it FAT32, so the sector count is halved until there are enough clusters,
; and a card too small for that is refused rather than formatted wrongly.
; =============================================================================
COMPUTE_GEOMETRY:
    LDA #$00
    STA ZP_ERR
    STA RAMWRTOFF         ; VARS writes below; the probe screen's PSTR left
                          ; the write bank on whatever column it ended on
    LDA #$94
    STA ZP_PTR2HI           ; every VARS variable lives on page $44, so the
    STA ZP_PTR3HI           ; helper pointers only ever need their low byte set
    LDA #<PART_LBA
    STA V_PART
    LDA #>PART_LBA
    STA V_PART+1
    LDA #$00
    STA V_PART+2
    STA V_PART+3
    LDA V_TOTAL             ; V_PSIZE = V_TOTAL - PART_LBA
    SEC
    SBC #<PART_LBA
    STA V_PSIZE
    LDA V_TOTAL+1
    SBC #>PART_LBA
    STA V_PSIZE+1
    LDA V_TOTAL+2
    SBC #$00
    STA V_PSIZE+2
    LDA V_TOTAL+3
    SBC #$00
    STA V_PSIZE+3
    BCC CG_TOOSMALL         ; the card ends before the partition would start
    JSR CG_PICK_SPC
    LDA #$14
    STA V_RETRY
CG_SPC_LOOP:
    JSR CG_FIT_FAT
    LDA ZP_ERR
    BNE CG_OUT
    JSR CG_AVAIL
    ; enough clusters to honestly be called FAT32?
    LDA #<K_MINCLUST
    STA ZP_PTR
    LDA #>K_MINCLUST
    STA ZP_PTRHI
    JSR SET_CONST
    LDA #<V_CLUST
    STA ZP_PTR2
    LDA #<MATHSB
    STA ZP_PTR3
    JSR CMP32
    BCS CG_OK
    LDA V_SPC
    CMP #$01
    BEQ CG_TOOSMALL
    LSR V_SPC               ; too few clusters: halve the cluster size, retry
    DEC V_SPCSH
    DEC V_RETRY
    BNE CG_SPC_LOOP
    LDA #$02
    STA ZP_ERR
    JMP CG_OUT
CG_OK:
    CLC
    RTS
CG_TOOSMALL:
    LDA #$01
    STA ZP_ERR
CG_OUT:
    RTS

; CG_PICK_SPC - the CMDR-DOS sectors-per-cluster table for V_PSIZE
CG_PICK_SPC:
    LDA #$01
    STA V_SPC
    LDA #<K_131072
    STA ZP_PTR
    LDA #>K_131072
    STA ZP_PTRHI
    JSR SET_CONST
    JSR CMP_PSIZE
    BCC CG_PS_HAVE
    LDA #$02
    STA V_SPC
    LDA #<K_524288
    STA ZP_PTR
    LDA #>K_524288
    STA ZP_PTRHI
    JSR SET_CONST
    JSR CMP_PSIZE
    BCC CG_PS_HAVE
    LDA #$08
    STA V_SPC
    LDA #<K_16777216
    STA ZP_PTR
    LDA #>K_16777216
    STA ZP_PTRHI
    JSR SET_CONST
    JSR CMP_PSIZE
    BCC CG_PS_HAVE
    LDA #$10
    STA V_SPC
    LDA #<K_33554432
    STA ZP_PTR
    LDA #>K_33554432
    STA ZP_PTRHI
    JSR SET_CONST
    JSR CMP_PSIZE
    BCC CG_PS_HAVE
    LDA #$20
    STA V_SPC
    LDA #<K_268435456
    STA ZP_PTR
    LDA #>K_268435456
    STA ZP_PTRHI
    JSR SET_CONST
    JSR CMP_PSIZE
    BCC CG_PS_HAVE
    LDA #$40
    STA V_SPC
CG_PS_HAVE:
    LDA #$00                ; V_SPCSH = log2(V_SPC)
    STA V_SPCSH
    LDA V_SPC
CG_LOG:
    CMP #$01
    BEQ CG_LOGDONE
    LSR
    INC V_SPCSH
    JMP CG_LOG
CG_LOGDONE:
    RTS

; CMP_PSIZE - compare V_PSIZE with MATHSB. Carry set when V_PSIZE >= MATHSB.
CMP_PSIZE:
    LDA #<V_PSIZE
    STA ZP_PTR2
    LDA #<MATHSB
    STA ZP_PTR3
    JMP CMP32

; CG_FIT_FAT - the fixed-point loop for the sectors-per-FAT field
CG_FIT_FAT:
    LDA #$00
    LDY #$03
CG_FZ:
    STA V_FATSZ,Y
    DEY
    BPL CG_FZ
    LDA #$14
    STA V_RETRY
CG_FAT_LOOP:
    JSR CG_AVAIL
    ; V_TMP3 = ((V_CLUST + 2) << 2 + 511) >> 9
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<V_CLUST
    STA ZP_PTR3
    JSR CP32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$02
    JSR ADD_IMM8
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$02
    JSR SHL32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<K_511
    STA ZP_PTR
    LDA #>K_511
    STA ZP_PTRHI
    JSR ADD_CONST
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$09
    JSR SHR32
    ; round up to a multiple of 8, the way CMDR-DOS does
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$07
    JSR ADD_IMM8
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$03
    JSR SHR32
    LDA #$03
    JSR SHL32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<V_FATSZ
    STA ZP_PTR3
    JSR CMP32
    BEQ CG_FAT_DONE         ; the size agrees with the assumption
    LDA #<V_FATSZ
    STA ZP_PTR2
    LDA #<V_TMP3
    STA ZP_PTR3
    JSR CP32
    DEC V_RETRY
    BNE CG_FAT_LOOP
    LDA #$02
    STA ZP_ERR
    RTS
CG_FAT_DONE:
    LDA #$00
    STA ZP_ERR
    RTS

; CG_AVAIL - V_CLUST and V_DATA for the current V_FATSZ
CG_AVAIL:
    LDA #<V_TMP4            ; V_TMP4 = 2 * V_FATSZ
    STA ZP_PTR2
    LDA #<V_FATSZ
    STA ZP_PTR3
    JSR CP32
    LDA #<V_TMP4
    STA ZP_PTR2
    LDA #$01
    JSR SHL32
    LDA #<V_TMP1            ; V_TMP1 = V_PSIZE - 32 - V_TMP4
    STA ZP_PTR2
    LDA #<V_PSIZE
    STA ZP_PTR3
    JSR CP32
    LDA #<V_TMP1
    STA ZP_PTR2
    LDA #<K_32
    STA ZP_PTR
    LDA #>K_32
    STA ZP_PTRHI
    JSR SUB_CONST
    LDA #<V_TMP1
    STA ZP_PTR2
    LDA #<V_TMP4
    STA ZP_PTR3
    JSR SUB32
    LDA #<V_CLUST           ; V_CLUST = V_TMP1 >> V_SPCSH
    STA ZP_PTR2
    LDA #<V_TMP1
    STA ZP_PTR3
    JSR CP32
    LDA #<V_CLUST
    STA ZP_PTR2
    LDA V_SPCSH
    JSR SHR32
    LDA #<V_DATA            ; V_DATA = 32 + V_TMP4
    STA ZP_PTR2
    LDA #<V_TMP4
    STA ZP_PTR3
    JSR CP32
    LDA #<V_DATA
    STA ZP_PTR2
    LDA #<K_32
    STA ZP_PTR
    LDA #>K_32
    STA ZP_PTRHI
    JSR ADD_CONST
    RTS

; ADD_IMM8 - add A to the four bytes ZP_PTR2 points at. The value goes through
; MATHSB because this assembler gives ADC no indirect operand.
ADD_IMM8:
    STA MATHSB
    LDA #$00
    STA MATHSB+1
    STA MATHSB+2
    STA MATHSB+3
    LDA #<MATHSB
    STA ZP_PTR3
    JMP ADD32

SUB_CONST:
    JSR SET_CONST
    LDA #<MATHSB
    STA ZP_PTR3
    JMP SUB32

ADD_CONST:
    JSR SET_CONST
    LDA #<MATHSB
    STA ZP_PTR3
    JMP ADD32

; SET_CONST - MATHSB = the four bytes at ZP_PTR/ZP_PTRHI
SET_CONST:
    LDY #$03
SETC_L:
    LDA (ZP_PTR),Y
    STA MATHSB,Y
    DEY
    BPL SETC_L
    RTS

; SET_LBA_FROM_PART - ZP_LBA = V_PART + A
SET_LBA_FROM_PART:
    STA ZP_TEMP
    LDA V_PART
    CLC
    ADC ZP_TEMP
    STA ZP_LBA0
    LDA V_PART+1
    ADC #$00
    STA ZP_LBA1
    LDA V_PART+2
    ADC #$00
    STA ZP_LBA2
    LDA V_PART+3
    ADC #$00
    STA ZP_LBA3
    RTS

; LBA_PLUS_FATSZ - step from FAT #1 to FAT #2
LBA_PLUS_FATSZ:
    CLC
    LDA ZP_LBA0
    ADC V_FATSZ
    STA ZP_LBA0
    LDA ZP_LBA1
    ADC V_FATSZ+1
    STA ZP_LBA1
    LDA ZP_LBA2
    ADC V_FATSZ+2
    STA ZP_LBA2
    LDA ZP_LBA3
    ADC V_FATSZ+3
    STA ZP_LBA3
    RTS

; SET_LBA_DATA_AREA - ZP_LBA = the first cluster of the volume
SET_LBA_DATA_AREA:
    CLC
    LDA V_PART
    ADC V_DATA
    STA ZP_LBA0
    LDA V_PART+1
    ADC V_DATA+1
    STA ZP_LBA1
    LDA V_PART+2
    ADC V_DATA+2
    STA ZP_LBA2
    LDA V_PART+3
    ADC V_DATA+3
    STA ZP_LBA3
    RTS

; =============================================================================
; DISPLAY
;
; The 80-column text page interleaves MAIN and AUX per column: each 40-address
; cell renders AUX on the left and MAIN on the right, so PUTCH has to switch the
; write bank for every character. Row R starts at $0400 + (R&7)*$80 + (R/8)*$28,
; which is scrambled rather than linear, hence GOTO_ROW computing it.
; The cursor stops at the last row instead of scrolling: every screen this
; program draws is laid out to fit 24 rows, so scrolling would only hide bugs.
; =============================================================================
CLEAR_SCREEN:
    LDA #$00
    STA RAMWRTOFF
    JSR CLEAR_BANK
    LDA #$00
    STA RAMWRTON
    JSR CLEAR_BANK
    LDA #$00
    STA RAMWRTOFF
    RTS

CLEAR_BANK:
    LDA #$A0                ; a normal space has bit7 set
    LDX #$00
CB_L0:
    STA $0400,X
    INX
    BNE CB_L0
    LDX #$00
CB_L1:
    STA $0500,X
    INX
    BNE CB_L1
    LDX #$00
CB_L2:
    STA $0600,X
    INX
    BNE CB_L2
    LDX #$00
CB_L3:
    STA $0700,X
    INX
    BNE CB_L3
    RTS

; PRINT_STRING - print the zero-terminated string at ZP_PTR/ZP_PTRHI. A $0D in
; the string moves to the start of the next row, which is how the messages
; below carry their own line breaks.
PRINT_STRING:
    LDA #$00
    STA ZP_DISPMODE
    LDY #$00
PS_LOOP:
    LDA (ZP_PTR),Y
    BEQ PS_DONE
    CMP #$0D
    BEQ PS_CR
    JSR PUTCH
    INY
    JMP PS_LOOP
PS_CR:
    JSR ROW_ADVANCE
    INY
    JMP PS_LOOP
PS_DONE:
    RTS

; PSTR - print the message whose address is in X (low) and Y (high). Three
; instructions instead of five: with about fifty message prints in this program
; that is a quarter of a kilobyte, which is what keeps the code out of the
; sector buffers.
PSTR:
    STX ZP_PTR
    STY ZP_PTRHI
    JMP PRINT_STRING

; PUTCH - write A to the cursor and advance it.
PUTCH:
    STA ZP_TEMP
    TYA
    PHA                     ; Y survives, so callers may index through a loop
    LDA ZP_COL
    LSR A                   ; cell offset, carry = this is an odd column
    TAY
    BCS PUTCH_MAIN
    LDA #$00
    STA RAMWRTON            ; even column lands in AUX
    JMP PUTCH_WRITE
PUTCH_MAIN:
    LDA #$00
    STA RAMWRTOFF           ; odd column lands in MAIN
PUTCH_WRITE:
    LDA ZP_TEMP
    LDX ZP_DISPMODE
    CPX #$01
    BEQ PUTCH_INV
    CPX #$02
    BEQ PUTCH_FLASH
    ORA #$80                ; normal
    JMP PUTCH_STORE
PUTCH_INV:
    AND #$3F                ; inverse
    JMP PUTCH_STORE
PUTCH_FLASH:
    AND #$3F
    ORA #$40                ; flash
PUTCH_STORE:
    STA (ZP_CURSOR),Y
    INC ZP_COL
    LDA ZP_COL
    CMP #$50                ; past column 79 the row is full
    BNE PUTCH_DONE
    JSR ROW_ADVANCE
PUTCH_DONE:
    PLA
    TAY
    RTS

ROW_ADVANCE:
    LDA ZP_ROW
    CMP #$17                ; row 23 is the last one; stop there
    BCS RA_RESET
    INC ZP_ROW
    LDA ZP_ROW
    AND #$07
    BNE RA_ADD80
    SEC                     ; wrapping into the next bank of rows: subtract the
    LDA ZP_CURSOR           ; eleven rows we just added and add $28
    SBC #$58
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    SBC #$03
    STA ZP_CURSORHI
    JMP RA_RESET
RA_ADD80:
    LDA ZP_CURSOR
    CLC
    ADC #$80
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    ADC #$00
    STA ZP_CURSORHI
RA_RESET:
    LDA #$00
    STA ZP_COL
    STA RAMWRTOFF
    RTS

SET_CURSOR_HOME:
    LDA #$00
    STA ZP_CURSOR
    STA ZP_COL
    STA ZP_ROW
    LDA #$04
    STA ZP_CURSORHI
    RTS

; GOTO_ROW - put the cursor at the start of display row A
GOTO_ROW:
    STA ZP_TEMP2
    STA ZP_ROW
    AND #$07
    TAY
    TYA
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                   ; (R&7) << 7, the low byte of the row offset
    STA ZP_CURSOR
    TYA
    LSR A
    CLC
    ADC #$04
    STA ZP_CURSORHI
    LDA ZP_TEMP2
    LSR A
    LSR A
    LSR A                   ; R / 8
    STA ZP_TEMP2
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                   ; (R/8) * 32
    STA ZP_TEMP
    LDA ZP_TEMP2
    ASL A
    ASL A
    ASL A                   ; (R/8) * 8
    CLC
    ADC ZP_TEMP             ; (R/8) * 40
    CLC
    ADC ZP_CURSOR
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    ADC #$00
    STA ZP_CURSORHI
    LDA #$00
    STA ZP_COL
    RTS

; READ_KEY - A = the key down (bit7 stripped), or 0 when nothing is pressed
READ_KEY:
    LDA KBD
    BPL RK_NONE
    STA KBDSTRB
    AND #$7F
    RTS
RK_NONE:
    LDA #$00
    RTS

; READ_KEY_W - wait for a key and fold letters to upper case
READ_KEY_W:
    JSR READ_KEY
    BEQ READ_KEY_W
    CMP #$61
    BCC RKW_DONE
    CMP #$7B
    BCS RKW_DONE
    AND #$DF
RKW_DONE:
    RTS

; READ_KEY_ANY - wait for any key at all
READ_KEY_ANY:
    JSR READ_KEY
    BEQ READ_KEY_ANY
    RTS

; CHECK_ESC - set ZP_ABORT when ESC has been pressed. Polled between sectors so
; a long zero-fill can be stopped, which leaves the card half written; the
; message that follows says exactly that.
CHECK_ESC:
    LDA KBD
    BPL CE_NONE
    STA KBDSTRB
    AND #$7F
    CMP #ESC_KEY
    BNE CE_NONE
    LDA #$01
    STA ZP_ABORT
CE_NONE:
    RTS

; PRINT_HEX2 - A as two hex digits
PRINT_HEX2:
    PHA
    LSR A
    LSR A
    LSR A
    LSR A
    JSR PRINT_NIB
    PLA
    AND #$0F
    JSR PRINT_NIB
    RTS

PRINT_NIB:
    AND #$0F
    CLC
    ADC #$30
    CMP #$3A
    BCC PN_OUT
    ADC #$06                ; A-F: +$06 plus the carry from CMP = +$07
PN_OUT:
    JSR PUTCH
    RTS

; PRINT_DEC32W - print the 32-bit value at ZP_PTR2 as ZP_TEMP2 right-aligned
; decimal digits. DIV32 does not preserve the helper pointers, so the source is
; saved and restored around the digit loop.
PRINT_DEC32W:
    ; The SD routines clobber the helper high bytes; pin them to page $44 so
    ; the (ZP_PTR2),Y / (ZP_PTR3),Y reads land on VARS, whatever ran before.
    LDA #$94
    STA ZP_PTR2HI
    STA ZP_PTR3HI
    ; PUTCH leaves RAMWRT on whichever bank the last column used; force MAIN so
    ; every store below (V_DIGBUF, V_TMP1, DIV32's in-place work) lands where
    ; the reads and the digit-output phase will look.
    LDA #$00
    STA RAMWRTOFF
    LDA ZP_PTR2
    STA ZP_SCR2
    LDA #$00
    STA ZP_SCR3
PDW_FILL:
    LDY #$0B
    LDA #$20
PDW_F2:
    STA V_DIGBUF,Y
    DEY
    BPL PDW_F2
    LDY #$03
PDW_CP:
    LDA (ZP_PTR2),Y
    STA V_TMP1,Y
    DEY
    BPL PDW_CP
    LDX #$0B
PDW_LOOP:
    LDA #$0A
    STA V_TMP2
    LDA #$00
    STA V_TMP2+1
    STA V_TMP2+2
    STA V_TMP2+3
    JSR DIV32
    CLC
    LDA V_REM
    ADC #$30
    STA V_DIGBUF,X
    DEX
    INC ZP_SCR3
    LDA ZP_SCR3
    CMP #$20
    BEQ PDW_DONE            ; bounded: never run more than 32 digits
    LDA V_TMP1
    ORA V_TMP1+1
    ORA V_TMP1+2
    ORA V_TMP1+3
    BNE PDW_LOOP
PDW_DONE:
    LDA ZP_SCR2
    STA ZP_PTR2
    ; print the fixed width from the digit buffer
    LDA #$0C
    SEC
    SBC ZP_TEMP2
    TAY
PDW_OUT:
    LDA V_DIGBUF,Y
    JSR PUTCH
    INY
    CPY #$0C
    BNE PDW_OUT
    RTS

; PRINT_11 - print the 11 padded characters of a volume label whose offset in
; WRKBUF is in X. PUTCH clobbers X, so the field is addressed through a pointer
; and only Y, which PUTCH preserves, counts through it.
PRINT_11:
    STX ZP_TEMP2
    LDA #$00
    STA ZP_PTR
    LDA #>WRKBUF
    STA ZP_PTRHI
    LDA ZP_TEMP2
    CLC
    ADC ZP_PTR
    STA ZP_PTR
    LDY #$00
P11_LOOP:
    LDA (ZP_PTR),Y
    CMP #$20
    BEQ P11_PAD
    JSR PUTCH
    INY
    CPY #$0B
    BNE P11_LOOP
    RTS
P11_PAD:
    CPY #$0B
    BEQ P11_DONE
    LDA #$20
    JSR PUTCH
    INY
    JMP P11_PAD
P11_DONE:
    RTS

; =============================================================================
; SCREEN LINES. Everything is placed on an explicit row so no screen can push
; text off the bottom, and the values are reprinted from the variables rather
; than cached, so what the user reads is what the formatter will write.
; =============================================================================
SHOW_VERA_LINE:
    LDA #$02
    JSR GOTO_ROW
    LDX #<MSG_SLOT
    LDY #>MSG_SLOT
    JSR PSTR
    LDA #$24                ; value column 36
    STA ZP_COL
    LDA ZP_VERAHI
    SEC
    SBC #$C0                ; $C2 -> slot 2, $C4 -> slot 4
    JSR PRINT_DEC32_1
    LDA #$03
    JSR GOTO_ROW
    LDX #<MSG_SPIK
    LDY #>MSG_SPIK
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA ZP_SDCLK
    AND #$02
    BEQ SV_FAST
    LDX #<MSG_SVSLOW
    LDY #>MSG_SVSLOW
    JSR PSTR
    RTS
SV_FAST:
    LDX #<MSG_SVFAST
    LDY #>MSG_SVFAST
    JSR PSTR
    RTS

; PRINT_DEC32_1 - A as a single unsigned decimal digit (the slot number)
PRINT_DEC32_1:
    CMP #$0A
    BCC PD1_OK
    JSR PRINT_HEX2          ; never reached on a real card, but harmless
    RTS
PD1_OK:
    CLC
    ADC #$30
    JSR PUTCH
    RTS

SHOW_CAP_LINE:
    LDA #$04
    JSR GOTO_ROW
    LDX #<MSG_CAPA
    LDY #>MSG_CAPA
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_TOTAL
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDX #<MSG_CAPB
    LDY #>MSG_CAPB
    JSR PSTR
    ; MiB = sectors >> 11. Copy V_TOTAL to V_TMP3 first so V_TOTAL stays intact!
    LDA #$00
    STA RAMWRTOFF
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<V_TOTAL
    STA ZP_PTR3
    JSR CP32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$0B                ; 11 bits (2048 sectors per MiB)
    JSR SHR32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$05
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDX #<MSG_CAPC
    LDY #>MSG_CAPC
    JSR PSTR
    RTS

; PROBE_EXISTING - read the MBR and the partition's boot sector and report what
; is on the card right now. The point of this screen is that a person can
; recognise the volume they are about to erase.
PROBE_EXISTING:
    LDA #$06
    JSR GOTO_ROW
    LDX #<MSG_EXIST
    LDY #>MSG_EXIST
    JSR PSTR
    ; ---- the master boot record -------------------------------------------
    LDA #$07
    JSR GOTO_ROW
    LDX #<MSG_MBRAT
    LDY #>MSG_MBRAT
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    LDA #$80
    STA ZP_BUFPG
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE PE_MBRREAD
    LDA WRKBUF+$1FE
    CMP #$55
    BNE PE_NOMBR
    LDA WRKBUF+$1FF
    CMP #$AA
    BNE PE_NOMBR
    LDX #<MSG_MBRYES
    LDY #>MSG_MBRYES
    JSR PSTR
    LDA WRKBUF+$1C2         ; the type of the first partition entry
    JSR PRINT_HEX2
    LDA WRKBUF+$1C2
    BEQ PE_MBRDONE
    LDX #<MSG_MBRTYPE
    LDY #>MSG_MBRTYPE
    JSR PSTR
    JMP PE_MBRDONE
PE_NOMBR:
    LDX #<MSG_MBRNONE
    LDY #>MSG_MBRNONE
    JSR PSTR
    JMP PE_MBRDONE
PE_MBRREAD:
    LDX #<MSG_READFAIL
    LDY #>MSG_READFAIL
    JSR PSTR
PE_MBRDONE:
    ; ---- what sits at the partition start ---------------------------------
    LDA #$08
    JSR GOTO_ROW
    LDX #<MSG_VBRAT
    LDY #>MSG_VBRAT
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_PART
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$80
    STA ZP_BUFPG
    LDY #$03
PE_SETPART:
    LDA V_PART,Y
    STA ZP_LBA0,Y
    DEY
    BPL PE_SETPART
    JSR SD_READ_SECTOR
    LDA ZP_ERR
    BNE PE_VBRREAD
    LDX #$06
PE_FATCHK:
    LDA TXT_FAT32,X
    CMP WRKBUF+$52,X
    BNE PE_NOFAT
    DEX
    BPL PE_FATCHK
    LDA #$20
    JSR PUTCH
    LDX #<MSG_VFAT32
    LDY #>MSG_VFAT32
    JSR PSTR
    LDX #$47                ; the label of the volume that is there now
    JSR PRINT_11
    RTS
PE_NOFAT:
    LDX #<MSG_VNOFAT
    LDY #>MSG_VNOFAT
    JSR PSTR
    RTS
PE_VBRREAD:
    LDX #<MSG_READFAIL
    LDY #>MSG_READFAIL
    JSR PSTR
    RTS

; SHOW_LAYOUT - what is going to be written
SHOW_LAYOUT:
    LDA #$94
    STA ZP_PTR2HI
    STA ZP_PTR3HI
    LDA #$00
    STA RAMWRTOFF
    LDA #$0A
    JSR GOTO_ROW
    LDX #<MSG_LAYOUT
    LDY #>MSG_LAYOUT
    JSR PSTR
    LDA #$0B
    JSR GOTO_ROW
    LDX #<MSG_LPART
    LDY #>MSG_LPART
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_PART
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$0C
    JSR GOTO_ROW
    LDX #<MSG_LSIZE
    LDY #>MSG_LSIZE
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_PSIZE
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$0D
    JSR GOTO_ROW
    LDX #<MSG_LSPC
    LDY #>MSG_LSPC
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA V_SPC
    JSR PRINT_DEC32_1
    LDX #<MSG_LSECT
    LDY #>MSG_LSECT
    JSR PSTR
    LDA #$0E
    JSR GOTO_ROW
    LDX #<MSG_LCLUST
    LDY #>MSG_LCLUST
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_CLUST
    STA ZP_PTR2
    LDA #$07
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$0F
    JSR GOTO_ROW
    LDX #<MSG_LFAT
    LDY #>MSG_LFAT
    JSR PSTR
    LDA #$24
    STA ZP_COL
    LDA #<V_FATSZ
    STA ZP_PTR2
    LDA #$06
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDA #$10
    JSR GOTO_ROW
    LDX #<MSG_LDATA
    LDY #>MSG_LDATA
    JSR PSTR
    LDA #$24
    STA ZP_COL
    ; first data LBA = V_PART + V_DATA
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<V_DATA
    STA ZP_PTR3
    JSR CP32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #<V_PART
    STA ZP_PTR3
    JSR ADD32
    LDA #<V_TMP3
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    RTS

; SHOW_TARGET - on the confirmation screen, what is about to be destroyed
SHOW_TARGET:
    LDA #$05
    JSR GOTO_ROW
    LDX #<MSG_TGT
    LDY #>MSG_TGT
    JSR PSTR
    LDA #<V_TOTAL
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDX #<MSG_TGTC
    LDY #>MSG_TGTC
    JSR PSTR
    LDA #<V_PSIZE
    STA ZP_PTR2
    LDA #$08
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDX #<MSG_TGTD
    LDY #>MSG_TGTD
    JSR PSTR
    RTS

SHOW_CHOICES:
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME
    LDX #<MSG_MENUTITLE
    LDY #>MSG_MENUTITLE
    JSR PSTR
    LDX #<MSG_CHOICES
    LDY #>MSG_CHOICES
    JSR PSTR
    RTS

SHOW_RESULT:
    JSR SET_CURSOR_END
    LDA V_VERERR
    ORA V_VERERR+1
    BNE SR_BAD
    LDX #<MSG_PASS
    LDY #>MSG_PASS
    JSR PSTR
    LDX #<MSG_PRESSKEY
    LDY #>MSG_PRESSKEY
    JSR PSTR
    JMP SR_WAIT
SR_BAD:
    LDX #<MSG_FAIL
    LDY #>MSG_FAIL
    JSR PSTR
    LDA #<V_VERERR
    STA ZP_PTR2
    LDA #$03
    STA ZP_TEMP2
    JSR PRINT_DEC32W
    LDX #<MSG_FAILB
    LDY #>MSG_FAILB
    JSR PSTR
    LDX #<MSG_PRESSKEY
    LDY #>MSG_PRESSKEY
    JSR PSTR
SR_WAIT:
    JSR READ_KEY_ANY
    RTS

; SET_CURSOR_END - keep the existing screen and continue at the current cursor
SET_CURSOR_END:
    RTS

; SUB_IMM8 - subtract A from the four bytes ZP_PTR2 points at
SUB_IMM8:
    STA MATHSB
    LDA #$00
    STA MATHSB+1
    STA MATHSB+2
    STA MATHSB+3
    LDA #$94
    STA ZP_PTR3HI
    LDA #<MATHSB
    STA ZP_PTR3
    JMP SUB32

; =============================================================================
; STAGE TABLE
;
;   +0 label (low, high)   +2 template builder (low, high)   +4 sector count
;   +5 where it starts     +6 offset within that             +7 flags
;
; Twelve entries of eight bytes. If an entry is added or removed, RF_BYTES has
; to change with it: this assembler cannot compute a difference between two
; labels, so the loop bound is the one literal in the program that is not
; derived.
; =============================================================================
RF_BYTES     = 96

RF_TAB:
    !BYTE <MSG_STG_ZERO, >MSG_STG_ZERO, <BUILD_ZEROS, >BUILD_ZEROS
    !BYTE CK_TOTAL, LK_ZERO, 0, 0
    !BYTE <MSG_STG_MBR, >MSG_STG_MBR, <BUILD_MBR, >BUILD_MBR
    !BYTE CK_ONE, LK_ZERO, 0, 0
    !BYTE <MSG_STG_VBR, >MSG_STG_VBR, <BUILD_VBR, >BUILD_VBR
    !BYTE CK_ONE, LK_PART, 0, 0
    !BYTE <MSG_STG_FS, >MSG_STG_FS, <BUILD_FSINFO, >BUILD_FSINFO
    !BYTE CK_ONE, LK_PART, 1, 0
    !BYTE <MSG_STG_BKV, >MSG_STG_BKV, <BUILD_VBR, >BUILD_VBR
    !BYTE CK_ONE, LK_PART, 6, 0
    !BYTE <MSG_STG_BKF, >MSG_STG_BKF, <BUILD_FSINFO, >BUILD_FSINFO
    !BYTE CK_ONE, LK_PART, 7, 0
    !BYTE <MSG_STG_F1A, >MSG_STG_F1A, <BUILD_FAT0, >BUILD_FAT0
    !BYTE CK_ONE, LK_PART, 32, 0
    !BYTE <MSG_STG_F1B, >MSG_STG_F1B, <BUILD_ZEROS, >BUILD_ZEROS
    !BYTE CK_FATSZ_M1, LK_PART, 33, 0
    !BYTE <MSG_STG_F2A, >MSG_STG_F2A, <BUILD_FAT0, >BUILD_FAT0
    !BYTE CK_ONE, LK_PART, 32, FL_FATSZ
    !BYTE <MSG_STG_F2B, >MSG_STG_F2B, <BUILD_ZEROS, >BUILD_ZEROS
    !BYTE CK_FATSZ_M1, LK_PART, 33, FL_FATSZ
    !BYTE <MSG_STG_ROOT, >MSG_STG_ROOT, <BUILD_ROOT, >BUILD_ROOT
    !BYTE CK_ONE, LK_DATA, 0, 0
    !BYTE <MSG_STG_RPAD, >MSG_STG_RPAD, <BUILD_ZEROS, >BUILD_ZEROS
    !BYTE CK_SPC_M1, LK_DATA, 1, 0
RF_TABEND:

; -----------------------------------------------------------------------------
; 32-bit constants the geometry needs. Little-endian.
; -----------------------------------------------------------------------------
K_32:         !BYTE 20, 00, 00, 00
K_100:        !BYTE 100, 00, 00, 00
K_511:        !BYTE $FF, $01, 00, 00
K_MINCLUST:   !BYTE $F5, $FF, 00, 00
K_131072:     !BYTE 00, 00, 02, 00
K_524288:     !BYTE 00, 00, 08, 00
K_16777216:   !BYTE 00, 00, 00, 01
K_33554432:   !BYTE 00, 00, 02, 01
K_268435456:  !BYTE 00, 00, 00, 10

; -----------------------------------------------------------------------------
; Volume identity strings. The OEM name and the "FAT32   " marker are what the
; readers look at; the label is deliberately generic so it says what the volume
; is for rather than what made it.
; -----------------------------------------------------------------------------
TXT_OEM:      ASC "CMDR-DOS"
TXT_FAT32:    ASC "FAT32   "
TXT_LABEL:    ASC "X16 DISK   "
FMT_WORD:     ASC "FORMAT"

; -----------------------------------------------------------------------------
; Messages. $0D starts the next row, so a message carries its own line breaks.
; -----------------------------------------------------------------------------
MSG_TITLE:
    ASC "VeraSDFormat - FAT32 Formatter for VERA SD v1.03 by anomixer"
    !BYTE $0D, 0
MSG_VERS:
    !BYTE 0
MSG_NOVERA:
    !BYTE $0D
    ASC "No VERA card on slot 2 or slot 4."
    !BYTE $0D
    ASC "Nothing was changed. Press any key."
    !BYTE 0
MSG_INITSD:
    ASC "  Init SD"
    !BYTE $0D, 0
MSG_CMDR1:
    ASC "CMD0 R1=$"
    !BYTE 0
MSG_ACMDR1:
    ASC "  ACMD41=$"
    !BYTE 0
MSG_READR1:
    ASC "  READ=$"
    !BYTE 0


MSG_SDFAIL:
    !BYTE $0D
    ASC "  SD card did not respond. Nothing was changed."
    !BYTE $0D
    ASC "  Press any key."
    !BYTE 0
MSG_SMALL:
    !BYTE $0D
    ASC "  This card is too small for a FAT32 volume"
    !BYTE $0D
    ASC "  with 65525 clusters. Nothing was changed."
    !BYTE 0
MSG_ANYKEY:
    !BYTE $0D
    ASC "  Press any key to leave."
    !BYTE 0
MSG_ABORTED:
    !BYTE $0D
    ASC "  STOPPED BY YOU - the card is half written"
    !BYTE $0D
    ASC "  and not mountable. Run a format again."
    !BYTE 0
MSG_WRITEFAIL:
    ASC "SD WRITE FAILED"
    !BYTE 0
MSG_SLOT:
    ASC "  VERA card:       Slot "
    !BYTE 0
MSG_SPIK:
    ASC "  SPI clock:       "
    !BYTE 0
MSG_SVSLOW:
    ASC "slow (390 kHz)"
    !BYTE 0
MSG_SVFAST:
    ASC "fast (12.5 MHz)"
    !BYTE 0
MSG_CAPA:
    ASC "  Card capacity:   "
    !BYTE 0
MSG_VTOT:
    ASC "  V_TOTAL=$"
    !BYTE 0
MSG_CAPB:
    ASC " sectors  ("
    !BYTE 0
MSG_CAPC:
    ASC " MiB), addressing "
    !BYTE 0
MSG_SDLBA:
    ASC "LBA"
    !BYTE 0
MSG_SDBYTE:
    ASC "byte"
    !BYTE 0
MSG_EXIST:
    ASC "  Existing volume:"
    !BYTE $0D, 0


MSG_MBRAT:
    ASC "    MBR:           "
    !BYTE 0
MSG_MBRYES:
    ASC "MBR type $"
    !BYTE 0
MSG_MBRTYPE:
    ASC "  (a real partition)"
    !BYTE 0
MSG_MBRNONE:
    ASC "no partition signature"
    !BYTE 0
MSG_READFAIL:
    ASC "read failed"
    !BYTE 0
MSG_VBRAT:
    ASC "    Boot sector:   LBA "
    !BYTE 0
MSG_VFAT32:
    ASC "FAT32 volume labelled "
    !BYTE 0
MSG_VNOFAT:
    ASC "not FAT32"
    !BYTE 0
MSG_LAYOUT:
    ASC "  New FAT32 layout:"
    !BYTE $0D, 0


MSG_LPART:
    ASC "    Partition LBA: "
    !BYTE 0
MSG_LSIZE:
    ASC "    Size (sectors): "
    !BYTE 0
MSG_LMIB:
    ASC " MiB"
    !BYTE $0D, 0
MSG_LSPC:
    ASC "    Cluster size (sectors): "
    !BYTE 0
MSG_LSECT:
    ASC " sectors"
    !BYTE 0
MSG_LCLUST:
    ASC "    Cluster count: "
    !BYTE 0
MSG_LFAT:
    ASC "    FAT size (sectors): "
    !BYTE 0
MSG_LDATA:
    ASC "    First data LBA: "
    !BYTE 0
MSG_TGT:
    ASC "  Target: a "
    !BYTE 0
MSG_TGTC:
    ASC " sector card."
    !BYTE $0D
    ASC "  The FAT32 volume it holds ("
    !BYTE 0
MSG_TGTD:
    ASC " sectors) and every"
    !BYTE $0D
    ASC "  file in it will be destroyed."
    !BYTE $0D, 0
MSG_CATTITLE:
    ASC "Root directory of this card:"
    !BYTE $0D
    !BYTE 0
MSG_CATHEAD:
    ASC "Filename Ext FileSize"
    !BYTE $0D
    !BYTE 0
MSG_CATDONE:
    ASC "End of directory. "
    !BYTE 0
MSG_CATVOL:
    ASC "  <VOL>"
    !BYTE 0
MSG_CATDIR:
    ASC "  <DIR>"
    !BYTE 0
MSG_CATFAIL:
    ASC "  Not a FAT32 volume - nothing to catalog."
    !BYTE $0D
    !BYTE 0
MSG_MENUTITLE:
    ASC "VeraSDFormat - choose an action"
    !BYTE $0D
    !BYTE $0D
    !BYTE 0
MSG_CHOICES:
    ASC "  [1] Catalog SD"
    !BYTE $0D
    ASC "  [2] Format SD"
    !BYTE $0D
    ASC "  [3] Verify SD"
    !BYTE $0D
    ASC "  [0] Exit"
    !BYTE 0
MSG_WORKING:
    !BYTE $0D
    ASC "  Building volume"
    !BYTE $0D, 0
MSG_OF:
    ASC "sectors"
    !BYTE 0
MSG_VERIFY:
    ASC "  Verifying"
    !BYTE $0D, 0

MSG_VI_MBR:
    ASC "    MBR       "
    !BYTE 0
MSG_VI_VBR:
    ASC "    VBR       "
    !BYTE 0
MSG_VI_FSINFO:
    ASC "    FSInfo    "
    !BYTE 0
MSG_VI_BKVBR:
    ASC "    VBR copy  "
    !BYTE 0
MSG_VI_BKFSINFO:
    ASC "    FSInfo cp "
    !BYTE 0
MSG_OK:
    ASC "ok"
    !BYTE $0D, 0
MSG_MISMATCH:
    ASC "DOES NOT MATCH"
    !BYTE $0D, 0
MSG_PASS:
    !BYTE $0D
    ASC "  PASS - the card holds a FAT32 volume. "
    !BYTE 0
MSG_FAIL:
    !BYTE $0D
    ASC "  FAIL - "
    !BYTE 0
MSG_FAILB:
    ASC " errors"
    !BYTE 0
MSG_WARN1:
    ASC "DELETE EVERYTHING ON THE CARD"
    !BYTE $0D, 0
MSG_WARNZERO:
    ASC "Wipes card"
    !BYTE $0D, 0

MSG_WARNQUICK:
    ASC "Rewrites FAT32"
    !BYTE $0D, 0

MSG_ESCCANCEL:
    !BYTE $0D
    ASC "ESC cancels at any point."
    !BYTE $0D, 0
MSG_TYPEFMT:
    ASC "Type FORMAT then RETURN: "
    !BYTE 0
MSG_PRESSKEY:
    ASC "Press any key to continue."
    !BYTE 0

MSG_STG_ZERO:
    ASC "zeroing card"
    !BYTE $0D, 0

MSG_STG_MBR:
    ASC "master boot record"
    !BYTE $0D, 0
MSG_STG_VBR:
    ASC "boot sector"
    !BYTE $0D, 0
MSG_STG_FS:
    ASC "FSInfo"
    !BYTE $0D, 0
MSG_STG_BKV:
    ASC "boot sector backup"
    !BYTE $0D, 0
MSG_STG_BKF:
    ASC "FSInfo backup"
    !BYTE $0D, 0
MSG_STG_F1A:
    ASC "FAT 1, first sector"
    !BYTE $0D, 0
MSG_STG_F1B:
    ASC "FAT 1, free space"
    !BYTE $0D, 0
MSG_STG_F2A:
    ASC "FAT 2, first sector"
    !BYTE $0D, 0
MSG_STG_F2B:
    ASC "FAT 2, free space"
    !BYTE $0D, 0
MSG_STG_ROOT:
    ASC "erase root directory"
    !BYTE $0D, 0
MSG_STG_RPAD:
    ASC "erase root remainder"
    !BYTE $0D, 0

; =============================================================================
; SAVE_ZP / RESTORE_ZP / QUIT
;
; QUIT leaves the way a BRUN'd program should: the card deselected, the IRQ
; vector and zero page back the way they were, 40 columns restored, the write
; bank forced to MAIN, then the ROM HOME so the ProDOS prompt lands on a clean
; screen, and RTS to the BYE stub. Forgetting the bank before HOME clears the
; wrong page and buries the prompt (AGENTS.md lesson 8).
; =============================================================================
SAVE_ZP:
    LDX #$00
SZ_L:
    LDA $50,X
    STA ZPBACKUP,X
    INX
    CPX #$30                ; $50 through $7F
    BNE SZ_L
    RTS

RESTORE_ZP:
    LDX #$00
RZ_L:
    LDA ZPBACKUP,X
    STA $50,X
    INX
    CPX #$30
    BNE RZ_L
    RTS

QUIT:
    LDA ZP_SDCLK
    AND #$FE                ; let the card go
    LDY #$00
    STA (ZP_SPISTLO),Y
    CLI
    LDA ZP_IRQLO
    STA $FFFE
    LDA ZP_IRQHI
    STA $FFFF
    JSR RESTORE_ZP
    LDA #$00
    STA $C00C               ; 40 columns
    STA TEXTON
    STA RAMWRTOFF
    JSR HOME_ROM
    RTS

; === END OF FILE ===







