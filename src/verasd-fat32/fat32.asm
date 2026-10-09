; Native FAT32 file client. This is not a ProDOS block-device translation.
; Built at $2000 by fat32-build.mjs; SD backend comes from the tested driver.
COUT=$FDED
PRBYTE=$FDDA
HOME=$FC58
KBD=$C000
KBDSTRB=$C010
start:
 php
 cld
 ldx #9
app_save_zp:
 lda $06,X
 sta saved_zp,X
 dex
 bpl app_save_zp
 jsr HOME
 lda #<title
 ldx #>title
 jsr print
 lda #<byline
 ldx #>byline
 jsr print
 jsr cr
 jsr cr
 lda #0
 sta zp_vera
 lda #$C2
 sta zp_vera+1
 jsr detect_vera
 bcs app_vera_found
 lda #$C4
 sta zp_vera+1
 jsr detect_vera
 bcs app_vera_found
 jmp app_error
app_vera_found:
 lda zp_vera+1
 sta slot_page
 ldy #6
 lda #0
 sta (zp_vera),Y
 jsr raw_setup
 jsr sd_init
 bcc app_sd_ready
 jmp app_error
app_sd_ready:
 jsr mount
 bcc app_mounted
 jmp app_error
app_mounted:
 lda #<mounted
 ldx #>mounted
 jsr print
 lda #<total_sectors
 ldx #>total_sectors
 jsr print32
 jsr cr
app_menu:
 lda #<menu
 ldx #>menu
 jsr print
 jsr key
 and #$DF
 cmp #'Q'
 beq app_exit
 cmp #'C'
 beq app_catalog
 cmp #'R'
 beq app_read
 cmp #'W'
 beq app_write
 jmp app_menu
app_catalog:
 jsr catalog
 bcc app_menu
 jmp app_error_continue
app_read:
 jsr filename
 bcs app_menu
 jsr find_file
 bcs app_error_continue
 jsr read_file
 bcc app_menu
 jmp app_error_continue
app_write:
 ; Initial write test deliberately requires a preallocated regular file.
 lda #<write_warning
 ldx #>write_warning
 jsr print
 jsr key
 and #$DF
 cmp #'Y'
 bne app_menu
 lda #<write_name
 sta ZP_PTR
 lda #>write_name
 sta ZP_PTR+1
 jsr find_named
 bcs app_error_continue
 jsr write_test
 bcs app_error_continue
 lda #<write_ok
 ldx #>write_ok
 jsr print
 jmp app_menu
app_error_continue:
 lda #<error_text
 ldx #>error_text
 jsr print
 lda sd_last_err
 jsr PRBYTE
 jsr cr
 jmp app_menu
app_error:
 lda #<error_text
 ldx #>error_text
 jsr print
app_exit:
 ldx #9
app_restore_zp:
 lda saved_zp,X
 sta $06,X
 dex
 bpl app_restore_zp
 plp
 rts

; Output uses self-modified absolute addressing: ROM scratch cannot damage it.
print:
 sta print_load+1
 stx print_load+2
 ldx #0
print_load:
 lda title,X
 beq print_done
 ora #$80
 stx print_index
 jsr COUT
 ldx print_index
 inx
 bne print_load
print_done:
 rts
cr:
 lda #$8D
 jmp COUT
key:
 lda KBD
 bpl key
 and #$7F
 bit KBDSTRB
 rts
print32:
 sta print32_load+1
 stx print32_load+2
 ldx #3
print32_load:
 lda total_sectors,X
 stx print_index
 jsr PRBYTE
 ldx print_index
 dex
 bpl print32_load
 rts

detect_vera:
 ldy #5
 lda #1
 sta (zp_vera),Y
 lda (zp_vera),Y
 cmp #1
 bne detect_bad
 lda #0
 sta (zp_vera),Y
 lda (zp_vera),Y
 bne detect_bad
 ldy #0
 sta (zp_vera),Y
 iny
 sta (zp_vera),Y
 iny
 sta (zp_vera),Y
 iny
 lda #$DE
 sta (zp_vera),Y
 lda (zp_vera),Y
 cmp #$DE
 bne detect_bad
 lda #$6F
 sta (zp_vera),Y
 lda (zp_vera),Y
 cmp #$6F
 bne detect_bad
 sec
 rts
