// nova_lm_filter: GPT-2 decides which blocks of the nova tree are orange and what their first
// alternative is.
//
// Runs after lua_filter@*nova_sentences, which writes the tree (property nova_tree, one block per
// line, format in nova_sentences.lua) and yields the decoder's sentence first, then up to five
// more whole sentences. This filter scores, with GPT-2 and the last committed characters as left
// context:
//   - the first `sentences` of those sentences, and
//   - `beam` sentences from a GPT-2 beam search that picks, at every syllable, any single
//     character with that 2-key code (from charmap). The beam ignores the decoder's word
//     segmentation, so it finds 太长 where the decoder only has the word 台长.
// A softmax over the sentence scores gives every block the share of sentences that agree with it
// (他/她/它, 的/地/得, 其他/其它 count as the same text). A block whose share is below `tau` is
// orange ("u" flag); the best other text at its place becomes its first overview alternative.
// Evaluation over 26 domains (top5 + beam5, tau 0.075): 90% of orange blocks are wrong, 73% of
// wrong blocks are orange, and for 71% of wrong blocks the first alternative is right.
//
// The tree of scored prefixes lives in a KV cache (tree_lm.h), so each keystroke runs only the
// prefixes it adds. The context is run once, when text is committed.
//
// With `repick` on, a block GPT-2 would write differently (its share is below `repick_tau` and
// another text has a larger share) takes that text: the first candidate and the tree change, and
// the decoder's text becomes the alternative. Blocks nova_sentences froze (s flag) and blocks the
// user chose stay as they are, and so do blocks with an abbreviated syllable (full-pinyin `nh`, see
// kWildcard); they are still marked orange and keep GPT-2's alternative. Off unless nova_lm/repick is set; nova.schema.yaml turns it on.
// Typed key by key over the same 26 domains
// (repick_tau 0.2): whole sentences right 57.4% -> 77.3%, 1387 sentences fixed and 96 broken of
// 6486; the last two characters change half as often while typing; p99 per key 11.5 -> 11.7 ms.
// What is still wrong is then rarely orange (73.7% -> 8.5% of wrong blocks at tau 0.075): sentences
// that are wrong with no orange on a wrong block go from 9.9% to 20.0%. A simulated user fixing
// 541 sentences with the real keys presses 1134 -> 870 keys.
//
// The model is uer's GPT-2 trained further on Nova's text (README). Typed key by key over the 26
// domains with repick on, it takes whole sentences right 77.9% -> 80.5%. A beam of 20 instead of 5
// then gives 82.2% (150 sentences fixed, 43 broken of 6486), 88% instead of 80% of orange blocks
// wrong, and the same per-key time (541 sentences, p99 4.4 ms). At 40 the prefix tree comes close to
// its 2048 nodes; a full tree starts its prefixes over, and if they still do not fit, that key is
// not scored.
//
// A key that leaves the input as it was (a pick, or Up/Down) makes nova_sentences decode what
// follows the picked word again, and that can lose a word that was right (范围|跟 -> 范伟|根 with
// a user dictionary). The sentence of the last key, with the chosen blocks written in, joins the
// scored sentences on such a key, so GPT-2 decides between the old text and the new decode. Not
// after [ or ] (nova_redecode): there the user asked for the old characters to go.
//
// 的/地/得 typed `de` count as one text for the shares, so the decoder's choice among them used to
// stand: it has 得 right 71.9% of the time and almost never writes 地 (2655 places of the 6486 eval
// sentences). With repick on, while such a syllable is one of the last three, the sentence is also
// scored with each of the other two there, and the best one is shown when it beats the decoder's:
// by any margin toward 地 or 得, by more than 2 nats toward 的. GPT-2 learnt from web text, which
// writes 的 for all three, so a small lead for 的 over the decoder's 得 is that habit, not grammar
// (5 of 7 such places wrong by the standard usage, 19 of 19 right above 2 nats), and a small lead for
// 地 or 得 over 的 goes against the habit (17 of 20 right under 0.5 nats). Two characters after the place are
// enough: 97.1% of places right by the set's labels (decoder 94.8%; 的 98.2, 地 64.9, 得 89.9), the
// same with six. Of the 32 changes against a label, 24 are the set writing 的 for 地/得.
// A `de` that is the last syllable stays out of 地/得: they attach to the word after them, and of
// the 5 sentences ending so in the replay, 4 were wrong.
// Further back the character of the last key stays, so text the user has typed past does not
// change (and a pick, which decodes what follows it again, cannot turn a 的 that was right into 得).
// Typing the 6486 sentences key by key: 得 right at 73.9 -> 79.4% of its places, 的 97.6 -> 97.8%;
// 39 sentences fixed and 22 broken by the set's labels, 14 of the 22 being the set writing 的 where
// the standard usage is 地/得; a 的/地/得 more than three characters back changed 61 -> 1 times.
// With the particle 地 typed `de` (41 sentences, the set types it `di`): 9.5 -> 64.3% of 42 places.
// Per-key time unchanged (541 sentences, mean 5.1 ms, p99 11.3 ms either way).
//
// Schema options (all under nova_lm/): enabled, model (GGUF, relative to the user or shared data
// directory), charmap (`code \t chars` per line), rare (`rare_share \t x` first, then
// `code \t character \t share` per reading, see score()), reading_weight, tau, sentences, beam,
// threads, context, drop_orange_context, repick, repick_tau, entity, entity_threshold, debug.
// With debug on, property nova_lm holds the time this filter took and every block's share, and
// a test can set property nova_lm_history to replace the committed text ("-" for none); the
// environment then overrides the schema: NOVA_REPICK=<repick_tau> turns repick on,
// NOVA_REPICK_FROZEN=1 lets it change frozen blocks too, NOVA_READING=<reading_weight>, and
// NOVA_DE_MARGIN=<toward 地/得>[,<toward 的>] (negative leaves 的/地/得 alone), NOVA_ENTITY=<entity_threshold>
// turns entity on (NOVA_ENT_DUMP=<file> appends the head's probabilities per final first choice).
//
// Entity (off by default; needs a model with the entity head, else it stays off): person and place names as one
// block. A small head in the GGUF (nova.ent.*, f32) tags every character of the final first choice O/B-PER/I-PER/
// B-LOC/I-LOC from the residual stream after nova.ent.layer blocks, LayerNorm without parameters, of the character
// and the next two (see TreeLM::ent_probs). A name is 2..6 characters whose tags are B then I of one kind and whose
// least probability is >= entity_threshold. After repick and before the orange marks, the blocks it crosses are cut
// at its ends on syllable boundaries and the blocks inside are joined (text unchanged, mark '&'; debug line
// ents=<joined>/<cut>, <cut> always 0 now). A name inside one block is not cut out of it: in eval0-3 that broke as many
// right words (中美洲, 惠灵顿, 拉脱维亚) as it fixed. A name is left alone when it touches a chosen, focused, aux, abbreviated
// or typo block, or a boundary nova_sentences took from nova_bounds, or when joining would stop a frozen block from
// being frozen on the next key (it takes the largest age and share of the pieces, at least age 2 over frozen ones),
// or would freeze text of the last decoder word, which nova_sentences keeps open while it may still change.
// The head needs the state of the whole first choice, so its last character is run through the model once per key.
// Creating nova_lm/debug.on in the user data directory turns on nova_lm/debug.log (see log_line).

#include <rime/candidate.h>
#include <rime/common.h>
#include <rime/composition.h>
#include <rime/config.h>
#include <rime/context.h>
#include <rime/deployer.h>
#include <rime/engine.h>
#include <rime/filter.h>
#include <rime/registry.h>
#include <rime/schema.h>
#include <rime/service.h>
#include <rime/translation.h>
#include <rime_api.h>

#ifndef _WIN32
#include <dlfcn.h>
#endif
#include <sys/stat.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <ctime>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <fstream>
#include <functional>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>
#include <unordered_map>

#include "tree_lm.h"

