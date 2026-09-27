sd_lba:          !fill 4, 0      ; target block LBA (4-byte LE) for sd_read_block
spi_ctrl_base:   !byte 0        ; shadow of SPI_CTRL non-CS bits (clock/autotx)
sd_arg:          !fill 4, 0      ; command argument, MSB..LSB
sd_crc:          !byte 0
sd_r1:           !byte 0         ; last R1 response
ocr_hi:          !byte 0         ; OCR[31:24] from CMD58
sd_block_addr:   !byte 0         ; 1 = SDHC/SDXC block addressing, 0 = byte
sd_last_err:     !byte 0
init_to:         !word 0         ; ACMD41 timeout counter
cmd_to:          !byte 0         ; sd_cmd response-poll counter (keeps X free)
rb_to:           !word 0         ; data-token timeout counter
rb_ba:           !fill 4, 0      ; byte-address scratch (lba << 9)
sx_xsave:        !byte 0         ; spi_xfer's X save slot
sx_ysave:        !byte 0         ; spi_xfer's Y save slot (see the note there)
spi_timeouts:    !byte 0         ; times BUSY never cleared (saturates at $FF)
spi_fault:       !byte 0         ; $80 = BUSY stuck, polling loops bail out
sd_trace_on:     !byte 0         ; $80 = print sd_read_block progress markers
sdt_x:           !byte 0         ; sd_trace register saves
sdt_y:           !byte 0
sd_fast_clock:   !byte 0         ; 0 = stay at ~390kHz (default, works in every
                                 ; slot), 1 = 12.5MHz (slot 4+ only). See
                                 ; sd_apply_clock for the measurements.
rb_ncap:         !byte 0         ; token bytes captured this read
rb_cap:          !fill RB_CAP_N, 0
probe_left:      !byte 0         ; sd_probe_clock fast reads remaining
vrb_passes:      !byte 0         ; sd_read_block_vram 2-pass counter
rrb_passes:      !byte 0         ; sd_read_block_ram 2-pass counter
ram_dest:        !fill 2, 0      ; fat_load_ram running RAM destination (survives
                                 ; the FAT-chain reads that trash ZP_PTR2)

; FAT32 layout (from fat_mount)
part_lba:        !fill 4, 0
fat_begin_lba:   !fill 4, 0
clus_begin_lba:  !fill 4, 0
root_clus:       !fill 4, 0
secs_per_clus:   !byte 0
fat_cache_lba:   !fill 4, 0      ; LBA currently in fat_buf ($FFFFFFFF = none)

; Streaming reader state
cur_clus:        !fill 4, 0
cur_lba:         !fill 4, 0
sects_left:      !byte 0
need_first:      !byte 0
bytes_left:      !fill 4, 0
this_len:        !word 0
fat_track_only:  !byte 0         ; 1 = fat_read_next_sector skips sd_read_block
                                 ; (caller does its own fast read via sd_lba)

; Scratch
tmp32:           !fill 4, 0
wanted_lba:      !fill 4, 0
mtmp:            !word 0

; File found by fat_find
file_first_clus: !fill 4, 0
file_size:       !fill 4, 0
search_name:     !fill 11, 0

; Caller-set VRAM destination for fat_load_vram (ADDR0_L/M/H)
ld_vaddr:        !fill 3, 0

; 512-byte sector buffers (no alignment needed: sd_read_block bumps the
; pointer's high byte by exactly 256 for the second half)
sd_buf:          !fill 512, 0    ; data / directory / MBR / BPB sector
fat_buf:         !fill 512, 0    ; cached FAT sector
