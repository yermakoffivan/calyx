#!/usr/bin/env python3
"""Generate Calyx/GhosttyBridge/EastAsianWidthTable.swift.

Usage: python3 -I scripts/gen-eaw-table.py <DerivedEastAsianWidth.txt> <output.swift>

Collects every code point whose East_Asian_Width is W or F, merges adjacent
ranges, and emits a sorted Swift table with a binary-search lookup.
"""
import os
import sys


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    ranges = []
    with open(src, encoding="utf-8") as f:
        for line in f:
            body = line.split("#", 1)[0].strip()
            if not body:
                continue
            cps, prop = (p.strip() for p in body.split(";"))
            if prop not in ("W", "F"):
                continue
            if ".." in cps:
                lo, hi = (int(x, 16) for x in cps.split(".."))
            else:
                lo = hi = int(cps, 16)
            ranges.append((lo, hi))
    ranges.sort()
    merged = []
    for lo, hi in ranges:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], hi))
        else:
            merged.append((lo, hi))

    name = os.path.basename(src)
    with open(src, encoding="utf-8") as f:
        first = f.readline().strip().lstrip("# ").strip()
    if first.startswith("DerivedEastAsianWidth-"):
        name = first

    out = [
        "// EastAsianWidthTable.swift",
        "// Calyx",
        "//",
        f"// Generated from {name} by scripts/gen-eaw-table.py — do not edit.",
        "// Code points whose East_Asian_Width is W (Wide) or F (Fullwidth).",
        "",
        "enum EastAsianWidthTable {",
        "    /// Sorted, non-overlapping, merged ranges.",
        "    nonisolated static let wideOrFullwidth: [ClosedRange<UInt32>] = [",
    ]
    for lo, hi in merged:
        out.append(f"        0x{lo:04X}...0x{hi:04X},")
    out += [
        "    ]",
        "",
        "    /// Binary search over `wideOrFullwidth`.",
        "    nonisolated static func isWideOrFullwidth(_ v: UInt32) -> Bool {",
        "        var lo = 0",
        "        var hi = wideOrFullwidth.count - 1",
        "        while lo <= hi {",
        "            let mid = (lo + hi) / 2",
        "            let r = wideOrFullwidth[mid]",
        "            if v < r.lowerBound {",
        "                hi = mid - 1",
        "            } else if v > r.upperBound {",
        "                lo = mid + 1",
        "            } else {",
        "                return true",
        "            }",
        "        }",
        "        return false",
        "    }",
        "}",
        "",
    ]
    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(out))


if __name__ == "__main__":
    main()
