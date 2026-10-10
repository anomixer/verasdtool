// verasd.mjs â€” build the VERA SD ProDOS 8 driver (P1)
// 1. Assemble the block driver (verasd_drv.asm) at $9000.
// 2. Inject its patch-point addresses + bytes into the installer.
// 3. Assemble the SYS-compatible installer (verasd_sys.asm) at $2000.
// 4. Create a raw SD image formatted as a single ProDOS volume.
// 5. Build a boot disk (PRODOS + BASIC.SYSTEM + VERASD).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assemble6502 } from "../asm6502.mjs";
import { compileApplesoftBasic } from "../applebasic.mjs";
import { setProDOSFileTimestamps } from "../prodos-timestamp.mjs";
import { setProDOSVolumeName } from "../prodos-volume-name.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const basePoPath = path.join(repoRoot, "assets", "ProDOS_2_4_3.po");
const startupBytes = compileApplesoftBasic(__dirname, path.join(__dirname, "startup.bas"));

// ------------------------------------------------------------ constants
const DRV_ADDR = 0xd400;
const INST_ADDR = 0x2000;
const SD_IMAGE_BLOCKS = 65536;
const SD_BLOCKS = 65535;       // P1: 4MB SD image (single ProDOS volume)

// ------------------------------------------------------------ assemble driver
const gateLabels = {};
const gateLines = fs.readFileSync(path.join(__dirname, "verasd_gate.asm"), "utf-8").split(/\r?\n/);
const gateBytes = assemble6502(gateLines, 0xff00, gateLabels);
if (gateBytes.length > 0x9b) throw new Error("gate overlaps ProDOS interrupt handler");
const helperEquates = [`GATE_LOAD = ${gateLabels.load_buffer}`, `GATE_STORE = ${gateLabels.store_buffer}`];
const drvLines = fs.readFileSync(path.join(__dirname, "verasd_drv.asm"), "utf-8").split(/\r?\n/);
const drvLabels = {};
const drvBytes = assemble6502([...helperEquates, ...drvLines], DRV_ADDR, drvLabels);
if (drvBytes.length > 0xc00) throw new Error("driver exceeds reserved memory");
if (drvBytes.length === 0) throw new Error("driver assembled to zero bytes");

// ------------------------------------------------------------ inject into installer
const equates = [
  `GATE_SIZE = ${gateBytes.length}`,
  `GATE_NO_DEVICE = ${gateLabels.no_device}`,
  `DRV_BLOCKS_LO = ${drvLabels["blocks_lo"]}`,
  `DRV_BLOCKS_HI = ${drvLabels["blocks_hi"]}`,
  `DRV_PART_OFF = ${drvLabels["part_offset"]}`,
  `DRV_SPI_DATA = ${drvLabels["spi_data_addr"]}`,
  `DRV_SPI_CTRL = ${drvLabels["spi_ctrl_addr"]}`,
  `DRV_BYTE_MODE = ${drvLabels["byte_addressed"]}`,
  `DRV_UNIT = ${drvLabels["unit_number"]}`,
  `DRV_SIZE = ${drvBytes.length}`,
  `DRV_PAGES = ${Math.ceil(drvBytes.length / 256)}`,
];
const hexLines = [];
for (let i = 0; i < drvBytes.length; i += 16) {
  const chunk = Array.from(drvBytes.slice(i, i + 16))
    .map((b) => b.toString(16).padStart(2, "0").toUpperCase())
    .join(" ");
  hexLines.push("HEX " + chunk);
}
const instLines = fs.readFileSync(path.join(__dirname, "verasd_sys.asm"), "utf-8").split(/\r?\n/);
const nextSysLines = fs.readFileSync(path.join(__dirname, "verasd_nextsys.asm"), "utf-8").split(/\r?\n/);
const nextSysBytes = assemble6502(nextSysLines, 0x1000);
const nextSysPages = Math.ceil(nextSysBytes.length / 256);
if (nextSysBytes.length === 0 || nextSysBytes.length >= 0x900) throw new Error("next-SYS helper overlaps its scratch data");
const nextSysPadded = new Uint8Array(nextSysPages * 256);
nextSysPadded.set(nextSysBytes);
const instFull = [
  ...equates, `NEXTSYS_PAGES = ${nextSysPages}`,
  ...instLines, ...hexLines,
  "gate_src:", ...Array.from(gateBytes, b => "!byte " + b),
  "nextsys_src:", ...Array.from(nextSysPadded, b => "!byte " + b),
];
const instLabels = {};
const instBytes = assemble6502(instFull, INST_ADDR, instLabels);
if (instBytes.length === 0) throw new Error("installer assembled to zero bytes");
const legacyLines = fs.readFileSync(path.join(__dirname, "verasd.asm"), "utf-8").split(/\r?\n/);
const legacyBytes = assemble6502([...equates, ...legacyLines, ...hexLines, "gate_src:", ...Array.from(gateBytes, b => "!byte " + b)], INST_ADDR);
if (legacyBytes.length === 0) throw new Error("legacy installer assembled to zero bytes");

