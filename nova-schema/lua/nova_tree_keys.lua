-- nova_tree_keys -- 树状候选的改错按键，以及原始字母光标。
-- 输入框里显示原始字母，光标（nova_cursor 属性，空表示在末尾）可以停在任意字母前后：
--   ←/→ 逐个字母移动，Shift+←/→（Tab/Shift+Tab 经 key_binder 变成它们）跳到下一个/上一个词块的末尾，
--   Home/End 到开头/末尾；光标在中间时打字插入到光标处，退格删光标前的字母，Delete 删光标后的。
-- Rime 自己的光标始终在末尾，所以候选总是覆盖整句。光标前一个字母所在的词块是焦点，数字键只选它；
-- 有焦点时 -/=、,/.（PageUp/PageDown）翻这个词的备选；↓/↑ 把这个词直接换成下一个/上一个备选，
-- 一直按 ↑ 回到原来的词，见 cycle。
-- 没有焦点时第一次按 =（PageDown）只打开普通候选列表、停在第一页，之后的翻页归 Rime；
-- 在第一页按 -（PageUp）回到树，见 list_open。
-- nova_cursor 为空表示没有焦点（光标在末尾，数字键直接选不确定块的备选，从左到右连续编号）；
-- 等于输入长度表示光标也在末尾，但焦点在最后一块（Tab 跳到最后一块的末尾）。
-- 选词时只冻结前面的块，所选范围和它后面的部分重新解码，后面的字可以跟新选的字组词
-- （显 + 时期 → 显示器）；用户选过的块不管在哪都保留。选的词覆盖整个输入时直接上屏。
-- 空格不管光标在哪都上屏整句；末尾有半个音节时上屏前面的完整部分，见 commit_before_pending。
-- ; 等于数字 1。有焦点时 [ / ] 伸缩焦点块：[ 让出最后一个音节给右边的块，] 让出第一个音节给左边的块，
-- 让出的音节和那个相邻块一起单独解码，见 shrink。没有焦点时 [ ] 照常是标点。
-- Shift+Delete 或 Control+Delete（Control+K 经 key_binder 变成前者）：把焦点块的词从用户词库里删掉，
-- 没有焦点时删最后一块，见 delete_word。
-- 用 [ ] 定过的边界上屏时记下来，下次同一串编码直接按它切，见 learn_bounds。

local bounds = require("nova_bounds")

-- 全拼简拼的音节是「声母键 + 通配符」两个字符（nVhV），见 nova.schema.yaml 的 abbrev 规则和 nova_quanpin。
local WILDCARD = "V"

local LEFT, RIGHT, SPACE = 0xff51, 0xff53, 0x20
local HOME, END, BACKSPACE, DELETE = 0xff50, 0xff57, 0xff08, 0xffff
local PAGE_UP, PAGE_DOWN, COMMA, PERIOD = 0xff55, 0xff56, 0x2c, 0x2e
local UP, DOWN = 0xff52, 0xff54
local SEMICOLON, BRACKET_LEFT, BRACKET_RIGHT = 0x3b, 0x5b, 0x5d
-- Swift 改了 nova_cursor（点击字母或词块）之后发这个键，让树按新光标重画。
local REFRESH = 0xffd1

local function clear(ctx)
    ctx:set_property("nova_pins", "")
    ctx:set_property("nova_pins_end", "")
    ctx:set_property("nova_open_from", "")
    ctx:set_property("nova_tree", "")
    ctx:set_property("nova_tree_input", "")
    ctx:set_property("nova_cursor", "")
    ctx:set_property("nova_alt_page", "")
    ctx:set_property("nova_cycle", "")
    ctx:set_property("nova_redecode", "")
    ctx:set_property("nova_resized", "")
    ctx:set_property("nova_bounds_used", "")
    -- 不清的话，下次打出同一串错的编码，没按空格就去算多打、漏打的改法，第一次空格也直接上屏。
    ctx:set_property("nova_fix_full", "")
    ctx:set_property("nova_list", "")
end

-- 没有焦点时翻页是在找树上没有的候选，面板改显示普通列表。第一次按 PageDown 交给 Rime 的话，
-- 它直接翻到第二页，第一页的候选就看不到了；所以第一次只写 nova_list，面板从第一页显示列表。
-- nova_list 记的是打开时的输入，面板和这里都拿它和当前输入比；nova_sentences 重新出候选时清掉它
-- （改了字母、选了一段、移了光标），所以输入没变而候选变了的时候不会留着。
local function list_open(ctx)
    return ctx.input ~= "" and ctx:get_property("nova_list") == ctx.input
