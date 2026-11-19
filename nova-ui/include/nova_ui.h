/*
 * nova_ui.h
 * Nova 候选面板里和平台无关的部分：数据模型、nova_tree 解析、内容组装、排版。
 *
 * 只暴露 C API，所以 Swift（macOS）、C++/DirectWrite（Windows）、fcitx5（Linux）都能直接调。
 * 这里只算「要画什么、画在哪」，不碰窗口、字体、颜色数值：
 *   - 文字测宽由平台提供回调（文本 + 字体角色 -> 宽度），字号由平台传入；
 *   - 颜色只给语义（NovaUIColor），具体数值由平台映射，nova_ui_default_color 给一张默认表；
 *   - 输出是显示列表：圆角矩形、连线、文字 run、分支路径、点击区、尺寸。
 * 所有字符串是 UTF-8；所有坐标是「左上角为原点、y 向下」的面板坐标。
 * 所有字符串指针和数组的生命周期跟着返回它们的句柄，句柄 free 之后不能再用。
 */
#ifndef NOVA_UI_H_
#define NOVA_UI_H_

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 颜色语义 ---- */

/* 绿：用户选过。紫：语法推翻了词频（多半是对的）。橙：解码器拿不准。蓝：普通。
 * 焦点块要在深浅窗口上都醒目，白色和黑色都不行，所以单独一个 FOCUS。
 * 全部是实色，没有透明度和描边。 */
typedef enum {
  NOVA_COLOR_BLUE = 0,
  NOVA_COLOR_ORANGE,
  NOVA_COLOR_PURPLE,
  NOVA_COLOR_GREEN,
  NOVA_COLOR_FOCUS,
  NOVA_COLOR_ALT_FILL,   /* 备选格、字母行的底色 */
  NOVA_COLOR_ALT_HOVER,  /* 鼠标悬停的备选格（只有平台知道悬停，排版不输出它） */
  NOVA_COLOR_CARD,       /* 普通列表和状态消息的整块底色 */
  NOVA_COLOR_BRANCH,     /* 分支线的描边色 */
  NOVA_COLOR_PRIMARY,    /* 主文字（白） */
  NOVA_COLOR_DIM,        /* 次要文字 */
  NOVA_COLOR_SHARE,      /* 词频比例的小字 */
  NOVA_COLOR_BLACK,      /* 焦点块（黄底）上的字 */
  NOVA_COLOR_COUNT
} NovaUIColor;

/* 默认调色板，sRGB，分量 0..1。平台可以直接用，也可以换成自己的。 */
void nova_ui_default_color(NovaUIColor color, double rgba[4]);

/* ---- 字体角色 ---- */

typedef enum {
  NOVA_FONT_BODY = 0, /* 正文，字号由平台传入 */
  NOVA_FONT_LABEL,    /* 序号、页码、注释：等宽数字，字号 round(正文 * 0.68) */
  NOVA_FONT_SHARE,    /* 词频比例：等宽数字，字号 round(正文 * 0.62) */
  NOVA_FONT_LETTER    /* 原始字母行：等宽，字号 round(正文 * 0.9) */
} NovaUIFont;

/* 某个角色的字号（点）。 */
double nova_ui_font_size(NovaUIFont font, double body_size);

/* 文字测宽回调：text 是 UTF-8、以 NUL 结尾；返回按该角色字体排版后的宽度。 */
typedef double (*NovaUIMeasureFn)(const char* text, NovaUIFont font, void* user);

/* ---- 数据模型 ---- */

typedef struct {
  const char* text;
  int has_share; /* 词库里没有比例时为 0 */
  int share;     /* 在同一段候选里占的词频比例（0-100），不是真实概率 */
} NovaUIChoice;

typedef struct {
  /* 这块在原始字母里的范围（第几个字母）。 */
  int from;
  int to;
  int pinned;
  int focused;
  int corrected;
  /* 换几个上下文窗口解码，这块的结果不一样：解码器拿不准，标橙。 */
  int uncertain;
  /* 没有焦点时直接显示备选的不确定块。 */
  int overview;
  NovaUIChoice word;
  const NovaUIChoice* alts;
  int alt_count;
  /* 焦点块的备选分页时的「第几页/共几页」，不分页时为空串。 */
  const char* page;
  /* ↓/↑ 换词时当前用的是这一页的第几个备选（从 1 起）。 */
  int has_current;
  int current;
  /* 原样的标记字段，只给界面日志用。 */
  const char* flags;
} NovaUIBlock;

typedef struct {
  const char* label;
  const char* text;
  const char* comment;
} NovaUICandidate;

typedef struct {
  const char* preedit;
  /* 选中范围，单位是 UTF-16 码元（和 Swift/Windows 的字符串索引一致）。
   * sel_location < 0 表示无效范围：整行都是正文（状态消息）；
   * 有效范围表示其余部分是已转换或未选中的输入。 */
  int sel_location;
  int sel_length;
  const NovaUIBlock* blocks;
  int block_count;
  /* 原始字母和光标位置（第几个字母之前）。空串表示不显示字母行。 */
  const char* letters;
  int cursor;
  /* 全拼时 letters 是拼音，而光标和词块范围是双拼编码里的位置：letter_map[编码位置] = 拼音位置。
   * 空表示 letters 就是编码。 */
  const int* letter_map;
  int letter_map_count;
  const NovaUICandidate* candidates;
  int candidate_count;
  int highlighted;
} NovaUIContent;

/* ---- nova_tree 解析 ---- */

typedef struct NovaUITree NovaUITree;
/* nova_tree 属性：每块一行，格式见 nova-schema/lua/nova_sentences.lua。 */
NovaUITree* nova_ui_tree_parse(const char* tree);
const NovaUIBlock* nova_ui_tree_blocks(const NovaUITree* tree, int* count);
void nova_ui_tree_free(NovaUITree* tree);

