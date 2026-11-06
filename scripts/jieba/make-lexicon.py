#!/usr/bin/env python3
"""从 jieba 的 dict.txt 生成 Nova 的分词词表 nova-schema/nova_lexicon.txt。

nova_sentences.lua 用这个词表在解码器的词内部再切分：三字以上的词不在词表里时，
按词频挑最可能的切法；成语都在词表里，所以保持完整。

格式：第一行 `#total\t<词频总和>`，之后每行 `词\t词频`，按 UTF-8 字节排序（Lua 里二分查找）。
只收全是汉字的词条（去掉 C++、T恤 这类）。同一个词出现多次时以最后一次为准，和 jieba 一致。

jieba 词典来自 https://github.com/fxsjy/jieba ，MIT 许可。

用法：python3 scripts/jieba/make-lexicon.py <jieba 的 dict.txt> > nova-schema/nova_lexicon.txt
"""
import re
import sys

HAN = re.compile(r"^[㐀-䶿一-鿿豈-﫿\U00020000-\U0003134f]+$")

words = {}
with open(sys.argv[1], encoding="utf-8") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 2 and HAN.match(parts[0]):
            words[parts[0]] = int(parts[1])

out = sys.stdout
out.write(f"#total\t{sum(words.values())}\n")
for word in sorted(words, key=lambda w: w.encode("utf-8")):
    out.write(f"{word}\t{words[word]}\n")