detect_bad:
 clc
 rts

raw_setup:
 lda #$1E
 sta zp_spidat
 lda #$1F
 sta zp_spist
 lda slot_page
 sta zp_spidat+1
 sta zp_spist+1
 rts
; sd_lba is a full 32-bit sector address, ZP_PTR2 points at 512-byte buffer.
sd_read_block:
 php
 sei
 cld
 jsr raw_setup
 jsr raw_bounds
 bcs raw_io_bad
 lda #SPI_ON
 ldy #0
 sta (zp_dsc),Y
 jsr sd_cmd17
 bcs raw_io_bad
 jsr sd_wait_token
 bcs raw_io_bad
 jsr sd_read_512
 bcs raw_io_bad
 jsr sd_release
 bcs raw_io_bad
 plp
 clc
 rts
sd_write_block:
 php
 sei
 cld
 jsr raw_setup
 jsr raw_bounds
 bcs raw_io_bad
 lda #SPI_ON
 ldy #0
 sta (zp_dsc),Y
 jsr sd_cmd24
 bcs raw_io_bad
 jsr sd_write_512
 bcs raw_io_bad
 jsr sd_wait_busy
 bcs raw_io_bad
 jsr sd_release
 bcs raw_io_bad
 plp
 clc
 rts
raw_io_bad:
 jsr sd_release
 lda #3
 sta sd_last_err
 plp
 sec
 rts
raw_bounds:
 ; Mounted volumes cannot access outside their selected volume.
 lda is_mounted
 beq raw_sds_check
 ldx #3
raw_lower:
 lda sd_lba,X
 cmp part_lba,X
 bcc raw_bounds_bad
 bne raw_upper_start
 dex
 bpl raw_lower
raw_upper_start:
 ldx #3
raw_upper:
 lda sd_lba,X
 cmp volume_end,X
 bcc raw_sds_check
 bne raw_bounds_bad
 dex
 bpl raw_upper
raw_bounds_bad:
 sec
 rts
raw_sds_check:
 lda address_mode
 beq raw_bounds_ok
 ; SDSC byte argument must fit in 32 bits before multiplying by 512.
 lda sd_lba+3
 bne raw_bounds_bad
 lda sd_lba+2
 and #$80
 bne raw_bounds_bad
raw_bounds_ok:
 clc
 rts
read_sd_buf:
 lda #<sd_buf
 sta ZP_PTR2
 lda #>sd_buf
 sta ZP_PTR2+1
 jmp sd_read_block
write_sd_buf:
 lda #<sd_buf
 sta ZP_PTR2
 lda #>sd_buf
 sta ZP_PTR2+1
 jmp sd_write_block

mount:
 lda #0
 sta is_mounted
 sta sd_last_err
 @zero sd_lba
 @zero part_lba
 jsr read_sd_buf
 bcc mount_sector0
 rts
mount_sector0:
 jsr signature
 bcc mount_sig_ok
 jmp mount_bad
mount_sig_ok:
 lda sd_buf+11
 bne mount_mbr
 lda sd_buf+12
 cmp #2
 beq mount_vbr
mount_mbr:
 ldx #0
mount_partition:
 lda sd_buf+$1C2,X
 cmp #$0B
 beq mount_partition_ok
 cmp #$0C
 beq mount_partition_ok
 txa
 clc
 adc #16
 tax
 cpx #64
 bne mount_partition
 jmp mount_bad
mount_partition_ok:
 ldy #0
mount_part_copy:
 lda sd_buf+$1C6,X
 sta part_lba,Y
 lda sd_buf+$1CA,X
 sta partition_size,Y
 inx
 iny
 cpy #4
 bne mount_part_copy
 @copy part_lba,sd_lba
 jsr read_sd_buf
 bcc mount_vbr
 rts
