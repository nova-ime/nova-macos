-- nova_sentences -- 在首选整句后面补多条不同的整句。
--
-- script_translator 只给一条整句，后面都是开头的词。这里对每个音节位置查词，
-- 用词频做 beam search，得到几条完整读法。首选仍是翻译器（带语法模型）的结果。

local bounds = require("nova_bounds")

local MAX_WORD_SYLLABLES = 6   -- 一次查询覆盖的最长词
local WORDS_PER_SPAN = 6       -- 每段保留的词数
local BEAM = 8                 -- 每个位置保留的路径数
local EXTRA = 5                -- 补几条整句
local CACHE_LIMIT = 2000
-- 全拼简拼的音节写成「声母键 + 通配符」两个字符（nVhV），见 nova.schema.yaml 的 abbrev 规则和 nova_quanpin。
-- 它占的位置和完整音节一样宽，后面不跟辅助码。
local WILDCARD = "V"

-- 这段编码里有没有辅助码。简拼音节里的通配符是大写字母，但不是辅助码。
local function has_aux(code)
    local pos = 1
    while pos <= #code do
        local token = code:match("^[a-z][a-z][A-Z]?[A-Z]?", pos) or code:match("^[a-z]" .. WILDCARD, pos)
        if token then
            if #token > 2 then return true end
            pos = pos + #token
        elseif code:find("^%u", pos) then
            return true
        else
            pos = pos + 1
        end
    end
    return false
end

-- 返回完整音节和结尾没打完的单个字母。没打完的字母不参与解码，词块也就不会每敲一键变一次。
local function syllables(input)
    local tokens, pos = {}, 1
    while pos <= #input do
        local token = input:match("^[a-z][a-z][A-Z]?[A-Z]?", pos) or input:match("^[a-z]" .. WILDCARD, pos)
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

-- 翻译器查一段码的结果，按输入框长度现算 quality。
--
-- quality = exp(weight) + initial_quality + quality_len / 输入框长度（script_translator.cc），
-- quality_len 是这个词按正常拼写匹配的码长（table.cc 的 delta_quality_len，简拼和模糊音少记）。
-- 只有最后一项随输入框长度变，所以缓存里存去掉它的部分，用的时候按当前长度加回去：
-- 每打一个音节只需要查新出现的位置，不用把整串重查一遍。
-- quality_len 不能直接读到：第一次查时先记下 quality，等输入框长度变了再查一次，两次的差解出它。
-- 所以每段码最多查两次。翻译器给候选的顺序不随长度变（按码长、用户词、词典顺序），照存。
-- 联想补全（completion）只在码到输入框末尾时出现，字数也和音节数对不上，组句时不要。
local QUERY_LIMIT = 120  -- 用到的最深处是翻页 PAGE_LIMIT * 3 = 108；150 句实测与 300 输出一致
local RAW_LIMIT = 4000