namespace nova_lm {

using std::string;
using std::u32string;
using std::vector;

// UTF-8 ---------------------------------------------------------------------

static u32string decode(const string &s) {
  u32string out;
  for (size_t i = 0; i < s.size();) {
    unsigned char c = s[i];
    int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    char32_t cp = n == 1 ? c : c & (0x7f >> n);
    for (int k = 1; k < n && i + k < s.size(); k++) cp = (cp << 6) | (s[i + k] & 0x3f);
    out.push_back(cp);
    i += n;
  }
  return out;
}

static string encode(const u32string &s) {
  string out;
  for (char32_t c : s) {
    if (c < 0x80) {
      out += (char)c;
    } else if (c < 0x800) {
      out += (char)(0xc0 | (c >> 6));
      out += (char)(0x80 | (c & 0x3f));
    } else if (c < 0x10000) {
      out += (char)(0xe0 | (c >> 12));
      out += (char)(0x80 | ((c >> 6) & 0x3f));
      out += (char)(0x80 | (c & 0x3f));
    } else {
      out += (char)(0xf0 | (c >> 18));
      out += (char)(0x80 | ((c >> 12) & 0x3f));
      out += (char)(0x80 | ((c >> 6) & 0x3f));
      out += (char)(0x80 | (c & 0x3f));
    }
  }
  return out;
}

// Same classes as the evaluation: 他/她/它, 的/地/得, 其他/其它.
static u32string norm(u32string s) {
  for (auto &c : s) {
    if (c == U'她' || c == U'它') c = U'他';
    else if (c == U'地' || c == U'得') c = U'的';
  }
  return s;  // 其它 becomes 其他 through 它
}

static const char32_t kDe[] = {U'的', U'地', U'得'};
static bool is_de(char32_t c) { return c == U'的' || c == U'地' || c == U'得'; }

static vector<string> split(const string &s, char sep) {
  vector<string> out;
  size_t from = 0;
  for (size_t at; (at = s.find(sep, from)) != string::npos; from = at + 1) out.push_back(s.substr(from, at - from));
  out.push_back(s.substr(from));
  return out;
}

// Wildcard of an abbreviated syllable in full-pinyin mode (nova_quanpin.lua): the initial's key and
// this letter, `nVhV` for 你好 typed nh. It is two characters like a full syllable and takes no aux
// letters. No character, rare reading or 的/地/得 key is spelled so: `allowed` has no such code and
// is_rare, reading_lp and the `de` check find nothing. A block with such a syllable is never re-picked
// (Block::abbr): repick_tau was set on candidates that share one code, where GPT-2's probability
// concentrates; for an abbreviation the candidates are different words, the mass is spread, conf is
// almost always under tau, and GPT-2 would override the dictionary's and the user's first choice.
static constexpr char kWildcard = 'V';

// Syllables of a block key, as nova_sentences.lua cuts them: two lowercase letters, then up to two
// uppercase aux letters, or a lowercase letter and the wildcard. Returns the 2-letter codes, or
// nothing if the key does not parse.
static vector<string> codes_of(const string &key) {
  vector<string> out;
  for (size_t i = 0; i < key.size();) {
    if (i + 1 >= key.size() || !islower(key[i])) return {};
    if (key[i + 1] == kWildcard) {
      out.push_back(key.substr(i, 2));
      i += 2;
      continue;
    }
    if (!islower(key[i + 1])) return {};
    out.push_back(key.substr(i, 2));
    i += 2;
    for (int k = 0; k < 2 && i < key.size() && isupper(key[i]); k++) i++;
  }
  return out;
}

// Length in bytes of every syllable of a block key (two letters, its aux letters or the wildcard), or nothing if
// the key does not parse. codes_of() cuts the same way.
static vector<size_t> syllable_lens(const string &key) {
  vector<size_t> out;
  for (size_t i = 0; i < key.size();) {
    if (i + 1 >= key.size() || !islower(key[i])) return {};
    size_t n = 2;
    if (key[i + 1] != kWildcard) {
      if (!islower(key[i + 1])) return {};
      for (; n < 4 && i + n < key.size() && isupper(key[i + n]); n++) {}
    }
    out.push_back(n);
    i += n;
  }
  return out;
}

// Model shared by all sessions --------------------------------------------

struct Model {
  TreeLM lm;
  std::unordered_map<char32_t, int> vocab;  // single-character tokens
  int cls = 101, unk = 100;
  std::unordered_map<string, vector<std::pair<int, char32_t>>> allowed;  // code -> (token, char)
  std::unordered_map<string, u32string> rare;  // code -> characters for which it is a rare reading, see score()
  bool is_rare(const string &key, char32_t c) const {
    auto it = rare.find(key.substr(0, 2));
    return it != rare.end() && it->second.find(c) != u32string::npos;
  }
  // code + character -> ln of the reading's share of the character, for characters with several
  // readings (nova_rare.txt); absent means one reading, 0.
  std::unordered_map<string, float> reading;
  float reading_lp(const string &key, char32_t c) const {
    if (reading.empty()) return 0.f;
    auto it = reading.find(key.substr(0, 2) + encode(u32string(1, c)));
    return it == reading.end() ? 0.f : it->second;
  }
  // Word counts of nova_lexicon.txt (`#total \t n` first, then `word \t count`), the list nova_sentences.lua cuts long
  // decoder words with. Here it re-cuts blocks whose text GPT-2 changed, see resegment(). Empty without the file.
  std::unordered_map<u32string, uint32_t> lexicon;
  double lexicon_log_total = 0;
  const void *owner = nullptr;  // filter whose tree is in the KV cache
};

static std::mutex g_mutex;
static std::shared_ptr<Model> g_model;
static std::atomic<bool> g_loading{false};
static string g_loaded_from;

// Debug log: <user data dir>/nova_lm/debug.log, written only while nova_lm/debug.on exists, so it
// can be switched on and off without redeploying. It holds what is typed (committed text, the
// sentence being composed, every block's share), so it stays off by default. Kept under 4 MB:
// the old log moves to debug.log.1.
static std::mutex g_log_mutex;

static string log_dir() {
  return (rime::Service::instance().deployer().user_data_dir / "nova_lm").string();
}

static bool log_on() {
  struct stat st;
  return ::stat((log_dir() + "/debug.on").c_str(), &st) == 0;
}

static void log_line(const string &line) {
  if (!log_on()) return;
  std::lock_guard<std::mutex> lock(g_log_mutex);
  string path = log_dir() + "/debug.log";
  struct stat st;
  if (::stat(path.c_str(), &st) == 0 && st.st_size > (4 << 20)) ::rename(path.c_str(), (path + ".1").c_str());
  std::ofstream out(path, std::ios::app);
  if (!out) return;
  auto now = std::chrono::system_clock::now();
  std::time_t t = std::chrono::system_clock::to_time_t(now);
  int ms = (int)(std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count() % 1000);
  char stamp[32];
  std::strftime(stamp, sizeof stamp, "%m-%d %H:%M:%S", std::localtime(&t));
  char frac[8];
  std::snprintf(frac, sizeof frac, ".%03d", ms);
  out << stamp << frac << '\t' << line << '\n';
}

static string resolve(const string &file) {
#ifdef _WIN32
  if (file.empty() || rime::path(file).is_absolute()) return file;
#else
  if (file.empty() || file[0] == '/') return file;
#endif
  auto &deployer = rime::Service::instance().deployer();
  for (const auto &dir : {deployer.user_data_dir, deployer.shared_data_dir}) {
    auto p = dir / file;
    if (std::ifstream(p.string()).good()) return p.string();
  }
  return "";
}

// The packaged app keeps the ggml CPU backends in a nova-lm folder next to this plugin.
static string backend_dir() {
#ifdef _WIN32
  return "";  // ggml and its CPU backend are linked into the plugin, nothing to load
#else
  Dl_info info;
  if (!dladdr((const void *)&backend_dir, &info) || !info.dli_fname) return "";
  string self = info.dli_fname;
  return self.substr(0, self.rfind('/') + 1) + "nova-lm";
#endif
}

// `nova_lm/entity` of the filter built last (every deploy builds them again), before the model loads: the entity head
// costs time on every key, so a model loaded without the wish does not compute it. See model() for switching it.
static std::atomic<bool> g_want_ent{false};
static bool g_loaded_ent = false;  // the wish g_loaded_from was loaded with

static std::shared_ptr<Model> load_model(const string &model_path, const string &charmap_path, const string &rare_path,
                                         const string &lexicon_path, int threads, int cap, bool want_ent) {
  auto m = std::make_shared<Model>();
  string line;
  if (!lexicon_path.empty()) {
    std::ifstream lex_in(lexicon_path);
    while (std::getline(lex_in, line)) {
      size_t tab = line.find('\t');
      if (tab == string::npos) continue;
      if (line.compare(0, tab, "#total") == 0) {
        double total = atof(line.c_str() + tab + 1);
        if (total > 0) m->lexicon_log_total = std::log(total);
        continue;
      }
      long count = atol(line.c_str() + tab + 1);
      if (count > 0) m->lexicon.emplace(decode(line.substr(0, tab)), (uint32_t)count);
    }
    if (m->lexicon_log_total <= 0) m->lexicon.clear();
  }
  std::ifstream rare_in(rare_path);
  // First `rare_share \t x`: a reading with a share under x is rare; without that line none is.
  // Then `code \t character \t share` per reading. scripts/wanxiang/rare_readings.py writes both.
  double rare_share = 0;
  while (std::getline(rare_in, line)) {
    if (line.empty() || line[0] == '#') continue;
    vector<string> f = split(line, '\t');
    if (f.size() == 2 && f[0] == "rare_share") {
      rare_share = atof(f[1].c_str());
      continue;
    }
    if (f.size() < 3 || f[0].size() != 2) continue;
    double share = atof(f[2].c_str());
    if (share <= 0) continue;
    m->reading[f[0] + f[1]] = (float)std::log(share);
    if (share < rare_share) m->rare[f[0]] += decode(f[1]);
  }
  if (!m->lm.load(model_path, threads, cap, backend_dir(), want_ent, true)) return nullptr;
  const auto &toks = m->lm.tokens();
  for (int i = 0; i < (int)toks.size(); i++) {
    u32string t = decode(toks[i]);
    if (toks[i] == "[CLS]") m->cls = i;
    else if (toks[i] == "[UNK]") m->unk = i;
    else if (t.size() == 1) m->vocab.emplace(t[0], i);
  }
  std::ifstream in(charmap_path);
  while (std::getline(in, line)) {
    auto tab = line.find('\t');
    if (tab != 2) continue;
    auto &list = m->allowed[line.substr(0, 2)];
    for (char32_t c : decode(line.substr(tab + 1))) {
      auto it = m->vocab.find(c);
      if (it != m->vocab.end() && !m->is_rare(line, c)) list.emplace_back(it->second, c);
    }
  }
  return m->allowed.empty() ? nullptr : m;
}

// Load in the background the first time; the filter passes everything through until it is ready.
// After `nova_lm/entity` is switched and redeployed, the model is loaded again in the background, with or without the
// entity head; the old one serves until then.
static std::shared_ptr<Model> model(const string &model_path, const string &charmap_path, const string &rare_path,
                                    const string &lexicon_path, int threads) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const bool want_ent = g_want_ent.load();
  if (g_loading || model_path.empty() || charmap_path.empty()) return g_model;
  // one attempt per path and wish, so a broken file is not reloaded on every key
  if (g_loaded_from == model_path ? g_loaded_ent == want_ent : g_model != nullptr) return g_model;
  g_loading = true;
  g_loaded_from = model_path;
  g_loaded_ent = want_ent;
  std::thread([=] {
    auto t0 = std::chrono::steady_clock::now();
    auto m = load_model(model_path, charmap_path, rare_path, lexicon_path, threads, 2048, want_ent);
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    log_line(string(m ? "load ok " : "load FAILED ") + model_path + " " + std::to_string((int)ms) + "ms");
    std::lock_guard<std::mutex> lock(g_mutex);
    if (m || !g_model) g_model = m;  // a failed reload keeps the model that works
    g_loading = false;
  }).detach();
  return g_model;
}

