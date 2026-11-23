# 把 Nova 词库拆成「不带辅助码的词条表」和「字 → 辅助码」表，供 app 在用户换辅助码时本机重新生成词库。
#
# 万象各辅助码版本（zrm、flypy、moqi）的词条完全相同，只有辅助码不同，而且一个字在所有词里的辅助码都一样。
# 所以词条表只要一份，每种辅助码只多一张约 0.3 MB 的小表。
#
#   python3 -I aux_tables.py base <万象 dicts 目录> <输出 nova_wx.base.txt> <表名>...
#       词条表：词\t双拼音节连写\t词频（词频原样）。顺序和 wx2nova.py 读万象词库的顺序一样，
#       (词, 音节) 重复的只留第一条。
#   python3 -I aux_tables.py aux <万象 dicts 目录> <输出 nova_aux_<方案>.txt> <表名>...
#       辅助码表：字\t辅助码（几个时用逗号隔开，和万象的写法一样）。
#   python3 -I aux_tables.py gen <nova_wx.base.txt> <nova_aux_<方案>.txt> <输出目录> <方案名>
#       用两张表生成 nova_wx.dict.yaml 和 nova_wx_jp.dict.yaml。app 里的 Swift 版（sources/NovaAuxDict.swift）
#       做同样的事，两边的输出必须逐字节一致；自然码的输出必须和 wx2nova.py 生成的词库正文一致。
#
# 生成规则和 wx2nova.py 一样：一个词里有字带几个辅助码时展开成多条，每个词最多 4 条；
# 简拼表每个词一条，词频取开头的数字，是 0 的不收。
#
# wx2nova.py 是按 (词, 带辅助码的编码) 去重的。辅助码只跟字有关，同一个 (词, 音节) 每次展开出来的编码都一样，
# 所以先按 (词, 音节) 去重、再展开，结果相同；简拼表也只记写进主词典的那一条，所以词频取的是第一条的。
import itertools
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wx2nova import MAX_COMBOS, detone, shuangpin  # noqa: E402


def lookup_chars(word):
    """按音节查辅助码用的字：外文人名里的间隔号（李·卡斯利）不占音节。"""
    return word.replace("·", "")


def entries(src, tables):
    for t in tables:
        body = False
        for line in (src / f"{t}.dict.yaml").open(encoding="utf-8"):
            if not body:
                body = line.startswith("...")
                continue
            if line.startswith("#") or "\t" not in line:
                continue
            parts = line.rstrip("\n").split("\t")
            yield parts[0], parts[1], parts[2] if len(parts) > 2 else "0"


def make_base(src, out, tables):
    seen = set()
    with out.open("w", encoding="utf-8") as f:
        for word, code, weight in entries(src, tables):
            sps = [shuangpin(detone(s.partition(";")[0])) for s in code.split(" ")]
            if any(sp is None or len(sp) != 2 for sp in sps):
                continue
            if len(lookup_chars(word)) != len(sps):
                raise SystemExit(f"字数和音节数对不上：{word}\t{code}")
            key = (word, "".join(sps))
            if key in seen:
                continue
            seen.add(key)
            f.write(f"{word}\t{key[1]}\t{weight}\n")
    print(f"{out.name}: {len(seen)} 条", file=sys.stderr)


def make_aux(src, out, tables):
    table = {}
    for word, code, _ in entries(src, tables):
        syls = code.split(" ")
        chars = lookup_chars(word)
        if len(chars) != len(syls):
            continue
        for ch, syl in zip(chars, syls):
            aux = ",".join(a for a in syl.partition(";")[2].split(",") if len(a) == 2)
            if table.setdefault(ch, aux) != aux:
                raise SystemExit(f"{ch} 的辅助码不止一种：{table[ch]} / {aux}")
    with out.open("w", encoding="utf-8") as f:
        for ch, aux in table.items():
            if aux:
                f.write(f"{ch}\t{aux}\n")
    print(f"{out.name}: {len(table)} 字", file=sys.stderr)


def header(name, scheme, imports):
    return (f"# 由星语按{scheme}辅助码生成（词库来自万象拼音，CC-BY-4.0），不要手改。\n"
            f"---\nname: {name}\nversion: \"wx\"\nsort: by_weight\nuse_preset_vocabulary: false\n"
            + (f"import_tables:\n  - {imports}\n" if imports else "") + "...\n")


def generate(base, aux_file, outdir, scheme):
    aux = {}
    for line in aux_file.open(encoding="utf-8"):
        ch, _, codes = line.rstrip("\n").partition("\t")
        aux[ch] = codes.split(",")
    with (outdir / "nova_wx.dict.yaml").open("w", encoding="utf-8") as main, \
            (outdir / "nova_wx_jp.dict.yaml").open("w", encoding="utf-8") as jp:
        main.write(header("nova_wx", scheme, "nova_wx_jp"))
        jp.write(header("nova_wx_jp", scheme, None))
        for line in base.open(encoding="utf-8"):
            word, sps, weight = line.rstrip("\n").split("\t")
            syls = [sps[i:i + 2] for i in range(0, len(sps), 2)]
            alts = [[f"{sp};{a}" for a in aux[ch]] if ch in aux else [sp]
                    for ch, sp in zip(lookup_chars(word), syls)]
            for combo in itertools.islice(itertools.product(*alts), MAX_COMBOS):
                main.write(f"{word}\t{' '.join(combo)}\t{weight}\n")
            digits = re.match(r"\d+", weight)
            count = int(digits.group()) if digits else 0
            if count > 0:
                jp.write(f"{word}\t{' '.join(s + '~' for s in syls)}\t{count}\n")


def main():
    cmd = sys.argv[1]
    if cmd == "base":
        make_base(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:])
    elif cmd == "aux":
        make_aux(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:])
    elif cmd == "gen":
        generate(Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4]), sys.argv[5])
    else:
        raise SystemExit(f"不认识的命令：{cmd}")


if __name__ == "__main__":
    main()
