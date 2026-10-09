; ==============================================================================
; VERASDEDIT â€” PC-Tools-style HEX SECTOR EDITOR for Apple II (VERA SD Card)
; ==============================================================================
; Reads a 512-byte sector from the VERA SD card (slot 2 SPI: $C21E/$C21F) and
; displays it as a classic hex-dump:
;     OFFS  hex bytes (16)  ASCII
;     0000  EB 58 90 ...    .X.CMDR-DOS...
; A 512-byte sector spans 2 pages of 16 rows (256 bytes each):
;     [SPACE] = next page   [N] = next LBA   [P] = prev LBA   [R] = reload
;     [L] = select LBA (type 1-8 hex digits & RETURN, DEL=backspace, ESC=cancel)
;     [E] = enter the editor   [Q] = quit to BASIC
; Editor: IJKM move the cursor, TAB toggles hex/ASCII field, [E] toggles the
; edit state (only while editing do keys modify bytes, so IJKL can be typed
; as data in the ASCII field), [W] writes the sector, ESC exits the editor.
;
; ProDOS binary: VERASDEDIT.BIN (type 0x06, load $2000)
; Launched via:  BRUN VERASDEDIT.BIN
; ==============================================================================

* = $2000

; ---------------------------------------------------------------------------
; Zero page variables
; ---------------------------------------------------------------------------
ZP_LBA0      = $50            ; LBA (32-bit, LBA0 = LSB ... LBA3 = MSB)
ZP_LBA1      = $51
ZP_LBA2      = $52
ZP_LBA3      = $53
ZP_SPIBUF    = $54            ; SPI byte in/out
ZP_SCRATCH   = $55            ; 80-col cursor column (0-79)
ZP_PTR       = $56            ; string pointer (2 bytes)
ZP_PTRHI     = $57
ZP_CURSOR    = $58            ; 80-col row base address (2 bytes, scrambled)
ZP_CURSORHI  = $59
ZP_TEMP      = $5A
ZP_TEMP2     = $5B
ZP_ROW       = $5C            ; current display row (0-23), for scramble advance
ZP_PAGE      = $5D            ; 0 or 1  (page offset within the sector)
ZP_OFFL      = $5E            ; current hex-row offset (low byte)
ZP_OFFH      = $5F            ; current hex-row offset (high byte, 0 or 1)
ZP_KEY       = $60            ; last pressed key (ASCII)
ZP_DSROW     = $61            ; hex-row counter in DISPLAY_SECTOR (0-15)
ZP_EDIT      = $62            ; editor: byte index 0-255 within current page
ZP_NIB       = $63            ; editor: hex nibble 0=high 1=low
ZP_FIELD     = $64            ; editor: 0=hex field, 1=ascii field
ZP_DIRTY     = $65            ; editor: 1 = unsaved changes
ZP_EDITCOL   = $66            ; editor: byte column 0-15 within a row
ZP_DISPMODE  = $67            ; PUTCH display mode: 0=normal, 1=inverse, 2=flash
ZP_HEXIDX    = $68            ; HEX_ROW: current byte index (0-255) for dispmode
ZP_EDITMODE  = $69            ; 0=viewer (no cursor flash), 1=editor (flash/inverse)
ZP_IBUF      = $6A            ; LBA input buffer (8 nibbles) $6A-$71
ZP_IBUFIDX   = $72            ; number of hex digits typed (0-8)
ZP_OLBA0     = $73            ; last successfully-loaded LBA (backup for error restore)
ZP_OLBA1     = $74
ZP_OLBA2     = $75
ZP_OLBA3     = $76
ZP_ERR       = $77            ; load error flag: 0=ok, 1=failed
ZP_EDITING   = $78            ; editor: 0=navigate (IJKM moves), 1=edit (keys modify bytes)
ZP_IRQLO     = $79            ; saved IRQ vector lo (restored on QUIT)
ZP_IRQHI     = $7A            ; saved IRQ vector hi
ZP_NIBPOS    = $7B            ; which hex nibble is being displayed: 0=high 1=low
ZP_VERALO    = $7C            ; detected VERA base (low byte, always $00)
ZP_VERAHI    = $7D            ; detected VERA base (high byte: $C2=slot 2, $C4=slot 4)
ZP_SPIDATLO  = $7E            ; VERA SPI DATA register address (low)
ZP_SPIDATHI  = $7F            ; VERA SPI DATA register address (high)
ZP_SPISTLO   = $80            ; VERA SPI STATUS register address (low)
ZP_SPISTHI   = $81            ; VERA SPI STATUS register address (high)

SCRATCH      = $3300          ; 16-byte scratch for the ASCII column (must stay above the code; moved up for room)
DIRTYMAP     = $3310          ; 32-byte dirty bitmap (1 bit per byte 0-255)
ORIGBUF      = $3400          ; 512-byte pristine copy of the loaded sector (original values)
ZPBACKUP     = $3200          ; 50-byte backup of ZP $50-$81, restored on QUIT so ProDOS/BASIC survive
TOTBUFF      = $3330          ; 4 bytes: total sector count (32-bit, LSB..MSB) from CMD9 CSD
CSDLO        = $3334          ; CMD9 CSD c_size low byte  (total sectors = (c_size+1)*1024)
CSDMD        = $3335          ; CMD9 CSD c_size mid byte
CSDHI        = $3336          ; CMD9 CSD c_size high byte (top 6 bits)
NEXTTMP      = $3337          ; 4-byte scratch: Total-1 (last sector) for NEXT_LBA wrap check
SECTOR0      = $3600          ; sector buffer page 0 (bytes 0-255) — moved up so the code
SECTOR1      = $3700          ; can grow past $3000 without overwriting sector data (page 1, bytes 256-511)
SWAPBUF      = $3800          ; 512-byte temp: re-read of the current LBA for the SD-changed check
SWAPBUF1     = $3900          ; SWAPBUF page 1 (bytes 256-511)

; VERA card registers (Slot 2: $C200-$C2FF)
VERA_ADDR_L  = $C200
VERA_ADDR_M  = $C201
VERA_ADDR_H  = $C202
VERA_DATA0   = $C203
VERA_CTRL    = $C205
VERA_IEN     = $C206          ; VERA interrupt enable
VERA_DC_VID  = $C209
VERA_L0_CFG  = $C20D
VERA_SPI_DAT = $C21E          ; SD SPI DATA
VERA_SPI_ST  = $C21F          ; SD SPI STATUS

; Apple II hardware
TEXTOFF      = $C050
TEXTON       = $C051
RAMWRTOFF    = $C004          ; write enable MAIN memory ($0200-$BFFF)
RAMWRTON     = $C005          ; write enable AUX  memory ($0200-$BFFF)
MIXEDOFF     = $C052
MIXEDON      = $C053
HIRESOFF     = $C056
HIRESON      = $C057
KBD          = $C000
KBDSTRB      = $C010
HOME_ROM     = $FC58          ; Apple IIe ROM HOME: clear 40-col screen + home cursor

; ---------------------------------------------------------------------------
; Entry
; ---------------------------------------------------------------------------
START:
    ; Disable interrupts (avoid VERA/ProDOS IRQ interference)
    SEI
    ; Save ZP $50-$81 (ProDOS/Applesoft work area) so QUIT can restore it —
    ; otherwise the RTS back to ProDOS lands in clobbered zero-page and crashes.
    JSR SAVE_ZP
    ; Save the IRQ vector, then set it to RTI (avoid VERA/ProDOS IRQ
    ; jumping to ROM BRK). QUIT restores it before returning to ProDOS.
    LDA $FFFE
    STA ZP_IRQLO
    LDA $FFFF
    STA ZP_IRQHI
    LDA #<NOIRQ
    STA $FFFE
    LDA #>NOIRQ
    STA $FFFF
    ; Text mode, 80-column, 80STORE off, PAGE2 off
    LDA #$00
    STA TEXTON               ; text mode
    STA $C00D                ; 80COLON
    STA $C000                ; 80STOREOFF
    STA $C054                ; PAGE2OFF -> display PAGE1
    STA ZP_SCRATCH           ; column 0
    ; Start on page 0 of the sector
    LDA #$00
    STA ZP_PAGE
    JSR CLEAR_SCREEN
    JSR SET_CURSOR_HOME

    ; Detect the VERA card: slot 2 first, else slot 4. If neither slot has
    ; one, prints "No VERA Card Detected on Slot 2 or 4!" and halts.
    ; On success ZP_VERALO/HI holds the detected base ($C200 or $C400).
    JSR DETECT_SLOTS

    ; Disable VERA interrupts + video on the detected slot, then set up the
    ; SPI register pointers. (Detection may have reset the VERA, so these
    ; are applied after detection.)
    JSR VERA_DISABLE_IRQ_VID
    JSR SETUP_SPI_PTRS

    ; Default LBA = 2048 ($00000800, FAT32 boot sector)
    LDA #$00
    STA ZP_LBA0
    LDA #$08
    STA ZP_LBA1
    LDA #$00
    STA ZP_LBA2
    STA ZP_LBA3
    ; viewer mode by default (no editor cursor flash); input empty
    LDA #$00
    STA ZP_EDITMODE
    STA ZP_IBUFIDX
    ; last-good LBA backup starts as the default LBA
    LDA ZP_LBA0
    STA ZP_OLBA0
    LDA ZP_LBA1
    STA ZP_OLBA1
    LDA ZP_LBA2
    STA ZP_OLBA2
    LDA ZP_LBA3
    STA ZP_OLBA3

    ; Init VERA + SD, read the SD's total sector count (CMD9 -> CSD) for the
    ; (TOTAL=...) display, then load + display
    JSR SD_INIT
    JSR GET_SD_TOTAL
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
NOIRQ:
    RTI

; ---------------------------------------------------------------------------
; Save ZP $50-$81 (ProDOS/Applesoft work area) to ZPBACKUP, so QUIT can restore
; it before the RTS back to ProDOS. Must be called before the program uses ZP.
; ---------------------------------------------------------------------------
SAVE_ZP:
    LDX #$31                ; save $50..$81 (50 bytes)
SV_LOOP:
    LDA $50, X
    STA ZPBACKUP, X
    DEX
    BPL SV_LOOP
    RTS

