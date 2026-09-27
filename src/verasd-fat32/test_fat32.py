"""Run the actual assembled FAT32 client against SD SPI sector fixtures."""
import importlib.util
import json
from pathlib import Path
from collections import deque
ROOT=Path(__file__).resolve().parent
from sd_spi_model import CardMemory,MPU
spec=importlib.util.spec_from_file_location('fixture',ROOT/'fat32-fixture.py')
fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
LABELS=json.loads((ROOT/'fat32.labels.json').read_text())
CODE=(ROOT/'fat32.bin').read_bytes()

class FatCard(CardMemory):
    def __init__(self,partition=0,byte_mode=False,spc=1,**kwargs):
        super().__init__(byte_mode=byte_mode,**kwargs)
        self.ram[0x2000:0x2000+len(CODE)]=CODE
        self.blocks=fixture.fixture(partition,spc)
        self.ram[LABELS['slot_page']]=0xc2
        self.ram[LABELS['address_mode']]=0x40 if byte_mode else 0
        self.output=[]
        self.keys=deque()
    def __getitem__(self,addr):
        if addr==0xc000:return (self.keys[0]|128) if self.keys else 0
        if addr==0xc010:
            if self.keys:self.keys.popleft()
            return 0
        return super().__getitem__(addr)
    def transfer(self,value):
        if len(self.rx)==5 and (self.rx[0]&63) not in (17,24):
            cmd=self.rx[0]&63;arg=int.from_bytes(bytes(self.rx[1:5]),'big')
            self.rx=[];self.frames.append((cmd,arg));self.reply.extend([255,255])
            if cmd==0:self.reply.append(1)
            elif cmd==8:self.reply.extend([1,0,0,1,170])
            elif cmd==55:self.reply.append(1)
            elif cmd==41:self.reply.append(0)
            elif cmd==58:self.reply.extend([0,0x80 if self.byte_mode else 0xc0,255,128,0])
            elif cmd==16:self.reply.append(0)
            else:raise AssertionError(cmd)
            return 255
        return super().transfer(value)

def number(card,label,value=None):
    addr=LABELS[label]
    if value is not None:card.ram[addr:addr+4]=value.to_bytes(4,'little')
    return int.from_bytes(bytes(card.ram[addr:addr+4]),'little')

def call(card,name,a=0,x=0,limit=4000000):
    cpu=MPU(memory=card);cpu.pc=LABELS[name];cpu.sp=0xfd;cpu.a=a;cpu.x=x
    card.ram[0x1fe:0x200]=[255,127]
    for _ in range(limit):
        if cpu.pc==0x8000:return cpu
        if cpu.pc in (0xfded,0xfdda,0xfc58):
            if cpu.pc==0xfded:card.output.append(chr(cpu.a&127))
            if cpu.pc==0xfdda:card.output.append(f'{cpu.a:02X}')
            card.ram[0x34:0x36]=[18,4];cpu.x=99;cpu.y=33
            cpu.pc=(cpu.stPopWord()+1)&65535
        else:cpu.step()
    raise AssertionError(f'{name} did not return, pc={cpu.pc:04x}')

def find(card,name):
    card.ram[0x1800:0x180b]=name
    card.ram[6:8]=[0,24]
    return call(card,'find_named')

def main():
    count=0
    for partition,byte_mode,spc in [(0,False,1),(2048,False,1),(0,True,1),(0,False,2)]:
        card=FatCard(partition,byte_mode,spc)
        assert not call(card,'mount').p&1,card.ram[LABELS['sd_last_err']]
        assert number(card,'total_sectors')==fixture.TOTAL
        assert not call(card,'catalog').p&1
        assert 'HIGH    BIN' in ''.join(card.output)
        assert not find(card,b'HIGH    BIN').p&1
        assert number(card,'file_size')==1024
        call(card,'chain_reset');call(card,'fat_open')
        data=bytearray()
        while number(card,'bytes_left'):
            assert not call(card,'fat_read_next_sector').p&1
            addr=LABELS['sd_buf'];size=number(card,'this_len')&65535
            data+=bytes(card.ram[addr:addr+size])
        assert data==fixture.PATTERN
        assert any(c==17 and (arg//512 if byte_mode else arg)>65535 for c,arg in card.frames)
        count+=1
        assert not find(card,b'TESTNOW BIN').p&1
        assert not call(card,'write_test').p&1
        writes=[arg//512 if byte_mode else arg for cmd,arg in card.frames if cmd==24]
        assert len(writes)==2 and all(b>65535 for b in writes)
        assert b''.join(card.blocks[b] for b in writes)==fixture.PATTERN
        count+=1
    for offset,value in [(11,1),(12,4),(13,0),(13,3),(16,0),(16,3),(17,1),(22,1),(42,1)]:
        card=FatCard();b=bytearray(card.blocks[0]);b[offset]=value;card.blocks[0]=bytes(b)
        assert call(card,'mount').p&1,(offset,value)
        count+=1
    card=FatCard();assert not call(card,'mount').p&1
    number(card,'sd_lba',fixture.TOTAL)
    card.frames.clear();assert call(card,'read_sd_buf').p&1 and not card.frames
    count+=1
    card=FatCard();card.keys.extend(b'CRHIGH.BIN\rWY RTESTNOW.BIN\rQ'.replace(b' ',b''))
    assert not call(card,'start').p&1
    output=''.join(card.output)
    assert 'HIGH    BIN' in output and 'WRITE OK' in output and output.count('SUM16 $FE00')==2,output
    count+=1
    # Bad chains must fail promptly rather than loop or claim an early EOF.
    for nxt in (70000,0,1,0x0ffffff7,0x0fffffff):
        card=FatCard();assert not call(card,'mount').p&1
        assert not find(card,b'HIGH    BIN').p&1
        lba=32+70000//128;b=bytearray(card.blocks[lba]);b[(70000%128)*4:(70000%128)*4+4]=nxt.to_bytes(4,'little');card.blocks[lba]=bytes(b)
        assert call(card,'read_file',limit=500000).p&1,nxt
        count+=1
    card=FatCard();assert not call(card,'mount').p&1
    assert not find(card,b'TESTNOW BIN').p&1
    card.reject=True;assert call(card,'write_test').p&1
    assert card.blocks[94126]==bytes(512)
    count+=1
    print(f'PASS: {count} FAT32 assembled-client cases (raw/MBR, SDHC/SDSC, fragmented high-LBA read/write, invalid BPB, bounds)')

if __name__=='__main__':main()
