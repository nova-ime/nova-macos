// 主题：读写主题文件、按主题给颜色和形状、检查对比度。C API 见 nova_ui.h 的「主题」一节。
// 只认 yaml 的一个子集（见 nova_ui.h），所以不依赖 yaml 库，Windows 和 macOS 用同一份代码。
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "../include/nova_ui.h"

namespace fs = std::filesystem;

namespace {

struct Field {
  NovaUIThemeField f;
  NovaUIColor color;  // 只有 COLOR 用
};

// 文件里的顺序、设置面板里的顺序都按这张表。
const Field kFields[] = {
    {{"name", "信息", "名字", "设置里显示的名字", NOVA_THEME_TEXT, 0, 0, 0, nullptr}, NOVA_COLOR_COUNT},
    {{"author", "信息", "作者", "", NOVA_THEME_TEXT, 0, 0, 0, nullptr}, NOVA_COLOR_COUNT},
    {{"appearance", "信息", "深浅", "dark 深色 / light 浅色；「跟随系统」时按它分组", NOVA_THEME_CHOICE, 0, 0, 0,
      "dark,light"},
     NOVA_COLOR_COUNT},
    {{"font/face", "字体", "正文字体", "空为系统字体；可写多个，逗号分隔，前面的优先", NOVA_THEME_TEXT, 0, 0, 0, nullptr},
     NOVA_COLOR_COUNT},
    {{"font/mono", "字体", "等宽字体", "序号、字母行用；空为系统等宽字体", NOVA_THEME_TEXT, 0, 0, 0, nullptr},
     NOVA_COLOR_COUNT},
    {{"font/size", "字体", "字号", "正文字号（点），序号和字母行按比例跟着变", NOVA_THEME_NUMBER, 10, 40, 1, nullptr},
     NOVA_COLOR_COUNT},
    {{"shape/card_radius", "形状", "底板圆角", "普通候选列表底板的圆角", NOVA_THEME_NUMBER, 0, 24, 1, nullptr},
     NOVA_COLOR_COUNT},
    {{"shape/chip_radius", "形状", "词块圆角", "词块、备选格的圆角", NOVA_THEME_NUMBER, 0, 16, 1, nullptr},
     NOVA_COLOR_COUNT},
    {{"shape/edge", "形状", "四周留白", "", NOVA_THEME_NUMBER, 2, 30, 1, nullptr}, NOVA_COLOR_COUNT},
    {{"shape/chip_padding", "形状", "词块左右留白", "", NOVA_THEME_NUMBER, 2, 24, 1, nullptr}, NOVA_COLOR_COUNT},
    {{"shape/column_gap", "形状", "词块间距", "", NOVA_THEME_NUMBER, 0, 40, 1, nullptr}, NOVA_COLOR_COUNT},
    {{"shape/row_height", "形状", "行高", "行高是字号的几倍", NOVA_THEME_NUMBER, 1.1, 2.5, 0.05, nullptr},
     NOVA_COLOR_COUNT},
    {{"shape/chip_height", "形状", "词块高度", "词块高是字号的几倍", NOVA_THEME_NUMBER, 1.1, 2.5, 0.05, nullptr},
     NOVA_COLOR_COUNT},
    {{"colors/blue", "颜色", "普通词块", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_BLUE},
    {{"colors/purple", "颜色", "改过的词", "Nova 结合上下文改过的词", NOVA_THEME_COLOR, 0, 0, 0, nullptr},
     NOVA_COLOR_PURPLE},
    {{"colors/orange", "颜色", "拿不准的词", "多在打错键时出现", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_ORANGE},
    {{"colors/green", "颜色", "选过的词", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_GREEN},
    {{"colors/chip_text", "颜色", "词块上的字", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_CHIP_TEXT},
    {{"colors/focus", "颜色", "焦点词块", "也是字母行光标的颜色", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_FOCUS},
    {{"colors/focus_text", "颜色", "焦点上的字", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_BLACK},
    {{"colors/alt_fill", "颜色", "备选格", "备选格、字母行的底色", NOVA_THEME_COLOR, 0, 0, 0, nullptr},
     NOVA_COLOR_ALT_FILL},
    {{"colors/alt_hover", "颜色", "悬停的备选格", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_ALT_HOVER},
    {{"colors/card", "颜色", "列表底板", "普通候选列表和状态消息的底色", NOVA_THEME_COLOR, 0, 0, 0, nullptr},
     NOVA_COLOR_CARD},
    {{"colors/text", "颜色", "文字", "备选、列表里的字", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_PRIMARY},
    {{"colors/dim", "颜色", "次要文字", "序号、注释、没盖到的字母", NOVA_THEME_COLOR, 0, 0, 0, nullptr},
     NOVA_COLOR_DIM},
    {{"colors/share", "颜色", "词频比例", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_SHARE},
    {{"colors/branch", "颜色", "分支线", "", NOVA_THEME_COLOR, 0, 0, 0, nullptr}, NOVA_COLOR_BRANCH},
};
constexpr int kFieldCount = sizeof(kFields) / sizeof(kFields[0]);

// 两种词块颜色在 CIE Lab 里的距离小于这个值，就算「太像」。
constexpr double kToneDistance = 15;

const Field* FindField(const std::string& key) {
  for (const auto& field : kFields)
    if (key == field.f.key) return &field;
  return nullptr;
}

std::string Trim(const std::string& s) {
  size_t a = s.find_first_not_of(" \t\r");
  if (a == std::string::npos) return "";
  size_t b = s.find_last_not_of(" \t\r");
  return s.substr(a, b - a + 1);
}

bool ParseColor(const std::string& text, double rgba[4]) {
  std::string s = Trim(text);
  if (!s.empty() && s[0] == '#') s = s.substr(1);
  if (s.size() != 6 && s.size() != 8) return false;
  for (char c : s)
    if (!std::isxdigit(static_cast<unsigned char>(c))) return false;
  for (int i = 0; i < 4; i++) {
    rgba[i] = i < 3 || s.size() == 8 ? std::strtol(s.substr(i * 2, 2).c_str(), nullptr, 16) / 255.0 : 1;
  }
  return true;
}

std::string FormatColor(const double rgba[4]) {
  auto byte = [](double v) { return static_cast<int>(std::lround(std::clamp(v, 0.0, 1.0) * 255)); };
  char buffer[16];
  if (byte(rgba[3]) == 255)
    std::snprintf(buffer, sizeof buffer, "#%02x%02x%02x", byte(rgba[0]), byte(rgba[1]), byte(rgba[2]));
  else
    std::snprintf(buffer, sizeof buffer, "#%02x%02x%02x%02x", byte(rgba[0]), byte(rgba[1]), byte(rgba[2]),
                  byte(rgba[3]));
  return buffer;
}

std::string FormatNumber(double v) {
  char buffer[32];
  std::snprintf(buffer, sizeof buffer, "%g", v);
  return buffer;
}

// yaml 字符串：总是加双引号，转义 \ 和 "。
std::string Quote(const std::string& s) {
  std::string out = "\"";
  for (char c : s) {
    if (c == '"' || c == '\\') out += '\\';
    out += c;
  }
  return out + "\"";
}

// 去掉引号外的 # 注释，返回值（引号里的内容原样）。没有闭合引号时 ok = false。
std::string ParseValue(const std::string& raw, bool* ok) {
  *ok = true;
  std::string s = Trim(raw);
  if (!s.empty() && (s[0] == '"' || s[0] == '\'')) {
    const char q = s[0];
    std::string out;
    for (size_t i = 1; i < s.size(); i++) {
      if (q == '"' && s[i] == '\\' && i + 1 < s.size()) {
        out += s[++i];
      } else if (q == '\'' && s[i] == '\'' && i + 1 < s.size() && s[i + 1] == '\'') {
        out += '\'';
        i++;
      } else if (s[i] == q) {
        return out;
      } else {
        out += s[i];
      }
    }
    *ok = false;
    return out;
  }
  size_t hash = s.find(" #");
  if (!s.empty() && s[0] == '#') return "";
  return Trim(hash == std::string::npos ? s : s.substr(0, hash));
}

// WCAG 2 的相对亮度和对比度。
double Luminance(const double c[4]) {
  auto channel = [](double v) { return v <= 0.03928 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); };
  return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2]);
}

// CIE Lab（D65），用来量两个颜色像不像。
void Lab(const double c[4], double out[3]) {
  auto lin = [](double v) { return v <= 0.04045 ? v / 12.92 : std::pow((v + 0.055) / 1.055, 2.4); };
  const double r = lin(c[0]), g = lin(c[1]), b = lin(c[2]);
  double x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  double y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  double z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  auto f = [](double t) { return t > 0.008856 ? std::cbrt(t) : 7.787 * t + 16.0 / 116; };
  out[0] = 116 * f(y) - 16;
  out[1] = 500 * (f(x) - f(y));
  out[2] = 200 * (f(y) - f(z));
}

fs::path PathOf(const char* utf8) {
#if defined(_WIN32)
  return fs::u8path(utf8);
#else
  return fs::path(utf8);
#endif
}

std::string Utf8Of(const fs::path& path) {
#if defined(_WIN32)
  auto u8 = path.u8string();
  return std::string(u8.begin(), u8.end());
#else
  return path.string();
#endif
}

}  // namespace

struct NovaUITheme {
  std::map<std::string, std::string> text;  // TEXT、CHOICE
  std::map<std::string, double> number;
  double colors[NOVA_COLOR_COUNT][4];
  std::string problems, dumped, checked;

  NovaUITheme() {
    for (int i = 0; i < NOVA_COLOR_COUNT; i++) nova_ui_default_color(static_cast<NovaUIColor>(i), colors[i]);
    text["name"] = "深色";
    text["author"] = "nova-ime";
    text["appearance"] = "dark";
    text["font/face"] = "";
    text["font/mono"] = "";
    number["font/size"] = 15;
    number["shape/card_radius"] = 10;
    number["shape/chip_radius"] = 6;
    number["shape/edge"] = 10;
    number["shape/chip_padding"] = 8;
    number["shape/column_gap"] = 12;
    number["shape/row_height"] = 1.5;
    number["shape/chip_height"] = 1.6;
  }

  // 返回 false 时不改。
  bool Set(const Field& field, const std::string& value) {
    switch (field.f.kind) {
      case NOVA_THEME_TEXT:
        text[field.f.key] = value;
        return true;
      case NOVA_THEME_CHOICE: {
        const std::string choices = std::string(",") + field.f.choices + ",";
        if (value.empty() || value.find(',') != std::string::npos || choices.find("," + value + ",") == std::string::npos)
          return false;
        text[field.f.key] = value;
        return true;
      }
      case NOVA_THEME_NUMBER: {
        char* end = nullptr;
        const double v = std::strtod(value.c_str(), &end);
        if (value.empty() || *end != '\0' || !std::isfinite(v)) return false;
        number[field.f.key] = std::clamp(v, field.f.min, field.f.max);
        return true;
      }
      case NOVA_THEME_COLOR: {
        double rgba[4];
        if (!ParseColor(value, rgba)) return false;
        std::copy(rgba, rgba + 4, colors[field.color]);
        return true;
      }
    }
    return false;
  }

  std::string Get(const Field& field) const {
    switch (field.f.kind) {
      case NOVA_THEME_NUMBER: return FormatNumber(number.at(field.f.key));
      case NOVA_THEME_COLOR: return FormatColor(colors[field.color]);
      default: return text.at(field.f.key);
    }
  }
};

extern "C" {

const NovaUIThemeField* nova_ui_theme_fields(int* count) {
  static std::vector<NovaUIThemeField> fields = [] {
    std::vector<NovaUIThemeField> out;
    for (const auto& field : kFields) out.push_back(field.f);
    return out;
  }();
  if (count) *count = kFieldCount;
  return fields.data();
}

NovaUITheme* nova_ui_theme_new(void) { return new NovaUITheme(); }

NovaUITheme* nova_ui_theme_parse(const char* yaml) {
  auto* theme = new NovaUITheme();
  std::istringstream in(yaml ? yaml : "");
  std::string line, section;
  int number = 0;
  auto problem = [&](const std::string& what) {
    theme->problems += "第 " + std::to_string(number) + " 行：" + what + "\n";
  };
  while (std::getline(in, line)) {
    number++;
    if (number == 1 && line.compare(0, 3, "\xEF\xBB\xBF") == 0) line = line.substr(3);  // BOM
    const std::string trimmed = Trim(line);
    if (trimmed.empty() || trimmed[0] == '#') continue;
    const bool indented = line[0] == ' ' || line[0] == '\t';
    const size_t colon = trimmed.find(':');
    if (colon == std::string::npos) {
      problem("看不懂这一行");
      continue;
    }
    const std::string key = Trim(trimmed.substr(0, colon));
    bool ok = true;
    const std::string value = ParseValue(trimmed.substr(colon + 1), &ok);
    if (!indented) section.clear();
    if (!indented && value.empty() && ok && Trim(trimmed.substr(colon + 1)).empty()) {
      section = key;  // 小节开头
      continue;
    }
    const std::string full = indented && !section.empty() ? section + "/" + key : key;
    if (full == "version") continue;
    const Field* field = FindField(full);
    if (!field) {
      problem("不认识的设置 " + full);
      continue;
    }
    if (!ok) {
      problem(full + " 的引号没有闭合");
      continue;
    }
    if (!theme->Set(*field, value)) problem(full + " 的值不对：" + value);
  }
  return theme;
}

NovaUITheme* nova_ui_theme_load(const char* path) {
  if (!path) return nullptr;
  std::ifstream file(PathOf(path), std::ios::binary);
  if (!file) return nullptr;
  std::stringstream buffer;
  buffer << file.rdbuf();
  return nova_ui_theme_parse(buffer.str().c_str());
}

NovaUITheme* nova_ui_theme_copy(const NovaUITheme* theme) {
  if (!theme) return new NovaUITheme();
  auto* copy = new NovaUITheme(*theme);
  copy->problems.clear();
  return copy;
}

void nova_ui_theme_free(NovaUITheme* theme) { delete theme; }

const char* nova_ui_theme_problems(const NovaUITheme* theme) { return theme->problems.c_str(); }

const char* nova_ui_theme_get(NovaUITheme* theme, const char* key) {
  const Field* field = key ? FindField(key) : nullptr;
  if (!field) return nullptr;
  theme->dumped = theme->Get(*field);
  return theme->dumped.c_str();
}

int nova_ui_theme_set(NovaUITheme* theme, const char* key, const char* value) {
  const Field* field = key ? FindField(key) : nullptr;
  if (!field || !value) return 0;
  return theme->Set(*field, Trim(value)) ? 1 : 0;
}

const char* nova_ui_theme_dump(NovaUITheme* theme) {
  std::string out =
      "# Nova 星语的主题。每个 .yaml 是一套主题，文件名就是主题的编号。\n"
      "# 放在用户目录的 nova_themes/ 里；改完在设置里重新选一次这个主题，或者点「重新加载设置」。\n"
      "version: 1\n";
  std::string section;
  for (const auto& field : kFields) {
    const std::string key = field.f.key;
    const size_t slash = key.find('/');
    const std::string group = slash == std::string::npos ? "" : key.substr(0, slash);
    if (group != section) {
      out += "\n" + group + ":\n";
      section = group;
    }
    const std::string name = slash == std::string::npos ? key : key.substr(slash + 1);
    const std::string value = theme->Get(field);
    const bool quote = field.f.kind == NOVA_THEME_TEXT || field.f.kind == NOVA_THEME_COLOR;
    std::string comment = field.f.label;
    if (*field.f.note) comment += "：" + std::string(field.f.note);
    out += (group.empty() ? "" : "  ") + name + ": " + (quote ? Quote(value) : value) + "  # " + comment + "\n";
  }
  theme->dumped = out;
  return theme->dumped.c_str();
}

int nova_ui_theme_save(NovaUITheme* theme, const char* path) {
  if (!path) return 0;
  const std::string text = nova_ui_theme_dump(theme);
  std::error_code error;
  const fs::path target = PathOf(path);
  fs::create_directories(target.parent_path(), error);
  fs::path temporary = target;
  temporary += ".tmp";
  {
    std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
    if (!file) return 0;
    file << text;
    if (!file) return 0;
  }
  fs::rename(temporary, target, error);
  return error ? 0 : 1;
}

void nova_ui_theme_color(const NovaUITheme* theme, NovaUIColor color, double rgba[4]) {
  if (!theme || color < 0 || color >= NOVA_COLOR_COUNT) {
    nova_ui_default_color(color, rgba);
    return;
  }
  std::copy(theme->colors[color], theme->colors[color] + 4, rgba);
}

void nova_ui_theme_style(const NovaUITheme* theme, NovaUIStyle* style) {
  if (!theme || !style) return;
  const auto& n = theme->number;
  style->font_size = n.at("font/size");
  style->card_radius = n.at("shape/card_radius");
  style->chip_radius = n.at("shape/chip_radius");
  style->edge = n.at("shape/edge");
  style->chip_padding = n.at("shape/chip_padding");
  style->column_gap = n.at("shape/column_gap");
  style->row_height = n.at("shape/row_height");
  style->chip_height = n.at("shape/chip_height");
  // 0 表示默认值，主题里写 0 的圆角要真的是 0。
  if (style->card_radius == 0) style->card_radius = 1e-9;
  if (style->chip_radius == 0) style->chip_radius = 1e-9;
  if (style->column_gap == 0) style->column_gap = 1e-9;
}

const char* nova_ui_theme_check(NovaUITheme* theme) {
  std::string out;
  auto label = [](NovaUIColor color) -> std::string {
    for (const auto& field : kFields)
      if (field.f.kind == NOVA_THEME_COLOR && field.color == color) return field.f.label;
    return "";
  };
  auto contrast = [&](NovaUIColor fore, NovaUIColor back, double minimum) {
    const double a = Luminance(theme->colors[fore]), b = Luminance(theme->colors[back]);
    const double ratio = (std::max(a, b) + 0.05) / (std::min(a, b) + 0.05);
    if (ratio + 1e-9 < minimum) {
      char buffer[64];
      std::snprintf(buffer, sizeof buffer, "%.1f", ratio);
      out += "「" + label(back) + "」上的「" + label(fore) + "」对比度只有 " + buffer + "，低于 " +
             FormatNumber(minimum) + "，可能看不清\n";
    }
  };
  for (NovaUIColor chip : {NOVA_COLOR_BLUE, NOVA_COLOR_PURPLE, NOVA_COLOR_ORANGE, NOVA_COLOR_GREEN})
    contrast(NOVA_COLOR_CHIP_TEXT, chip, 3);
  contrast(NOVA_COLOR_BLACK, NOVA_COLOR_FOCUS, 4.5);
  contrast(NOVA_COLOR_PRIMARY, NOVA_COLOR_ALT_FILL, 4.5);
  contrast(NOVA_COLOR_PRIMARY, NOVA_COLOR_CARD, 4.5);
  contrast(NOVA_COLOR_DIM, NOVA_COLOR_ALT_FILL, 3);
  // 词块的颜色本身就是提示：两种颜色太像就分不清是哪一种。
  const NovaUIColor tones[] = {NOVA_COLOR_BLUE, NOVA_COLOR_PURPLE, NOVA_COLOR_ORANGE, NOVA_COLOR_GREEN,
                               NOVA_COLOR_FOCUS};
  for (int i = 0; i < 5; i++) {
    for (int j = i + 1; j < 5; j++) {
      double a[3], b[3];
      Lab(theme->colors[tones[i]], a);
      Lab(theme->colors[tones[j]], b);
      const double distance = std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) +
                                        (a[2] - b[2]) * (a[2] - b[2]));
      if (distance < kToneDistance)
        out += "「" + label(tones[i]) + "」和「" + label(tones[j]) + "」颜色太像，打字时不容易分清\n";
    }
  }
  theme->checked = out;
  return theme->checked.c_str();
}

}  // extern "C"

struct NovaUIThemeList {
  std::vector<std::string> strings;  // 拥有 entries 里的字符串
  std::vector<NovaUIThemeEntry> entries;
};

extern "C" {

NovaUIThemeList* nova_ui_theme_list(const char* shared_dir, const char* user_dir) {
  struct Item {
    std::string id, name, path, appearance;
    int user;
  };
  std::map<std::string, Item> items;  // 按编号排序，用户的覆盖自带的
  int dir_index = 0;
  for (const char* dir : {shared_dir, user_dir}) {
    const int user = dir_index++;
    if (!dir || !*dir) continue;
    std::error_code error;
    for (fs::directory_iterator it(PathOf(dir), error), end; !error && it != end; it.increment(error)) {
      const fs::path path = it->path();
      if (path.extension() != ".yaml") continue;
      const std::string file = Utf8Of(path);
      NovaUITheme* theme = nova_ui_theme_load(file.c_str());
      if (!theme) continue;
      const std::string id = Utf8Of(path.stem());
      items[id] = {id, theme->text["name"], file, theme->text["appearance"], user};
      nova_ui_theme_free(theme);
    }
  }
  auto* list = new NovaUIThemeList();
  // 先把字符串都放好，不再扩容之后再取指针。
  list->strings.reserve(items.size() * 4);
  for (auto& [id, item] : items) {
    list->strings.push_back(item.id);
    list->strings.push_back(item.name);
    list->strings.push_back(item.path);
    list->strings.push_back(item.appearance);
  }
  size_t index = 0;
  for (auto& [id, item] : items) {
    NovaUIThemeEntry entry;
    entry.id = list->strings[index].c_str();
    entry.name = list->strings[index + 1].c_str();
    entry.path = list->strings[index + 2].c_str();
    entry.appearance = list->strings[index + 3].c_str();
    entry.user = item.user;
    list->entries.push_back(entry);
    index += 4;
  }
  return list;
}

const NovaUIThemeEntry* nova_ui_theme_list_entries(const NovaUIThemeList* list, int* count) {
  if (count) *count = list ? static_cast<int>(list->entries.size()) : 0;
  return list && !list->entries.empty() ? list->entries.data() : nullptr;
}

void nova_ui_theme_list_free(NovaUIThemeList* list) { delete list; }

}  // extern "C"
