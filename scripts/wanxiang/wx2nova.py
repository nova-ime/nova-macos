# 把万象拼音 zrm-fuzhu 版的词库转成 Nova 的「自然码双拼;辅助码」编码。
#
#   万象：货号\thuò;bh hào;kk\t401    带声调全拼；一个字有几个辅助码时用逗号隔开
#   Nova：货号\tho;bh hk;kk\t401
#
# 一个词里有字带多个辅助码时，展开成多条，每个词最多 4 条。
# 数据来源：https://github.com/amzxyz/rime-wanxiang（CC-BY-4.0）
#
# 用法：python3 -I wx2nova.py <万象 dicts 目录> <输出 .dict.yaml> <词典名> <表名>...
import itertools
import sys
import unicodedata
from pathlib import Path

MAX_COMBOS = 4

FINAL = {
    "iu": "q", "ia": "w", "ua": "w", "uan": "r", "van": "r", "ue": "t", "ve": "t",
    "ing": "y", "uai": "y", "uo": "o", "o": "o", "un": "p", "vn": "p", "ong": "s",
    "iong": "s", "iang": "d", "uang": "d", "en": "f", "eng": "g", "ang": "h",
    "an": "j", "ao": "k", "ai": "l", "ei": "z", "ie": "x", "iao": "c", "ui": "v",
    "v": "v", "ou": "b", "in": "n", "ian": "m", "a": "a", "e": "e", "i": "i", "u": "u",
}
ZERO = {"a": "aa", "ai": "ai", "an": "an", "ang": "ah", "ao": "ao", "e": "ee", "ei": "ei",
        "en": "en", "eng": "eg", "er": "er", "o": "oo", "ou": "ou",
        # 万象把「嗯」「呣」标成没有韵母的 n、ng、m；双拼里没有这种音节，按习惯的打法放。
        "n": "en", "ng": "en", "m": "mu"}


def shuangpin(py):
    """无调全拼（ü 写作 v）转自然码双拼；转不了返回 None。"""
    if py in ZERO:
        return ZERO[py]
    for ini, key in (("zh", "v"), ("ch", "i"), ("sh", "u")):
        if py.startswith(ini):
            rest = py[2:]
            return key + FINAL[rest] if rest in FINAL else None
    if not py:
        return None
    ini, rest = py[0], py[1:]
    if ini in "jqxy" and rest.startswith("u"):  # ju、que、yuan 里的 u 是 ü
        rest = {"u": "u", "ue": "ve", "uan": "van", "un": "vn"}.get(rest, rest)
    if rest not in FINAL:
        return None
    return ini + FINAL[rest]


def detone(s):
    s = unicodedata.normalize("NFD", s).replace("ü", "v").replace("Ü", "v")
    return "".join(c for c in s if not unicodedata.combining(c)).lower()


def convert(code):
    alts = []
    for syl in code.split(" "):
        py, _, aux = syl.partition(";")
        sp = shuangpin(detone(py))
        if sp is None or len(sp) != 2:
            return None
        auxes = [a for a in aux.split(",") if len(a) == 2] or [""]
        alts.append([f"{sp};{a}" if a else sp for a in auxes])
    return [" ".join(c) for c in itertools.islice(itertools.product(*alts), MAX_COMBOS)]


def main():
    src, out, name, tables = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4:]
    n = bad = 0
    seen = set()
    with out.open("w", encoding="utf-8") as f:
        f.write(f"# 由 scripts/wanxiang/wx2nova.py 从万象拼音 zrm-fuzhu 词库生成（CC-BY-4.0），不要手改。\n"
                f"---\nname: {name}\nversion: \"wx\"\nsort: by_weight\nuse_preset_vocabulary: false\n...\n")
        for t in tables:
            body = False
            for line in (src / f"{t}.dict.yaml").open(encoding="utf-8"):
                if not body:
                    body = line.startswith("...")
                    continue
                if line.startswith("#") or "\t" not in line:
                    continue
                parts = line.rstrip("\n").split("\t")
                word, code = parts[0], parts[1]
                weight = parts[2] if len(parts) > 2 else "0"
                codes = convert(code)
                if not codes:
                    bad += 1
                    continue
                for c in codes:
                    if (word, c) in seen:
                        continue
                    seen.add((word, c))
                    f.write(f"{word}\t{c}\t{weight}\n")
                    n += 1
    print(f"{out.name}: {n} 条，跳过 {bad} 条", file=sys.stderr)


if __name__ == "__main__":
    main()
