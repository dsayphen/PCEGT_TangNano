#!/usr/bin/env python3
"""Send a PC Engine / TurboGrafx-16 HuCard image to the Tang Nano 20K core.

Usage:
    python tools/pce_send.py COM7 game.pce
    python tools/pce_send.py /dev/ttyUSB0 game.pce --baud 921600

Wire protocol (see rtl/tang/rom_loader.v):

    "PCE" 0x01                 4 byte magic
    <size>                     4 byte little endian image size
    <size bytes>               the raw image

The 512 byte header that some .pce dumps carry is *not* stripped here: the
core detects it (size & 0x3FF == 0x200) and skips it while reading, exactly
like the MiST/MiSTer version of this core does.

Requires pyserial (`pip install pyserial`).
"""

import argparse
import os
import struct
import sys
import time

try:
    import serial
except ImportError:  # pragma: no cover
    sys.exit("pyserial is required: pip install pyserial")

MAGIC = b"PCE\x01"
MAX_SIZE = 4 * 1024 * 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", help="serial port of the Tang Nano 20K (e.g. COM7)")
    ap.add_argument("image", help=".pce / .bin HuCard image")
    ap.add_argument("--baud", type=int, default=115200,
                    help="must match BAUD_RATE in rtl/top_tang_nano20k.v "
                         "(default: 115200)")
    ap.add_argument("--chunk", type=int, default=4096,
                    help="write chunk size in bytes (default: 4096)")
    args = ap.parse_args()

    with open(args.image, "rb") as handle:
        data = handle.read()

    size = len(data)
    if size == 0 or size > MAX_SIZE:
        sys.exit("image size %d is out of range (1 .. %d)" % (size, MAX_SIZE))

    header = (size & 0x3FF) == 0x200
    print("%s: %d bytes (%d KiB)%s" %
          (os.path.basename(args.image), size, size // 1024,
           ", 512 byte header detected" if header else ""))
    print("ROM_SZ code = 0x%02X" % ((size >> 16) & 0xFF))

    with serial.Serial(args.port, args.baud, timeout=1) as port:
        # a short pause lets the board settle after the port is opened
        time.sleep(0.1)
        port.reset_output_buffer()
        port.write(MAGIC + struct.pack("<I", size))

        start = time.time()
        sent = 0
        while sent < size:
            end = min(sent + args.chunk, size)
            port.write(data[sent:end])
            sent = end
            done = 100 * sent // size
            sys.stdout.write("\r  sending... %3d%%" % done)
            sys.stdout.flush()
        port.flush()

    elapsed = time.time() - start
    print("\ndone in %.1f s (%.1f KiB/s)" % (elapsed, size / 1024.0 / max(elapsed, 1e-6)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
