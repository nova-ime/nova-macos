-- nova_words -- 用 ] 并出来的词，记过几次。
-- 用户用 ] 把几个音节并成一块再上屏，这个词先在用户目录下的 nova_words.txt 记一次，每行：
--   编码<Tab>文字<Tab>次数
-- 编码是不带辅助码的双拼，音节连写（lqrs），和 nova_bounds.txt 一样。这个文件不进用户词库，解码器也不读它，
-- 所以记的这几次不影响排序。同一个词记满次数后，nova_tree_keys 把它写进用户词库、从这里删掉，
-- 见它的 learn_words；Shift+Delete 删词时也会删掉这里还没记满的，见它的 delete_word。
-- 文件读写照 nova_bounds：隔几秒重读，先写临时文件再改名。
local M = {}

local FILE = "nova_words.txt"
local CHECK_SECONDS = 3
local MAX_ENTRIES = 2000   -- 超过时丢掉最早记的
local MAX_SYLLABLES = 6    -- 一个词最多几个音节，和 nova_sentences 查词的最长词一致

local entries = {}  -- 按记的先后，每记一次移到末尾
local content, checked

local function key_of(code, text)
    return code .. "\t" .. text
end

local function valid(code, text)
    return code:match("^%l+$") and #code % 2 == 0 and #code >= 4 and #code <= MAX_SYLLABLES * 2
        and not text:find("[%c]") and utf8.len(text) == #code / 2
end

local function parse(text)
    local all, last = {}, {}
    for line in text:gmatch("[^\r\n]+") do
        local code, word, count = line:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
        if code and valid(code, word) then
            local key = key_of(code, word)
            all[#all + 1] = { code = code, text = word, count = tonumber(count), key = key }
            last[key] = #all
        end
    end
    -- 同一个词只留最后一行。
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
    local data = file and file:read("a") or ""
    if file then file:close() end
    if data == content then return end
    content = data
    entries = parse(data)
end

local function save()
    while #entries > MAX_ENTRIES do table.remove(entries, 1) end
    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = table.concat({ entry.code, entry.text, entry.count }, "\t")
    end
    local data = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
    -- 先写到旁边再改名，别的会话不会读到写了一半的文件。
    local temp = path() .. ".tmp"
    local file = io.open(temp, "w")
    if not file then return end
    file:write(data)
    file:close()
    if not os.rename(temp, path()) then os.remove(temp) return end
    content = data
end

-- 记一次，这一行移到末尾，返回现在的次数。
function M.bump(code, text)
    if not valid(code, text) then return 0 end
    load(true)
    local key, count = key_of(code, text), 0
    for i, entry in ipairs(entries) do
        if entry.key == key then
            count = entry.count
            table.remove(entries, i)
            break
        end
    end
    count = count + 1
    entries[#entries + 1] = { code = code, text = text, count = count, key = key }
    save()
    return count
end

-- 删掉这个词的记录；没有就什么也不做。
function M.remove(code, text)
    load(true)
    local key = key_of(code, text)
    for i, entry in ipairs(entries) do
        if entry.key == key then
            table.remove(entries, i)
            save()
            return
        end
    end
end

return M
