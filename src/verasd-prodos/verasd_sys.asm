; verasd.asm — VERA SD ProDOS 8 driver installer (assembled at $2000)
; BRUN from BASIC. Detects VERA (slot 2/4), inits SD, copies the block
; driver to LC bank-2 $D400 with a common $FF00 bridge, then registers it.
; ON_LINE logs the volume; body and bridge survive SYSTEM program changes.
;
; SD / SPI layer derives from verasdformat. SPI_CTRL
; (base+$1F): bit0=Select (1=CS low), bit1=Slow clock (1=390kHz), bit7=Busy.
; This installer runs everything on the slow 390kHz clock, which works in
; every slot (VERA's 12.5MHz fast clock loses reads on some Apple II slots).
; SD init uses CMD0/CMD8/CMD55/ACMD41/CMD58 and CMD16 for SDSC,
; preceded by deselected power-up clocks.
;
; Build script injects: DRV_SPI_DATA/DRV_SPI_CTRL/DRV_BLOCKS_LO/
; DRV_BLOCKS_HI/DRV_PART_OFF (driver patch-point addresses), DRV_SIZE,
; and the driver bytes after `driver_src:`.

MLI         = $BF00
DEVADR      = $BF10
DEVCNT      = $BF31
DEVLST      = $BF32
ON_LINE     = $C5
ONLINE_BUF  = $1B00
COUT        = $FDED
DRV_TARGET  = $FF00
DRV_BODY    = $D400

; --- ZP scratch ---
zp_spidat = $32      ; 2 bytes: SPI_DATA address
zp_spist  = $34      ; 2 bytes: SPI_CTRL address
zp_vera   = $3A
zp_ptr    = $38
sd_arg0   = $2C
sd_arg1   = $2D
sd_arg2   = $2E
sd_arg3   = $2F
sd_crc    = $28
zp_sx     = $2A
zp_sy     = $2B
zp_tmp    = $30
zp_unit   = $31
sd_tmp0   = $26      ; busy-wait counters (free here)
sd_tmp1   = $27
sd_err    = $25      ; sticky SPI error flag

SPI_ON    = $03      ; CS selected + slow clock
SPI_OFF   = $02      ; CS released + slow clock

start:
        php
        sei
        cld
        ldx #$22
installer_save_zp:
        lda $25,X
        sta saved_zp,X
        dex
        bpl installer_save_zp
        jsr reserve_memory
        bcc allocated_start
        lda #2
        sta message_id
        jmp done
allocated_start:
        lda #$00
        sta zp_vera
        lda #$C2
        sta zp_vera+1
        jsr detect_vera
        bcs slot_ok
        lda #$00
        sta zp_vera
        lda #$C4
        sta zp_vera+1
        jsr detect_vera
        bcs slot_ok
        lda #0
        sta message_id
        jmp failed_done

slot_ok:
        jsr vera_disable_irq_vid
        lda zp_vera
        clc
        adc #$1E
        sta zp_spidat
        lda zp_vera+1
        adc #$00
        sta zp_spidat+1
        lda zp_vera
        clc
        adc #$1F
        sta zp_spist
        lda zp_vera+1
        adc #$00
        sta zp_spist+1

        jsr sd_init
        bcs init_fail
        jsr copy_driver
        jsr patch_driver
        jsr read_volume
        bcs install_rollback
        jsr register_device
        bcs install_rollback
        lda #1
        sta message_id
        jmp done

install_rollback:
init_fail:
        lda #2
        sta message_id
failed_done:
        jsr release_memory
done:
        ldx #$22
installer_restore_zp:
        lda saved_zp,X
        sta $25,X
        dex
        bpl installer_restore_zp
        jsr show_message
        jsr message_delay
        plp

        ; Return to ProDOS via MLI QUIT ($65). This is the standard way a SYS
        ; file exits: ProDOS takes control back and returns to the caller (the
        ; Bitsy Bye menu, the ] prompt, or the boot sequence). A SYS file is
        ; entered via JMP with no return address, so RTS would pop $FFFF and
        ; fall into ROM $0000 -> BRK.
        lda     #4
        sta     $3420
        lda     #0
        sta     $3421
        sta     $3422
        sta     $3423
        sta     $3424
        jsr     MLI
        !byte   $65
        !word   $3420
        jmp     quit_returned

