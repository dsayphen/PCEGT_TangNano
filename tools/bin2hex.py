#!/usr/bin/env python3
"""Convert a raw binary into a one-byte-per-line hex file for $readmemh.

    python tools/bin2hex.py firmware/firmware.bin sim/prog.hex [pad_bytes]
"""

import sys


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    pad = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    with open(src, "rb") as fh:
        data = bytearray(fh.read())
    while len(data) < pad:
        data.append(0xFF)

    with open(dst, "w", encoding="ascii", newline="\n") as fh:
        for b in data:
            fh.write("%02x\n" % b)

    sys.stdout.write("wrote %s (%d bytes)\n" % (dst, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
