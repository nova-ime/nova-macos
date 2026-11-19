// 候选面板的几何。这里只算要画什么、画在哪，不碰窗口。
// 逐行对应原来 macOS 的 NovaLayout.swift；注意浮点运算的顺序，改动要保持画面逐像素不变。
// 不许编译器把 a + b * c 融合成一条乘加指令：融合后末位和 Swift 原版差一点点，
// 画面逐像素不变要求这里的浮点结果和原来完全一致。
#if defined(__clang__)
#pragma clang fp contract(off)
#endif
#include <algorithm>
#include <cmath>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "model.h"
#include "../include/nova_ui.h"

namespace {

constexpr double kCornerRadius = 10;
constexpr double kEdge = 10;
constexpr double kChipRadius = 6;
constexpr double kChipPadding = 8;
constexpr double kColumnGap = 12;
constexpr double kLinkHeight = 3;
constexpr double kBranchIndent = 6;
constexpr double kAltIndent = 16;
constexpr double kAltPadding = 6;
constexpr double kAltGap = 8;
constexpr double kBusGap = 5;
constexpr double kSpineOffset = 10;
constexpr double kBranchRadius = 4;
constexpr double kLabelGap = 4;
constexpr double kRowPadding = 6;
constexpr double kShareRow = 13;
constexpr double kAltSpacing = 3;
constexpr double kMaxAlts = 6;

struct Rect {
  double x, y, w, h;
  double MinX() const { return x; }
  double MinY() const { return y; }
  double MaxX() const { return x + w; }
  double MaxY() const { return y + h; }
  double MidX() const { return x + w / 2; }
  double MidY() const { return y + h / 2; }
  Rect InsetBy(double dx, double dy) const { return {x + dx, y + dy, w - 2 * dx, h - 2 * dy}; }
  NovaUIRect C() const { return {x, y, w, h}; }
};

struct Style {
  double size;
  bool linear, show_share;
  double RowHeight() const { return std::ceil(size * 1.5); }
  double ChipHeight() const { return std::ceil(size * 1.6); }
  double AltHeight() const { return std::ceil(size * 1.5); }
  double ShareHeight() const { return show_share ? kShareRow : 0; }
  double AltRowHeight() const { return AltHeight() + (show_share ? kShareRow : kAltSpacing); }
};

// 一排词块的竖向坐标。d 是离词块顶边的距离；往上长时整排上下翻转。
struct Tier {
  double top, height;
  bool upward;
  double Y(double distance) const { return upward ? top + height - distance : top + distance; }
  Rect R(double x, double distance, double width, double row_height) const {
    return {x, upward ? Y(distance) - row_height : Y(distance), width, row_height};
  }
};

struct AltCell {
  std::string label, text, share;
  bool has_share;
  double label_width, text_width, width;
};

struct Column {
  int index;
  const NovaUIBlock* block;
  std::string chip, share;
  bool has_share;
  double chip_width;
  std::vector<AltCell> cells;
  int first_label;
};

class Layout {
 public:
  Layout(const NovaUIContent& content, const Style& style, NovaUIMeasureFn measure, void* user, double max_width,
         bool upward)
      : s_(style), measure_(measure), user_(user), upward_(upward), bottom_(kEdge) {
    card_ = content.block_count == 0;
    AddPreedit(content);
    if (content.block_count == 0) {
      AddCandidates(content, max_width);
    } else {
      // 字母行贴着输入的文字：面板在下方时放最上面，在上方时放最下面。
      if (!upward_) AddLetters(content);
      AddTree(content, max_width);
      if (upward_) AddLetters(content);
    }
    width_ = std::ceil(right_) + kEdge;
    height_ = std::ceil(bottom_) + kEdge;
  }

  double width_ = 0, height_ = 0;
  bool card_ = false;
  std::vector<NovaUIBox> links_, boxes_;
  std::vector<NovaUIPathSeg> path_;
  std::vector<NovaUIHit> hits_;
  struct RunStore {
    std::string text;
    NovaUIRun run;
  };
  std::vector<RunStore> runs_;

