// GPT-2 (GGUF, arch gpt2) prefix-tree scorer on ggml's CPU backend.
//
// Every tree node is one token with one KV cell; a node attends to its ancestor chain only, so
// candidates that share a prefix share its computation. flush() runs, in one batch, only the nodes
// added since the last flush. Scores come from the parent's final hidden state:
// log p(tok | ancestors) = wte[tok] . h(parent) - lse(parent).
#pragma once

#include <cstdlib>
#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#endif
#include <ggml-alloc.h>
#include <ggml-backend.h>
#include <ggml.h>
#include <gguf.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace nova_lm {

struct Head {
  ggml_tensor *fc1 = nullptr, *fb1 = nullptr, *fc2 = nullptr, *fb2 = nullptr;
  int layer = 0, h = 0, nout = 0;
  bool ok = false;
};

class TreeLM {
 public:
  ~TreeLM() {
    if (galloc_) ggml_gallocr_free(galloc_);
    for (auto *b : {kbuf_, wbuf_, rbuf_})
      if (b) ggml_backend_buffer_free(b);
    for (auto *c : {kctx_, wctx_, rctx_})
      if (c) ggml_free(c);
    if (be_) ggml_backend_free(be_);
  }

  // cap = number of KV cells (tree nodes, context included) kept at once.
  // backend_dir: where the ggml CPU backend libraries are (libggml-cpu-*.so); empty means
  // ggml's built-in search path.
  bool load(const std::string &path, int threads, int cap, const std::string &backend_dir = "", bool want_ent = false,
            bool want_seg = false) {
    // The CPU backend runs on libomp, whose workers busy-wait 200 ms after each parallel region by default.
    // In an input method that burns several cores after every key. 0 is slower (a graph wakes
    // the workers many times); 5 ms keeps them warm within one key: 400 typed sentences give
    // p50/p99 3.5/7.2 ms against 4.2/10.0 at 200 and 8.0/12.3 at 0. Read when libomp starts;
    // a setting already in the environment wins.
#ifndef _WIN32
    setenv("KMP_BLOCKTIME", "5", 0);
#endif
    if (!backend_dir.empty()) ggml_backend_load_all_from_path(backend_dir.c_str());
    if (!ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU)) ggml_backend_load_all();
    be_ = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, nullptr);
    if (!be_) return false;
    auto set_threads = (ggml_backend_set_n_threads_t)ggml_backend_reg_get_proc_address(
        ggml_backend_dev_backend_reg(ggml_backend_get_device(be_)), "ggml_backend_set_n_threads");
    if (set_threads) set_threads(be_, threads);
    // Matmul weights go to the CPU "repack" buffer (interleaved Q8_0 for the i8mm GEMM kernels),
    // everything else (embeddings for get_rows, norms, biases) to the plain buffer.
    ggml_backend_buffer_type_t repack = nullptr;
    ggml_backend_dev_t dev = ggml_backend_get_device(be_);
    auto reg = ggml_backend_dev_backend_reg(dev);
    if (auto fx = (ggml_backend_dev_get_extra_bufts_t)ggml_backend_reg_get_proc_address(
            reg, "ggml_backend_dev_get_extra_bufts"))
      for (auto *b = fx(dev); b && *b; b++)
        if (strstr(ggml_backend_buft_name(*b), "REPACK")) repack = *b;
    // ggml repacks Q8_0 only for ARM (NEON with i8mm or dotprod). On x86 a Q8_0 tensor in the repack buffer gets no
    // traits (extra == nullptr), and loading it or the first matmul then dereferences null. Use the buffer only where
    // ggml has a layout for the weights.
    if (repack) {
      bool neon = false, i8mm_or_dot = false;
      if (auto gf = (ggml_backend_get_features_t)ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features"))
        for (auto *ft = gf(reg); ft && ft->name; ft++) {
          if (!strcmp(ft->name, "NEON")) neon = true;
          if (!strcmp(ft->name, "MATMUL_INT8") || !strcmp(ft->name, "DOTPROD")) i8mm_or_dot = true;
        }
      if (!(neon && i8mm_or_dot)) repack = nullptr;
    }

    ggml_context *meta = nullptr;
    gguf_init_params gp{true, &meta};
    gguf_context *g = gguf_init_from_file(path.c_str(), gp);
    if (!g) return false;
    auto u32 = [&](const char *k) {
      int64_t id = gguf_find_key(g, k);
      return id < 0 ? 0 : (int)gguf_get_val_u32(g, id);
    };
    L_ = u32("gpt2.block_count");
    D_ = u32("gpt2.embedding_length");
    NH_ = u32("gpt2.attention.head_count");
    int64_t tk = gguf_find_key(g, "tokenizer.ggml.tokens");
    if (!L_ || !D_ || !NH_ || tk < 0) { gguf_free(g); ggml_free(meta); return false; }
    for (size_t i = 0, n = gguf_get_arr_n(g, tk); i < n; i++) tokens_.push_back(gguf_get_arr_str(g, tk, i));
    // Entity head (nova.ent.*) and segmentation head (nova.seg.*), see probs(); a file without one, or with one this
    // code does not know, just has no such head.
    bool ent_meta = false, seg_meta = false;
    {
      int64_t et = gguf_find_key(g, "nova.ent.tags");
      static const char *kTags[] = {"O", "B-PER", "I-PER", "B-LOC", "I-LOC"};
      ent_meta = et >= 0 && gguf_get_arr_n(g, et) == 5;
      for (int i = 0; ent_meta && i < 5; i++) ent_meta = !strcmp(gguf_get_arr_str(g, et, i), kTags[i]);
      ent_.layer = u32("nova.ent.layer");
      ent_.h = u32("nova.ent.hidden");
      ent_.nout = 5;
      ent_meta = ent_meta && u32("nova.ent.window") == 3;
      seg_.layer = u32("nova.seg.layer");
      seg_.h = u32("nova.seg.hidden");
      seg_.nout = 2;
      seg_meta = u32("nova.seg.window") == 3;
    }

    int64_t nt = gguf_get_n_tensors(g);
    ggml_init_params ip{ggml_tensor_overhead() * (nt + 1), nullptr, true};
    wctx_ = ggml_init(ip);
    rctx_ = ggml_init(ip);
    auto is_mm = [](const char *n) {
      for (const char *s : {"attn_qkv.weight", "attn_output.weight", "ffn_up.weight", "ffn_down.weight"})
        if (strstr(n, s)) return true;
      return false;
    };
    std::vector<std::pair<ggml_tensor *, ggml_tensor *>> dst(nt);  // (main, tied output copy)
    bool has_out = false;
    for (int64_t i = 0; i < nt; i++) {
      const char *n = gguf_get_tensor_name(g, i);
      ggml_tensor *src = ggml_get_tensor(meta, n);
      ggml_tensor *t = ggml_dup_tensor(repack && is_mm(n) && ggml_is_quantized(src->type) ? rctx_ : wctx_, src);
      ggml_set_name(t, n);
      dst[i].first = t;
      has_out |= !strcmp(n, "output.weight");
    }
    for (int64_t i = 0; i < nt && !has_out; i++)
      if (!strcmp(gguf_get_tensor_name(g, i), "token_embd.weight")) {  // tied output head
        dst[i].second = ggml_dup_tensor(repack && ggml_is_quantized(dst[i].first->type) ? rctx_ : wctx_, dst[i].first);
        ggml_set_name(dst[i].second, "output.weight");
      }
    wbuf_ = ggml_backend_alloc_ctx_tensors(wctx_, be_);
    if (repack) rbuf_ = ggml_backend_alloc_ctx_tensors_from_buft(rctx_, repack);
    FILE *f = fopen(path.c_str(), "rb");
    bool ok = f != nullptr;
    std::vector<char> tmp;
    for (int64_t i = 0; ok && i < nt; i++) {
      tmp.resize(ggml_nbytes(dst[i].first));
      fseek(f, (long)(gguf_get_data_offset(g) + gguf_get_tensor_offset(g, i)), SEEK_SET);
      ok = fread(tmp.data(), 1, tmp.size(), f) == tmp.size();
      if (!ok) break;
      ggml_backend_tensor_set(dst[i].first, tmp.data(), 0, tmp.size());
      if (dst[i].second) ggml_backend_tensor_set(dst[i].second, tmp.data(), 0, tmp.size());
    }
    if (f) fclose(f);
    gguf_free(g);
    ggml_free(meta);
    if (!ok) return false;
    wte_ = W("token_embd.weight");
    wpe_ = W("position_embd.weight");
    out_ = W("output.weight");
    if (!wte_ || !wpe_ || !out_) return false;
    V_ = (int)wte_->ne[1];
    npos_ = (int)wpe_->ne[1];
    ent_.ok = want_ent && ent_meta && bind(ent_, "ent");
    seg_.ok = want_seg && seg_meta && bind(seg_, "seg");
    // Both heads read the same node vector e: with the two at different layers, the segmentation head goes.
    if (ent_.ok && seg_.ok && seg_.layer != ent_.layer) seg_.ok = false;
    e_layer_ = ent_.ok ? ent_.layer : seg_.ok ? seg_.layer : 0;

    cap_ = cap;
    ggml_init_params kp{ggml_tensor_overhead() * (2 * L_ + 1), nullptr, true};
    kctx_ = ggml_init(kp);
    for (int l = 0; l < L_; l++) {
      kc_.push_back(ggml_new_tensor_2d(kctx_, GGML_TYPE_F16, D_, cap_));  // [D, cell]
      vc_.push_back(ggml_new_tensor_2d(kctx_, GGML_TYPE_F16, D_, cap_));
    }
    kbuf_ = ggml_backend_alloc_ctx_tensors(kctx_, be_);
    galloc_ = ggml_gallocr_new(ggml_backend_get_default_buffer_type(be_));
    meta_.resize(ggml_tensor_overhead() * 4096 + ggml_graph_overhead_custom(4096, false));
    row_.resize(D_);
    ebuf_.resize(V_);
    return true;
  }

  const std::vector<std::string> &tokens() const { return tokens_; }
  bool has_ent() const { return ent_.ok; }
  bool has_seg() const { return seg_.ok; }
  bool ent_probs(const std::vector<int> &chain, std::vector<float> *out) { return probs(ent_, 0, chain, out); }
  // Segmentation head: out[2 * k + 1] is the chance that a block starts at character k (trained for k >= 1).
  bool seg_probs(const std::vector<int> &chain, std::vector<float> *out) { return probs(seg_, 1, chain, out); }

  // A head (entity or segmentation). Per character k of a sentence (chain[k] = flushed node whose token is character k, so the
  // chain is the sentence's own prefixes): the residual stream after `nova.ent.layer` blocks, LayerNorm without
  // parameters, e_k; input [e_k, e_k+1, e_k+2, has k+1, has k+2] with a missing state 0; Linear -> GELU -> Linear;
  // softmax over the head's labels (entity: O, B-PER, I-PER, B-LOC, I-LOC; segmentation: no cut, cut). out[nout * k + t].
  // The first Linear splits by input block, so each node keeps W_j e (3 x hidden) the first time a head reads it
  // (proj[slot]) and a character costs three additions.
  bool probs(const Head &hd, int slot, const std::vector<int> &chain, std::vector<float> *out) {
    if (!hd.ok) return false;
    const int n = (int)chain.size(), H = hd.h, ld = 3 * D_ + 2, T = hd.nout;
    const float *W1 = (const float *)hd.fc1->data, *b1 = (const float *)hd.fb1->data;
    const float *W2 = (const float *)hd.fc2->data, *b2 = (const float *)hd.fb2->data;
    for (int c : chain) {
      Node &nd = nodes_[c];
      if ((int)nd.e.size() != D_) return false;
      std::vector<float> &proj = nd.proj[slot];
      if (!proj.empty()) continue;
      proj.resize(3 * H);
      for (int j = 0; j < 3; j++)
#ifdef __APPLE__
        cblas_sgemv(CblasRowMajor, CblasNoTrans, H, D_, 1.f, W1 + j * D_, ld, nd.e.data(), 1, 0.f, proj.data() + j * H, 1);
#else
        for (int r = 0; r < H; r++) {
          double acc = 0;
          const float *w = W1 + j * D_ + (size_t)r * ld;
          for (int k = 0; k < D_; k++) acc += (double)w[k] * nd.e[k];
          proj[j * H + r] = (float)acc;
        }
#endif
    }
    out->assign((size_t)n * T, 0.f);
    std::vector<float> pre(H);
    float lg[8];
    for (int k = 0; k < n; k++) {
      const float *p0 = nodes_[chain[k]].proj[slot].data();
      const float *p1 = k + 1 < n ? nodes_[chain[k + 1]].proj[slot].data() + H : nullptr;
      const float *p2 = k + 2 < n ? nodes_[chain[k + 2]].proj[slot].data() + 2 * H : nullptr;
      for (int r = 0; r < H; r++) {
        float v = b1[r] + p0[r];
        if (p1) v += p1[r] + W1[(size_t)r * ld + 3 * D_];
        if (p2) v += p2[r] + W1[(size_t)r * ld + 3 * D_ + 1];
        pre[r] = 0.5f * v * (1.f + std::erf(v * 0.70710678118654752f));
      }
      float mx = -INFINITY, sum = 0;
      for (int t = 0; t < T; t++) {
        lg[t] = b2[t];
        for (int r = 0; r < H; r++) lg[t] += W2[(size_t)t * H + r] * pre[r];
        mx = std::max(mx, lg[t]);
      }
      for (int t = 0; t < T; t++) sum += (lg[t] = std::exp(lg[t] - mx));
      for (int t = 0; t < T; t++) (*out)[(size_t)T * k + t] = lg[t] / sum;
    }
    return true;
  }
  int size() const { return (int)nodes_.size(); }
  int max_pos() const { return npos_; }

  // Drop every node from `keep` on (their KV cells are reused).
  void truncate(int keep) {
    nodes_.resize(keep);
    if (done_ > keep) done_ = keep;
  }

  // parent < 0 starts a root. Returns the node id, or -1 when the tree is full.
  int add(int parent, int tok) {
    if ((int)nodes_.size() >= cap_) return -1;
    int pos = parent < 0 ? 0 : nodes_[parent].pos + 1;
    if (pos >= npos_) return -1;
    nodes_.push_back({parent, pos, tok, 0.f, {}, {}, {}});
    return (int)nodes_.size() - 1;
  }

  // log p(tok | node and its ancestors). The node must be flushed.
  float logp(int node, int tok) {
    const Node &p = nodes_[node];
    const char *src = (const char *)wte_->data + (size_t)tok * wte_->nb[1];
    if (wte_->type == GGML_TYPE_F32) memcpy(row_.data(), src, D_ * sizeof(float));
    else ggml_get_type_traits(wte_->type)->to_float(src, row_.data(), D_);
    float s;
#ifdef __APPLE__
    vDSP_dotpr(row_.data(), 1, p.h.data(), 1, &s, D_);
#else
    double acc = 0;
    for (int k = 0; k < D_; k++) acc += (double)row_[k] * p.h[k];
    s = (float)acc;
#endif
    return s - p.lse;
  }

  // Run all nodes added since the last flush.
  void flush() {
    int c0 = done_, n = (int)nodes_.size() - c0, nkv = (int)nodes_.size();
    if (n <= 0) return;
    ggml_init_params cp{meta_.size(), meta_.data(), true};
    ggml_context *ctx = ggml_init(cp);
    ggml_cgraph *gf = ggml_new_graph_custom(ctx, 4096, false);
    ggml_tensor *tok = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n), *pos = ggml_new_tensor_1d(ctx, GGML_TYPE_I32, n);
    ggml_tensor *mask = ggml_new_tensor_2d(ctx, GGML_TYPE_F16, nkv, n);
    ggml_set_input(tok);
    ggml_set_input(pos);
    ggml_set_input(mask);
    const int hd = D_ / NH_;
    ggml_tensor *x = ggml_add(ctx, ggml_get_rows(ctx, wte_, tok), ggml_get_rows(ctx, wpe_, pos));
    ggml_tensor *ent_x = nullptr;
    char nm[64];
    auto Wl = [&](const char *fmt, int l) { snprintf(nm, sizeof nm, fmt, l); return W(nm); };
    for (int l = 0; l < L_; l++) {
      ggml_tensor *h = ggml_norm(ctx, x, 1e-5f);
      h = ggml_add(ctx, ggml_mul(ctx, h, Wl("blk.%d.attn_norm.weight", l)), Wl("blk.%d.attn_norm.bias", l));
      ggml_tensor *qkv = ggml_add(ctx, ggml_mul_mat(ctx, Wl("blk.%d.attn_qkv.weight", l), h), Wl("blk.%d.attn_qkv.bias", l));
      ggml_tensor *k = ggml_view_2d(ctx, qkv, D_, n, qkv->nb[1], D_ * sizeof(float));
      ggml_tensor *v = ggml_view_2d(ctx, qkv, D_, n, qkv->nb[1], 2 * D_ * sizeof(float));
      ggml_build_forward_expand(gf, ggml_cpy(ctx, k, ggml_view_2d(ctx, kc_[l], D_, n, kc_[l]->nb[1], c0 * kc_[l]->nb[1])));
      ggml_build_forward_expand(gf, ggml_cpy(ctx, v, ggml_view_2d(ctx, vc_[l], D_, n, vc_[l]->nb[1], c0 * vc_[l]->nb[1])));
      ggml_tensor *q = ggml_permute(ctx, ggml_view_3d(ctx, qkv, hd, NH_, n, hd * sizeof(float), qkv->nb[1], 0), 0, 2, 1, 3);
      ggml_tensor *K = ggml_view_3d(ctx, kc_[l], hd, nkv, NH_, kc_[l]->nb[1], hd * kc_[l]->nb[0], 0);
      ggml_tensor *Vv = ggml_view_3d(ctx, vc_[l], hd, nkv, NH_, vc_[l]->nb[1], hd * vc_[l]->nb[0], 0);
      // CPU flash attention skips -inf mask cells, so cost follows the ancestor chain, not the tree size.
      ggml_tensor *a = ggml_flash_attn_ext(ctx, q, K, Vv, mask, 1.f / std::sqrt((float)hd), 0.f, 0.f);
      a = ggml_reshape_2d(ctx, a, D_, n);
      a = ggml_add(ctx, ggml_mul_mat(ctx, Wl("blk.%d.attn_output.weight", l), a), Wl("blk.%d.attn_output.bias", l));
      x = ggml_add(ctx, x, a);
      h = ggml_norm(ctx, x, 1e-5f);
      h = ggml_add(ctx, ggml_mul(ctx, h, Wl("blk.%d.ffn_norm.weight", l)), Wl("blk.%d.ffn_norm.bias", l));
      h = ggml_gelu(ctx, ggml_add(ctx, ggml_mul_mat(ctx, Wl("blk.%d.ffn_up.weight", l), h), Wl("blk.%d.ffn_up.bias", l)));
      h = ggml_add(ctx, ggml_mul_mat(ctx, Wl("blk.%d.ffn_down.weight", l), h), Wl("blk.%d.ffn_down.bias", l));
      x = ggml_add(ctx, x, h);
      if (e_layer_ && l + 1 == e_layer_) {
        ent_x = ggml_norm(ctx, x, 1e-5f);  // F.layer_norm(h, (768,)): no weight, no bias
        ggml_set_output(ent_x);
      }
    }
    x = ggml_norm(ctx, x, 1e-5f);
    x = ggml_add(ctx, ggml_mul(ctx, x, W("output_norm.weight")), W("output_norm.bias"));
    ggml_tensor *logits = ggml_mul_mat(ctx, out_, x);
    ggml_set_output(x);
    ggml_set_output(logits);
    ggml_build_forward_expand(gf, x);
    ggml_build_forward_expand(gf, logits);
    if (ent_x) ggml_build_forward_expand(gf, ent_x);
    ggml_gallocr_alloc_graph(galloc_, gf);

    std::vector<int32_t> tv(n), pv(n);
    std::vector<float> mv((size_t)nkv * n, -INFINITY);
    for (int r = 0; r < n; r++) {
      tv[r] = nodes_[c0 + r].tok;
      pv[r] = nodes_[c0 + r].pos;
      for (int c = c0 + r; c >= 0; c = nodes_[c].parent) mv[(size_t)r * nkv + c] = 0.f;
    }
    ggml_backend_tensor_set(tok, tv.data(), 0, n * sizeof(int32_t));
    ggml_backend_tensor_set(pos, pv.data(), 0, n * sizeof(int32_t));
    std::vector<ggml_fp16_t> mh(mv.size());
    ggml_fp32_to_fp16_row(mv.data(), mh.data(), (int64_t)mv.size());
    ggml_backend_tensor_set(mask, mh.data(), 0, mh.size() * sizeof(ggml_fp16_t));
    ggml_backend_graph_compute(be_, gf);

    const float *hx = (const float *)x->data, *lg = (const float *)logits->data;
    for (int r = 0; r < n; r++) {
      Node &nd = nodes_[c0 + r];
      nd.h.assign(hx + (size_t)r * D_, hx + (size_t)(r + 1) * D_);
      if (ent_x) {
        const float *ex = (const float *)ent_x->data;
        nd.e.assign(ex + (size_t)r * D_, ex + (size_t)(r + 1) * D_);
      }
      const float *row = lg + (size_t)r * V_;
      float mx, sum, neg;
#ifdef __APPLE__
      vDSP_maxv(row, 1, &mx, V_);
      neg = -mx;
      vDSP_vsadd(row, 1, &neg, ebuf_.data(), 1, V_);
      int nv = V_;
      vvexpf(ebuf_.data(), ebuf_.data(), &nv);
      vDSP_sve(ebuf_.data(), 1, &sum, V_);
#else
      mx = row[0];
      for (int k = 1; k < V_; k++) mx = std::max(mx, row[k]);
      neg = -mx;
      double acc = 0;
      for (int k = 0; k < V_; k++) {
        ebuf_[k] = std::exp(row[k] + neg);
        acc += ebuf_[k];
      }
      sum = (float)acc;
#endif
      nd.lse = mx + std::log(sum);
    }
    ggml_free(ctx);
    done_ = nkv;
  }

 private:
  ggml_tensor *W(const char *n) const {
    ggml_tensor *t = ggml_get_tensor(rctx_, n);
    return t ? t : ggml_get_tensor(wctx_, n);
  }

  struct Node {
    int parent, pos, tok;
    float lse;
    std::vector<float> h;
    std::vector<float> e;        // heads: layer-norm'd residual stream after e_layer_ blocks
    std::vector<float> proj[2];  // its three projections per head (0 entity, 1 segmentation), lazy
  };
  // Tensors fc1.w [hidden, 3D+2], fc1.bias, fc2.w [nout, hidden], fc2.bias, all F32.
  bool bind(Head &hd, const char *pre) {
    char nm[32];
    auto get = [&](const char *s) { snprintf(nm, sizeof nm, "%s.%s", pre, s); return W(nm); };
    hd.fc1 = get("fc1.w"); hd.fb1 = get("fc1.bias"); hd.fc2 = get("fc2.w"); hd.fb2 = get("fc2.bias");
    return hd.fc1 && hd.fb1 && hd.fc2 && hd.fb2 && hd.layer >= 1 && hd.layer < L_ && hd.h > 0 && hd.nout <= 8 &&
           hd.fc1->type == GGML_TYPE_F32 && hd.fc2->type == GGML_TYPE_F32 && hd.fb1->type == GGML_TYPE_F32 &&
           hd.fb2->type == GGML_TYPE_F32 && hd.fc1->ne[0] == 3 * D_ + 2 && hd.fc1->ne[1] == hd.h &&
           hd.fc2->ne[0] == hd.h && hd.fc2->ne[1] == hd.nout && hd.fb1->ne[0] == hd.h && hd.fb2->ne[0] == hd.nout;
  }
  int L_ = 0, D_ = 0, NH_ = 0, V_ = 0, npos_ = 0, cap_ = 0, done_ = 0;
  ggml_backend_t be_ = nullptr;
  ggml_context *wctx_ = nullptr, *rctx_ = nullptr, *kctx_ = nullptr;
  ggml_backend_buffer_t wbuf_ = nullptr, rbuf_ = nullptr, kbuf_ = nullptr;
  ggml_gallocr_t galloc_ = nullptr;
  ggml_tensor *wte_ = nullptr, *wpe_ = nullptr, *out_ = nullptr;
  Head ent_, seg_;
  int e_layer_ = 0;  // layer whose residual stream nodes keep for the heads; 0 = none
  std::vector<ggml_tensor *> kc_, vc_;
  std::vector<Node> nodes_;
  std::vector<std::string> tokens_;
  std::vector<char> meta_;
  std::vector<float> row_, ebuf_;
};

}  // namespace nova_lm
