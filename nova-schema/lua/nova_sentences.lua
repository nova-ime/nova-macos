-- nova_sentences -- 在首选整句后面补多条不同的整句。
--
-- script_translator 只给一条整句，后面都是开头的词。这里对每个音节位置查词，
-- 用词频做 beam search，得到几条完整读法。首选仍是翻译器（带语法模型）的结果。

local MAX_WORD_SYLLABLES = 6   -- 一次查询覆盖的最长词
local WORDS_PER_SPAN = 6       -- 每段保留的词数
local BEAM = 8                 -- 每个位置保留的路径数
local EXTRA = 5                -- 补几条整句
local CACHE_LIMIT = 2000

-- 返回完整音节和结尾没打完的单个字母。没打完的字母不参与解码，词块也就不会每敲一键变一次。
local function syllables(input)
    local tokens, pos = {}, 1
    while pos <= #input do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos)
        if not token then
            local pending = input:match("^[a-z]$", pos)
            return pending and tokens or nil, pending or ""
        end
        tokens[#tokens + 1] = token
        pos = pos + #token
    end
    return tokens, ""
end

-- 翻译器给的 quality 不只看查询串：librime 用整个输入框的长度做分母
-- （script_translator.cc 里 end_of_input = context->input().length()，quality 加上 quality_len / 它）。
-- 同一段查询，输入框多打一个字母，分数的基数就变了。所以缓存的键要带上输入框长度，
-- 不然整句解码会把不同时刻查到的分数加在一起，结果取决于之前缓存了什么。
local function cache_key(env, key)
    return #env.engine.context.input .. ":" .. key
end

-- 从 tokens[first] 开始的所有词，返回 { [音节数] = { {text, score}, ... } }。
-- 缓存按输入串共用，所以这里不能存绝对位置。
local function words_from(env, tokens, first)
    local last = math.min(#tokens, first + MAX_WORD_SYLLABLES - 1)
    local key = table.concat(tokens, "", first, last)
    local slot = cache_key(env, key)
    local cached = env.cache[slot]
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
        env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
    end
    env.cache[slot] = by_end
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

-- prefix 不为空时只留和它一致的路径：开头这几个字固定，词可以从它们跨到后面（显 + 示器）。
local function sentences(env, tokens, prefix)
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
                        local text = path[1] .. word[1]
                        if not prefix or prefix:sub(1, #text) == text or text:sub(1, #prefix) == prefix then
                            bucket[#bucket + 1] = { text, path[2] + word[2] - env.word_penalty }
                        end
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
-- nova_tree 属性：每块一行，`标记\t起\t止\t键\t文字\t备选...`，起止是段内字节偏移。
--   标记末尾的 a数字 是这块已经稳定了几个音节，见 frozen_lines。
--   标记：首字符 1 表示用户选过，0 表示没有；含 f 是焦点块；含 c 是整句解码选了词频较低的词；
--   含 o 是没有焦点时直接显示备选的不确定块，数字键从左到右连续编号；含 u 是解码器拿不准（面板标橙）。
--   文字：`文字\31比例`；备选：`文字\31比例\31止[\31起]`，长度可以和块不同；带起点的是只换光标处
--   一个字的单字备选（起点在块中间）。
--   比例是在同段候选里占的词频比例，不是真实概率，可以为空。
-- nova_pins 属性：每个固定段一行，`起:止:键:h|s:文字`。h 是用户选的；s 是选词时冻结的前文，
--   这样改一处不会让前面的词重新解码；后面的词跟着新选的字重新解码。
-- nova_pins_end 属性：选词时的输入长度，见 parse_pins。
-- nova_open_from 属性：`起点:输入`，刚选的词在段内的起点。它后面的块不冻结，见 frozen_lines。
-- nova_cursor 属性：原始字母光标在整个输入里的位置，空表示在末尾。光标所在的块是焦点，
--   在末尾时没有焦点。Rime 自己的光标始终在末尾，见 nova_tree_keys。

local MAX_BLOCK_SYLLABLES = 3  -- 词库有「我很喜欢」这样的短语，块太长就没有东西可选
local MAX_ALTS = 6
local MAX_SAME_LENGTH_ALTS = 4 -- 给别的长度留位置，切分错了才改得了
local OVERVIEW_ALTS = 2        -- 没有焦点时每个不确定块显示几个备选
local MAX_LABELS = 9
local CONFIDENT_SHARE = 80     -- 比例低于这个值算词频上没把握（冻结和备选用，不再决定颜色）
-- 换几个上下文窗口（块前后各取几个音节）单独解码，至少这么多个窗口在这块的位置解出别的词，
-- 就算解码器拿不准，面板标橙。评测里比按词频比例标准：标出的块少四成，真错的比例翻倍。
local UNCERTAIN_WINDOWS = 2
local WINDOWS = { { 2, 2 }, { 1, 1 }, { 0, 2 }, { 2, 0 }, { 0, 0 }, { 3, 3 } }

local function char_sub(text, first, last)
    local from = utf8.offset(text, first)
    local to = utf8.offset(text, last + 1)
    if not from or not to then return nil end
    return text:sub(from, to - 1)
end

local function offsets_end(tokens, k)
    local at = 0
    for i = 1, k do at = at + #tokens[i] end
    return at
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

-- 解码 tokens[first..last]，开头必须是 prefix（前面固定段的字），返回 prefix 后面的部分。
-- 改了前面的字，后面要跟着它重新组词：只解后面这段看不到它，整句首选又没带上它。
local function decode_after(env, tokens, first, last, prefix)
    local key = table.concat(tokens, "", first, last)
    local want = last - first + 1
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        for _ = 1, 100 do
            local cand = nxt(this)
            if not cand then break end
            if cand._end == #key and utf8.len(cand.text) == want and cand.text:sub(1, #prefix) == prefix then
                return cand.text:sub(#prefix + 1)
            end
        end
    end
    local sub = {}
    for i = first, last do sub[#sub + 1] = tokens[i] end
    for _, path in ipairs(sentences(env, sub, prefix)) do
        if utf8.len(path[1]) == want and path[1]:sub(1, #prefix) == prefix then
            return path[1]:sub(#prefix + 1)
        end
    end
    return nil
end

-- quality 是一个随查询变化的底数加归一化词频，同一段候选的底数相同。
-- 这里减掉这段里最低的 quality，近似得到词频。只有两三个同音词时会偏向首位。
local function span_weights(env, key, want)
    local slot = cache_key(env, key)
    local cached = env.weights[slot]
    if cached then return cached end
    local top, count, lowest = {}, 0, math.huge
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        for _ = 1, 100 do
            local cand = nxt(this)
            if not cand then break end
            if cand._end == #key and cand.type ~= "sentence" and utf8.len(cand.text) == want then
                lowest = math.min(lowest, cand.quality)
                if count < WORDS_PER_SPAN then
                    top[cand.text] = cand.quality
                    count = count + 1
                end
            end
        end
    end
    local weights = {}
    for text, quality in pairs(top) do weights[text] = quality - lowest end
    env.weights[slot] = weights
    return weights
end

-- text 占这组候选词频的比例（0-100），不在里面时返回 nil。
local function share_of(weights, text)
    local own = weights[text]
    if not own then return nil end
    local total = 0
    for _, weight in pairs(weights) do total = total + weight end
    if total <= 0 then return nil end
    return math.floor(own * 100 / total + 0.5)
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
        blocks[#blocks + 1] = { pinned = false, first = i, last = i + length - 1, text = piece }
        i = i + length
    end
end

-- extra 是自动冻结的块，写在用户的固定段前面，同一位置以用户的为准。
local function parse_pins(env, tokens, offsets, input, extra)
    local value = (extra or "") .. (env.engine.context:get_property("nova_pins") or "")
    local start_at, end_at, aux_end_at = {}, {}, {}
    for i = 1, #tokens do
        start_at[offsets[i]] = i
        end_at[offsets[i] + #tokens[i]] = i
        -- 选词后接着打的大写辅助码并进最后一个音节（hk → hkK），用户选的段终点落在辅助码前面。
        for at = offsets[i] + 2, offsets[i] + #tokens[i] - 1 do aux_end_at[at] = i end
    end
    local pins = {}
    -- 选词时的最后一块在继续打字后要能和新字母组词，不再冻结。
    local open_end = tonumber(env.engine.context:get_property("nova_pins_end") or "")
    for from, to, key, kind, text in value:gmatch("(%d+):(%d+):([^:]*):([hs]):([^\n]*)") do
        from, to = tonumber(from), tonumber(to)
        local i, j = start_at[from], end_at[to]
        -- 用户选好的字不因后补的辅助码作废，前提是辅助码和它对得上（货号 + K）；
        -- 对不上（选了好又补 K）说明用户要换字，和自动冻结的段一样按辅助码重新筛选。
        if not j and kind == "h" and i and aux_end_at[to] then
            local k = aux_end_at[to]
            for _, word in ipairs(words_from(env, tokens, i)[k - i + 1] or {}) do
                if word[1] == text then j = k; break end
            end
        end
        local reopened = kind == "s" and to == open_end and #input > open_end
        if i and j and not reopened and input:sub(from + 1, to) == key and utf8.len(text) == j - i + 1 then
            pins[i] = { last = j, text = text, chosen = kind == "h" }
        end
    end
    return pins
end

-- 解码器整句的分词，换算成音节下标 { {first, last}, ... }。不是整句（整串是词库里的一个词）时整串算一块。
local function decoder_spans(cand, tokens)
    if utf8.len(cand.text) ~= #tokens then return nil end
    local ok, sentence = pcall(function() return cand:get_genuine():to_sentence() end)
    if not (ok and sentence) then return { { 1, #tokens } } end
    local lengths = sentence.word_lengths
    if type(lengths) ~= "table" or #lengths == 0 then return nil end
    local spans, pos, k = {}, 0, 0
    for _, length in ipairs(lengths) do
        pos = pos + length
        local start = k + 1
        while k < #tokens and offsets_end(tokens, k + 1) <= pos do k = k + 1 end
        if k < start then return nil end
        spans[#spans + 1] = { start, k }
    end
    if k ~= #tokens then return nil end
    return spans
end

-- 词表（jieba 词典的两字以上词条和词频）：解码器的词库里有很多短语（我再也不、变成了），
-- 三字以上的词不在词表里时，在词内部按词频重新切，成语在词表里所以保持完整。
-- 整个词表存成一个按字节排好序的字符串（`词\t词频\n`），二分查找。
-- 不用 table：几十万条的表会让每次垃圾回收都扫一遍，打字明显变慢。
local lexicon_data, lexicon_total = nil, 0

local function bytes_less(a, b)
    for i = 1, math.min(#a, #b) do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then return x < y end
    end
    return #a < #b
end

local function lexicon_count(word)
    local data = lexicon_data
    if not data then return nil end
    local lo, hi = 1, #data + 1 -- 行首的范围 [lo, hi)
    while lo < hi do
        local mid = (lo + hi) // 2
        local start = lo
        if mid > lo then
            start = data:find("\n", mid - 1, true) + 1
            if start >= hi then start = lo end
        end
        local tab = data:find("\t", start, true)
        local key = data:sub(start, tab - 1)
        local line_end = data:find("\n", tab, true)
        if key == word then return tonumber(data:sub(tab + 1, line_end - 1)) end
        if bytes_less(key, word) then lo = line_end + 1 else hi = start end
    end
    return nil
end

local function load_lexicon()
    if lexicon_data then return end
    local f = io.open(rime_api.get_user_data_dir() .. "/nova_lexicon.txt", "r")
    if not f then lexicon_data = false; return end
    lexicon_data = f:read("a")
    f:close()
    lexicon_total = tonumber(lexicon_data:match("^#total\t(%d+)\n")) or 0
    if lexicon_total <= 0 then lexicon_data = false end
end

-- 返回 piece 的切法（字数列表），不需要切时返回 nil。
local function lexicon_split(piece)
    local n = utf8.len(piece)
    if n < 3 or not lexicon_data or lexicon_count(piece) then return nil end
    local chars = {}
    for _, code in utf8.codes(piece) do chars[#chars + 1] = utf8.char(code) end
    local log_total = math.log(lexicon_total)
    local best = { [0] = { 0, {} } }
    for i = 0, n - 1 do
        if best[i] then
            local word = ""
            for j = i + 1, n do
                word = word .. chars[j]
                local count = lexicon_count(word) or (j - i == 1 and 1 or nil)
                if count then
                    local score = best[i][1] + math.log(count) - log_total
                    if not best[j] or score > best[j][1] then
                        local lengths = { table.unpack(best[i][2]) }
                        lengths[#lengths + 1] = j - i
                        best[j] = { score, lengths }
                    end
                end
            end
        end
    end
    local lengths = best[n][2]
    local singles = 0
    for _, length in ipairs(lengths) do if length == 1 then singles = singles + 1 end end
    -- 切出来一半以上是单字（颜值爆表、小矮人）多半是词表太旧，不切。
    if #lengths < 2 or singles * 2 > n then return nil end
    return lengths
end

-- 按解码器的分词切 tokens[first..last]，跨过边界的词在边界处截断；超长的词再细分。
local function split_by_decoder(env, tokens, first, last, text, spans, blocks)
    for _, span in ipairs(spans) do
        local a, b = math.max(span[1], first), math.min(span[2], last)
        if a <= b then
            local piece = char_sub(text, a - first + 1, b - first + 1)
            local lengths = lexicon_split(piece)
            if lengths then
                for _, length in ipairs(lengths) do
                    blocks[#blocks + 1] = { pinned = false, first = a, last = a + length - 1,
                                            text = char_sub(piece, 1, length) }
                    piece = char_sub(piece, length + 1, utf8.len(piece)) or ""
                    a = a + length
                end
            elseif b - a + 1 > MAX_WORD_SYLLABLES then
                split_blocks(env, tokens, a, b, piece, blocks)
            else
                blocks[#blocks + 1] = { pinned = false, first = a, last = b, text = piece }
            end
        end
    end
end

local function build_blocks(env, tokens, pins, default_text, spans)
    local blocks, n, i = {}, #tokens, 1
    local has_pin = next(pins) ~= nil
    local before -- 紧挨在前面的固定段
    while i <= n do
        if pins[i] then
            blocks[#blocks + 1] = { pinned = pins[i].chosen, first = i, last = pins[i].last, text = pins[i].text }
            before = { first = i, text = pins[i].text }
            i = pins[i].last + 1
        else
            local stop = i
            while stop < n and not pins[stop + 1] do stop = stop + 1 end
            -- 优先取整句首选里对应的字，它带着前后文；首选字数对不上音节时（词库里的「喜欢你」）
            -- 才单独解码这一段。首选和前面的固定段对不上时（用户改了那里的字），
            -- 带着固定段一起解码，后面的字才能跟它组词。
            local text, from_default
            if default_text and not (before and char_sub(default_text, before.first, i - 1) ~= before.text) then
                text = char_sub(default_text, i, stop)
                from_default = true
            elseif before then
                text = decode_after(env, tokens, before.first, stop, before.text)
            end
            text = text or decode(env, tokens, i, stop)
            if not text then return nil end
            before = nil
            if from_default and spans then
                split_by_decoder(env, tokens, i, stop, text, spans, blocks)
            else
                split_blocks(env, tokens, i, stop, text, blocks)
            end
            i = stop + 1
        end
    end
    return blocks
end

-- 焦点块的备选：先放同样长度的词，再每种长度放一个，用来重新切分。
-- 光标停在多字词里的某个字上时，先列这个字的同音单字：只换这一个字，词里其他字不动。
-- 备选带上起点，和块的起点不同，nova_tree_keys 据此只固定这个字。
local MAX_CHAR_ALTS = 4

local function char_alternatives(env, tokens, offsets, block, k, result)
    local current = char_sub(block.text, k - block.first + 1, k - block.first + 1)
    local weights = span_weights(env, tokens[k], 1)
    for _, word in ipairs(words_from(env, tokens, k)[1] or {}) do
        if #result >= MAX_CHAR_ALTS then break end
        if word[1] ~= current and utf8.len(word[1]) == 1 then
            result[#result + 1] = { text = word[1], from = offsets[k], to = offsets[k] + #tokens[k],
                                    share = share_of(weights, word[1]) }
        end
    end
end

local function alternatives(env, tokens, offsets, block, cursor_syllable)
    local result, seen = {}, { [block.text] = true }
    if cursor_syllable and block.last > block.first then
        char_alternatives(env, tokens, offsets, block, cursor_syllable, result)
    end
    local by_length = words_from(env, tokens, block.first)
    local function add(length, limit)
        local last = block.first + length - 1
        if last > #tokens then return end
        local key = table.concat(tokens, "", block.first, last)
        local added = 0
        for _, word in ipairs(by_length[length] or {}) do
            if added >= limit or #result >= MAX_ALTS then return end
            if not seen[word[1]] and utf8.len(word[1]) == length then
                seen[word[1]] = true
                result[#result + 1] = { text = word[1], to = offsets[last] + #tokens[last],
                                        share = share_of(span_weights(env, key, length), word[1]) }
                added = added + 1
            end
        end
    end
    local length = block.last - block.first + 1
    add(length, MAX_SAME_LENGTH_ALTS)
    for other = length - 1, 1, -1 do add(other, 1) end
    for other = length + 1, MAX_BLOCK_SYLLABLES do add(other, 1) end
    add(length, MAX_ALTS)
    return result
end

-- key 这段编码下长度为 want 的词，按翻译器的顺序，最多 limit 个。翻页时用，比 words_from 深。
local function span_words(env, key, want, limit)
    local words = {}
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        for _ = 1, limit * 3 do
            local cand = nxt(this)
            if not cand or #words >= limit then break end
            if cand._end == #key and cand.type ~= "sentence" and utf8.len(cand.text) == want then
                words[#words + 1] = cand.text
            end
        end
    end
    return words
end

local PAGE_LIMIT = 36  -- 翻页时最多列多少个备选

-- 焦点块的全部备选：第一页同原来（单字、同长度、别的长度），后面接更多的单字和同长度词。
local function all_alternatives(env, tokens, offsets, block, cursor_syllable)
    local result = alternatives(env, tokens, offsets, block, cursor_syllable)
    local seen = { [block.text] = true }
    for _, alt in ipairs(result) do seen[alt.text .. ":" .. (alt.from or "")] = true end
    local function more(first, last, from, list)
        for _, text in ipairs(list) do
            if #result >= PAGE_LIMIT then return end
            local id = text .. ":" .. (from or "")
            if not seen[id] and text ~= block.text then
                seen[id] = true
                result[#result + 1] = { text = text, from = from, to = offsets[last] + #tokens[last] }
            end
        end
    end
    local length = block.last - block.first + 1
    if cursor_syllable and length > 1 then
        local current = char_sub(block.text, cursor_syllable - block.first + 1, cursor_syllable - block.first + 1)
        local chars = {}
        for _, text in ipairs(span_words(env, tokens[cursor_syllable], 1, PAGE_LIMIT)) do
            if text ~= current then chars[#chars + 1] = text end
        end
        more(cursor_syllable, cursor_syllable, offsets[cursor_syllable], chars)
    end
    more(block.first, block.last, nil, span_words(env, table.concat(tokens, "", block.first, block.last), length, PAGE_LIMIT))
    return result
end

-- 光标前一个字母所在的块和音节（光标在开头时取第一个字母）。没有焦点或在没打完的字母上时返回 nil。
local function focused_index(env, blocks, offsets, tokens, seg)
    local cursor = tonumber(env.engine.context:get_property("nova_cursor") or "")
    if not cursor then return nil end
    cursor = math.max(cursor - seg._start - 1, 0)
    for i, block in ipairs(blocks) do
        for k = block.first, block.last do
            if cursor >= offsets[k] and cursor < offsets[k] + #tokens[k] then return i, k end
        end
    end
    return nil
end

local function field(...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = parts[i] == nil and "" or tostring(parts[i]) end
    return table.concat(parts, "\31", 1, select("#", ...))
end

-- 有几个上下文窗口在这块的位置解出了别的词。窗口就是整句时跳过（和整句解码一样）。
local function window_disagreements(env, block, tokens)
    local disagree = 0
    for _, w in ipairs(WINDOWS) do
        local a, b = math.max(1, block.first - w[1]), math.min(#tokens, block.last + w[2])
        if not (a == 1 and b == #tokens) then
            local slot = cache_key(env, table.concat(tokens, "", a, b))
            local text = env.decoded[slot]
            if text == nil then
                text = decode(env, tokens, a, b) or false
                env.decoded[slot] = text
            end
            if text and char_sub(text, block.first - a + 1, block.last - a + 1) ~= block.text then
                disagree = disagree + 1
            end
        end
    end
    return disagree
end

-- 块的词频比例，整句解码是否选了词频较低的词（紫），以及解码器是否拿不准（橙）。
-- 紫的块不再标橙：语法推翻了词频的地方多半是对的，评测里窗口不一致时紫块错 20%，其他块错 43%。
local function measure_block(env, block, tokens)
    local key = table.concat(tokens, "", block.first, block.last)
    local weights = span_weights(env, key, block.last - block.first + 1)
    block.key = key
    block.share = not block.pinned and share_of(weights, block.text) or nil
    -- 一两个字的词不在词频最高的几个里，多半选错了，比例记 0。
    -- 三个字的常是短语，词库里排得靠后不代表错。
    if not block.pinned and block.last - block.first < 2 and next(weights) and not weights[block.text] then
        block.share = 0
    end
    block.corrected = false
    if block.share then
        for text in pairs(weights) do
            if text ~= block.text and (share_of(weights, text) or 0) > block.share then block.corrected = true; break end
        end
    end
    block.disagree = not block.pinned and window_disagreements(env, block, tokens) or 0
    block.uncertain = not block.corrected and block.disagree >= UNCERTAIN_WINDOWS
end

-- 编号不够时，让最不确定的块先拿到，每块要么全有要么没有：橙的先，窗口不一致多的先，然后是紫的。
local function pick_overview(env, blocks, tokens, offsets)
    local uncertain = {}
    for _, block in ipairs(blocks) do
        if block.uncertain or block.corrected then
            uncertain[#uncertain + 1] = block
        end
    end
    table.sort(uncertain, function(a, b)
        if a.uncertain ~= b.uncertain then return a.uncertain end
        if a.disagree ~= b.disagree then return a.disagree > b.disagree end
        return (a.share or 100) < (b.share or 100)
    end)
    local labels = 0
    for _, block in ipairs(uncertain) do
        local alts = alternatives(env, tokens, offsets, block)
        for i = #alts, OVERVIEW_ALTS + 1, -1 do alts[i] = nil end
        if #alts > 0 and labels + #alts <= MAX_LABELS then
            block.overview = alts
            labels = labels + #alts
        end
    end
end

-- ↓/↑ 换词中时返回开始换词时记下的备选列表和当前序号（0 是原来的词），否则返回 nil。
local function cycling_list(env)
    local context = env.engine.context
    local index, signature = (context:get_property("nova_cycle") or ""):match("^(%d+):(.*)$")
    local cursor = tonumber(context:get_property("nova_cursor") or "") or #context.input
    if signature ~= cursor .. ":" .. context.input then return nil end
    local list = {}
    for from, to, text in (context:get_property("nova_cycle_alts") or ""):gmatch("(%d+):(%d+):([^\n]*)\n") do
        list[#list + 1] = { from = tonumber(from), to = tonumber(to), text = text }
    end
    return list, tonumber(index)
end

-- nova_alt_page 属性：`页码:光标:输入`，光标或输入变了就是第一页。见 nova_tree_keys 的 turn_page。
local function page_of(env)
    local context = env.engine.context
    local page, signature = (context:get_property("nova_alt_page") or ""):match("^(%d+):(.*)$")
    local cursor = tonumber(context:get_property("nova_cursor") or "") or #context.input
    if signature ~= cursor .. ":" .. context.input then return 0 end
    return tonumber(page) or 0
end

local function serialize(env, blocks, tokens, offsets, focus, ages, cursor_syllable)
    for _, block in ipairs(blocks) do measure_block(env, block, tokens) end
    pick_overview(env, blocks, tokens, offsets)
    local lines = {}
    for i, block in ipairs(blocks) do
        local flags = block.pinned and "1" or "0"
        if i == focus then flags = flags .. "f" end
        if block.corrected then flags = flags .. "c" end
        if block.overview then flags = flags .. "o" end
        if block.uncertain then flags = flags .. "u" end
        local from, to = offsets[block.first], offsets[block.last] + #tokens[block.last]
        flags = flags .. "a" .. (ages[from .. ":" .. to .. ":" .. block.text] or 0)
        local fields = { flags, tostring(offsets[block.first]), tostring(offsets[block.last] + #tokens[block.last]),
                         block.key, field(block.text, block.share) }
        local alts = block.overview or {}
        if i == focus then
            -- 焦点块的备选按页给出，每页 MAX_ALTS 个；页码越界时收到最后一页。
            -- ↓/↑ 换词时（nova_cycle 对得上）显示开始换词时记下的列表，当前用的那项高亮，页码跟着它走。
            local all, current = cycling_list(env)
            if not all then
                all = all_alternatives(env, tokens, offsets, block, cursor_syllable)
                local lines = {}
                for _, alt in ipairs(all) do
                    lines[#lines + 1] = string.format("%d:%d:%s\n", alt.from or from, alt.to, alt.text)
                end
                env.engine.context:set_property("nova_focus_alts", table.concat(lines))
            end
            local pages = math.max(1, math.ceil(#all / MAX_ALTS))
            local page = current and current > 0 and math.floor((current - 1) / MAX_ALTS) or math.min(page_of(env), pages - 1)
            alts = {}
            for j = page * MAX_ALTS + 1, math.min(#all, (page + 1) * MAX_ALTS) do
                local alt = all[j]
                -- 都带上起点：换词后焦点块可能变了，数字键要按备选自己的范围固定。
                alts[#alts + 1] = { text = alt.text, share = alt.share, to = alt.to, from = alt.from or from }
            end
            fields[1] = flags
            if pages > 1 then fields[1] = fields[1] .. "p" .. (page + 1) .. "/" .. pages end
            if current and current > 0 then fields[1] = fields[1] .. "h" .. ((current - 1) % MAX_ALTS + 1) end
        end
        for _, alt in ipairs(alts) do
            fields[#fields + 1] = alt.from and field(alt.text, alt.share, alt.to, alt.from) or field(alt.text, alt.share, alt.to)
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

-- 打过去的词不再跟着后面的字变。上一次的树里，除了最后一块，多字词满足其一就冻结：
--   有把握（占比够高），或者之后又打了 STABLE_SYLLABLES 个音节都没变（用户看过、认了）。
-- 单字和刚出现的没把握的词照样跟着整句解码变（无党 → 武当、无 → 武当）。
-- 输入没变时（移动焦点、选词后刷新），或者只多了一个没打完的字母，整棵树原样保留，
-- 不然同一个输入会来回跳，半个音节也会让前面的词闪一下。
local FREEZE_SHARE = 50
local STABLE_SYLLABLES = 2

-- 上一次的树：每块的字段和它已经稳定了几个音节（标记里的数字）。
local function previous_blocks(previous)
    local blocks = {}
    for line in previous:gmatch("[^\n]+") do
        local fields = {}
        for value in line:gmatch("[^\t]+") do fields[#fields + 1] = value end
        if #fields >= 5 then
            local text, share = fields[5]:match("^([^\31]*)\31?(%d*)")
            blocks[#blocks + 1] = { from = fields[2], to = fields[3], key = fields[4], text = text,
                                    share = tonumber(share) or 0, age = tonumber(fields[1]:match("a(%d+)")) or 0 }
        end
    end
    return blocks
end

-- open_from 是刚选的词的起点：只冻结它前面的块，后面的跟着新选的字重新解码。
-- groups 是上一次的树里解码器每个词的字节范围（`起:止` 每行一个）。一个词按词表切成几块时，
-- 最后那个词的几块都算「最后一块」，不冻结：这个词还没打完，后面的字可能把它整个改掉（一边我 → 以便我）。
local function last_group_from(previous, groups)
    local last = previous[#previous]
    if not (last and groups) then return nil end
    for from, to in groups:gmatch("(%d+):(%d+)") do
        if to == last.to then return tonumber(from) end
    end
    return nil
end

local function frozen_lines(previous, same_input, open_from, groups)
    local lines = {}
    local open_group = last_group_from(previous, groups)
    for i, block in ipairs(previous) do
        local settled = i < #previous and utf8.len(block.text) >= 2
            and not (open_group and tonumber(block.from) >= open_group)
            and (block.share >= FREEZE_SHARE or block.age >= STABLE_SYLLABLES)
        local opened = open_from and tonumber(block.to) > open_from
        if (same_input or settled) and not opened then
            lines[#lines + 1] = string.format("%s:%s:%s:s:%s\n", block.from, block.to, block.key, block.text)
        end
    end
    return table.concat(lines)
end

-- 新树里每块稳定了几个音节：和上一次同位置同文字的块接着数，打完一个音节加一。
local function block_ages(previous, step)
    local ages = {}
    for _, block in ipairs(previous) do
        ages[block.from .. ":" .. block.to .. ":" .. block.text] = block.age + step
    end
    return ages
end

-- 打大写辅助码就是选字，和数字键选词一样：辅助码所在的整个词当场固定成用户选的（货号 + K）。
-- 之后补打或删掉辅助码，键对不上，这个选择作废，按新的辅助码重新筛选后再固定。
local function choose_by_aux(context, blocks, tokens, offsets)
    local chosen, starts = {}, {}
    for _, block in ipairs(blocks) do
        local key = table.concat(tokens, "", block.first, block.last)
        if not block.pinned and key:find("%u") then
            block.pinned = true
            local from = offsets[block.first]
            starts[tostring(from)] = true
            chosen[#chosen + 1] = string.format("%d:%d:%s:h:%s\n", from, from + #key, key, block.text)
        end
    end
    if #chosen == 0 then return end
    -- 同一起点的旧选择换成新的，免得属性越积越长。
    local kept = {}
    for line, from in (context:get_property("nova_pins") or ""):gmatch("((%d+):[^\n]*\n)") do
        if not starts[from] then kept[#kept + 1] = line end
    end
    context:set_property("nova_pins", table.concat(kept) .. table.concat(chosen))
end

-- 返回 nova_tree 属性，以及要替换首选时的新候选。
local function build_tree(env, tokens, seg, cand, stop)
    local context = env.engine.context
    local offsets = token_offsets(tokens)
    local same_input = context:get_property("nova_tree_input") == context.input
    local previous = previous_blocks(context:get_property("nova_tree") or "")
    -- nova_open_from：`起点:输入`，nova_tree_keys 选词时写，输入变了就失效。
    local open_from, open_input = (context:get_property("nova_open_from") or ""):match("^(%d+):(.*)$")
    open_from = open_input == context.input and tonumber(open_from) or nil
    local frozen = frozen_lines(previous, same_input or stop ~= seg._end, open_from,
                                context:get_property("nova_tree_groups"))
    local pins = parse_pins(env, tokens, offsets, context.input:sub(seg._start + 1, seg._end), frozen)
    local default_text = utf8.len(cand.text) == #tokens and cand.text or nil
    local spans = default_text and decoder_spans(cand, tokens)
    local blocks = build_blocks(env, tokens, pins, default_text, spans)
    if not blocks then return nil end
    -- 树原样保留时（输入没变、只多了半个音节）分组也不变。
    if not same_input and stop == seg._end then
        local groups = {}
        for _, span in ipairs(spans or {}) do
            groups[#groups + 1] = offsets[span[1]] .. ":" .. (offsets[span[2]] + #tokens[span[2]])
        end
        context:set_property("nova_tree_groups", table.concat(groups, "\n"))
    end
    choose_by_aux(context, blocks, tokens, offsets)
    local focus, cursor_syllable = focused_index(env, blocks, offsets, tokens, seg)
    -- 没打完的字母不算，只在多了完整音节时加一。
    local grew = not same_input and stop == seg._end
    local tree = serialize(env, blocks, tokens, offsets, focus, block_ages(previous, grew and 1 or 0), cursor_syllable)
    if not (next(pins) or env.tree_debug or top_text(blocks) ~= cand.text) then return tree end
    -- 候选只覆盖完整音节，没打完的字母留在输入框里。
    local replacement = Candidate("sentence", seg._start, stop, top_text(blocks), env.tree_debug and tree or "")
    replacement.preedit = cand.preedit
    return tree, replacement
end

local function init(env)
    load_lexicon()
    env.translator = Component.Translator(env.engine, "", "script_translator@translator")
    env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
    -- contextual_suggestions 打开时，翻译器按上一次上屏的文字调整分数（poet.h 的 ContextualWeighted），
    -- 上屏后缓存里的分数就过期了，清掉。
    env.commit = env.engine.context.commit_notifier:connect(function()
        env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
    end)
    env.word_penalty = env.engine.schema.config:get_double("nova_sentences/word_penalty") or 0.0
    env.tree_enabled = env.engine.schema.config:get_bool("nova_tree/enabled") or false
    env.tree_debug = env.engine.schema.config:get_bool("nova_tree/debug") or false
end

local function func(input, env)
    local composition = env.engine.context.composition
    local seg = not composition:empty() and composition:back() or nil
    local tokens, pending
    if seg then tokens, pending = syllables(env.engine.context.input:sub(seg._start + 1, seg._end)) end
    local stop = seg and seg._end - #(pending or "")
    local context = env.engine.context
    local first = true
    local pinned = false
    for cand in input:iter() do
        local shown = cand
        if first and env.tree_enabled then
            local tree = ""
            if tokens and #tokens >= 1 then
                -- 树出错时退回普通列表，不能让候选消失。
                local ok, result, replacement = pcall(build_tree, env, tokens, seg, cand, stop)
                if ok and result then
                    tree = result
                    pinned = next(parse_pins(env, tokens, token_offsets(tokens), context.input:sub(seg._start + 1, seg._end))) ~= nil
                    shown = replacement or cand
                elseif not ok then
                    log.error("nova_sentences: " .. tostring(result))
                end
            end
            -- 只打了一个字母：还没有词块，面板不显示，输入框里也只留这个字母。
            if tokens and #tokens == 0 then
                tree = "\n"
                shown = Candidate("raw", seg._start, seg._end, pending, "")
            end
            context:set_property("nova_tree", tree)
            context:set_property("nova_tree_input", context.input)
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
                        local extra = Candidate("sentence", seg._start, stop, path[1], "")
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

local function fini(env)
    if env.commit then env.commit:disconnect() end
end

return { init = init, func = func, fini = fini }