; Restore ZP $50-$81 from ZPBACKUP (called by QUIT).
RESTORE_ZP:
    LDX #$31
RS_LOOP:
    LDA ZPBACKUP, X
    STA $50, X
    DEX
    BPL RS_LOOP
    RTS

; ---------------------------------------------------------------------------
; Load current LBA and display it (resets to page 0)
; ---------------------------------------------------------------------------
LOAD_AND_SHOW:
    LDA #$00
    STA ZP_PAGE
    ; Clear the dirty bitmap so the viewer never shows stale/garbage
    ; dirty bits (which would render bytes inverse) on a fresh load.
    JSR CLEAR_DIRTY
    JSR LOAD_SECTOR
    LDA ZP_ERR
    BNE LAS_FAIL
    ; success: remember this LBA as the last-good one
    LDA ZP_LBA0
    STA ZP_OLBA0
    LDA ZP_LBA1
    STA ZP_OLBA1
    LDA ZP_LBA2
    STA ZP_OLBA2
    LDA ZP_LBA3
    STA ZP_OLBA3
    JSR COPY_ORIG           ; keep a pristine copy for change detection
    JSR DISPLAY_SECTOR
    RTS
LAS_FAIL:
    ; restore the last-good LBA so the viewer returns to a valid sector
    LDA ZP_OLBA0
    STA ZP_LBA0
    LDA ZP_OLBA1
    STA ZP_LBA1
    LDA ZP_OLBA2
    STA ZP_LBA2
    LDA ZP_OLBA3
    STA ZP_LBA3
    JSR DISPLAY_SECTOR
    JSR PRINT_ERROR
    RTS

; ---------------------------------------------------------------------------
; Clear Apple II text page ($0400-$07FF) in both main and aux memory
; ---------------------------------------------------------------------------
CLEAR_SCREEN:
    LDA #$00
    STA RAMWRTOFF           ; write enable main
    JSR CLEAR_MAIN
    LDA #$00
    STA RAMWRTON            ; write enable aux
    JSR CLEAR_MAIN
    LDA #$00
    STA RAMWRTOFF           ; back to main
    RTS
CLEAR_MAIN:
    LDA #$A0              ; NORMAL space (0x20 + 0x80), NOT 0x20 (INVERSE)
    LDX #$00
CS1: STA $0400, X
    INX
    CPX #$00
    BNE CS1
    LDA #$A0
    LDX #$00
CS2: STA $0500, X
    INX
    CPX #$00
    BNE CS2
    LDA #$A0
    LDX #$00
CS3: STA $0600, X
    INX
    CPX #$00
    BNE CS3
    LDA #$A0
    LDX #$00
CS4: STA $0700, X
    INX
    CPX #$00
    BNE CS4
    RTS

; ---------------------------------------------------------------------------
; Print null-terminated string pointed by ZP_PTR (hi/lo).
; CR ($0D) -> advance to next row.
; ---------------------------------------------------------------------------
PRINT_STRING:
    LDA #$00
    STA ZP_DISPMODE         ; strings always print normal
    LDY #$00
PS_LOOP:
    LDA (ZP_PTR), Y
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

; Put char in A at the 80-col screen, then advance the column.
; The Apple IIe 80-column display INTERLEAVES MAIN/AUX per column: for each
; 40-address text-page cell it renders AUX in the LEFT cell and MAIN in the
; RIGHT cell (NTSC updateScreenText80: bits=(main<<7)|aux, bit0 = leftmost).
; So column C -> bank = C&1 (0=AUX, 1=MAIN), cell offset = C>>1 (0-39).
; ZP_CURSOR is the ROW BASE (advances 40 per physical row).
; High bit is set so every char displays NORMAL (black-on-white).
PUTCH:
    STA ZP_TEMP             ; save A (char to write)
    TYA
    PHA                     ; save Y
    LDA ZP_SCRATCH          ; current column (0-79)
    LSR A                   ; A = C>>1 (cell offset 0-39), carry = odd?
    TAY                     ; save cell offset in Y BEFORE clobbering A
    BCS PUTCH_MAIN          ; odd column -> main bank
    LDA #$00
    STA RAMWRTON            ; even column -> aux bank
    JMP PUTCH_WRITE
PUTCH_MAIN:
    LDA #$00
    STA RAMWRTOFF           ; odd column -> main bank
PUTCH_WRITE:
    LDA ZP_TEMP             ; restore A (char to write)
    LDX ZP_DISPMODE         ; 0=normal, 1=inverse, 2=flash
    CPX #$01
    BEQ PUTCH_INV
    CPX #$02
    BEQ PUTCH_FLASH
    ORA #$80                ; normal: bit7 set (0x80-0xFF)
    JMP PUTCH_STORE
PUTCH_INV:
    AND #$3F                ; inverse: bit7=0, bit6=0 (6-bit char code)
    JMP PUTCH_STORE
PUTCH_FLASH:
    AND #$3F                ; flash: bit7=0, bit6=1 (6-bit char code)
    ORA #$40
PUTCH_STORE:
    STA (ZP_CURSOR), Y
    INC ZP_SCRATCH
    LDA ZP_SCRATCH
    CMP #$50                ; 80?
    BNE PUTCH_DONE
    JSR ROW_ADVANCE         ; full physical row done
PUTCH_DONE:
    PLA                     ; restore Y
    TAY
    RTS

; Advance cursor to the next scrambled 80-col row base, reset column to 0.
; Display row R base = $0400 + (R&7)*$80 + (R/8)*$28.
ROW_ADVANCE:
    INC ZP_ROW
    LDA ZP_ROW
    AND #$07
    BNE ROW_ADD80
    SEC
    LDA ZP_CURSOR
    SBC #$58
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    SBC #$03
    STA ZP_CURSORHI
    JMP ROW_DONE
ROW_ADD80:
    LDA ZP_CURSOR
    CLC
    ADC #$80
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    ADC #$00
    STA ZP_CURSORHI
ROW_DONE:
    LDA #$00
    STA ZP_SCRATCH
    LDA #$00
    STA RAMWRTOFF           ; back to main write routing
    RTS

; Set cursor to start of text page ($0400), column 0, display row 0
SET_CURSOR_HOME:
    LDA #$00
    STA ZP_CURSOR
    LDA #$04
    STA ZP_CURSORHI
    LDA #$00
    STA ZP_SCRATCH
    STA ZP_ROW
    RTS

; ---------------------------------------------------------------------------
; GOTO_ROW: position cursor at display row A (0-23).
; Base = $0400 + (R&7)*$80 + (R/8)*$28  (computed arithmetically; no table)
; ---------------------------------------------------------------------------
GOTO_ROW:
    ; cursor = $0400 + (R&7)*$80 + (R/8)*$28
    STA ZP_TEMP2            ; save row
    AND #$07                ; R7 = R & 7
    TAY                     ; Y = R7
    ; low byte of (R7*$80) = (R7<<7) & 0xFF
    TYA
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                   ; R7<<7 (wraps in 8-bit = low byte)
    STA ZP_CURSOR
    ; high byte of (R7*$80) = R7>>1, then + $04 (for $0400)
    TYA
    LSR A
    CLC
    ADC #$04
    STA ZP_CURSORHI         ; $0400 + (R&7)*$80
    ; add (R/8)*$28  (= *40)
    LDA ZP_TEMP2
    LSR A
    LSR A
    LSR A                   ; R/8 (0..2)
    STA ZP_TEMP2
    ASL A
    ASL A
    ASL A
    ASL A
    ASL A                   ; (R/8)*32
    STA ZP_TEMP
    LDA ZP_TEMP2
    ASL A
    ASL A
    ASL A                   ; (R/8)*8
    CLC
    ADC ZP_TEMP             ; (R/8)*40
    CLC
    ADC ZP_CURSOR
    STA ZP_CURSOR
    LDA ZP_CURSORHI
    ADC #$00
    STA ZP_CURSORHI
    LDA #$00
    STA ZP_SCRATCH
    RTS

; ---------------------------------------------------------------------------
; SD SPI: send byte (A) -> SPI DATA, wait
; ---------------------------------------------------------------------------
SPI_SEND_A:
    LDY #$00
    STA (ZP_SPIDATLO),Y
    JSR SPI_WAIT
    RTS

SPI_READ_A:
    LDY #$00
    LDA #$FF
    STA (ZP_SPIDATLO),Y
    JSR SPI_WAIT
    LDY #$00
    LDA (ZP_SPIDATLO),Y
    RTS

SPI_WAIT:
    LDY #$00
SW_LOOP:
    LDA (ZP_SPISTLO),Y
    AND #$80
    BNE SW_LOOP
    RTS

; ---------------------------------------------------------------------------
; Detect the VERA card: slot 2 first, then slot 4. On success, sets
; ZP_VERALO/HI to the detected base ($C200 or $C400). If neither slot has a
; VERA card, prints "No VERA Card Detected on Slot 2 or 4!" and halts.
; ---------------------------------------------------------------------------
DETECT_SLOTS:
    ; Try slot 2
    LDA #$C2
    STA ZP_VERAHI
    LDA #$00
    STA ZP_VERALO
    JSR DETECT_VERA
    BCS DS_DONE              ; found in slot 2
    ; Try slot 4
    LDA #$C4
    STA ZP_VERAHI
    LDA #$00
    STA ZP_VERALO
    JSR DETECT_VERA
    BCS DS_DONE              ; found in slot 4
    ; Neither slot has a VERA card: show the message and stop.
    JSR PRINT_NO_VERA
DS_HALT:
    JMP DS_HALT
DS_DONE:
    RTS

; ---------------------------------------------------------------------------
; Probe the VERA at base ZP_VERALO/HI. Returns C=1 if present, C=0 if not.
; Mirrors veratest's detection: CTRL write/read, then ADDR + DATA0 write/read.
; ---------------------------------------------------------------------------
DETECT_VERA:
    LDA ZP_VERALO
    STA ZP_PTR
    LDA ZP_VERAHI
    STA ZP_PTRHI
    ; CTRL (offset $05): write 1, must read back 1
    LDY #$05
    LDA #$01
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    CMP #$01
    BNE DV_FAIL
    ; CTRL: write 0, must read back 0
    LDA #$00
    STA (ZP_PTR),Y
    LDA (ZP_PTR),Y
    BNE DV_FAIL
    ; ADDR_L/M/H = 0,0,0 ; then DATA0 (offset $03) write/read test
    LDY #$00
    LDA #$00
    STA (ZP_PTR),Y          ; ADDR_L
    INY
    STA (ZP_PTR),Y          ; ADDR_M
    INY
    STA (ZP_PTR),Y          ; ADDR_H
    INY                     ; Y = $03 = DATA0
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

