#!/usr/bin/env python3
"""生成各家双拼的换键表 nova-schema/nova_shuangpin.txt（lua/nova_quanpin.lua 读它）。

用法：scripts/shuangpin_table.py nova-schema/nova_quanpin.txt nova-schema/nova_shuangpin.txt

Nova 内部始终是自然码双拼。用别家双拼时，每两个键查这张表得到音节，再从 nova_quanpin.txt
查到自然码编码。表里每行：<方案> <两个键> <音节>。

各方案的拼写规则照搬 Rime 的拼写运算：小鹤、微软取自 rime/rime-double-pinyin，
搜狗取自 iDvel/rime-ice。音节表和词频取自 nova_quanpin.txt。两个音节落到同一编码时留词频高的。
"""
import re
import sys

SCHEMES = {
    "flypy": [
        "derive/^([jqxy])u$/$1v/",
        "derive/^([aoe])([ioun])$/$1$1$2/",
        "xform/^([aoe])(ng)?$/$1$1$2/",
        "xform/iu$/Q/", "xform/(.)ei$/$1W/", "xform/uan$/R/", "xform/[uv]e$/T/", "xform/un$/Y/",
        "xform/^sh/U/", "xform/^ch/I/", "xform/^zh/V/", "xform/uo$/O/", "xform/ie$/P/",
        "xform/i?ong$/S/", "xform/ing$|uai$/K/", "xform/(.)ai$/$1D/", "xform/(.)en$/$1F/",
        "xform/(.)eng$/$1G/", "xform/[iu]ang$/L/", "xform/(.)ang$/$1H/", "xform/ian$/M/",
        "xform/(.)an$/$1J/", "xform/(.)ou$/$1Z/", "xform/[iu]a$/X/", "xform/iao$/N/",
        "xform/(.)ao$/$1C/", "xform/ui$/V/", "xform/in$/B/",
    ],
    "mspy": [
        "derive/^([jqxy])u$/$1v/",
        "derive/^([aoe].*)$/o$1/",
        "xform/^([ae])(.*)$/$1$1$2/",
        "xform/iu$/Q/", "xform/[iu]a$/W/", "xform/er$|[uv]an$/R/", "xform/[uv]e$/T/",
        "xform/v$|uai$/Y/", "xform/^sh/U/", "xform/^ch/I/", "xform/^zh/V/", "xform/uo$/O/",
        "xform/[uv]n$/P/", "xform/i?ong$/S/", "xform/[iu]ang$/D/", "xform/(.)en$/$1F/",
        "xform/(.)eng$/$1G/", "xform/(.)ang$/$1H/", "xform/ian$/M/", "xform/(.)an$/$1J/",
        "xform/iao$/C/", "xform/(.)ao$/$1K/", "xform/(.)ai$/$1L/", "xform/(.)ei$/$1Z/",
        "xform/ie$/X/", "xform/ui$/V/", "derive/T$/V/", "xform/(.)ou$/$1B/", "xform/in$/N/",
        "xform/ing$/;/",
    ],
    "sogou": [
        "derive/^([jqxy])u$/$1v/",
        "derive/^([aoe].*)$/o$1/",
        "xform/^([ae])(.*)$/$1$1$2/",
        "xform/iu$/Q/", "xform/[iu]a$/W/", "xform/er$|[uv]an$/R/", "xform/[uv]e$/T/",
        "xform/v$|uai$/Y/", "xform/^sh/U/", "xform/^ch/I/", "xform/^zh/V/", "xform/uo$/O/",
        "xform/[uv]n$/P/", "xform/(.)i?ong$/$1S/", "xform/[iu]ang$/D/", "xform/(.)en$/$1F/",
        "xform/(.)eng$/$1G/", "xform/(.)ang$/$1H/", "xform/ian$/M/", "xform/(.)an$/$1J/",
        "xform/iao$/C/", "xform/(.)ao$/$1K/", "xform/(.)ai$/$1L/", "xform/(.)ei$/$1Z/",
        "xform/ie$/X/", "xform/ui$/V/", "xform/(.)ou$/$1B/", "xform/in$/N/", "xform/ing$/;/",
    ],
}


def spell(syllable, rules):
    forms = {syllable}
    for rule in rules:
        op, pattern, repl = rule.split("/")[:3]
        repl = re.sub(r"\$(\d)", r"\\\1", repl)
        new = set()
        for f in forms:
            g = re.sub(pattern, repl, f)
            if op == "derive":
                new.add(f)
            new.add(g)
        forms = new
    return {f.lower() for f in forms if re.fullmatch(r"[a-z;][a-z;]", f.lower())}


def main():
    counts = {}
    for line in open(sys.argv[1], encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if f[0] == "s":
            counts[f[1]] = int(f[3])
    out = ["# 由 scripts/shuangpin_table.py 生成，不要手改。"]
    for name, rules in SCHEMES.items():
        table = {}
        for s in counts:
            for code in spell(s, rules):
                old = table.get(code)
                if old and old != s:
                    print(f"{name}: {code} 同时是 {old} 和 {s}", file=sys.stderr)
                if not old or counts[s] > counts[old]:
                    table[code] = s
        missing = [s for s in counts if s not in table.values()]
        if missing:
            print(f"{name}: 打不出 {' '.join(missing)}", file=sys.stderr)
        out += [f"{name}\t{code}\t{s}" for code, s in sorted(table.items())]
    open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
