-- nova_phrases -- 日期时间和自定义短语。两种候选都以普通列表显示，不进词块树。
--
-- 日期时间：orq 日期、osj 时间、oxq 星期（和魔然相同）。这三串字母在自然码里不是音节，不会和打字冲突；
-- 由 recognizer 的 date 规则认出来，整段不走拼音解码。
--
-- 自定义短语：用户目录下的 nova_phrases.txt，每行 `文字<Tab>编码`，和 Rime 的 custom_phrase.txt 同一格式
-- （第三列权重可有可无，这里不用）。整段输入正好等于某个编码时，短语排在第一位，后面照常是拼音的候选。
-- 编码只能是小写字母。文件改了不用重新部署：打字时最多每 2 秒看一次文件，内容变了就重读。
--
-- 符号表：o 加类别名，如 ofh 符号、osx 数学，和 /fh、/sx 是同一份表（punctuator/symbols）。
-- 用户把 / 设成直接上屏顿号时 /fh 进不去，所以另给一个字母的入口。o 后面除了 o、u 都不成音节，
-- 不会和打字冲突；类别名以 o、u 开头的（/oe、/ue 这几组拉丁字母）和数字的（/1）因此没有 o 的入口。
-- orq、osj、oxq 先出日期时间，后面接 /rq、/sj、/xq 的符号。obq 先出 emoji，见 EMOJI。

local PHRASE_FILE = "nova_phrases.txt"
local CHECK_SECONDS = 2
local WEEKDAYS = { "日", "一", "二", "三", "四", "五", "六" }
local DIGITS = { [0] = "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九" }

-- 2026 → 二〇二六
local function digit_by_digit(number)
    return (tostring(number):gsub("%d", function(d) return DIGITS[tonumber(d)] end))
end

-- 1..99 → 一、十、十一、二十、三十一
local function chinese_number(n)
    if n < 10 then return DIGITS[n] end
    local tens, ones = n // 10, n % 10
    return (tens > 1 and DIGITS[tens] or "") .. "十" .. (ones > 0 and DIGITS[ones] or "")
end

local function date_texts(code, now)
    local t = os.date("*t", now)
    if code == "orq" then
        return {
            os.date("%Y-%m-%d", now),
            string.format("%d年%d月%d日", t.year, t.month, t.day),
            os.date("%Y/%m/%d", now),
            string.format("%d月%d日", t.month, t.day),
            os.date("%Y%m%d", now),
            digit_by_digit(t.year) .. "年" .. chinese_number(t.month) .. "月" .. chinese_number(t.day) .. "日",
        }
    elseif code == "osj" then
        return {
            os.date("%H:%M", now),
            os.date("%H:%M:%S", now),
            os.date("%Y-%m-%d %H:%M", now),
            os.date("%Y-%m-%d %H:%M:%S", now),
            string.format("%d点%02d分", t.hour, t.min),
        }
    elseif code == "oxq" then
        local day = WEEKDAYS[t.wday]
        return {
            "星期" .. day,
            "周" .. day,
            string.format("%d年%d月%d日 星期%s", t.year, t.month, t.day, day),
        }
    end
    return {}
end

