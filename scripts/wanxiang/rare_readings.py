#!/usr/bin/env python3
"""Rare readings of single characters, for the GPT-2 plugin (nova_lm/rare in nova.schema.yaml).

    python3 -I rare_readings.py nova_wx.dict.yaml nova-schema/nova_rare.txt

万象 lists old or rare readings of common characters as single-character entries: 从 zòng (zs, weight
140 against 1294801 for cs), 不 fǒu, 能 nài, 她 jiě. GPT-2 sees only the characters, so a sentence
built on such a reading reads well to it and was re-picked over the word the user typed: uizs gave
是从 instead of 失踪. A reading is rare when its single-character weight is under SHARE of the
character's total; inside a word of two or more characters (放纵, 首都) it is not affected.

Output: one line per code, `code \t characters`.
"""
import collections
import sys

SHARE = 0.005


def main(dict_path, out_path):
    weights = collections.defaultdict(lambda: collections.Counter())
    body = False
    with open(dict_path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("..."):
                body = True
                continue
            if not body or line.startswith("#"):
                continue
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3 or len(parts[0]) != 1:
                continue
            try:
                weight = int(parts[2])
            except ValueError:
                continue
            code = parts[1].split(";")[0]
            weights[parts[0]][code] += weight
    rare = collections.defaultdict(list)
    for char, codes in weights.items():
        total = sum(codes.values())
        if len(codes) < 2 or total <= 0:
            continue
        for code, weight in codes.items():
            if weight < total * SHARE:
                rare[code].append(char)
    with open(out_path, "w", encoding="utf-8") as out:
        out.write("# 单字的冷僻读音（占该字单字词频不到 0.5%），由 scripts/wanxiang/rare_readings.py 生成。\n")
        for code in sorted(rare):
            out.write(code + "\t" + "".join(sorted(rare[code])) + "\n")
    print(f"{sum(map(len, rare.values()))} rare readings in {len(rare)} codes -> {out_path}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