mount_vbr:
 jsr validate_bpb
 bcc mount_bpb_ok
 jmp mount_bad
mount_bpb_ok:
 @copy total_sectors,volume_end
 @add volume_end,part_lba
 bcc mount_end_ok
 jmp mount_bad
mount_end_ok:
 ; MBR partition size bounds the BPB volume.
 lda part_lba
 ora part_lba+1
 ora part_lba+2
 ora part_lba+3
 beq mount_layout
 ldx #3
mount_part_size_check:
 lda total_sectors,X
 cmp partition_size,X
 bcc mount_layout
 bne mount_bad_near
 dex
 bpl mount_part_size_check
mount_layout:
 @copy part_lba,fat_begin_lba
 @add fat_begin_lba,reserved_sectors
 bcs mount_bad_near
 @copy fat_begin_lba,clus_begin_lba
 ldx fat_count
mount_add_fats:
 @add clus_begin_lba,fat_size
 bcs mount_bad_near
 dex
 bne mount_add_fats
 @copy volume_end,cluster_count
 @sub cluster_count,clus_begin_lba
 bcc mount_bad_near
 jmp mount_count_clusters
mount_bad_near:
 jmp mount_bad
mount_count_clusters:
 lda secs_per_clus
 sta shift_count
mount_cluster_shift:
 lsr shift_count
 beq mount_cluster_count_done
 lsr cluster_count+3
 ror cluster_count+2
 ror cluster_count+1
 ror cluster_count
 jmp mount_cluster_shift
mount_cluster_count_done:
 ; FAT32 requires at least 65525 data clusters, upper reserved range excluded.
 lda cluster_count+3
 cmp #$0F
 bcs mount_bad_near
 ora cluster_count+2
 bne mount_count_valid
 lda cluster_count+1
 cmp #$FF
 bne mount_bad_near
 lda cluster_count
 cmp #$F5
 bcc mount_bad_near
mount_count_valid:
 @copy cluster_count,max_cluster
 @inc max_cluster
 @copy max_cluster,required_fat
 @inc required_fat
 ldx #7
mount_fat_sector_count:
 lsr required_fat+3
 ror required_fat+2
 ror required_fat+1
 ror required_fat
 dex
 bne mount_fat_sector_count
 @inc required_fat
 ldx #3
mount_fat_size_check:
 lda fat_size,X
 cmp required_fat,X
 bcc mount_bad_near2
 bne mount_root_check
 dex
 bpl mount_fat_size_check
mount_root_check:
 @copy root_clus,cur_clus
 jsr valid_cluster
 bcs mount_bad_near2
 ; Read-only active FAT supported; write test requires mirrored FATs.
 lda fat_flags
 and #$80
 beq mount_cache_reset
 lda fat_flags
 and #$0F
 cmp fat_count
 bcs mount_bad_near2
 tax
 beq mount_cache_reset
mount_active_fat:
 @add fat_begin_lba,fat_size
 dex
 bne mount_active_fat
mount_cache_reset:
 lda #$FF
 sta fat_cache_lba
 sta fat_cache_lba+1
 sta fat_cache_lba+2
 sta fat_cache_lba+3
 lda #1
 sta is_mounted
 clc
 rts
mount_bad_near2:
 jmp mount_bad
mount_bad:
 lda #4
 sta sd_last_err
 sec
 rts
signature:
 lda sd_buf+510
 cmp #$55
 bne signature_bad
 lda sd_buf+511
 cmp #$AA
 bne signature_bad
 clc
 rts
signature_bad:
 sec
 rts
validate_bpb:
 jsr signature
 bcs bpb_bad
 lda sd_buf+11
 bne bpb_bad
 lda sd_buf+12
 cmp #2
 bne bpb_bad
 lda sd_buf+13
 beq bpb_bad
 bmi bpb_bad
 sta secs_per_clus
 sec
 sbc #1
 and secs_per_clus
 bne bpb_bad
 lda sd_buf+14
 ora sd_buf+15
 beq bpb_bad
 lda sd_buf+16
 beq bpb_bad
 cmp #3
 bcs bpb_bad
 sta fat_count
 lda sd_buf+17
 ora sd_buf+18
 ora sd_buf+19
 ora sd_buf+20
 ora sd_buf+22
 ora sd_buf+23
 ora sd_buf+42
 ora sd_buf+43
 bne bpb_bad
 jmp bpb_copy