// Filter ---------------------------------------------------------------------

class NovaLmFilter : public rime::Filter {
 public:
  explicit NovaLmFilter(const rime::Ticket &ticket) : Filter(ticket) {
    rime::Config *config = engine_->schema() ? engine_->schema()->config() : nullptr;
    if (config) {
      config->GetBool("nova_lm/enabled", &enabled_);
      config->GetBool("nova_lm/debug", &debug_);
      config->GetString("nova_lm/model", &model_file_);
      config->GetString("nova_lm/charmap", &charmap_file_);
      config->GetString("nova_lm/rare", &rare_file_);
      config->GetDouble("nova_lm/tau", &tau_);
      config->GetInt("nova_lm/sentences", &sentences_);
      config->GetInt("nova_lm/beam", &beam_);
      config->GetInt("nova_lm/threads", &threads_);
      config->GetInt("nova_lm/context", &context_chars_);
      config->GetBool("nova_lm/drop_orange_context", &drop_orange_);
      config->GetBool("nova_lm/repick", &repick_);
      config->GetDouble("nova_lm/repick_tau", &repick_tau_);
      config->GetDouble("nova_lm/reading_weight", &reading_w_);
      config->GetBool("nova_lm/entity", &entity_);
      config->GetDouble("nova_lm/entity_threshold", &entity_thr_);
    }
    if (debug_) {
      if (const char *e = getenv("NOVA_REPICK")) {
        repick_ = true;
        repick_tau_ = atof(e);
      }
      repick_frozen_ = getenv("NOVA_REPICK_FROZEN") != nullptr;
      if (const char *e = getenv("NOVA_ENTITY")) {  // <threshold>: merge person and place names into one block
        entity_ = true;
        entity_thr_ = atof(e);
      }
      if (const char *e = getenv("NOVA_READING")) reading_w_ = atof(e);
      if (const char *e = getenv("NOVA_DE_MARGIN")) {  // `to 地/得[,to 的]`; negative: leave 的/地/得 alone
        de_margin_ = (float)atof(e);
        if (const char *comma = strchr(e, ',')) de_margin_plain_ = (float)atof(comma + 1);
      }
    }
    if (!enabled_) return;
    model_file_ = resolve(model_file_);
    charmap_file_ = resolve(charmap_file_);
    rare_file_ = resolve(rare_file_);
    lexicon_file_ = resolve(lexicon_file_);
    g_want_ent = entity_;
    model(model_file_, charmap_file_, rare_file_, lexicon_file_, threads_);
    if (ready()) announce(engine_->context());
    commit_ =engine_->context()->commit_notifier().connect([this](rime::Context *ctx) {
      // Orange blocks committed unchanged stay out of the context: a wrong word there makes GPT-2
      // sure of the same wrong word the next time it is typed (两代 for 两袋).
      u32string text = decode(ctx->GetCommitText());
      vector<bool> drop(text.size(), false);
      size_t at = shown_top_.empty() ? u32string::npos : text.rfind(shown_top_);
      if (drop_orange_ && at != u32string::npos)
        for (auto [a, b] : shown_orange_)
          for (size_t i = a; i < b; i++) drop[at + i] = true;
      shown_top_.clear();
      shown_orange_.clear();
      last_ages_.clear();
      last_marks_.clear();
      prev_top_.clear();
      last_top_.clear();
      prev_input_.clear();
      u32string dropped;
      for (size_t i = 0; i < text.size(); i++) {
        char32_t c = text[i];
        if (c == U' ' || c == U'\t' || c == U'\n') continue;
        if (drop[i]) {
          dropped.push_back(c);
          continue;
        }
        history_.push_back(c);
      }
      if (history_.size() > 256) history_.erase(0, history_.size() - 256);
      if (log_on()) {
        size_t from = history_.size() > (size_t)context_chars_ ? history_.size() - context_chars_ : 0;
        log_line("commit\t" + ctx->GetCommitText() + "\tcontext=" + encode(history_.substr(from)) +
                 (dropped.empty() ? "" : "\tdropped=" + encode(dropped)));
      }
      // The context pass runs here, on the commit key, so the next sentence's first key stays fast.
      if (auto m = ready()) {
        std::lock_guard<std::mutex> lock(g_mutex);
        prepare(*m);
      }
    });
  }

  ~NovaLmFilter() override { commit_.disconnect(); }

