#!/usr/bin/env python3
"""Generate rtl/tang/iosys/font_rom.v from tools/font8x8_basic.txt.

The Tang Nano 20K build has all 46 block RAMs occupied by the PC Engine core,
so the OSD font cannot live in a BSRAM.  It is emitted here as a plain
combinational case statement, which GowinSynthesis maps onto ROM16 LUTs.

Usage:  python tools/gen_font_rom.py
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(HERE, "font8x8_basic.txt")
DST = os.path.join(ROOT, "rtl", "tang", "iosys", "font_rom.v")

FIRST_CHAR = 0x20
LAST_CHAR = 0x7F


def read_font():
    glyphs = {}
    with open(SRC, "r", encoding="ascii") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 9:
                raise ValueError("bad font line: %r" % line)
            code = int(parts[0], 16)
            glyphs[code] = [int(p, 16) for p in parts[1:]]
    missing = [c for c in range(FIRST_CHAR, LAST_CHAR + 1) if c not in glyphs]
    if missing:
        raise ValueError("missing glyphs: %s" % missing)
    return glyphs


def main():
    glyphs = read_font()
    n = LAST_CHAR - FIRST_CHAR + 1
    out = []
    out.append("//")
    out.append("// 8x8 OSD font ROM - GENERATED FILE, DO NOT EDIT.")
    out.append("// Regenerate with:  python tools/gen_font_rom.py")
    out.append("//")
    out.append("// Glyphs: font8x8_basic by Daniel Hepper <daniel@hepper.net>,")
    out.append("// https://github.com/dhepper/font8x8, released into the public domain.")
    out.append("//")
    out.append("// ASCII 0x%02X..0x%02X, 8 rows per glyph, row 0 on top." % (FIRST_CHAR, LAST_CHAR))
    out.append("// Bit 0 of a row byte is the leftmost pixel.")
    out.append("//")
    out.append("// The address is {char - 0x%02X, row}, i.e. char_index * 8 + row." % FIRST_CHAR)
    out.append("// Mapped to LUT based ROM16 cells - the design has no spare BSRAM.")
    out.append("//")
    out.append("")
    out.append("module font_rom (")
    out.append("    input  wire       clk,")
    out.append("    input  wire [9:0] addr,     // 0 .. %d" % (n * 8 - 1))
    out.append("    output reg  [7:0] data")
    out.append(");")
    out.append("")
    out.append("always @(posedge clk) begin")
    out.append("    case (addr)")
    for c in range(FIRST_CHAR, LAST_CHAR + 1):
        rows = glyphs[c]
        idx = c - FIRST_CHAR
        ch = chr(c) if 0x20 < c < 0x7F else " "
        out.append("        // 0x%02X '%s'" % (c, ch))
        for r in range(8):
            out.append("        10'd%-3d: data <= 8'h%02X;" % (idx * 8 + r, rows[r]))
    out.append("        default: data <= 8'h00;")
    out.append("    endcase")
    out.append("end")
    out.append("")
    out.append("endmodule")
    out.append("")

    with open(DST, "w", encoding="ascii", newline="\n") as fh:
        fh.write("\n".join(out))
    sys.stdout.write("wrote %s (%d glyphs)\n" % (DST, n))


if __name__ == "__main__":
    main()