// ------------------------------------------------------------ SD image (ProDOS volume)
const sd = new Uint8Array(SD_IMAGE_BLOCKS * 512);
const vol = sd.subarray(2 * 512, 2 * 512 + 256);
vol[0x00] = 0x00; vol[0x01] = 0x00;
vol[0x02] = 0x03; vol[0x03] = 0x00;
vol[0x04] = 0xf0 | 6;
const volName = "VERASD";
for (let i = 0; i < volName.length; i++) vol[0x05 + i] = volName.charCodeAt(i);
vol[0x20] = 0x00;
vol[0x22] = 0xc3;
for (let block = 3; block <= 5; block++) {
  sd[block * 512] = block - 1;
  sd[block * 512 + 2] = block === 5 ? 0 : block + 1;
}
vol[0x23] = 0x27;
vol[0x24] = 0x0d;
vol[0x27] = 0x06; vol[0x28] = 0x00;
vol[0x29] = SD_BLOCKS & 0xff; vol[0x2a] = (SD_BLOCKS >> 8) & 0xff;
const bm = sd.subarray(6 * 512, 6 * 512 + Math.ceil(SD_BLOCKS / 4096) * 512);
bm.fill(0xff);
const reservedBlocks = 6 + Math.ceil(SD_BLOCKS / 4096);
for (let block = 0; block < reservedBlocks; block++) {
  bm[block >> 3] &= ~(0x80 >> (block & 7));
}
// The final physical block is outside the 65535-block ProDOS volume.
bm[8191] &= 0xfe;

