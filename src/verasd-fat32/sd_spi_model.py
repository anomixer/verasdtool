"""SPI SD-card model used to run the assembled FAT32 client under py65."""
from collections import deque
from py65.devices.mpu6502 import MPU

class CardMemory:
    def __init__(self,byte_mode=False,r1=0,token_delay=0,reject=False,stuck=False,busy_stuck=False):
        self.ram=[0]*65536;self.selected=False;self.rx=[];self.reply=deque()
        self.received=255;self.frames=[];self.blocks={};self.write_packet=None
        self.write_block=None;self.byte_mode=byte_mode;self.r1=r1
        self.token_delay=token_delay;self.reject=reject;self.stuck=stuck
        self.busy_stuck=busy_stuck;self.programming=False;self.sent=[]
    def __getitem__(self,addr):
        if isinstance(addr,slice):return self.ram[addr]
        if addr==0xC21F:return 128 if self.stuck else (3 if self.selected else 2)
        if addr==0xC21E:return self.received
        return self.ram[addr]
    def __setitem__(self,addr,value):
        if isinstance(addr,slice):self.ram[addr]=value;return
        if addr==0xC21F:
            self.selected=bool(value&1)
            if not self.selected:self.rx=[];self.reply.clear();self.programming=False
        elif addr==0xC21E:
            self.sent.append(value)
            self.received=self.transfer(value) if self.selected else 255
        else:self.ram[addr]=value
    def transfer(self,value):
        if self.write_packet is not None:
            self.write_packet.append(value)
            if len(self.write_packet)==515:
                assert self.write_packet[0]==254
                if not self.reject:self.blocks[self.write_block]=bytes(self.write_packet[1:513])
                self.write_packet=None
                self.reply.extend([255,13 if self.reject else 5,0,0]+([] if self.busy_stuck else [255]))
                self.programming=True
            return 255
        if getattr(self,'pending_write',False) and not self.reply and value==254:
            self.pending_write=False;self.write_packet=[254];return 255
        if self.reply and value==255:return self.reply.popleft()
        if self.programming and self.busy_stuck:return 0
        if not self.rx and value==255:return 255
        self.rx.append(value)
        if len(self.rx)==6:
            cmd=self.rx[0]&63;arg=int.from_bytes(bytes(self.rx[1:5]),'big')
            self.frames.append((cmd,arg));self.rx=[];self.reply.extend([255,255,self.r1])
            block=arg//512 if self.byte_mode else arg
            if cmd==17 and self.r1==0:
                self.reply.extend([255]*self.token_delay+[254]+list(self.blocks.get(block,bytes(512)))+[18,52])
            elif cmd==24 and self.r1==0:
                self.write_block=block;self.pending_write=True
        return 255
