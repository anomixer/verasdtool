"""Independent read-only verification using pyfatfs, not the 6502 engine."""
from pathlib import Path
from pyfatfs.PyFat import PyFat

path=Path(__file__).resolve().parents[2]/'VeraSD-IFS-FAT32.img'
fat=PyFat()
fat.open(str(path),read_only=True)
try:
    for name in ('HIGH.BIN','TESTNOW.BIN'):
        entry=fat.root_dir.get_entry(name)
        data=b''.join(fat.read_cluster_contents(c) for c in fat.get_cluster_chain(entry.get_cluster()))
        data=data[:entry.filesize]
        assert data==bytes(range(256))*4,name
        print(f'PASS: independent FAT32 extraction of {name}, {len(data)} bytes')
    with path.open('rb') as image:
        image.seek(32*512);first=image.read(2048*512)
        second=image.read(2048*512)
        assert first==second,'FAT mirrors differ'
    print('PASS: both FAT copies remain identical')
finally:
    fat.close()
