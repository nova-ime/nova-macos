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
-- 末尾没打完的音节也参与候选：只打了声母时保留一个双拼键，让引擎按这个声母补全；
-- 已经带了韵母字母（zho、zhon、ten）时猜词频最高的完整音节，其余高频补全作为备选，
-- 由 nova_sentences 合并（muq 出「目前」，zhon 出「中」）。前面是简拼时末尾仍当简拼（nh）。
-- 全拼的合法音节另外挂上模糊音变体码（nova_qp_alt），同样由 nova_sentences 合并。
-- 每打一个字母只重切最后 3 个单元，前面的不再变。6486 句评测逐键切分，整句切对 98.9%（加简拼之前量的）。
--   单元：s 音节（双拼两个字母）、j 简拼音节（声母键 + V）、
--   p 末尾没打完的音节（声母键，或按前缀猜出来的完整音节码）、
--   g 切不成音节的字母（原样）、a 大写辅助码（原样）、d 隔音符 '（不占双拼）、
--   x 整段原样（日期 orq、符号表 ofh 这类编码）。
-- 光标只停在单元之间：←/→ 按音节移动；在中间打字、退格、Delete 改的是光标处的拼音，
-- 前后各一两个单元跟着重切，固定段和树照双拼的改动平移（nova_tree_keys.replace_input）。
-- 输入被别处改了（选打错键的备选、空格上屏前半句）时，没变的头尾单元保留拼音，变了的部分从双拼反推。
-- 输入里有字母以外的字符（邮箱、网址）或以大写开头（英文）时，这次输入不再管，原样交给 Rime。
--
-- 别家双拼（小鹤 flypy、微软 mspy、搜狗 sogou）也走这里：方案选单「双拼方案」是一组单选开关
-- （zrm flypy mspy sogou quanpin），选了别家双拼时，打的键每两个一组，查 nova_shuangpin.txt
-- （scripts/shuangpin_table.py 生成）得到音节，再换成自然码。末尾单独一个键当没打完的音节。
-- 不切音节、不纠错、没有简拼。微软、搜狗的 ing 是 ;，只在前面是没打完的音节时才当拼音，
-- 别的时候照旧是选词键。选自然码时这个处理器什么都不做。

local tree_keys = require("nova_tree_keys")

local TABLE_FILE = "nova_quanpin.txt"
local SP_FILE = "nova_shuangpin.txt"
local SHUANGPIN = { "flypy", "mspy", "sogou" }
local GARBAGE = -40.0
-- 简拼音节的罚分，要介于正常音节（二元分数一般在 -3 到 -12）和 GARBAGE 之间。
local ABBREV = -20.0
-- 简拼音节编码里跟在声母键后面的通配符，和 nova.schema.yaml 的 abbrev 规则一致。
local WILDCARD = "V"

