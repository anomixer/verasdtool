!zone clus_to_lba
clus_to_lba:
        sec
        lda cur_clus+0
        sbc #2
        sta tmp32+0
        lda cur_clus+1
        sbc #0
        sta tmp32+1
        lda cur_clus+2
        sbc #0
        sta tmp32+2
        lda cur_clus+3
        sbc #0
        sta tmp32+3
        ; X = log2(secs_per_clus). fat_mount rejects 0, but belt and braces:
        ; 0 never reaches 1 by shifting, and this loop has no other exit.
        ldx #0
        lda secs_per_clus
        beq .counted
.count:
        cmp #1
        beq .counted
        lsr
        inx
        jmp .count
.counted:
        cpx #0
        beq .noshift
.sh:
        asl tmp32+0
        rol tmp32+1
        rol tmp32+2
        rol tmp32+3
        dex
        bne .sh
.noshift:
        clc
        lda clus_begin_lba+0
        adc tmp32+0
        sta cur_lba+0
        lda clus_begin_lba+1
        adc tmp32+1
        sta cur_lba+1
        lda clus_begin_lba+2
        adc tmp32+2
        sta cur_lba+2
        lda clus_begin_lba+3
        adc tmp32+3
        sta cur_lba+3
        rts

; =============================================================================
; fat_next_cluster: cur_clus = FAT[cur_clus]. Carry set = end of chain.
; Uses fat_buf as a one-sector cache (fat_cache_lba tracks what's loaded).
; =============================================================================
!zone fat_next_cluster
fat_next_cluster:
        ; tmp32 = cur_clus >> 7  (FAT sector offset = cluster / 128)
        lda cur_clus+0
        sta tmp32+0
        lda cur_clus+1
        sta tmp32+1
        lda cur_clus+2
        sta tmp32+2
        lda cur_clus+3
        sta tmp32+3
        ldx #7
.sr:
        lsr tmp32+3
        ror tmp32+2
        ror tmp32+1
        ror tmp32+0
        dex
        bne .sr

        ; wanted = fat_begin_lba + tmp32
        clc
        lda fat_begin_lba+0
        adc tmp32+0
        sta wanted_lba+0
        lda fat_begin_lba+1
        adc tmp32+1
        sta wanted_lba+1
        lda fat_begin_lba+2
        adc tmp32+2
        sta wanted_lba+2
        lda fat_begin_lba+3
        adc tmp32+3
        sta wanted_lba+3

        ; cached?
        lda wanted_lba+0
        cmp fat_cache_lba+0
        bne .reload
        lda wanted_lba+1
        cmp fat_cache_lba+1
        bne .reload
        lda wanted_lba+2
        cmp fat_cache_lba+2
        bne .reload
        lda wanted_lba+3
        cmp fat_cache_lba+3
        beq .cached
.reload:
        lda wanted_lba+0
        sta sd_lba+0
        lda wanted_lba+1
        sta sd_lba+1
        lda wanted_lba+2
        sta sd_lba+2
        lda wanted_lba+3
        sta sd_lba+3
        lda #<fat_buf
        sta ZP_PTR2
        lda #>fat_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcs .eoc                 ; read error -> treat as end of chain
        lda wanted_lba+0
        sta fat_cache_lba+0
        lda wanted_lba+1
        sta fat_cache_lba+1
        lda wanted_lba+2
        sta fat_cache_lba+2
        lda wanted_lba+3
        sta fat_cache_lba+3
.cached:
        ; entry offset within the sector = (cur_clus & $7F) * 4
        lda cur_clus+0
        and #$7F
        sta mtmp+0
        lda #0
        sta mtmp+1
        asl mtmp+0
        rol mtmp+1
        asl mtmp+0
        rol mtmp+1               ; mtmp = offset (0..508)
        clc
        lda #<fat_buf
        adc mtmp+0
        sta ZP_PTR2
        lda #>fat_buf
        adc mtmp+1
        sta ZP_PTR2+1
        ; read 4-byte FAT32 entry, mask top nibble
        ldy #0
        lda (ZP_PTR2),y
        sta cur_clus+0
        iny
        lda (ZP_PTR2),y
        sta cur_clus+1
        iny
        lda (ZP_PTR2),y
        sta cur_clus+2
        iny
        lda (ZP_PTR2),y
        and #$0F
        sta cur_clus+3
        ; end of chain? cur_clus >= $0FFFFFF8
        lda cur_clus+3
        cmp #$0F
        bne .not_eoc
        lda cur_clus+2
        cmp #$FF
        bne .not_eoc
        lda cur_clus+1
        cmp #$FF
        bne .not_eoc
        lda cur_clus+0
        cmp #$F8
        bcc .not_eoc
.eoc:
        sec
        rts
.not_eoc:
        clc
        rts

; =============================================================================
; fat_find: locate an 8.3 file in the ROOT directory.
; Input: ZP_PTR -> 11-byte space-padded uppercase name, such as "IMAGE   BIN".
; On success (carry clear): file_first_clus + file_size set.
; On failure (carry set): sd_last_err = SDERR_FIND.
; =============================================================================
!zone fat_find
fat_find:
        ldy #10
.cpname:
        lda (ZP_PTR),y
        sta search_name,y
        dey
        bpl .cpname

        lda root_clus+0
        sta cur_clus+0
        lda root_clus+1
        sta cur_clus+1
        lda root_clus+2
        sta cur_clus+2
        lda root_clus+3
        sta cur_clus+3
.clus_loop:
        jsr clus_to_lba
        lda secs_per_clus
        sta sects_left
.sect_loop:
        lda cur_lba+0
        sta sd_lba+0
        lda cur_lba+1
        sta sd_lba+1
        lda cur_lba+2
        sta sd_lba+2
        lda cur_lba+3
        sta sd_lba+3
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rdok
        jmp .err
.rdok:
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        ldx #16                  ; 16 dir entries per 512-byte sector
.entry_loop:
        ldy #0
        lda (ZP_PTR2),y
        bne .not_di_end
        jmp .notfound            ; $00 first byte = end of directory
.not_di_end:
        cmp #$E5
        beq .next_entry          ; deleted
        ldy #$0B
        lda (ZP_PTR2),y          ; attribute byte
        cmp #$0F
        beq .next_entry          ; long-filename entry
        and #$08
        bne .next_entry          ; volume label
        ; compare 11 name bytes
        ldy #10
.cmp:
        lda (ZP_PTR2),y
        cmp search_name,y
        bne .next_entry
        dey
        bpl .cmp
        ; MATCH: first cluster hi @ $14, lo @ $1A, size @ $1C (4 LE)
        ldy #$14
        lda (ZP_PTR2),y
        sta file_first_clus+2
        iny
        lda (ZP_PTR2),y
        sta file_first_clus+3
        ldy #$1A
        lda (ZP_PTR2),y
        sta file_first_clus+0
        iny
        lda (ZP_PTR2),y
        sta file_first_clus+1
        ldy #$1C
        lda (ZP_PTR2),y
        sta file_size+0
        iny
        lda (ZP_PTR2),y
        sta file_size+1
        iny
        lda (ZP_PTR2),y
        sta file_size+2
        iny
        lda (ZP_PTR2),y
        sta file_size+3
        clc
        rts
.next_entry:
        clc
        lda ZP_PTR2
        adc #32
        sta ZP_PTR2
        bcc .noc
        inc ZP_PTR2+1
.noc:
        dex
        beq .sector_done
        jmp .entry_loop
.sector_done:
        ; next sector within this cluster
        inc cur_lba+0
        bne .sdec
        inc cur_lba+1
        bne .sdec
        inc cur_lba+2
        bne .sdec
        inc cur_lba+3
.sdec:
        dec sects_left
        beq .cluster_done
        jmp .sect_loop
.cluster_done:
        ; next cluster in the root's chain
        jsr fat_next_cluster
        bcs .notfound
        jmp .clus_loop
.notfound:
        lda #SDERR_FIND
        sta sd_last_err
.err:
        sec
        rts

; =============================================================================
; fat_open: reset the streaming reader for the file found by fat_find.
; =============================================================================
!zone fat_open
fat_open:
        lda file_first_clus+0
        sta cur_clus+0
        lda file_first_clus+1
        sta cur_clus+1
        lda file_first_clus+2
        sta cur_clus+2
        lda file_first_clus+3
        sta cur_clus+3
        lda file_size+0
        sta bytes_left+0
        lda file_size+1
        sta bytes_left+1
        lda file_size+2
        sta bytes_left+2
        lda file_size+3
        sta bytes_left+3
        lda #1
        sta need_first
        lda #0
        sta sects_left
        rts

; =============================================================================
; fat_read_next_sector: read the file's next data sector into sd_buf.
; Carry set = no more data (EOF or end of chain). On carry clear, this_len
; (16-bit) = valid bytes in sd_buf (1..512), and bytes_left is decremented.
; =============================================================================
!zone fat_read_next_sector
fat_read_next_sector:
        lda bytes_left+0
        ora bytes_left+1
        ora bytes_left+2
        ora bytes_left+3
        bne .havebytes
        sec                      ; EOF
        rts
.havebytes:
        lda sects_left
        bne .read
        ; need a new cluster
        lda need_first
        beq .advance
        lda #0
        sta need_first
        jmp .setclus
.advance:
        jsr fat_next_cluster
        bcc .setclus
        jmp .eof
.setclus:
        jsr clus_to_lba
        lda secs_per_clus
        sta sects_left
.read:
        lda cur_lba+0
        sta sd_lba+0
        lda cur_lba+1
        sta sd_lba+1
        lda cur_lba+2
        sta sd_lba+2
        lda cur_lba+3
        sta sd_lba+3
        ; track_only: skip the actual sector read. Used by the fast streaming
        ; loaders (fat_load_vram / fat_load_ram) which call sd_read_block_vram
        ; or sd_read_block_ram themselves with the sd_lba we just published.
        ; The LBA tracking and bytes_left accounting below still happen, so a
        ; track_only caller can read every sector the chain walks past.
        lda fat_track_only
        bne .skip_read
        lda #<sd_buf
        sta ZP_PTR2
        lda #>sd_buf
        sta ZP_PTR2+1
        jsr sd_read_block
        bcc .rdok
        jmp .eof
.skip_read:
        clc
.rdok:
        ; advance cur_lba, dec sects_left
        inc cur_lba+0
        bne .a1
        inc cur_lba+1
        bne .a1
        inc cur_lba+2
        bne .a1
        inc cur_lba+3
.a1:
        dec sects_left

        ; this_len = min(512, bytes_left), then bytes_left -= this_len
        lda bytes_left+3
        ora bytes_left+2
        bne .full
        lda bytes_left+1
        cmp #$02
        bcc .partial             ; hi byte < 2 -> < 512
        bne .full                ; hi byte > 2 -> > 512
        ; hi byte == 2 -> >= 512 -> full
.full:
        lda #<512
        sta this_len+0
        lda #>512
        sta this_len+1
        sec
        lda bytes_left+0
        sbc #<512
        sta bytes_left+0
        lda bytes_left+1
        sbc #>512
        sta bytes_left+1
        lda bytes_left+2
        sbc #0
        sta bytes_left+2
        lda bytes_left+3
        sbc #0
        sta bytes_left+3
        clc
        rts
.partial:
        lda bytes_left+0
        sta this_len+0
        lda bytes_left+1
        sta this_len+1
        lda #0
        sta bytes_left+0
        sta bytes_left+1
        sta bytes_left+2
        sta bytes_left+3
        clc
        rts
.eof:
        sec
        rts

; =============================================================================
