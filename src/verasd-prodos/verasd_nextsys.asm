; One-shot SYS handoff helper. Copied to $1000 after the VERA driver is
; installed, so it never becomes part of the resident driver. It scans the
; boot volume directory for the first .SYSTEM entry after VERASD.SYSTEM.
;
; Entry unit is saved by verasd_sys.asm at $1FF0. The helper uses $1800 as
; a ProDOS block/file buffer and loads the next SYS at $2000.

MLI             = $BF00
BOOT_UNIT       = $1FF0
BLOCKBUF        = $1800
SYS_LOAD        = $2000
PATHBUF         = $0280

zp_ptr          = $A5
zp_entry        = $A7
zp_block        = $A9
zp_seen_self    = $AB
zp_refnum       = $AC
zp_count        = $AD
; Keep these outside BLOCKBUF ($1800-$19FF); storing the volume name at
; $1900 used to overwrite later directory entries before the scan reached them.
VOLNAME         = $1A00
VOLLEN          = $1A10

nextsys_start:
        lda #2
        sta zp_block
        lda #0
        sta zp_block+1
        lda #0
        sta zp_seen_self

scan_block:
        lda #3
        sta rb_params
        lda BOOT_UNIT
        sta rb_params+1
        lda #<BLOCKBUF
        sta rb_params+2
        lda #>BLOCKBUF
        sta rb_params+3
        lda zp_block
        sta rb_params+4
        lda zp_block+1
        sta rb_params+5
        jsr MLI
        !byte $80
        !word rb_params
        bcc block_read_ok
        jmp no_next
block_read_ok:

        ; Save the volume name from block 2 before scanning later blocks.
        lda zp_block
        cmp #2
        bne volume_saved
        lda BLOCKBUF+4
        and #$0F
        sta VOLLEN
        ldy #0
save_volume_name:
        cpy VOLLEN
        beq volume_saved
        lda BLOCKBUF+5,Y
        and #$7F
        sta VOLNAME,Y
        iny
        bne save_volume_name
volume_saved:

        ; Entries begin at $2B in the volume directory's first block,
        ; and at $04 in continuation blocks.
        lda zp_block
        cmp #2
        bne scan_first_entry
        lda #$2B
        sta zp_entry
        lda #>BLOCKBUF
        sta zp_entry+1
        lda #12
        sta zp_count
        jmp scan_entry
scan_first_entry:
        lda #4
set_entry:
        sta zp_entry
        lda #>BLOCKBUF
        sta zp_entry+1
        lda #13
        sta zp_count

scan_entry:
        ldy #0
        lda (zp_entry),Y
        beq skip_entry
        and #$F0
        cmp #$10                 ; seedling, sapling, or tree file
        beq storage_ok
        cmp #$20
        beq storage_ok
        cmp #$30
        bne skip_entry
storage_ok:
        ldy #$10
        lda (zp_entry),Y
        cmp #$FF                 ; SYS file type
        bne skip_entry
        jsr is_system_name
        bcc skip_entry
        lda zp_seen_self
        bne found_next
        jsr is_verasd_name
        bcc skip_entry
        lda #1
        sta zp_seen_self
skip_entry:
        jmp advance_entry

found_next:
        ; Save the target's EOF before OPEN reuses BLOCKBUF as its I/O buffer.
        ldy #$15
        lda (zp_entry),Y
        sta read_params+4
        iny
        lda (zp_entry),Y
        sta read_params+5
        jsr build_path
        bcc path_ok
        jmp no_next
path_ok:
        lda #3
        sta open_params
        lda #<PATHBUF
        sta open_params+1
        lda #>PATHBUF
        sta open_params+2
        lda #<BLOCKBUF
        sta open_params+3
        lda #>BLOCKBUF
        sta open_params+4
        jsr MLI
        !byte $C8
        !word open_params
        bcc open_ok
        jmp no_next