quit_returned:
        jmp     quit_returned

; Leave the result visible briefly before returning control to ProDOS/launcher.
; Two 65536-iteration loops at roughly 1 MHz are about one second total.
message_delay:
        ldx #2
md_outer:
        lda #$00
        sta md_count
        sta md_count+1
md_loop:
        dec md_count
        bne md_loop
        dec md_count+1
        bne md_loop
        dex
        bne md_outer
        rts
md_count: !word 0

; =============================================================================
; Copy the driver to DRV_TARGET
; =============================================================================
copy_driver:
        lda $C083
        lda $C083
        lda #<DRV_BODY
        sta zp_ptr
        lda #>DRV_BODY
        sta zp_ptr+1
        lda #<driver_src
        sta zp_tmp
        lda #>driver_src
        sta zp_tmp+1
        ldx #0
        ldy #0
cp_loop:
        lda (zp_tmp),Y
        sta (zp_ptr),Y
        iny
        bne cp_loop
        inc zp_tmp+1
        inc zp_ptr+1
        inx
        cpx #DRV_PAGES
        bne cp_loop
        lda $C08B
        lda $C08B
        ldx #0
copy_gate:
        lda gate_src,X
        sta DRV_TARGET,X
        inx
        cpx #GATE_SIZE
        bne copy_gate
        lda $C082
        rts

; =============================================================================
; Patch the driver's data area at DRV_TARGET
; =============================================================================
patch_driver:
        lda zp_vera+1
        asl
        asl
        asl
        asl
        sta installed_unit
        lda $C083
        lda $C083
        lda zp_spidat
        sta DRV_SPI_DATA
        lda zp_spidat+1
        sta DRV_SPI_DATA+1
        lda zp_spist
        sta DRV_SPI_CTRL
        lda zp_spist+1
        sta DRV_SPI_CTRL+1
        lda #$FF
        sta DRV_BLOCKS_LO
        sta DRV_BLOCKS_HI
        lda #$00
        sta DRV_PART_OFF
        sta DRV_PART_OFF+1
        lda address_mode
        sta DRV_BYTE_MODE
        lda zp_vera+1
        asl
        asl
        asl
        asl
        sta DRV_UNIT
        lda $C082
        clc
        rts

; =============================================================================
; Register the device + ON_LINE
; =============================================================================
register_device:
        lda installed_unit
        sta on_line_unit
        ldx DEVCNT
        inx
        stx device_count
        cpx #14
        bcs registration_bad
        ldy #0
check_device:
        cpy device_count
        beq append_device
        lda DEVLST,Y
        and #$F0
        cmp on_line_unit
        beq registration_bad
        iny
        bne check_device
append_device:
        lda on_line_unit
        sta DEVLST,Y
        inc DEVCNT
        lda zp_vera+1
        and #$0F
        asl
        tax
        lda DEVADR,X
        sta old_vector
        lda DEVADR+1,X
        sta old_vector+1
        lda #<DRV_TARGET
        sta DEVADR,X
        lda #>DRV_TARGET
        sta DEVADR+1,X
        jsr MLI
        !byte ON_LINE
        !word on_line_params
        bcc on_ok
        lda installed_unit
        lsr
        lsr
        lsr
        tax
        lda old_vector
        sta DEVADR,X
        lda old_vector+1
        sta DEVADR+1,X
        dec DEVCNT
registration_bad:
        sec
        rts
on_ok:
        clc
        rts

on_line_params:
        !byte 2
on_line_unit:
        !byte 0
        !word ONLINE_BUF

; =============================================================================
; VERA detection
; =============================================================================
detect_vera:
        lda zp_vera
        sta zp_ptr
        lda zp_vera+1
        sta zp_ptr+1
        ldy #$05
        lda #$01
        sta (zp_ptr),Y
        lda (zp_ptr),Y
        cmp #$01
        bne dv_fail
        lda #$00
        sta (zp_ptr),Y
        lda (zp_ptr),Y
        bne dv_fail
        ldy #$00
        lda #$00
        sta (zp_ptr),Y
        iny
        sta (zp_ptr),Y
        iny
        sta (zp_ptr),Y
        iny
        lda #$DE
        sta (zp_ptr),Y
        lda (zp_ptr),Y
        cmp #$DE
        bne dv_fail
        lda #$6F
        sta (zp_ptr),Y
        lda (zp_ptr),Y
        cmp #$6F
        bne dv_fail
        sec
        rts