bpb_bad:
 sec
 rts
bpb_copy:
 @zero reserved_sectors
 lda sd_buf+14
 sta reserved_sectors
 lda sd_buf+15
 sta reserved_sectors+1
 ldx #3
bpb_copy_fields:
 lda sd_buf+32,X
 sta total_sectors,X
 lda sd_buf+36,X
 sta fat_size,X
 lda sd_buf+44,X
 sta root_clus,X
 dex
 bpl bpb_copy_fields
 lda total_sectors
 ora total_sectors+1
 ora total_sectors+2
 ora total_sectors+3
 beq bpb_bad
 lda fat_size
 ora fat_size+1
 ora fat_size+2
 ora fat_size+3
 beq bpb_bad
 lda sd_buf+40
 sta fat_flags
 lda sd_buf+41
 bne bpb_bad
 clc
 rts

valid_cluster:
 lda cur_clus+3
 ora cur_clus+2
 ora cur_clus+1
 bne valid_upper
 lda cur_clus
 cmp #2
 bcc valid_bad
valid_upper:
 ldx #3
valid_upper_loop:
 lda cur_clus,X
 cmp max_cluster,X
 bcc valid_ok
 bne valid_bad
 dex
 bpl valid_upper_loop
valid_ok:
 clc
 rts
valid_bad:
 lda #6
 sta sd_last_err
 sec
 rts
chain_reset:
 @copy cluster_count,chain_budget
 lda #0
 sta sd_last_err
 sta cycle_initialized
 rts
fat_next_cluster:
 lda cycle_initialized
 bne chain_cycle_ready
 @copy cur_clus,cycle_anchor
 @zero cycle_length
 @zero cycle_power
 inc cycle_power
 lda #1
 sta cycle_initialized
chain_cycle_ready:
 sec
 lda chain_budget
 sbc #1
 sta chain_budget
 lda chain_budget+1
 sbc #0
 sta chain_budget+1
 lda chain_budget+2
 sbc #0
 sta chain_budget+2
 lda chain_budget+3
 sbc #0
 sta chain_budget+3
 bcc valid_bad
 jsr valid_cluster
 bcs valid_bad
 jsr fat_next_cluster_unchecked
 bcs chain_return
 jsr valid_cluster
 bcs chain_return
 ; Brent cycle detection: constant storage, no cap on legitimate file size.
 ldx #3
chain_compare_anchor:
 lda cur_clus,X
 cmp cycle_anchor,X
 bne chain_advance_cycle
 dex
 bpl chain_compare_anchor
 jmp valid_bad
chain_advance_cycle:
 @inc cycle_length
 ldx #3
chain_compare_power:
 lda cycle_length,X
 cmp cycle_power,X
 bne chain_cycle_ok
 dex
 bpl chain_compare_power
 @copy cur_clus,cycle_anchor
 @zero cycle_length
 asl cycle_power
 rol cycle_power+1
 rol cycle_power+2
 rol cycle_power+3
chain_cycle_ok:
 clc
 rts
chain_return:
 rts
fat_chain_io_error:
 lda #3
 sta sd_last_err
 sec
 rts

catalog:
 jsr chain_reset
 @copy root_clus,cur_clus
catalog_cluster:
 jsr valid_cluster
 bcc catalog_valid
 rts
catalog_valid:
 jsr clus_to_lba
 lda secs_per_clus
 sta catalog_sectors
catalog_sector:
 @copy cur_lba,sd_lba
 jsr read_sd_buf
 bcc catalog_read_ok
 rts
catalog_read_ok:
 lda #<sd_buf
 sta entry_ptr
 lda #>sd_buf
 sta entry_ptr+1
 lda #16
 sta catalog_entries
