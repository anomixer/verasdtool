// verasdformat.mjs — assemble VERASDFORMAT + compile its STARTUP and
// package a bootable ProDOS 2.4.3 disk (verasdformat.po).
//
// Same build shape as verasdedit.mjs: same asm6502 + applebasic compilers,
// same ProDOS 2.4.3 base disk, same "keep PRODOS + BASIC.SYSTEM" freeing.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { assemble6502 } from "../asm6502.mjs";
import { compileApplesoftBasic } from "../applebasic.mjs";
import { setProDOSFileTimestamps } from "../prodos-timestamp.mjs";
import { setProDOSVolumeName } from "../prodos-volume-name.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, "..", "..");
const basePoPath = path.join(repoRoot, "assets", "ProDOS_2_4_3.po");

// ---------------------------------------------------------------- assemble
const asmLines = fs
  .readFileSync(path.join(__dirname, "verasdformat.asm"), "utf-8")
  .split(/\r?\n/);
const bin = assemble6502(asmLines, 0x2000);

if (bin.length > 0x6000) {
  throw new Error(
    `Code too large: ${bin.length} bytes > 0x6000 (the program must live entirely inside $2000-$7FFF)`
  );
}

// ------------------------------------------------------------------ startup
const startup = compileApplesoftBasic(
  __dirname,
  path.join(__dirname, "startup.bas")
);

// --------------------------------------------------------------- disk build
const buildProDosDisk = () => {
  if (!fs.existsSync(basePoPath)) {
    throw new Error(`Base ProDOS 2.4.3.po not found at ${basePoPath}!`);
  }
  const disk = new Uint8Array(fs.readFileSync(basePoPath));
  setProDOSVolumeName(disk, "VERASDFORMAT");

  const bitmap = disk.subarray(6 * 512, 7 * 512);
  const isBlockFree = (b) =>
    (bitmap[Math.floor(b / 8)] & (1 << (7 - (b % 8)))) !== 0;
  const markBlockUsed = (b) => {
    bitmap[Math.floor(b / 8)] &= ~(1 << (7 - (b % 8)));
  };
  const markBlockFree = (b) => {
    bitmap[Math.floor(b / 8)] |= 1 << (7 - (b % 8));
  };

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
    throw new Error("Disk full: no free blocks");
  };

  let fileCount = 0;
  let currBlock = 2;

  // Free all existing user files (keep PRODOS + BASIC.SYSTEM)
  while (currBlock !== 0) {
    const blk = disk.subarray(currBlock * 512, (currBlock + 1) * 512);
    const next = blk[0x02] | (blk[0x03] << 8);

    for (let i = 0; i < 13; i++) {
      const off = 4 + i * 39;
      if (currBlock === 2 && i === 0) continue;

      const stLen = blk[off];
      if (stLen === 0) continue;

      const nameLen = stLen & 0x0f;
      const name = String.fromCharCode(
        ...blk.subarray(off + 1, off + 1 + nameLen)
      );

      if (name === "PRODOS" || name === "BASIC.SYSTEM") {
        fileCount++;
        continue;
      }

      const stType = (stLen >> 4) & 0x0f;
      const keyBlk = blk[off + 0x11] | (blk[off + 0x12] << 8);

      if (stType === 1) {
        markBlockFree(keyBlk);
      } else if (stType === 2) {
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

  const addFile = (filename, type, aux, data) => {
    const size = data.length;
    let stType, keyBlock;

    if (size <= 512) {
      stType = 1;
      keyBlock = allocateBlock();
      disk.set(data, keyBlock * 512);
    } else {
      stType = 2;
      keyBlock = allocateBlock();
      const indexBlk = disk.subarray(keyBlock * 512, (keyBlock + 1) * 512);
      const numBlocks = Math.ceil(size / 512);
      for (let i = 0; i < numBlocks; i++) {
        const db = allocateBlock();
        const chunk = data.subarray(
          i * 512,
          Math.min(size, (i + 1) * 512)
        );
        disk.set(chunk, db * 512);
        indexBlk[i] = db & 0xff;
        indexBlk[i + 256] = (db >> 8) & 0xff;
      }
    }

    const blocksUsed = stType === 1 ? 1 : 1 + Math.ceil(size / 512);

    let blkNum = 2;
    let found = false;

    while (blkNum !== 0 && !found) {
      const blk = disk.subarray(blkNum * 512, (blkNum + 1) * 512);
      const next = blk[0x02] | (blk[0x03] << 8);

      for (let i = 0; i < 13; i++) {
        const off = 4 + i * 39;
        if (blkNum === 2 && i === 0) continue;

        if (blk[off] === 0) {
          blk[off] = (stType << 4) | (filename.length & 0x0f);
          for (let c = 0; c < 15; c++) {
            blk[off + 1 + c] = c < filename.length ? filename.charCodeAt(c) : 0;
          }
          blk[off + 0x10] = type;
          blk[off + 0x11] = keyBlock & 0xff;
          blk[off + 0x12] = (keyBlock >> 8) & 0xff;
          blk[off + 0x13] = blocksUsed & 0xff;
          blk[off + 0x14] = (blocksUsed >> 8) & 0xff;
          blk[off + 0x15] = size & 0xff;
          blk[off + 0x16] = (size >> 8) & 0xff;
          blk[off + 0x17] = (size >> 16) & 0xff;
          blk[off + 0x1e] = 0xc3;
          blk[off + 0x1f] = aux & 0xff;
          blk[off + 0x20] = (aux >> 8) & 0xff;
          blk[off + 0x25] = 0x02;
          blk[off + 0x26] = 0x00;
          fileCount++;
          found = true;
          break;
        }
      }
      blkNum = next;
    }
  };

  addFile("VERASDFORMAT", 0x06, 0x2000, bin);
  addFile("STARTUP", 0xfc, 0x0801, startup);

  disk[2 * 512 + 0x25] = fileCount & 0xff;
  disk[2 * 512 + 0x26] = (fileCount >> 8) & 0xff;

  setProDOSFileTimestamps(disk, ["VERASDFORMAT", "STARTUP"]);
  return disk;
};

const outPath = path.join(repoRoot, "verasdformat.po");
const writePo = (target, data) => {
  try {
    fs.writeFileSync(target, data);
  } catch (err) {
    const locked = err?.code === "EPERM" || err?.code === "EACCES" || err?.code === "EBUSY";
    if (!locked || process.platform !== "win32") throw err;
    console.warn("verasdformat.po is locked; terminating AppleWin and retrying...");
    try {
      execFileSync("taskkill", ["/IM", "AppleWin.exe", "/F"], { stdio: "ignore" });
    } catch {
      // AppleWin may already have exited; the retry below gives the real error.
    }
    fs.writeFileSync(target, data);
  }
};
writePo(outPath, buildProDosDisk());
console.log(`Created ${outPath} (143360 bytes)`);
console.log(`  VERASDFORMAT: ${bin.length} bytes (load $2000)`);
console.log(`  STARTUP: ${startup.length} bytes`);