dv_fail:
        clc
        rts

; Disable VERA interrupt-enable and video display (IEN=0, DC_VID=0),
; so the VERA SD/VSYNC lines stay quiet during the transfer.
vera_disable_irq_vid:
        lda zp_vera
        sta zp_ptr
        lda zp_vera+1
        sta zp_ptr+1
        ldy #$06
        lda #$00
        sta (zp_ptr),Y
        ldy #$09
        sta (zp_ptr),Y
        rts

; =============================================================================
; SPI primitives (proven verasdformat layer, slow clock)
; =============================================================================
; Clock A out over SPI. X/Y preserved. Carry set on timeout.
spi_send:
        stx zp_sx
        sty zp_sy
        ldy #0
        sta (zp_spidat),Y
        jsr spi_wait
        bcs send_tmo
        ldx zp_sx
        ldy zp_sy
        clc
        rts
send_tmo:
        lda #$01
        sta sd_err
        ldx zp_sx
        ldy zp_sy
        sec
        rts

; Clock out $FF and return the received byte. X/Y preserved.
spi_read:
        stx zp_sx
        sty zp_sy
        ldy #0
        lda #$FF
        sta (zp_spidat),Y
        jsr spi_wait
        bcs read_tmo
        lda (zp_spidat),Y
        ldx zp_sx
        ldy zp_sy
        clc
        rts
read_tmo:
        lda #$01
        sta sd_err
        ldx zp_sx
        ldy zp_sy
        sec
        rts

; Spin until BUSY (bit7 of SPI_CTRL) clears. Carry set on timeout.
spi_wait:
        lda #$00
        sta sd_tmp0
        sta sd_tmp1
swait:  lda (zp_spist),Y
        and #$80
        beq sok
        inc sd_tmp0
        bne swait
        inc sd_tmp1
        bne swait
        sec
        rts
sok:    clc
        rts

; =============================================================================
; SD commands
; =============================================================================
; A = command number. sd_arg0-3 = argument (MSB first), sd_crc = CRC byte.
; Returns R1 in A; carry set on timeout.
sd_cmd:
        ora #$40
        sta command_byte
        lda #$FF
        jsr spi_send
        bcs cmd_tmo
        lda command_byte
        jsr spi_send
        bcs cmd_tmo
        lda sd_arg0
        jsr spi_send
        bcs cmd_tmo
        lda sd_arg1
        jsr spi_send
        bcs cmd_tmo
        lda sd_arg2
        jsr spi_send
        bcs cmd_tmo
        lda sd_arg3
        jsr spi_send
        bcs cmd_tmo
        lda sd_crc
        jsr spi_send
        bcs cmd_tmo
        ldx #$FF
poll:   jsr spi_read
        bcs cmd_tmo
        cmp #$80
        bcc got
        dex
        bne poll
        sec
        rts
got:    clc
        rts
cmd_tmo:
        sec
        rts

; =============================================================================
; SD init (SDHC/SDSC negotiation and bounded readiness retries)
; =============================================================================
sd_init:
        jsr sd_preamble
        bcs sd_init_bad
        jsr sd_cmd0
        bcs sd_init_bad
        jsr sd_cmd8
        bcs sd_init_bad
        lda #0
        sta init_attempts
init_retry:
        jsr sd_cmd55
        bcs sd_init_bad
        jsr sd_acmd41
        bcs sd_init_bad
        cmp #0
        beq init_ready
        cmp #1
        bne sd_init_bad
        inc init_attempts
        bne init_retry
        beq sd_init_bad
init_ready:
        jsr sd_ocr
        bcs sd_init_bad
        lda address_mode
        beq init_finish
        jsr sd_cmd16
        bcs sd_init_bad
init_finish:
        lda #SPI_OFF
        ldy #0
        sta (zp_spist),Y
        clc
        rts
