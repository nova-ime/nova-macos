#!/usr/bin/env python3
"""生成全拼切音节用的表 nova-schema/nova_quanpin.txt（lua/nova_quanpin.lua 读它）。

用法：scripts/wanxiang/quanpin_table.py <万象 zrm 词库的 dicts 目录> <输出文件>
dicts 目录由 setup-wanxiang.sh 下载到 .scratch/wanxiang/zrm/dicts。

表里两种行：
  s <音节> <自然码双拼> <词频>     每个能转成双拼的拼音音节
  b <前一个音节> <后一个音节> <词频>  词库的词里相邻出现的所有音节对
词频是词库里含这个音节（音节对）的词的权重之和。

音节对全留（11.7 万条，1.8 MB，读一次约 0.04 秒）：2 万句逐键切分，整句切对 98.57%；
只留词频最高的 1 万条是 98.27%，而且「en en」这种词频低的对没了，enen 只能切成 e + nen。
"""
import collections
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import wx2nova  # noqa: E402

SKIP = {"en.dict.yaml", "mixed.dict.yaml", "abbrev.dict.yaml"}


def main():
    source, output = Path(sys.argv[1]), Path(sys.argv[2])
    unigram, bigram = collections.Counter(), collections.Counter()
    for path in sorted(source.glob("*.dict.yaml")):
        if path.name in SKIP:
            continue
        body = False
        for line in path.open(encoding="utf-8"):
            if not body:
                body = line.startswith("...")
                continue
            fields = line.rstrip("\n").split("\t")
            if line.startswith("#") or len(fields) < 2:
                continue
            try:
                weight = max(float(fields[2]), 1.0) if len(fields) > 2 else 1.0
            except ValueError:
                weight = 1.0
            syllables = [wx2nova.detone(s.partition(";")[0]) for s in fields[1].split(" ")]
            for syllable in syllables:
                unigram[syllable] += weight
            for pair in zip(syllables, syllables[1:]):
                bigram[pair] += weight
    codes = {}
    for syllable in unigram:
        # 没有韵母的 m、n、ng（嗯、呣）在词库里另按 en、mu 放，全拼里不单独成音节。
        if syllable in ("m", "n", "ng"):
            continue
        code = wx2nova.shuangpin(syllable)
        if code and len(code) == 2:
            codes[syllable] = code
    pairs = [(pair, count) for pair, count in bigram.items() if pair[0] in codes and pair[1] in codes]
    pairs.sort(key=lambda item: (-item[1], item[0]))
    with output.open("w", encoding="utf-8") as out:
        out.write("# 由 scripts/wanxiang/quanpin_table.py 生成，不要手改。\n")
        for syllable in sorted(codes):
            out.write(f"s\t{syllable}\t{codes[syllable]}\t{round(unigram[syllable])}\n")
        for (first, second), count in pairs:
            out.write(f"b\t{first}\t{second}\t{round(count)}\n")
    print(f"{len(codes)} 个音节，{len(pairs)} 条音节对 -> {output}")


if __name__ == "__main__":
    main()
