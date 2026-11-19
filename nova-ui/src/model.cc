// nova_tree 解析、内容组装、颜色和字体的小函数。
#include <algorithm>
#include <cmath>
#include <cstring>

#include "model.h"

namespace nova {

bool ParseInt(const std::string& s, int* out) {
  size_t i = 0;
  bool negative = false;
  if (i < s.size() && (s[i] == '+' || s[i] == '-')) {
    negative = s[i] == '-';
    i++;
  }
  if (i >= s.size()) return false;
  int64_t value = 0;
  for (; i < s.size(); i++) {
    if (s[i] < '0' || s[i] > '9') return false;
    value = value * 10 + (s[i] - '0');
    if (value > INT32_MAX + 1LL) return false;
  }
  if (negative) value = -value;
  if (value > INT32_MAX || value < INT32_MIN) return false;
  *out = static_cast<int>(value);
  return true;
}

int Utf16Length(const std::string& s) {
  int n = 0;
  for (size_t i = 0; i < s.size(); i++) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if ((c & 0xC0) == 0x80) continue;  // 续字节
    n += c >= 0xF0 ? 2 : 1;            // 4 字节序列是代理对
  }
  return n;
}

// 按分隔符切开；omit_empty 对应 Swift split 默认的 omittingEmptySubsequences。
static std::vector<std::string> Split(const std::string& s, char sep, bool omit_empty) {
  std::vector<std::string> parts;
  size_t start = 0;
  for (size_t i = 0; i <= s.size(); i++) {
    if (i == s.size() || s[i] == sep) {
      if (!omit_empty || i > start) parts.push_back(s.substr(start, i - start));
      start = i + 1;
    }
  }
  return parts;
}

static void FillChoice(const std::string& field, std::string* text_storage, NovaUIChoice* choice) {
  std::vector<std::string> parts = Split(field, '\x1F', false);
  *text_storage = parts.empty() ? "" : parts[0];
  choice->has_share = 0;
  choice->share = 0;
  int share = 0;
  if (parts.size() > 1 && ParseInt(parts[1], &share)) {
    choice->has_share = 1;
    choice->share = share;
  }
}

static bool Contains(const std::string& s, char c) { return s.find(c) != std::string::npos; }

// 标记里 p数字/数字 的第一处（不含 p）；没有时为空。
static std::string FindPage(const std::string& flags) {
  for (size_t i = 0; i < flags.size(); i++) {
    if (flags[i] != 'p') continue;
    size_t j = i + 1;
    while (j < flags.size() && flags[j] >= '0' && flags[j] <= '9') j++;
    if (j == i + 1 || j >= flags.size() || flags[j] != '/') continue;
    size_t k = j + 1;
    while (k < flags.size() && flags[k] >= '0' && flags[k] <= '9') k++;
    if (k == j + 1) continue;
    return flags.substr(i + 1, k - i - 1);
  }
  return "";
}

// 标记里 h数字 的第一处的数字。
static bool FindCurrent(const std::string& flags, int* out) {
  for (size_t i = 0; i < flags.size(); i++) {
    if (flags[i] != 'h') continue;
    size_t j = i + 1;
    while (j < flags.size() && flags[j] >= '0' && flags[j] <= '9') j++;
    if (j == i + 1) continue;
    int value = 0;
    // 数字太长放不下时按没有算（和 Int(...) 返回 nil 一致）。
    if (!ParseInt(flags.substr(i + 1, j - i - 1), &value)) return false;
    *out = value;
    return true;
  }
  return false;
}

}  // namespace nova

using nova::BlockStore;

