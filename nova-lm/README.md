# nova-lm：GPT-2 标橙插件

librime 滤镜 `nova_lm_filter`，接在 `lua_filter@*nova_sentences` 后面。每按一个键，用 GPT-2 给
解码器的前 5 句和 GPT-2 按码逐字 beam 出的 20 句打分，按各块的份额决定哪些块标橙、第一备选是什么。
做法和评测数字见 `nova_lm.cc` 开头的注释。

`nova_lm/repick: true` 时，GPT-2 还会直接改首选：某块另一种写法的份额更大，就换成那种写法。
`nova_sentences` 冻结的块（树里的 `s` 标记：学到的切分、输入没变时原样保留的树）和用户选过的块不换；打过去但没选的词不冻结，每一键都可以重选。默认开；开了以后剩下的错很少再标橙，
想多看到橙色提示就在 `nova.schema.yaml` 里改成 `false`。

重选打开时，按 `de` 打出的「的/地/得」也由 GPT-2 来定：这个音节还在最后三个音节之内时，三种写法各算一遍分，分高的显示出来。改成「地/得」只要分更高，改回「的」要高出 2 nats（GPT-2 学的网页文本习惯全写「的」）。`de` 是最后一个音节时不改成「地/得」。再往前的字保持上一键的写法，不再变。

## 构建和安装

1. `nova-lm/build.sh`：编出 `lib/rime-plugins/librime-nova-lm.dylib`，并把 ggml 的 CPU 后端复制到
   `lib/rime-plugins/nova-lm/`。需要 Homebrew 的 `ggml` 和 `boost`。
2. `scripts/build-nova.sh`：把插件、CPU 后端和 Homebrew 的 libggml、libomp 放进 app，改成 `@rpath`
   引用后签名。
3. `scripts/install-nova.sh`：把 `nova-lm/model/` 里的模型和字表复制到用户目录的 `nova_lm/`。
   没有模型时照常安装，插件原样放行。

Homebrew 升级 ggml 的主版本后（库名从 `libggml.0` 变成 `libggml.1`），插件链接的旧库就不在了，要重跑第 1 步；
第 2 步发现这种情况会停下并提示。ggml 0.27 换成 1.0.0 后 GPT-2 的打分略有变化：1622 句评测（eval0）整句全对
1094 → 1091，最终输出有 21 句不同。

## 模型文件（不进 git）

`nova-lm/model/` 里两个文件，约 111 MB：

- `gpt2.gguf`：[uer/gpt2-chinese-cluecorpussmall](https://huggingface.co/uer/gpt2-chinese-cluecorpussmall)
  用约 22 亿字的多领域中文语料继续训练 13.6 万步。损失是逐字的语言模型损失，加上只在同码字之间比较的同音损失。
  转成 F32 GGUF 后用 llama.cpp 的 `llama-quantize` 量化成 Q8_0。
  6486 句逐键评测（beam 5）整句全对 77.9% → 80.5%。训练代码和数据在本机 `.scratch/bench/retrain/`，不进 git。
  文件里另带人名地名标注头（`nova.ent.*`、`ent.*`，F32，约 2.4 MB），md5 `3cd523f8f15725e568ba6c52b41708a2`。
  标注头是接在第 6 层后面的小 MLP，冻住 GPT-2 单独训练，标签来自 LTP 对约 300 万字训练语料的人名地名识别。
  GPT-2 部分和不带标注头的那份（md5 `47c0250e0bd78fabc8718004f0b0f21a`）相同，`entity` 关着时两份输出一样。
  未训练的原模型用 `tools/to_gguf.py` 转换，md5 `46c0605f448663f389af6669179c9f4e`。
- `charmap.tsv`：每行 `双拼码 \t 字`，来自万象词库的单字条目，只留 GB2312 内、且在 uer 词表里
  是单个 token 的字。beam 每个音节只在这些字里选。

`nova_lm/entity: true` 把人名、地名合成一个词块（默认关）。需要带标注头的模型（GGUF 里有 `nova.ent.*` 元数据和 `ent.*` 权重）；模型里没有时自动保持关闭。
`nova_lm/entity_threshold` 是名字里各字标签概率的最小值，默认 0.8。只改分块，不改字；碰到用户选过的块、焦点块、辅助码、简拼、打错键的块，
或 `nova_bounds` 学到的边界时跳过；名字整个落在一个块里时不切出来。改 `entity` 后要重新部署，模型会在后台重新加载一次。开启后每键多跑一次整句最后一个字的前向。
6486 句逐键评测（阈值 0.8，人名地名按 LTP 标注）：人名整个成一块 57.2% → 70.3%，地名 79.5% → 81.3%，整句全对 5328 → 5329。
541 句逐键回放，每键平均 1.87 → 2.44 ms，p99 4.1 → 4.9 ms。
