// 基于 librime C API 的便捷层，见 nova_ui_rime.h。
#ifdef NOVA_UI_RIME_STDBOOL
#include <rime_api_stdbool.h>
#endif
#include <rime_api.h>

#include <string>
#include <vector>

#include "../include/nova_ui_rime.h"

#ifdef NOVA_UI_RIME_STDBOOL
using Api = RimeApi_stdbool;
#else
using Api = RimeApi;
#endif

namespace {

constexpr int kKeyPageUp = 0xff55;
constexpr int kKeyPageDown = 0xff56;
constexpr int kKeyF20 = 0xffd1;

Api* A(void* api) { return static_cast<Api*>(api); }

// 属性不存在或放不进缓冲区时为 false。
// 属性比缓冲区长时，librime 的 strncpy 不补结尾的 0。这时当作没有这个属性，不往缓冲区外面读。
bool Property(void* api, uintptr_t session, const char* name, size_t capacity, std::string* out) {
  std::vector<char> buffer(capacity, 0);
  if (!A(api)->get_property(session, name, buffer.data(), capacity) || buffer[capacity - 1] != 0) return false;
  *out = buffer.data();
  return true;
}

}  // namespace

NovaUIContentHandle* nova_ui_rime_assemble(void* api, uintptr_t session, const NovaUIAssembleInput* base) {
  NovaUIAssembleInput in = *base;
  const char* input = A(api)->get_input(session);
  std::string tree, list, cursor, raw, map;
  const bool has_tree = Property(api, session, "nova_tree", 8192, &tree);
  const bool has_list = Property(api, session, "nova_list", 1024, &list);
  const bool has_cursor = Property(api, session, "nova_cursor", 32, &cursor);
  const bool has_raw = Property(api, session, "nova_qp_raw", 4096, &raw);
  const bool has_map = Property(api, session, "nova_qp_map", 16384, &map);
  in.input = input ? input : "";
  in.prop_tree = has_tree ? tree.c_str() : nullptr;
  in.prop_list = has_list ? list.c_str() : nullptr;
  in.prop_cursor = has_cursor ? cursor.c_str() : nullptr;
  in.prop_qp_raw = has_raw ? raw.c_str() : nullptr;
  in.prop_qp_map = has_map ? map.c_str() : nullptr;
  return nova_ui_assemble(&in);
}

int nova_ui_rime_pin_alternative(void* api, uintptr_t session, int label) {
  return A(api)->process_key(session, 0x30 + label, 0) ? 1 : 0;
}

int nova_ui_rime_move_cursor(void* api, uintptr_t session, int position) {
  A(api)->set_property(session, "nova_cursor", std::to_string(position).c_str());
  return A(api)->process_key(session, kKeyF20, 0) ? 1 : 0;
}

int nova_ui_rime_turn_page(void* api, uintptr_t session, int up) {
  return A(api)->process_key(session, up ? kKeyPageUp : kKeyPageDown, 0) ? 1 : 0;
}

int nova_ui_rime_select_candidate(void* api, uintptr_t session, int index) {
  return A(api)->select_candidate_on_current_page(session, static_cast<size_t>(index)) ? 1 : 0;
}