-- 模糊音。只在全拼层展开：合法音节保留用户打的码，另外发布同字节长的变体码，
-- 由 nova_sentences 在查询时合并。分组名和 nova.schema.yaml 的开关一致。
local FUZZY_INITIALS = {
    { "zh", "z", "zcs" },
    { "ch", "c", "zcs" },
    { "sh", "s", "zcs" },
    { "n", "l", "nl" },
}
local FUZZY_FINALS = {
    { "ang", "an", "nasal" },
    { "eng", "en", "nasal" },
    { "ing", "in", "nasal" },
    { "iang", "ian", "nasal" },
    { "uang", "uan", "nasal" },
}
local FUZZY_GROUPS = { "zcs", "nasal", "nl" }
-- 参考 nova_sentences 的 FUZZY_COST，单位和 log(quality) 一样；合并规则数越多罚得越重。
local FUZZY_ALT_COST = 2.5
-- 待定音节猜了一个完整音节后，其余高频补全的罚分（第 2 名起）。
local PEND_ALT_COST = 1.0
local PREFIX_SYLS = 8
-- 不成立但像模糊音的整串，作为音节参与切分。比 typo 的 -22 轻很多：
-- zuang 这样的串如果只罚 -10，会被“zuang = zuan + 待定 g”的高前缀频率盖过，出不了装/专。
local FUZZY_TYPO = -4.0
-- 模糊音拼法落在末尾时多给一点分：suang 会被算成 suan + 待定 g，
-- 有这个词频相近的竞争时，整段模糊读法（shuang）要更容易胜出。只加在结尾，不干扰句子中间。
local FUZZY_SUFFIX_BONUS = 2.0
-- 拼音纠错：切不成音节的一段字母，按打错一个键（相邻两键颠倒、漏一键、多按一个邻键或重复键、
-- 按到邻键）换成最常用的那个音节，罚 CORRECT。不含元音的一段不纠（是简拼）；
-- 比 GARBAGE 轻，切不成的才纠。纠过的单元 raw 仍是打的字母（面板和光标照旧），syl 是纠成的音节。
-- 末尾的一段要是还能打成音节（某个音节的前缀），当没打完，不纠。
-- CORRECT 比一个简拼（ABBREV）重：nih 可以是 ni + h 简拼，也可以是 niu 按到邻键，按简拼切，
-- 夹在全拼里的简拼照旧切出来。再轻纠得更多，但夹简拼的整句掉到 40%–60%。
-- 评测（gold.tsv 1898 句，整句切分）：拼对的切分不变、零误纠；全打简拼 99.2% 不变；
-- 全拼夹一个简拼 97.3% -> 96.9%；末尾以外打错一个键的整句纠回约 45%（颠倒、按到邻键纠得最多）。
local CORRECT = -22.0
-- QWERTY 上每个字母的邻键。
local NEIGHBOR = {
    q = "wa", w = "qeas", e = "wrsd", r = "etdf", t = "ryfg", y = "tugh", u = "yihj", i = "uojk",
    o = "ipkl", p = "ol", a = "qwsz", s = "awedzx", d = "serfxc", f = "drtgcv", g = "ftyhvb",
    h = "gyujbn", j = "huiknm", k = "jiolm", l = "kop", z = "asx", x = "zsdc", c = "xdfv",
    v = "cfgb", b = "vghn", n = "bhjm", m = "njk",
}
local WINDOW = 3
local LEFT, RIGHT, BACKSPACE, DELETE, APOSTROPHE, SEMICOLON = 0xff51, 0xff53, 0xff08, 0xffff, 0x27, 0x3b
-- 双拼的声母键反推拼音声母（没打完的音节从双拼反推时用）。
local INITIAL_OF = { v = "zh", i = "ch", u = "sh" }
-- 能单独当简拼的声母，对应的双拼声母键。
local INITIAL_KEY = { zh = "v", ch = "i", sh = "u" }
for letter in ("bpmfdtnlgkhjqxrzcsyw"):gmatch(".") do INITIAL_KEY[letter] = letter end

local T  -- 表，所有会话共用，第一次用时读

local function find_file(name)
    for _, dir in ipairs({ rime_api.get_user_data_dir(), rime_api.get_shared_data_dir() }) do
        local file = io.open(dir .. "/" .. name, "r")
        if file then file:close() return dir .. "/" .. name end
    end
end

-- 别家双拼的表：T.sp[方案][两个键] = 音节，T.sp_key[方案][音节] = 两个键，
-- T.sp_first[方案][键] = 以这个键开头的最常用音节的自然码首键（没打完的音节用）。
local function load_shuangpin()
    T.sp, T.sp_key, T.sp_first = {}, {}, {}
    for _, name in ipairs(SHUANGPIN) do T.sp[name], T.sp_key[name], T.sp_first[name] = {}, {}, {} end
    local path = find_file(SP_FILE)
    if not path then
        log.error("nova_quanpin: " .. SP_FILE .. " not found")
        return
    end
    local best = {}
    for line in io.lines(path) do
        local name, keys, syllable = line:match("^(%a+)\t(%S%S)\t(%a+)$")
        local code = name and T.sp[name] and T.code[syllable]
        if code then
            T.sp[name][keys] = syllable
            T.sp_key[name][syllable] = T.sp_key[name][syllable] or keys
            local k = name .. keys:sub(1, 1)
            if not best[k] or T.uni[syllable] > T.uni[best[k]] then
                best[k] = syllable
                T.sp_first[name][keys:sub(1, 1)] = code:sub(1, 1)
            end
        end
    end
end

