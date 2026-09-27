"""Installer protocol tests with delayed replies and mocked ProDOS/BASIC services.
The actual ProDOS filesystem integration is separately exercised in AppleWin.
"""
from test_driver import CardMemory, MPU, ROOT

class InstallMemory(CardMemory):
    def __init__(self, legacy=False, attempts=3, missing=False):
        super().__init__()
        self.ram[0x2000:0x2000+len((ROOT/'verasd.bin').read_bytes())]=(ROOT/'verasd.bin').read_bytes()
        self.ram[0xBEFB]=0x96
        self.ram[0x74]=0x96
        self.ram[0xBF26:0xBF28]=[0,255]
        self.ram[0xBF31]=0xFF
        self.legacy=legacy
        self.attempts=attempts
        self.missing=missing
        self.ready=False
        self.blocks[2]=bytearray(512)
        self.blocks[2][4]=0xF6
        self.blocks[2][5:11]=b'VERASD'
        self.blocks[2][0x23]=39
        self.blocks[2][0x24]=13
        self.blocks[2][0x29:0x2B]=bytes([0,32])
    def __getitem__(self,addr):
        if self.missing and addr in (0xC205,0xC405): return 255
        return super().__getitem__(addr)
    def transfer(self,value):
        if self.reply and value == 255:return self.reply.popleft()
        if not self.rx and value == 255:return 255
        self.rx.append(value)
        if len(self.rx) < 6:return 255
        cmd=self.rx[0]&63;arg=int.from_bytes(bytes(self.rx[1:5]),'big')
        self.frames.append((cmd,arg));self.rx=[]
        self.reply.extend([255,255])
        if cmd == 0:self.reply.append(1)
        elif cmd == 8:self.reply.extend([5] if self.legacy else [1,0,0,1,170])
        elif cmd == 55:self.reply.append(0 if self.ready else 1)
        elif cmd == 41:
            assert arg == (0 if self.legacy else 0x40000000)
            self.attempts-=1;self.ready=self.attempts<=0
            self.reply.append(0 if self.ready else 1)
        elif cmd == 58:self.reply.extend([0,0x80 if self.legacy else 0xC0,255,128,0])
        elif cmd == 16:
            assert self.legacy and arg == 512
            self.reply.append(0)
        elif cmd == 17:
            assert arg == (1024 if self.legacy else 2)
            self.reply.extend([0,255,254]+list(self.blocks[2])+[255,255])
        else:raise AssertionError(f'unexpected CMD{cmd}')
        return 255

def install(card, mli_error=0):
    cpu=MPU(memory=card);cpu.pc=0x2000;cpu.sp=0xFD;cpu.p=0x28
    card.ram[0x1FE:0x200]=[255,127]
    for i in range(0x25,0x48):card.ram[i]=(i*11)&255
    before=card.ram[0x25:0x48].copy()
    output=[];allocated=False
    for _ in range(2_000_000):
        if cpu.pc == 0xBEF5:
            assert cpu.a == 10
            cpu.a=0x90;cpu.p &= ~1;allocated=True
            cpu.pc=(cpu.stPopWord()+1)&65535
        elif cpu.pc == 0xBEF8:
            allocated=False;cpu.pc=(cpu.stPopWord()+1)&65535
        elif cpu.pc == 0xBF00:
            assert card.ram[0xBF31] == 0
            assert card.ram[0xBF32] == 0x20
            assert card.ram[0xBF14:0xBF16] == [0,0xFF]
            ret=cpu.stPopWord()+1
            assert card.ram[ret] == 0xC5
            cpu.a=mli_error
            cpu.p=(cpu.p|1) if mli_error else (cpu.p&~1)
            cpu.pc=ret+3
        elif cpu.pc == 0xFDED:
            output.append(chr(cpu.a&127))
            card.ram[0x34:0x36]=[18,4] # monitor scratch clobber
            cpu.x=99;cpu.y=33
            cpu.pc=(cpu.stPopWord()+1)&65535
        elif cpu.pc == 0x8000:break
        else:cpu.step()
    else:raise AssertionError('installer did not return')
    assert cpu.sp == 255 and cpu.p&12 == 8
    # COUT intentionally updates monitor scratch after the installer restores ZP.
    assert card.ram[0x25:0x34] == before[:15]
    assert card.ram[0x36:0x48] == before[17:]
    return ''.join(output),card.ram[0xBF14:0xBF16] == [0,0xFF]

for legacy in (False,True):
    card=InstallMemory(legacy=legacy)
    output,allocated=install(card)
    assert output == 'VERASD INSTALLED\r' and allocated
    assert card.ram[0xBEFB] == 0x96
    assert card.ram[0xBF6A] == 0 and card.ram[0xBF6B] == 0
for card,error in [(InstallMemory(missing=True),0),(InstallMemory(),0x27)]:
    output,allocated=install(card,error)
    assert not allocated
    assert card.ram[0xBF31] == 255
    assert card.ram[0xBF6A] == 0 and card.ram[0xBF6B] == 0
    assert card.ram[0xBEFB] == 0x96
print('PASS: 4 installer cases (SDHC/SDSC delayed init, missing VERA, registration rollback)')

card=InstallMemory();card.ram[0xBF26:0xBF28]=[0,0xA0]
output,allocated=install(card)
assert output == 'VERASD FAILED\r' and not allocated
assert card.ram[0xBF26:0xBF28] == [0,0xA0] and not card.frames
print('PASS: third-party RAM driver refused without altering its vector')
