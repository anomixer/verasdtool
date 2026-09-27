import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {assemble6502} from '../asm6502.mjs';
const dir=path.dirname(fileURLToPath(import.meta.url));
const repoRoot=path.resolve(dir,'../..');
const read=n=>fs.readFileSync(path.join(dir,n),'utf8');
// Share the tested SD protocol, without changing the ProDOS product.
let backend=read('sd-protocol.inc');
backend=backend.replace(/sd_build_lba:[\s\S]*?lba_done:\s*rts/,`sd_build_lba:
 ldx #3
raw_lba_copy:
 lda sd_lba,X
 sta raw_arg,X
 dex
 bpl raw_lba_copy
 lda address_mode
 beq raw_lba_done
 ldx #9
raw_lba_shift:
 asl raw_arg
 rol raw_arg+1
 rol raw_arg+2
 rol raw_arg+3
 dex
 bne raw_lba_shift
raw_lba_done:
 rts`);
backend=backend.replaceAll('sd_lba0','raw_arg').replaceAll('sd_lba1','raw_arg+1').replaceAll('sd_lba2','raw_arg+2').replaceAll('sd_lba3','raw_arg+3');
backend=backend.replaceAll('jsr GATE_STORE','sta (zp_buf),Y').replaceAll('jsr GATE_LOAD','lda (zp_buf),Y');
let fat=read('fat-filesystem-core.inc');
// Namespace ACME local labels and expand its allocation directives.
let zone='fat';
fat=fat.split(/\r?\n/).map(line=>{
 const m=line.match(/^!zone\s+(\w+)/);if(m){zone=m[1];return '';}
 return line.replace(/\.(\w+)/g,(_,name)=>`${zone}_${name}`);
}).join('\n');
// Use explicit long branches; this assembler has no branch relaxation.
let branchId=0;
const inverse={beq:'bne',bne:'beq',bcc:'bcs',bcs:'bcc',bmi:'bpl',bpl:'bmi',bvc:'bvs',bvs:'bvc'};
function longBranches(source){return source.split('\n').map(line=>{
 const m=line.match(/^(\s*)(beq|bne|bcc|bcs|bmi|bpl|bvc|bvs)\s+([\w]+)\s*(;.*)?$/i);
 if(!m)return line;
 const skip=`long_branch_${branchId++}`;
 return ` ${inverse[m[2].toLowerCase()]} ${skip}\n jmp ${m[3]}\n${skip}:`;
}).join('\n');}
// Distinguish FAT read errors from EOC; validate every next cluster.
fat=fat.replace(/^fat_next_cluster:$/m, 'fat_next_cluster_unchecked:');
fat=fat.replace('bcs fat_next_cluster_eoc','bcs fat_chain_io_error');
fat=fat.replace('fat_find_err:\n', 'fat_find_err:\n');
const storage=`
zp_ptr=$06
ZP_PTR=$06
ZP_PTR2=$08
zp_buf=$08
zp_spidat=$0A
zp_dsp=$0A
zp_spist=$0C
zp_dsc=$0C
zp_vera=$0E
SPI_ON=$03
SPI_OFF=$02
SDERR_FIND=5
sd_arg0: !byte 0
sd_arg1: !byte 0
sd_arg2: !byte 0
sd_arg3: !byte 0
sd_crc: !byte 0
zp_sx: !byte 0
zp_sy: !byte 0
sd_tmp0: !byte 0
sd_tmp1: !byte 0
sd_err: !byte 0
command_byte: !byte 0
address_mode: !byte 0
hcs_flag: !byte 0
init_attempts: !byte 0
busy_count: !word 0
token_count: !word 0
raw_arg: !word 0,0
`;
let fatStorage=read('fat-filesystem-data.inc');
fatStorage=fatStorage.replace(/^sd_crc:.*$/m,'');
fatStorage=fatStorage.replaceAll('!fill RB_CAP_N, 0','!fill 5, 0').replace(/!fill\s+(\d+),\s*0/g,(_,n)=>'HEX '+Array(Number(n)).fill('00').join(' '));
let source=read('fat32.asm')+'\n'+backend+'\n'+fat+'\n'+storage+'\n'+fatStorage;
source=source.replaceAll('!word 0,0','HEX 00 00 00 00');
source=source.replace(/#'(.)'/g,(_,c)=>'#'+c.charCodeAt(0));
// Expand named 32-bit primitives while keeping the source readable.
source=source.split(/\r?\n/).flatMap(line=>{
 const m=line.trim().match(/^@(copy|zero|add|sub|inc)\s+([^;]+)/);if(!m)return [line];
 const args=m[2].trim().split(/\s*,\s*/);const [a,b]=args;
 if(m[1]==='copy')return Array.from({length:4},(_,i)=>` lda ${a}+${i}\n sta ${b}+${i}`);
 if(m[1]==='zero')return [' lda #0',...Array.from({length:4},(_,i)=>` sta ${a}+${i}`)];
 if(m[1]==='inc')return [' clc',' lda '+a,' adc #1',' sta '+a,...[1,2,3].map(i=>` lda ${a}+${i}\n adc #0\n sta ${a}+${i}`)];
 return [m[1]==='add'?' clc':' sec',...[0,1,2,3].map(i=>` lda ${a}+${i}\n ${m[1]==='add'?'adc':'sbc'} ${b}+${i}\n sta ${a}+${i}`)];
}).join('\n');
source=longBranches(source);
source=source.replace(/,([xy])\b/g,(_,r)=>','+r.toUpperCase());
fs.writeFileSync(path.join(dir,'fat32.generated.asm'),source);
const labels={},bin=assemble6502(source.split('\n'),0x2000,labels);
if(0x2000+bin.length>=0x9000)throw new Error('FAT32 program exceeds memory budget');
fs.writeFileSync(path.join(dir,'fat32.bin'),bin);
fs.writeFileSync(path.join(dir,'fat32.labels.json'),JSON.stringify(labels,null,2));
// Reuse boot-file allocation only; do not build or reset the ProDOS SD image.
let diskCode=read('boot-disk-pack.mjs.inc');
const basePoPath=path.join(dir,'../../assets/ProDOS_2_4_3.po');
diskCode=diskCode.replace('"VERASD.SYSTEM"','"FAT32.SYSTEM"');
const disk=new Function('fs','basePoPath','instBytes','INST_ADDR',diskCode+'\nreturn disk;')(fs,basePoPath,bin,0x2000);
const outPo=path.join(repoRoot,'VeraSD-IFS-FAT32.po');
fs.writeFileSync(outPo,disk);
console.log(`FAT32.SYSTEM ${bin.length} bytes @ $2000; built ${outPo}`);
