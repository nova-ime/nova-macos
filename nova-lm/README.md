# nova-lm：GPT-2 标橙插件

librime 滤镜 `nova_lm_filter`，接在 `lua_filter@*nova_sentences` 后面。每按一个键，用 GPT-2 给
解码器的前 5 句和 GPT-2 按码逐字 beam 出的 5 句打分，按各块的份额决定哪些块标橙、第一备选是什么。
做法和评测数字见 `nova_lm.cc` 开头的注释。

## 构建和安装

1. `nova-lm/build.sh`：编出 `lib/rime-plugins/librime-nova-lm.dylib`，并把 ggml 的 CPU 后端复制到
   `lib/rime-plugins/nova-lm/`。需要 Homebrew 的 `ggml` 和 `boost`。
2. `scripts/build-nova.sh`：把插件、CPU 后端和 Homebrew 的 libggml、libomp 放进 app，改成 `@rpath`
   引用后签名。
3. `scripts/install-nova.sh`：把 `nova-lm/model/` 里的模型和字表复制到用户目录的 `nova_lm/`。
   没有模型时照常安装，插件原样放行。

## 模型文件（不进 git）

`nova-lm/model/` 里两个文件，约 111 MB：

- `gpt2.gguf`：[uer/gpt2-chinese-cluecorpussmall](https://huggingface.co/uer/gpt2-chinese-cluecorpussmall)
  用 `tools/to_gguf.py` 转成 F32 GGUF，再用 llama.cpp 的 `llama-quantize` 量化成 Q8_0。
  原模型未经微调。
- `charmap.tsv`：每行 `双拼码 \t 字`，来自万象词库的单字条目，只留 GB2312 内、且在 uer 词表里
  是单个 token 的字。beam 每个音节只在这些字里选。