  rime::an<rime::Translation> Apply(rime::an<rime::Translation> translation, rime::CandidateList *candidates) override {
    if (!enabled_) return translation;
    auto m = ready();
    rime::Context *ctx = engine_->context();
    if (!m || !ctx) {
      if (ctx && log_on()) log_line("key\t" + ctx->input() + "\tmodel not ready");
      return translation;
    }
    announce(ctx);
    auto t0 = std::chrono::steady_clock::now();
    if (debug_) {  // tests set the left context directly
      string forced = ctx->get_property("nova_lm_history");
      if (!forced.empty()) {
        history_.clear();
        for (char32_t c : decode(forced == "-" ? "" : forced))
          if (c != U' ' && c != U'\t' && c != U'\n' && c != U'\u3000') history_.push_back(c);
        ctx->set_property("nova_lm_history", "");
        std::lock_guard<std::mutex> lock(g_mutex);
        prepare(*m);
      }
    }
    // Take the first candidate and the whole sentences after it; nova_sentences writes the tree
    // while yielding the first one.
    auto head = rime::New<rime::FifoTranslation>();
    vector<rime::an<rime::Candidate>> taken;
    vector<u32string> sentences;
    for (int i = 0; !translation->exhausted() && i < sentences_; i++) {
      auto cand = translation->Peek();
      if (!cand || (i > 0 && cand->type() != "sentence")) break;
      taken.push_back(cand);
      sentences.push_back(decode(cand->text()));
      translation->Next();
    }
    auto t1 = std::chrono::steady_clock::now();
    string tree = ctx->get_property("nova_tree");
    // nova_redecode is `from:to:input`, valid while the input is the one it was written for.
    string redecode = ctx->get_property("nova_redecode");
    size_t colon = redecode.find(':');
    if (colon != string::npos) colon = redecode.find(':', colon + 1);
    bool shrunk = colon != string::npos && redecode.substr(colon + 1) == ctx->input();
    carry_ = ctx->input() == prev_input_ && !shrunk ? prev_top_ : u32string();
    prev_input_ = ctx->input();
    last_top_ = prev_top_;
    prev_top_.clear();
    shown_top_.clear();
    shown_orange_.clear();
    swaps_ = 0;
    resegments_ = 0;
    retexted_ = false;
    if (tree.size() > 1) {
      std::lock_guard<std::mutex> lock(g_mutex);
      string out, info;
      bool ok = rewrite(*m, tree, sentences, &out, &info);
      bool logging = log_on();
      if (logging) {
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t1).count();
        double pull = std::chrono::duration<double, std::milli>(t1 - t0).count();
        char times[64];
        std::snprintf(times, sizeof times, "lm=%.1fms pull=%.1fms", ms, pull);
        log_line("key\t" + ctx->input() + "\t" + (ok ? info.substr(info.find_first_not_of(' ')) : "rewrite failed") + "\t" + times);
      }
      if (ok) {
        ctx->set_property("nova_tree", out);
        // Re-picked blocks and 的/地/得: the first candidate (what space commits) carries the same text as the tree.
        if (retexted_ && !taken.empty())
          taken[0] = rime::New<rime::SimpleCandidate>(taken[0]->type(), taken[0]->start(), taken[0]->end(),
                                                      encode(shown_top_), taken[0]->comment(), taken[0]->preedit());
        if (debug_) {
          // first number: GPT-2 work; pull= time the upstream filters took to yield their sentences
          auto t2 = std::chrono::steady_clock::now();
          double ms = std::chrono::duration<double, std::milli>(t2 - t1).count();
          double pull = std::chrono::duration<double, std::milli>(t1 - t0).count();
          ctx->set_property("nova_lm", std::to_string(ms) + "ms pull=" + std::to_string(pull) + info);
        }
      }
    }
    for (const auto &cand : taken) head->Append(cand);
    return head + translation;
  }

 private:
  struct Beam {
    u32string text;
    float score;
  };
  struct Block {
    vector<string> fields;
    size_t a, b;  // characters [a, b) of the sentence
    bool chosen, focus, aux;  // aux: nova_sentences lists what the typed aux code leaves (x flag)
    bool frozen, swapped = false;  // frozen: s flag; swapped: re-picked on this key
    bool de = false;  // a 的/地/得 of the block is not the decoder's, see the header
    bool abbr = false;  // has an abbreviated syllable (second character kWildcard): not re-picked
    char mark = 0;      // '&' merged by the entity head, '%' cut out of a larger block, see merge_entities
    float conf = 1.f;
    u32string alt;
  };

  std::shared_ptr<Model> ready() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_model;
  }

  // nova_sentences leaves the orange marks and the order of typo fixes to this filter only once
  // property nova_lm_ready is "1"; with the plugin or the model missing it keeps doing both.
  void announce(rime::Context *ctx) {
    if (announced_ || !ctx) return;
    announced_ = true;
    ctx->set_property("nova_lm_ready", "1");
  }

  int token(const Model &m, char32_t c) const {
    if (c >= U'A' && c <= U'Z') c += 32;  // the BERT tokenizer lowercases
    auto it = m.vocab.find(c);
    return it == m.vocab.end() ? m.unk : it->second;
  }

  // Put [CLS] + the last context characters in the KV cache, unless they are already there.
  void prepare(Model &m) {
    vector<int> want{m.cls};
    size_t from = history_.size() > (size_t)context_chars_ ? history_.size() - context_chars_ : 0;
    for (size_t i = from; i < history_.size(); i++) want.push_back(token(m, history_[i]));
    if (m.owner == this && want == context_) return;
    m.lm.truncate(0);
    int parent = -1;
    for (int t : want) parent = m.lm.add(parent, t);
    m.lm.flush();
    m.owner = this;
    context_ = want;
    tail_ = parent;
    reset_tree();
  }

  void reset_tree() {
    prefixes_.clear();
    beams_.assign(1, {{U"", 0.f}});
    beam_keys_.clear();
  }

  // Node of a candidate prefix; adds missing ancestors. -1 when the tree is full.
  int node(Model &m, const u32string &prefix) {
    if (prefix.empty()) return tail_;
    auto it = prefixes_.find(prefix);
    if (it != prefixes_.end()) return it->second;
    int parent = node(m, prefix.substr(0, prefix.size() - 1));
    if (parent < 0) return -1;
    int id = m.lm.add(parent, token(m, prefix.back()));
    if (id >= 0) prefixes_.emplace(prefix, id);
    return id;
  }

  // Log-probability of a whole sentence. Every proper prefix must be in the tree and flushed.
  //
  // A Chinese character outside the vocabulary is scored as [UNK], which stands for every such
  // character at once and so gets far more probability than any one of them deserves: 奀我知道了
  // beat 嗯我知道了. Such a character counts as kUnseen at most, below any in-vocabulary homophone,
  // so it stays only where every candidate has one. `words` exempts the characters the decoder put
  // there inside a word of two or more (暴殄天物, 山莨菪碱): the dictionary vouches for those.
  //
  // The same cap holds for a character typed with a rare reading of it (nova_rare.txt): GPT-2 sees
  // only the characters, so 是从 (从 read zòng, 140 against 1294801 for cōng) read better to it than
  // 失踪 for uizs and was re-picked. The decoder had 失踪 first; 万象 keeps such readings so they can
  // be typed, and leaves the order to the word weights GPT-2 does not see. `keys` holds the code of
  // each place; inside a word of the decoder's (放纵, 首都) the reading is not touched.
  //
  // Outside such a word every typed character also gets reading_weight * ln P(code | character),
  // the share of that reading among the character's single-character weights: the decoder's side
  // of the score, which GPT-2 alone does not see. Characters with one reading get 0.
  float score(Model &m, const u32string &s, const u32string *words = nullptr, const vector<string> *keys = nullptr) {
    float total = 0;
    for (size_t k = 0; k < s.size(); k++) {
      int tok = token(m, s[k]);
      float lp = m.lm.logp(node(m, s.substr(0, k)), tok);
      bool in_word = words && k < words->size() && (*words)[k] == s[k];
      bool unseen = tok == m.unk && is_han(s[k]) && !in_word;
      bool typed = keys && k < keys->size() && !in_word && (*keys)[k].size() == 2;  // not chosen by the user
      bool rare = typed && m.is_rare((*keys)[k], s[k]);
      total += unseen || rare ? std::min(lp, kUnseen) : lp;
      if (typed) total += reading_w_ * m.reading_lp((*keys)[k], s[k]);
    }
    return total;
  }
  static constexpr float kUnseen = -20.f;  // nats
  static bool is_han(char32_t c) {
    return (c >= 0x3400 && c <= 0x9fff) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0x20000 && c <= 0x3ffff);
  }

  // Typo fixes from nova_sentences come as alternatives of the t line, each
  // `text\x1f\x1fto\x1ffrom\x1fcode\x1fkind\x1fsentence`: the corrected code, the kind of edit
  // (n neighbour key, s swapped keys, d extra key, i missing key) and the whole decoded sentence.
  // GPT-2 scores the sentences; the best kTypoAlts stay, without the last two parts.
  void rerank_typo(Model &m, string &line) {
    vector<string> fields = split(line, '\t');
    if (fields.size() <= 5) return;
    struct Fix { string field; float score; };
    vector<Fix> fixes;
    vector<u32string> sentences;
    for (size_t k = 5; k < fields.size(); k++) {
      vector<string> p = split(fields[k], '\x1f');
      if (p.size() < 7 || p[6].empty()) return;  // not from a GPT-2-aware nova_sentences: keep as is
      sentences.push_back(decode(p[6]));
      fixes.push_back({p[0] + "\x1f\x1f" + p[2] + "\x1f" + p[3] + "\x1f" + p[4], kTypoCost(p[5][0])});
    }
    auto add = [&] {
      for (const auto &s : sentences)
        for (size_t k = 0; k < s.size(); k++)
          if (node(m, s.substr(0, k)) < 0) return false;
      return true;
    };
    if (!add()) {  // tree full: keep the context, start the prefixes over
      m.lm.truncate((int)context_.size());
      reset_tree();
      if (!add()) return;
    }
    m.lm.flush();
    const char *dump_path = getenv("NOVA_FIX_DUMP");
    FILE *dump = dump_path ? fopen(dump_path, "a") : nullptr;
    for (size_t i = 0; i < fixes.size(); i++) {
      float lp = score(m, sentences[i]);
      if (dump) {
        vector<string> p = split(fields[5 + i], '\x1f');
        fprintf(dump, "%s\t#lm\t%s\t%s\t%zu\t%.3f\n", fields[3].c_str(), p[4].c_str(), p[5].c_str(), sentences[i].size(), lp);
      }
      fixes[i].score = lp + kTypoPerChar * sentences[i].size() - fixes[i].score;
    }
    if (dump) fclose(dump);
    std::stable_sort(fixes.begin(), fixes.end(), [](const Fix &a, const Fix &b) { return a.score > b.score; });
    fields.resize(5);
    for (size_t i = 0; i < fixes.size() && i < (size_t)kTypoAlts; i++) fields.push_back(fixes[i].field);
    std::ostringstream os;
    for (size_t k = 0; k < fields.size(); k++) os << (k ? "\t" : "") << fields[k];
    line = os.str();
  }
  static constexpr int kTypoAlts = 3;
  static constexpr float kTypoPerChar = 0.0f;  // nats per character, offsets length differences
  static float kTypoCost(char kind) { return kind == 'n' || kind == 's' ? 1.0f : 2.5f; }

  // Adds every proper prefix of the sentences and the current beam; false when the tree is full.
  bool add_all(Model &m, const vector<u32string> &sentences, size_t step) {
    for (const auto &s : sentences)
      for (size_t k = 1; k < s.size(); k++)
        if (node(m, s.substr(0, k)) < 0) return false;
    for (const auto &b : beams_[step])
      if (node(m, b.text) < 0) return false;
    return true;
  }

  // Code-constrained beam from the longest still-valid step to the end. Steps whose code (or
  // chosen character) has not changed since the last key are reused.
  bool run_beam(Model &m, const vector<string> &keys, const vector<std::pair<int, char32_t>> &fixed) {
    size_t step = 0;
    while (step < keys.size() && step < beam_keys_.size() && keys[step] == beam_keys_[step] && step + 1 < beams_.size())
      step++;
    beams_.resize(step + 1);
    beam_keys_.resize(step);
    beam_from_ = (int)step;
    for (; step < keys.size(); step++) {
      for (const auto &b : beams_[step])
        if (node(m, b.text) < 0) return false;
      m.lm.flush();
      vector<std::pair<int, char32_t>> one;
      const vector<std::pair<int, char32_t>> *options = &one;
      if (fixed[step].second) {
        one.push_back(fixed[step]);
      } else {
        auto it = m.allowed.find(keys[step].substr(0, 2));
        if (it == m.allowed.end()) {
          beams_.resize(step + 1);  // no character has this code: the beam stops here
          return true;
        }
        options = &it->second;
      }
      vector<Beam> next;
      for (const auto &b : beams_[step]) {
        int parent = node(m, b.text);
        for (const auto &[tok, c] : *options) {
          float s = b.score + m.lm.logp(parent, tok);
          if (!fixed[step].second) s += reading_w_ * m.reading_lp(keys[step], c);
          if ((int)next.size() == beam_ && s <= next.back().score) continue;
          u32string text = b.text;
          text.push_back(c);
          auto at = std::upper_bound(next.begin(), next.end(), s, [](float v, const Beam &x) { return v > x.score; });
          next.insert(at, {std::move(text), s});
          if ((int)next.size() > beam_) next.pop_back();
        }
      }
      beams_.push_back(std::move(next));
      beam_keys_.push_back(keys[step]);
    }
    return true;
  }

  // Names, see the header. `pr` holds the five tag probabilities of every character of `top` (O, B-PER, I-PER, B-LOC,
  // I-LOC). Names are cut by the rule the head was trained with (retrain distill/ner_ltp.py spans): B starts one, I of the
  // same type continues it, an I after anything else starts one, fewer than two characters is none; kept when the least
  // probability of the chosen tags inside is at least entity_threshold; at most kEntityMax characters.
  // A name touching a block the user chose, the focused block, one narrowed by aux letters, or one with an abbreviated
  // syllable stays as it is. Blocks are cut only at syllable boundaries of a key that is the typed input (a key the input
  // does not spell letter by letter cannot be cut). Only the blocks change, never a character.
  // A block that nova_sentences would freeze on the next key (frozen_lines: not the last, two characters or more, share
  // at least 50 or age at least 2, outside the last decoder word) must end in a block that it freezes too, else the name
  // is left alone: one character would otherwise be decoded again, or merged with the last block, and the frozen text
  // would change. The reverse holds too: characters of the last decoder word, which nova_sentences leaves open because
  // the next syllables may still change the whole word, must not end in a block it freezes (a name that starts before
  // that word and would be frozen whole is left alone). The merged block takes the larger age and share of its parts,
  // at least the age a frozen block needs if any part was frozen. Marks: '&' two or more blocks made one; '%' (a name
  // cut out of one block) is no longer made.
  void merge_entities(Model &m, vector<Block> &blocks, const u32string &top, const vector<float> &pr, size_t typo_lines,
                      const std::function<double(Block &)> &assess, int *merged, int *split_out) {
    const size_t n = top.size();
    if (pr.size() != 5 * n) return;
    vector<int> tag(n);
    vector<float> conf(n);
    for (size_t k = 0; k < n; k++) {
      int t = 0;
      for (int j = 1; j < 5; j++)
        if (pr[5 * k + j] > pr[5 * k + t]) t = j;
      tag[k] = t;
      conf[k] = pr[5 * k + t];
    }
    vector<std::pair<size_t, size_t>> names;
    for (size_t i = 0; i < n;) {
      if (!tag[i]) {
        i++;
        continue;
      }
      int kind = tag[i] <= 2 ? 1 : 3;
      size_t j = i + 1;
      while (j < n && tag[j] == kind + 1) j++;
      float least = 1.f;
      for (size_t k = i; k < j; k++) least = std::min(least, conf[k]);
      if (j - i >= 2 && j - i <= kEntityMax && least >= entity_thr_) names.emplace_back(i, j);
      i = j;
    }
    if (names.empty()) return;

    // The last decoder word, as nova_sentences keeps it in nova_tree_groups: its blocks are not frozen.
    long long open_from = -1;
    if (typo_lines == 0) {
      rime::Context *ctx = engine_->context();
      string groups = ctx ? ctx->get_property("nova_tree_groups") : "";
      string last_to = blocks.back().fields[2];
      for (const auto &line : split(groups, '\n')) {
        size_t colon = line.find(':');
        if (colon != string::npos && line.substr(colon + 1) == last_to) open_from = atoll(line.c_str());
      }
    }
    std::set<string> used_bounds;  // `byte offset:left code:right code` lines of nova_bounds_used: the offsets
    if (rime::Context *ctx = engine_->context())
      for (const auto &line : split(ctx->get_property("nova_bounds_used"), '\n')) {
        size_t colon = line.find(':');
        if (colon != string::npos) used_bounds.insert(line.substr(0, colon));
      }
    auto share_of = [](const Block &b) {
      auto parts = split(b.fields[4], '\x1f');
      return parts.size() > 1 ? atoi(parts[1].c_str()) : 0;
    };
    auto age_of = [](const Block &b) {
      size_t at = b.fields[0].find('a');
      return at == string::npos ? 0 : atoi(b.fields[0].c_str() + at + 1);
    };
    // Would nova_sentences freeze this block on the next key, were it block `i` of `list`?
    auto freezes = [&](const vector<Block> &list, size_t i, bool by_value) {
      const Block &b = list[i];
      return i + 1 < list.size() + typo_lines && b.b - b.a >= 2 && !(open_from >= 0 && atoll(b.fields[1].c_str()) >= open_from) &&
             (!by_value || share_of(b) >= 50 || age_of(b) >= 2);
    };
    // A block's piece [lo, hi) of its characters: block with the key, bytes and text of the piece.
    auto piece = [&](const Block &src, size_t lo, size_t hi) {
      vector<size_t> lens = syllable_lens(src.fields[3]);
      size_t from = atol(src.fields[1].c_str()), off_lo = 0, off_hi = 0;
      for (size_t k = 0; k < hi; k++) {
        if (k < lo) off_lo += lens[k];
        off_hi += lens[k];
      }
      Block nb = src;
      nb.fields = {string("0") + (src.frozen ? "s" : "") + "a" + std::to_string(age_of(src)), std::to_string(from + off_lo),
                   std::to_string(from + off_hi), src.fields[3].substr(off_lo, off_hi - off_lo), ""};
      nb.a = src.a + lo;
      nb.b = src.a + hi;
      nb.fields[4] = encode(top.substr(nb.a, nb.b - nb.a)) + "\x1f" + std::to_string(share_of(src));
      nb.alt.clear();
      nb.mark = 0;
      return nb;
    };
    auto cuttable = [&](const Block &b) {
      vector<size_t> lens = syllable_lens(b.fields[3]);
      return lens.size() == b.b - b.a && b.fields[3].size() == (size_t)(atol(b.fields[2].c_str()) - atol(b.fields[1].c_str()));
    };

    for (auto [x, y] : names) {
      size_t p = blocks.size(), q = 0;
      for (size_t i = 0; i < blocks.size(); i++)
        if (blocks[i].a < y && blocks[i].b > x) {
          if (p == blocks.size()) p = i;
          q = i;
        }
      if (p == blocks.size()) continue;
      if (p == q) continue;  // already one block, or inside one block: not cut out (see the header)
      bool skip = false;
      for (size_t i = p; i <= q; i++) skip = skip || blocks[i].chosen || blocks[i].focus || blocks[i].aux || blocks[i].abbr;
      const bool cut_l = blocks[p].a < x, cut_r = blocks[q].b > y;
      // A boundary nova_sentences took from nova_bounds (the user's [ ] choices) is forgotten at commit when no
      // block edge is left there, so a name is not merged across one.
      for (size_t i = p; i < q; i++) skip = skip || used_bounds.count(blocks[i].fields[2]);
      if (skip || (cut_l && !cuttable(blocks[p])) || (cut_r && !cuttable(blocks[q]))) continue;
      // frozen text must stay frozen
      bool was_frozen = false;
      for (size_t i = p; i <= q; i++) was_frozen = was_frozen || freezes(blocks, i, true);
      vector<Block> made;  // what replaces blocks p..q
      if (cut_l) made.push_back(piece(blocks[p], 0, x - blocks[p].a));
      Block e = piece(blocks[p], x - blocks[p].a, p == q ? y - blocks[p].a : blocks[p].b - blocks[p].a);
      bool all_frozen = blocks[p].frozen;
      int age = age_of(blocks[p]), share = share_of(blocks[p]);
      for (size_t i = p + 1; i <= q; i++) {
        Block t = piece(blocks[i], 0, i == q ? y - blocks[i].a : blocks[i].b - blocks[i].a);
        e.fields[2] = t.fields[2];
        e.fields[3] += t.fields[3];
        e.swapped = e.swapped || blocks[i].swapped;
        e.de = e.de || blocks[i].de;
        all_frozen = all_frozen && blocks[i].frozen;
        age = std::max(age, age_of(blocks[i]));
        share = std::max(share, share_of(blocks[i]));
      }
      e.b = y;
      e.frozen = all_frozen;
      if (was_frozen) age = std::max(age, 2);
      e.fields[0] = string("0") + (all_frozen ? "s" : "") + "a" + std::to_string(age);
      e.fields[4] = encode(top.substr(x, y - x)) + "\x1f" + std::to_string(share);
      e.mark = q > p ? '&' : '%';
      made.push_back(std::move(e));
      if (cut_r) made.push_back(piece(blocks[q], y - blocks[q].a, blocks[q].b - blocks[q].a));
      vector<Block> view(blocks.begin(), blocks.begin() + p);  // the blocks as they would be after the change
      view.insert(view.end(), made.begin(), made.end());
      view.insert(view.end(), blocks.begin() + q + 1, blocks.end());
      bool ok = true;
      for (size_t i = 0; i < made.size(); i++)
        for (size_t j = p; j <= q; j++) {
          if (blocks[j].a >= made[i].b || blocks[j].b <= made[i].a) continue;
          if (freezes(blocks, j, true) && !freezes(view, p + i, false)) ok = false;
          // text of the last decoder word stays open
          if (open_from >= 0 && atoll(blocks[j].fields[1].c_str()) >= open_from && freezes(view, p + i, true)) ok = false;
        }
      if (!ok) continue;
      for (auto &b : made) assess(b);
      blocks.erase(blocks.begin() + p, blocks.begin() + q + 1);
      blocks.insert(blocks.begin() + p, made.begin(), made.end());
      (made.size() > 0 && made[cut_l ? 1 : 0].mark == '&' ? *merged : *split_out)++;
    }
  }
  static constexpr size_t kEntityMax = 6;

  // A re-picked block keeps the edges of the decoder's words: for zjuibuuixm the decoder has 咱|时不时|先, GPT-2
  // re-picks 暂, 时不实 and 现, and 时不实 is no word. Every run of adjacent re-picked blocks that holds such a block
  // (two characters or more, not in nova_lexicon.txt) is cut again into lexicon words by count, as lexicon_split in
  // nova_sentences.lua does: 暂时|不|实现. Blocks GPT-2 left alone keep their edges: the lexicon has no 王毅 or 过道里,
  // which the decoder and the entity head put together. Only the blocks change, never a character. Runs stop at
  // blocks the user chose, the focused block, blocks narrowed by aux letters, frozen ones, ones with an abbreviated
  // syllable or a key the input does not spell letter by letter, and at boundaries from nova_bounds.
  //
  // With the segmentation head in the model file, its cuts replace the lexicon's: the head tags the final first
  // sentence (a block starts at character k when its chance is 0.5 or more), and a run is cut again wherever a word
  // of the head joins characters of two blocks. The head knows names and words outside the lexicon.
  void resegment(Model &m, vector<Block> &blocks, const u32string &top, const std::function<double(Block &)> &assess) {
    if (blocks.size() < 2) return;
    vector<bool> head_cut;  // per character of top: a block starts here, by the segmentation head; empty = lexicon
    if (m.lm.has_seg()) {
      bool any_swapped = false;
      for (const auto &b : blocks) any_swapped = any_swapped || b.swapped;
      if (!any_swapped) return;
      vector<int> chain;
      vector<float> pr;
      bool ok = true;
      for (size_t k = 1; ok && k <= top.size(); k++) {
        int id = node(m, top.substr(0, k));
        if (id < 0) ok = false;
        else chain.push_back(id);
      }
      if (ok) m.lm.flush();
      if (ok && m.lm.seg_probs(chain, &pr)) {
        head_cut.assign(top.size() + 1, true);
        for (size_t k = 1; k < top.size(); k++) head_cut[k] = pr[2 * k + 1] >= 0.5f;
      }
    }
    if (head_cut.empty() && m.lexicon.empty()) return;
    auto known = [&](const u32string &w) { return m.lexicon.count(w) > 0; };
    std::set<string> used_bounds;
    if (rime::Context *ctx = engine_->context())
      for (const auto &line : split(ctx->get_property("nova_bounds_used"), '\n')) {
        size_t colon = line.find(':');
        if (colon != string::npos) used_bounds.insert(line.substr(0, colon));
      }
    auto age_of = [](const Block &b) {
      size_t at = b.fields[0].find('a');
      return at == string::npos ? 0 : atoi(b.fields[0].c_str() + at + 1);
    };
    auto free_block = [&](const Block &b) {
      vector<size_t> lens = syllable_lens(b.fields[3]);
      return !b.chosen && !b.focus && !b.aux && !b.abbr && !b.frozen && !b.mark && lens.size() == b.b - b.a &&
             b.fields[3].size() == (size_t)(atol(b.fields[2].c_str()) - atol(b.fields[1].c_str()));
    };
    auto broken = [&](const Block &b) {
      return b.swapped && b.b - b.a >= 2 && !known(top.substr(b.a, b.b - b.a));
    };
    for (size_t p = 0; p < blocks.size(); p++) {
      if (!free_block(blocks[p])) continue;
      size_t q = p;
      while (q + 1 < blocks.size() && free_block(blocks[q + 1]) && !used_bounds.count(blocks[q].fields[2]) &&
             blocks[q].swapped && blocks[q + 1].swapped)
        q++;
      bool any = !head_cut.empty();  // the head: the word check below decides
      for (size_t i = p; i <= q; i++) any = any || broken(blocks[i]);
      if (!any) {
        p = q;
        continue;
      }
      const size_t x0 = blocks[p].a, n = blocks[q].b - x0;
      vector<size_t> cuts;  // word ends, relative to x0
      if (!head_cut.empty()) {
        for (size_t j = 1; j <= n; j++)
          if (j == n || head_cut[x0 + j]) cuts.push_back(j);
      } else {
        // Best cut of the run's text: sum of ln(count / total) per word; a single character not in the list counts 1.
        vector<double> best(n + 1, -INFINITY);
        vector<size_t> from(n + 1, 0);
        best[0] = 0;
        for (size_t i = 0; i < n; i++) {
          if (best[i] == -INFINITY) continue;
          for (size_t j = i + 1; j <= n && j - i <= kWordMax; j++) {
            auto it = m.lexicon.find(top.substr(x0 + i, j - i));
            double count = it != m.lexicon.end() ? it->second : (j - i == 1 ? 1 : 0);
            if (count <= 0) continue;
            double s = best[i] + std::log(count) - m.lexicon_log_total;
            if (s > best[j]) {
              best[j] = s;
              from[j] = i;
            }
          }
        }
        for (size_t j = n; j > 0; j = from[j]) cuts.push_back(j);
        std::reverse(cuts.begin(), cuts.end());
      }
      // Byte offset in the input and key of every character of the run.
      vector<size_t> at{(size_t)atol(blocks[p].fields[1].c_str())};
      vector<string> keys;
      vector<int> ages;
      vector<bool> swapped;
      for (size_t i = p; i <= q; i++) {
        size_t off = 0;
        for (size_t len : syllable_lens(blocks[i].fields[3])) {
          keys.push_back(blocks[i].fields[3].substr(off, len));
          off += len;
          at.push_back(at.back() + len);
          ages.push_back(age_of(blocks[i]));
          swapped.push_back(blocks[i].swapped);
        }
      }
      // The new cut is taken only where a lexicon word joins characters of two blocks (暂+时, 实+现): the blocks such
      // words touch take it, the others keep their edges. A block that is no word is not just split (所租, 林炎).
      vector<bool> hit(q - p + 1, false);
      auto block_of = [&](size_t rel) {
        size_t i = p;
        while (blocks[i].b <= x0 + rel) i++;
        return i - p;
      };
      {
        size_t lo = 0;
        for (size_t hi : cuts) {
          size_t first = block_of(lo), last = block_of(hi - 1);
          if (first != last)
            for (size_t i = first; i <= last; i++) hit[i] = true;
          lo = hi;
        }
      }
      if (std::find(hit.begin(), hit.end(), true) == hit.end()) {
        p = q;
        continue;
      }
      auto make = [&](size_t lo, size_t hi) {
        Block nb = blocks[p];
        nb.a = x0 + lo;
        nb.b = x0 + hi;
        string key;
        int age = 0;
        bool sw = false;
        for (size_t k = lo; k < hi; k++) {
          key += keys[k];
          age = std::max(age, ages[k]);
          sw = sw || swapped[k];
        }
        nb.fields = {"0a" + std::to_string(age), std::to_string(at[lo]), std::to_string(at[hi]), key,
                     encode(top.substr(nb.a, nb.b - nb.a)) + "\x1f"};
        nb.swapped = sw;
        nb.de = false;
        nb.alt.clear();
        assess(nb);
        return nb;
      };
      vector<Block> made;
      for (size_t i = 0; i <= q - p; i++) {
        if (!hit[i]) {
          made.push_back(blocks[p + i]);
          continue;
        }
        size_t k = i;
        while (k + 1 <= q - p && hit[k + 1]) k++;
        size_t lo = blocks[p + i].a - x0, gh = blocks[p + k].b - x0;
        for (size_t hi : cuts)
          if (hi > lo && hi <= gh) {
            made.push_back(make(lo, hi));
            lo = hi;
          }
        i = k;
      }
      const size_t count = made.size();
      blocks.erase(blocks.begin() + p, blocks.begin() + q + 1);
      blocks.insert(blocks.begin() + p, std::make_move_iterator(made.begin()), std::make_move_iterator(made.end()));
      resegments_++;
      p += count - 1;
    }
  }
  static constexpr size_t kWordMax = 8;

  bool rewrite(Model &m, const string &tree, vector<u32string> sentences, string *out, string *info) {
    vector<Block> blocks;
    vector<string> keys;  // code of each syllable, plus the chosen character when the block is chosen
    vector<std::pair<int, char32_t>> fixed;
    u32string top;
    // Typo tail (t flag): raw letters after a syllable that does not parse, with corrected codes
    // from nova_sentences as alternatives. Passed through as is; GPT-2 does not score it.
    vector<string> typo_lines;
    bool typo_alts = false;
    for (const auto &line : split(tree, '\n')) {
      if (line.empty()) continue;
      Block blk;
      blk.fields = split(line, '\t');
      if (blk.fields.size() < 5) return false;
      const string &flags = blk.fields[0];
      if (flags.find('t') < flags.find('a')) {
        typo_lines.push_back(line);
        typo_alts = typo_alts || blk.fields.size() > 5;
        continue;
      }
      blk.chosen = flags[0] == '1';
      blk.focus = flags.find('f') < flags.find('a');
      blk.aux = flags.find('x') < flags.find('a');
      blk.frozen = flags.find('s') < flags.find('a');
      vector<string> codes = codes_of(blk.fields[3]);
      u32string text = decode(split(blk.fields[4], '\x1f')[0]);
      if (codes.empty() || codes.size() != text.size()) return false;
      for (const auto &c : codes) blk.abbr = blk.abbr || c[1] == kWildcard;
      blk.a = top.size();
      blk.b = blk.a + text.size();
      for (size_t k = 0; k < codes.size(); k++) {
        keys.push_back(blk.chosen ? codes[k] + encode(text.substr(k, 1)) : codes[k]);
        fixed.emplace_back(blk.chosen ? std::make_pair(token(m, text[k]), text[k]) : std::make_pair(0, U'\0'));
      }
      top += text;
      blocks.push_back(std::move(blk));
    }
    if (blocks.empty() || top.size() + context_.size() + 2 > (size_t)m.lm.max_pos()) return false;
    const u32string given = top;  // the tree's text, before anything here changes it
    // 的/地/得, see the header. `recent` are the places still open to GPT-2.
    vector<std::pair<size_t, Block *>> recent;
    if (repick_ && de_margin_ >= 0)
      for (auto &blk : blocks) {
        if (blk.chosen || blk.aux || blk.focus || blk.frozen) continue;
        for (size_t k = blk.a; k < blk.b; k++) {
          if (keys[k] != "de" || !is_de(top[k])) continue;
          if (k + kDeWindow >= top.size()) {
            recent.emplace_back(k, &blk);
          } else if (k < last_top_.size() && is_de(last_top_[k]) && last_top_[k] != top[k]) {
            top[k] = last_top_[k];
            blk.de = true;
          }
        }
      }
    sentences.erase(std::remove_if(sentences.begin(), sentences.end(), [&](const u32string &s) { return s.size() != top.size(); }),
                    sentences.end());
    if (std::find(sentences.begin(), sentences.end(), top) == sentences.end()) sentences.insert(sentences.begin(), top);
    for (const auto &[k, blk] : recent)
      for (char32_t c : kDe)
        if (c != top[k]) {
          u32string v = top;
          v[k] = c;
          if (std::find(sentences.begin(), sentences.end(), v) == sentences.end()) sentences.push_back(std::move(v));
        }
    if (carry_.size() == top.size()) {  // see the header: the last key's sentence around the chosen blocks
      u32string carry = carry_;
      for (const auto &blk : blocks)
        if (blk.chosen) carry.replace(blk.a, blk.b - blk.a, top, blk.a, blk.b - blk.a);
      if (std::find(sentences.begin(), sentences.end(), carry) == sentences.end()) sentences.push_back(carry);
    }

    prepare(m);
    for (int attempt = 0;; attempt++) {
      size_t step = 0;
      while (step < keys.size() && step < beam_keys_.size() && keys[step] == beam_keys_[step] && step + 1 < beams_.size())
        step++;
      bool ok = add_all(m, sentences, std::min(step, beams_.size() - 1)) && run_beam(m, keys, fixed);
      if (ok) break;
      if (attempt) return false;
      m.lm.truncate((int)context_.size());  // tree full: keep the context, start the prefixes over
      reset_tree();
    }
    // The entity head reads the first sentence whole, so its last node goes into this flush too. Without room in the
    // tree the head is skipped on this key (see below); the orange marks and repicks go on.
    if (entity_ && m.lm.has_ent() && !sentences.empty()) node(m, sentences.front());
    m.lm.flush();

    // Sentence scores: decoder sentences and full-length beam sentences, without duplicates.
    std::unordered_map<u32string, float> scored;
    u32string words(top.size(), U'\0');  // see score()
    for (const auto &blk : blocks)
      if (blk.b - blk.a > 1) words.replace(blk.a, blk.b - blk.a, top, blk.a, blk.b - blk.a);
    for (const auto &s : sentences) scored.emplace(s, score(m, s, &words, &keys));
    if (beams_.size() == top.size() + 1)
      for (const auto &b : beams_.back()) scored.emplace(b.text, b.score);
    float best = -INFINITY;
    for (const auto &[s, v] : scored) best = std::max(best, v);
    double z = 0;
    for (const auto &[s, v] : scored) z += std::exp(v - best);

    // nova_sentences counts how long a block has kept its text and freezes it after two syllables.
    // It decodes a re-picked block back to the decoder's text on every key, so the count for the
    // re-picked text is kept here: `step` is 1 when a syllable was completed since the last key.
    if (keys.size() < last_syllables_) last_ages_.clear();
    int step = keys.size() != last_syllables_ ? 1 : 0;
    // A block whose text is not the decoder's: the count goes on from the last key, and the
    // word-frequency share goes, it was the decoder text's.
    auto retext = [&](Block &blk, const u32string &t) {
      string text = encode(t);
      auto age = last_ages_.find(blk.fields[1] + ":" + blk.fields[2] + ":" + text);
      string &flags = blk.fields[0];
      flags = flags.substr(0, flags.find('a')) + "a" + std::to_string(age == last_ages_.end() ? 0 : age->second + step);
      blk.fields[4] = text + "\x1f";
    };
    {
      const u32string decoded = top;  // each place is judged against the decoder's sentence
      float mine = scored[decoded];
      for (const auto &[k, blk] : recent) {
        float most = -INFINITY;
        for (char32_t c : kDe) {
          u32string v = decoded;
          v[k] = c;
          auto it = scored.find(v);
          if (c == decoded[k] || it == scored.end()) continue;
          if (c != U'的' && k + 1 == decoded.size()) continue;  // 地 and 得 go before a word: not yet typed, not yet judged
          if (it->second > mine + (c == U'的' ? de_margin_plain_ : de_margin_) && it->second > most) {
            most = it->second;
            top[k] = c;
            blk->de = true;
          }
        }
      }
    }
    // Share of the sentences that agree with the block's text, and the best other text (its alternative).
    // Returns that other text's share.
    auto assess = [&](Block &blk) {
      std::unordered_map<u32string, double> mass;
      std::unordered_map<u32string, std::pair<double, u32string>> shown;  // class -> (weight, text)
      for (const auto &[s, v] : scored) {
        u32string part = s.substr(blk.a, blk.b - blk.a);
        double w = std::exp(v - best) / z;
        u32string cls = norm(part);
        mass[cls] += w;
        auto &sh = shown[cls];
        if (w > sh.first) sh = {w, part};
      }
      u32string cur = top.substr(blk.a, blk.b - blk.a), mine = norm(cur);
      blk.conf = (float)mass[mine];
      double alt_mass = 0;
      blk.alt.clear();
      for (const auto &[cls, w] : mass)
        if (cls != mine && w > alt_mass) {
          alt_mass = w;
          blk.alt = shown[cls].second;
        }
      // Classes merge 的/地/得 and 他/她/它, so the alternative may swap 地 for 的 where the user's
      // text already had the right one (用力地区 -> 用力的去). Keep the shown character there:
      // it was typed with the same code, and the one-key fix should change only what differs.
      if (blk.alt.size() == cur.size())
        for (size_t k = 0; k < cur.size(); k++)
          if (blk.alt[k] != cur[k] && norm(u32string(1, blk.alt[k])) == norm(u32string(1, cur[k])))
            blk.alt[k] = cur[k];
      return alt_mass;
    };
    for (auto &blk : blocks) {
      if (blk.chosen) continue;
      if (blk.de) retext(blk, top.substr(blk.a, blk.b - blk.a));
      double alt_mass = assess(blk);
      u32string cur = top.substr(blk.a, blk.b - blk.a);
      if (repick_ && !blk.aux && !blk.abbr && !blk.focus && (!blk.frozen || repick_frozen_) && blk.alt.size() == cur.size() &&
          blk.conf < repick_tau_ && alt_mass > blk.conf) {
        top.replace(blk.a, cur.size(), blk.alt);
        retext(blk, blk.alt);
        blk.alt = cur;
        blk.conf = (float)alt_mass;
        blk.swapped = true;
        swaps_++;
      }
    }
    if (repick_) resegment(m, blocks, top, assess);

    // Person and place names, see the header: the entity head tags the final first sentence, and a name that
    // two or more blocks share is made one block.
    int ent_merged = 0, ent_split = 0;
    const bool entity_on = entity_ && m.lm.has_ent();
    double ent_flush_ms = 0;
    auto ent_t0 = std::chrono::steady_clock::now();
    if (entity_on && blocks.size() > 1) {
      vector<int> chain;
      vector<float> pr;
      bool ok = true;
      for (size_t k = 1; ok && k <= top.size(); k++) {
        int id = node(m, top.substr(0, k));
        if (id < 0) ok = false;
        else chain.push_back(id);
      }
      if (ok) m.lm.flush();
      ent_flush_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - ent_t0).count();
      ok = ok && m.lm.ent_probs(chain, &pr);
      if (ok) {
        if (const char *dump_path = debug_ ? getenv("NOVA_ENT_DUMP") : nullptr) {
          if (FILE *dump = fopen(dump_path, "a")) {
            size_t from = history_.size() > (size_t)context_chars_ ? history_.size() - context_chars_ : 0;
            fprintf(dump, "%s\t%s\t", encode(history_.substr(from)).c_str(), encode(top).c_str());
            for (size_t i = 0; i < pr.size(); i++) fprintf(dump, i ? " %.6f" : "%.6f", pr[i]);
            fprintf(dump, "\n");
            fclose(dump);
          }
        }
        merge_entities(m, blocks, top, pr, typo_lines.size(), assess, &ent_merged, &ent_split);
      }
    }
    const double ent_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - ent_t0).count();
    if (entity_on)  // a block merged on an earlier key keeps its mark while it stays the same block
      for (auto &blk : blocks)
        if (!blk.mark) {
          auto it = last_marks_.find(blk.fields[1] + ":" + blk.fields[2] + ":" + encode(top.substr(blk.a, blk.b - blk.a)));
          if (it != last_marks_.end()) blk.mark = it->second;
        }

    // Orange blocks get the GPT-2 alternative first. Overview alternatives share nine number
    // keys, two per block: orange blocks first (least sure first), then purple ones as before.
    const int kAlts = 2, kLabels = 9;
    vector<int> order;
    for (int i = 0; i < (int)blocks.size(); i++) order.push_back(i);
    // Blocks narrowed by an aux code keep nova_sentences' list and all the labels: the user is
    // choosing there right now, so no orange and no alternatives elsewhere.
    auto orange = [&](const Block &b) { return !b.chosen && !b.aux && b.conf < tau_; };
    bool any_aux = typo_alts;
    for (const auto &b : blocks) any_aux = any_aux || b.aux;
    std::stable_sort(order.begin(), order.end(), [&](int x, int y) {
      if (blocks[x].aux != blocks[y].aux) return blocks[x].aux;
      bool ox = orange(blocks[x]), oy = orange(blocks[y]);
      if (ox != oy) return ox;
      return ox && blocks[x].conf < blocks[y].conf;
    });
    int labels = 0;
    for (int i : order) {
      Block &blk = blocks[i];
      string &flags = blk.fields[0];
      size_t age = flags.find('a');
      string head = flags.substr(0, age), tail = age == string::npos ? "" : flags.substr(age);
      bool purple = head.find('c') != string::npos, had_overview = head.find('o') != string::npos;
      // The panel draws purple over orange, so a block GPT-2 marks orange drops nova_sentences'
      // purple flag: orange is the measured signal (90% of orange blocks are wrong).
      string kept;
      for (char c : head)
        if (c != 'o' && c != 'u' && !(c == 'c' && (orange(blk) || blk.swapped))) kept += c;
      if (blk.aux) {
        flags = kept + (had_overview ? "o" : "") + tail;
        labels += (int)blk.fields.size() - 5;
        continue;
      }
      if (blk.focus) {  // the focused block's paged list stays as nova_sentences made it
        if (orange(blk)) kept += 'u';
        flags = kept + tail;
        continue;
      }
      vector<string> alts;
      string own = split(blk.fields[4], '\x1f')[0];
      if (orange(blk) && !blk.alt.empty()) alts.push_back(encode(blk.alt) + "\x1f\x1f" + blk.fields[2]);
      if (had_overview && (orange(blk) || purple))
        for (size_t k = 5; k < blk.fields.size() && (int)alts.size() < kAlts; k++) {
          string alt = split(blk.fields[k], '\x1f')[0];
          if (alt != (blk.alt.empty() ? "" : encode(blk.alt)) && alt != own) alts.push_back(blk.fields[k]);
        }
      if (any_aux || alts.empty() || labels + (int)alts.size() > kLabels) alts.clear();
      labels += (int)alts.size();
      if (!alts.empty()) kept += 'o';
      if (orange(blk)) kept += 'u';
      if (blk.mark) kept += blk.mark;
      flags = kept + tail;
      blk.fields.resize(5);
      blk.fields.insert(blk.fields.end(), alts.begin(), alts.end());
    }

    std::ostringstream os, dbg;
    for (size_t i = 0; i < blocks.size(); i++) {
      if (i) os << '\n';
      for (size_t k = 0; k < blocks[i].fields.size(); k++) os << (k ? "\t" : "") << blocks[i].fields[k];
      // per block: text=share% ('!' orange, '*' chosen by the user, '^' re-picked, '~' 的/地/得 changed), then /alternative
      dbg << ' ' << encode(top.substr(blocks[i].a, blocks[i].b - blocks[i].a)) << (blocks[i].chosen ? "*" : orange(blocks[i]) ? "!" : "")
          << (blocks[i].swapped ? "^" : "") << (blocks[i].de ? "~" : "") << (blocks[i].mark ? string(1, blocks[i].mark) : "") << '=' << (int)(100 * blocks[i].conf);
      if (!blocks[i].alt.empty()) dbg << '/' << encode(blocks[i].alt);
    }
    dbg << " flags=";  // what the panel gets, block by block
    for (size_t i = 0; i < blocks.size(); i++) dbg << (i ? "," : "") << blocks[i].fields[0];
    dbg << " swaps=" << swaps_ << " recut=" << resegments_ << " tau=" << (int)(1000 * tau_) << "e-3 from=" << beam_from_ << "/" << keys.size() << " nodes=" << m.lm.size() << " sentences=" << scored.size();
    if (entity_on) dbg << " ents=" << ent_merged << "/" << ent_split << " ent_ms=" << ent_flush_ms << "+" << ent_ms - ent_flush_ms;
    for (auto &line : typo_lines) {
      rerank_typo(m, line);
      os << '\n' << line;
    }
    *out = os.str();
    *info = dbg.str();
    last_ages_.clear();
    for (const auto &blk : blocks) {
      const string &flags = blk.fields[0];
      size_t at = flags.find('a');
      last_ages_[blk.fields[1] + ":" + blk.fields[2] + ":" + split(blk.fields[4], '\x1f')[0]] = at == string::npos ? 0 : atoi(flags.c_str() + at + 1);
    }
    last_syllables_ = keys.size();
    last_marks_.clear();
    for (const auto &blk : blocks)
      if (blk.mark) last_marks_[blk.fields[1] + ":" + blk.fields[2] + ":" + encode(top.substr(blk.a, blk.b - blk.a))] = blk.mark;
    shown_top_ = top;
    prev_top_ = top;
    retexted_ = top != given;
    for (const auto &blk : blocks)
      if (orange(blk)) shown_orange_.emplace_back(blk.a, blk.b);
    return true;
  }

  bool enabled_ = false, debug_ = false;
  string model_file_ = "nova_lm/gpt2.gguf", charmap_file_ = "nova_lm/charmap.tsv", rare_file_ = "nova_rare.txt";
  string lexicon_file_ = "nova_lexicon.txt";  // same file nova_sentences.lua reads
  double tau_ = 0.075;
  int sentences_ = 5, beam_ = 5, threads_ = 4, context_chars_ = 30;
  bool drop_orange_ = true;  // nova_lm/drop_orange_context
  bool repick_ = false, repick_frozen_ = false;
  double repick_tau_ = 0.2;
  bool entity_ = false;  // nova_lm/entity: merge person and place names, needs a model with the entity head
  double entity_thr_ = 0.8;  // nova_lm/entity_threshold: least probability of any character's tag inside a name
  std::unordered_map<string, char> last_marks_;  // `from:to:text` of the blocks marked '&' or '%' on the last key
  double reading_w_ = 0;  // weight of ln P(code | character), see score()
  bool announced_ = false;  // nova_lm_ready is set, see announce()
  int swaps_ = 0;  // blocks re-picked on the last key
  int resegments_ = 0;  // runs of blocks cut again on the last key, see resegment()
  // Blocks of the last key (`from:to:text`) and how many syllables each has kept its text.
  std::unordered_map<string, int> last_ages_;
  size_t last_syllables_ = 0;
  rime::connection commit_;
  u32string history_;
  // The first sentence of the last key and its orange blocks (offsets into it), for the commit.
  u32string shown_top_;
  vector<std::pair<size_t, size_t>> shown_orange_;
  // The input and first sentence of the last key, and that sentence when this key kept the input.
  string prev_input_;
  u32string prev_top_, carry_;
  u32string last_top_;  // the first sentence of the last key, whatever its input was
  float de_margin_ = 0.f, de_margin_plain_ = 2.f;  // nats toward 地/得 and toward 的, see the header; NOVA_DE_MARGIN with debug
  bool retexted_ = false;  // this key's first sentence is not the tree's text
  static constexpr size_t kDeWindow = 3;  // a `de` syllable is open while it is one of the last three
  vector<int> context_;
  int tail_ = -1, beam_from_ = 0;
  std::unordered_map<u32string, int> prefixes_;
  vector<vector<Beam>> beams_;
  vector<string> beam_keys_;
};

}  // namespace nova_lm

static void rime_nova_lm_initialize() {
  rime::Registry::instance().Register("nova_lm_filter", new rime::Component<nova_lm::NovaLmFilter>);
}

static void rime_nova_lm_finalize() {}

RIME_REGISTER_MODULE(nova_lm)