// ------------------------------------------------------------ boot disk
if (!fs.existsSync(basePoPath)) throw new Error(`Base disk not found: ${basePoPath}`);
const disk = new Uint8Array(fs.readFileSync(basePoPath));
setProDOSVolumeName(disk, "VERASDIFSPRODOS");
const bitmap = disk.subarray(6 * 512, 7 * 512);
const isBlockFree = (b) => (bitmap[Math.floor(b / 8)] & (1 << (7 - (b % 8)))) !== 0;
const markBlockUsed = (b) => { bitmap[Math.floor(b / 8)] &= ~(1 << (7 - (b % 8))); };
const markBlockFree = (b) => { bitmap[Math.floor(b / 8)] |= 1 << (7 - (b % 8)); };
let freeBlockSearch = 7;
const allocateBlock = () => {
  while (freeBlockSearch < 280) {
    if (isBlockFree(freeBlockSearch)) {
      const b = freeBlockSearch++;
      markBlockUsed(b);
      disk.fill(0, b * 512, (b + 1) * 512);
      return b;
    }
    freeBlockSearch++;
  }
  throw new Error("boot disk full");
};
let fileCount = 0;
let quitSystemFound = false;
let currBlock = 2;
while (currBlock !== 0) {
  const blk = disk.subarray(currBlock * 512, (currBlock + 1) * 512);
  const next = blk[0x02] | (blk[0x03] << 8);
  for (let i = 0; i < 13; i++) {
    const off = 4 + i * 39;
    if (currBlock === 2 && i === 0) continue;
    const stLen = blk[off];
    if (stLen === 0) continue;
    const nameLen = stLen & 0x0f;
    const name = String.fromCharCode(...blk.subarray(off + 1, off + 1 + nameLen).map(c => c & 0x7f));
    const stType = (stLen >> 4) & 0x0f;
    if (name === "PRODOS" || name === "BASIC.SYSTEM" || name === "QUIT.SYSTEM") {
      if (name === "QUIT.SYSTEM" && stType === 1 && blk[off + 0x10] === 0xff) quitSystemFound = true;
      fileCount++;
      continue;
    }
    const keyBlk = blk[off + 0x11] | (blk[off + 0x12] << 8);
    if (stType === 1) markBlockFree(keyBlk);
    else if (stType === 2) {
      const idxBlk = disk.subarray(keyBlk * 512, (keyBlk + 1) * 512);
      markBlockFree(keyBlk);
      for (let b = 0; b < 256; b++) {
        const db = idxBlk[b] | (idxBlk[b + 256] << 8);
        if (db !== 0) markBlockFree(db);
      }
    }
    blk.fill(0, off, off + 39);
  }
  currBlock = next;
}
if (!quitSystemFound) throw new Error("Base ProDOS image is missing its seedling QUIT.SYSTEM SYS program");
const addFile = (filename, type, aux, data) => {
  const size = data.length;
  let stType, keyBlock;
  if (size <= 512) { stType = 1; keyBlock = allocateBlock(); disk.set(data, keyBlock * 512); }
  else {
    stType = 2; keyBlock = allocateBlock();
    const idxBlk = disk.subarray(keyBlock * 512, (keyBlock + 1) * 512);
    const numBlocks = Math.ceil(size / 512);
    for (let i = 0; i < numBlocks; i++) {
      const db = allocateBlock();
      disk.set(data.subarray(i * 512, Math.min(size, (i + 1) * 512)), db * 512);
      idxBlk[i] = db & 0xff; idxBlk[i + 256] = (db >> 8) & 0xff;
    }
  }
  const blocksUsed = stType === 1 ? 1 : 1 + Math.ceil(size / 512);
  let blkNum = 2, found = false;
  while (blkNum !== 0 && !found) {
    const blk = disk.subarray(blkNum * 512, (blkNum + 1) * 512);
    const next = blk[0x02] | (blk[0x03] << 8);
    for (let i = 0; i < 13; i++) {
      const off = 4 + i * 39;
      if (blkNum === 2 && i === 0) continue;
      if (blk[off] === 0) {
        blk[off] = (stType << 4) | (filename.length & 0x0f);
        for (let c = 0; c < 15; c++) blk[off + 1 + c] = c < filename.length ? filename.charCodeAt(c) : 0;
        blk[off + 0x10] = type;
        blk[off + 0x11] = keyBlock & 0xff; blk[off + 0x12] = (keyBlock >> 8) & 0xff;
        blk[off + 0x13] = blocksUsed & 0xff; blk[off + 0x14] = (blocksUsed >> 8) & 0xff;
        blk[off + 0x15] = size & 0xff; blk[off + 0x16] = (size >> 8) & 0xff; blk[off + 0x17] = (size >> 16) & 0xff;
        blk[off + 0x1e] = 0xc3;
        blk[off + 0x1f] = aux & 0xff; blk[off + 0x20] = (aux >> 8) & 0xff;
        blk[off + 0x25] = 0x02; blk[off + 0x26] = 0x00;
        fileCount++;
        found = true;
        break;
      }
    }
    blkNum = next;
  }
  if (!found) throw new Error("boot disk directory full");
};
// type $FF SYS: ProDOS launchers execute this as a system program (load addr is in directory aux field)
const verasdFile = instBytes;
addFile("VERASD.SYSTEM", 0xFF, INST_ADDR, verasdFile);
addFile("VERASD.BIN", 0x06, INST_ADDR, legacyBytes);
addFile("STARTUP", 0xFC, 0x0801, startupBytes);

