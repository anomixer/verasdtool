// dump.mjs — assemble installer + driver and print a 6502 disassembly
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { assemble6502 } from "../asm6502.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const gateLabels = {};
const gateLines = fs.readFileSync(path.join(__dirname, "verasd_gate.asm"), "utf-8").split(/\r?\n/);
const gateBytes = assemble6502(gateLines, 0xff00, gateLabels);
if (gateBytes.length > 0x9b) throw new Error("gate overlaps ProDOS interrupt handler");
const helperEquates = [`GATE_LOAD = ${gateLabels.load_buffer}`, `GATE_STORE = ${gateLabels.store_buffer}`];
const drvLines = fs.readFileSync(path.join(__dirname, "verasd_drv.asm"), "utf-8").split(/\r?\n/);
const drvLabels = {};
const drvBytes = assemble6502([...helperEquates, ...drvLines], 0xd400, drvLabels);

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
const instLines = fs.readFileSync(path.join(__dirname, "verasd.asm"), "utf-8").split(/\r?\n/);
const instFull = [...equates, ...instLines, ...hexLines, "gate_src:", ...Array.from(gateBytes, b => "!byte " + b)];
const instBytes = assemble6502(instFull, 0x2000);

// opcode map: [mnemonic, length]  length 1/2/3
const OPS = {
  0x00: ["BRK", 1], 0x60: ["RTS", 1], 0x40: ["RTI", 1], 0x08: ["PHP", 1], 0x28: ["PLP", 1],
  0x18: ["CLC", 1], 0x38: ["SEC", 1], 0xb8: ["CLV", 1], 0xd8: ["CLD", 1], 0x58: ["CLI", 1],
  0x78: ["SEI", 1], 0x48: ["PHA", 1], 0x68: ["PLA", 1], 0x8a: ["TXA", 1], 0x98: ["TYA", 1],
  0x9a: ["TXS", 1], 0xba: ["TSX", 1], 0xe8: ["INX", 1], 0xc8: ["INY", 1], 0xca: ["DEX", 1],
  0x88: ["DEY", 1],
  0xa9: ["LDA #", 2], 0xa5: ["LDA $", 2], 0xb5: ["LDA $X", 2], 0xad: ["LDA $", 3],
  0xbd: ["LDA $X", 3], 0xb9: ["LDA $Y", 3], 0xb1: ["LDA ($),Y", 2],
  0xa0: ["LDY #", 2], 0xa4: ["LDY $", 2], 0xac: ["LDY $", 3],
  0xa2: ["LDX #", 2], 0xa6: ["LDX $", 2], 0xae: ["LDX $", 3],
  0x85: ["STA $", 2], 0x95: ["STA $X", 2], 0x8d: ["STA $", 3], 0x9d: ["STA $X", 3], 0x99: ["STA $Y", 3],
  0x91: ["STA ($),Y", 2], 0x84: ["STY $", 2], 0x8c: ["STY $", 3], 0x86: ["STX $", 2],
  0x8e: ["STX $", 3],
  0x0a: ["ASL A", 1], 0x06: ["ASL $", 2], 0x0e: ["ASL $", 3],
  0x4a: ["LSR A", 1], 0x46: ["LSR $", 2], 0x4e: ["LSR $", 3],
  0x2a: ["ROL A", 1], 0x26: ["ROL $", 2], 0x2e: ["ROL $", 3],
  0x6a: ["ROR A", 1], 0x66: ["ROR $", 2], 0x6e: ["ROR $", 3],
  0xe6: ["INC $", 2], 0xee: ["INC $", 3], 0xc6: ["DEC $", 2], 0xce: ["DEC $", 3],
  0x4c: ["JMP $", 3], 0x6c: ["JMP ($)", 3], 0x20: ["JSR $", 3],
  0x10: ["BPL", 2], 0x30: ["BMI", 2], 0x50: ["BVC", 2], 0x70: ["BVS", 2],
  0x90: ["BCC", 2], 0xb0: ["BCS", 2], 0xd0: ["BNE", 2], 0xf0: ["BEQ", 2],
  0xc9: ["CMP #", 2], 0xc5: ["CMP $", 2], 0xcd: ["CMP $", 3], 0xd1: ["CMP ($),Y", 2],
  0xc0: ["CPY #", 2], 0xc4: ["CPY $", 2], 0xcc: ["CPY $", 3],
  0xe0: ["CPX #", 2], 0xe4: ["CPX $", 2], 0xec: ["CPX $", 3],
  0x29: ["AND #", 2], 0x25: ["AND $", 2], 0x2d: ["AND $", 3], 0x39: ["AND $Y", 3],
  0x09: ["ORA #", 2], 0x05: ["ORA $", 2], 0x0d: ["ORA $", 3],
  0x49: ["EOR #", 2], 0x45: ["EOR $", 2], 0x4d: ["EOR $", 3],
  0x69: ["ADC #", 2], 0x65: ["ADC $", 2], 0x6d: ["ADC $", 3], 0x71: ["ADC ($),Y", 2],
  0xe9: ["SBC #", 2], 0xe5: ["SBC $", 2], 0xed: ["SBC $", 3], 0xf1: ["SBC ($),Y", 2],
};
function disasm(bytes, base) {
  const out = [];
  let pc = 0;
  while (pc < bytes.length) {
    const addr = (base + pc) & 0xffff;
    const op = bytes[pc];
    const e = OPS[op];
    let len = 1, mnem = `.byte $${op.toString(16).padStart(2, "0")}`, operand = "";
    if (e) {
      len = e[1];
      mnem = e[0];
      if (len === 2) {
        const b = bytes[pc + 1];
        if (mnem.endsWith("#")) operand = `#$${b.toString(16).padStart(2, "0")}`;
        else if (mnem.endsWith("$X")) operand = `$${b.toString(16).padStart(2, "0")},X`;
        else if (mnem.endsWith("$Y")) operand = `$${b.toString(16).padStart(2, "0")},Y`;
        else if (mnem.endsWith("($)")) operand = `($${b.toString(16).padStart(2, "0")}),Y`;
        else if (mnem.endsWith("$")) operand = `$${b.toString(16).padStart(2, "0")}`;
        else if (mnem === "BPL" || mnem === "BMI" || mnem === "BVC" || mnem === "BVS" || mnem === "BCC" || mnem === "BCS" || mnem === "BNE" || mnem === "BEQ") {
          const t = (addr + 2 + (bytes[pc + 1] < 0x80 ? bytes[pc + 1] : bytes[pc + 1] - 0x100)) & 0xffff;
          operand = `$${t.toString(16).padStart(4, "0")}`;
        }
      } else if (len === 3) {
        const a = bytes[pc + 1] | (bytes[pc + 2] << 8);
        if (mnem.endsWith("$X")) operand = `$${a.toString(16).padStart(4, "0")},X`;
        else if (mnem.endsWith("$Y")) operand = `$${a.toString(16).padStart(4, "0")},Y`;
        else if (mnem.endsWith("($)")) operand = `($${a.toString(16).padStart(4, "0")})`;
        else operand = `$${a.toString(16).padStart(4, "0")}`;
      }
    }
    const hexb = Array.from(bytes.slice(pc, pc + len)).map(b => b.toString(16).padStart(2, "0")).join(" ");
    out.push(`${addr.toString(16).padStart(4, "0")}: ${hexb.padEnd(10)} ${mnem} ${operand}`.trimEnd());
    pc += len;
  }
  return out;
}
console.log("=== installer:", instBytes.length, "bytes; driver:", drvBytes.length, "bytes ===");
console.log(disasm(instBytes, 0x2000).join("\n"));
console.log("=== DRIVER ===");
console.log(disasm(drvBytes, 0xD400).join("\n"));