sd_init_bad:
        lda #SPI_OFF
        ldy #0
        sta (zp_spist),Y
        sec
        rts

; 80 dummy bytes provide 640 clocks; SD requires >=74 with CS high.
sd_preamble:
        lda #SPI_OFF
        ldy #0
        sta (zp_spist),Y
        ldx #80
prm:    lda #$FF
        jsr spi_send
        bcs prm_bad
        dex
        bne prm
        clc
        rts
prm_bad:
        sec
        rts

; CMD0: 40 00 00 00 00 95 (real CRC7) — selects the card, R1 must be $01.
sd_cmd0:
        lda #SPI_ON
        ldy #0
        sta (zp_spist),Y
        lda #$00
        sta sd_arg0
        sta sd_arg1
        sta sd_arg2
        sta sd_arg3
        lda #$95
        sta sd_crc
        lda #0
        jsr sd_cmd
        bcs c0_bad
        cmp #$01
        bne c0_bad
        clc
        rts
c0_bad:
        sec
        rts

; CMD8: 48 00 00 01 AA 87 (real CRC7) — card stays selected from CMD0.
sd_cmd8:
        lda #$00
        sta sd_arg0
        sta sd_arg1
        lda #$01
        sta sd_arg2
        lda #$AA
        sta sd_arg3
        lda #$87
        sta sd_crc
        lda #8
        jsr sd_cmd
        bcs c8_bad
        cmp #$05
        beq c8_legacy
        cmp #$01
        bne c8_bad
        ldx #4
c8_tail:
        jsr spi_read
        bcs c8_bad
        dex
        bne c8_tail
        cmp #$AA
        bne c8_bad
        lda #$40
        sta hcs_flag
c8_legacy:
        clc
        rts
c8_bad:
        sec
        rts

; CMD55: 77 00 00 00 00 01 (next command is an ACMD).
sd_cmd55:
        lda #$00
        sta sd_arg0
        sta sd_arg1
        sta sd_arg2
        sta sd_arg3
        lda #$01
        sta sd_crc
        lda #55
        jsr sd_cmd
        bcs c55_bad
        cmp #2
        bcs c55_bad
        clc
        rts
c55_bad:
        sec
        rts

; ACMD41: request HCS for CMD8-capable cards; R1=1 retries, R1=0 ready.
sd_acmd41:
        lda hcs_flag
        sta sd_arg0
        lda #$00
        sta sd_arg1
        sta sd_arg2
        sta sd_arg3
        lda #$FF
        sta sd_crc
        lda #41
        jsr sd_cmd
        rts
c41_bad:
        sec
        rts

; CMD16: 50 00 00 02 00 FF (SET_BLOCKLEN 512, MSB first).
sd_cmd16:
        lda #$00
        sta sd_arg0
        sta sd_arg1
        lda #$02
        sta sd_arg2
        lda #$00
        sta sd_arg3
        lda #$FF
        sta sd_crc
        lda #16
        jsr sd_cmd
        bcs c16_bad
        cmp #0
        bne c16_bad
        clc
        rts
c16_bad:
        sec
        rts

; =============================================================================
 ; OCR identifies SDHC block addressing versus SDSC byte addressing.
sd_ocr:
        lda #0
        sta sd_arg0
        sta sd_arg1
        sta sd_arg2
        sta sd_arg3
        lda #$FF
        sta sd_crc
        lda #58
        jsr sd_cmd
        bcs ocr_bad
        cmp #0
        bne ocr_bad
        jsr spi_read
        bcs ocr_bad
        and #$40
        eor #$40
        sta address_mode
        ldx #3
ocr_tail:
        jsr spi_read
        bcs ocr_bad
        dex
        bne ocr_tail
        clc
        rts
ocr_bad:
        sec
        rts

reserve_memory:
        ; Only replace the native /RAM bridge, never a third-party RAM driver.
        lda $BF26
        bne reserve_bad
        lda $BF27
        cmp #$FF
        bne reserve_bad
        lda DEVCNT
        sta saved_count
        ldx #13
save_device_list:
        lda DEVLST,X
        sta saved_devices,X
        dex
        bpl save_device_list
        lda $C08B
        lda $C08B
        ldx #0
