"""uer/gpt2-chinese-cluecorpussmall (HF GPT2LMHeadModel, BERT char vocab) -> GGUF (arch gpt2), F32.
Tokenization is done by the caller (char -> id from vocab.txt), so the GGUF vocab is only a token list.
Usage: python -I to_gguf.py <hf_snapshot_dir> <out.gguf>
"""
import sys
from pathlib import Path

import gguf
import numpy as np
import torch

src, dst = Path(sys.argv[1]), sys.argv[2]
sd = torch.load(src / "pytorch_model.bin", map_location="cpu", weights_only=True)
sd = {k.removeprefix("transformer."): v.float().numpy() for k, v in sd.items()}
vocab = (src / "vocab.txt").read_text(encoding="utf-8").split("\n")  # not splitlines(): token 343 is U+2028
nl = 1 + max(int(k.split(".")[1]) for k in sd if k.startswith("h."))
D = sd["wte.weight"].shape[1]
vocab = vocab[: sd["wte.weight"].shape[0]]  # vocab.txt has trailing extras

w = gguf.GGUFWriter(dst, "gpt2")
w.add_context_length(sd["wpe.weight"].shape[0])
w.add_embedding_length(D)
w.add_feed_forward_length(4 * D)
w.add_block_count(nl)
w.add_head_count(D // 64)
w.add_layer_norm_eps(1e-5)
w.add_file_type(gguf.LlamaFileType.ALL_F32)
w.add_tokenizer_model("gpt2")
w.add_tokenizer_pre("default")
w.add_token_list(vocab)
w.add_token_types([gguf.TokenType.NORMAL] * len(vocab))
w.add_token_merges(["[ CLS]"])  # loader needs a non-empty merges list; never used
w.add_bos_token_id(vocab.index("[CLS]"))
w.add_eos_token_id(vocab.index("[SEP]"))


def put(name, a):
    w.add_tensor(name, np.ascontiguousarray(a, dtype=np.float32))


put("token_embd.weight", sd["wte.weight"])
put("position_embd.weight", sd["wpe.weight"])
# HF Conv1D stores [in, out]; ggml wants numpy [out, in].
for i in range(nl):
    p = f"h.{i}."
    for hf, gg in [("ln_1", "attn_norm"), ("ln_2", "ffn_norm")]:
        put(f"blk.{i}.{gg}.weight", sd[p + hf + ".weight"])
        put(f"blk.{i}.{gg}.bias", sd[p + hf + ".bias"])
    for hf, gg in [("attn.c_attn", "attn_qkv"), ("attn.c_proj", "attn_output"), ("mlp.c_fc", "ffn_up"),
                   ("mlp.c_proj", "ffn_down")]:
        put(f"blk.{i}.{gg}.weight", sd[p + hf + ".weight"].T)
        put(f"blk.{i}.{gg}.bias", sd[p + hf + ".bias"])
put("output_norm.weight", sd["ln_f.weight"])
put("output_norm.bias", sd["ln_f.bias"])
w.write_header_to_file()
w.write_kv_data_to_file()
w.write_tensors_to_file()
w.close()
print("wrote", dst, "layers", nl, "dim", D, "vocab", len(vocab))