-- { [编码] = { 文字, ... } }，同一编码按文件里的先后排。
local function parse_phrases(content)
    local phrases = {}
    for line in content:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            -- 编码后面只能是行尾或下一列：不然 `ab1` 会被当成 `ab`。
            local text, code, rest = line:match("^([^\t]+)\t([a-z]+)(.*)$")
            if text and (rest == "" or rest:match("^%s")) then
                local list = phrases[code]
                if not list then list = {}; phrases[code] = list end
                list[#list + 1] = text
            end
        end
    end
    return phrases
end

local function load_phrases(env)
    local now = os.time()
    if env.checked and now - env.checked < CHECK_SECONDS then return end
    env.checked = now
    local file = io.open(env.path, "r")
    local content = file and file:read("a") or ""
    if file then file:close() end
    if content == env.content then return end
    env.content = content
    env.phrases = parse_phrases(content)
end

-- obq（表情）：常用 emoji 排在 /bq 原有的 ☻☺☹ 前面。先脸、再手势、心、节庆物件、花果动物，大致按使用频率。
local EMOJI = {
    "😂", "🤣", "😭", "😊", "😁", "😅", "😆", "😄", "😀", "😃", "🙂", "🙃", "😉", "😍", "🥰", "😘", "😚", "😋", "😜", "😝", "😛",
    "🤪", "🤗", "🤭", "🤔", "🤨", "🧐", "😏", "😌", "😎", "🥳", "🤩", "😇", "🥺", "😢", "😥", "😓", "😔", "😞", "😟", "😕", "🙁",
    "☹️", "😣", "😖", "😫", "😩", "😤", "😠", "😡", "🤬", "😱", "😨", "😰", "😳", "😲", "😮", "😯", "😬", "🙄", "😒", "😑", "😐",
    "😶", "🤐", "🥱", "😴", "🤤", "😪", "🥴", "🤢", "🤮", "🤧", "😷", "🤒", "🥵", "🥶", "😈", "💀", "💩", "🤡", "👻", "🙈", "🙉",
    "🙊", "😹", "😻", "👍", "👎", "👌", "👏", "🙏", "🤝", "💪", "👊", "✊", "✌️", "🤞", "🤟", "🤘", "🤙", "👋", "🙌", "👐", "🤲",
    "👉", "👈", "👆", "👇", "☝️", "✋", "🫡", "🤦", "🤷", "🙋", "🙇", "💃", "🏃", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤",
    "🤍", "💔", "💕", "💞", "💓", "💗", "💖", "💘", "💝", "💋", "🎉", "🎊", "🎈", "🎁", "🎂", "🧧", "🏮", "🧨", "🔥", "✨", "🌟",
    "⭐", "💯", "💥", "💦", "💤", "💰", "👀", "👑", "✅", "❌", "❗", "❓", "⚡", "☀️", "🌙", "🌈", "🌹", "🌸", "🌺", "🌻", "🌷",
    "🍀", "🍉", "🍎", "🍓", "🍺", "🍻", "☕", "🍵", "🐶", "🐱", "🐰", "🐼", "🐷", "🐮", "🐯", "🐲", "🦋", "🀄",
}

-- { ["ofh"] = { "©", "®", ... } }，取自方案的 punctuator/symbols。
local function load_symbols(config)
    local symbols = {}
    local map = config:get_map("punctuator/symbols")
    if not map then return symbols end
    for _, key in ipairs(map:keys()) do
        local name = key:match("^/([a-z]+)$")
        if name and not name:match("^[ou]") then
            local list = map:get(key):get_list()
            local texts = {}
            for i = 0, (list and list.size or 0) - 1 do
                local value = list:get_value_at(i)
                if value and value.value ~= "" then texts[#texts + 1] = value.value end
            end
            if #texts > 0 then symbols["o" .. name] = texts end
        end
    end
    local faces = {}
    for _, e in ipairs(EMOJI) do faces[#faces + 1] = e end
    for _, e in ipairs(symbols["obq"] or {}) do faces[#faces + 1] = e end
    symbols["obq"] = faces
    return symbols
end

local function init(env)
    env.path = rime_api.get_user_data_dir() .. "/" .. PHRASE_FILE
    env.phrases = {}
    env.symbols = load_symbols(env.engine.schema.config)
    load_phrases(env)
end

local function func(input, seg, env)
    if seg:has_tag("date") then
        for _, text in ipairs(date_texts(input, os.time())) do
            yield(Candidate("date", seg.start, seg._end, text, ""))
        end
        for _, text in ipairs(env.symbols[input] or {}) do
            yield(Candidate("date", seg.start, seg._end, text, ""))
        end
        return
    end
    if not seg:has_tag("abc") then return end
    load_phrases(env)
    for _, texts in ipairs({ env.phrases[input] or {}, env.symbols[input] or {} }) do
        for _, text in ipairs(texts) do
            local cand = Candidate("nova_phrase", seg.start, seg._end, text, "")
            -- 排在拼音整句前面：候选先比覆盖的长度，再比 quality。
            cand.quality = 1000
            yield(cand)
        end
    end
end

return { init = init, func = func }