; ---------------------------------------------------------------------------
; Disable VERA interrupts (IEN=0) and VERA video (DC_VID=0) on the detected
; slot. Called after detection because detection may have reset the VERA.
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; Set ZP_SPIDAT = base+$1E (SPI data) and ZP_SPIST = base+$1F (SPI status).
; ---------------------------------------------------------------------------
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

; ---------------------------------------------------------------------------
; SD init: select card, CMD0, CMD8, ACMD41, CMD16
; ---------------------------------------------------------------------------
SD_INIT:
    LDA #$01
    LDY #$00
    STA (ZP_SPISTLO),Y
    ; CMD0: 40 00 00 00 00 95
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

; ---------------------------------------------------------------------------
; Read the SD card's total capacity via CMD9 (SEND_CSD) and store the total
; sector count (512-byte sectors) in TOTBUFF (32-bit) for the (TOTAL=...) line.
; The emulator's VERASD returns a 21-byte CSD; bytes 12/13/14 hold C_SIZE:
;   c_size = ((b12 & 0x3F)<<16) | (b13<<8) | b14
;   total_sectors = (c_size + 1) * 1024   == (c_size+1) << 10
; We read all 21 bytes so the emulator's response is fully consumed (the next
; SPI read won't return a stale CSD byte). Clobbers A, X, Y and ZP_TEMP.
; ---------------------------------------------------------------------------
GET_SD_TOTAL:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN so TOTBUFF/CSD land in the right bank
    LDA #$49                ; CMD9 (SEND_CSD)
    JSR SPI_SEND_A
    LDA #$00
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    JSR SPI_SEND_A
    LDA #$FF                ; CRC (emulator ignores it)
    JSR SPI_SEND_A
    LDX #$00                ; response byte index (0-20)
GST_LOOP:
    JSR SPI_READ_A          ; A = next CSD byte
    CPX #$0C                ; byte 12 -> c_size high bits
    BNE GST_NOT12
    AND #$3F                ; top 6 bits of c_size
    STA CSDHI
    JMP GST_NEXT
GST_NOT12:
    CPX #$0D                ; byte 13 -> c_size mid byte
    BNE GST_NOT13
    STA CSDMD
    JMP GST_NEXT
GST_NOT13:
    CPX #$0E                ; byte 14 -> c_size low byte
    BNE GST_NEXT
    STA CSDLO
GST_NEXT:
    INX
    CPX #$15                ; read all 21 CSD bytes (consume the response)
    BNE GST_LOOP
    ; total = c_size + 1   (32-bit into TOTBUFF)
    LDA CSDLO
    CLC
    ADC #$01
    STA TOTBUFF
    LDA CSDMD
    ADC #$00
    STA TOTBUFF+1
    LDA CSDHI
    ADC #$00
    STA TOTBUFF+2
    LDA #$00
    ADC #$00
    STA TOTBUFF+3
    ; total = total << 10  (multiply by 1024)
    LDA #$0A
    JSR SHL_TOT
    RTS

; Shift TOTBUFF..TOTBUFF+3 (32-bit, LSB..MSB) left by A bits.
; Clobbers A and ZP_TEMP.
SHL_TOT:
    STA ZP_TEMP
ST_LOOP:
    CLC
    ROL TOTBUFF
    ROL TOTBUFF+1
    ROL TOTBUFF+2
    ROL TOTBUFF+3
    DEC ZP_TEMP
    BNE ST_LOOP
    RTS

; ---------------------------------------------------------------------------
; Load sector: CMD17 + LBA, read 512 bytes to the sector buffer (SECTOR0/SECTOR1)
; ---------------------------------------------------------------------------
LOAD_SECTOR:
    LDA #$00
    STA ZP_ERR              ; assume success until proven otherwise
    LDA #$00
    STA RAMWRTOFF           ; main write, so sector buffer (SECTOR0/SECTOR1) goes to MAIN
    LDA #$51
    JSR SPI_SEND_A
    LDA ZP_LBA3
    JSR SPI_SEND_A
    LDA ZP_LBA2
    JSR SPI_SEND_A
    LDA ZP_LBA1
    JSR SPI_SEND_A
    LDA ZP_LBA0
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A
    JSR SPI_READ_A          ; R1
    STA ZP_SPIBUF
    LDA ZP_SPIBUF
    BNE LOAD_FAIL
    JSR SPI_READ_A          ; data token
    CMP #$FE
    BNE LOAD_FAIL
    LDX #$00
LR_LOOP:
    JSR SPI_READ_A
    STA SECTOR0, X
    INX
    CPX #$00
    BNE LR_LOOP
    LDX #$00
LR_LOOP2:
    JSR SPI_READ_A
    STA SECTOR1, X
    INX
    CPX #$00
    BNE LR_LOOP2
    RTS

LOAD_FAIL:
    LDA #$01
    STA ZP_ERR
    RTS

; ---------------------------------------------------------------------------
; Display the current sector (page ZP_PAGE) as a hex dump
; ---------------------------------------------------------------------------
DISPLAY_SECTOR:
    JSR SET_CURSOR_HOME
    JSR PRINT_MSG1          ; title
    JSR PRINT_LBA_LINE      ; LBA + page
    JSR PRINT_MSG_HEAD      ; column header
    JSR PRINT_MSG_SEP       ; dash separator line
    JSR DRAW_DATA           ; 16 hex rows
    JSR PRINT_MSG_PAGE      ; key help line
    JSR CLEAR_INPUT
    JSR CLEAR_BOTTOM        ; clear status rows 21-23
    RTS

; ---------------------------------------------------------------------------
; Clear display rows 21-23 (status area below the key-help line).
; ---------------------------------------------------------------------------
CLEAR_BOTTOM:
    LDA #21
    JSR GOTO_ROW
    JSR CLEAR_LINE
    LDA #22
    JSR GOTO_ROW
    JSR CLEAR_LINE
    LDA #23
    JSR GOTO_ROW
    JSR CLEAR_LINE
    RTS

; ---------------------------------------------------------------------------
; Fill the current display row with 80 normal spaces.
; ---------------------------------------------------------------------------
CLEAR_LINE:
    LDA #$00
    STA ZP_DISPMODE
    LDA #$00
    STA ZP_SCRATCH
CL_LOOP:
    LDA #$20
    JSR PUTCH
    LDA ZP_SCRATCH
    BNE CL_LOOP             ; PUTCH past col 79 advances the row -> 0 -> done
    RTS

; ---------------------------------------------------------------------------
; Clear the LBA input buffer (typed digits are discarded).
; ---------------------------------------------------------------------------
CLEAR_INPUT:
    LDA #$00
    STA ZP_IBUFIDX          ; no digits typed
    LDX #$08                ; zero all 8 buffer bytes so stale digits can never
CI_ZERO:                    ; leak into the parse or the input line
    DEX
    LDA #$00
    STA ZP_IBUF, X
    CPX #$00
    BNE CI_ZERO
    RTS

; ---------------------------------------------------------------------------
; Draw the LBA input line at display row 23: "LBA> " + typed digits + cursor.
; The cursor is a solid inverse block at the current input position.
; ---------------------------------------------------------------------------
DRAW_INPUT_LINE:
    LDA #23
    JSR GOTO_ROW
    JSR PRINT_MSG_INPUT         ; "LBA> " (normal)
    LDY #$00
DIL_LOOP:
    CPY ZP_IBUFIDX
    BCS DIL_CURSOR
    LDA ZP_IBUF, Y
    JSR PRINT_NIBBLE
    INY
    JMP DIL_LOOP
DIL_CURSOR:
    ; inverse space = solid block cursor
    LDA #$01
    STA ZP_DISPMODE            ; inverse
    LDA #$20                  ; space
    JSR PUTCH
    ; pad the rest of the line with normal spaces (clears stale text)
    LDA #$00
    STA ZP_DISPMODE
DIL_PAD:
    LDA ZP_SCRATCH
    CMP #$50                  ; reached column 80?
    BCS DIL_PAD_DONE
    LDA #$20
    JSR PUTCH
    LDA ZP_SCRATCH
    BEQ DIL_PAD_DONE          ; PUTCH past col 79 advanced the row -> done
    JMP DIL_PAD
DIL_PAD_DONE:
    RTS

; ---------------------------------------------------------------------------
; Print "SD Read failed!" at display row 22 (a status row, above the prompt).
; ---------------------------------------------------------------------------
PRINT_ERROR:
    LDA #22
    JSR GOTO_ROW
    JSR PRINT_MSG_FAIL
    RTS

; ---------------------------------------------------------------------------
; DRAW_DATA: redraw the 16 hex data rows (display rows 4-19), all normal.
; Used by both the viewer and the editor (the editor then re-highlights the
; cursor cell via DRAW_CURSOR).
; ---------------------------------------------------------------------------
DRAW_DATA:
    LDA #4
    JSR GOTO_ROW            ; row base for display row 4
    LDA #4
    STA ZP_ROW              ; keep ROW_ADVANCE's counter in sync with the base
    LDA #$00
    STA ZP_DSROW            ; row 0
DD_LOOP:
    LDA ZP_DSROW
    JSR HEX_ROW
    JSR ROW_ADVANCE
    INC ZP_DSROW
    LDA ZP_DSROW
    CMP #$10
    BNE DD_LOOP
    RTS

