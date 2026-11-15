-- nova_bounds -- 学到的词块边界。
-- 用户用 [ ] 伸缩过一个词块再上屏，边界两侧的两块记进用户目录下的 nova_bounds.txt，每行：
--   左编码<Tab>左文字<Tab>右编码<Tab>右文字
-- 编码是不带辅助码的双拼，音节连写（he、ugwz）。下次打到同一串编码、两头又正好落在解码器的
-- 词边界上时，nova_sentences 直接按这条切，见它的 apply_bounds。用户把学到的切法改掉再上屏，
-- nova_tree_keys 把这条删掉，见它的 learn_bounds。
-- 同一个会话里 nova_sentences 和 nova_tree_keys 共用这张表；别的会话写的，隔几秒重读文件拿到。
local M = {}

local FILE = "nova_bounds.txt"
local CHECK_SECONDS = 3
local MAX_ENTRIES = 2000   -- 超过时丢掉最早学的
local MAX_SYLLABLES = 6    -- 一块最多几个音节，和 nova_sentences 查词的最长词一致
-- 两块加起来至少几个音节。两个单字之间的边界不学：切法只有这一种，要改的是字，那归用户词库。
local MIN_SYLLABLES = 3

local entries = {}  -- 按学到的先后
local index = {}    -- 左编码的第一个音节 → 这些条目，长的在前
local content, checked

local function key_of(left, right)
    return left .. "\t" .. right
end

local function valid_block(code, text)
    return code:match("^%l+$") and #code % 2 == 0 and #code <= MAX_SYLLABLES * 2
        and not text:find("[%c]") and utf8.len(text) == #code / 2
end

local function valid(left, ltext, right, rtext)
    return valid_block(left, ltext) and valid_block(right, rtext) and #left + #right >= MIN_SYLLABLES * 2
end

local function rebuild()
    index = {}
    for _, entry in ipairs(entries) do
        local first = entry.left:sub(1, 2)
        index[first] = index[first] or {}
        table.insert(index[first], entry)
    end
    for _, list in pairs(index) do
        table.sort(list, function(a, b) return #a.left + #a.right > #b.left + #b.right end)
    end
end

local function parse(text)
    local all, last = {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local left, ltext, right, rtext = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$")
        if left and valid(left, ltext, right, rtext) then
            local key = key_of(left, right)
            all[#all + 1] = { left = left, ltext = ltext, right = right, rtext = rtext, key = key }
            last[key] = #all
        end
    end
    -- 同一串编码只留最后一条。
    local list = {}
    for i, entry in ipairs(all) do
        if last[entry.key] == i then list[#list + 1] = entry end
    end
    return list
end

local function path()
    return rime_api.get_user_data_dir() .. "/" .. FILE
end

local function load(force)
    local now = os.time()
    if not force and checked and now - checked < CHECK_SECONDS then return end
    checked = now
    local file = io.open(path(), "r")
    local text = file and file:read("a") or ""
    if file then file:close() end
    if text == content then return end
    content = text
    entries = parse(text)
    rebuild()
end

local function save()
    while #entries > MAX_ENTRIES do table.remove(entries, 1) end
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = table.concat({ entry.left, entry.ltext, entry.right, entry.rtext }, "\t")
    end
    local text = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
    -- 先写到旁边再改名，别的会话不会读到写了一半的文件。
    local temp = path() .. ".tmp"
    local file = io.open(temp, "w")
    if not file then return end
    file:write(text)
    file:close()
    if not os.rename(temp, path()) then os.remove(temp) return end
    content = text
    rebuild()
end

-- 左编码第一个音节是 pair 的条目，长的在前。
function M.starting_with(pair)
    load(false)
    return index[pair]
end

function M.put(left, ltext, right, rtext)
    if not valid(left, ltext, right, rtext) then return end
    load(true)
    local key = key_of(left, right)
    for i, entry in ipairs(entries) do
        if entry.key == key then
            if entry.ltext == ltext and entry.rtext == rtext then return end
            table.remove(entries, i)
            break
        end
    end
    entries[#entries + 1] = { left = left, ltext = ltext, right = right, rtext = rtext, key = key }
    save()
end

function M.drop(key)
    load(true)
    for i, entry in ipairs(entries) do
        if entry.key == key then
            table.remove(entries, i)
            save()
            return
        end
    end
end

M.key_of = key_of

return M
