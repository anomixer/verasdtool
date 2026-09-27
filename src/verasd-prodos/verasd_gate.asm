; Common language-card bridge, assembled at $FF00. Replaces the native /RAM
; driver after removing that device. $FF9B-$FFFF interrupt code stays intact.
start:
        php
        sei
        lda $C083
        lda $C083
        jsr $D400
        php
        pha
        txa
        pha
        tya
        pha
        tsx
        lda $0105,X
        and #$04
        beq caller_irq_on
        lda $0104,X
        ora #$04
        bne gate_flags_ready
caller_irq_on:
        lda $0104,X
        and #$FB
gate_flags_ready:
        sta $0105,X
        lda $C08B
        lda $C08B
        pla
        tay
        pla
        tax
        pla
        plp
        plp
        rts

; Driver body executes in bank 2. ProDOS buffers in $D000-$DFFF are in bank 1.
; All accesses to the caller's buffer pass through these common-RAM routines.
load_buffer:
        lda $C08B
        lda (zp_buf),Y
        pha
        lda $C083
        pla
        rts
store_buffer:
        pha
        lda $C08B
        pla
        sta (zp_buf),Y
        lda $C083
        rts
no_device:
        lda #$28
        sec
        rts
zp_buf = $30
