#!/usr/bin/env python3
"""Independent Python-integer oracle for the 64-bit arithmetic regression."""
from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

Q = 18446744069414584321  # Goldilocks prime: 2**64 - 2**32 + 1
SEED = 0x819264
COUNT = 512


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("build/wide_vectors"))
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    edges = [0, 1, 2, Q - 1, Q - 2, Q // 2, 2**32 - 1, 2**63, 2**64 - 2**32]
    cases = []
    for i, a in enumerate(edges):
        for j, b in enumerate(edges):
            cases.append((a, b, edges[(i + 2 * j) % len(edges)]))
    rng = random.Random(SEED)
    while len(cases) < COUNT:
        cases.append((rng.randrange(Q), rng.randrange(Q), rng.randrange(Q)))
    with (args.out / "cases.hex").open("w", encoding="ascii", newline="\n") as stream:
        for a, b, w in cases:
            result = (a * b) % Q
            y0, y1 = (a + b * w) % Q, (a - b * w) % Q
            stream.write("".join(f"{word:016x}" for word in (a, b, w, result, y0, y1)) + "\n")
    (args.out / "manifest.json").write_text(
        json.dumps({"width": 64, "modulus": str(Q), "seed": SEED, "cases": COUNT,
                    "layout_msb_first": ["a", "b", "twiddle", "a_times_b_mod_q", "y0", "y1"],
                    "oracle": "Python arbitrary-precision integer arithmetic"}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Generated {COUNT} 64-bit arithmetic vectors in {args.out}")


if __name__ == "__main__":
    main()