 private:
  Style s_;
  NovaUIMeasureFn measure_;
  void* user_;
  bool upward_;
  double bottom_;
  double right_ = 0;

  double Width(const std::string& text, NovaUIFont font) const { return measure_(text.c_str(), font, user_); }
  double Size(NovaUIFont font) const { return nova_ui_font_size(font, s_.size); }

  // 汉字的字面中心约在基线上方 0.38 em，让它落在行的正中。
  double Baseline(const Rect& rect, NovaUIFont font) const { return rect.MidY() + Size(font) * 0.38; }

  void AddRun(const std::string& text, NovaUIFont font, NovaUIColor color, double x, double baseline) {
    RunStore store;
    store.text = text;
    store.run = {nullptr, font, Size(font), color, -1, -1, color, x, baseline};
    runs_.push_back(std::move(store));
  }

  void AddBox(std::vector<NovaUIBox>& to, const Rect& rect, double radius, NovaUIColor color) {
    to.push_back({rect.C(), radius, color});
  }

  void AddHit(const Rect& rect, NovaUIActionKind action, int value) { hits_.push_back({rect.C(), action, value}); }

  void AddPreedit(const NovaUIContent& content) {
    const std::string preedit = content.preedit ? content.preedit : "";
    if (preedit.empty()) return;
    const int length = nova::Utf16Length(preedit);
    const bool selected = content.sel_location >= 0 && content.sel_location + content.sel_length <= length;
    Rect rect = {kEdge, bottom_, 0, s_.RowHeight()};
    RunStore store;
    store.text = preedit;
    store.run = {nullptr, NOVA_FONT_BODY, s_.size, selected ? NOVA_COLOR_DIM : NOVA_COLOR_PRIMARY, -1, -1,
                 NOVA_COLOR_PRIMARY, kEdge, Baseline(rect, NOVA_FONT_BODY)};
    if (selected) {
      store.run.hl_start = content.sel_location;
      store.run.hl_end = content.sel_location + content.sel_length;
    }
    runs_.push_back(std::move(store));
    right_ = std::max(right_, kEdge + Width(preedit, NOVA_FONT_BODY));
    bottom_ += s_.RowHeight();
    if (content.block_count > 0 || content.candidate_count > 0) bottom_ += 6;
  }

