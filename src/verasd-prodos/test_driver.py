"""Execute the assembled 6502 driver against an SPI card, including fault cases.
Requires: pip install py65. Build first with node verasd.mjs.
"""
import json
from collections import deque
from pathlib import Path
from py65.devices.mpu6502 import MPU

ROOT = Path(__file__).resolve().parent
LABELS = json.loads((ROOT / 'verasd_drv.labels.json').read_text())
CODE = (ROOT / 'verasd_drv.bin').read_bytes()

class CardMemory:
    def __init__(self, byte_mode=False, r1=0, token_delay=0, reject=False, stuck=False, busy_stuck=False):
        self.ram = [0] * 65536
        self.ram[0xD400:0xD400 + len(CODE)] = CODE
        gate = (ROOT / "verasd_gate.bin").read_bytes()
        self.ram[0xFF00:0xFF00 + len(gate)] = gate
        self.bank1 = [0] * 4096
        self.lc_bank = 1
        self.selected = False
        self.rx = []
        self.reply = deque()
        self.received = 255
        self.frames = []
        self.blocks = {2: bytes(range(256)) * 2}
        self.write_packet = None
        self.write_block = None
        self.byte_mode = byte_mode
        self.r1 = r1
        self.token_delay = token_delay
        self.reject = reject
        self.stuck = stuck
        self.busy_stuck = busy_stuck
        self.programming = False
        self.sent = []
    def __getitem__(self, addr):
        if isinstance(addr, slice): return self.ram[addr]
        if addr == 0xC083: self.lc_bank = 2; return 0
        if addr in (0xC08B, 0xC082): self.lc_bank = 1; return 0
        if 0xD000 <= addr < 0xE000 and self.lc_bank == 1: return self.bank1[addr - 0xD000]
        if addr == 0xC21F: return 128 if self.stuck else (3 if self.selected else 2)
        if addr == 0xC21E: return self.received
        return self.ram[addr]
    def __setitem__(self, addr, value):
        if isinstance(addr, slice): self.ram[addr] = value; return
        if 0xD000 <= addr < 0xE000 and self.lc_bank == 1:
            self.bank1[addr - 0xD000] = value
        elif addr == 0xC21F:
            self.selected = bool(value & 1)
            if not self.selected: self.rx=[];self.reply.clear();self.programming=False
        elif addr == 0xC21E:
            self.sent.append(value)
            self.received = self.transfer(value) if self.selected else 255
        else: self.ram[addr] = value
    def transfer(self, value):
        if self.write_packet is not None:
            self.write_packet.append(value)
            if len(self.write_packet) == 515:
                assert self.write_packet[0] == 254
                if not self.reject: self.blocks[self.write_block] = bytes(self.write_packet[1:513])
                self.write_packet=None
                self.reply.extend([255, 13 if self.reject else 5, 0, 0] + ([] if self.busy_stuck else [255]))
                self.programming=True
            return 255
        if self.reply and value == 255:
            return self.reply.popleft()
        if self.programming and self.busy_stuck: return 0
        if not self.rx and value == 255: return 255
        self.rx.append(value)
        if len(self.rx) == 6:
            cmd=self.rx[0]&63;arg=int.from_bytes(bytes(self.rx[1:5]),'big')
            self.frames.append((cmd,arg));self.rx=[]
            self.reply.extend([255,255,self.r1])
            block=arg//512 if self.byte_mode else arg
            if cmd == 17 and self.r1 == 0:
                self.reply.extend([255]*self.token_delay+[254]+list(self.blocks.get(block,bytes(512)))+[18,52])
            elif cmd == 24 and self.r1 == 0:
                self.write_block=block
                # Start the write packet only after R1 and optional dummy clocks.
                self.pending_write=True
            return 255
        return 255

# Write token is special: preceding FF bytes must not become packet data.
_original_transfer=CardMemory.transfer
def transfer_with_token(self,value):
    if getattr(self,'pending_write',False) and not self.reply and value == 254:
        self.pending_write=False;self.write_packet=[254];return 255
    return _original_transfer(self,value)