// Present BASIC.SYSTEM and its auto-run STARTUP guide first in the catalog.
const directoryEntries = [];
const directorySlots = [];
currBlock = 2;
while (currBlock !== 0) {
  const blk = disk.subarray(currBlock * 512, (currBlock + 1) * 512);
  const next = blk[0x02] | (blk[0x03] << 8);
  for (let i = 0; i < 13; i++) {
    if (currBlock === 2 && i === 0) continue;
    const off = 4 + i * 39;
    directorySlots.push({ blk, off });
    if (blk[off] === 0) continue;
    const len = blk[off] & 0x0f;
    const name = String.fromCharCode(...blk.subarray(off + 1, off + 1 + len));
    directoryEntries.push({ name, bytes: Buffer.from(blk.subarray(off, off + 39)) });
  }
  currBlock = next;
}
const catalogRank = (name) => name === "BASIC.SYSTEM" ? 0 : name === "STARTUP" ? 1 : name === "QUIT.SYSTEM" ? 3 : 2;
directoryEntries.sort((a, b) => {
  return catalogRank(a.name) - catalogRank(b.name);
});
for (const { blk, off } of directorySlots) blk.fill(0, off, off + 39);
directoryEntries.forEach(({ bytes }, i) => directorySlots[i].blk.set(bytes, directorySlots[i].off));
disk[2 * 512 + 0x25] = fileCount & 0xff;
disk[2 * 512 + 0x26] = (fileCount >> 8) & 0xff;

// ------------------------------------------------------------ write outputs
const bootOutputArg = process.argv.find(arg => arg.startsWith("--boot-output="));
const outBoot = bootOutputArg
  ? path.resolve(bootOutputArg.slice("--boot-output=".length))
  : path.join(repoRoot, "VeraSD-IFS-ProDOS.po");
const outSd = path.join(repoRoot, "VeraSD-IFS-ProDOS.img");
const createSd = !fs.existsSync(outSd) || process.argv.includes("--reset-sd");
setProDOSFileTimestamps(disk, ["VERASD.SYSTEM", "VERASD.BIN", "STARTUP"]);
if (createSd) fs.writeFileSync(outSd, sd);
fs.writeFileSync(outBoot, disk);
fs.writeFileSync(path.join(__dirname, "verasd.bin"), legacyBytes);
fs.writeFileSync(path.join(__dirname, "verasd_sys.bin"), instBytes);
fs.writeFileSync(path.join(__dirname, "verasd.labels.json"), JSON.stringify(instLabels, null, 2));
fs.writeFileSync(path.join(__dirname, "verasd_drv.bin"), drvBytes);
fs.writeFileSync(path.join(__dirname, "verasd_gate.bin"), gateBytes);
fs.writeFileSync(path.join(__dirname, "verasd_gate.labels.json"), JSON.stringify(gateLabels, null, 2));
fs.writeFileSync(path.join(__dirname, "verasd_drv.labels.json"), JSON.stringify(drvLabels, null, 2));
console.log(`Created ${outBoot} (${disk.length} bytes)`);
console.log(`  VERASD.SYSTEM: ${instBytes.length} bytes (SYS, load $2000)`);
console.log(`  VERASD.BIN: ${legacyBytes.length} bytes (BIN, load $2000)`);
console.log(`  SYS handoff helper: ${nextSysBytes.length} transient bytes at $1000; not resident`);
console.log(`  STARTUP: ${startupBytes.length} bytes (BAS, load $0801)`);
console.log(`  driver: ${drvBytes.length} bytes (load $${DRV_ADDR.toString(16)})`);
console.log(`${createSd ? "Created" : "Preserved"} ${outSd}; new-image geometry: ${sd.length} physical bytes, ${SD_BLOCKS} ProDOS blocks`);
