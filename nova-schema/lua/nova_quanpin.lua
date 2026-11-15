-- nova_quanpin -- 全拼输入。开关 quanpin（方案选单里的「双拼/全拼」）打开时，字母键在这里处理。
--
-- 用户打的拼音（原始字母）切成音节，每个音节换成自然码双拼，Rime 的输入（ctx.input）始终是双拼编码。
-- 解码、词块树、改错按键、GPT-2 插件都照双拼工作，不用知道全拼。
-- 面板的字母行显示原始拼音：nova_qp_raw 是拼音，nova_qp_map 是双拼每个位置（0..#输入）对应的拼音位置，
-- 逗号分隔。两个属性为空时面板直接显示输入。
--
-- 切音节：音节的二元词频（nova_quanpin.txt，scripts/wanxiang/quanpin_table.py 生成）上做 Viterbi，
-- 末尾可以是没打完的音节（按以它开头的音节的总词频打分），切不成音节的字母每个罚 40（log 量纲）。
-- 单独一个声母（b p m f d t n l g k h j q x r z c s y w，以及 zh ch sh）可以当简拼音节：nh 是你好，
-- 罚 ABBREV（见下面的常量）。简拼写成「声母键 + 通配符 V」两个字符（nVhV），和别的音节一样宽，
-- 下游的位置运算不用改；schema 的 abbrev 规则让词库认得这种编码。
-- 末尾单独一个声母，前面是完整音节时仍当没打完的（nih 在去 nihao 的路上），不让词块每敲一键变一次；
-- 前面是简拼时当简拼（nh 立刻解码），所以 nihaos 等到 nihaosj 才出 s、j。
-- 每打一个字母只重切最后 3 个单元，前面的不再变。6486 句评测逐键切分，整句切对 98.9%（加简拼之前量的）。
--   单元：s 音节（双拼两个字母）、j 简拼音节（声母键 + V）、p 末尾没打完的音节（双拼的声母键）、
--   g 切不成音节的字母（原样）、a 大写辅助码（原样）、d 隔音符 '（不占双拼）、
--   x 整段原样（日期 orq、符号表 ofh 这类编码）。
-- 光标只停在单元之间：←/→ 按音节移动；在中间打字、退格、Delete 改的是光标处的拼音，
-- 前后各一两个单元跟着重切，固定段和树照双拼的改动平移（nova_tree_keys.replace_input）。
-- 输入被别处改了（选打错键的备选、空格上屏前半句）时，没变的头尾单元保留拼音，变了的部分从双拼反推。
-- 输入里有字母以外的字符（邮箱、网址）或以大写开头（英文）时，这次输入不再管，原样交给 Rime。

local tree_keys = require("nova_tree_keys")

local TABLE_FILE = "nova_quanpin.txt"
local GARBAGE = -40.0
-- 简拼音节的罚分，要介于正常音节（二元分数一般在 -3 到 -12）和 GARBAGE 之间。
local ABBREV = -20.0
-- 简拼音节编码里跟在声母键后面的通配符，和 nova.schema.yaml 的 abbrev 规则一致。
local WILDCARD = "V"
local WINDOW = 3
local LEFT, RIGHT, BACKSPACE, DELETE, APOSTROPHE = 0xff51, 0xff53, 0xff08, 0xffff, 0x27
-- 双拼的声母键反推拼音声母（没打完的音节从双拼反推时用）。
local INITIAL_OF = { v = "zh", i = "ch", u = "sh" }
-- 能单独当简拼的声母，对应的双拼声母键。
local INITIAL_KEY = { zh = "v", ch = "i", sh = "u" }
for letter in ("bpmfdtnlgkhjqxrzcsyw"):gmatch(".") do INITIAL_KEY[letter] = letter end

local T  -- 表，所有会话共用，第一次用时读