// nova_tree 属性：每块一行，格式见 nova_sentences.lua。
NovaUITree* nova_ui_tree_parse(const char* tree_text) {
  auto* tree = new NovaUITree();
  const std::string text = tree_text ? tree_text : "";
  for (const std::string& line : nova::Split(text, '\n', true)) {
    std::vector<std::string> fields = nova::Split(line, '\t', true);
    BlockStore store;
    store.flags = fields.empty() ? "" : fields[0];
    NovaUIBlock& b = store.block;
    std::memset(&b, 0, sizeof b);
    int value = 0;
    b.from = fields.size() > 1 && nova::ParseInt(fields[1], &value) ? value : 0;
    value = 0;
    b.to = fields.size() > 2 && nova::ParseInt(fields[2], &value) ? value : 0;
    const std::string& flags = store.flags;
    b.pinned = !flags.empty() && flags[0] == '1';
    b.focused = nova::Contains(flags, 'f');
    b.corrected = nova::Contains(flags, 'c');
    b.uncertain = nova::Contains(flags, 'u');
    b.overview = nova::Contains(flags, 'o');
    nova::FillChoice(fields.size() > 4 ? fields[4] : "", &store.word, &b.word);
    for (size_t i = 5; i < fields.size(); i++) {
      store.alt_texts.emplace_back();
      store.alts.emplace_back();
      nova::FillChoice(fields[i], &store.alt_texts.back(), &store.alts.back());
    }
    store.page = nova::FindPage(flags);
    int current = 0;
    b.has_current = nova::FindCurrent(flags, &current);
    b.current = b.has_current ? current : 0;
    tree->stores.push_back(std::move(store));
  }
  // 指针要等 vector 不再增长、元素不再搬动之后再取。
  tree->blocks.reserve(tree->stores.size());
  for (BlockStore& s : tree->stores) {
    s.block.word.text = s.word.c_str();
    for (size_t i = 0; i < s.alts.size(); i++) s.alts[i].text = s.alt_texts[i].c_str();
    s.block.alts = s.alts.data();
    s.block.alt_count = static_cast<int>(s.alts.size());
    s.block.page = s.page.c_str();
    s.block.flags = s.flags.c_str();
    tree->blocks.push_back(s.block);
  }
  return tree;
}

const NovaUIBlock* nova_ui_tree_blocks(const NovaUITree* tree, int* count) {
  if (count) *count = tree ? static_cast<int>(tree->blocks.size()) : 0;
  return tree ? tree->blocks.data() : nullptr;
}

void nova_ui_tree_free(NovaUITree* tree) { delete tree; }

// 绿：用户选过。紫：语法推翻了词频（多半是对的）。橙：解码器拿不准。见 nova_sentences.lua 的 measure_block。
NovaUIColor nova_ui_block_color(const NovaUIBlock* b) {
  if (b->pinned) return NOVA_COLOR_GREEN;
  if (b->corrected) return NOVA_COLOR_PURPLE;
  return b->uncertain ? NOVA_COLOR_ORANGE : NOVA_COLOR_BLUE;
}

const char* nova_ui_block_tone(const NovaUIBlock* b) {
  if (b->pinned) return "green";
  if (b->corrected) return "purple";
  return b->uncertain ? "orange" : "blue";
}

int nova_ui_letter_position(const NovaUIContent* c, int code) {
  if (c->letter_map_count <= 0) return code;
  return c->letter_map[std::min(std::max(code, 0), c->letter_map_count - 1)];
}

// 拼音位置对应的编码位置：第一个拼音位置不小于它的编码位置，也就是落到所在音节的末尾。
int nova_ui_code_position(const NovaUIContent* c, int letter) {
  if (c->letter_map_count <= 0) return letter;
  for (int i = 0; i < c->letter_map_count; i++) {
    if (c->letter_map[i] >= letter) return i;
  }
  return c->letter_map_count - 1;
}

// 全部是实色，没有透明度和描边。
void nova_ui_default_color(NovaUIColor color, double rgba[4]) {
  auto rgb = [&](int r, int g, int b) {
    rgba[0] = r / 255.0;
    rgba[1] = g / 255.0;
    rgba[2] = b / 255.0;
    rgba[3] = 1;
  };
  auto grey = [&](double w) {
    rgba[0] = rgba[1] = rgba[2] = w;
    rgba[3] = 1;
  };
  switch (color) {
    case NOVA_COLOR_BLUE: rgb(0x2f, 0x6f, 0xde); break;
    case NOVA_COLOR_ORANGE: rgb(0xd2, 0x66, 0x24); break;
    case NOVA_COLOR_PURPLE: rgb(0x7b, 0x48, 0xd8); break;
    case NOVA_COLOR_GREEN: rgb(0x1f, 0x9d, 0x6b); break;
    // 焦点块要在深浅窗口上都醒目，白色和黑色都不行。
    case NOVA_COLOR_FOCUS: rgb(0xf5, 0xc5, 0x18); break;
    case NOVA_COLOR_ALT_FILL: grey(0.16); break;
    case NOVA_COLOR_ALT_HOVER: grey(0.28); break;
    case NOVA_COLOR_CARD: grey(0.13); break;
    case NOVA_COLOR_BRANCH: grey(0.55); break;
    case NOVA_COLOR_PRIMARY: grey(1); break;
    case NOVA_COLOR_DIM: grey(0.62); break;
    case NOVA_COLOR_SHARE: grey(0.5); break;
    case NOVA_COLOR_BLACK: grey(0); break;
    default: grey(0); break;
  }
}