end

-- 光标位置，以及是否有焦点（nova_cursor 不为空）。
local function cursor_of(ctx)
    local cursor = tonumber(ctx:get_property("nova_cursor") or "")
    if not cursor then return #ctx.input, false end
    return math.min(math.max(0, cursor), #ctx.input), true
end

-- focused=false 时回到末尾、没有焦点。移动光标时备选回到第一页。
local function set_cursor(ctx, cursor, focused)
    if focused == false or (focused == nil and cursor >= #ctx.input) then
        ctx:set_property("nova_cursor", "")
    else
        ctx:set_property("nova_cursor", tostring(math.min(math.max(0, cursor), #ctx.input)))
    end
    ctx:set_property("nova_alt_page", "")
end

-- 输入在 at 处删去 removed 个字母、插入 inserted 个字母后，固定段和上一次的树跟着平移：
-- 整段在改动前的不动，整段在改动后的跟着移，和改动重叠的作废（它的按键变了）。
-- 在段的末尾插入大写辅助码（aux）也算改这段：用户是要用辅助码重新筛选这个字。
local function shift_range(from, to, at, removed, inserted, aux)
    if to < at or (to == at and not aux) then return from, to end
    if from >= at + removed and (removed > 0 or from >= at) then
        return from + inserted - removed, to + inserted - removed
    end
    return nil
end

local function shift_properties(ctx, at, removed, inserted, aux)
    local delta = inserted - removed
    local pins = {}
    for from, to, rest in (ctx:get_property("nova_pins") or ""):gmatch("(%d+):(%d+):([^\n]*)\n") do
        local a, b = shift_range(tonumber(from), tonumber(to), at, removed, inserted, aux)
        if a then pins[#pins + 1] = string.format("%d:%d:%s\n", a, b, rest) end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    local open_end = tonumber(ctx:get_property("nova_pins_end") or "")
    if open_end then ctx:set_property("nova_pins_end", tostring(open_end > at and math.max(at, open_end + delta) or open_end)) end
    local lines = {}
    for line in (ctx:get_property("nova_tree") or ""):gmatch("[^\n]+") do
        local flags, from, to, rest = line:match("^([^\t]*)\t(%d+)\t(%d+)\t(.*)$")
        if flags then
            local a, b = shift_range(tonumber(from), tonumber(to), at, removed, inserted, aux)
            if a then lines[#lines + 1] = string.format("%s\t%d\t%d\t%s", flags, a, b, rest) end
        end
    end
    ctx:set_property("nova_tree", table.concat(lines, "\n"))
    ctx:set_property("nova_tree_input", "")
    -- 中间的字母改了，伸缩时定的边界不再作数。
    ctx:set_property("nova_resized", "")
end

-- 在光标处插入 text，或删去光标前（before=true）/后的一个字母。只处理光标不在末尾的情形。
local function insert_at_cursor(ctx, text)
    local input, cursor = ctx.input, cursor_of(ctx)
    shift_properties(ctx, cursor, 0, 1, text:match("^[A-Z]$") ~= nil)
    ctx:set_property("nova_cursor", tostring(cursor + 1))
    ctx:set_property("nova_alt_page", "")
    ctx.input = input:sub(1, cursor) .. text .. input:sub(cursor + 1)
end

local function delete_at_cursor(ctx, before)
    local input, cursor = ctx.input, cursor_of(ctx)
    local at = before and cursor - 1 or cursor
    if at < 0 or at >= #input then return end
    shift_properties(ctx, at, 1, 0)
    ctx:set_property("nova_cursor", tostring(at))
    ctx:set_property("nova_alt_page", "")
    if #input == 1 then ctx:clear() return end
    ctx.input = input:sub(1, at) .. input:sub(at + 2)
end

-- 全拼（nova_quanpin）用：输入在 at 处的 removed 个字母换成 text，固定段和树照上面平移。光标由调用方设。
local function replace_input(ctx, at, removed, text, aux)
    local input = ctx.input
    shift_properties(ctx, at, removed, #text, aux)
    ctx.input = input:sub(1, at) .. text .. input:sub(at + removed + 1)
end

local learn_bounds  -- 定义在 parse_tree 后面

local function init(env)
    local ctx = env.engine.context
    env.enabled = env.engine.schema.config:get_bool("nova_tree/enabled") or false
    -- 只用来删用户词（delete_word）。和翻译器共用同一个用户词库；不设 memorize 回调，上屏时不会重复记词。
    local ok, memory = pcall(Memory, env.engine, env.engine.schema, "translator")
    env.memory = ok and memory or nil
    env.commit = ctx.commit_notifier:connect(function(c)
        local learned, err = pcall(learn_bounds, c, c:get_commit_text())
        if not learned then log.error("nova_tree_keys: " .. tostring(err)) end
        clear(c)
    end)
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
            local text, _, to, from, code = fields[i]:match("^([^\31]*)\31([^\31]*)\31(%d+)\31?(%d*)\31?(%l*)")
            block.alts[#block.alts + 1] = { text = text, to = tonumber(to), from = tonumber(from),
                                            code = code ~= "" and code or nil }
        end
        blocks[#blocks + 1] = block
        if fields[1]:find("f", 1, true) then focus = #blocks end
    end
    return blocks, focus
end

-- 上屏时学边界。nova_resized 是这次用 [ ] 定过的边界（`字节偏移:到边界后一个音节为止的输入` 每行一个），
-- 边界还在的话把两侧的块记进 nova_bounds。nova_bounds_used 是 nova_sentences 这次对上的学过的条目：
-- 边界还在就留着（用户在两侧选过字的话，字跟着换），被用户改掉了就忘掉，下次照解码器的切。
-- 上屏的文字和树对不上时（直接选了整句候选）什么都不做。
local function block_code(input, block)
    local parts, pos = {}, block.from + 1
    while pos <= block.to do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos) or input:match("^[a-z]" .. WILDCARD, pos)
        -- 简拼的音节不是确定的读音，不学。
        if not token or token:sub(2, 2) == WILDCARD then return "" end
        parts[#parts + 1] = token:sub(1, 2)
        pos = pos + #token
    end
    return table.concat(parts)
end

function learn_bounds(ctx, text)
    local resized, used = ctx:get_property("nova_resized") or "", ctx:get_property("nova_bounds_used") or ""
    if resized == "" and used == "" then return end
    local seg = ctx.composition:back()
    if not seg then return end
    local parts, ending, starting = {}, {}, {}
    for _, block in ipairs((parse_tree(ctx:get_property("nova_tree") or ""))) do
        parts[#parts + 1] = block.text
        ending[block.to], starting[block.from] = block, block
    end
    local shown = table.concat(parts)
    if shown == "" or text:sub(-#shown) ~= shown then return end
    local input = ctx.input:sub(seg._start + 1, seg._end)
    for pos, left, right in used:gmatch("(%d+):(%l+):(%l+)\n") do
        local a, b = ending[tonumber(pos)], starting[tonumber(pos)]
        if a and b and block_code(input, a) == left and block_code(input, b) == right then
            -- 解码器自己也这么切时字可能不同（市｜长江、是｜长江），那不是用户改的，学过的字不动。
            if a.chosen or b.chosen then bounds.put(left, a.text, right, b.text) end
        else
            bounds.drop(bounds.key_of(left, right))
        end
    end
    for pos, prefix in resized:gmatch("(%d+):([^\n]*)\n") do
        local a, b = ending[tonumber(pos)], starting[tonumber(pos)]
        if a and b and input:sub(1, #prefix) == prefix then
            bounds.put(block_code(input, a), a.text, block_code(input, b), b.text)
        end
    end
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
    -- 这条路不经过 commit_notifier，边界在这里学。
    learn_bounds(ctx, text)
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

-- 段内每个音节的起止，和 nova_sentences 的 syllables 同一套切法。
local function syllable_ranges(input)
    local ranges, pos = {}, 1
    while pos <= #input do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos) or input:match("^[a-z]" .. WILDCARD, pos)
        if not token then break end
        ranges[#ranges + 1] = { pos - 1, pos - 1 + #token }
        pos = pos + #token
    end
    return ranges
end

-- 块里 [from, to) 这几个音节对应的字。
local function block_chars(input, block, from, to)
    local index, first, last = 0, nil, nil
    for _, range in ipairs(syllable_ranges(input)) do
        if range[1] >= block.from and range[2] <= block.to then
            index = index + 1
            if range[1] >= from and range[2] <= to then
                first = first or index
                last = index
            end
        end
    end
    if not first then return nil end
    local a, b = utf8.offset(block.text, first), utf8.offset(block.text, last + 1)
    return a and b and block.text:sub(a, b - 1) or nil
end

local function choose(env, seg, blocks, chosen, alt)
    local ctx = env.engine.context
    -- 打错键的备选带着改好的编码：换掉这一段输入，整段重新解码。
    if alt.code then
        local before, after = ctx.input:sub(1, seg._start), ctx.input:sub(seg._end + 1)
        clear(ctx)
        ctx.input = before .. alt.code .. after
        ctx.caret_pos = #before + #alt.code
        return
    end
    local input = ctx.input:sub(seg._start + 1, seg._end)
    -- 单字备选从块中间开始，只换光标处这个字。
    local from = alt.from or chosen.from
    if from == 0 and alt.to == #input then
        commit_alternative(env, seg, alt.text)
        return
    end
    local pins = { pin_line(input, from, alt.to, "h", alt.text) }
    for _, block in ipairs(blocks) do
        if block.to <= from or (block.chosen and block.from >= alt.to) then
            pins[#pins + 1] = pin_line(input, block.from, block.to, block.chosen and "h" or "s", block.text)
        end
    end
    -- 同一个词里在它前面的字原样保留，词从这里拆开；后面的字跟着重新解码。
    if alt.from then
        local before = block_chars(input, chosen, chosen.from, from)
        if before then pins[#pins + 1] = pin_line(input, chosen.from, from, chosen.chosen and "h" or "s", before) end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    ctx:set_property("nova_pins_end", tostring(#input))
    ctx:set_property("nova_open_from", from .. ":" .. ctx.input)
    ctx:set_property("nova_alt_page", "")
    ctx:set_property("nova_cycle", "")
    ctx:set_property("nova_redecode", "")
    ctx:refresh_non_confirmed_composition()
end

-- Shift+←/→：跳到上一个/下一个词块的末尾。没有焦点时往左到最后一块、往右到第一块；
-- 最后一块再往右回到没有焦点，所以一直按 Tab 是循环：第一块 … 最后一块、没有焦点、第一块。
local function jump_block(ctx, blocks, step)
    local cursor, focused = cursor_of(ctx)
    if not focused then
        if #blocks > 0 then set_cursor(ctx, step < 0 and blocks[#blocks].to or blocks[1].to, true) end
    else
        local target
        for i = 1, #blocks do
            local to = blocks[step > 0 and i or #blocks + 1 - i].to
            if (step > 0 and to > cursor) or (step < 0 and to < cursor) then target = to break end
        end
        if target then set_cursor(ctx, target, true)
        elseif step > 0 then set_cursor(ctx, #ctx.input, false)
        else set_cursor(ctx, blocks[1] and blocks[1].to or 0, true) end
    end
    ctx:refresh_non_confirmed_composition()
end

-- ↓/↑：把焦点词直接换成下一个/上一个备选。第一次按时记下焦点词的全部备选（nova_focus_alts，
-- nova_sentences 写的）和其他词当时的样子，之后都按这份记录换：列表不会因为换了词而变，
-- 第 0 项是原来的词。光标或输入变了就重新开始。
--   nova_cycle：`序号:光标:输入`；nova_cycle_alts：`起:止:文字` 每行一个；
--   nova_cycle_base：其他词的固定段；nova_cycle_orig：原来的词 `起:止:h|s:文字`。
local function cycle(env, seg, blocks, focus, step)
    local ctx = env.engine.context
    local input = ctx.input:sub(seg._start + 1, seg._end)
    local signature = cursor_of(ctx) .. ":" .. ctx.input
    local index, saved = (ctx:get_property("nova_cycle") or ""):match("^(%d+):(.*)$")
    if saved ~= signature then
        local block = blocks[focus]
        local alts = ctx:get_property("nova_focus_alts") or ""
        if not block or alts == "" then return end
        local base = {}
        for i, other in ipairs(blocks) do
            if i ~= focus then base[#base + 1] = pin_line(input, other.from, other.to, other.chosen and "h" or "s", other.text) end
        end
        ctx:set_property("nova_cycle_base", table.concat(base))
        ctx:set_property("nova_cycle_alts", alts)
        ctx:set_property("nova_cycle_orig", string.format("%d:%d:%s:%s", block.from, block.to, block.chosen and "h" or "s", block.text))
        index = 0
    end
    local list = {}
    for from, to, text in (ctx:get_property("nova_cycle_alts") or ""):gmatch("(%d+):(%d+):([^\n]*)\n") do
        list[#list + 1] = { from = tonumber(from), to = tonumber(to), text = text }
    end
    index = math.min(math.max(tonumber(index) + step, 0), #list)
    local of, ot, kind, otext = (ctx:get_property("nova_cycle_orig") or ""):match("^(%d+):(%d+):([hs]):(.*)$")
    local original = { from = tonumber(of), to = tonumber(ot), text = otext }
    local alt = list[index]
    local low, high = original.from, original.to
    if alt then low, high = math.min(low, alt.from), math.max(high, alt.to) end
    local pins = {}
    -- 前面的词冻结；后面的只留用户选过的，其余跟着换上的词重新解码。换成更长的词时，被它盖住的词让开。
    -- 回到原来的词时其他词全部照原样放回。
    for line, from, to, other in (ctx:get_property("nova_cycle_base") or ""):gmatch("((%d+):(%d+):[^:]*:([hs]):[^\n]*\n)") do
        if tonumber(to) <= low or (tonumber(from) >= high and (other == "h" or not alt)) then
            pins[#pins + 1] = line
        end
    end
    if not alt then
        pins[#pins + 1] = pin_line(input, original.from, original.to, kind, original.text)
    else
        pins[#pins + 1] = pin_line(input, alt.from, alt.to, "h", alt.text)
        -- 只换了词里的一个字时，其他字原样保留。
        if alt.from > original.from then
            local before = block_chars(input, original, original.from, alt.from)
            if before then pins[#pins + 1] = pin_line(input, original.from, alt.from, "s", before) end
        end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    ctx:set_property("nova_pins_end", tostring(#input))
    ctx:set_property("nova_open_from", alt and (low .. ":" .. ctx.input) or "")
    ctx:set_property("nova_cycle", index .. ":" .. signature)
    ctx:set_property("nova_redecode", "")
    ctx:set_property("nova_alt_page", "")
    ctx:refresh_non_confirmed_composition()
end

-- [ / ]：焦点块让出最后一个/第一个音节，留下的字原样固定（和以词定字一样），光标留在这块上，
-- 可以接着按。让出的音节和右边/左边那块（用户没选过时）一起单独解码，词不越过新边界；
-- 其他块原样冻结。块只剩一个音节时不动。
local function shrink(env, seg, blocks, focus, keep_front)
    local ctx = env.engine.context
    local input = ctx.input:sub(seg._start + 1, seg._end)
    local block = blocks[focus]
    local inside = {}
    for _, range in ipairs(syllable_ranges(input)) do
        if range[1] >= block.from and range[2] <= block.to then inside[#inside + 1] = range end
    end
    if #inside < 2 then return end
    local keep_from, keep_to, low, high, neighbor
    if keep_front then
        keep_from, keep_to = block.from, inside[#inside - 1][2]
        neighbor = blocks[focus + 1]
        low, high = keep_to, (neighbor and not neighbor.chosen) and neighbor.to or block.to
    else
        keep_from, keep_to = inside[2][1], block.to
        neighbor = blocks[focus - 1]
        low, high = (neighbor and not neighbor.chosen) and neighbor.from or block.from, keep_from
    end
    local kept = block_chars(input, block, keep_from, keep_to)
    if not kept then return end
    local pins = { pin_line(input, keep_from, keep_to, "h", kept) }
    for i, other in ipairs(blocks) do
        if i ~= focus and (other.to <= low or other.from >= high) then
            pins[#pins + 1] = pin_line(input, other.from, other.to, other.chosen and "h" or "s", other.text)
        end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    ctx:set_property("nova_pins_end", tostring(#input))
    ctx:set_property("nova_open_from", math.min(low, keep_from) .. ":" .. ctx.input)
    ctx:set_property("nova_redecode", low .. ":" .. high .. ":" .. ctx.input)
    ctx:set_property("nova_cycle", "")
    -- 这条边界是用户定的，上屏时学，见 learn_bounds。连着按是在挪同一条边界，旧位置作废。
    local moved, edge = keep_front and block.to or block.from, keep_front and keep_to or keep_from
    local resized = {}
    for line, pos in (ctx:get_property("nova_resized") or ""):gmatch("((%d+):[^\n]*\n)") do
        if tonumber(pos) ~= moved and tonumber(pos) ~= edge then resized[#resized + 1] = line end
    end
    resized[#resized + 1] = edge .. ":" .. input:sub(1, edge + 2) .. "\n"
    ctx:set_property("nova_resized", table.concat(resized))
    set_cursor(ctx, seg._start + keep_to, true)
    ctx:refresh_non_confirmed_composition()
end

-- 用户词库里的词条：键是 `音节;辅助码 音节;辅助码 <Tab>文字`。找出文字是 text、每个音节的双拼和 pairs
-- 一一对上的词条，标成已删除（librime 的 UpdateEntry(entry, -1)）。返回删了几条。
-- 只能按键的前缀查，所以用第一个音节查出一批再筛。
local function forget(env, pairs, text)
    local memory = env.memory
    if not memory or not memory:user_lookup(pairs[1] .. ";", true) then return 0 end
    local found = {}
    for entry in memory:iter_user() do
        if entry.text == text then
            local i, same = 0, true
            for syllable in entry.custom_code:gmatch("%S+") do
                i = i + 1
                if syllable:match("^[^;]*") ~= pairs[i] then same = false break end
            end
            if same and i == #pairs then found[#found + 1] = entry end
        end
    end
    for _, entry in ipairs(found) do memory:update_userdict(entry, -1, "") end
    return #found
end

-- 删词：把焦点块（没有焦点时是最后一块）的词从用户词库里删掉，这一块当场重新解码。
-- 学到的更长的词如果盖住这一块、文字又和现在显示的一样（学了「范伟根」，块是「范伟」），一起删：
-- 不删的话解码器下次还是用它写出同样的字。词库自带的词删不掉，只是去掉了学到的那份优先。
-- 其他块原样固定；nova_redecode 让这一块单独解码，nova_lm_filter 看到它也不会把删掉的写法带回来。
local MAX_WORD_SYLLABLES = 6  -- 和 nova_sentences 查词的最长词一致

local function delete_word(env, seg, blocks, focus)
    local ctx = env.engine.context
    local target = blocks[focus or #blocks]
    if not target then return end
    local input = ctx.input:sub(seg._start + 1, seg._end)
    -- 每个音节的双拼、显示的字，以及它属于哪一块。
    local pairs, chars, first, last = {}, {}, nil, nil
    for _, range in ipairs(syllable_ranges(input)) do
        for _, block in ipairs(blocks) do
            if range[1] >= block.from and range[2] <= block.to then
                local char = block_chars(input, block, range[1], range[2])
                if not char then return end
                pairs[#pairs + 1] = input:sub(range[1] + 1, range[1] + 2)
                chars[#chars + 1] = char
                if block == target then
                    first = first or #pairs
                    last = #pairs
                end
            end
        end
    end
    if not first then return end
    -- 刚上屏的词还在 librime 的待写缓冲里（下一次上屏才写进词库），查不到也删不掉：先写进去。
    if env.memory then env.memory:finish_session() end
    local deleted = 0
    for from = math.max(1, last - MAX_WORD_SYLLABLES + 1), first do
        for to = last, math.min(#pairs, from + MAX_WORD_SYLLABLES - 1) do
            deleted = deleted + forget(env, { table.unpack(pairs, from, to) }, table.concat(chars, "", from, to))
        end
    end
    if deleted == 0 then return end
    local pins = {}
    for _, block in ipairs(blocks) do
        if block ~= target then
            pins[#pins + 1] = pin_line(input, block.from, block.to, block.chosen and "h" or "s", block.text)
        end
    end
    ctx:set_property("nova_pins", table.concat(pins))
    ctx:set_property("nova_pins_end", tostring(#input))
    ctx:set_property("nova_open_from", target.from .. ":" .. ctx.input)
    ctx:set_property("nova_redecode", target.from .. ":" .. target.to .. ":" .. ctx.input)
    ctx:set_property("nova_cycle", "")
    ctx:set_property("nova_alt_page", "")
    ctx:set_property("nova_flush", "1")
    ctx:refresh_non_confirmed_composition()
end

-- 翻焦点块的备选。页码带着光标和输入，换了位置就回到第一页；页数上限由 nova_sentences 收住。
local function turn_page(ctx, step)
    local cursor = cursor_of(ctx)
    local signature = cursor .. ":" .. ctx.input
    local page, saved = (ctx:get_property("nova_alt_page") or ""):match("^(%d+):(.*)$")
    page = saved == signature and tonumber(page) or 0
    ctx:set_property("nova_alt_page", math.max(0, page + step) .. ":" .. signature)
    ctx:refresh_non_confirmed_composition()
end

-- 输入末尾没打完的单个字母，没有时返回 nil。和 nova_sentences 的 syllables 同一套切法。
local function pending_letter(input)
    local pos = 1
    while pos <= #input do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos) or input:match("^[a-z]" .. WILDCARD, pos)
        if not token then return input:match("^[a-z]$", pos) end
        pos = pos + #token
    end
end

-- 空格：末尾有半个音节时，完整的部分直接上屏，半个音节留下继续输入。
-- Rime 默认只确认前面那段、不上屏，后面那个字母自成一段，必须补全它整句才能上屏。
local function commit_before_pending(env, seg)
    local ctx = env.engine.context
    if seg._start ~= 0 or seg.selected_index > 0 then return false end
    local letter = pending_letter(ctx.input:sub(seg._start + 1, seg._end))
    if not letter or #ctx.input < 3 then return false end
    local top = seg.menu:get_candidate_at(0)
    if not top or top._end ~= seg._end - 1 then return false end
    local text = top.text
    ctx:pop_input(1)
    commit_alternative(env, ctx.composition:back(), text)
    ctx:push_input(letter)
    return true
end

-- 空格：有打错键的原样字母块时，首选只到打错的音节前。交给 Rime 的话它只确认这一段、不上屏，
-- 剩下的字母另成一段（o 开头的还会被符号表接走），要再按一次空格。这里一次上屏：前面的字 + 原样的字母。
local function commit_with_raw_tail(env, seg)
    local ctx = env.engine.context
    local top = seg.menu:get_candidate_at(0)
    if not top or top._end >= seg._end then return false end
    local tail, text = ctx.input:sub(top._end + 1), top.text
    ctx:pop_input(#tail)
    commit_alternative(env, ctx.composition:back(), text)
    env.engine:commit_text(tail)
    return true
end

local function is_code_letter(code)
    return (code >= 0x61 and code <= 0x7a) or (code >= 0x41 and code <= 0x5a)
end

local function func(key, env)
    if not env.enabled or key:release() or key:alt() or key:super() then return 2 end
    local code = key.keycode
    local ctx = env.engine.context
    if not ctx:is_composing() then return 2 end
    -- 删词。显示普通列表时（没有树，或用户在翻页）交给 Rime 自己删高亮的候选。
    if code == DELETE and (key:ctrl() or key:shift()) then
        local tree = ctx:get_property("nova_tree") or ""
        local seg = ctx.composition:back()
        if tree == "" or seg.selected_index > 0 or seg.menu:prepare(1) == 0 or list_open(ctx) then return 2 end
        local blocks, focus = parse_tree(tree)
        delete_word(env, seg, blocks, focus)
        return 1
    end
    if key:ctrl() then return 2 end
    local cursor, focused = cursor_of(ctx)
    local inside = cursor < #ctx.input
    -- 光标在末尾但焦点在最后一块时，接着打字就是普通输入，先取消焦点。
    if focused and not inside and (is_code_letter(code) or code == BACKSPACE) then
        set_cursor(ctx, cursor, false)
        return 2
    end
    -- 光标在中间时，字母、退格、Delete 改光标处的字母。
    if inside and is_code_letter(code) then insert_at_cursor(ctx, string.char(code)) return 1 end
    if code == BACKSPACE and inside then delete_at_cursor(ctx, true) return 1 end
    if code == DELETE and inside then delete_at_cursor(ctx, false) return 1 end
    if code == LEFT and not key:shift() then
        set_cursor(ctx, focused and cursor - 1 or #ctx.input - 1, true) ctx:refresh_non_confirmed_composition() return 1
    end
    if code == RIGHT and not key:shift() then
        if not focused then return 1 end
        set_cursor(ctx, cursor + 1, cursor + 1 <= #ctx.input and inside) ctx:refresh_non_confirmed_composition() return 1
    end
    if code == HOME then set_cursor(ctx, 0, true) ctx:refresh_non_confirmed_composition() return 1 end
    if code == END then set_cursor(ctx, #ctx.input, false) ctx:refresh_non_confirmed_composition() return 1 end
    if code == REFRESH then ctx:refresh_non_confirmed_composition() return 1 end
    if focused and (code == PAGE_UP or code == COMMA or code == PAGE_DOWN or code == PERIOD) then
        turn_page(ctx, (code == PAGE_UP or code == COMMA) and -1 or 1)
        return 1
    end
    if code == PAGE_UP or code == PAGE_DOWN then
        -- 树正显示着（有树、有候选、还在第一页第一项）才接：PageDown 打开列表，列表第一页上 PageUp 关掉。
        if (ctx:get_property("nova_tree") or "") == "" then return 2 end
        local seg = ctx.composition:back()
        if seg.selected_index > 0 or seg.menu:prepare(1) == 0 then return 2 end
        local open = list_open(ctx)
        if (code == PAGE_DOWN) == open then return 2 end
        ctx:set_property("nova_list", open and "" or ctx.input)
        return 1
    end
    local is_digit = (code >= 0x31 and code <= 0x39) or code == SEMICOLON
    local is_cycle = focused and (code == UP or code == DOWN)
    local is_shrink = focused and (code == BRACKET_LEFT or code == BRACKET_RIGHT)
    if not is_digit and not is_cycle and not is_shrink and code ~= LEFT and code ~= RIGHT and code ~= SPACE then return 2 end
    local tree = ctx:get_property("nova_tree") or ""
    if tree == "" then return (code == LEFT or code == RIGHT) and 1 or 2 end
    -- 用户翻页或移动高亮后，面板显示的是普通列表，按键归列表。
    local seg = ctx.composition:back()
    if seg.selected_index > 0 then return 2 end
    -- 菜单空时过滤器没有运行，属性里还是上一次的树。
    if seg.menu:prepare(1) == 0 then return 2 end
    -- 列表刚打开、还停在第一项时也一样；空格除外，高亮的就是首选整句，照常由这里上屏。
    if code ~= SPACE and list_open(ctx) then return 2 end
    if code == SPACE then
        -- 有打错键的原样字母块（标记 t）：第一次空格不上屏，先把多打、漏打的改法也算出来列成备选；
        -- 再按一次空格原样上屏，见 commit_with_raw_tail。
        local has_typo = false
        for line in tree:gmatch("[^\n]+") do
            local flags = line:match("^[^\t]*")
            local head = flags:match("^[^a]*")
            if head:find("t", 1, true) then has_typo = true break end
        end
        if has_typo and ctx:get_property("nova_fix_full") ~= ctx.input then
            if focused then set_cursor(ctx, #ctx.input, false) end
            ctx:set_property("nova_fix_full", ctx.input)
            ctx:refresh_non_confirmed_composition()
            return 1
        end
        -- 空格上屏整句：光标回到末尾，首选本来就覆盖整句。
        if focused then set_cursor(ctx, #ctx.input, false) end
        if has_typo and commit_with_raw_tail(env, seg) then return 1 end
        return commit_before_pending(env, seg) and 1 or 2
    end
    local blocks, focus = parse_tree(tree)
    if is_cycle then
        if focus then cycle(env, seg, blocks, focus, code == DOWN and 1 or -1) end
        return 1
    end
    if is_shrink then
        if focus then shrink(env, seg, blocks, focus, code == BRACKET_LEFT) end
        return 1
    end
    if is_digit then
        local chosen, alt = find_choice(blocks, focus, code == SEMICOLON and 1 or code - 0x30)
        -- ; 没有可选的备选时照常是标点。
        if not alt and code == SEMICOLON then return 2 end
        -- 没有这个编号时吞掉，否则选中的是面板上看不到的候选。
        if alt then choose(env, seg, blocks, chosen, alt) end
        return 1
    end
    -- 还没有词块时也吞掉。
    if #blocks == 0 then return 1 end
    jump_block(ctx, blocks, code == LEFT and -1 or 1)
    return 1
end

return { init = init, func = func, fini = fini, replace_input = replace_input }
