#!/usr/bin/env python3
"""Rare readings of single characters, for the GPT-2 plugin (nova_lm/rare in nova.schema.yaml).

    python3 -I rare_readings.py nova_wx.dict.yaml nova-schema/nova_rare.txt

万象 lists old or rare readings of common characters as single-character entries: 从 zòng (zs, weight
140 against 1294801 for cs), 不 fǒu, 能 nài, 她 jiě. GPT-2 sees only the characters, so a sentence
built on such a reading reads well to it and was re-picked over the word the user typed: uizs gave
是从 instead of 失踪. A reading is rare when its single-character weight is under SHARE of the
character's total; inside a word of two or more characters (放纵, 首都) it is not affected.

Every reading of a character with more than one also carries its share, so GPT-2 can weigh how likely
the typed code is for that character (log P(code | char), the decoder's side of the sentence score
that GPT-2 does not see). Characters with one reading have share 1 and are left out.

Output: `rare_share \t SHARE` first, the threshold the plugin reads; then one line per reading,
`code \t character \t share`, sorted by code.
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
    rows, rare = [], 0
    for char, codes in weights.items():
        total = sum(codes.values())
        if len(codes) < 2 or total <= 0:
            continue
        for code, weight in codes.items():
            share = max(weight, 1) / total
            rows.append((code, char, share))
            rare += share < SHARE
    rows.sort()
    with open(out_path, "w", encoding="utf-8") as out:
        out.write(f"rare_share\t{SHARE:g}\n")
        out.write("# 多音字每个读音占该字单字词频的比例；不到 rare_share 的算冷僻读音。由 scripts/wanxiang/rare_readings.py 生成。\n")
        for code, char, share in rows:
            out.write(f"{code}\t{char}\t{share:.3g}\n")
    print(f"{len(rows)} readings, {rare} rare -> {out_path}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