-- { {text, end, quality, 序号, nil, 是否联想补全}, ... }，序号从 1 数，整句候选也占一个。
local function query_all(env, key)
    local list = {}
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if translation then
        local nxt, this = translation:iter()
        local seen = 0
        while seen < QUERY_LIMIT do
            local cand = nxt(this)
            if not cand then break end
            seen = seen + 1
            if cand.type ~= "sentence" then
                list[#list + 1] = { cand.text, cand._end, cand.quality, seen, nil, cand.type == "completion" }
            end
        end
    end
    return list
end

-- key 的候选：{ list = { {text, end, base, 序号, quality_len}, ... } }，base 去掉了长度项。
-- 还没解出 quality_len 时，raw.length 是第一次查询时的输入框长度，base 存的是那时的 quality。
local function raw_words(env, key)
    local length = #env.engine.context.input
    local raw = env.raw[key]
    if raw and (not raw.length or raw.length == length) then return raw end
    if raw then
        local now = {}
        for _, cand in ipairs(query_all(env, key)) do now[cand[1] .. "@" .. cand[2]] = cand[3] end
        for _, word in ipairs(raw.list) do
            local quality = now[word[1] .. "@" .. word[2]]
            local quality_len = word[2]
            if quality then
                quality_len = math.floor((quality - word[3]) / (1 / length - 1 / raw.length) + 0.5)
            end
            word[3] = word[3] - quality_len / raw.length
            word[5] = quality_len
        end
        raw.length = nil
        return raw
    end
    raw = { list = query_all(env, key), length = length }
    if env.raw_size >= RAW_LIMIT then env.raw, env.raw_size = {}, 0 end
    env.raw[key] = raw
    env.raw_size = env.raw_size + 1
    return raw
end

-- 当前输入框长度下的 quality。
local function quality_now(raw, word, length)
    return raw.length and word[3] or word[3] + word[5] / length
end

-- 从 tokens[first] 开始的所有词，返回 { [音节数] = { {text, score}, ... } }。
-- 缓存按输入串共用，所以这里不能存绝对位置。
local function words_from(env, tokens, first)
    local last = math.min(#tokens, first + MAX_WORD_SYLLABLES - 1)
    local key = table.concat(tokens, "", first, last)
    local slot = cache_key(env, key)
    local cached = env.cache[slot]
    if cached then return cached end

    local ends, offset = {}, 0
    for i = first, last do
        offset = offset + #tokens[i]
        ends[offset] = i - first + 1
    end
    local length = #env.engine.context.input
    local by_end = {}
    local raw = raw_words(env, key)
    -- 保持翻译器给的顺序：它不是严格按 quality 排的（用户词优先、同权重按词典顺序），
    -- 重排会换掉前 WORDS_PER_SPAN 个里的词。
    for _, word in ipairs(raw.list) do
        local count = ends[word[2]]
        if count and not word[6] then
            local quality = quality_now(raw, word, length)
            local out = by_end[count]
            if not out then out = {}; by_end[count] = out end
            if quality > 0 and #out < WORDS_PER_SPAN then out[#out + 1] = { word[1], math.log(quality) } end
        end
    end
    for count, out in pairs(by_end) do
        if #out == 0 then by_end[count] = nil end
    end
    if env.cache_size >= CACHE_LIMIT then
        env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
    end
    env.cache[slot] = by_end
    env.cache_size = env.cache_size + 1
    return by_end
end

local function best_paths(extensions, beam)
    table.sort(extensions, function(a, b) return a[2] > b[2] end)
    local seen, result = {}, {}
    for _, path in ipairs(extensions) do
        if not seen[path[1]] then
            seen[path[1]] = true
            result[#result + 1] = path
            if #result >= (beam or BEAM) then break end
        end
    end
    return result
end

-- prefix 不为空时只留和它一致的路径：开头这几个字固定，词可以从它们跨到后面（显 + 示器）。
local function sentences(env, tokens, prefix, beam)
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
            paths[first] = best_paths(pending[first], beam)
        end
    end
    return paths[n] or {}
end


-- 树状候选 ----------------------------------------------------------------
-- nova_tree 属性：每块一行，`标记\t起\t止\t键\t文字\t备选...`，起止是段内字节偏移。
--   标记末尾的 a数字 是这块已经稳定了几个音节（只供 nova_lm 合并人名用，不再决定冻结）。
--   标记：首字符 1 表示用户选过，0 表示没有；含 f 是焦点块；含 c 是整句解码选了词频较低的词；
--   含 o 是没有焦点时直接显示备选的不确定块，数字键从左到右连续编号；含 u 是解码器拿不准（面板标橙）；
--   含 s 是冻结的块（学到的切分，或选词时冻结的前文），nova_lm_filter 重选首选时不动它；
--   含 x 是辅助码筛完还剩几个字、列成备选等用户选的块，见 choose_by_aux；
--   含 t 是打错键后原样留下的字母块，见 tail_line。
--   a数字 后面还可以跟 p页码/总页数（焦点块的备选分页时）和 h序号（↓/↑ 换词时当前用的是这一页第几个）。
--   文字：`文字\31比例`；备选：`文字\31比例\31止[\31起]`，长度可以和块不同；带起点的是只换光标处
--   一个字的单字备选（起点在块中间）。打错键的备选再带上改好的编码：`文字\31\31止\31起\31编码[\31种类\31整句]`。
--   比例是在同段候选里占的词频比例，不是真实概率，可以为空。
-- nova_pins 属性：每个固定段一行，`起:止:键:h|s:文字`。h 是用户选的；s 是选词时冻结的前文，
--   这样改一处不会让前面的词重新解码；后面的词跟着新选的字重新解码。
-- nova_pins_end 属性：选词时的输入长度，见 parse_pins。
-- nova_open_from 属性：`起点:输入`，刚选的词在段内的起点。它后面的块不冻结，见 frozen_lines。
--   只用一次：选词后重新解码一遍就清掉，之后移动光标整棵树原样保留。
-- nova_cursor 属性：原始字母光标在整个输入里的位置，空表示在末尾。光标所在的块是焦点，
--   在末尾时没有焦点。Rime 自己的光标始终在末尾，见 nova_tree_keys。

local MAX_BLOCK_SYLLABLES = 3  -- 词库有「我很喜欢」这样的短语，块太长就没有东西可选
local MAX_ALTS = 6
local MAX_SAME_LENGTH_ALTS = 4 -- 给别的长度留位置，切分错了才改得了
local OVERVIEW_ALTS = 2        -- 没有焦点时每个不确定块显示几个备选
local MAX_LABELS = 9
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
    local length = #env.engine.context.input
    local raw = raw_words(env, key)
    for _, word in ipairs(raw.list) do
        if word[4] > 100 then break end
        if word[2] == #key and utf8.len(word[1]) == want then
            local quality = quality_now(raw, word, length)
            lowest = math.min(lowest, quality)
            if count < WORDS_PER_SPAN then
                top[word[1]] = quality
                count = count + 1
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

-- extra 是原样保留的块（学到的切分，或输入没变时的整棵树），写在用户的固定段前面，同一位置以用户的为准。
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
    for from_s, to_s, key, kind, text in value:gmatch("(%d+):(%d+):([^:]*):([hs]):([^\n]*)") do
        local from, to = tonumber(from_s), tonumber(to_s)
        local i, j = start_at[from], end_at[to]
        -- 用户选好的字不因后补的辅助码作废，前提是辅助码和它对得上（货号 + K）；
        -- 对不上（选了好又补 K）说明用户要换字，和 s 段一样按辅助码重新筛选。
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
    -- 用户目录里的优先，没有就用安装包带的（共享目录）。
    local f
    for _, dir in ipairs({ rime_api.get_user_data_dir(), rime_api.get_shared_data_dir() }) do
        f = io.open(dir .. "/nova_lexicon.txt", "r")
        if f then break end
    end
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

-- redecode 是伸缩块时让出音节的那一段（音节下标 { first, last }）：不取首选里的字，单独解码，
-- 这样词不会越过用户定的边界。
local function build_blocks(env, tokens, pins, default_text, spans, redecode)
    local blocks, n, i = {}, #tokens, 1
    local before -- 紧挨在前面的固定段
    while i <= n do
        if pins[i] then
            blocks[#blocks + 1] = { pinned = pins[i].chosen, frozen = not pins[i].chosen,
                                    first = i, last = pins[i].last, text = pins[i].text }
            before = { first = i, text = pins[i].text }
            i = pins[i].last + 1
        else
            local stop = i
            while stop < n and not pins[stop + 1] do stop = stop + 1 end
            -- 优先取整句首选里对应的字，它带着前后文；首选字数对不上音节时（词库里的「喜欢你」）
            -- 才单独解码这一段。首选和前面的固定段对不上时（用户改了那里的字），
            -- 带着固定段一起解码，后面的字才能跟它组词。
            local text, from_default
            if redecode and i <= redecode.last and stop >= redecode.first then
                text = decode(env, tokens, i, stop)
            elseif default_text and not (before and char_sub(default_text, before.first, i - 1) ~= before.text) then
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
    for _, word in ipairs(raw_words(env, key).list) do
        if word[4] > limit * 3 or #words >= limit then break end
        if word[2] == #key and utf8.len(word[1]) == want then words[#words + 1] = word[1] end
    end
    return words
end

local PAGE_LIMIT = 36  -- 翻页时最多列多少个备选

-- 焦点块的全部备选：第一页同原来（单字、同长度、别的长度），后面接更多的单字和同长度词。
local function all_alternatives(env, tokens, offsets, block, cursor_syllable)
    local result = alternatives(env, tokens, offsets, block, cursor_syllable)
    local seen = { [block.text] = true }
    for _, alt in ipairs(result) do seen[alt.text .. ":" .. (alt.from or "")] = true end
    local function more(last, from, list)
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
        more(cursor_syllable, offsets[cursor_syllable], chars)
    end
    more(block.last, nil, span_words(env, table.concat(tokens, "", block.first, block.last), length, PAGE_LIMIT))
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
    -- 学到的切法（apply_bounds）是用户定的，词频低也不算选错，不列备选。
    if block.share and not block.learned then
        for text in pairs(weights) do
            if text ~= block.text and (share_of(weights, text) or 0) > block.share then block.corrected = true; break end
        end
    end
    -- nova_lm 插件开着时由它按 GPT-2 标橙，这里的窗口解码（每块好几次整段查询）就省掉。
    block.disagree = not block.pinned and not env.lm_orange and window_disagreements(env, block, tokens) or 0
    block.uncertain = not block.corrected and not block.aux_words and block.disagree >= UNCERTAIN_WINDOWS
end

-- 编号不够时，让最不确定的块先拿到，每块要么全有要么没有：橙的先，窗口不一致多的先，然后是紫的。
local function pick_overview(env, blocks, tokens, offsets)
    -- 辅助码筛完还剩几个字的块：编号全给它，按词库顺序列出，别的块这时不给备选。
    local labels = 0
    for _, block in ipairs(blocks) do
        if block.aux_words then
            local last = block.last
            local weights = span_weights(env, block.key, last - block.first + 1)
            local alts = {}
            for _, text in ipairs(block.aux_words) do
                if labels + #alts >= MAX_LABELS then break end
                if text ~= block.text then
                    alts[#alts + 1] = { text = text, to = offsets[last] + #tokens[last], share = share_of(weights, text) }
                end
            end
            if #alts > 0 then block.overview = alts end
            labels = labels + #alts
        end
    end
    if labels > 0 then return end
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
        if block.aux_words then flags = flags .. "x" end
        if block.overview then flags = flags .. "o" end
        if block.uncertain then flags = flags .. "u" end
        if block.frozen then flags = flags .. "s" end
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
                local saved = {}
                for _, alt in ipairs(all) do
                    saved[#saved + 1] = string.format("%d:%d:%s\n", alt.from or from, alt.to, alt.text)
                end
                env.engine.context:set_property("nova_focus_alts", table.concat(saved))
            end
            local pages = math.max(1, math.ceil(#all / MAX_ALTS))
            local page = current and current > 0 and math.floor((current - 1) / MAX_ALTS) or math.min(page_of(env), pages - 1)
            alts = {}
            for j = page * MAX_ALTS + 1, math.min(#all, (page + 1) * MAX_ALTS) do
                local alt = all[j]
                -- 都带上起点：换词后焦点块可能变了，数字键要按备选自己的范围固定。
                alts[#alts + 1] = { text = alt.text, share = alt.share, to = alt.to, from = alt.from or from }
            end
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

-- 打过去的词会跟着后面的字重新解码：没有自动冻结，不管占比多高、稳定了几个音节都一样，
-- 这样前面写错的词能被后面的字改对。只有这几种不再动：
--   用户选过的块（nova_pins 里的 h）；
--   学到的切分（nova_bounds，见 apply_bounds）：上一次用上的左右两块接着保留（最后一块也是），
--   免得后面的字把它并进更长的词（报道 + 查 → 道查）；
--   输入没变时（移动焦点、选词后刷新），或者只多了一个没打完的字母，整棵树原样保留，
--   不然同一个输入会来回跳，半个音节也会让前面的词闪一下。

-- 上一次的树：每块的字段和它已经稳定了几个音节（标记里的数字，现在只供 nova_lm 合并人名用）。
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

-- 上一次 apply_bounds 用上的学到的边界（nova_bounds_used：`边界的字节偏移:左编码:右编码`）
-- 两侧的块，键是 `起:止:编码`。
local function learned_blocks(used)
    local keys = {}
    for at, left, right in (used or ""):gmatch("(%d+):(%a+):(%a+)") do
        local middle = tonumber(at)
        keys[string.format("%d:%d:%s", middle - #left, middle, left)] = true
        keys[string.format("%d:%d:%s", middle, middle + #right, right)] = true
    end
    return keys
end

-- open_from 是刚选的词的起点：它后面的块不再原样保留，跟着新选的字重新解码。
local function frozen_lines(previous, same_input, open_from, bounds_used)
    local lines = {}
    local learned = learned_blocks(bounds_used)
    for i, block in ipairs(previous) do
        local settled = learned[block.from .. ":" .. block.to .. ":" .. block.key]
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
-- 筛完还剩不止一个词时（ui + A 有十、事、史、师……）先不固定，把它们列成备选（x 标记），
-- 用户按数字键选，或者再补一个辅助码筛到只剩一个。
local function choose_by_aux(env, blocks, tokens, offsets)
    local context = env.engine.context
    local chosen, starts = {}, {}
    for _, block in ipairs(blocks) do
        local key = table.concat(tokens, "", block.first, block.last)
        local words = not block.pinned and has_aux(key) and span_words(env, key, block.last - block.first + 1, MAX_LABELS + 1)
        -- 扩展区的生僻字（hk + N 除了好还有 𡚽、㚪）不算，不然几乎每个辅助码都要再选一次。
        if words then
            local common = {}
            for _, text in ipairs(words) do
                local basic = true
                for _, code in utf8.codes(text) do
                    if code < 0x4E00 or code > 0x9FFF then basic = false; break end
                end
                if basic then common[#common + 1] = text end
            end
            words = common
        end
        if words and #words > 1 then
            block.aux_words = words
        elseif words then
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

-- 学到的边界：用户用 [ ] 伸缩过再上屏的切法（nova_bounds）。一串连着的块，编码正好是某条学过的
-- 左右两块、两头又都落在块的边界上时，换成学到的两块，标成冻结（nova_lm_filter 不再改它）。
-- 里面有用户这次选过的块就不动；带辅助码的也不动，那是用户在筛字。
-- 返回这次对上的条目，每行 `边界的字节偏移:左编码:右编码`，写进 nova_bounds_used：
-- 上屏时 nova_tree_keys 看这条边界还在不在，不在了就把它忘掉。
local function pair_code(tokens, first, last)
    local parts = {}
    for k = first, last do
        if #tokens[k] ~= 2 then return nil end
        parts[#parts + 1] = tokens[k]
    end
    return table.concat(parts)
end

local function apply_bounds(blocks, tokens, offsets)
    local used, p = {}, 1
    while p <= #blocks do
        local first, step = blocks[p].first, 1
        for _, entry in ipairs(bounds.starting_with(tokens[first]:sub(1, 2)) or {}) do
            local middle = first + #entry.left // 2
            local last = middle + #entry.right // 2 - 1
            local q = p
            while blocks[q] and blocks[q].last < last do q = q + 1 end
            if blocks[q] and blocks[q].last == last and pair_code(tokens, first, middle - 1) == entry.left
                and pair_code(tokens, middle, last) == entry.right then
                local chosen = false
                for k = p, q do chosen = chosen or blocks[k].pinned end
                local same = q == p + 1 and blocks[p].last == middle - 1
                if not chosen and not same then
                    for _ = p, q do table.remove(blocks, p) end
                    table.insert(blocks, p, { pinned = false, frozen = true, learned = true, first = middle, last = last, text = entry.rtext })
                    table.insert(blocks, p, { pinned = false, frozen = true, learned = true, first = first, last = middle - 1, text = entry.ltext })
                    same = true
                elseif same and blocks[p].text == entry.ltext and blocks[q].text == entry.rtext then
                    -- 上一键换好的，或解码器自己就这么切、字也一样：照样算学到的。
                    for k = p, q do
                        if not blocks[k].pinned then blocks[k].frozen, blocks[k].learned = true, true end
                    end
                end
                used[#used + 1] = string.format("%d:%s:%s\n", offsets[middle], entry.left, entry.right)
                if same then step = 2 end
                break
            end
        end
        p = p + step
    end
    return table.concat(used)
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
    -- 只用这一次。不清掉的话，后面的块每次移动光标都重新解码；nova_lm_filter 重选首选时不动焦点块，
    -- 焦点移上去文字就变回解码器的写法，移开又变回去。
    if open_from then context:set_property("nova_open_from", "") end
    local frozen = frozen_lines(previous, same_input or stop ~= seg._end, open_from,
                                context:get_property("nova_bounds_used"))
    local pins = parse_pins(env, tokens, offsets, context.input:sub(seg._start + 1, seg._end), frozen)
    local default_text = utf8.len(cand.text) == #tokens and cand.text or nil
    local spans = default_text and decoder_spans(cand, tokens)
    -- nova_redecode：`起:止:输入`，nova_tree_keys 伸缩块时写，输入变了就失效。
    local redecode
    local rfrom, rto, rinput = (context:get_property("nova_redecode") or ""):match("^(%d+):(%d+):(.*)$")
    if rinput == context.input then
        for i = 1, #tokens do
            if offsets[i] == tonumber(rfrom) then redecode = { first = i } end
            if redecode and offsets[i] + #tokens[i] == tonumber(rto) then redecode.last = i break end
        end
        if redecode and not redecode.last then redecode = nil end
    end
    local blocks = build_blocks(env, tokens, pins, default_text, spans, redecode)
    if not blocks then return nil end
    context:set_property("nova_bounds_used", apply_bounds(blocks, tokens, offsets))
    -- 树原样保留时（输入没变、只多了半个音节）分组也不变。
    if not same_input and stop == seg._end then
        local groups = {}
        for _, span in ipairs(spans or {}) do
            groups[#groups + 1] = offsets[span[1]] .. ":" .. (offsets[span[2]] + #tokens[span[2]])
        end
        context:set_property("nova_tree_groups", table.concat(groups, "\n"))
    end
    choose_by_aux(env, blocks, tokens, offsets)
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

-- 打错键 ------------------------------------------------------------------
-- 编码里出现不成立的音节时（librime 的首选只覆盖到这里），前面照常出树，
-- 从这里到末尾是一块原样的字母（标记 t，标橙）。它的备选是改一个键之后编码成立的写法：
-- 相邻键、两键颠倒、多打一个键、漏打一个键。备选带着改好的编码，选中就换掉输入。
-- 只在编码不成立时才算，打对的编码不受影响。
local FIX_WINDOW = 6     -- 往卡住的地方前面看几个音节（漏键、多键时打错的键在卡住处之前）
local FIX_RIGHT = 8      -- 打分时卡住处之后带几个字母
local FIX_ALTS = 3
local FIX_LM_ALTS = 200  -- 交给 GPT-2 重排的写法数
local FIX_COST = { n = 1.0, s = 1.0, d = 2.5, i = 2.5 }  -- 相邻键、颠倒、多打、漏打的罚分
local FIX_BUDGET = 0.03  -- 秒，打字时的上限，超时就用已经算出的
local KEY_ROWS = { "qwertyuiop", "asdfghjkl;", "zxcvbnm,./" }

local NEIGHBOURS = {}
for r, row in ipairs(KEY_ROWS) do
    for i = 1, #row do
        local c = row:sub(i, i)
        if c:match("%a") then
            local list = {}
            for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { -1, 1 }, { 1, -1 }, { 1, 0 } }) do
                local other = KEY_ROWS[r + d[1]]
                local n = other and other:sub(i + d[2], i + d[2]) or ""
                if n:match("^%a$") then list[#list + 1] = n end
            end
            NEIGHBOURS[c] = list
        end
    end
end

-- 两个字母是不是一个音节：翻译器能给出正好两个字母长的字。
local function valid_pair(env, pair)
    local v = env.valid[pair]
    if v == nil then
        v = false
        for _, word in ipairs(raw_words(env, pair).list) do
            if word[2] == 2 then v = true break end
        end
        env.valid[pair] = v
    end
    return v
end

local function all_valid(env, code)
    if #code % 2 == 1 then return false end
    for i = 1, #code, 2 do
        if not valid_pair(env, code:sub(i, i + 1)) then return false end
    end
    return true
end

-- 改一个键的所有写法：{ 编码, 种类, 改动位置 }，位置从 0 数。
local function fix_variants(env, code, broken, full)
    local seen, out = { [code] = true }, {}
    local function add(v, kind, at)
        if not seen[v] then
            seen[v] = true
            if all_valid(env, v) then out[#out + 1] = { v, kind, at } end
        end
    end
    local lo = math.max(0, broken - 2 * FIX_WINDOW)
    for p = lo, math.min(#code - 1, broken + 1) do
        local c = code:sub(p + 1, p + 1)
        local before, after = code:sub(1, p), code:sub(p + 2)
        if p + 1 < #code then add(before .. code:sub(p + 2, p + 2) .. c .. code:sub(p + 3), "s", p) end
        for _, n in ipairs(NEIGHBOURS[c] or {}) do add(before .. n .. after, "n", p) end
        if full then
            add(before .. after, "d", p)
            for b = 97, 122 do add(before .. string.char(b) .. c .. after, "i", p) end
        end
    end
    if full and broken >= #code - 2 then
        for b = 97, 122 do add(code .. string.char(b), "i", #code) end
    end
    return out, lo
end

local function best_score(env, tokens, beam)
    local paths = sentences(env, tokens, nil, beam)
    return paths[1] and paths[1][2], paths[1] and paths[1][1]
end

-- librime 给这串编码解出的整句（带语法模型，比这里的 sentences 准）。解不出整句时返回 nil。
local function librime_sentence(env, key)
    local seg = Segment(0, #key)
    seg.tags = Set { "abc" }
    local translation = env.translator:query(key, seg)
    if not translation then return nil end
    local nxt, this = translation:iter()
    local cand = nxt(this)
    if cand and cand._end == #key then return cand.text end
end

-- 返回排好的备选：{ code = 改好的整段编码, text = 改动处附近解出的字 }。
-- full：也试多打、漏打。这两种每次有近百种写法，每种都要查翻译器，只在用户按空格要求时算。
local function typo_fixes(env, code, broken, full)
    local started = os.clock()
    local variants, lo = fix_variants(env, code, broken, full)
    -- 先算卡住的音节和它附近的音节，便宜的改法在前。打字时有时间上限，排在后面的可能算不到。
    local home = math.floor(broken / 2)
    table.sort(variants, function(a, b)
        local da, db = math.abs(home - math.floor(a[3] / 2)), math.abs(home - math.floor(b[3] / 2))
        if da ~= db then return da < db end
        if FIX_COST[a[2]] ~= FIX_COST[b[2]] then return FIX_COST[a[2]] < FIX_COST[b[2]] end
        return a[1] < b[1]
    end)
    local function window_of(v)
        local width = math.min(#v[1] - lo, broken - lo + FIX_RIGHT)
        width = width - width % 2
        return syllables(v[1]:sub(lo + 1, lo + width))
    end
    -- 前 lo 个字母所有写法都一样，解一次，接在每种写法的窗口前面交给 GPT-2。
    local head = ""
    if lo > 0 then head = librime_sentence(env, code:sub(1, lo)) or "" end
    local scored = {}
    for _, v in ipairs(variants) do
        if not full and os.clock() - started > FIX_BUDGET then break end
        -- 只解卡住处附近一段。
        local window = window_of(v)
        -- 插件开着时只要字（GPT-2 打分），不算词库分数。
        local score, text = 0, nil
        if window and #window > 0 then
            if env.lm_orange then text = librime_sentence(env, table.concat(window))
            else score, text = best_score(env, window) end
        end
        if score and text and utf8.len(text) == #window then
            -- 从改动处前一个音节开始显示，看得出换掉了什么。
            local first = math.max(1, v[3] // 2 - lo // 2)
            local last = math.min(#window, first + 4)
            local shown = text:sub(utf8.offset(text, first), (utf8.offset(text, last + 1) or #text + 1) - 1)
            scored[#scored + 1] = { code = v[1], kind = v[2], at = v[3], score = score - FIX_COST[v[2]], tokens = #window,
                                    text = shown, sentence = head .. text, order = #scored + 1 }
        end
    end
    -- 插件开着时按上面的顺序给 GPT-2 最多 FIX_LM_ALTS 种（词库分数几乎只看切出几个词，区分不了），
    -- 由它重排后留 FIX_ALTS 个；没开时按词库分数取前 FIX_ALTS 个。
    if not env.lm_orange then table.sort(scored, function(a, b) return a.score > b.score end) end
    local fixes = {}
    for i = 1, math.min(env.lm_orange and FIX_LM_ALTS or FIX_ALTS, #scored) do
        local s = scored[i]
        fixes[#fixes + 1] = { code = s.code, text = s.text, kind = s.kind, sentence = s.sentence }
    end
    local dump = os.getenv("NOVA_FIX_DUMP")
    if dump then
        local f = io.open(dump, "a")
        if f then
            for rank, s in ipairs(scored) do
                f:write(table.concat({ code, s.code, s.kind, s.at, string.format("%.3f", s.score), s.tokens, rank }, "\t"), "\n")
            end
            f:write(table.concat({ code, "#time", string.format("%.1f", 1000 * (os.clock() - started)), #variants, full and "full" or "quick" }, "\t"), "\n")
            f:close()
        end
    end
    return fixes
end

-- 原样字母这一块。有备选时只有它带数字键：用户这会儿要改的是这里。
local function tail_line(env, code, broken, fixes)
    local flags = "0t" .. (#fixes > 0 and "o" or "") .. "ua0"
    local fields = { flags, tostring(broken), tostring(#code), code:sub(broken + 1), field(code:sub(broken + 1), nil) }
    for _, fix in ipairs(fixes) do
        fields[#fields + 1] = env.lm_orange and field(fix.text, nil, #code, broken, fix.code, fix.kind, fix.sentence)
                              or field(fix.text, nil, #code, broken, fix.code)
    end
    return table.concat(fields, "\t")
end

local function without_overview(tree)
    local lines = {}
    for line in tree:gmatch("[^\n]+") do
        local fields = {}
        for value in line:gmatch("[^\t]+") do fields[#fields + 1] = value end
        local head, tail = fields[1]:match("^([^a]*)(.*)$")
        fields[1] = head:gsub("o", "") .. tail
        lines[#lines + 1] = table.concat(fields, "\t", 1, math.min(#fields, 5))
    end
    return table.concat(lines, "\n")
end

local function init(env)
    load_lexicon()
    env.valid, env.fixes = {}, {}
    env.translator = Component.Translator(env.engine, "", "script_translator@translator")
    env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
    env.raw, env.raw_size = {}, 0
    -- contextual_suggestions 打开时，翻译器按上一次上屏的文字调整分数（poet.h 的 ContextualWeighted），
    -- 上屏后缓存里的分数就过期了，清掉。
    env.commit = env.engine.context.commit_notifier:connect(function()
        env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
        env.raw, env.raw_size = {}, 0
    end)
    env.word_penalty = env.engine.schema.config:get_double("nova_sentences/word_penalty") or 0.0
    env.tree_enabled = env.engine.schema.config:get_bool("nova_tree/enabled") or false
    env.tree_debug = env.engine.schema.config:get_bool("nova_tree/debug") or false
    env.lm_enabled = env.engine.schema.config:get_bool("nova_lm/enabled") or false
    env.lm_orange = false
end

local function func(input, env)
    local composition = env.engine.context.composition
    local seg = not composition:empty() and composition:back() or nil
    local tokens, pending
    -- 只有拼音段出树。日期（orq）这类由 recognizer 认出的段，字母碰巧也能切成音节。
    if seg and seg:has_tag("abc") then
        tokens, pending = syllables(env.engine.context.input:sub(seg._start + 1, seg._end))
    end
    local stop = seg and seg._end - #(pending or "")
    local context = env.engine.context
    -- 重新出候选就回到树，见 nova_tree_keys 的 list_open。
    if (context:get_property("nova_list") or "") ~= "" then context:set_property("nova_list", "") end
    -- nova_lm_filter 的模型加载好之后写 nova_lm_ready。配置里开着、但插件或模型没装（或还没加载完）时，
    -- 标橙和改错键的排序仍由这里做，不然两边都不做。
    env.lm_orange = env.lm_enabled and context:get_property("nova_lm_ready") == "1"
    -- nova_tree_keys 删了用户词之后写 nova_flush：缓存里还有那个词，清掉。
    if (context:get_property("nova_flush") or "") ~= "" then
        context:set_property("nova_flush", "")
        env.cache, env.cache_size, env.weights, env.decoded = {}, 0, {}, {}
        env.raw, env.raw_size = {}, 0
    end
    local first = true
    local pinned = false
    for cand in input:iter() do
        local shown = cand
        -- 自定义短语（nova_phrases）排在第一位时不出树：面板显示普通列表，短语后面是拼音的候选。
        if first and cand.type == "nova_phrase" then tokens = nil end
        if first and env.tree_enabled then
            local tree = ""
            -- 首选停在一个不成立的音节前：后面全部当原样字母，前面照常出树。
            local typo
            if tokens and #tokens >= 1 and cand._end < stop then
                local code = context.input:sub(seg._start + 1, seg._end)
                local at = cand._end - seg._start
                local offsets = token_offsets(tokens)
                for i = 1, #tokens do
                    if offsets[i] == at then
                        if not valid_pair(env, tokens[i]:sub(1, 2)) then
                            typo = { code = code, broken = at }
                            tokens = { table.unpack(tokens, 1, i - 1) }
                            stop = cand._end
                        end
                        break
                    end
                end
            end
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
            if tokens and #tokens == 0 and not typo then
                tree = "\n"
                shown = Candidate("raw", seg._start, seg._end, pending, "")
            end
            if typo and not has_aux(typo.code) then
                local full = context:get_property("nova_fix_full") == context.input
                local key = (full and "F" or "Q") .. typo.code
                local ok, fixes = true, env.fixes[key]
                if not fixes then
                    ok, fixes = pcall(typo_fixes, env, typo.code, typo.broken, full)
                    if ok then env.fixes = { [key] = fixes } end
                end
                if not ok then
                    log.error("nova_sentences: " .. tostring(fixes))
                    fixes = {}
                end
                if #fixes > 0 and tree ~= "" and tree ~= "\n" then tree = without_overview(tree) end
                local line = tail_line(env, typo.code, typo.broken, fixes)
                tree = (tree == "" or tree == "\n") and line or tree .. "\n" .. line
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
