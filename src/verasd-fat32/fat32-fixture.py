"""Create disposable 128-MiB FAT32 fixtures, without touching user images."""
from pathlib import Path
import struct
ROOT=Path(__file__).resolve().parents[2]
TOTAL=262144
RESERVED=32
FAT_SIZE=2048
DATA=RESERVED+2*FAT_SIZE
CLUSTERS=TOTAL-DATA
PATTERN=bytes(range(256))*4

def fixture(partition=0, spc=1):
    sectors={}
    b=bytearray(512);b[:3]=b'\xeb\x58\x90';b[3:11]=b'VERASD  '
    struct.pack_into('<HBHBHHBHHHII',b,11,512,spc,RESERVED,2,0,0,0xF8,0,63,255,partition,TOTAL)
    struct.pack_into('<IHHIHH',b,36,FAT_SIZE,0,0,2,1,6)
    b[64]=0x80;b[66]=0x29;struct.pack_into('<I',b,67,0x56455241)
    b[71:82]=b'VERAFAT32  ';b[82:90]=b'FAT32   ';b[510:]=b'\x55\xaa'
    sectors[partition]=bytes(b);sectors[partition+6]=bytes(b)
    allocated={2:0x0fffffff,3:0x0fffffff,70000:70005,70005:0x0fffffff,90000:90005,90005:0x0fffffff}
    if spc!=1:
        allocated={2:0x0fffffff,3:0x0fffffff,35000:0x0fffffff,45000:0x0fffffff}
    info=bytearray(512);struct.pack_into('<I',info,0,0x41615252);struct.pack_into('<III',info,484,0x61417272,CLUSTERS//spc-len(allocated),4);struct.pack_into('<I',info,508,0xaa550000)
    sectors[partition+1]=bytes(info);sectors[partition+7]=bytes(info)
    for c,nxt in {0:0x0ffffff8,1:0xffffffff,**allocated}.items():
        for copy in (0,1):
            lba=partition+RESERVED+copy*FAT_SIZE+c//128
            block=bytearray(sectors.get(lba,bytes(512)))
            struct.pack_into('<I',block,(c%128)*4,nxt);sectors[lba]=bytes(block)
    directory=bytearray(512)
    high=70000 if spc==1 else 35000;write=90000 if spc==1 else 45000
    hello=b'Hello from VERA FAT32 beyond ProDOS volume limits!\r\n'
    for i,(name,cluster,data) in enumerate([(b'HELLO   TXT',3,hello),(b'HIGH    BIN',high,PATTERN),(b'TESTNOW BIN',write,bytes(1024))]):
        off=i*32;directory[off:off+11]=name;directory[off+11]=0x20
        struct.pack_into('<H',directory,off+20,cluster>>16);struct.pack_into('<H',directory,off+26,cluster&65535);struct.pack_into('<I',directory,off+28,len(data))
    sectors[partition+DATA]=bytes(directory)
    sectors[partition+DATA+spc]=hello.ljust(512,b'\0')
    for c,data in [(high,PATTERN[:512]),(70005 if spc==1 else high,PATTERN[512:]),(write,bytes(512)),(90005 if spc==1 else write,bytes(512))]:
        lba=partition+DATA+(c-2)*spc
        if spc!=1 and c in (high,write) and lba in sectors:lba+=1
        sectors[lba]=data
    if partition:
        m=bytearray(512);m[446]=0x80;m[450]=0x0c;struct.pack_into('<II',m,454,partition,TOTAL);m[510:]=b'\x55\xaa';sectors[0]=bytes(m)
    return sectors

def create(path,partition=0):
    if path.exists():raise FileExistsError(f'Preserving {path}; choose another disposable filename')
    with path.open('wb') as f:
        f.truncate((TOTAL+partition)*512)
        for lba,data in fixture(partition).items():f.seek(lba*512);f.write(data)
    print(f'Created {path}: 128 MiB FAT32 volume; HIGH.BIN starts beyond 32 MiB')

if __name__=='__main__':
    create(ROOT/'VeraSD-IFS-FAT32.img')
