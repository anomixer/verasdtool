; verasd_drv.asm — VERA SD ProDOS 8 block driver (assembled at bank-2 $D400)
; ProDOS 8 device driver: JMP (goAdr) entry. ZP: $42=cmd(0=status/1=read/2=write),
; $43=unit, $44/45=buffer, $46/47=block. Carry clear=ok, carry set=err(A).
; Installed by verasd.asm; the data area is patched by the installer.
;
; SD / SPI layer derives from verasdformat (C64/AGFA lineage), with
; ProDOS memory/ABI protection and bounded SD protocol handling:
;   * SPI_CTRL (base+$1F): bit0=Select (1=CS low/selected), bit1=Slow clock
;     (1=390kHz), bit7=Busy (1=transfer in progress). VERA's 12.5MHz fast clock
;     is not reliable in every slot, so this driver runs everything on the slow
;     390kHz clock.
;   * SPI_DATA (base+$1E): write starts a transfer, read returns the received byte.
;   * CMD0/CMD8 carry real CRC7 ($95/$87); every other command uses $FF because
;     CRC checking is off in SPI mode by default.
;   * One dummy byte is clocked out before each command (Ncr response latency).
;   * CMD17/CMD24 use block addresses for SDHC and byte addresses for SDSC.
;   * The busy-wait is bounded: a card that never frees the line reports an
;     error instead of stalling the machine (~98s with no bound).

        ; --- ZP scratch (driver only uses $28-$3F, never clobbers $40+) ---
        sd_lba0 = $28
        sd_lba1 = $29
        sd_lba2 = $2A
        sd_lba3 = $2B
        zp_sx   = $2C
        zp_sy   = $2D
        zp_buf  = $30      ; 2 bytes: $44/$45 buffer
        zp_dsp  = $32      ; 2 bytes: SPI_DATA address
        zp_dsc  = $34      ; 2 bytes: SPI_CTRL address
        sd_tmp0 = $36      ; busy-wait counters (page $36/$37, free here)
        sd_tmp1 = $37
        sd_err  = $3E      ; sticky SPI error flag (0=ok, $01=timeout)

        SPI_ON  = $03      ; CS selected + slow clock
        SPI_OFF = $02      ; CS released + slow clock

start:
        php
        sei
        cld
        ldx #$17
save_zp:
        lda $28,X
        pha
        dex
        bpl save_zp
        jsr dispatch
        sta result_a
        stx result_x
        sty result_y
        ldx #0
restore_zp:
        pla
        sta $28,X
        inx
        cpx #$18
        bne restore_zp
        plp
        ldx result_x
        ldy result_y
        lda result_a
        beq return_ok
        sec
        rts
return_ok:
        clc
        rts
dispatch:
        lda $43
        and #$F0
        cmp unit_number
        beq valid_unit
        lda #$28
        sec
        rts
valid_unit:
        cld
        lda $42
        beq do_status
        cmp #1
        beq do_io
        cmp #2
        beq do_io
        lda #$27
        sec
        rts

do_status:
        ldx blocks_lo
        ldy blocks_hi
        clc
        lda #$00
        rts

do_io:
        lda $47
        cmp blocks_hi
        bcc block_valid
        bne block_invalid
        lda $46
        cmp blocks_lo
        bcc block_valid
block_invalid:
        lda #$27
        sec
        rts
block_valid:
        ; set up ZP pointers from driver data (patched by installer)
        lda spi_data_addr
        sta zp_dsp
        lda spi_data_addr+1
        sta zp_dsp+1
        lda spi_ctrl_addr
        sta zp_dsc
        lda spi_ctrl_addr+1
        sta zp_dsc+1
        lda $44
        sta zp_buf
        lda $45
        sta zp_buf+1
        lda $42
        cmp #1
        beq do_read
do_write:
        lda #SPI_ON
        ldy #0
        sta (zp_dsc),Y
        jsr sd_cmd24
        bcs io_err
        jsr sd_write_512
        bcs io_err
        jsr sd_wait_busy
        bcs io_err
        jsr sd_release
        bcs release_error
        clc
        lda #$00
        rts
do_read:
        lda #SPI_ON
        ldy #0
        sta (zp_dsc),Y
        jsr sd_cmd17
        bcs io_err
        jsr sd_wait_token
        bcs io_err
        jsr sd_read_512
        bcs io_err
        jsr sd_release
        bcs release_error
        clc
        lda #$00
        rts
io_err:
        jsr sd_release
release_error:
        lda #$27
        sec
        rts

sd_release:
        lda #SPI_OFF
        ldy #0
        sta (zp_dsc),Y
        lda #$FF
        jsr spi_xfer
        rts

; --- SD commands -------------------------------------------------------------
sd_cmd17:
        lda #17
        jsr sd_cmd2
        rts
sd_cmd24:
        lda #24
        jsr sd_cmd2
        bcs c24err
        lda #$FF
        jsr spi_xfer
        bcs c24err
        lda #$FE
        jsr spi_xfer            ; data token for the write
        bcs c24err
        clc
        rts
c24err: sec
        rts

