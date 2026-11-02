-- nova_sentences -- 在首选整句后面补多条不同的整句。
--
-- script_translator 只给一条整句，后面都是开头的词。这里对每个音节位置查词，
-- 用词频做 beam search，得到几条完整读法。首选仍是翻译器（带语法模型）的结果。

local MAX_WORD_SYLLABLES = 6   -- 一次查询覆盖的最长词
local WORDS_PER_SPAN = 6       -- 每段保留的词数
local BEAM = 8                 -- 每个位置保留的路径数
local EXTRA = 5                -- 补几条整句
local CACHE_LIMIT = 2000

local function syllables(input)
    local tokens, pos = {}, 1
    while pos <= #input do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos)
        if not token then return nil end
        tokens[#tokens + 1] = token
        pos = pos + #token
    end
    return tokens
end

-- 从 tokens[first] 开始的所有词，返回 { [音节数] = { {text, score}, ... } }。
-- 缓存按输入串共用，所以这里不能存绝对位置。
local function words_from(env, tokens, first)
    local last = math.min(#tokens, first + MAX_WORD_SYLLABLES - 1)
    local key = table.concat(tokens, "", first, last)
    local cached = env.cache[key]
    if cached then return cached end

    local ends, by_end, offset = {}, {}, 0
    for i = first, last do
        offset = offset + #tokens[i]
        ends[offset] = i - first + 1
    end
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        local seen = 0
        while seen < 300 do
            local cand = nxt(this)
            if not cand then break end
            seen = seen + 1
            local length = ends[cand._end]
            if length and cand.type ~= "sentence" and cand.quality > 0 then
                local list = by_end[length]
                if not list then
                    list = {}
                    by_end[length] = list
                end
                if #list < WORDS_PER_SPAN then
                    list[#list + 1] = { cand.text, math.log(cand.quality) }
                end
            end
        end
    end
    if env.cache_size >= CACHE_LIMIT then
        env.cache, env.cache_size = {}, 0
    end
    env.cache[key] = by_end
    env.cache_size = env.cache_size + 1
    return by_end
end

local function best_paths(extensions)
    table.sort(extensions, function(a, b) return a[2] > b[2] end)
    local seen, result = {}, {}
    for _, path in ipairs(extensions) do
        if not seen[path[1]] then
            seen[path[1]] = true
            result[#result + 1] = path
            if #result >= BEAM then break end
        end
    end
    return result
end

local function sentences(env, tokens)
    local n = #tokens
    local pending = {}
    for i = 1, n do pending[i] = {} end
    local paths = { [0] = { { "", 0 } } }
    for first = 1, n do
        local starts = paths[first - 1]
        if starts then
            for length, words in pairs(words_from(env, tokens, first)) do
                local bucket = pending[first + length - 1]
                for _, word in ipairs(words) do
                    for _, path in ipairs(starts) do
                        bucket[#bucket + 1] = { path[1] .. word[1], path[2] + word[2] - env.word_penalty }
                    end
                end
            end
        end
        if #pending[first] > 0 then
            paths[first] = best_paths(pending[first])
        end
    end
    return paths[n] or {}
end


-- 树状候选 ----------------------------------------------------------------
-- nova_tree 属性：每块一行，`固定\t起\t止\t键\t文字\t备选...`，起止是段内字节偏移。
-- nova_pins 属性：每个固定段一行，`起:止:键:文字`。

local MAX_BLOCK_SYLLABLES = 3  -- 词库有「我很喜欢」这样的短语，块太长就没有东西可选
local ALTS_PER_BLOCK = 3
local MAX_LABELS = 9

local function char_sub(text, first, last)
    local from = utf8.offset(text, first)
    local to = utf8.offset(text, last + 1)
    if not from or not to then return nil end
    return text:sub(from, to - 1)
end

-- 单独解码 tokens[first..last]，优先用翻译器的整句（带语法模型）。
local function decode(env, tokens, first, last)
    local key = table.concat(tokens, "", first, last)
    local want = last - first + 1
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        for _ = 1, 20 do
            local cand = nxt(this)
            if not cand then break end
            if cand._end == #key and utf8.len(cand.text) == want then
                return cand.text
            end
        end
    end
    local sub = {}
    for i = first, last do sub[#sub + 1] = tokens[i] end
    for _, path in ipairs(sentences(env, sub)) do
        if utf8.len(path[1]) == want then return path[1] end
    end
    return nil
end

-- 把 tokens[first..last] 的文字切成词块，取词库里最长的词。
local function split_blocks(env, tokens, first, last, text, blocks)
    local i = first
    while i <= last do
        local by_length = words_from(env, tokens, i)
        local length = 1
        for try = math.min(MAX_BLOCK_SYLLABLES, last - i + 1), 2, -1 do
            local piece = char_sub(text, i - first + 1, i - first + try)
            for _, word in ipairs(by_length[try] or {}) do
                if word[1] == piece then length = try; break end
            end
            if length > 1 then break end
        end
        local piece = char_sub(text, i - first + 1, i - first + length)
        local alts = {}
        for _, word in ipairs(by_length[length] or {}) do
            if word[1] ~= piece and utf8.len(word[1]) == length then
                alts[#alts + 1] = word[1]
                if #alts >= ALTS_PER_BLOCK then break end
            end
        end
        blocks[#blocks + 1] = { pinned = false, first = i, last = i + length - 1, text = piece, alts = alts }
        i = i + length
    end
end

local function parse_pins(env, tokens, offsets, input)
    local value = env.engine.context:get_property("nova_pins") or ""
    local start_at, end_at = {}, {}
    for i = 1, #tokens do
        start_at[offsets[i]] = i
        end_at[offsets[i] + #tokens[i]] = i
    end
    local pins = {}
    for from, to, key, text in value:gmatch("(%d+):(%d+):([^:]*):([^\n]*)") do
        from, to = tonumber(from), tonumber(to)
        local i, j = start_at[from], end_at[to]
        if i and j and input:sub(from + 1, to) == key and utf8.len(text) == j - i + 1 then
            pins[i] = { last = j, text = text }
        end
    end
    return pins
end

local function build_blocks(env, tokens, pins, default_text)
    local blocks, n, i = {}, #tokens, 1
    local has_pin = next(pins) ~= nil
    while i <= n do
        if pins[i] then
            blocks[#blocks + 1] = { pinned = true, first = i, last = pins[i].last, text = pins[i].text, alts = {} }
            i = pins[i].last + 1
        else
            local stop = i
            while stop < n and not pins[stop + 1] do stop = stop + 1 end
            local text = has_pin and decode(env, tokens, i, stop) or default_text
            if not text then return nil end
            split_blocks(env, tokens, i, stop, text, blocks)
            i = stop + 1
        end
    end
    return blocks
end

local function serialize(blocks, tokens, offsets)
    local lines, labels = {}, 0
    for _, block in ipairs(blocks) do
        local from = offsets[block.first]
        local to = offsets[block.last] + #tokens[block.last]
        local fields = { block.pinned and "1" or "0", tostring(from), tostring(to),
                         table.concat(tokens, "", block.first, block.last), block.text }
        for _, alt in ipairs(block.alts) do
            if labels < MAX_LABELS then
                labels = labels + 1
                fields[#fields + 1] = alt
            end
        end
        lines[#lines + 1] = table.concat(fields, "\t")
    end
    return table.concat(lines, "\n")
end

local function top_text(blocks)
    local parts = {}
    for _, block in ipairs(blocks) do parts[#parts + 1] = block.text end
    return table.concat(parts)
end

local function token_offsets(tokens)
    local offsets, at = {}, 0
    for i, token in ipairs(tokens) do
        offsets[i] = at
        at = at + #token
    end
    return offsets
end

local function init(env)
    env.translator = Component.Translator(env.engine, "", "script_translator@translator")
    env.cache, env.cache_size = {}, 0
    env.word_penalty = env.engine.schema.config:get_double("nova_sentences/word_penalty") or 0.0
    env.tree_enabled = env.engine.schema.config:get_bool("nova_tree/enabled") or false
    env.tree_debug = env.engine.schema.config:get_bool("nova_tree/debug") or false
end

local function func(input, env)
    local composition = env.engine.context.composition
    local seg = not composition:empty() and composition:back() or nil
    local tokens = seg and syllables(env.engine.context.input:sub(seg._start + 1, seg._end))
    local context = env.engine.context
    local first = true
    local pinned = false
    for cand in input:iter() do
        local shown = cand
        if first and env.tree_enabled then
            local tree = ""
            if tokens and #tokens >= 2 then
                local offsets = token_offsets(tokens)
                local pins = parse_pins(env, tokens, offsets, context.input:sub(seg._start + 1, seg._end))
                local default_text = utf8.len(cand.text) == #tokens and cand.text or nil
                local blocks = (next(pins) or default_text) and build_blocks(env, tokens, pins, default_text)
                if blocks then
                    tree = serialize(blocks, tokens, offsets)
                    pinned = next(pins) ~= nil
                    if pinned or env.tree_debug then
                        shown = Candidate("sentence", seg._start, seg._end, top_text(blocks),
                                          env.tree_debug and tree or "")
                        shown.preedit = cand.preedit
                    end
                end
            end
            context:set_property("nova_tree", tree)
        end
        yield(shown)
        -- 固定之后只剩这一条整句，别的候选和固定段无关。
        if pinned then break end
        if first then
            first = false
            if tokens and #tokens >= 2 then
                local added = 0
                for _, path in ipairs(sentences(env, tokens)) do
                    -- 词库里有多于音节数的词条（喜欢你），它们不是这串按键的整句。
                    if path[1] ~= cand.text and utf8.len(path[1]) == #tokens then
                        local extra = Candidate("sentence", seg._start, seg._end, path[1], "")
                        extra.preedit = cand.preedit
                        yield(extra)
                        added = added + 1
                        if added >= EXTRA then break end
                    end
                end
            end
        end
    end
end

return { init = init, func = func }