catalog_entry:
 lda entry_ptr
 sta ZP_PTR
 lda entry_ptr+1
 sta ZP_PTR+1
 ldy #0
 lda (ZP_PTR),Y
 beq catalog_done
 cmp #$E5
 beq catalog_next
 ldy #11
 lda (ZP_PTR),Y
 and #$08
 bne catalog_next
 lda #0
 sta catalog_char
catalog_name:
 lda entry_ptr
 sta ZP_PTR
 lda entry_ptr+1
 sta ZP_PTR+1
 ldy catalog_char
 lda (ZP_PTR),Y
 ora #$80
 jsr COUT
 inc catalog_char
 lda catalog_char
 cmp #11
 bne catalog_name
 jsr cr
catalog_next:
 clc
 lda entry_ptr
 adc #32
 sta entry_ptr
 bcc catalog_ptr_ok
 inc entry_ptr+1
catalog_ptr_ok:
 dec catalog_entries
 bne catalog_entry
 @inc cur_lba
 dec catalog_sectors
 bne catalog_sector
 jsr fat_next_cluster
 bcc catalog_cluster
 lda sd_last_err
 bne catalog_error
catalog_done:
 clc
 rts
catalog_error:
 sec
 rts

filename:
 lda #<name_prompt
 ldx #>name_prompt
 jsr print
 ldx #10
 lda #' '
filename_clear:
 sta input_name,X
 dex
 bpl filename_clear
 lda #0
 sta name_pos
filename_key:
 jsr key
 cmp #13
 beq filename_done
 cmp #27
 beq filename_cancel
 cmp #'.'
 beq filename_ext
 cmp #'a'
 bcc filename_upper
 cmp #'z'+1
 bcs filename_upper
 and #$DF
filename_upper:
 cmp #'A'
 bcc filename_digit
 cmp #'Z'+1
 bcc filename_store
filename_digit:
 cmp #'0'
 bcc filename_key
 cmp #'9'+1
 bcs filename_key
filename_store:
 ldx name_pos
 cpx #11
 bcs filename_key
 sta input_name,X
 inc name_pos
 ora #$80
 jsr COUT
 jmp filename_key
filename_ext:
 lda #8
 sta name_pos
 lda #$AE
 jsr COUT
 jmp filename_key
filename_cancel:
 jsr cr
 sec
 rts
filename_done:
 jsr cr
 clc
 rts
find_file:
 lda #<input_name
 sta ZP_PTR
 lda #>input_name
 sta ZP_PTR+1
find_named:
 jsr chain_reset
 jsr fat_find
 bcc find_attributes
 rts
find_attributes:
 ; Do not treat directories as regular files, or overwrite read-only files.
 ldy #11
 lda (ZP_PTR2),Y
 sta found_attributes
 and #$10
 beq find_cluster
 jmp valid_bad
find_cluster:
 @copy file_first_clus,cur_clus
 lda file_size
 ora file_size+1
 ora file_size+2
 ora file_size+3
 beq find_empty
 jmp valid_cluster
find_empty:
 clc
 rts

read_file:
 @copy file_size,display_size
 lda #<size_text
 ldx #>size_text
 jsr print
 lda #<display_size
 ldx #>display_size
 jsr print32
 jsr cr
 jsr chain_reset
 jsr fat_open
 lda #0
 sta checksum
 sta checksum+1
 sta preview_done
read_file_sector:
 lda bytes_left
 ora bytes_left+1
 ora bytes_left+2
 ora bytes_left+3
 beq read_file_done
 jsr fat_read_next_sector
 bcc read_file_got
 ; EOF while bytes remain is a truncated/corrupt chain, not success.
 lda #6
 sta sd_last_err
 sec
 rts
read_file_got:
 lda preview_done
 bne read_sum
 lda #1
 sta preview_done
 lda #0
 sta preview_index
read_preview:
 ldx preview_index
 lda sd_buf,X
 jsr PRBYTE
 lda #$A0
 jsr COUT
 inc preview_index
 lda preview_index
 cmp #8
 bne read_preview
 jsr cr