/* 块的颜色语义（界面日志的颜色名也按这个：绿/紫/橙/蓝）。 */
NovaUIColor nova_ui_block_color(const NovaUIBlock* block);
const char* nova_ui_block_tone(const NovaUIBlock* block); /* "green" "purple" "orange" "blue" */

/* 拼音位置 <-> 编码位置，规则见 NovaUIContent.letter_map。 */
int nova_ui_letter_position(const NovaUIContent* content, int code);
int nova_ui_code_position(const NovaUIContent* content, int letter);

/* ---- 内容组装 ---- */

/* 决定显示树还是普通列表、字母行显示什么：纯数据输入，不依赖平台。
 * 所有字符串指针可以为 NULL（等同没有这个属性）。 */
typedef struct {
  /* rime 的输入串（get_input）。 */
  const char* input;
  /* 属性 nova_tree、nova_list、nova_cursor、nova_qp_raw、nova_qp_map；没有这个属性传 NULL。 */
  const char* prop_tree;
  const char* prop_list;
  const char* prop_cursor;
  const char* prop_qp_raw;
  const char* prop_qp_map;
  /* 菜单状态。 */
  int page_no;
  int highlighted;
  int num_candidates;
  /* rime 的 preedit 和选中范围（UTF-16 码元，<0 为无效）。 */
  const char* preedit;
  int sel_location;
  int sel_length;
  /* 输入框里已经内嵌显示 preedit 时，面板里不再重复。 */
  int inline_preedit;
  /* 候选，labels 可以比 count 短，缺的按序号补。 */
  int count;
  const char* const* texts;
  const char* const* comments;
  const char* const* labels;
  int label_count;
} NovaUIAssembleInput;

typedef struct NovaUIContentHandle NovaUIContentHandle;
NovaUIContentHandle* nova_ui_assemble(const NovaUIAssembleInput* input);
const NovaUIContent* nova_ui_content_view(const NovaUIContentHandle* handle);
void nova_ui_content_free(NovaUIContentHandle* handle);

/* ---- 排版 ---- */

typedef struct {
  double font_size; /* 正文字号 */
  int linear;       /* 普通列表横排 */
  int show_share;   /* 在词和备选下面显示词频比例，对应 style/show_share */
} NovaUIStyle;

typedef struct {
  double x, y, width, height;
} NovaUIRect;

typedef struct {
  NovaUIRect rect;
  double radius;
  NovaUIColor color;
} NovaUIBox;

typedef struct {
  const char* text;
  NovaUIFont font;
  double font_size;
  NovaUIColor color;
  /* 高亮子串（UTF-16 码元 [hl_start, hl_end)）用 hl_color；hl_start < 0 表示没有。
   * 只有 preedit 用：已转换部分是 DIM，选中部分是 PRIMARY。 */
  int hl_start;
  int hl_end;
  NovaUIColor hl_color;
  double x;
  /* 基线的 y。画的时候原点就是基线，字体回退不会让行之间错位。 */
  double baseline;
} NovaUIRun;

typedef enum { NOVA_PATH_MOVE = 0, NOVA_PATH_LINE, NOVA_PATH_CURVE } NovaUIPathKind;
/* 分支路径：MOVE/LINE 用 (x, y)；CURVE 是三次贝塞尔，终点 (x, y)，控制点 (c1x, c1y)、(c2x, c2y)。
 * 用 NOVA_COLOR_BRANCH 描边，线宽 1，不填充。 */
typedef struct {
  NovaUIPathKind kind;
  double x, y;
  double c1x, c1y, c2x, c2y;
} NovaUIPathSeg;

typedef enum {
  NOVA_ACTION_SELECT = 0, /* 选第 value 个候选（当前页，从 0 起） */
  NOVA_ACTION_PIN,        /* 第 value 个备选（从 1 起），和数字键同一个编号 */
  NOVA_ACTION_FOCUS,      /* 第 value 个词块成为焦点（光标移到它的末尾） */
  NOVA_ACTION_CURSOR      /* 把原始字母光标移到第 value 个字母之前 */
} NovaUIActionKind;

typedef struct {
  NovaUIRect rect;
  NovaUIActionKind action;
  int value;
} NovaUIHit;

typedef struct {
  double width, height;
  /* 只有普通列表和状态消息有底色（整块圆角 nova_ui_corner_radius，CARD 色）；
   * 树直接浮在文字下方，没有边缘可以跳动。 */
  int card;
  /* 绘制顺序：card 底色 -> links（填充矩形）-> path 描边 -> boxes（圆角矩形）-> runs。 */
  const NovaUIBox* links;
  int link_count;
  const NovaUIPathSeg* path;
  int path_count;
  const NovaUIBox* boxes;
  int box_count;
  const NovaUIRun* runs;
  int run_count;
  const NovaUIHit* hits;
  int hit_count;
} NovaUILayoutView;

typedef struct NovaUILayout NovaUILayout;

/* upward：放在光标上方时，词块贴着光标，备选往上长。max_width 是面板最大宽度，放不下时词块另起一排。 */
NovaUILayout* nova_ui_layout_create(const NovaUIContent* content, const NovaUIStyle* style,
                                    NovaUIMeasureFn measure, void* user, double max_width, int upward);
const NovaUILayoutView* nova_ui_layout_view(const NovaUILayout* layout);
void nova_ui_layout_free(NovaUILayout* layout);

/* 词块加满备选的高度，用来判断光标下方放不放得下。 */
double nova_ui_full_height(const NovaUIStyle* style);
double nova_ui_corner_radius(void);
double nova_ui_edge(void);

#ifdef __cplusplus
}
#endif
#endif /* NOVA_UI_H_ */