; ---------------------------------------------------------------------------
; Print one hex row (A = row 0-15) from the current page.
; Layout: OOOO  BB BB ... (16 bytes)   ASCII
; ---------------------------------------------------------------------------
HEX_ROW:
    ASL A
    ASL A
    ASL A
    ASL A                   ; row*16
    STA ZP_OFFL             ; offset low (0..240)
    LDA ZP_PAGE
    STA ZP_OFFH             ; offset high (0 or 1)
    ; leading space then offset: '0' + OFFH + OFFL hi + OFFL lo (all normal)
    LDA #$00
    STA ZP_DISPMODE
    LDA #$20
    JSR PUTCH               ; leading space
    LDA #$00
    JSR PRINT_NIBBLE
    LDA ZP_OFFH
    JSR PRINT_NIBBLE
    LDA ZP_OFFL
    AND #$F0
    LSR A
    LSR A
    LSR A
    LSR A
    JSR PRINT_NIBBLE
    LDA ZP_OFFL
    AND #$0F
    JSR PRINT_NIBBLE
    LDA #$00
    STA ZP_DISPMODE
    LDA #$20
    JSR PUTCH               ; space after offset
    LDA #$20
    JSR PUTCH               ; second space (2 spaces before hex bytes)
    ; hex bytes. Loop counter is ZP_TEMP2 â€” PUTCH clobbers ZP_TEMP!
    LDA #$00
    STA ZP_TEMP2            ; i = 0
HB_LOOP:
    LDA ZP_OFFL
    CLC
    ADC ZP_TEMP2            ; index = row*16 + i
    STA ZP_HEXIDX           ; save byte index for dispmode
    TAX
    LDA #$00
    STA RAMWRTOFF           ; main write, so SCRATCH saves go to MAIN memory
    LDA ZP_PAGE
    BNE HB_PAGE1
    LDA SECTOR0, X
    JMP HB_HAVE
HB_PAGE1:
    LDA SECTOR1, X
HB_HAVE:
    LDY ZP_TEMP2
    STA SCRATCH, Y          ; save byte for ASCII column
    JSR HEX_DISPMODE        ; set ZP_DISPMODE (clobbers A)
    ; reload the byte for the hex digits (HEX_DISPMODE clobbered A)
    LDA ZP_OFFL
    CLC
    ADC ZP_TEMP2            ; byte index within page
    TAY
    LDA ZP_PAGE
    BNE HB_HAVE_P1
    LDA SECTOR0, Y
    JMP HB_HAVE_GO
HB_HAVE_P1:
    LDA SECTOR1, Y
HB_HAVE_GO:
    JSR PRINT_HEX2
    LDA #$00
    STA ZP_DISPMODE         ; separator space after hex byte -> normal
    LDA #$20
    JSR PUTCH
    INC ZP_TEMP2
    LDA ZP_TEMP2
    CMP #$10
    BNE HB_LOOP
    ; ASCII column: 2 spaces then 16 chars (all normal except per-byte)
    LDA #$00
    STA ZP_DISPMODE
    LDA #$20
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    LDA #$00
    STA ZP_TEMP2
HA_LOOP:
    ; byte index = ZP_OFFL + ZP_TEMP2
    LDA ZP_OFFL
    CLC
    ADC ZP_TEMP2
    STA ZP_HEXIDX
    LDY ZP_TEMP2
    LDA SCRATCH, Y
    CMP #$20
    BCC HA_DOT
    CMP #$7F
    BCS HA_DOT
    JSR ASCII_DISPMODE      ; set ZP_DISPMODE for this byte's ascii char
    LDY ZP_TEMP2
    LDA SCRATCH, Y          ; reload char (ASCII_DISPMODE clobbers A)
    JSR PUTCH
    JMP HA_NEXT
HA_DOT:
    ; non-printable byte: still show '.' with the cursor/dirty display mode,
    ; so the ASCII-field cursor flash works even on non-printable bytes.
    JSR ASCII_DISPMODE      ; set ZP_DISPMODE for this byte (clobbers A)
    LDA #$2E                ; '.'
    JSR PUTCH
HA_NEXT:
    INC ZP_TEMP2
    LDA ZP_TEMP2
    CMP #$10
    BNE HA_LOOP
    RTS

; ---------------------------------------------------------------------------
; Print hex byte in A (2 chars)
; ---------------------------------------------------------------------------
PRINT_HEX2:
    PHA                     ; save byte
    AND #$F0
    LSR A
    LSR A
    LSR A
    LSR A
    PHA                     ; save high nibble value
    LDA #$00
    STA ZP_NIBPOS           ; high nibble position
    JSR HEX_DISPMODE
    PLA
    JSR PRINT_NIBBLE
    PLA                     ; byte
    AND #$0F
    PHA                     ; save low nibble value
    LDA #$01
    STA ZP_NIBPOS           ; low nibble position
    JSR HEX_DISPMODE
    PLA
    JSR PRINT_NIBBLE
    RTS

PRINT_NIBBLE:
    CMP #$0A
    BCC PN_DIGIT
    SEC
    SBC #$09                ; 10-9=1('A') ... 15-9=6('F')
    CLC
    ADC #$40                ; -> $41-$46 ('A'-'F')
    JMP PN_DONE
PN_DIGIT:
    CLC
    ADC #$30                ; '0'-'9'
PN_DONE:
    JSR PUTCH
    RTS

; ---------------------------------------------------------------------------
; LBA line: "LBA=xxxxxxxx  (TOTAL=000nnnnnn) PAGE n" (n = 1 or 2)
; TOTAL = total sectors (512-byte) from CMD9 CSD, shown as 9 hex digits.
; ---------------------------------------------------------------------------
PRINT_LBA_LINE:
    LDA #$00
    STA ZP_DISPMODE         ; LBA line prints normal
    LDA #$4C                ; 'L'
    JSR PUTCH
    LDA #$42                ; 'B'
    JSR PUTCH
    LDA #$41                ; 'A'
    JSR PUTCH
    LDA #$3D                ; '='
    JSR PUTCH
    LDA ZP_LBA3
    JSR PRINT_HEX2
    LDA ZP_LBA2
    JSR PRINT_HEX2
    LDA ZP_LBA1
    JSR PRINT_HEX2
    LDA ZP_LBA0
    JSR PRINT_HEX2
    LDA #$20                ; ' '
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    ; (TOTAL=000nnnnnn) — total sectors from CMD9, printed as 9 hex digits
    LDA #$28                ; '('
    JSR PUTCH
    LDA #$54                ; 'T'
    JSR PUTCH
    LDA #$4F                ; 'O'
    JSR PUTCH
    LDA #$54                ; 'T'
    JSR PUTCH
    LDA #$41                ; 'A'
    JSR PUTCH
    LDA #$4C                ; 'L'
    JSR PUTCH
    LDA #$3D                ; '='
    JSR PUTCH
    LDA #$30                ; leading '0' (9-digit TOTAL)
    JSR PUTCH
    LDA TOTBUFF+3
    JSR PRINT_HEX2
    LDA TOTBUFF+2
    JSR PRINT_HEX2
    LDA TOTBUFF+1
    JSR PRINT_HEX2
    LDA TOTBUFF
    JSR PRINT_HEX2
    LDA #$29                ; ')'
    JSR PUTCH
    LDA #$20                ; ' '
    JSR PUTCH
    LDA #$50                ; 'P'
    JSR PUTCH
    LDA #$41                ; 'A'
    JSR PUTCH
    LDA #$47                ; 'G'
    JSR PUTCH
    LDA #$45                ; 'E'
    JSR PUTCH
    LDA #$20
    JSR PUTCH
    LDA ZP_PAGE             ; page digit: '1' + page
    CLC
    ADC #$31
    JSR PUTCH
    JSR ROW_ADVANCE
    RTS

; ---------------------------------------------------------------------------
; Keyboard input
; ---------------------------------------------------------------------------
READ_KEY:
    LDA KBD
    BPL RK_NONE
    AND #$7F                ; mask off high bit -> ASCII
    STA ZP_TEMP
    LDA #$00
    STA KBDSTRB             ; clear strobe
    LDA ZP_TEMP
    RTS
RK_NONE:
    LDA #$00
    RTS

; Convert A: lowercase 'a'-'z' -> uppercase 'A'-'Z'. Other chars unchanged.
; Used for command keys only (never on edit-mode data, so lowercase ASCII can
; still be typed as data).
NORMKEY:
    CMP #$61                ; < 'a'?
    BCC NK_DONE
    CMP #$7B                ; >= 'z'+1?
    BCS NK_DONE
    SEC
    SBC #$20                ; 'a'-$20 = 'A'  (SEC: exact subtract, no borrow)
NK_DONE:
    RTS

; Convert char in A to hex nibble. Returns nibble in A, C=0 if valid, C=1 if not.
CONVERT_HEX:
    CMP #$30                ; < '0'?
    BCC CV_FAIL
    CMP #$3A                ; '0'-'9'?
    BCC CV_DIGIT
    CMP #$41                ; < 'A'?
    BCC CV_FAIL
    CMP #$47                ; 'A'-'F'?
    BCC CV_UPPER
    CMP #$61                ; < 'a'?
    BCC CV_FAIL
    CMP #$67                ; 'a'-'f'?
    BCC CV_LOWER
CV_FAIL:
    SEC
    RTS
CV_DIGIT:
    SEC
    SBC #$30
    CLC
    RTS
CV_UPPER:
    SEC
    SBC #$37                ; 'A'-0x37 = 10
    CLC
    RTS
CV_LOWER:
    SEC
    SBC #$57                ; 'a'-0x57 = 10
    CLC
    RTS

; Shift the 32-bit LBA (LBA0 LSB .. LBA3 MSB) left by 4 bits
SHL32_4:
    LDY #$04
SHL_LOOP:
    CLC
    ROL ZP_LBA0
    ROL ZP_LBA1
    ROL ZP_LBA2
    ROL ZP_LBA3
    DEY
    BNE SHL_LOOP
    RTS

; Increment 32-bit LBA by 1
INC32:
    INC ZP_LBA0
    BNE INC32_DONE
    INC ZP_LBA1
    BNE INC32_DONE
    INC ZP_LBA2
    BNE INC32_DONE
    INC ZP_LBA3
INC32_DONE:
    RTS

; Decrement 32-bit LBA by 1 (clamped at 0)
DEC32:
    LDA ZP_LBA0
    BNE DEC_L0
    LDA ZP_LBA1
    BNE DEC_L1
    LDA ZP_LBA2
    BNE DEC_L2
    LDA ZP_LBA3
    BNE DEC_L3
    RTS                     ; all zero -> stay
DEC_L0:
    DEC ZP_LBA0
    RTS