local function load_table()
    if T then return T end
    T = { code = {}, uni = {}, bi = {}, lu = {}, lp = {}, prefix_code = {}, inv = {}, maxl = 1 }
    local path
    for _, dir in ipairs({ rime_api.get_user_data_dir(), rime_api.get_shared_data_dir() }) do
        local file = io.open(dir .. "/" .. TABLE_FILE, "r")
        if file then path = dir .. "/" .. TABLE_FILE file:close() break end
    end
    if not path then
        log.error("nova_quanpin: " .. TABLE_FILE .. " not found")
        return T
    end
    local total = 0
    for line in io.lines(path) do
        local kind, a, b, count = line:match("^(%a)\t(%S+)\t(%S+)\t(%d+)")
        if kind == "s" then
            count = tonumber(count)
            T.code[a], T.uni[a] = b, count
            total = total + count
            T.maxl = math.max(T.maxl, #a)
            if not T.inv[b] or count > T.uni[T.inv[b]] then T.inv[b] = a end
        elseif kind == "b" then
            T.bi[a .. " " .. b] = tonumber(count)
        end
    end
    local mass, best = {}, {}
    for syllable, count in pairs(T.uni) do
        T.lu[syllable] = math.log((count + 1) / total)
        for i = 1, #syllable - 1 do
            local prefix = syllable:sub(1, i)
            mass[prefix] = (mass[prefix] or 0) + count
            if not best[prefix] or count > T.uni[best[prefix]] then best[prefix] = syllable end
        end
    end
    for prefix, m in pairs(mass) do
        T.lp[prefix] = math.log((m + 1) / total)
        T.prefix_code[prefix] = T.code[best[prefix]]:sub(1, 1)
    end
    return T
end

-- 音节 b 跟在 a 后面的分数。a 为 "" 时只看 b 自己的词频。
local function bigram(a, b)
    if a == "" then return T.lu[b] end
    local c = T.bi[a .. " " .. b] or 0
    return math.log(0.7 * c / T.uni[a] + 0.3 * math.exp(T.lu[b]))
end

-- 一串小写字母切成单元。prev 是它前面的音节（没有时为 ""），after_abbr 是它前面的单元是不是简拼。
local function segment(text, prev, after_abbr)
    local n = #text
    local best = {}
    for i = 0, n do best[i] = {} end
    best[0][prev] = { 0.0 }
    for i = 0, n - 1 do
        for last, entry in pairs(best[i]) do
            local score = entry[1]
            for l = 1, math.min(T.maxl, n - i) do
                local s = text:sub(i + 1, i + l)
                if T.code[s] then
                    local v = score + bigram(last, s)
                    local old = best[i + l][s]
                    if not old or v > old[1] then best[i + l][s] = { v, i, last, s, "s" } end
                end
            end
            local v = score + GARBAGE
            local old = best[i + 1][""]
            if not old or v > old[1] then best[i + 1][""] = { v, i, last, text:sub(i + 1, i + 1), "g" } end
            for l = 1, math.min(2, n - i) do
                local s = text:sub(i + 1, i + l)
                if INITIAL_KEY[s] then
                    v = score + ABBREV
                    old = best[i + l][""]
                    if not old or v > old[1] then best[i + l][""] = { v, i, last, s, "j" } end
                end
            end
        end
    end
    local top, top_i, top_last, top_part = nil, n, nil, nil
    for last, entry in pairs(best[n]) do
        if not top or entry[1] > top then top, top_last, top_part = entry[1], last, nil end
    end
    for i = math.max(0, n - T.maxl + 1), n - 1 do
        local part = text:sub(i + 1)
        local lp = T.lp[part]
        -- 没打完的部分本身是音节时，只按完整音节和前一个音节一起算（上面 best[n] 已经算过）。
        -- 按前缀总频率算会偏向后面还有字母：enen 会切成 e + nen(g)，打不出「嗯嗯」。
        if lp and not T.code[part] then
            for last, entry in pairs(best[i]) do
                if not top or entry[1] + lp > top then top, top_i, top_last, top_part = entry[1] + lp, i, last, part end
            end
        end
    end
    local out = {}
    -- 没打完的部分自己就是音节时（xi 后面可能还有 an），先按这个音节出字，接着打再重切。
    if top_part and T.code[top_part] then
        out[1] = { raw = top_part, code = T.code[top_part], kind = "s" }
    elseif top_part then
        out[1] = { raw = top_part, code = T.prefix_code[top_part], kind = "p" }
    end
    local i, last = top_i, top_last
    while i > 0 do
        local entry = best[i][last]
        local raw, kind = entry[4], entry[5]
        local code = raw
        if kind == "s" then code = T.code[raw] elseif kind == "j" then code = INITIAL_KEY[raw] .. WILDCARD end
        table.insert(out, 1, { raw = raw, code = code, kind = kind })
        i, last = entry[2], entry[3]
    end
    -- 末尾单独一个声母、前面是简拼：也当简拼。前面是完整音节时仍留着不动，见文件头。
    local tail, before = out[#out], out[#out - 1]
    if tail and tail.kind == "p" and INITIAL_KEY[tail.raw] and (before and before.kind == "j" or not before and after_abbr) then
        tail.code, tail.kind = INITIAL_KEY[tail.raw] .. WILDCARD, "j"
    end
    return out
end

-- 一段原始字母（可能夹着大写和 '）切成单元。prev、after_abbr 同上。
local function tokenize(raw, prev, after_abbr)
    local out, pos = {}, 1
    while pos <= #raw do
        local run = raw:match("^%l+", pos)
        if run then
            for _, unit in ipairs(segment(run, prev, after_abbr)) do out[#out + 1] = unit end
            pos = pos + #run
        else
            local ch = raw:sub(pos, pos)
            out[#out + 1] = { raw = ch, code = ch == "'" and "" or ch, kind = ch == "'" and "d" or "a" }
            pos = pos + 1
        end
        local last = out[#out]
        prev = last and last.kind == "s" and last.raw or ""
        after_abbr = last ~= nil and last.kind == "j"
    end
    return out
end

local function concat(units, field, from, to)
    local parts = {}
    for i = from or 1, to or #units do parts[#parts + 1] = units[i][field] end
    return table.concat(parts)
end

-- 双拼编码反推单元（输入被别处改了时用）。
local function from_code(code)
    local out, pos = {}, 1
    while pos <= #code do
        local pair = code:match("^%l%l", pos)
        local syllable = pair and T.inv[pair]
        local key = code:match("^%l" .. WILDCARD, pos)
        if syllable then
            out[#out + 1] = { raw = syllable, code = pair, kind = "s" }
            pos = pos + 2
        elseif key then
            out[#out + 1] = { raw = INITIAL_OF[key:sub(1, 1)] or key:sub(1, 1), code = key, kind = "j" }
            pos = pos + 2
        else
            local ch = code:sub(pos, pos)
            if ch:match("%u") then
                out[#out + 1] = { raw = ch, code = ch, kind = "a" }
            elseif pos == #code then
                out[#out + 1] = { raw = INITIAL_OF[ch] or ch, code = ch, kind = "p" }
            else
                out[#out + 1] = { raw = ch, code = ch, kind = "g" }
            end
            pos = pos + 1
        end
    end
    return out
end

-- 让 env.units 和 ctx.input 对上。没变的头尾单元原样保留。
local function sync(env, ctx)
    local input = ctx.input
    if input == env.code then return end
    local units = env.units or {}
    local head, pos = {}, 1
    for _, unit in ipairs(units) do
        if input:sub(pos, pos + #unit.code - 1) ~= unit.code then break end
        head[#head + 1] = unit
        pos = pos + #unit.code
    end
    local tail, stop = {}, #input
    for i = #units, #head + 1, -1 do
        local unit = units[i]
        if stop - #unit.code + 1 < pos or input:sub(stop - #unit.code + 1, stop) ~= unit.code then break end
        table.insert(tail, 1, unit)
        stop = stop - #unit.code
    end
    local middle = from_code(input:sub(pos, stop))
    for _, unit in ipairs(middle) do head[#head + 1] = unit end
    for _, unit in ipairs(tail) do head[#head + 1] = unit end
    env.units, env.code = head, input
end

-- 每个单元的拼音起止和双拼起止。
local function spans(units)
    local list, r, c = {}, 0, 0
    for i, unit in ipairs(units) do
        list[i] = { r, r + #unit.raw, c, c + #unit.code }
        r, c = r + #unit.raw, c + #unit.code
    end
    return list
end

local function publish(env, ctx)
    local units = env.units or {}
    local map, r = { "0" }, 0
    for _, unit in ipairs(units) do
        -- 音节中间的双拼位置对到音节开头，这样点拼音里任何一个字母都落到音节末尾（见 NovaLayout）。
        for k = 1, #unit.code do map[#map + 1] = tostring(k == #unit.code and r + #unit.raw or r) end
        r = r + #unit.raw
    end
    ctx:set_property("nova_qp_raw", concat(units, "raw"))
    ctx:set_property("nova_qp_map", table.concat(map, ","))
end

local function reset(env, ctx)
    env.units, env.code = {}, ""
    if (ctx:get_property("nova_qp_raw") or "") ~= "" then
        ctx:set_property("nova_qp_raw", "")
        ctx:set_property("nova_qp_map", "")
    end
end

-- 把 units 换成新单元，按双拼的改动设 ctx.input。cursor 是新的双拼光标（nil 表示末尾、没有焦点）。
local function apply(env, ctx, units, cursor)
    local raw = concat(units, "raw")
    if env.special[raw] then units = { { raw = raw, code = raw, kind = "x" } } end
    if raw == "" then
        env.units, env.code = {}, ""
        ctx:clear()
        return
    end
    local old, new = ctx.input, concat(units, "code")
    local p = 0
    while p < #old and p < #new and old:byte(p + 1) == new:byte(p + 1) do p = p + 1 end
    local q = 0
    while q < #old - p and q < #new - p and old:byte(#old - q) == new:byte(#new - q) do q = q + 1 end
    local inserted = new:sub(p + 1, #new - q)
    env.units, env.code = units, new
    ctx:set_property("nova_cursor", cursor and tostring(cursor) or "")
    ctx:set_property("nova_alt_page", "")
    -- 只在末尾加字母、删字母时和双拼打字一样走 push_input / pop_input，不平移固定段。
    if new:sub(1, #old) == old and #new > #old then
        ctx:push_input(new:sub(#old + 1))
    elseif old:sub(1, #new) == new and #old > #new then
        ctx:pop_input(#old - #new)
    elseif old ~= new then
        tree_keys.replace_input(ctx, p, #old - p - q, inserted, inserted:match("^%u$") ~= nil)
    else
        publish(env, ctx)
        ctx:refresh_non_confirmed_composition()
    end
end

-- 在拼音位置 at 删去 removed 个字母、插入 text，重切改动附近的单元。
local function edit(env, ctx, at, removed, text, at_end)
    local units = env.units
    local sp = spans(units)
    -- 改动所在的单元：插入时是 at 前面那个，删除时是被删字母所在的那个。
    local j = #units
    for i, s in ipairs(sp) do
        if (removed > 0 and at < s[2]) or (removed == 0 and at <= s[2] and at > s[1]) then j = i break end
        if removed == 0 and at == 0 then j = 0 break end
    end
    local lo, hi
    if at_end then lo, hi = math.max(1, #units - WINDOW + 1), #units
    else lo, hi = math.max(1, j - 1), math.min(#units, j + 2) end
    local start = lo <= #units and sp[lo][1] or at
    local window = concat(units, "raw", lo, hi)
    window = window:sub(1, at - start) .. text .. window:sub(at - start + removed + 1)
    local prev = ""
    local after_abbr = lo > 1 and units[lo - 1].kind == "j"
    for i = lo - 1, 1, -1 do
        if units[i].kind == "s" then prev = units[i].raw break end
        if units[i].kind ~= "d" then break end
    end
    local new = {}
    for i = 1, lo - 1 do new[#new + 1] = units[i] end
    for _, unit in ipairs(tokenize(window, prev, after_abbr)) do new[#new + 1] = unit end
    for i = hi + 1, #units do new[#new + 1] = units[i] end
    local cursor
    if not at_end then
        -- 光标落在改动后那个拼音位置所在单元的末尾。
        local target, c = at + #text, 0
        for _, s in ipairs(spans(new)) do
            if target > s[1] and target <= s[2] then c = s[4] break end
            if target <= s[1] then break end
            c = s[4]
        end
        cursor = c
    end
    apply(env, ctx, new, cursor)
end

local function load_special(config)
    local special = { orq = true, osj = true, oxq = true }
    local map = config:get_map("punctuator/symbols")
    if map then
        for _, key in ipairs(map:keys()) do
            local name = key:match("^/([a-z]+)$")
            if name and not name:match("^[ou]") then special["o" .. name] = true end
        end
    end
    return special
end

local function init(env)
    load_table()
    local ctx = env.engine.context
    env.special = load_special(env.engine.schema.config)
    env.units, env.code, env.passthrough = {}, "", false
    env.update = ctx.update_notifier:connect(function(c)
        if not c:get_option("quanpin") or not c:is_composing() then
            env.passthrough = false
            reset(env, c)
            return
        end
        if env.passthrough then return end
        if c.input:match("[^%a]") or c.input:match("^%u") then
            env.passthrough = true
            reset(env, c)
            return
        end
        sync(env, c)
        publish(env, c)
    end)
end

local function fini(env)
    env.update:disconnect()
end

-- 双拼光标对到单元边界：光标前一个单元的双拼末尾。
local function boundaries(units)
    local list, seen = { 0 }, { [0] = true }
    for _, s in ipairs(spans(units)) do
        if not seen[s[4]] then list[#list + 1] = s[4] seen[s[4]] = true end
    end
    return list
end

local function func(key, env)
    if key:release() or key:alt() or key:super() or key:ctrl() then return 2 end
    local ctx = env.engine.context
    if not ctx:get_option("quanpin") or ctx:get_option("ascii_mode") then return 2 end
    local code = key.keycode
    local lower = code >= 0x61 and code <= 0x7a
    local upper = code >= 0x41 and code <= 0x5a
    if not ctx:is_composing() then
        if not lower then return 2 end
        env.units, env.code, env.passthrough = {}, "", false
        edit(env, ctx, 0, 0, string.char(code), true)
        return 1
    end
    if env.passthrough then return 2 end
    -- 选了列表里的候选、只确认了前半段时，交给 Rime。
    local seg = ctx.composition:back()
    if not seg or seg._start ~= 0 then return 2 end
    sync(env, ctx)
    local units = env.units
    local raw_length = #concat(units, "raw")
    local cursor = tonumber(ctx:get_property("nova_cursor") or "")
    local focused = cursor ~= nil
    cursor = cursor and math.min(math.max(0, cursor), #ctx.input) or #ctx.input
    -- 双拼光标对应的拼音位置：光标所在单元边界前面那个单元的末尾。
    local raw_cursor = 0
    for _, s in ipairs(spans(units)) do
        if s[4] <= cursor then raw_cursor = s[2] end
    end
    local inside = cursor < #ctx.input
    if lower or upper or code == APOSTROPHE then
        if code == APOSTROPHE and raw_length == 0 then return 2 end
        if inside then edit(env, ctx, raw_cursor, 0, string.char(code), false)
        else edit(env, ctx, raw_length, 0, string.char(code), true) end
        return 1
    end
    if code == BACKSPACE then
        if inside then
            if raw_cursor > 0 then edit(env, ctx, raw_cursor - 1, 1, "", false) end
        else
            edit(env, ctx, raw_length - 1, 1, "", true)
        end
        return 1
    end
    if code == DELETE and not key:shift() then
        if inside then edit(env, ctx, raw_cursor, 1, "", raw_cursor + 1 >= raw_length) end
        return inside and 1 or 2
    end
    if (code == LEFT or code == RIGHT) and not key:shift() then
        local list = boundaries(units)
        local target
        if code == LEFT then
            local from = focused and cursor or #ctx.input
            for i = #list, 1, -1 do if list[i] < from then target = list[i] break end end
            target = target or 0
            ctx:set_property("nova_cursor", tostring(target))
        else
            if not focused then return 1 end
            for _, b in ipairs(list) do if b > cursor then target = b break end end
            if not target or (target >= #ctx.input and not inside) then
                ctx:set_property("nova_cursor", "")
            else
                ctx:set_property("nova_cursor", tostring(target))
            end
        end
        ctx:set_property("nova_alt_page", "")
        ctx:refresh_non_confirmed_composition()
        return 1
    end
    return 2
end

return { init = init, func = func, fini = fini }
