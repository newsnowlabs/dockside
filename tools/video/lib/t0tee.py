#!/usr/bin/env python3
"""Copies stdin to a file, and writes the epoch-millisecond time the first bytes arrived to a second file.

    t0tee.py <out-file> <t0-file>

record.sh pipes the capture through this so build.py knows, to within a frame, when
the capture began. The capture is flushed packet by packet, so the first bytes
arrive as the first frame is encoded.
"""
import os
import sys
import time

out, t0_file = sys.argv[1:3]
first = True
with open(out, 'wb') as f:
    while True:
        chunk = os.read(0, 1 << 16)
        if not chunk:
            break
        if first:
            with open(t0_file, 'w') as t:
                t.write(str(int(time.time() * 1000)))
            first = False
        f.write(chunk)
