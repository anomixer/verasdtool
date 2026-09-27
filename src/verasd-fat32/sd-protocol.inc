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