DEC_L1:
    DEC ZP_LBA1
    LDA #$FF
    STA ZP_LBA0
    RTS
DEC_L2:
    DEC ZP_LBA2
    LDA #$FF
    STA ZP_LBA1
    LDA #$FF
    STA ZP_LBA0
    RTS
DEC_L3:
    DEC ZP_LBA3
    LDA #$FF
    STA ZP_LBA2
    LDA #$FF
    STA ZP_LBA1
    LDA #$FF
    STA ZP_LBA0
    RTS

; ---------------------------------------------------------------------------
; PREV_LBA: previous LBA, but wrap from 0 to the last sector (Total-1).
; If LBA == 0, load LBA = TOTBUFF - 1; otherwise just decrement (DEC32).
; Clobbers A.
; ---------------------------------------------------------------------------
PREV_LBA:
    LDA ZP_LBA0
    ORA ZP_LBA1
    ORA ZP_LBA2
    ORA ZP_LBA3
    BNE PREV_DEC            ; non-zero -> plain decrement
    ; LBA == 0: wrap to the last sector = Total - 1
    LDA TOTBUFF
    SEC
    SBC #$01
    STA ZP_LBA0
    LDA TOTBUFF+1
    SBC #$00
    STA ZP_LBA1
    LDA TOTBUFF+2
    SBC #$00
    STA ZP_LBA2
    LDA TOTBUFF+3
    SBC #$00
    STA ZP_LBA3
    RTS
PREV_DEC:
    JSR DEC32
    RTS

; ---------------------------------------------------------------------------
; NEXT_LBA: next LBA, but wrap from the last sector (Total-1) back to 0.
; If LBA == Total-1, set LBA = 0; otherwise just increment (INC32).
; Clobbers A.
; ---------------------------------------------------------------------------
NEXT_LBA:
    ; last = Total - 1  (compute into NEXTTMP)
    LDA TOTBUFF
    SEC
    SBC #$01
    STA NEXTTMP
    LDA TOTBUFF+1
    SBC #$00
    STA NEXTTMP+1
    LDA TOTBUFF+2
    SBC #$00
    STA NEXTTMP+2
    LDA TOTBUFF+3
    SBC #$00
    STA NEXTTMP+3
    ; if LBA == last -> wrap to 0
    LDA ZP_LBA0
    CMP NEXTTMP
    BNE NXT_INC
    LDA ZP_LBA1
    CMP NEXTTMP+1
    BNE NXT_INC
    LDA ZP_LBA2
    CMP NEXTTMP+2
    BNE NXT_INC
    LDA ZP_LBA3
    CMP NEXTTMP+3
    BNE NXT_INC
    ; LBA == last sector: wrap to 0
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    RTS
NXT_INC:
    JSR INC32
    RTS

; Toggle page 0 <-> 1
TOGGLE_PAGE:
    LDA ZP_PAGE
    EOR #$01
    STA ZP_PAGE
    RTS

; ---------------------------------------------------------------------------
; String messages
; ---------------------------------------------------------------------------
MSG1:
    ASC "VeraSDEdit (Hex Sector Editor)  v1.03 by anomixer 2026"
    !BYTE $0D, 0
MSG_HEAD:
    ASC "Offset 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F   ASCII Dump"
    !BYTE $0D, 0
MSG_SEP:
    ASC "------ -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --   ----------------"
    !BYTE $0D, 0
MSG_PAGE:
    ASC "[SPACE]=page  [N]=next  [P]=prev  [R]=reload  [L]=LBA  [E]=edit  [Q]=quit"
    !BYTE $0D, 0
MSG_LBAHELP:
    ASC "Type 1-8 hex digits & RETURN  DEL=backspace  [ESC]=cancel"
    !BYTE $0D, 0
MSG_INPUT:
    ASC "LBA> "
    !BYTE 0
MSG_FAIL:
    ASC "SD Read failed!"
    !BYTE 0
MSG_EDIT1:
    ASC "[IJKM]=move [TAB]=field [E]=edit [W]=write [ESC]=exit"
    !BYTE $0D, 0
MSG_EDIT2:
    ASC "[EDIT] [0-F]=hex [TAB]=field [RETURN]=done [ESC]=abort"
    !BYTE $0D, 0
MSG_DIRTY:
    ASC "MODIFIED - changes not written!"
    !BYTE 0
MSG_SAVED:
    ASC "Saved (clean)"
    !BYTE 0
MSG_WFAIL:
    ASC "SD Write failed!"
    !BYTE 0
MSG_WP:
    ASC "SD Write Protected!"
    !BYTE 0
MSG_FORCE:
    ASC "SD Card Changed. Force Write (y/n)?"
    !BYTE 0
MSG_NO_VERA:
    ASC "No VERA Card Detected on Slot 2 or 4!"
    !BYTE 0

; ---------------------------------------------------------------------------
; String-printing wrappers
; ---------------------------------------------------------------------------
PRINT_MSG1:
    LDA #<MSG1
    STA ZP_PTR
    LDA #>MSG1
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_HEAD:
    LDA #<MSG_HEAD
    STA ZP_PTR
    LDA #>MSG_HEAD
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_SEP:
    LDA #<MSG_SEP
    STA ZP_PTR
    LDA #>MSG_SEP
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_PAGE:
    LDA #<MSG_PAGE
    STA ZP_PTR
    LDA #>MSG_PAGE
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_HELP:
    LDA #<MSG_LBAHELP
    STA ZP_PTR
    LDA #>MSG_LBAHELP
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_INPUT:
    LDA #<MSG_INPUT
    STA ZP_PTR
    LDA #>MSG_INPUT
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_FAIL:
    LDA #<MSG_FAIL
    STA ZP_PTR
    LDA #>MSG_FAIL
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_EDIT1:
    LDA #<MSG_EDIT1
    STA ZP_PTR
    LDA #>MSG_EDIT1
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_EDIT2:
    LDA #<MSG_EDIT2
    STA ZP_PTR
    LDA #>MSG_EDIT2
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_DIRTY:
    LDA #<MSG_DIRTY
    STA ZP_PTR
    LDA #>MSG_DIRTY
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_SAVED:
    LDA #<MSG_SAVED
    STA ZP_PTR
    LDA #>MSG_SAVED
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_WFAIL:
    LDA #<MSG_WFAIL
    STA ZP_PTR
    LDA #>MSG_WFAIL
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_WP:
    LDA #<MSG_WP
    STA ZP_PTR
    LDA #>MSG_WP
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_MSG_FORCE:
    LDA #<MSG_FORCE
    STA ZP_PTR
    LDA #>MSG_FORCE
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS
PRINT_NO_VERA:
    LDA #<MSG_NO_VERA
    STA ZP_PTR
    LDA #>MSG_NO_VERA
    STA ZP_PTRHI
    JSR PRINT_STRING
    RTS

; ---------------------------------------------------------------------------
; Main loop
; ---------------------------------------------------------------------------
MAIN_LOOP:
    JSR READ_KEY
    BEQ MAIN_LOOP           ; no key
    JSR NORMKEY             ; N/P/R/L/E/Q accept lowercase too
    STA ZP_KEY
    LDA ZP_KEY
    CMP #$20                ; SPACE -> toggle page
    BNE ML_NOT_SPACE
    JSR TOGGLE_PAGE
    JSR DISPLAY_SECTOR
    JMP MAIN_LOOP
ML_NOT_SPACE:
    CMP #$4E                ; 'N' -> next LBA
    BNE ML_NOT_N
    JSR NEXT_LBA
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
ML_NOT_N:
    CMP #$50                ; 'P' -> prev LBA
    BNE ML_NOT_P
    JSR PREV_LBA
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
ML_NOT_P:
    CMP #$52                ; 'R' -> reload current LBA
    BNE ML_NOT_R
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
ML_NOT_R:
    CMP #$4C                ; 'L' -> enter LBA select mode
    BNE ML_NOT_L
    JMP LBA_SELECT
ML_NOT_L:
    CMP #$45                ; 'E' -> enter editor mode
    BNE ML_NOT_E
    JMP ENTER_EDIT
ML_NOT_E:
    CMP #$51                ; 'Q' -> quit to BASIC
    BNE ML_NOT_Q
    JMP QUIT
ML_NOT_Q:
    JMP MAIN_LOOP

; ---------------------------------------------------------------------------
; LBA_SELECT: [L] submode. Type 1-8 hex digits + RETURN to jump to that LBA,
; DEL backspaces, ESC cancels back to the viewer.
; ---------------------------------------------------------------------------
LBA_SELECT:
    JSR CLEAR_INPUT
    ; help line at row 21, prompt at row 23
    LDA #21
    JSR GOTO_ROW
    JSR PRINT_MSG_HELP
    JSR DRAW_INPUT_LINE
LBS_LOOP:
    JSR READ_KEY
    BEQ LBS_LOOP
    STA ZP_KEY
    ; hex digit -> append to the input buffer
    LDA ZP_KEY
    JSR CONVERT_HEX
    BCS LBS_NOT_DIGIT
    LDY ZP_IBUFIDX
    CPY #$08                ; buffer full?
    BCS LBS_LOOP
    STA ZP_IBUF, Y
    INC ZP_IBUFIDX
    JSR DRAW_INPUT_LINE
    JMP LBS_LOOP
LBS_NOT_DIGIT:
    LDA ZP_KEY
    CMP #$0D                ; RETURN -> commit the typed LBA
    BNE LBS_NOT_ENTER
    LDA ZP_IBUFIDX
    BEQ LBS_RELOAD          ; no digits -> just reload current LBA
    ; parse buffer digits into ZP_LBA
    LDA #$00
    STA ZP_LBA0
    STA ZP_LBA1
    STA ZP_LBA2
    STA ZP_LBA3
    LDX #$00
LBS_PARSE_LOOP:
    CPX ZP_IBUFIDX
    BCS LBS_PARSE_DONE
    JSR SHL32_4
    LDA ZP_IBUF, X
    ORA ZP_LBA0
    STA ZP_LBA0
    INX
    JMP LBS_PARSE_LOOP
LBS_PARSE_DONE:
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
LBS_RELOAD:
    JSR LOAD_AND_SHOW
    JMP MAIN_LOOP
