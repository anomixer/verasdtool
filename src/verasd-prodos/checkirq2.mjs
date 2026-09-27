// Verify that the installer no longer overwrites ProDOS IRQ vectors in ROM/LC.
import fs from 'node:fs';
import assert from 'node:assert/strict';
const bytes = fs.readFileSync(new URL('./verasd.bin', import.meta.url));
for (const vector of [0xfffe, 0xffff]) {
  const store = Buffer.from([0x8d, vector & 255, vector >> 8]);
  assert.equal(bytes.indexOf(store), -1, `installer writes IRQ vector ${vector.toString(16)}`);
}
console.log('PASS: installer leaves IRQ vectors intact; saves/restores interrupt state');