double nova_ui_font_size(NovaUIFont font, double body) {
  switch (font) {
    case NOVA_FONT_LABEL: return std::round(body * 0.68);
    case NOVA_FONT_SHARE: return std::round(body * 0.62);
    case NOVA_FONT_LETTER: return std::round(body * 0.9);
    default: return body;
  }
}

// 决定显示树还是普通列表、字母行显示什么。
NovaUIContentHandle* nova_ui_assemble(const NovaUIAssembleInput* in) {
  auto str = [](const char* s) { return std::string(s ? s : ""); };
  auto* h = new NovaUIContentHandle();
  const std::string input = str(in->input);

  // 翻页或移动高亮是在找树上没有的候选，这时才显示普通列表。
  // 没有焦点时第一次翻页不交给 Rime（它会直接翻到第二页），nova_tree_keys 只把当时的输入写进 nova_list：
  // 列表从第一页显示。
  const bool list_open = !input.empty() && in->prop_list && input == in->prop_list;
  const bool browsing = in->page_no > 0 || in->highlighted > 0 || list_open;
  const std::string tree = browsing || in->num_candidates == 0 ? "" : str(in->prop_tree);
  // 有树时原始字母只画在面板里（带光标和按词块着色的下划线），输入框照常显示首选整句。
  const std::string code = tree.empty() ? "" : input;

  // 原始字母光标，nova_cursor 属性为空时在末尾。
  const int input_length = static_cast<int>(code.size());
  int cursor = input_length;
  int parsed = 0;
  if (in->prop_cursor && nova::ParseInt(in->prop_cursor, &parsed)) {
    cursor = std::min(std::max(parsed, 0), input_length);
  }

  // 全拼时字母行显示拼音，见 lua/nova_quanpin.lua：
  // nova_qp_raw / nova_qp_map 对得上当前输入时，用拼音和编码位置到拼音位置的对照；否则原样用编码。
  h->letters = code;
  if (!code.empty() && in->prop_qp_raw && in->prop_qp_map) {
    std::vector<int> positions;
    std::string map = in->prop_qp_map;
    size_t start = 0;
    for (size_t i = 0; i <= map.size(); i++) {
      if (i == map.size() || map[i] == ',') {
        int v = 0;
        if (i > start && nova::ParseInt(map.substr(start, i - start), &v)) positions.push_back(v);
        start = i + 1;
      }
    }
    if (in->prop_qp_raw[0] != 0 && positions.size() == code.size() + 1) {
      h->letters = in->prop_qp_raw;
      h->letter_map = positions;
    }
  }

  // 空行表示还没有词块（只打了一个字母），这时什么都不显示。
  const bool no_candidates = tree == "\n";
  h->preedit = in->inline_preedit || !h->letters.empty() ? "" : str(in->preedit);

  NovaUITree* parsed_tree = nova_ui_tree_parse(tree.c_str());
  h->tree = std::move(*parsed_tree);
  delete parsed_tree;

  const int count = no_candidates ? 0 : in->count;
  h->label_s.reserve(count);
  h->text_s.reserve(count);
  h->comment_s.reserve(count);
  for (int i = 0; i < count; i++) {
    h->label_s.push_back(i < in->label_count && in->labels && in->labels[i] ? in->labels[i] : std::to_string(i + 1));
    h->text_s.push_back(in->texts && in->texts[i] ? in->texts[i] : "");
    h->comment_s.push_back(in->comments && in->comments[i] ? in->comments[i] : "");
  }
  for (int i = 0; i < count; i++) {
    h->candidates.push_back({h->label_s[i].c_str(), h->text_s[i].c_str(), h->comment_s[i].c_str()});
  }

  NovaUIContent& v = h->view;
  v.preedit = h->preedit.c_str();
  v.sel_location = in->sel_location;
  v.sel_length = in->sel_length;
  v.blocks = h->tree.blocks.data();
  v.block_count = static_cast<int>(h->tree.blocks.size());
  v.letters = h->letters.c_str();
  v.cursor = cursor;
  v.letter_map = h->letter_map.data();
  v.letter_map_count = static_cast<int>(h->letter_map.size());
  v.candidates = h->candidates.data();
  v.candidate_count = count;
  v.highlighted = in->highlighted;
  return h;
}

const NovaUIContent* nova_ui_content_view(const NovaUIContentHandle* h) { return &h->view; }

void nova_ui_content_free(NovaUIContentHandle* h) { delete h; }
