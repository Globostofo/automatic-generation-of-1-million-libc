#!/usr/bin/env python3
# =============================================================================
# Script   : gen_order_script.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate a partial linker script that places .text.* sections
#            in a random order with random padding gaps between them
# Usage    : readelf -S --wide *.o | grep -oP '\.text\.\S+' | sort -u \
#              | ./scripts/gen_order_script.py <seed> [pad_min] [pad_max]
# =============================================================================

import random
import sys

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <seed> [pad_min] [pad_max]", file=sys.stderr)
    sys.exit(1)

SEED = int(sys.argv[1])
PAD_MIN = int(sys.argv[2]) if len(sys.argv) > 2 else 0
PAD_MAX = int(sys.argv[3]) if len(sys.argv) > 3 else 64

sections = sorted(set(line.strip() for line in sys.stdin if line.strip()))

rng = random.Random(SEED)
rng.shuffle(sections)

lines = ["SECTIONS", "{", "  .text : {"]
for i, section in enumerate(sections):
    lines.append(f"    *({section})")
    if i < len(sections) - 1:
        gap = rng.randint(PAD_MIN, PAD_MAX)
        if gap > 0:
            lines.append(f"    . += {gap};")
lines.append("    *(.text .text.*)")
lines.append("  }")
lines.append("}")
lines.append("INSERT AFTER .text;")

print("\n".join(lines))