CardMemory.transfer=transfer_with_token

def run(card, command=1, block=2, buffer=0x60A7, unit=0x20, flags=0x28, blocks=8192):
    cpu=MPU(memory=card)
    for i in range(0x28,0x40): card.ram[i]=(i*7)&255
    before=card.ram[0x28:0x40].copy()
    card.ram[0x42:0x48]=[command,unit,buffer&255,buffer>>8,block&255,block>>8]
    card.ram[LABELS['blocks_lo']]=blocks&255
    card.ram[LABELS['blocks_hi']]=blocks>>8
    card.ram[LABELS['byte_addressed']]=int(card.byte_mode)
    cpu.p=flags;cpu.sp=0xFD
    card.ram[0x1FE]=0xFF;card.ram[0x1FF]=0x7F
    cpu.pc=0xFF00
    for _ in range(5_000_000):
        cpu.step()
        if cpu.pc == 0x8000: break
    else: raise AssertionError('driver did not return')
    assert card.ram[0x28:0x40] == before, 'zero page damaged'
    assert cpu.p&0x0C == flags&0x0C, 'interrupt/decimal state damaged'
    assert cpu.sp == 0xFF, 'stack unbalanced'
    assert not card.selected, 'card left selected'
    assert card.lc_bank == 1, 'language-card bank not restored'
    return cpu

def main():
    count=0
    for byte_mode in (False,True):
        card=CardMemory(byte_mode=byte_mode,token_delay=4)
        cpu=run(card)
        assert cpu.a == 0 and not cpu.p&1
        assert bytes(card.ram[0x60A7:0x62A7]) == bytes(range(256))*2
        assert card.frames == [(17,1024 if byte_mode else 2)]
        count+=1
        card=CardMemory(byte_mode=byte_mode)
        pattern=bytes((i*13+255)&255 for i in range(512))
        card.ram[0x60A7:0x62A7]=pattern
        cpu=run(card,command=2,block=123)
        assert cpu.a == 0 and not cpu.p&1
        assert card.blocks[123] == pattern
        count+=1
    card=CardMemory();cpu=run(card,buffer=0xDCA7)
    assert cpu.a == 0 and bytes(card.bank1[0xCA7:0xEA7]) == bytes(range(256))*2
    count+=1
    card=CardMemory();cpu=run(card,buffer=0xCEA7)
    assert cpu.a == 0 and (bytes(card.ram[0xCEA7:0xD000]) + bytes(card.bank1[:0xA7])) == bytes(range(256))*2
    count+=1
    card=CardMemory();pattern=bytes(range(256))*2
    card.bank1[0xCA7:0xEA7]=pattern
    cpu=run(card,command=2,buffer=0xDCA7)
    assert cpu.a == 0 and card.blocks[2] == pattern
    count+=1
    for cmd,block,unit in [(3,2,32),(4,2,32),(1,8192,32),(1,2,160)]:
        card=CardMemory();cpu=run(card,command=cmd,block=block,unit=unit)
        assert cpu.p&1 and cpu.a != 0 and not card.frames
        count+=1
    card=CardMemory();cpu=run(card,command=0)
    assert cpu.a == 0 and cpu.x == 0 and cpu.y == 32
    count+=1
    for cmd in (1,2):
        card=CardMemory();cpu=run(card,command=cmd,block=65534,blocks=65535)
        assert cpu.a == 0 and not cpu.p&1 and card.frames == [(17 if cmd == 1 else 24,65534)]
        count+=1
        card=CardMemory();cpu=run(card,command=cmd,block=65535,blocks=65535)
        assert cpu.p&1 and not card.frames
        count+=1
    for options,cmd in [({'r1':4},1),({'reject':True},2),({'stuck':True},1),({'busy_stuck':True},2)]:
        card=CardMemory(**options);cpu=run(card,command=cmd)
        assert cpu.p&1 and cpu.a == 0x27
        count+=1
    print(f'PASS: {count} assembled-driver cases (SDHC/SDSC, read/write, ABI, bounds, faults)')

if __name__ == '__main__': main()
