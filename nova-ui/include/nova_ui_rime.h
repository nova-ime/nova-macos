/*
 * nova_ui_rime.h
 * 便捷层：直接用 librime 的 C API（RimeApi*、session）读属性、执行面板上的动作。
 * librime 在各平台都有，所以这一层也是跨平台的；不用 librime 的前端可以只用 nova_ui.h。
 *
 * api 参数是 librime 的 RimeApi*（librime 自己的 rime_get_api() 返回的）。
 * 构建时 Bool 的类型要和 api 一致：macOS 的 Squirrel 用 stdbool 版（RimeApi_stdbool），
 * 编译这个文件时要定义 NOVA_UI_RIME_STDBOOL；Windows/Linux 用标准版，不定义。
 * 这里按 void* 收，是为了 Swift 这类不方便引 rime_api.h 的前端也能调。
 */
#ifndef NOVA_UI_RIME_H_
#define NOVA_UI_RIME_H_

#include <stdint.h>

#include "nova_ui.h"

#ifdef __cplusplus
extern "C" {
#endif

/* get_context 之后调用（nova_tree 由候选过滤器在生成菜单时写入）。
 * 从 session 读 input 和属性 nova_tree、nova_list、nova_cursor、nova_qp_raw、nova_qp_map，
 * 连同调用方给的菜单状态和候选一起交给 nova_ui_assemble。
 * base 里的 input 和 prop_* 字段会被忽略（由这里填）。 */
NovaUIContentHandle* nova_ui_rime_assemble(void* api, uintptr_t session, const NovaUIAssembleInput* base);

/* 以下动作返回 librime 是否处理了按键；返回非 0 时前端要刷新界面。 */
/* 点备选：数字键由 nova_tree_keys.lua 处理，点击走同一条路。label 从 1 起，和数字键同一个编号。 */
int nova_ui_rime_pin_alternative(void* api, uintptr_t session, int label);
/* 点击字母或词块：改原始字母光标，再发 F20 让 nova_tree_keys.lua 按新光标重画树。 */
int nova_ui_rime_move_cursor(void* api, uintptr_t session, int position);
/* 滚轮翻页和 PageUp/PageDown 走同一条路，由 nova_tree_keys.lua 处理：有焦点块时翻它的备选，
 * 否则翻普通候选列表（第一次只打开列表，停在第一页）。 */
int nova_ui_rime_turn_page(void* api, uintptr_t session, int up);
/* 点普通候选列表里的一项（当前页，从 0 起）。 */
int nova_ui_rime_select_candidate(void* api, uintptr_t session, int index);

#ifdef __cplusplus
}
#endif
#endif