-- 音节拆成声母（zh/ch/sh 或单辅音，或空）和韵母。y/w 按声母算。
local function split_syllable(s)
    local two = s:sub(1, 2)
    local initial = ""
    if two == "zh" or two == "ch" or two == "sh" then
        initial = two
    elseif s:match("^[bpmfdtnlgkhjqxrzcsyw]") then
        initial = s:sub(1, 1)
    end
    return initial, s:sub(#initial + 1)
end

local function merge_groups(a, b)
    if not a or a == "" then return b end
    if not b or b == "" or a == b then return a end
    return a < b and a .. "," .. b or b .. "," .. a
end

-- 一个声母/韵母在有这条规则时可能变成什么。第一条是原样，后面是变体。
local function rule_variants(value, rules)
    local out = { { value, nil, 0 } }
    for _, rule in ipairs(rules) do
        local a, b, group = rule[1], rule[2], rule[3]
        if value == a then
            out[#out + 1] = { b, group, 1 }
        elseif value == b then
            out[#out + 1] = { a, group, 1 }
        end
    end
    return out
end

local function groups_enabled(groups, enabled)
    if not groups or groups == "" then return true end
    for group in groups:gmatch("[^,]+") do
        if not enabled[group] then return false end
    end
    return true
end

-- 现在启用的模糊音分组，以及稳定的签名（设置里改了要清 nova_sentences 的缓存）。
local function fuzzy_groups(ctx)
    local set, names = {}, {}
    for _, group in ipairs(FUZZY_GROUPS) do
        if ctx:get_option("fuzzy_" .. group) then
            set[group] = true
            names[#names + 1] = group
        end
    end
    return set, table.concat(names, ",")
end

-- T.fuzzy[音节]：合法变体；T.fuzzy_typo[不成立的拼法]：最常用的目标音节。
-- 同一音节里声母和韵母规则可以叠加（zang → zhang、zan、zhan），cost 记叠加了几条。
local function build_fuzzy()
    T.fuzzy, T.fuzzy_typo, T.maxfuzzy = {}, {}, 0
    local function add_typo(typed, target, groups, cost)
        if T.code[typed] then return end
        local slot = T.fuzzy_typo[typed]
        if not slot then slot = {}; T.fuzzy_typo[typed] = slot end
        local key = groups or ""
        local old = slot[key]
        if not old or T.uni[target] > T.uni[old.target] then
            slot[key] = { target = target, groups = groups, cost = cost }
        end
        T.maxfuzzy = math.max(T.maxfuzzy, #typed)
    end
    for syllable in pairs(T.code) do
        local initial, final = split_syllable(syllable)
        local initials = rule_variants(initial, FUZZY_INITIALS)
        local finals = rule_variants(final, FUZZY_FINALS)
        local seen, alts = { [syllable] = true }, {}
        for _, iopt in ipairs(initials) do
            for _, fopt in ipairs(finals) do
                local alt = iopt[1] .. fopt[1]
                if alt ~= syllable and not seen[alt] then
                    seen[alt] = true
                    local groups = merge_groups(iopt[2], fopt[2])
                    local cost = iopt[3] + fopt[3]
                    if T.code[alt] then
                        alts[#alts + 1] = { alt = alt, groups = groups, cost = cost }
                    elseif groups then
                        add_typo(alt, syllable, groups, cost)
                    end
                end
            end
        end
        T.fuzzy[syllable] = alts
    end
end

local function load_table()
    if T then return T end
    T = { code = {}, uni = {}, bi = {}, lu = {}, lp = {}, prefix_syl = {},
          inv = {}, rev = {}, maxl = 1, fix = {}, maxfix = 0, fuzzy = {}, fuzzy_typo = {}, maxfuzzy = 0,
          sp = {}, sp_key = {}, sp_first = {} }
    local path = find_file(TABLE_FILE)
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
            local rev = T.rev[b]
            if not rev then rev = {}; T.rev[b] = rev end
            rev[#rev + 1] = a
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
            local list = T.prefix_syl[prefix]
            if not list then list = {}; T.prefix_syl[prefix] = list end
            list[#list + 1] = syllable
        end
    end
    for prefix, m in pairs(mass) do
        T.lp[prefix] = math.log((m + 1) / total)
    end
    -- 每个前缀只留最常用的几个补全音节，待定音节猜主码和备选时用。
    for _, list in pairs(T.prefix_syl) do
        table.sort(list, function(a, b) return T.uni[a] > T.uni[b] end)
        for i = #list, PREFIX_SYLS + 1, -1 do list[i] = nil end
    end
    -- 纠错表：打错一个键的拼法 -> 最常用的音节。本身是音节的拼法不收；短于 2 个字母的不收（是简拼）。
    local function add(typo, syllable)
        -- 不含元音的不收：那是一串简拼（zd 是「知道」，不是 ze 按错了邻键）。
        if #typo < 2 or T.code[typo] or not typo:find("[aeiouv]") then return end
        local old = T.fix[typo]
        if not old or T.uni[syllable] > T.uni[old] then T.fix[typo] = syllable end
        T.maxfix = math.max(T.maxfix, #typo)
    end
    for s in pairs(T.uni) do
        local n = #s
        for k = 1, n do
            local before, ch, after = s:sub(1, k - 1), s:sub(k, k), s:sub(k + 1)
            add(before .. after, s)  -- 漏一键
            for nb in (NEIGHBOR[ch] or ""):gmatch(".") do
                add(before .. nb .. after, s)          -- 按到邻键
                add(before .. nb .. ch .. after, s)    -- 多按一个邻键（在前）
                add(before .. ch .. nb .. after, s)    -- 多按一个邻键（在后）
            end
            add(before .. ch .. ch .. after, s)        -- 重复按了一下
            if k < n and ch ~= s:sub(k + 1, k + 1) then  -- 相邻两键颠倒
                add(before .. s:sub(k + 1, k + 1) .. ch .. s:sub(k + 2), s)
            end
        end
    end
    build_fuzzy()
    load_shuangpin()
    return T
end

-- 现在用的输入方式："quanpin"、别家双拼的名字，或者 nil（自然码，这里不管）。
local function layout_of(ctx)
    if ctx:get_option("quanpin") then return "quanpin" end
    for _, name in ipairs(SHUANGPIN) do
        if ctx:get_option(name) then return name end
    end
end

-- 别家双拼的一串键切成单元：每两个键一个音节，末尾单独一个键是没打完的音节。
local function sp_segment(text, layout)
    local sp, first, out = T.sp[layout], T.sp_first[layout], {}
    local i = 1
    while i <= #text do
        local pair = text:sub(i, i + 1)
        local syllable = #pair == 2 and sp[pair]
        if syllable then
            out[#out + 1] = { raw = pair, code = T.code[syllable], kind = "s", syl = syllable }
            i = i + 2
        elseif #pair == 1 and first[pair] then
            out[#out + 1] = { raw = pair, code = first[pair], kind = "p" }
            i = i + 1
        else
            local ch = text:sub(i, i)
            out[#out + 1] = { raw = ch, code = ch == ";" and "" or ch, kind = "g" }
            i = i + 1
        end
    end
    return out
end

-- 音节 b 跟在 a 后面的分数。a 为 "" 时只看 b 自己的词频。
local function bigram(a, b)
    if a == "" then return T.lu[b] end
    local c = T.bi[a .. " " .. b] or 0
    return math.log(0.7 * c / T.uni[a] + 0.3 * math.exp(T.lu[b]))
end

-- 一串小写字母切成单元。prev 是它前面的音节（没有时为 ""），after_abbr 是它前面的单元是不是简拼。
local function segment(text, prev, after_abbr, fuzzy)
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
            for l = 2, math.min(T.maxfix, n - i) do
                local s = text:sub(i + 1, i + l)
                local fix = T.fix[s]
                if fix and (i + l < n or not T.lp[s]) then
                    local v = score + bigram(last, fix) + CORRECT
                    local old = best[i + l][fix]
                    if not old or v > old[1] then best[i + l][fix] = { v, i, last, s, "s", fix } end
                end
            end
            -- 模糊音拼法（zuang、suang、sei）作为整音节参与切分，不然会被切成 zu + ang。
            if fuzzy then
                for l = 2, math.min(T.maxfuzzy, n - i) do
                    local s = text:sub(i + 1, i + l)
                    local slot = T.fuzzy_typo[s]
                    if slot then
                        local pick
                        for _, entry in pairs(slot) do
                            if groups_enabled(entry.groups, fuzzy) and (not pick
                                or entry.cost < pick.cost
                                or (entry.cost == pick.cost and T.uni[entry.target] > T.uni[pick.target])) then
                                pick = entry
                            end
                        end
                        -- 本身还是某个音节的前缀时（zua 是 zuan 的前缀），留给待定音节逻辑：
                        -- 主码猜最常用的补全，模糊前缀（zhua）作为备选，两边的字都能看到。
                        if pick and not T.lp[s] then
                            local bonus = i + l == n and FUZZY_SUFFIX_BONUS or 0
                            local v = score + bigram(last, pick.target) + FUZZY_TYPO * pick.cost + bonus
                            local old = best[i + l][pick.target]
                            if not old or v > old[1] then
                                best[i + l][pick.target] = { v, i, last, s, "s", pick.target }
                            end
                        end
                    end
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
    -- 整个串本身是合法音节（只是比较生僻，biang、feng），却被当成了「完整音节 + 待定尾巴」时，
    -- 优先整音节；模糊音变体在 nova_sentences 查询时再合并（biang 会列出 bian 的字）。
    if top_part and T.code[text] and T.fuzzy[text] and #T.fuzzy[text] > 0 and best[n][text] then
        top_i, top_last, top_part = n, text, nil
    end
    local out = {}
    -- 没打完的部分自己就是音节时（xi 后面可能还有 an），先按这个音节出字，接着打再重切。
    if top_part and T.code[top_part] then
        out[1] = { raw = top_part, code = T.code[top_part], kind = "s" }
    elseif top_part then
        -- 只有声母时保留一个双拼键，让引擎按这个声母补全所有音节；
        -- 已经带了韵母字母（zho、zhon、ten、zua）时猜词频最高的完整音节，
        -- 否则引擎会把它们都压成声母键，zhon 会出所有 zh 音节。
        local code
        if INITIAL_KEY[top_part] then
            -- 主码用用户实际打的声母键（z 就是 z，zh 才是 v），模糊音的另一边作为备选。
            code = INITIAL_KEY[top_part]
        else
            local list = T.prefix_syl[top_part]
            code = list and list[1] and T.code[list[1]]
            if not code then
                local initial = split_syllable(top_part)
                code = INITIAL_KEY[initial] or top_part:sub(1, 1)
            end
        end
        out[1] = { raw = top_part, code = code, kind = "p" }
    end
    local i, last = top_i, top_last
    while i > 0 do
        local entry = best[i][last]
        local raw, kind, fix = entry[4], entry[5], entry[6]
        local code = raw
        if kind == "s" then code = T.code[fix or raw] elseif kind == "j" then code = INITIAL_KEY[raw] .. WILDCARD end
        table.insert(out, 1, { raw = raw, code = code, kind = kind, syl = fix })
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
local function tokenize(raw, prev, after_abbr, layout, fuzzy)
    local sp = layout and layout ~= "quanpin"
    local out, pos = {}, 1
    while pos <= #raw do
        local run = raw:match(sp and "^[%l;]+" or "^%l+", pos)
        if run then
            local units = sp and sp_segment(run, layout) or segment(run, prev, after_abbr, fuzzy)
            for _, unit in ipairs(units) do out[#out + 1] = unit end
            pos = pos + #run
        else
            local ch = raw:sub(pos, pos)
            out[#out + 1] = { raw = ch, code = ch == "'" and "" or ch, kind = ch == "'" and "d" or "a" }
            pos = pos + 1
        end
        local last = out[#out]
        prev = last and last.kind == "s" and (last.syl or last.raw) or ""
        after_abbr = last ~= nil and last.kind == "j"
    end
    return out
end

local function concat(units, field, from, to)
    local parts = {}
    for i = from or 1, to or #units do parts[#parts + 1] = units[i][field] end
    return table.concat(parts)
end

-- 双拼编码反推单元（输入被别处改了时用）。layout 是别家双拼时，单元的 raw 写成那家的键。
local function from_code(code, layout)
    local sp_key = layout and T.sp_key[layout]
    local out, pos = {}, 1
    while pos <= #code do
        local pair = code:match("^%l%l", pos)
        local syllable = pair and T.inv[pair]
        local key = code:match("^%l" .. WILDCARD, pos)
        if syllable and sp_key then
            out[#out + 1] = { raw = sp_key[syllable] or pair, code = pair, kind = "s", syl = syllable }
            pos = pos + 2
        elseif syllable then
            out[#out + 1] = { raw = syllable, code = pair, kind = "s" }
            pos = pos + 2
        elseif key then
            out[#out + 1] = { raw = INITIAL_OF[key:sub(1, 1)] or key:sub(1, 1), code = key, kind = "j" }
            pos = pos + 2
        else
            local ch = code:sub(pos, pos)
            if ch:match("%u") then
                out[#out + 1] = { raw = ch, code = ch, kind = "a" }
            elseif pos == #code and sp_key then
                -- 三家的声母键和自然码相同（zh ch sh 也是 v i u），没打完的音节原样就是那家的键。
                out[#out + 1] = { raw = ch, code = ch, kind = "p" }
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
    local middle = from_code(input:sub(pos, stop), env.layout)
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

-- 一个单元的模糊/补全备选，码长和主码相同，nova_sentences 替换后位置不用换算。
local function unit_alternates(unit, groups)
    local out, seen = {}, {}
    local function add(code, cost)
        if code and code ~= unit.code and #code == #unit.code and not seen[code] then
            seen[code] = true
            out[#out + 1] = { code = code, cost = cost or FUZZY_ALT_COST }
        end
    end
    if unit.kind == "p" then
        local raw = unit.raw or ""
        if #unit.code == 1 then
            -- 只打了声母：主码就是用户实际打的声母键；这里补上模糊配对的键
            -- （z↔v、c↔i、s↔u、n↔l），两边的补全都查。
            for _, rule in ipairs(FUZZY_INITIALS) do
                local a, b, group = rule[1], rule[2], rule[3]
                local target
                if raw == a then target = b elseif raw == b then target = a end
                if target and groups[group] and INITIAL_KEY[target] then
                    add(INITIAL_KEY[target], FUZZY_ALT_COST)
                end
            end
        else
            -- 带了韵母字母：先猜了一个完整音节，其余高频补全是备选。
            local list = T.prefix_syl[raw]
            if list then
                for rank = 2, #list do
                    add(T.code[list[rank]], PEND_ALT_COST + 0.5 * (rank - 2))
                end
            end
            -- 再把声母换成模糊音、剩下的韵母前缀保留，找那边的补全（zon 也会出中）。
            local initial, final = split_syllable(raw)
            for _, rule in ipairs(FUZZY_INITIALS) do
                local a, b, group = rule[1], rule[2], rule[3]
                local alt_initial
                if initial == a then alt_initial = b elseif initial == b then alt_initial = a end
                if alt_initial and groups[group] then
                    local alt_prefix = alt_initial .. final
                    local alts = T.prefix_syl[alt_prefix] or {}
                    -- 换完声母后剩下正好是个音节时（zua → zhua），先列它；
                    -- 否则列以它开头的高频补全（zon → zhong、zhou）。
                    if T.code[alt_prefix] then add(T.code[alt_prefix], FUZZY_ALT_COST) end
                    local rank = 0
                    for i = 1, #alts do
                        if alts[i] ~= alt_prefix then
                            rank = rank + 1
                            add(T.code[alts[i]], FUZZY_ALT_COST + 0.5 * rank)
                            if rank >= 2 then break end
                        end
                    end
                end
            end
        end
    elseif unit.kind == "s" and unit.code:match("^[a-z][a-z]$") then
        -- 完整音节：同码的所有读音（lo 同时是 lo/luo）的合法模糊变体。
        for _, syllable in ipairs(T.rev[unit.code] or {}) do
            for _, alt in ipairs(T.fuzzy[syllable] or {}) do
                if groups_enabled(alt.groups, groups) then
                    add(T.code[alt.alt], FUZZY_ALT_COST * (alt.cost > 0 and alt.cost or 1))
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.code < b.code
    end)
    return out
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
    -- 模糊音和未完成音节的补全备选只有全拼有。
    if env.layout ~= "quanpin" then
        ctx:set_property("nova_qp_pend", "")
        ctx:set_property("nova_qp_alt", "")
        ctx:set_property("nova_qp_fuzzy", "")
        return
    end
    local groups, signature = fuzzy_groups(ctx)
    local lines, merged = {}, {}
    for _, unit in ipairs(units) do
        local alts = unit_alternates(unit, groups)
        if #alts > 0 then
            local entry = merged[unit.code]
            if not entry then entry = { list = {}, seen = {} }; merged[unit.code] = entry end
            for _, alt in ipairs(alts) do
                if not entry.seen[alt.code] then
                    entry.seen[alt.code] = true
                    entry.list[#entry.list + 1] = alt
                end
            end
        end
    end
    for code, entry in pairs(merged) do
        table.sort(entry.list, function(a, b)
            if a.cost ~= b.cost then return a.cost < b.cost end
            return a.code < b.code
        end)
        local parts = {}
        for _, alt in ipairs(entry.list) do parts[#parts + 1] = string.format("%s,%.1f", alt.code, alt.cost) end
        lines[#lines + 1] = code .. ":" .. table.concat(parts, "|")
    end
    table.sort(lines)
    local last = units[#units]
    local pending = ""
    if last and last.kind == "p" and #last.code > 0 then
        -- 码长:输入长度:原始前缀。nova_sentences 用它区分“待定”和“完整音节”，
        -- 输入长度对上才算数，避免上一次输入残留的标记。
        pending = string.format("%d:%d:%s", #last.code, #(env.code or ctx.input), last.raw)
    end
    ctx:set_property("nova_qp_alt", table.concat(lines, ";"))
    ctx:set_property("nova_qp_fuzzy", signature)
    ctx:set_property("nova_qp_pend", pending)
end

local function reset(env, ctx)
    env.units, env.code = {}, ""
    if (ctx:get_property("nova_qp_raw") or "") ~= "" then
        ctx:set_property("nova_qp_raw", "")
        ctx:set_property("nova_qp_map", "")
    end
    if (ctx:get_property("nova_qp_alt") or "") ~= "" then ctx:set_property("nova_qp_alt", "") end
    if (ctx:get_property("nova_qp_pend") or "") ~= "" then ctx:set_property("nova_qp_pend", "") end
    if (ctx:get_property("nova_qp_fuzzy") or "") ~= "" then ctx:set_property("nova_qp_fuzzy", "") end
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
    -- 先同步发布输入相关的属性，再改 ctx.input。push_input/pop_input 内部就会触发候选过滤器，
    -- update notifier 要等这一轮处理完才跑。发布晚一步，过滤器就会把待定音节当成完整音节，
    -- 或者用上一键的备选。标记里的输入长度用新编码的长度，而不是还没更新的 ctx.input。
    publish(env, ctx)
    -- 只在末尾加字母、删字母时和双拼打字一样走 push_input / pop_input，不平移固定段。
    if new:sub(1, #old) == old and #new > #old then
        ctx:push_input(new:sub(#old + 1))
    elseif old:sub(1, #new) == new and #old > #new then
        ctx:pop_input(#old - #new)
    elseif old ~= new then
        tree_keys.replace_input(ctx, p, #old - p - q, inserted, inserted:match("^%u$") ~= nil)
    end
    if old == new then ctx:refresh_non_confirmed_composition() end
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
        if units[i].kind == "s" then prev = units[i].syl or units[i].raw break end
        if units[i].kind ~= "d" then break end
    end
    local new = {}
    for i = 1, lo - 1 do new[#new + 1] = units[i] end
    for _, unit in ipairs(tokenize(window, prev, after_abbr, env.layout, env.fuzzy)) do new[#new + 1] = unit end
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
        env.layout = layout_of(c)
        if not env.layout or not c:is_composing() then
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
    env.layout = layout_of(ctx)
    if not env.layout or ctx:get_option("ascii_mode") then return 2 end
    if env.layout == "quanpin" then
        local groups = fuzzy_groups(ctx)
        env.fuzzy = next(groups) and groups or nil
    else
        env.fuzzy = nil
    end
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
    publish(env, ctx)
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
    -- 微软、搜狗的 ing：跟在没打完的音节后面才是拼音。
    if code == SEMICOLON and env.layout ~= "quanpin" and not inside and units[#units] and units[#units].kind == "p"
        and T.sp[env.layout][units[#units].raw .. ";"] then
        edit(env, ctx, raw_length, 0, ";", true)
        return 1
    end
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

-- _tokenize / _load / _alternates 只给离线测试用。
return { init = init, func = func, fini = fini, _tokenize = tokenize, _load = load_table,
         _alternates = unit_alternates, _groups = fuzzy_groups }