  // 原始字母一行：每块的字母下面画一条和词块同色的线，焦点块是黄色；光标是一根黄色竖线。
  // 点一个字母，光标移到它前面。
  void AddLetters(const NovaUIContent& content) {
    const std::string letters_text = content.letters ? content.letters : "";
    if (letters_text.empty()) return;
    if (upward_) bottom_ += 6;
    // 按 Unicode 字符拆（原始字母和拼音都是 ASCII）。
    std::vector<std::string> letters;
    for (size_t i = 0; i < letters_text.size();) {
      size_t n = 1;
      unsigned char c = static_cast<unsigned char>(letters_text[i]);
      if (c >= 0xF0) n = 4; else if (c >= 0xE0) n = 3; else if (c >= 0xC0) n = 2;
      letters.push_back(letters_text.substr(i, n));
      i += n;
    }
    const double count = static_cast<double>(letters.size());
    const double width = std::ceil(Width("m", NOVA_FONT_LETTER));
    Rect rect = {kEdge + kChipPadding, bottom_, width * count, s_.RowHeight()};
    const double line = Baseline(rect, NOVA_FONT_LETTER);
    // 字母是白色，铺一块深色底，在浅色窗口上也看得见。
    AddBox(boxes_, rect.InsetBy(-kChipPadding, 0), kChipRadius, NOVA_COLOR_ALT_FILL);
    std::set<int> covered;
    for (int i = 0; i < content.block_count; i++) {
      const int from = nova_ui_letter_position(&content, content.blocks[i].from);
      const int to = std::max(from, nova_ui_letter_position(&content, content.blocks[i].to));
      for (int p = from; p < to; p++) covered.insert(p);
    }
    for (size_t index = 0; index < letters.size(); index++) {
      const double x = rect.MinX() + static_cast<double>(index) * width;
      AddRun(letters[index], NOVA_FONT_LETTER, covered.count(static_cast<int>(index)) ? NOVA_COLOR_PRIMARY : NOVA_COLOR_DIM, x, line);
      // 光标落在点的字母后面：焦点按光标前一个字母算。
      AddHit({x, rect.MinY(), width, rect.h}, NOVA_ACTION_CURSOR, nova_ui_code_position(&content, static_cast<int>(index) + 1));
    }
    for (int i = 0; i < content.block_count; i++) {
      const NovaUIBlock& block = content.blocks[i];
      if (!(block.to > block.from)) continue;
      const int from = nova_ui_letter_position(&content, block.from), to = nova_ui_letter_position(&content, block.to);
      const double x = rect.MinX() + static_cast<double>(from) * width;
      AddBox(boxes_, {x + 1, rect.MaxY() - 5, static_cast<double>(to - from) * width - 2, 2}, 0,
             block.focused ? NOVA_COLOR_FOCUS : nova_ui_block_color(&block));
    }
    const int cursor_letter = std::min(std::max(nova_ui_letter_position(&content, content.cursor), 0), static_cast<int>(letters.size()));
    const double cursor_x = rect.MinX() + static_cast<double>(cursor_letter) * width;
    AddBox(boxes_, {cursor_x - 1, rect.MinY() + 3, 2, rect.h - 6}, 1, NOVA_COLOR_FOCUS);
    right_ = std::max(right_, rect.MaxX() + kChipPadding);
    bottom_ += s_.RowHeight();
    if (!upward_) bottom_ += 6;
  }

  AltCell MakeAlt(const NovaUIChoice& choice, int number) const {
    AltCell cell;
    cell.label = std::to_string(number);
    cell.text = choice.text ? choice.text : "";
    cell.has_share = s_.show_share && choice.has_share;
    if (cell.has_share) cell.share = std::to_string(choice.share);
    cell.label_width = Width(cell.label, NOVA_FONT_LABEL);
    cell.text_width = Width(cell.text, NOVA_FONT_BODY);
    cell.width = kAltPadding * 2 + std::ceil(cell.label_width) + kLabelGap + std::ceil(cell.text_width);
    return cell;
  }

  Column Measure(const NovaUIBlock& block, int index, int first_label, bool shows) const {
    Column column;
    column.index = index;
    column.block = &block;
    column.chip = block.word.text ? block.word.text : "";
    column.chip_width = std::ceil(Width(column.chip, NOVA_FONT_BODY)) + kChipPadding * 2;
    if (shows) {
      for (int i = 0; i < block.alt_count; i++) column.cells.push_back(MakeAlt(block.alts[i], first_label + i));
    }
    column.has_share = s_.show_share && block.word.has_share;
    if (column.has_share) column.share = std::to_string(block.word.share);
    column.first_label = first_label;
    return column;
  }

  // 词块只按自身宽度排在一条连线上，放不下时另起一排。
  void AddTree(const NovaUIContent& content, double max_width) {
    const double limit = max_width - kEdge * 2;
    std::vector<std::vector<Column>> tiers;
    double tier_width = 0;
    bool has_focus = false;
    for (int i = 0; i < content.block_count; i++) has_focus = has_focus || content.blocks[i].focused;
    int label = 1;
    for (int index = 0; index < content.block_count; index++) {
      const NovaUIBlock& block = content.blocks[index];
      const bool shows = has_focus ? block.focused : block.overview;
      Column column = Measure(block, index, has_focus ? 1 : label, shows);
      if (shows && !has_focus) label += block.alt_count;
      if (tiers.empty() || tier_width + column.chip_width > limit) {
        tiers.emplace_back();
        tier_width = 0;
      }
      tier_width += column.chip_width + kColumnGap;
      tiers.back().push_back(std::move(column));
    }
    for (size_t i = 0; i < tiers.size(); i++) {
      if (i > 0) bottom_ += 8;
      AddTier(tiers[i]);
    }
  }

  void AddTier(const std::vector<Column>& columns) {
    size_t depth = 0;
    for (const Column& c : columns) depth = std::max(depth, c.cells.size());
    const double alts_height = depth > 0 ? kBusGap + static_cast<double>(depth) * s_.AltRowHeight() : 0;
    const Tier tier = {bottom_, s_.ChipHeight() + s_.ShareHeight() + alts_height, upward_};
    double x = kEdge;
    bool has_previous = false;
    double previous_end = 0;
    double alt_floor = 0;
    for (const Column& column : columns) {
      if (has_previous) {
        // 连线伸进两边的词块下面，避开圆角处的缝。
        const Rect chip = tier.R(0, 0, 0, s_.ChipHeight());
        AddBox(links_, {previous_end - 2, chip.MidY() - kLinkHeight / 2, x - previous_end + 4, kLinkHeight}, 0,
               nova_ui_block_color(column.block));
      }
      AddChip(column, x, tier);
      AddAlternatives(column, x, tier, &alt_floor);
      has_previous = true;
      previous_end = x + column.chip_width;
      right_ = std::max(right_, x + column.chip_width);
      x += column.chip_width + kColumnGap;
    }
    bottom_ = tier.top + tier.height;
  }

  void AddChip(const Column& column, double x, const Tier& tier) {
    const Rect rect = tier.R(x, 0, column.chip_width, s_.ChipHeight());
    // 焦点块换底色，不用描边。
    AddBox(boxes_, rect, kChipRadius, column.block->focused ? NOVA_COLOR_FOCUS : nova_ui_block_color(column.block));
    AddHit(rect, NOVA_ACTION_FOCUS, column.index);
    AddRun(column.chip, NOVA_FONT_BODY, column.block->focused ? NOVA_COLOR_BLACK : NOVA_COLOR_PRIMARY,
           x + kChipPadding, Baseline(rect, NOVA_FONT_BODY));
    if (column.has_share) {
      const Rect row = tier.R(x, s_.ChipHeight(), column.chip_width, s_.ShareHeight());
      AddRun(column.share, NOVA_FONT_SHARE, NOVA_COLOR_SHARE,
             x + (column.chip_width - std::ceil(Width(column.share, NOVA_FONT_SHARE))) / 2, Baseline(row, NOVA_FONT_SHARE));
    }
  }

  void Move(double x, double y) { path_.push_back({NOVA_PATH_MOVE, x, y, 0, 0, 0, 0}); }
  void Line(double x, double y) { path_.push_back({NOVA_PATH_LINE, x, y, 0, 0, 0, 0}); }
  void Curve(double x, double y, double c1x, double c1y, double c2x, double c2y) {
    path_.push_back({NOVA_PATH_CURVE, x, y, c1x, c1y, c2x, c2y});
  }

  // 备选放不下时往右让，用一条横线接回词块。
  void AddAlternatives(const Column& column, double x, const Tier& tier, double* alt_floor) {
    if (column.cells.empty()) return;
    const double cell_x = std::max(x + kAltIndent, *alt_floor);
    double width = 0;
    for (const AltCell& c : column.cells) width = std::max(width, c.width);
    const double spine = cell_x - kSpineOffset;
    const double first_row = s_.ChipHeight() + s_.ShareHeight() + kBusGap;
    const double bus = tier.Y(first_row - kBusGap / 2);
    Move(x + kBranchIndent, tier.Y(s_.ChipHeight()));
    Line(x + kBranchIndent, bus);
    Line(spine, bus);
    for (size_t row = 0; row < column.cells.size(); row++) {
      const AltCell& cell = column.cells[row];
      const double distance = first_row + static_cast<double>(row) * s_.AltRowHeight();
      const Rect rect = tier.R(cell_x, distance, width, s_.AltHeight());
      AddBranch(spine, bus, cell_x, rect.MidY());
      // ↓/↑ 换上的那一项铺蓝色，和普通列表的高亮一样。
      AddBox(boxes_, rect, 5,
             column.block->has_current && column.block->current == static_cast<int>(row) + 1 ? NOVA_COLOR_BLUE : NOVA_COLOR_ALT_FILL);
      AddHit(rect, NOVA_ACTION_PIN, column.first_label + static_cast<int>(row));
      const double line = Baseline(rect, NOVA_FONT_BODY);
      double cursor = cell_x + kAltPadding;
      AddRun(cell.label, NOVA_FONT_LABEL, NOVA_COLOR_DIM, cursor, line);
      cursor += std::ceil(cell.label_width) + kLabelGap;
      AddRun(cell.text, NOVA_FONT_BODY, NOVA_COLOR_PRIMARY, cursor, line);
      if (cell.has_share) {
        const Rect share_rect = tier.R(cell_x, distance + s_.AltHeight(), width, s_.ShareHeight());
        AddRun(cell.share, NOVA_FONT_SHARE, NOVA_COLOR_SHARE,
               rect.MidX() - std::ceil(Width(cell.share, NOVA_FONT_SHARE)) / 2, Baseline(share_rect, NOVA_FONT_SHARE));
      }
    }
    // 分页时在最后一个备选右边标出页码，-/= 或 ,/. 翻页。
    const std::string page = column.block->page ? column.block->page : "";
    if (!page.empty()) {
      const Rect rect = tier.R(cell_x, first_row + static_cast<double>(column.cells.size() - 1) * s_.AltRowHeight(), width, s_.AltHeight());
      const std::string text = "\xE2\x80\xB9 " + page + " \xE2\x80\xBA";  // ‹ 页码 ›
      AddRun(text, NOVA_FONT_LABEL, NOVA_COLOR_DIM, cell_x + width + kAltGap, Baseline(rect, NOVA_FONT_LABEL));
      right_ = std::max(right_, cell_x + width + kAltGap + std::ceil(Width(text, NOVA_FONT_LABEL)));
    }
    right_ = std::max(right_, cell_x + width);
    *alt_floor = cell_x + width + kAltGap;
  }

  void AddBranch(double spine, double from, double end_x, double y) {
    const double radius = std::min(kBranchRadius, end_x - spine);
    Move(spine, from);
    Line(spine, y > from ? y - radius : y + radius);
    Curve(spine + radius, y, spine, y, spine, y);
    Line(end_x, y);
  }

  // 普通候选列表：竖排或横排，高亮的一项铺底色。
  void AddCandidates(const NovaUIContent& content, double max_width) {
    struct Entry {
      std::string label, text, comment;
      double label_width, text_width, comment_width, width;
    };
    std::vector<Entry> entries;
    for (int i = 0; i < content.candidate_count; i++) {
      const NovaUICandidate& c = content.candidates[i];
      Entry e;
      e.label = c.label ? c.label : "";
      e.text = c.text ? c.text : "";
      e.comment = c.comment ? c.comment : "";
      e.label_width = Width(e.label, NOVA_FONT_LABEL);
      e.text_width = Width(e.text, NOVA_FONT_BODY);
      e.comment_width = Width(e.comment, NOVA_FONT_LABEL);
      double width = kRowPadding * 2 + std::ceil(e.text_width);
      width += e.label.empty() ? 0 : std::ceil(e.label_width) + kLabelGap;
      width += e.comment.empty() ? 0 : std::ceil(e.comment_width) + kLabelGap;
      e.width = width;
      entries.push_back(std::move(e));
    }
    bool has_uniform = false;
    double uniform = 0;
    if (!s_.linear && !entries.empty()) {
      has_uniform = true;
      uniform = entries[0].width;
      for (const Entry& e : entries) uniform = std::max(uniform, e.width);
    }
    double x = kEdge;
    const double limit = max_width - kEdge;
    double row_top = bottom_;
    for (size_t index = 0; index < entries.size(); index++) {
      const Entry& entry = entries[index];
      const double width = has_uniform ? uniform : entry.width;
      if (x > kEdge && x + width > limit) {
        x = kEdge;
        row_top += s_.RowHeight();
      }
      const Rect rect = {x, row_top, width, s_.RowHeight()};
      if (static_cast<int>(index) == content.highlighted) AddBox(boxes_, rect, kChipRadius, NOVA_COLOR_BLUE);
      AddHit(rect, NOVA_ACTION_SELECT, static_cast<int>(index));
      const double line = Baseline(rect, NOVA_FONT_BODY);
      double cursor = x + kRowPadding;
      if (!entry.label.empty()) {
        AddRun(entry.label, NOVA_FONT_LABEL, NOVA_COLOR_DIM, cursor, line);
        cursor += std::ceil(entry.label_width) + kLabelGap;
      }
      if (!entry.text.empty()) {
        AddRun(entry.text, NOVA_FONT_BODY, NOVA_COLOR_PRIMARY, cursor, line);
        cursor += std::ceil(entry.text_width) + kLabelGap;
      }
      if (!entry.comment.empty()) {
        AddRun(entry.comment, NOVA_FONT_LABEL, NOVA_COLOR_DIM, cursor, line);
        cursor += std::ceil(entry.comment_width) + kLabelGap;
      }
      right_ = std::max(right_, x + width);
      if (s_.linear) {
        x += width;
      } else {
        row_top += s_.RowHeight();
      }
    }
    bottom_ = s_.linear || entries.empty() ? row_top + (entries.empty() ? 0 : s_.RowHeight()) : row_top;
  }
};

}  // namespace

struct NovaUILayout {
  std::unique_ptr<Layout> layout;
  std::vector<NovaUIRun> runs;
  NovaUILayoutView view;
};

NovaUILayout* nova_ui_layout_create(const NovaUIContent* content, const NovaUIStyle* style, NovaUIMeasureFn measure,
                                    void* user, double max_width, int upward) {
  auto* out = new NovaUILayout();
  Style s = {style->font_size, style->linear != 0, style->show_share != 0};
  out->layout.reset(new Layout(*content, s, measure, user, max_width, upward != 0));
  Layout& l = *out->layout;
  for (auto& store : l.runs_) {
    store.run.text = store.text.c_str();
    out->runs.push_back(store.run);
  }
  NovaUILayoutView& v = out->view;
  v.width = l.width_;
  v.height = l.height_;
  v.card = l.card_;
  v.links = l.links_.data();
  v.link_count = static_cast<int>(l.links_.size());
  v.path = l.path_.data();
  v.path_count = static_cast<int>(l.path_.size());
  v.boxes = l.boxes_.data();
  v.box_count = static_cast<int>(l.boxes_.size());
  v.runs = out->runs.data();
  v.run_count = static_cast<int>(out->runs.size());
  v.hits = l.hits_.data();
  v.hit_count = static_cast<int>(l.hits_.size());
  return out;
}

const NovaUILayoutView* nova_ui_layout_view(const NovaUILayout* layout) { return &layout->view; }

void nova_ui_layout_free(NovaUILayout* layout) { delete layout; }

// 词块加满备选的高度，用来判断光标下方放不放得下。
double nova_ui_full_height(const NovaUIStyle* style) {
  Style s = {style->font_size, style->linear != 0, style->show_share != 0};
  return kEdge * 2 + s.ChipHeight() + s.ShareHeight() + kBusGap + kMaxAlts * s.AltRowHeight();
}

double nova_ui_corner_radius(void) { return kCornerRadius; }
double nova_ui_edge(void) { return kEdge; }
