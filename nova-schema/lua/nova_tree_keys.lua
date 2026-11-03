-- nova_tree_keys -- 树状候选的改错按键。
-- 没有焦点时，数字键直接选不确定块的备选，从左到右连续编号。
-- ←/→（Tab 经 key_binder 也变成它们）移动焦点；有焦点时数字键只选焦点块。
-- 从最后一块再按 → 回到没有焦点的状态。
-- 选词时其他块冻结，只有和所选范围重叠的部分重新解码。选的词覆盖整个输入时直接上屏。

local LEFT, RIGHT = 0xff51, 0xff53

local function clear(ctx)
    ctx:set_property("nova_pins", "")
    ctx:set_property("nova_pins_end", "")
    ctx:set_property("nova_tree", "")
    ctx:set_property("nova_tree_input", "")
    ctx:set_property("nova_focus", "")
end

local function init(env)
    local ctx = env.engine.context
    env.enabled = env.engine.schema.config:get_bool("nova_tree/enabled") or false
    env.commit = ctx.commit_notifier:connect(clear)
    env.update = ctx.update_notifier:connect(function(c)
        if not c:is_composing() then clear(c) end
    end)
end

local function fini(env)
    env.commit:disconnect()
    env.update:disconnect()
end

local function before_separator(value)
    return (value:gsub("\31.*", ""))
end

local function parse_tree(tree)
    local blocks, focus = {}, nil
    for line in tree:gmatch("[^\n]+") do
        local fields = {}
        for value in line:gmatch("[^\t]+") do fields[#fields + 1] = value end
        local block = { chosen = fields[1]:sub(1, 1) == "1", overview = fields[1]:find("o", 1, true) ~= nil,
                        from = tonumber(fields[2]), to = tonumber(fields[3]),
                        text = before_separator(fields[5]), alts = {} }
        for i = 6, #fields do
            local text, _, to = fields[i]:match("^([^\31]*)\31([^\31]*)\31(%d+)$")
            block.alts[#block.alts + 1] = { text = text, to = tonumber(to) }
        end
        blocks[#blocks + 1] = block
        if fields[1]:find("f", 1, true) then focus = #blocks end
    end
    return blocks, focus
end

-- 走 ctx:select 才会记进用户词库；菜单里找不到（被 max_homophones 截掉）时直接上屏。
local function commit_alternative(env, seg, text)
    local ctx = env.engine.context
    for i = 0, seg.menu:prepare(100) - 1 do
        local cand = seg.menu:get_candidate_at(i)
        if cand and cand.text == text then
            ctx:select(i)
            return
        end
    end
    env.engine:commit_text(text)
    ctx:clear()
end

local function pin_line(input, from, to, kind, text)
    return string.format("%d:%d:%s:%s:%s\n", from, to, input:sub(from + 1, to), kind, text)
end

-- 数字键对应的块和备选。
local function find_choice(blocks, focus, label)
    if focus then return blocks[focus], blocks[focus].alts[label] end
    local count = 0
    for _, block in ipairs(blocks) do
        if block.overview then
            if label <= count + #block.alts then return block, block.alts[label - count] end
            count = count + #block.alts
        end
    end
end

local function choose(env, seg, blocks, focus, chosen, alt)
    local ctx = env.engine.context
    local input = ctx.input:sub(seg._start + 1, seg._end)
    local from = chosen.from
    if from == 0 and alt.to == #input then
        commit_alternative(env, seg, alt.text)
        return
    end
    local pins = { pin_line(input, from, alt.to, "h", alt.text) }
    for _, block in ipairs(blocks) do
        if block.to <= from or block.from >= alt.to then
            pins[#pins + 1] = pin_line(input, block.from, block.to, block.chosen and "h" or "s", block.text)
        end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    ctx:set_property("nova_pins_end", tostring(#input))
    ctx:set_property("nova_focus", focus and (from .. ":" .. ctx.input) or "")
    ctx:refresh_non_confirmed_composition()
end

local function move_focus(ctx, blocks, focus, step)
    -- 没有焦点时：← 到最后一块，→ 到第一块。最后一块再按 → 取消焦点。
    local index = focus and focus + step or (step < 0 and #blocks or 1)
    local target = blocks[math.max(1, index)]
    ctx:set_property("nova_focus", target and (target.from .. ":" .. ctx.input) or "")
    ctx:refresh_non_confirmed_composition()
end

local function func(key, env)
    if not env.enabled or key:release() or key:ctrl() or key:alt() or key:super() then return 2 end
    local code = key.keycode
    local is_digit = code >= 0x31 and code <= 0x39
    if not is_digit and code ~= LEFT and code ~= RIGHT then return 2 end
    local ctx = env.engine.context
    if not ctx:is_composing() then return 2 end
    local tree = ctx:get_property("nova_tree") or ""
    if tree == "" then return 2 end
    -- 用户翻页或移动高亮后，面板显示的是普通列表，按键归列表。
    local seg = ctx.composition:back()
    if seg.selected_index > 0 then return 2 end
    -- 菜单空时过滤器没有运行，属性里还是上一次的树。
    if seg.menu:prepare(1) == 0 then return 2 end
    local blocks, focus = parse_tree(tree)
    if is_digit then
        local chosen, alt = find_choice(blocks, focus, code - 0x30)
        -- 没有这个编号时吞掉，否则选中的是面板上看不到的候选。
        if alt then choose(env, seg, blocks, focus, chosen, alt) end
        return 1
    end
    -- 还没有词块时也吞掉：这时动拼音光标只会打乱解码。
    if #blocks == 0 then return 1 end
    move_focus(ctx, blocks, focus, code == LEFT and -1 or 1)
    return 1
end

return { init = init, func = func, fini = fini }