LBS_NOT_ENTER:
    CMP #$08                ; DEL / Ctrl-H -> backspace
    BEQ LBS_BS
    CMP #$7F                ; DEL -> backspace
    BNE LBS_NOT_BS
LBS_BS:
    LDA ZP_IBUFIDX
    BEQ LBS_BS_EMPTY
    DEC ZP_IBUFIDX
    JSR DRAW_INPUT_LINE
LBS_BS_EMPTY:
    JMP LBS_LOOP
LBS_NOT_BS:
    CMP #$1B                ; ESC -> cancel back to the viewer
    BNE LBS_NOT_ESC
    JSR DISPLAY_SECTOR
    JMP MAIN_LOOP
LBS_NOT_ESC:
    JMP LBS_LOOP

; ---------------------------------------------------------------------------
; QUIT: return to ProDOS (the BRUN caller) — the ProDOS "BYE" behaviour, not
; the Applesoft warm-start. The program was launched via BRUN, which pushed a
; return address; the stack is balanced at this point, so an RTS pops it and
; hands control back to ProDOS. Restore the IRQ vector and 40-col first.
; ---------------------------------------------------------------------------
QUIT:
    JSR RESTORE_ZP          ; restore ZP $50-$81 before returning to ProDOS
    LDA ZP_IRQLO
    STA $FFFE               ; restore the saved IRQ vector
    LDA ZP_IRQHI
    STA $FFFF
    LDA #$00
    STA TEXTON              ; text mode (already on, keep it)
    STA $C00C               ; 80COLOFF -> 40-col so the ProDOS prompt is legible
    LDA #$00
    STA RAMWRTOFF           ; write MAIN so HOME clears the visible text page
    JSR HOME_ROM            ; clear the screen so the ']' prompt is on a clean screen
    CLI                     ; re-enable interrupts (we SEI'd at entry)
    RTS                     ; return to ProDOS (BRUN caller)

; =============================================================================
; HEX SECTOR EDITOR
; =============================================================================
; Editor mode lets you move a cursor over the hex + ASCII columns and modify
; bytes in memory; 'W' writes the whole sector back to the SD card via CMD24.
;
;   Keys:
;     I/M/J/K  move cursor (up/down/left/right; hex column moves per nibble)
;     TAB      toggle between the hex field and the ASCII field
;     0-9A-F   in hex field: set the nibble under the cursor
;     (printable)  in ASCII field: set the byte under the cursor
;     W        write the current sector back to the SD card (CMD24)
;     ESC      leave editor and return to the viewer
; =============================================================================

; ---------------------------------------------------------------------------
; Enter editor mode (never returns; jumps into EDIT_LOOP).
; ---------------------------------------------------------------------------
ENTER_EDIT:
    LDA #$01
    STA ZP_EDITMODE          ; enable editor cursor flash/inverse
    LDA #$00
    STA ZP_EDIT
    STA ZP_NIB
    STA ZP_FIELD
    STA ZP_DIRTY
    STA ZP_EDITING           ; start in navigate mode (IJKM move the cursor)
    JSR CLEAR_DIRTY          ; clear the dirty bitmap
    JSR DRAW_EDIT_BANNER
    JSR UPDATE_DIRTY
    JSR DRAW_DATA            ; HEX_ROW draws inverse/flash per dirty+cursor
    JMP EDIT_LOOP

; ---------------------------------------------------------------------------
; Draw the editor banner at display row 20 (navigate vs edit mode hint).
; ---------------------------------------------------------------------------
DRAW_EDIT_BANNER:
    LDA #20
    JSR GOTO_ROW
    JSR CLEAR_LINE           ; clear row 20 first (banner length varies)
    LDA #20
    JSR GOTO_ROW
    LDA ZP_EDITING
    BEQ DEB_NAV
    JSR PRINT_MSG_EDIT2
    JMP DEB_DONE
DEB_NAV:
    JSR PRINT_MSG_EDIT1
DEB_DONE:
    RTS

; ---------------------------------------------------------------------------
; Redraw the dirty/clean indicator at display row 21.
; ---------------------------------------------------------------------------
UPDATE_DIRTY:
    LDA #21
    JSR GOTO_ROW
    LDA ZP_DIRTY
    BEQ UD_SAVED
    JSR PRINT_MSG_DIRTY
    JMP UD_PAD
UD_SAVED:
    JSR PRINT_MSG_SAVED
UD_PAD:
    ; pad the rest of the line with spaces (clears stale text).
    ; NOTE: PUTCH at the last column (79) advances the row and resets the
    ; column to 0, so detect that via BEQ instead of the CMP (which never
    ; sees 0x50 after the reset) - otherwise this loops forever.
    LDA ZP_SCRATCH
UD_PAD_LOOP:
    CMP #$50
    BCS UD_PAD_DONE
    LDA #$20
    JSR PUTCH
    LDA ZP_SCRATCH
    BEQ UD_PAD_DONE          ; row advanced past col 79 -> done
    JMP UD_PAD_LOOP
UD_PAD_DONE:
    RTS

; ---------------------------------------------------------------------------
; Fetch A = buffer[ZP_EDIT] for the current page (ZP_PAGE).
; RAMRD stays at MAIN (we never switch it), so the buffer at SECTOR0/SECTOR1 is
; read directly.
; ---------------------------------------------------------------------------
GET_BUF_BYTE:
    LDA ZP_PAGE
    BNE GB_P1
    LDY ZP_EDIT
    LDA SECTOR0, Y
    RTS
GB_P1:
    LDY ZP_EDIT
    LDA SECTOR1, Y
    RTS

; ---------------------------------------------------------------------------
; Store ZP_TEMP2 -> buffer[ZP_EDIT] (MAIN bank, SECTOR0 or SECTOR1).
; ---------------------------------------------------------------------------
STORE_BUF_BYTE:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN so the buffer goes to the right bank
    LDA ZP_PAGE
    BNE SB_P1
    LDY ZP_EDIT
    LDA ZP_TEMP2
    STA SECTOR0, Y
    JMP SB_DONE
SB_P1:
    LDY ZP_EDIT
    LDA ZP_TEMP2
    STA SECTOR1, Y
SB_DONE:
    RTS

; ---------------------------------------------------------------------------
; HEX_DISPMODE: set ZP_DISPMODE for the hex digits of byte ZP_HEXIDX.
;   cursor byte + hex field:
;     nibble under cursor (ZP_NIBPOS=ZP_NIB) -> flash (even if dirty)
;     other nibble                          -> dirty ? inverse : normal
;   cursor elsewhere / non-cursor:
;     dirty byte                            -> inverse
;   otherwise                              -> normal
; ---------------------------------------------------------------------------
HEX_DISPMODE:
    LDA ZP_EDITMODE
    BEQ HD_NORMAL           ; viewer: never flash/inverse
    LDA ZP_EDIT
    CMP ZP_HEXIDX
    BNE HD_DIRTY            ; not cursor byte
    LDA ZP_FIELD
    BNE HD_DIRTY            ; cursor in ascii field -> not hex-flashed
    ; cursor byte, hex field
    LDA ZP_NIBPOS
    CMP ZP_NIB
    BEQ HD_FLASH            ; nibble under cursor: flash, even if dirty
    JSR IS_DIRTY
    BCS HD_INVERSE          ; other nibble of a changed byte: inverse
    LDA #$00
    STA ZP_DISPMODE
    RTS
HD_FLASH:
    LDA #$02
    STA ZP_DISPMODE         ; flash
    RTS
HD_DIRTY:
    JSR IS_DIRTY
    BCC HD_NORMAL
HD_INVERSE:
    LDA #$01
    STA ZP_DISPMODE         ; inverse
    RTS
HD_NORMAL:
    LDA #$00
    STA ZP_DISPMODE         ; normal
    RTS

; ---------------------------------------------------------------------------
; ASCII_DISPMODE: set ZP_DISPMODE for the ascii char of byte ZP_HEXIDX.
;   cursor byte + ascii field -> flash (even if dirty)
;   dirty byte (non-cursor)   -> inverse
;   otherwise                 -> normal
; ---------------------------------------------------------------------------
ASCII_DISPMODE:
    LDA ZP_EDITMODE
    BEQ AD_NORMAL           ; viewer: never flash/inverse
    LDA ZP_EDIT
    CMP ZP_HEXIDX
    BNE AD_DIRTY
    LDA ZP_FIELD
    BEQ AD_DIRTY            ; cursor in hex field -> not ascii-flashed
    ; cursor byte, ascii field: always flash (even if dirty)
    LDA #$02
    STA ZP_DISPMODE         ; flash
    RTS
AD_DIRTY:
    JSR IS_DIRTY
    BCC AD_NORMAL
AD_INVERSE:
    LDA #$01
    STA ZP_DISPMODE         ; inverse
    RTS
AD_NORMAL:
    LDA #$00
    STA ZP_DISPMODE         ; normal
    RTS

; ---------------------------------------------------------------------------
; IS_DIRTY: return C=1 if byte ZP_HEXIDX is marked dirty (bit set in DIRTYMAP).
; Clobbers X, Y and ZP_TEMP. (6502 AND has no indexed-Y mode, so the bit mask
; is computed by shifting in BITMASK rather than a table lookup.)
; ---------------------------------------------------------------------------
IS_DIRTY:
    LDA ZP_HEXIDX
    LSR A
    LSR A
    LSR A
    TAX                     ; byte offset 0-31 in the bitmap
    LDA ZP_HEXIDX
    AND #$07
    TAY                     ; bit 0-7
    LDA DIRTYMAP, X
    PHA                     ; save the bitmap byte
    JSR BITMASK             ; A = 1<<Y
    STA ZP_TEMP             ; bit mask
    PLA                     ; A = bitmap byte
    AND ZP_TEMP
    BEQ ID_CLEAR
    SEC
    RTS
ID_CLEAR:
    CLC
    RTS

; ---------------------------------------------------------------------------
; BITMASK: A = 1<<Y (Y = 0..7). Clobbers A and Y; preserves X.
; ---------------------------------------------------------------------------
BITMASK:
    LDA #$01
BM_LOOP:
    CPY #$00
    BEQ BM_DONE
    ASL A
    DEY
    JMP BM_LOOP
BM_DONE:
    RTS

; ---------------------------------------------------------------------------
; SET_DIRTY_BIT: mark byte ZP_EDIT as dirty (set its bit in DIRTYMAP).
; Clobbers X, Y and ZP_TEMP.
; ---------------------------------------------------------------------------
SET_DIRTY_BIT:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN so the bitmap lands in the right bank
    LDA ZP_EDIT
    LSR A
    LSR A
    LSR A
    TAX                     ; bitmap byte 0-31
    LDA ZP_EDIT
    AND #$07
    TAY                     ; bit 0-7
    JSR BITMASK             ; A = 1<<Y
    STA ZP_TEMP             ; bit mask
    LDA DIRTYMAP, X
    ORA ZP_TEMP
    STA DIRTYMAP, X
    RTS

; ---------------------------------------------------------------------------
; CLEAR_DIRTY: zero all 32 bytes of DIRTYMAP.
; ---------------------------------------------------------------------------
CLEAR_DIRTY:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN
    LDX #$00
CD_LOOP:
    LDA #$00
    STA DIRTYMAP, X
    INX
    CPX #$20
    BNE CD_LOOP
    RTS

; ---------------------------------------------------------------------------
; CLEAR_DIRTY_BIT: clear the DIRTYMAP bit for byte ZP_EDIT.
; Clobbers X, Y and ZP_TEMP.
; ---------------------------------------------------------------------------
CLEAR_DIRTY_BIT:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN
    LDA ZP_EDIT
    LSR A
    LSR A
    LSR A
    TAX                     ; bitmap byte 0-31
    LDA ZP_EDIT
    AND #$07
    TAY                     ; bit 0-7
    JSR BITMASK             ; A = 1<<Y
    EOR #$FF                ; invert -> clear mask
    STA ZP_TEMP
    LDA DIRTYMAP, X
    AND ZP_TEMP
    STA DIRTYMAP, X
    RTS

; ---------------------------------------------------------------------------
; UPDATE_DIRTY_BYTE: after editing byte ZP_EDIT, mark it dirty ONLY if its
; value actually differs from the original (ORIGBUF). A byte edited back to
; its original value (e.g. 00 -> 00) stays clean, so it never shows inverse.
; ---------------------------------------------------------------------------
UPDATE_DIRTY_BYTE:
    JSR GET_BUF_BYTE        ; A = current buffer[ZP_EDIT] (new value)
    STA ZP_TEMP
    LDA ZP_PAGE
    BNE UDB_P1
    LDY ZP_EDIT
    LDA ORIGBUF, Y
    JMP UDB_CMP
UDB_P1:
    LDY ZP_EDIT
    LDA ORIGBUF+$100, Y
UDB_CMP:
    CMP ZP_TEMP
    BEQ UDB_CLEAR           ; value unchanged -> not dirty
    JSR SET_DIRTY_BIT       ; changed -> dirty
    RTS
UDB_CLEAR:
    JSR CLEAR_DIRTY_BIT
    RTS

; ---------------------------------------------------------------------------
; SET_DIRTY_FLAG: ZP_DIRTY = 1 if any DIRTYMAP bit is set, else 0.
; ---------------------------------------------------------------------------
SET_DIRTY_FLAG:
    LDA #$00
    STA ZP_DIRTY
    LDX #$00
SDF_LOOP:
    LDA DIRTYMAP, X
    BNE SDF_SET
    INX
    CPX #$20
    BNE SDF_LOOP
    RTS
SDF_SET:
    LDA #$01
    STA ZP_DIRTY
    RTS

; ---------------------------------------------------------------------------
; COPY_ORIG: copy the loaded sector (SECTOR0/SECTOR1, 512 bytes) to ORIGBUF.
; Call after a successful LOAD_SECTOR so ORIGBUF always holds the last-good
; original values (and after W, so ORIGBUF tracks the written sector).
; ---------------------------------------------------------------------------
COPY_ORIG:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN
    LDX #$00
CO_LOOP0:
    LDA SECTOR0, X
    STA ORIGBUF, X
    INX
    BNE CO_LOOP0
CO_LOOP1:
    LDA SECTOR1, X
    STA ORIGBUF+$100, X
    INX
    BNE CO_LOOP1
    RTS

; ---------------------------------------------------------------------------
; CHECK_SD_UNCHANGED: re-read the current LBA from the SD card and compare it
; against ORIGBUF (the pristine copy from the last successful load). If they
; differ, the SD image was swapped/changed since we loaded — return C=0 so the
; caller aborts the write (otherwise we'd write the old card's data to a
; different image's LBA). Returns C=1 if the SD still holds the same sector.
; Clobbers A, X, Y.
; ---------------------------------------------------------------------------
CHECK_SD_UNCHANGED:
    LDA #$00
    STA RAMWRTOFF           ; write MAIN so SWAPBUF goes to the right bank
    ; CMD17 read current LBA into SWAPBUF
    LDA #$51
    JSR SPI_SEND_A
    LDA ZP_LBA3
    JSR SPI_SEND_A
    LDA ZP_LBA2
    JSR SPI_SEND_A
    LDA ZP_LBA1
    JSR SPI_SEND_A
    LDA ZP_LBA0
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A
    JSR SPI_READ_A          ; R1
    BNE CH_FAIL             ; read failed -> treat as changed (abort write)
    JSR SPI_READ_A          ; data token
    CMP #$FE
    BNE CH_FAIL
    LDX #$00
CH_LOOP0:
    JSR SPI_READ_A
    STA SWAPBUF, X
    INX
    BNE CH_LOOP0
    LDX #$00
CH_LOOP1:
    JSR SPI_READ_A
    STA SWAPBUF1, X
    INX
    BNE CH_LOOP1
    ; compare SWAPBUF vs ORIGBUF (512 bytes)
    LDX #$00
CH_CMP0:
    LDA SWAPBUF, X
    CMP ORIGBUF, X
    BNE CH_CHANGED
    INX
    BNE CH_CMP0
    LDX #$00
CH_CMP1:
    LDA SWAPBUF1, X
    CMP ORIGBUF+$100, X
    BNE CH_CHANGED
    INX
    BNE CH_CMP1
    SEC                     ; unchanged
    RTS
CH_CHANGED:
CH_FAIL:
    CLC                     ; changed / read failed
    RTS

; ---------------------------------------------------------------------------
; Write the current sector (LBA) back to the SD card via CMD24.
; Returns A: 0 = success (token 0x05), 1 = generic failure (R1 != 0 or bad
; token), 2 = SD write protected / write rejected (token 0x0D).
;   CMD24 0x58 + LBA3..LBA0 + CRC(0xFF) -> R1
;   start token 0xFE + 512 data bytes + 2 CRC bytes
;   (emulator writes once it has received 515 bytes: token+data+CRC)
;   data response token: 0x05 = accepted, 0x0D = rejected (write-protected)
; ---------------------------------------------------------------------------
WRITE_SECTOR:
    LDA #$00
    STA RAMWRTOFF           ; read MAIN buffer
    LDA #$58                ; CMD24 (WRITE_SINGLE_BLOCK)
    JSR SPI_SEND_A
    LDA ZP_LBA3
    JSR SPI_SEND_A
    LDA ZP_LBA2
    JSR SPI_SEND_A
    LDA ZP_LBA1
    JSR SPI_SEND_A
    LDA ZP_LBA0
    JSR SPI_SEND_A
    LDA #$FF                ; CRC (emulator ignores it)
    JSR SPI_SEND_A
    JSR SPI_READ_A          ; R1
    BNE WS_FAIL             ; non-zero R1 -> fail
    LDA #$FE                ; data start token
    JSR SPI_SEND_A
    ; send 512 bytes: SECTOR0 (256) then SECTOR1 (256)
    LDX #$00
WS_LOOP0:
    LDA SECTOR0, X
    JSR SPI_SEND_A
    INX
    BNE WS_LOOP0
    LDX #$00
WS_LOOP1:
    LDA SECTOR1, X
    JSR SPI_SEND_A
    INX
    BNE WS_LOOP1
    ; 2 CRC bytes
    LDA #$FF
    JSR SPI_SEND_A
    LDA #$FF
    JSR SPI_SEND_A
    ; wait for the card to finish (busy: reads 0x00 until done), then read the
    ; data response token: 0x05 = accepted, 0x0D = rejected (write-protected).
WS_BUSY:
    JSR SPI_READ_A
    CMP #$00
    BEQ WS_BUSY
    CMP #$05
    BEQ WS_OK               ; 0x05 -> data accepted
    CMP #$0D
    BEQ WS_WP               ; 0x0D -> data rejected (write protected / error)
    LDA #$01                ; unexpected token -> generic failure
    RTS
WS_WP:
    LDA #$02                ; SD write protected (0x0D)
    RTS
WS_OK:
    LDA #$00                ; success
    RTS
WS_FAIL:
    LDA #$01
    RTS

; ---------------------------------------------------------------------------
; PROMPT_FORCE_WRITE: the SD image changed since we loaded (CHECK_SD_UNCHANGED
; failed). Show "SD Card Changed. Force Write (y/n)?" and read the
; response. Returns C=1 if the user chose Y (force the write), C=0 if N
; (abort). Clobbers A. The prompt line (row 22) is cleared by the caller.
; ---------------------------------------------------------------------------
PROMPT_FORCE_WRITE:
    ; clear row 22, then show the prompt
    LDA #22
    JSR GOTO_ROW
    JSR CLEAR_LINE
    LDA #22
    JSR GOTO_ROW
    JSR PRINT_MSG_FORCE
PFW_LOOP:
    JSR READ_KEY
    BEQ PFW_LOOP
    JSR NORMKEY
    CMP #$59                ; 'Y'
    BEQ PFW_YES
    CMP #$4E                ; 'N'
    BEQ PFW_NO
    JMP PFW_LOOP            ; any other key: keep waiting
PFW_YES:
    SEC
    RTS
PFW_NO:
    CLC
    RTS

; ---------------------------------------------------------------------------
; Editor main loop
; ---------------------------------------------------------------------------
EDIT_LOOP:
    JSR READ_KEY
    BEQ EDIT_LOOP
    STA ZP_KEY
    LDA ZP_KEY
    CMP #$1B                ; ESC
    BNE EL_NOT_ESC
    ; context-sensitive: edit -> navigate (discard/revert), navigate -> viewer
    LDA ZP_EDITING
    BEQ EL_ESC_VIEWER
EL_ESC_EDIT:
    ; discard edits: re-read sector from SD, stay in navigate mode
    LDA #$00
    STA ZP_EDITMODE         ; viewer mode for the re-read
    JSR LOAD_AND_SHOW       ; re-reads sector, draws viewer
    LDA #$01
    STA ZP_EDITMODE         ; editor mode again
    LDA #$00
    STA ZP_EDITING
    JSR DRAW_EDIT_BANNER
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_ESC_VIEWER:
    LDA #$00
    STA ZP_EDITMODE         ; viewer: no cursor flash
    JSR DISPLAY_SECTOR
    JMP MAIN_LOOP
EL_NOT_ESC:
    CMP #$09                ; TAB -> toggle hex/ascii field (works in both states)
    BNE EL_NOT_TAB
    LDA ZP_FIELD
    EOR #$01
    STA ZP_FIELD
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_NOT_TAB:
    LDA ZP_EDITING
    BEQ EL_NAV_KEYS         ; navigate mode: W writes, IJKM move
    JMP EL_EDITING_ON       ; edit state: keys modify bytes (W is typed as data)
EL_NAV_KEYS:
    LDA ZP_KEY              ; navigate: reload key (LDA ZP_EDITING clobbered A)
    CMP #$57                ; 'W' write sector back to SD (navigate only)
    BEQ EL_WRITE
    CMP #$77                ; 'w' write (lowercase)
    BNE EL_NOT_W
EL_WRITE:
    ; Safety: re-read the sector and compare against ORIGBUF. If the SD image
    ; was swapped/changed since we loaded, prompt for a forced write instead of
    ; blindly writing the old card's data to a different image's LBA.
    JSR CHECK_SD_UNCHANGED
    BCS EL_WR_GO              ; SD unchanged -> write normally
    JSR PROMPT_FORCE_WRITE    ; "SD Card Changed. Force Write (y/n)?"
    BCC EL_WR_ABORT           ; user said no -> abort the write
EL_WR_GO:
    JSR WRITE_SECTOR
    BEQ EL_WOK
    CMP #$02
    BEQ EL_WP
    ; generic failure: the SD may have been swapped / re-attached, which resets
    ; the SPI state (deselect + uninitialized). Re-run SD_INIT (re-select +
    ; CMD0/8/55/41/16) and retry the write once; only report failure if the
    ; retry still fails.
    JSR SD_INIT
    JSR WRITE_SECTOR
    BEQ EL_WOK
    CMP #$02
    BEQ EL_WP
    JMP EL_WFAIL
EL_WR_ABORT:
    ; user cancelled the force write: clear the prompt line and stay
    LDA #22
    JSR GOTO_ROW
    JSR CLEAR_LINE
    JMP EDIT_LOOP
EL_WP:
    ; SD is write protected: show the specific message
    LDA #22
    JSR GOTO_ROW
    JSR PRINT_MSG_WP
    JMP EDIT_LOOP
EL_WOK:
    LDA #$00
    STA ZP_DIRTY
    JSR CLEAR_DIRTY          ; all bytes written -> clear the dirty map
    JSR COPY_ORIG            ; written bytes are now the new original
    JSR UPDATE_DIRTY
    ; clear the stale status row 22 (e.g. a previous "SD Write Protected!" /
    ; "SD Write failed!" from an earlier attempt) so it doesn't linger beside
    ; the fresh "Saved (clean)" indicator.
    LDA #22
    JSR GOTO_ROW
    JSR CLEAR_LINE
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_WFAIL:
    LDA #22
    JSR GOTO_ROW
    JSR PRINT_MSG_WFAIL
    JMP EDIT_LOOP
EL_NOT_W:
    ; navigate mode: IJKM move the cursor, E enters edit
    LDA ZP_KEY
    JSR NORMKEY             ; I/J/K/M/E accept lowercase too
    CMP #$45                ; 'E' -> enter edit mode
    BNE EL_NOT_E
    LDA #$01
    STA ZP_EDITING
    LDA #$00
    STA ZP_NIB              ; start at the high (left) nibble of the cursor byte
    JSR DRAW_EDIT_BANNER
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_NOT_E:
    CMP #$49                ; 'I' up
    BNE EL_NOT_I
    LDA ZP_EDIT
    CMP #$10
    BCC EL_NO_UP
    SEC
    SBC #16
    STA ZP_EDIT
    JSR DRAW_DATA
EL_NO_UP:
    JMP EDIT_LOOP
EL_NOT_I:
    CMP #$4D                ; 'M' down
    BNE EL_NOT_M
    LDA ZP_EDIT
    CMP #$F0                ; >= 240 -> bottom row, don't move
    BCS EL_NO_DOWN
    CLC
    ADC #16
    STA ZP_EDIT
    JSR DRAW_DATA
EL_NO_DOWN:
    JMP EDIT_LOOP
EL_NOT_M:
    CMP #$4A                ; 'J' left
    BNE EL_NOT_J
    LDA ZP_FIELD
    BNE ELJ_ASCII
    ; hex field: per-nibble left
    LDA ZP_NIB
    BNE ELJ_NIB1
    ; nib==0 -> previous byte, nib=1
    LDA ZP_EDIT
    BEQ ELJ_DONE
    SEC
    SBC #$01
    STA ZP_EDIT
    LDA #$01
    STA ZP_NIB
    JMP ELJ_DONE
ELJ_NIB1:
    ; nib==1 -> nib=0, same byte
    LDA #$00
    STA ZP_NIB
    JMP ELJ_DONE
ELJ_ASCII:
    ; ascii field: byte-1
    LDA ZP_EDIT
    BEQ ELJ_DONE
    SEC
    SBC #$01
    STA ZP_EDIT
ELJ_DONE:
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_NOT_J:
    CMP #$4B                ; 'K' right
    BNE EL_NOT_K
    LDA ZP_FIELD
    BNE ELK_ASCII
    ; hex field: per-nibble right
    LDA ZP_NIB
    BEQ ELK_NIB0
    ; nib==1 -> next byte, nib=0
    LDA ZP_EDIT
    CMP #$FF
    BEQ ELK_DONE
    CLC
    ADC #$01
    STA ZP_EDIT
    LDA #$00
    STA ZP_NIB
    JMP ELK_DONE
ELK_NIB0:
    ; nib==0 -> nib=1, same byte
    LDA #$01
    STA ZP_NIB
ELK_DONE:
    JSR DRAW_DATA
    JMP EDIT_LOOP
ELK_ASCII:
    ; ascii field: byte+1
    LDA ZP_EDIT
    CMP #$FF
    BEQ ELK_DONE2
    CLC
    ADC #$01
    STA ZP_EDIT
ELK_DONE2:
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_NOT_K:
    JMP EDIT_LOOP           ; navigate: other keys ignored
EL_EDITING_ON:
    ; ---- edit state: keys modify the byte under the cursor, CR exits ----
    LDA ZP_KEY              ; reload: EL_NOT_TAB's LDA ZP_EDITING clobbered A
    CMP #$0D                ; CR -> exit edit mode back to navigate
    BNE EL_ED_NOT_CR
    LDA #$00
    STA ZP_EDITING
    JSR DRAW_EDIT_BANNER
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_ED_NOT_CR:
    LDA ZP_FIELD
    BEQ EL_TRY_HEX          ; hex field -> hex digit handling
    ; ascii field: printable char -> set byte (incl. I/J/K/L/M)
    LDA ZP_KEY
    CMP #$20
    BCC EL_ASCII_SKIP       ; < 0x20 -> ignore
    CMP #$7F
    BCS EL_ASCII_SKIP       ; >= 0x7F -> ignore
    STA ZP_TEMP2            ; char -> new byte value
    JSR STORE_BUF_BYTE
    JSR UPDATE_DIRTY_BYTE   ; dirty only if value actually changed
    JSR SET_DIRTY_FLAG      ; ZP_DIRTY = any dirty?
    JSR UPDATE_DIRTY
    ; advance to next byte
    LDA ZP_EDIT
    CMP #$FF
    BEQ EL_ASCII_DONE
    CLC
    ADC #$01
    STA ZP_EDIT
EL_ASCII_DONE:
    JSR DRAW_DATA
    JMP EDIT_LOOP
EL_ASCII_SKIP:
    JMP EDIT_LOOP
EL_TRY_HEX:
    ; hex digit?
    LDA ZP_KEY
    JSR CONVERT_HEX
    BCC EL_ED_VALID         ; valid nibble -> edit
    JMP EDIT_LOOP           ; invalid -> ignore
EL_ED_VALID:
    STA ZP_TEMP2            ; save nibble
    LDA ZP_NIB
    BNE EL_ED_LOW
    ; high nibble: newbyte = (nibble<<4) | (byte & 0x0F)
    LDA ZP_TEMP2
    ASL A
    ASL A
    ASL A
    ASL A
    STA ZP_TEMP
    JSR GET_BUF_BYTE
    AND #$0F
    ORA ZP_TEMP
    JMP EL_ED_HAVE
EL_ED_LOW:
    ; low nibble: newbyte = (byte & 0xF0) | nibble
    JSR GET_BUF_BYTE
    AND #$F0
    ORA ZP_TEMP2
EL_ED_HAVE:
    STA ZP_TEMP2            ; new byte value
    JSR STORE_BUF_BYTE
    JSR UPDATE_DIRTY_BYTE   ; dirty only if value actually changed
    JSR SET_DIRTY_FLAG      ; ZP_DIRTY = any dirty?
    JSR UPDATE_DIRTY
    ; advance nibble: 0->1 same byte, 1->0 next byte
    LDA ZP_NIB
    BNE EL_ED_LOWADV
    LDA #$01
    STA ZP_NIB
    JMP EL_ED_AFTER
EL_ED_LOWADV:
    LDA ZP_EDIT
    CMP #$FF
    BEQ EL_ED_AFTER
    CLC
    ADC #$01
    STA ZP_EDIT
    LDA #$00
    STA ZP_NIB
EL_ED_AFTER:
    JSR DRAW_DATA
    JMP EDIT_LOOP