open_ok:
        lda open_params+5
        sta zp_refnum

        lda #4
        sta read_params
        lda zp_refnum
        sta read_params+1
        lda #<SYS_LOAD
        sta read_params+2
        lda #>SYS_LOAD
        sta read_params+3
        ; read_params+4/5 holds the EOF size saved before OPEN. A $FFFF-byte
        ; request at $2000 crosses the ProDOS address space and can be rejected.
        lda #0
        sta read_params+6
        sta read_params+7
        jsr MLI
        !byte $CA
        !word read_params
        php
        lda #1
        sta close_params
        lda zp_refnum
        sta close_params+1
        jsr MLI
        !byte $CC
        !word close_params
        plp
        bcc read_ok
        jmp no_next
read_ok:
        jmp SYS_LOAD

advance_entry:
        clc
        lda zp_entry
        adc #39
        sta zp_entry
        bcc entry_no_carry
        inc zp_entry+1
entry_no_carry:
        dec zp_count
        beq entries_done
        jmp scan_entry
entries_done:

        ; Follow the directory's forward link (block bytes 2-3).
        lda BLOCKBUF+2
        sta zp_block
        lda BLOCKBUF+3
        sta zp_block+1
        ora zp_block
        beq no_next
        jmp scan_block
        ; No later .SYSTEM: fall back to ProDOS/launcher QUIT.
no_next:
        lda #4
        sta quit_params
        lda #0
        ldx #1
clear_quit:
        sta quit_params,X
        inx
        cpx #5
        bne clear_quit
        jsr MLI
        !byte $65
        !word quit_params
quit_hung:
        jmp quit_hung

; Carry set if the current directory entry has a name ending in .SYSTEM.
is_system_name:
        ldy #0
        lda (zp_entry),Y
        and #$0F
        cmp #7
        bcc isn_no
        ; suffix offset = name length - 7; filename bytes begin at +1
        sec
        sbc #6
        tay
        lda (zp_entry),Y
        and #$7F
        cmp #$2E
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$53
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$59
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$53
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$54
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$45
        bne isn_no
        iny
        lda (zp_entry),Y
        and #$7F
        cmp #$4D
        bne isn_no
        sec
        rts
isn_no:
        clc
        rts

; Carry set only for the exact VERASD.SYSTEM filename.
is_verasd_name:
        ldy #0
        lda (zp_entry),Y
        and #$0F
        cmp #13
        bne ivn_no
        ldy #1
        ldx #0
ivn_loop:
        lda (zp_entry),Y
        and #$7F
        cmp self_name,X
        bne ivn_no
        iny
        inx
        cpx #13
        bne ivn_loop
        sec
        rts
ivn_no:
        clc
        rts

; Build /VOLUME/filename in ProDOS's global path buffer. The root volume
; name is in the volume header entry at BLOCKBUF+5; target name is entry+1.
build_path:
        lda #$2F
        sta PATHBUF+1
        lda VOLLEN
        sta zp_count
        ldy #0
        ldx #2
bp_vol:
        cpy zp_count
        beq bp_slash
        lda VOLNAME,Y
        sta PATHBUF,X
        iny
        inx
        bne bp_vol
bp_slash:
        lda #$2F
        sta PATHBUF,X
        inx
        ldy #0
        lda (zp_entry),Y
        and #$0F
        sta zp_count
        ldy #1
bp_name:
        lda (zp_entry),Y
        and #$7F
        sta PATHBUF,X
        iny
        inx
        dec zp_count
        bne bp_name
bp_end:
        dex
        stx PATHBUF
        clc
        rts

self_name: HEX 56 45 52 41 53 44 2E 53 59 53 54 45 4D
rb_params: !byte 3,0,0,0,0,0
open_params: !byte 3,0,0,0,0,0
read_params: !byte 4,0,0,0,0,0,0,0
close_params: !byte 1,0
quit_params: !byte 4,0,0,0,0
