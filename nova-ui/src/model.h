// 内部头文件：解析和内容组装用到的小工具，不对外。
#ifndef NOVA_UI_MODEL_H_
#define NOVA_UI_MODEL_H_

#include <cstdint>
#include <string>
#include <vector>

#include "../include/nova_ui.h"

namespace nova {

// 和 Swift 的 Int(String) 一致：可选的 +/-，后面全是数字，放得下就行；不然算解析失败。
bool ParseInt(const std::string& s, int* out);

// UTF-8 字符串按 UTF-16 码元数的长度。
int Utf16Length(const std::string& s);

struct BlockStore {
  std::string flags, page, word;
  std::vector<std::string> alt_texts;
  NovaUIBlock block;
  std::vector<NovaUIChoice> alts;
};

}  // namespace nova

struct NovaUITree {
  std::vector<nova::BlockStore> stores;
  std::vector<NovaUIBlock> blocks;
};

struct NovaUIContentHandle {
  std::string preedit, letters;
  NovaUITree tree;
  std::vector<int> letter_map;
  std::vector<std::string> label_s, text_s, comment_s;
  std::vector<NovaUICandidate> candidates;
  NovaUIContent view;
};

#endif
