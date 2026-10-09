// Update the ProDOS volume-directory header name in a block-ordered disk image.
export function setProDOSVolumeName(disk, name) {
  name = name.toUpperCase();
  if (name.length < 1 || name.length > 15) {
    throw new RangeError("ProDOS volume names must be 1 to 15 characters");
  }

  const header = 2 * 512 + 4;
  if ((disk[header] >> 4) !== 0x0f) {
    throw new Error("ProDOS volume directory header not found in block 2");
  }

  disk[header] = 0xf0 | name.length;
  disk.fill(0x20, header + 1, header + 16);
  for (let i = 0; i < name.length; i++) {
    const code = name.charCodeAt(i);
    if (code < 0x20 || code > 0x7e) {
      throw new RangeError("ProDOS volume names must contain printable ASCII");
    }
    disk[header + 1 + i] = code;
  }
}
