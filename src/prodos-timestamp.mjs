// Stamp every active file entry in a block-ordered ProDOS volume directory.
export function setProDOSFileTimestamps(disk, filenames, when = new Date()) {
  const targets = new Set(filenames);
  const year = when.getFullYear();
  const yearField = year >= 2000 ? year - 2000 : year - 1900;
  if (yearField < 0 || yearField > 99) {
    throw new RangeError(`ProDOS timestamps cannot represent year ${year}`);
  }

  const date = (yearField << 9) | ((when.getMonth() + 1) << 5) | when.getDate();
  const time = (when.getHours() << 8) | when.getMinutes();
  let block = 2;
  const visited = new Set();

  while (block !== 0) {
    if (visited.has(block)) throw new Error(`ProDOS directory loop at block ${block}`);
    visited.add(block);
    const blockOffset = block * 512;
    const next = disk[blockOffset + 2] | (disk[blockOffset + 3] << 8);

    for (let i = 0; i < 13; i++) {
      if (block === 2 && i === 0) continue; // Volume directory header.
      const entry = blockOffset + 4 + i * 39;
      if (disk[entry] === 0) continue;
      const nameLength = disk[entry] & 0x0f;
      const name = String.fromCharCode(...disk.subarray(entry + 1, entry + 1 + nameLength));
      if (!targets.has(name)) continue;
      disk[entry + 0x18] = date & 0xff;
      disk[entry + 0x19] = date >> 8;
      disk[entry + 0x1a] = time & 0xff;
      disk[entry + 0x1b] = time >> 8;
      disk[entry + 0x21] = date & 0xff;
      disk[entry + 0x22] = date >> 8;
      disk[entry + 0x23] = time & 0xff;
      disk[entry + 0x24] = time >> 8;
    }
    block = next;
  }
}