; Send one command frame and poll for R1.  A = command number on entry;
; returns the R1 byte in A, carry clear on success.
sd_cmd2:
        ora #$40
        sta command_byte
        lda #$FF
        jsr spi_xfer
        bcs cmd_err
        lda command_byte
        jsr spi_xfer            ; 0x40 + command number
        bcs cmd_err
        jsr sd_build_lba
        lda sd_lba3
        jsr spi_xfer            ; LBA bits 31-24
        bcs cmd_err
        lda sd_lba2
        jsr spi_xfer            ; bits 23-16
        bcs cmd_err
        lda sd_lba1
        jsr spi_xfer            ; bits 15-8
        bcs cmd_err
        lda sd_lba0
        jsr spi_xfer            ; bits 7-0
        bcs cmd_err
        lda #$FF
        jsr spi_xfer            ; CRC (off in SPI mode)
        bcs cmd_err
        ldx #$FF
poll2:  lda #$FF
        jsr spi_xfer            ; poll for R1 (bit7 clear = answer)
        bcs cmd_err
        cmp #$80
        bcc r1ok
        dex
        bne poll2
        sec
        rts
r1ok:   cmp #0
        bne cmd_err
        clc
        rts
cmd_err:
        sec
        rts

sd_build_lba:
        lda $46
        clc
        adc part_offset
        sta sd_lba0
        lda $47
        adc part_offset+1
        sta sd_lba1
        lda #$00
        adc #$00
        sta sd_lba2
        lda #0
        sta sd_lba3
        lda byte_addressed
        beq lba_done
        ldx #9
lba_shift:
        asl sd_lba0
        rol sd_lba1
        rol sd_lba2
        rol sd_lba3
        dex
        bne lba_shift
lba_done:
        rts

; --- data token / busy -------------------------------------------------------
sd_wait_token:
        lda #0
        sta token_count
        sta token_count+1
tok:
        lda #$FF
        jsr spi_xfer
        bcs tok_err
        cmp #$FE
        beq tokok
        cmp #$FF
        bne tok_err
        inc token_count
        bne tok
        inc token_count+1
        bne tok
tok_err:
        sec
        rts
tokok:
        clc
        rts

sd_wait_busy:
        ldx #$FF
response_poll:
        lda #$FF
        jsr spi_xfer
        bcs busy_err
        cmp #$FF
        bne response_got
        dex
        bne response_poll
        sec
        rts
response_got:
        and #$1F
        cmp #$05
        bne busy_err
        lda #0
        sta busy_count
        sta busy_count+1
busy:
        lda #$FF
        jsr spi_xfer
        bcs busy_err
        cmp #$FF
        beq busyok
        inc busy_count
        bne busy
        inc busy_count+1
        bne busy
busy_err:
        sec
        rts
busyok:
        clc
        rts

; --- 512-byte transfer -------------------------------------------------------
sd_read_512:
        ldy #0
r0:     lda #$FF
        jsr spi_xfer
        bcs rd_err
        jsr GATE_STORE
        iny
        bne r0
        inc zp_buf+1
        ldy #0
r1:     lda #$FF
        jsr spi_xfer
        bcs rd_err
        jsr GATE_STORE
        iny
        bne r1
        dec zp_buf+1
        lda #$FF
        jsr spi_xfer            ; the two CRC bytes
        bcs rd_err
        lda #$FF
        jsr spi_xfer
        bcs rd_err
        clc
        rts
rd_err:
        sec
        rts

sd_write_512:
        ldy #0
w0:     jsr GATE_LOAD
        jsr spi_xfer
        bcs wr_err
        iny
        bne w0
        inc zp_buf+1
        ldy #0
w1:     jsr GATE_LOAD
        jsr spi_xfer
        bcs wr_err
        iny
        bne w1
        dec zp_buf+1
        lda #$FF
        jsr spi_xfer            ; the two CRC bytes
        bcs wr_err
        lda #$FF
        jsr spi_xfer
        bcs wr_err
        clc
        rts
wr_err:
        sec
        rts

; --- SPI primitive -----------------------------------------------------------
; Write A to SPI_DATA, wait for BUSY to clear, return the received byte in A.
; Carry set on timeout.
spi_xfer:
        stx zp_sx
        sty zp_sy
        ldy #0
        sta (zp_dsp),Y
        jsr spi_wait2
        bcs xfer_tmo
        lda (zp_dsp),Y
        ldx zp_sx
        ldy zp_sy
        clc
        rts
xfer_tmo:
        lda #$01
        sta sd_err
        ldx zp_sx
        ldy zp_sy
        sec
        rts

spi_wait2:
        lda #$00
        sta sd_tmp0
        sta sd_tmp1
sw2:    lda (zp_dsc),Y
        bpl ok2
        inc sd_tmp0
        bne sw2
        inc sd_tmp1
        bne sw2
        sec
        rts
ok2:    clc
        rts

; --- driver data area (patched by the installer) ----------------------------
blocks_lo:      !byte 0
blocks_hi:      !byte 0
part_offset:    !word 0
spi_data_addr:  !word $C21E
spi_ctrl_addr:  !word $C21F

byte_addressed: !byte 0
unit_number: !byte $20
result_a: !byte 0
result_x: !byte 0
result_y: !byte 0
busy_count: !word 0
command_byte: !byte 0
token_count: !word 0