save_old_gate:
        lda DRV_TARGET,X
        sta saved_gate,X
        inx
        cpx #GATE_SIZE
        bne save_old_gate
        lda $C082
        ; Disconnect /RAM without touching its auxiliary-memory contents.
        lda DEVCNT
        cmp #$FF
        beq ram_removed
        ldx #0
remove_ram_scan:
        cpx DEVCNT
        bcc remove_ram_check
        beq remove_ram_check
        bcs ram_removed
remove_ram_check:
        lda DEVLST,X
        and #$F0
        cmp #$B0
        beq remove_ram_shift
        inx
        bne remove_ram_scan
remove_ram_shift:
        cpx DEVCNT
        beq remove_ram_last
        lda DEVLST+1,X
        sta DEVLST,X
        inx
        bne remove_ram_shift
remove_ram_last:
        dec DEVCNT
ram_removed:
        lda #<GATE_NO_DEVICE
        sta $BF26
        lda #>GATE_NO_DEVICE
        sta $BF27
        clc
        rts
reserve_bad:
        sec
        rts
release_memory:
        lda $C08B
        lda $C08B
        ldx #0
restore_old_gate:
        lda saved_gate,X
        sta DRV_TARGET,X
        inx
        cpx #GATE_SIZE
        bne restore_old_gate
        lda $C082
        lda #0
        sta $BF26
        lda #$FF
        sta $BF27
        lda saved_count
        sta DEVCNT
        ldx #13
restore_device_list:
        lda saved_devices,X
        sta DEVLST,X
        dex
        bpl restore_device_list
        rts
read_volume:
        lda #1
        sta $42
        lda installed_unit
        sta $43
        lda #<ONLINE_BUF
        sta $44
        lda #>ONLINE_BUF
        sta $45
        lda #2
        sta $46
        lda #0
        sta $47
        lda $C08B
        lda $C08B
        jsr DRV_TARGET
        lda $C082
        bcs volume_bad
        lda ONLINE_BUF+4
        and #$F0
        cmp #$F0
        bne volume_bad
        lda ONLINE_BUF+$23
        cmp #39
        bne volume_bad
        lda ONLINE_BUF+$24
        cmp #13
        bne volume_bad
        lda ONLINE_BUF+$2A
        bne volume_size_ok
        lda ONLINE_BUF+$29
        cmp #8
        bcc volume_bad
volume_size_ok:
        lda $C083
        lda $C083
        lda ONLINE_BUF+$29
        sta DRV_BLOCKS_LO
        lda ONLINE_BUF+$2A
        sta DRV_BLOCKS_HI
        lda $C082
        clc
        rts
volume_bad:
        sec
        rts

; =============================================================================
; Messages
; =============================================================================
show_message:
        lda message_id
        beq message_novera
        cmp #1
        beq message_ok
        lda #<txt_fail
        ldx #>txt_fail
        jmp message_start
message_novera:
        lda #<txt_novera
        ldx #>txt_novera
        jmp message_start
message_ok:
        lda #<txt_ok
        ldx #>txt_ok
message_start:
        sta message_load+1
        stx message_load+2
        ldx #0
message_load:
        lda txt_ok,X
        beq message_end
        ora #$80
        stx message_index
        jsr COUT
        ldx message_index
        inx
        bne message_load
message_end:
        lda #$8D
        jsr COUT
        rts
installed_unit: !byte 0
saved_count: !byte 0
saved_devices: HEX 00 00 00 00 00 00 00 00 00 00 00 00 00 00
saved_gate: HEX 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
message_id: !byte 0
message_index: !byte 0

saved_zp: HEX 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
command_byte: !byte 0
address_mode: !byte 0
hcs_flag: !byte 0
init_attempts: !byte 0
device_count: !byte 0
old_vector: !word 0
txt_novera: ASC "VERA NOT FOUND"
            !byte 0
txt_ok:     ASC "VERASD INSTALLED"
            !byte 0
txt_fail:   ASC "VERASD FAILED"
            !byte 0

; =============================================================================
; The driver bytes are appended here by the build script.
; =============================================================================
driver_src:
