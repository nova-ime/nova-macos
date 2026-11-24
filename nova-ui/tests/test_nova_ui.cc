// nova-ui 的单元测试：解析、内容组装、排版（用固定宽度的假测宽函数）。
// 构建运行：make -C nova-ui test
#include <cmath>
#include <filesystem>
#include <fstream>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "../include/nova_ui.h"

static int g_failures = 0, g_checks = 0;
#define CHECK(cond)                                                          \
  do {                                                                       \
    g_checks++;                                                              \
    if (!(cond)) {                                                           \
      g_failures++;                                                          \
      std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);            \
    }                                                                        \
  } while (0)
#define CHECK_NEAR(a, b) CHECK(std::fabs((a) - (b)) < 1e-9)
#define CHECK_STR(a, b) CHECK(std::string(a) == std::string(b))

// 假测宽：每个 Unicode 字符的宽度由字体角色决定，和平台无关，结果可以手算。
static double FakeMeasure(const char* text, NovaUIFont font, void*) {
  int chars = 0;
  for (const char* p = text; *p; p++) chars += (static_cast<unsigned char>(*p) & 0xC0) != 0x80;
  static const double per[] = {10, 6, 5, 8};
  return chars * per[font];
}

static const char US = '\x1F';
static std::string Line(const std::string& flags, int from, int to, const std::string& key, const std::string& word,
                        const std::vector<std::string>& alts = {}) {
  std::string s = flags + "\t" + std::to_string(from) + "\t" + std::to_string(to) + "\t" + key + "\t" + word;
  for (const auto& a : alts) s += "\t" + a;
  return s + "\n";
}

static void TestParse() {
  std::string tree = Line("0fp2/5h3", 0, 2, "wo", std::string("我") + US + "62", {std::string("窝") + US + "20", "沃"});
  tree += Line("1", 2, 4, "ni", "你");
  tree += Line("0cu", 4, 6, "hao", "好");
  tree += Line("0uo", 6, 8, "a", "啊");
  NovaUITree* t = nova_ui_tree_parse(tree.c_str());
  int n = 0;
  const NovaUIBlock* b = nova_ui_tree_blocks(t, &n);
  CHECK(n == 4);
  CHECK(b[0].from == 0 && b[0].to == 2 && b[0].focused && !b[0].pinned && !b[0].corrected && !b[0].uncertain);
  CHECK_STR(b[0].word.text, "我");
  CHECK(b[0].word.has_share && b[0].word.share == 62);
  CHECK(b[0].alt_count == 2);
  CHECK_STR(b[0].alts[0].text, "窝");
  CHECK(b[0].alts[0].has_share && b[0].alts[0].share == 20);
  CHECK_STR(b[0].alts[1].text, "沃");
  CHECK(!b[0].alts[1].has_share);
  CHECK_STR(b[0].page, "2/5");
  CHECK(b[0].has_current && b[0].current == 3);
  CHECK_STR(b[0].flags, "0fp2/5h3");
  CHECK(b[1].pinned && !b[1].focused);
  CHECK_STR(b[1].page, "");
  CHECK(!b[1].has_current);
  CHECK(b[2].corrected && b[2].uncertain);
  CHECK(b[3].overview && b[3].uncertain);
  CHECK(nova_ui_block_color(&b[1]) == NOVA_COLOR_GREEN);
  CHECK(nova_ui_block_color(&b[2]) == NOVA_COLOR_PURPLE);  // 紫优先于橙
  CHECK(nova_ui_block_color(&b[3]) == NOVA_COLOR_ORANGE);
  CHECK(nova_ui_block_color(&b[0]) == NOVA_COLOR_BLUE);
  CHECK_STR(nova_ui_block_tone(&b[2]), "purple");
  nova_ui_tree_free(t);

  // 空行被跳过；空字段也被跳过（和 Swift 的 split 默认行为一致）：后面的字段整体前移。
  t = nova_ui_tree_parse("0\t0\t2\t\t我\t窝\n\n0f\t2\t4\tshi\t是\n");
  b = nova_ui_tree_blocks(t, &n);
  CHECK(n == 2);
  CHECK_STR(b[0].word.text, "窝");  // 键是空字段被跳过，「我」落到第 3 位
  CHECK(b[0].alt_count == 0);
  CHECK_STR(b[1].word.text, "是");
  nova_ui_tree_free(t);

  t = nova_ui_tree_parse("\n");
  nova_ui_tree_blocks(t, &n);
  CHECK(n == 0);
  nova_ui_tree_free(t);
  t = nova_ui_tree_parse("x\tabc\t-3\tk\tw");  // 解析不了的数字按 0，负数照收
  b = nova_ui_tree_blocks(t, &n);
  CHECK(b[0].from == 0 && b[0].to == -3);
  nova_ui_tree_free(t);
  t = nova_ui_tree_parse("0f p3/x h\tk");  // p 后面不是「数字/数字」、h 后面没数字，都不算
  b = nova_ui_tree_blocks(t, &n);
  CHECK_STR(b[0].page, "");
  CHECK(!b[0].has_current);
  nova_ui_tree_free(t);
}

static void TestPalette() {
  double c[4];
  nova_ui_default_color(NOVA_COLOR_BLUE, c);
  CHECK_NEAR(c[0], 0x2f / 255.0);
  CHECK_NEAR(c[1], 0x6f / 255.0);
  CHECK_NEAR(c[2], 0xde / 255.0);
  CHECK_NEAR(c[3], 1);
  nova_ui_default_color(NOVA_COLOR_FOCUS, c);
  CHECK_NEAR(c[0], 0xf5 / 255.0);
  nova_ui_default_color(NOVA_COLOR_CARD, c);
  CHECK_NEAR(c[1], 0.13);
  CHECK_NEAR(nova_ui_font_size(NOVA_FONT_LABEL, 15), 10);   // round(10.2)
  CHECK_NEAR(nova_ui_font_size(NOVA_FONT_SHARE, 15), 9);    // round(9.3)
  CHECK_NEAR(nova_ui_font_size(NOVA_FONT_LETTER, 15), 14);  // round(13.5) 向远离 0 的方向
  CHECK_NEAR(nova_ui_font_size(NOVA_FONT_BODY, 15), 15);
}

struct Assembled {
  NovaUIContentHandle* h;
  const NovaUIContent* v;
  explicit Assembled(const NovaUIAssembleInput& in) : h(nova_ui_assemble(&in)), v(nova_ui_content_view(h)) {}
  ~Assembled() { nova_ui_content_free(h); }
};

static void TestAssemble() {
  const std::string tree = Line("0", 0, 2, "wo", "我") + Line("0", 2, 4, "ni", "你");
  const char* texts[] = {"我你", "我"};
  const char* comments[] = {"", "c"};
  NovaUIAssembleInput in = {};
  in.input = "woni";
  in.prop_tree = tree.c_str();
  in.num_candidates = 2;
  in.count = 2;
  in.texts = texts;
  in.comments = comments;
  in.preedit = "我你";
  in.sel_location = 0;
  in.sel_length = 2;
  in.highlighted = 0;
  {
    Assembled a(in);  // 显示树：字母行出现，preedit 清空，光标默认在末尾
    CHECK(a.v->block_count == 2);
    CHECK_STR(a.v->letters, "woni");
    CHECK(a.v->cursor == 4);
    CHECK_STR(a.v->preedit, "");
    CHECK(a.v->candidate_count == 2);
    CHECK_STR(a.v->candidates[0].label, "1");  // labels 缺时按序号补
    CHECK_STR(a.v->candidates[1].label, "2");
    CHECK_STR(a.v->candidates[1].comment, "c");
    CHECK(a.v->sel_location == 0 && a.v->sel_length == 2);
  }
  {
    NovaUIAssembleInput x = in;  // 翻页：看普通列表
    x.page_no = 1;
    Assembled a(x);
    CHECK(a.v->block_count == 0);
    CHECK_STR(a.v->letters, "");
    CHECK_STR(a.v->preedit, "我你");
  }
  {
    NovaUIAssembleInput x = in;  // 高亮移动
    x.highlighted = 1;
    Assembled a(x);
    CHECK(a.v->block_count == 0 && a.v->highlighted == 1);
  }
  {
    NovaUIAssembleInput x = in;  // nova_list 等于当前输入：列表已打开
    x.prop_list = "woni";
    Assembled a(x);
    CHECK(a.v->block_count == 0);
    x.prop_list = "wo";  // 是上一次输入留下的，不算
    Assembled b(x);
    CHECK(b.v->block_count == 2);
  }
  {
    NovaUIAssembleInput x = in;  // 没有候选
    x.num_candidates = 0;
    x.count = 0;
    Assembled a(x);
    CHECK(a.v->block_count == 0);
  }
  {
    NovaUIAssembleInput x = in;  // 只有一个字母：树是空行，没有词块，面板把这个字母当输入文字显示
    std::string one = "\n";
    x.prop_tree = one.c_str();
    x.input = "w";
    Assembled a(x);
    CHECK(a.v->block_count == 0 && a.v->candidate_count == 0);
    CHECK_STR(a.v->letters, "w");
    CHECK_STR(a.v->preedit, "w");
    x.inline_preedit = 1;  // 输入框里已经显示了这个字母：面板不再显示
    Assembled b(x);
    CHECK_STR(b.v->preedit, "");
  }
  {
    NovaUIAssembleInput x = in;  // 光标：属性有效时夹在 [0, 长度]，解析不了就在末尾
    x.prop_cursor = "2";
    Assembled a(x);
    CHECK(a.v->cursor == 2);
    x.prop_cursor = "99";
    Assembled b(x);
    CHECK(b.v->cursor == 4);
    x.prop_cursor = "-5";
    Assembled c(x);
    CHECK(c.v->cursor == 0);
    x.prop_cursor = "";
    Assembled d(x);
    CHECK(d.v->cursor == 4);
  }
  {
    NovaUIAssembleInput x = in;  // 全拼：map 长度 = 编码长度 + 1 才采用
    x.prop_qp_raw = "wo'ni";
    x.prop_qp_map = "0,1,2,4,5";
    Assembled a(x);
    CHECK_STR(a.v->letters, "wo'ni");
    CHECK(a.v->letter_map_count == 5 && a.v->letter_map[3] == 4);
    CHECK_STR(a.v->preedit, "");
    CHECK(nova_ui_letter_position(a.v, 3) == 4);
    CHECK(nova_ui_letter_position(a.v, 99) == 5);  // 夹在范围内
    CHECK(nova_ui_code_position(a.v, 3) == 3);     // 第一个不小于 3 的是下标 3（值 4）
    CHECK(nova_ui_code_position(a.v, 99) == 4);
    x.prop_qp_map = "0,1,2";
    Assembled b(x);
    CHECK_STR(b.v->letters, "woni");
    CHECK(b.v->letter_map_count == 0);
    CHECK(nova_ui_letter_position(b.v, 3) == 3);
  }
  {
    NovaUIAssembleInput x = in;  // 输入框里已经内嵌 preedit：面板里不重复
    x.page_no = 1;
    x.inline_preedit = 1;
    Assembled a(x);
    CHECK_STR(a.v->preedit, "");
  }
  {
    const char* labels[] = {"a"};
    NovaUIAssembleInput x = in;
    x.page_no = 1;
    x.labels = labels;
    x.label_count = 1;
    Assembled a(x);
    CHECK_STR(a.v->candidates[0].label, "a");
    CHECK_STR(a.v->candidates[1].label, "2");
  }
}

struct Laid {
  NovaUILayout* l;
  const NovaUILayoutView* v;
  Laid(const NovaUIContent& c, double size, bool linear, bool share, double max_width, bool upward) {
    NovaUIStyle s = {};
    s.font_size = size;
    s.linear = linear;
    s.show_share = share;
    l = nova_ui_layout_create(&c, &s, FakeMeasure, nullptr, max_width, upward);
    v = nova_ui_layout_view(l);
  }
  ~Laid() { nova_ui_layout_free(l); }
  const NovaUIRun* Run(const char* text) const {
    for (int i = 0; i < v->run_count; i++) if (std::strcmp(v->runs[i].text, text) == 0) return &v->runs[i];
    return nullptr;
  }
};

static NovaUIContent ContentFromTree(NovaUITree* t) {
  NovaUIContent c = {};
  c.preedit = "";
  c.sel_location = -1;
  c.blocks = nova_ui_tree_blocks(t, &c.block_count);
  c.letters = "";
  return c;
}

static void TestLayoutStatusAndEmpty() {
  NovaUIContent c = {};
  c.preedit = "ab";
  c.sel_location = -1;
  c.letters = "";
  {
    Laid L(c, 15, false, false, 900, false);  // 状态消息：一行字，有底色
    CHECK(L.v->card);
    CHECK(L.v->run_count == 1);
    CHECK_STR(L.v->runs[0].text, "ab");
    CHECK_NEAR(L.v->runs[0].x, 10);
    CHECK_NEAR(L.v->runs[0].baseline, 10 + 23 / 2.0 + 15 * 0.38);  // rowHeight = ceil(22.5) = 23
    CHECK(L.v->runs[0].color == NOVA_COLOR_PRIMARY && L.v->runs[0].hl_start < 0);
    CHECK_NEAR(L.v->width, std::ceil(10 + 20) + 10);
    CHECK_NEAR(L.v->height, std::ceil(10 + 23) + 10);
  }
  {
    NovaUIContent e = {};  // 空内容
    e.preedit = "";
    e.sel_location = -1;
    e.letters = "";
    Laid L(e, 15, false, false, 900, false);
    CHECK(L.v->card && L.v->run_count == 0 && L.v->box_count == 0 && L.v->hit_count == 0);
    CHECK_NEAR(L.v->width, 10);
    CHECK_NEAR(L.v->height, 20);
  }
  {
    c.sel_location = 1;  // 有效选中范围：已转换 DIM，选中 PRIMARY
    c.sel_length = 1;
    Laid L(c, 15, false, false, 900, false);
    CHECK(L.v->runs[0].color == NOVA_COLOR_DIM && L.v->runs[0].hl_start == 1 && L.v->runs[0].hl_end == 2);
    CHECK(L.v->runs[0].hl_color == NOVA_COLOR_PRIMARY);
    c.sel_length = 5;  // 超出长度：当作无效
    Laid M(c, 15, false, false, 900, false);
    CHECK(M.v->runs[0].hl_start < 0 && M.v->runs[0].color == NOVA_COLOR_PRIMARY);
    c.sel_location = 0;  // UTF-16 码元：「𠮷」占两个
    c.sel_length = 2;
    c.preedit = "\xF0\xA0\xAE\xB7";
    Laid N(c, 15, false, false, 900, false);
    CHECK(N.v->runs[0].hl_start == 0 && N.v->runs[0].hl_end == 2);
  }
}

static void TestLayoutTree() {
  std::string tree = Line("0", 0, 2, "wo", "我") + Line("0f", 2, 4, "ni", "你好", {std::string("泥") + US + "5", "尼"});
  NovaUITree* t = nova_ui_tree_parse(tree.c_str());
  NovaUIContent c = ContentFromTree(t);
  {
    Laid L(c, 15, false, false, 900, false);  // 往下长，字体 15：chip 高 ceil(24) = 24，备选行 23 + 3
    CHECK(!L.v->card);
    // 词块宽：「我」10+16 = 26；「你好」20+16 = 36
    CHECK(L.v->hit_count == 4);
    CHECK(L.v->hits[0].action == NOVA_ACTION_FOCUS && L.v->hits[0].value == 0);
    CHECK_NEAR(L.v->hits[0].rect.x, 10);
    CHECK_NEAR(L.v->hits[0].rect.y, 10);
    CHECK_NEAR(L.v->hits[0].rect.width, 26);
    CHECK_NEAR(L.v->hits[0].rect.height, 24);
    CHECK_NEAR(L.v->hits[1].rect.x, 10 + 26 + 12);
    CHECK_NEAR(L.v->hits[1].rect.width, 36);
    CHECK(L.v->hits[2].action == NOVA_ACTION_PIN && L.v->hits[2].value == 1);  // 焦点块的备选从 1 编号
    CHECK(L.v->hits[3].value == 2);
    // 连线夹在两个词块之间，颜色是后一块的（蓝）
    CHECK(L.v->link_count == 1);
    CHECK_NEAR(L.v->links[0].rect.x, 10 + 26 - 2);
    CHECK_NEAR(L.v->links[0].rect.width, 12 + 4);
    CHECK_NEAR(L.v->links[0].rect.height, 3);
    CHECK_NEAR(L.v->links[0].rect.y, 10 + 12 - 1.5);
    CHECK(L.v->links[0].color == NOVA_COLOR_BLUE);
    // 焦点块用 FOCUS 底色，字是黑的
    CHECK(L.v->boxes[1].color == NOVA_COLOR_FOCUS);
    CHECK(L.Run("你好")->color == NOVA_COLOR_BLACK);
    CHECK(L.Run("我")->color == NOVA_COLOR_CHIP_TEXT);
    // 备选 cell：x = 词块 x + 16；第一行 y = 10 + 24 + 5
    CHECK_NEAR(L.v->hits[2].rect.x, 48 + 16);
    CHECK_NEAR(L.v->hits[2].rect.y, 10 + 24 + 5);
    CHECK_NEAR(L.v->hits[3].rect.y, 10 + 24 + 5 + 26);
    CHECK_NEAR(L.v->hits[2].rect.height, 23);
    // 宽 = 6*2 + ceil(label 6) + 4 + ceil(text 10) = 32
    CHECK_NEAR(L.v->hits[2].rect.width, 32);
    // 分支路径：3 段主干 + 每个备选 4 段（含一个曲线）
    CHECK(L.v->path_count == 3 + 4 * 2);
    CHECK(L.v->path[0].kind == NOVA_PATH_MOVE && L.v->path[3].kind == NOVA_PATH_MOVE && L.v->path[5].kind == NOVA_PATH_CURVE);
    CHECK_NEAR(L.v->path[0].x, 48 + 6);
    CHECK_NEAR(L.v->path[0].y, 10 + 24);
    CHECK_NEAR(L.v->path[5].c1x, L.v->path[5].c2x);  // 控制点重合在转角
    CHECK(L.Run("1") && L.Run("1")->font == NOVA_FONT_LABEL && L.Run("1")->color == NOVA_COLOR_DIM);
    CHECK_NEAR(L.v->height, std::ceil(10 + 24 + 5 + 2 * 26) + 10);
    CHECK_NEAR(L.v->width, 64 + 32 + 10);
  }
  {
    Laid L(c, 15, false, true, 900, false);  // 显示比例：每个有比例的项下面多 13 高
    CHECK(L.Run("5") && L.Run("5")->font == NOVA_FONT_SHARE && L.Run("5")->color == NOVA_COLOR_SHARE);
    CHECK_NEAR(L.v->hits[3].rect.y - L.v->hits[2].rect.y, 23 + 13);
  }
  {
    Laid L(c, 15, false, false, 900, true);  // 往上长：词块在整排的底部，备选在上面
    const double tier_height = 24 + 5 + 2 * 26;
    // 词块的下边在 top + height（top = 10，没有字母行）
    CHECK_NEAR(L.v->hits[0].rect.y + L.v->hits[0].rect.height, 10 + tier_height);
    CHECK(L.v->hits[2].rect.y < L.v->hits[0].rect.y);
    CHECK(L.v->hits[3].rect.y > L.v->hits[2].rect.y);  // 编号仍从上往下读：第二个备选在第一个下面
    CHECK(L.v->hits[3].rect.y < L.v->hits[0].rect.y);  // 两个备选都在词块上方
  }
  {
    Laid L(c, 15, false, false, 60, false);  // 很窄：每块各占一排（limit = 40，36 放得下一块）
    CHECK_NEAR(L.v->hits[0].rect.x, 10);
    CHECK_NEAR(L.v->hits[1].rect.x, 10);
    CHECK(L.v->hits[1].rect.y > L.v->hits[0].rect.y + 24);
    CHECK(L.v->link_count == 0);
  }
  nova_ui_tree_free(t);
}

static void TestLayoutOverviewAndPage() {
  std::string tree = Line("0", 0, 2, "a", "甲") + Line("0uo", 2, 4, "b", "乙", {"乙1", "乙2"}) +
                     Line("0uo", 4, 6, "c", "丙", {"丙1"}) + Line("0", 6, 8, "d", "丁", {"丁1"});
  NovaUITree* t = nova_ui_tree_parse(tree.c_str());
  NovaUIContent c = ContentFromTree(t);
  Laid L(c, 15, false, false, 900, false);
  // 没有焦点：只有 o 块显示备选，数字键连续编号 1,2,3
  int pins = 0, last = 0;
  for (int i = 0; i < L.v->hit_count; i++) {
    if (L.v->hits[i].action == NOVA_ACTION_PIN) {
      pins++;
      CHECK(L.v->hits[i].value == ++last);
    }
  }
  CHECK(pins == 3);
  int orange = 0;
  for (int i = 0; i < L.v->box_count; i++) orange += L.v->boxes[i].color == NOVA_COLOR_ORANGE;
  CHECK(orange == 2);  // 两个 o 块；备选格是 ALT_FILL
  // 橙块和后一块之间的连线用后一块的颜色
  CHECK(L.v->link_count == 3 && L.v->links[0].color == NOVA_COLOR_ORANGE && L.v->links[2].color == NOVA_COLOR_BLUE);
  nova_ui_tree_free(t);

  // 备选分页：页码标在最后一个备选右边；h 标出的当前项铺蓝色
  tree = Line("0fp2/5h2", 0, 2, "a", "甲", {"甲1", "甲2", "甲3"});
  t = nova_ui_tree_parse(tree.c_str());
  c = ContentFromTree(t);
  Laid P(c, 15, false, false, 900, false);
  const NovaUIRun* page = P.Run("\xE2\x80\xB9 2/5 \xE2\x80\xBA");
  CHECK(page != nullptr && page->font == NOVA_FONT_LABEL);
  // 备选 cell 宽 = 12 + 6 + 4 + ceil(30) = 52 ... 「甲1」两个字：20
  const NovaUIHit& last_alt = P.v->hits[3];
  CHECK_NEAR(page->x, last_alt.rect.x + last_alt.rect.width + 8);
  int blue = 0;
  for (int i = 0; i < P.v->box_count; i++) blue += P.v->boxes[i].color == NOVA_COLOR_BLUE;
  CHECK(blue == 1 && P.v->boxes[2].color == NOVA_COLOR_BLUE);  // 第二个备选
  nova_ui_tree_free(t);
}

static void TestLayoutLetters() {
  std::string tree = Line("0", 0, 2, "wo", "我") + Line("0f", 2, 4, "ni", "你");
  NovaUITree* t = nova_ui_tree_parse(tree.c_str());
  NovaUIContent c = ContentFromTree(t);
  c.letters = "woni";
  c.cursor = 3;
  {
    Laid L(c, 15, false, false, 900, false);  // 字母行在最上面，字母宽 ceil(8) = 8，行高 23
    // 底：整行 insetBy(-8)；然后每块一条线；最后光标
    CHECK(L.v->boxes[0].color == NOVA_COLOR_ALT_FILL);
    CHECK_NEAR(L.v->boxes[0].rect.x, 10);
    CHECK_NEAR(L.v->boxes[0].rect.width, 4 * 8 + 16);
    CHECK(L.v->boxes[1].color == NOVA_COLOR_BLUE && L.v->boxes[2].color == NOVA_COLOR_FOCUS);
    CHECK_NEAR(L.v->boxes[1].rect.x, 18 + 1);
    CHECK_NEAR(L.v->boxes[1].rect.width, 2 * 8 - 2);
    CHECK_NEAR(L.v->boxes[1].rect.height, 2);
    // 光标：x = 18 + 3 * 8 - 1，宽 2，高 rowHeight - 6，圆角 1
    bool found = false;
    for (int i = 0; i < L.v->box_count; i++) {
      const NovaUIBox& b = L.v->boxes[i];
      if (b.color == NOVA_COLOR_FOCUS && b.radius == 1) {
        found = true;
        CHECK_NEAR(b.rect.x, 18 + 24 - 1);
        CHECK_NEAR(b.rect.width, 2);
        CHECK_NEAR(b.rect.height, 23 - 6);
      }
    }
    CHECK(found);
    // 点字母：光标移到它后面（第 i 个字母 -> i+1）
    int cursors = 0;
    for (int i = 0; i < L.v->hit_count; i++) {
      if (L.v->hits[i].action == NOVA_ACTION_CURSOR) CHECK(L.v->hits[i].value == ++cursors);
    }
    CHECK(cursors == 4);
    CHECK_NEAR(L.v->hits[0].rect.y, 10);  // 往下长：字母行在最上面
  }
  {
    Laid L(c, 15, false, false, 900, true);  // 往上长：字母行在最下面（词块之后），上面多 6
    double letter_y = 0;
    for (int i = 0; i < L.v->hit_count; i++) {
      if (L.v->hits[i].action == NOVA_ACTION_CURSOR) letter_y = L.v->hits[i].rect.y;
    }
    CHECK(letter_y > 10 + 24);
  }
  {
    // 全拼：letters 是拼音，块范围和光标是编码位置，按 letter_map 转换
    c.letters = "wo'ni";
    int map[] = {0, 1, 2, 4, 5};
    c.letter_map = map;
    c.letter_map_count = 5;
    c.cursor = 4;
    Laid L(c, 15, false, false, 900, false);
    // 块 [0,2) 对应拼音位置 [0,2)；块 [2,4) 对应 [2,5)
    CHECK_NEAR(L.v->boxes[1].rect.width, 2 * 8 - 2);
    CHECK_NEAR(L.v->boxes[2].rect.width, 3 * 8 - 2);
    // 点第 2 个字母（拼音下标 1，落在「wo」里）：编码位置是第一个不小于 2 的 -> 2
    // 点撇号（下标 2）：不小于 3 的最小值在编码位置 3（map[3]=4）
    int values[5], k = 0;
    for (int i = 0; i < L.v->hit_count; i++) if (L.v->hits[i].action == NOVA_ACTION_CURSOR) values[k++] = L.v->hits[i].value;
    CHECK(k == 5);
    CHECK(values[1] == 2 && values[2] == 3 && values[4] == 4);
    // 字母着色：被块覆盖的是白色，撇号（下标 2）也在块 [2,5) 内
    CHECK(L.v->runs[0].color == NOVA_COLOR_PRIMARY);
  }
  nova_ui_tree_free(t);
}

static void TestLayoutList() {
  NovaUICandidate cands[] = {{"1", "你好", ""}, {"2", "你", "注"}, {"3", "拟好吗", ""}};
  NovaUIContent c = {};
  c.preedit = "nihao";
  c.sel_location = 0;
  c.sel_length = 5;
  c.letters = "";
  c.candidates = cands;
  c.candidate_count = 3;
  c.highlighted = 1;
  {
    Laid L(c, 15, false, false, 900, false);  // 竖排：每行同宽，一行一个
    CHECK(L.v->card);
    CHECK(L.v->hit_count == 3 && L.v->hits[0].action == NOVA_ACTION_SELECT && L.v->hits[2].value == 2);
    // 最宽：6*2 + 序号 6 + 4 + 正文 30 = 52；「你」带注释：12 + 6+4 + 10 + 6+4 = 42
    CHECK_NEAR(L.v->hits[0].rect.width, 52);
    CHECK_NEAR(L.v->hits[2].rect.width, 52);
    CHECK_NEAR(L.v->hits[1].rect.y - L.v->hits[0].rect.y, 23);
    CHECK(L.v->box_count == 1 && L.v->boxes[0].color == NOVA_COLOR_BLUE);
    CHECK_NEAR(L.v->boxes[0].rect.y, L.v->hits[1].rect.y);
    CHECK_NEAR(L.v->boxes[0].radius, 6);
    // preedit 一行 23 + 6，候选从 10 + 29 开始
    CHECK_NEAR(L.v->hits[0].rect.y, 10 + 23 + 6);
    CHECK_NEAR(L.v->height, std::ceil(10 + 29 + 3 * 23) + 10);
    CHECK(L.Run("注") && L.Run("注")->font == NOVA_FONT_LABEL);
  }
  {
    Laid L(c, 15, true, false, 900, false);  // 横排：按各自宽度依次排
    CHECK_NEAR(L.v->hits[0].rect.y, L.v->hits[1].rect.y);
    CHECK_NEAR(L.v->hits[0].rect.width, 12 + 6 + 4 + 20);
    CHECK_NEAR(L.v->hits[1].rect.x, 10 + L.v->hits[0].rect.width);
    CHECK_NEAR(L.v->height, std::ceil(10 + 29 + 23) + 10);
  }
  {
    Laid L(c, 15, true, false, 100, false);  // 横排放不下：折到下一排（limit = 90）
    CHECK_NEAR(L.v->hits[0].rect.x, 10);
    CHECK(L.v->hits[1].rect.y == L.v->hits[0].rect.y || L.v->hits[1].rect.x == 10);
    bool wrapped = false;
    for (int i = 1; i < 3; i++) wrapped = wrapped || L.v->hits[i].rect.y > L.v->hits[0].rect.y;
    CHECK(wrapped);
  }
  NovaUIStyle s = {};  // fullHeight：20 + 24 + 0 + 5 + 6 * 26
  s.font_size = 15;
  CHECK_NEAR(nova_ui_full_height(&s), 20 + 24 + 5 + 6 * 26);
  s.show_share = 1;
  CHECK_NEAR(nova_ui_full_height(&s), 20 + 24 + 13 + 5 + 6 * (23 + 13));
  CHECK_NEAR(nova_ui_corner_radius(), 10);
  CHECK_NEAR(nova_ui_edge(), 10);
}

static void TestTheme() {
  // 默认主题和默认颜色表一致，dump 再 parse 回来不变。
  NovaUITheme* t = nova_ui_theme_new();
  double a[4], b[4];
  for (int i = 0; i < NOVA_COLOR_COUNT; i++) {
    nova_ui_theme_color(t, static_cast<NovaUIColor>(i), a);
    nova_ui_default_color(static_cast<NovaUIColor>(i), b);
    for (int k = 0; k < 4; k++) CHECK(std::fabs(a[k] - b[k]) < 1.0 / 255);
  }
  CHECK_STR(nova_ui_theme_check(t), "");
  const std::string dumped = nova_ui_theme_dump(t);
  NovaUITheme* back = nova_ui_theme_parse(dumped.c_str());
  CHECK_STR(nova_ui_theme_problems(back), "");
  CHECK_STR(nova_ui_theme_dump(back), dumped);
  nova_ui_theme_free(back);

  // set / get：颜色、数字夹到范围、非法值不改。
  CHECK(nova_ui_theme_set(t, "colors/blue", "#112233"));
  CHECK_STR(nova_ui_theme_get(t, "colors/blue"), "#112233");
  CHECK(nova_ui_theme_set(t, "colors/blue", "11223380"));
  CHECK_STR(nova_ui_theme_get(t, "colors/blue"), "#11223380");
  CHECK(!nova_ui_theme_set(t, "colors/blue", "#12"));
  CHECK_STR(nova_ui_theme_get(t, "colors/blue"), "#11223380");
  CHECK(nova_ui_theme_set(t, "font/size", "99"));
  CHECK_STR(nova_ui_theme_get(t, "font/size"), "40");
  CHECK(!nova_ui_theme_set(t, "font/size", "abc"));
  CHECK(!nova_ui_theme_set(t, "appearance", "blue"));
  CHECK(nova_ui_theme_set(t, "appearance", "light"));
  CHECK(!nova_ui_theme_set(t, "nope", "1"));
  CHECK(nova_ui_theme_get(t, "nope") == nullptr);
  nova_ui_theme_free(t);

  // parse：小节、引号、注释、不认识的键、缺的字段用默认。
  t = nova_ui_theme_parse(
      "\xEF\xBB\xBF# 注释\n"
      "version: 1\n"
      "name: \"浅 #色\"  # 引号里的 # 不是注释\n"
      "appearance: light\n"
      "font:\n"
      "  face: 'PingFang SC, Microsoft YaHei'\n"
      "  size: 18\n"
      "shape:\n"
      "  chip_radius: 0\n"
      "  wobble: 3\n"
      "colors:\n"
      "  blue: \"#0000ff\"\n"
      "  green: 绿\n"
      "oops\n");
  CHECK_STR(nova_ui_theme_get(t, "name"), "浅 #色");
  CHECK_STR(nova_ui_theme_get(t, "appearance"), "light");
  CHECK_STR(nova_ui_theme_get(t, "font/face"), "PingFang SC, Microsoft YaHei");
  CHECK_STR(nova_ui_theme_get(t, "colors/blue"), "#0000ff");
  CHECK_STR(nova_ui_theme_get(t, "shape/edge"), "10");
  const std::string problems = nova_ui_theme_problems(t);
  CHECK(problems.find("第 10 行") != std::string::npos);  // wobble
  CHECK(problems.find("第 13 行") != std::string::npos);  // 绿
  CHECK(problems.find("第 14 行") != std::string::npos);  // oops
  NovaUIStyle s = {};
  s.linear = 1;
  nova_ui_theme_style(t, &s);
  CHECK_NEAR(s.font_size, 18);
  CHECK(s.linear == 1);
  CHECK(s.chip_radius > 0 && s.chip_radius < 1e-6);  // 0 圆角是真的 0，不是「用默认」
  CHECK_NEAR(s.card_radius, 10);
  nova_ui_theme_free(t);

  // check：字看不清、两种词块颜色太像。
  t = nova_ui_theme_new();
  nova_ui_theme_set(t, "colors/chip_text", "#ffffff");
  nova_ui_theme_set(t, "colors/green", "#eeeeee");
  nova_ui_theme_set(t, "colors/purple", nova_ui_theme_get(t, "colors/blue"));
  const std::string warn = nova_ui_theme_check(t);
  CHECK(warn.find("「选过的词」上的「词块上的字」") != std::string::npos);
  CHECK(warn.find("「普通词块」和「改过的词」颜色太像") != std::string::npos);
  nova_ui_theme_free(t);

  // 圆角、留白真的进了排版。
  NovaUIStyle round = {};
  round.font_size = 15;
  NovaUIStyle square = round;
  square.card_radius = 1e-9;
  square.edge = 4;
  CHECK_NEAR(nova_ui_style_corner_radius(&round), 10);
  CHECK(nova_ui_style_corner_radius(&square) < 1e-6);
  CHECK_NEAR(nova_ui_style_edge(&square), 4);
}

static void TestThemeFiles() {
  namespace fs = std::filesystem;
  const fs::path root = fs::temp_directory_path() / "nova_ui_theme_test";
  fs::remove_all(root);
  fs::create_directories(root / "shared");
  fs::create_directories(root / "user");
  NovaUITheme* t = nova_ui_theme_new();
  CHECK(nova_ui_theme_save(t, (root / "shared" / "dark.yaml").string().c_str()));
  nova_ui_theme_set(t, "name", "浅色");
  nova_ui_theme_set(t, "appearance", "light");
  CHECK(nova_ui_theme_save(t, (root / "shared" / "light.yaml").string().c_str()));
  nova_ui_theme_set(t, "name", "我的浅色");
  CHECK(nova_ui_theme_save(t, (root / "user" / "light.yaml").string().c_str()));
  CHECK(!fs::exists(root / "user" / "light.yaml.tmp"));
  nova_ui_theme_free(t);
  std::ofstream(root / "user" / "notes.txt") << "x";

  NovaUIThemeList* list =
      nova_ui_theme_list((root / "shared").string().c_str(), (root / "user").string().c_str());
  int n = 0;
  const NovaUIThemeEntry* e = nova_ui_theme_list_entries(list, &n);
  CHECK(n == 2);
  if (n == 2) {
    CHECK_STR(e[0].id, "dark");
    CHECK_STR(e[0].name, "深色");
    CHECK(e[0].user == 0);
    CHECK_STR(e[1].id, "light");
    CHECK_STR(e[1].name, "我的浅色");  // 用户的覆盖自带的
    CHECK_STR(e[1].appearance, "light");
    CHECK(e[1].user == 1);
    NovaUITheme* loaded = nova_ui_theme_load(e[1].path);
    CHECK(loaded != nullptr);
    if (loaded) CHECK_STR(nova_ui_theme_get(loaded, "name"), "我的浅色");
    nova_ui_theme_free(loaded);
  }
  nova_ui_theme_list_free(list);
  CHECK(nova_ui_theme_load((root / "missing.yaml").string().c_str()) == nullptr);
  list = nova_ui_theme_list((root / "missing").string().c_str(), nullptr);
  nova_ui_theme_list_entries(list, &n);
  CHECK(n == 0);
  nova_ui_theme_list_free(list);
  fs::remove_all(root);
}

int main() {
  TestParse();
  TestPalette();
  TestAssemble();
  TestLayoutStatusAndEmpty();
  TestLayoutTree();
  TestLayoutOverviewAndPage();
  TestLayoutLetters();
  TestLayoutList();
  TestTheme();
  TestThemeFiles();
  std::printf("%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