read_sum:
 lda #<sd_buf
 sta ZP_PTR
 lda #>sd_buf
 sta ZP_PTR+1
 lda this_len
 sta sum_left
 lda this_len+1
 sta sum_left+1
read_sum_loop:
 lda sum_left
 ora sum_left+1
 beq read_file_sector
 ldy #0
 clc
 lda (ZP_PTR),Y
 adc checksum
 sta checksum
 bcc read_sum_no_carry
 inc checksum+1
read_sum_no_carry:
 inc ZP_PTR
 bne read_sum_ptr_ok
 inc ZP_PTR+1
read_sum_ptr_ok:
 lda sum_left
 bne read_sum_dec
 dec sum_left+1
read_sum_dec:
 dec sum_left
 jmp read_sum_loop
read_file_done:
 lda #<sum_text
 ldx #>sum_text
 jsr print
 lda checksum+1
 jsr PRBYTE
 lda checksum
 jsr PRBYTE
 jsr cr
 clc
 rts

write_test:
 lda found_attributes
 and #1
 bne write_refused
 lda file_size
 ora file_size+2
 ora file_size+3
 bne write_refused
 lda file_size+1
 cmp #4
 bne write_refused
 jsr chain_reset
 jsr fat_open
 lda #1
 sta fat_track_only
write_test_sector:
 jsr fat_read_next_sector
 bcs write_test_bad
 lda #<sd_buf
 sta ZP_PTR2
 lda #>sd_buf
 sta ZP_PTR2+1
 ldy #0
write_test_fill:
 tya
 sta sd_buf,Y
 sta sd_buf+256,Y
 iny
 bne write_test_fill
 jsr sd_write_block
 bcs write_test_bad
 lda bytes_left
 ora bytes_left+1
 ora bytes_left+2
 ora bytes_left+3
 bne write_test_sector
 lda #0
 sta fat_track_only
 clc
 rts
write_refused:
 lda #7
 sta sd_last_err
 sec
 rts
write_test_bad:
 lda #0
 sta fat_track_only
 sec
 rts

title: ASC "VeraSD FAT32 Native File Client v1.03"
 !byte 13,0
byline: ASC "by anomixer 2026"
 !byte 0
mounted: ASC "MOUNTED - SECTORS $"
 !byte 0
menu: ASC "C:CATALOG R:READ W:WRITE TEST Q:QUIT"
 !byte 13,0
error_text: ASC "FAT32 ERROR $"
 !byte 0
name_prompt: ASC "8.3 FILE: "
 !byte 0
size_text: ASC "BYTES $"
 !byte 0
sum_text: ASC "SUM16 $"
 !byte 0
write_warning: ASC "OVERWRITE TESTNOW.BIN WITH 1024 BYTES? Y"
 !byte 13,0
write_ok: ASC "WRITE OK"
 !byte 13,0
write_name: ASC "TESTNOW BIN"
saved_zp: HEX 00 00 00 00 00 00 00 00 00 00
slot_page: !byte 0
print_index: !byte 0
is_mounted: !byte 0
fat_count: !byte 0
fat_flags: !byte 0
shift_count: !byte 0
catalog_sectors: !byte 0
catalog_entries: !byte 0
catalog_char: !byte 0
entry_ptr: !word 0
found_attributes: !byte 0
name_pos: !byte 0
input_name: HEX 00 00 00 00 00 00 00 00 00 00 00
checksum: !word 0
sum_left: !word 0
preview_done: !byte 0
preview_index: !byte 0
total_sectors: !word 0,0
display_size: !word 0,0
volume_end: !word 0,0
partition_size: !word 0,0
reserved_sectors: !word 0,0
fat_size: !word 0,0
cluster_count: !word 0,0
max_cluster: !word 0,0
required_fat: !word 0,0
chain_budget: !word 0,0
cycle_initialized: !byte 0
cycle_anchor: !word 0,0
cycle_length: !word 0,0
cycle_power: !word 0,0
