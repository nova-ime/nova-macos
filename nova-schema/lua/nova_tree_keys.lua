-- nova_tree_keys -- 数字键固定树状候选里的一块，不上屏。其余部分由 nova_sentences 重新解码。

local function clear(ctx)
    ctx:set_property("nova_pins", "")
    ctx:set_property("nova_tree", "")
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

-- 第 label 个备选所在的块。
local function find_label(tree, label)
    local count = 0
    for line in tree:gmatch("[^\n]+") do
        local fields = {}
        for field in line:gmatch("[^\t]+") do fields[#fields + 1] = field end
        for i = 6, #fields do
            count = count + 1
            if count == label then
                return fields[2], fields[3], fields[4], fields[i]
            end
        end
    end
end

local function func(key, env)
    if not env.enabled or key:release() or key:ctrl() or key:alt() or key:super() then return 2 end
    local code = key.keycode
    if code < 0x31 or code > 0x39 then return 2 end
    local ctx = env.engine.context
    if not ctx:is_composing() then return 2 end
    local from, to, keys, text = find_label(ctx:get_property("nova_tree") or "", code - 0x30)
    if not from then return 2 end
    local pins = ctx:get_property("nova_pins") or ""
    ctx:set_property("nova_pins", pins .. string.format("%s:%s:%s:%s\n", from, to, keys, text))
    ctx:refresh_non_confirmed_composition()
    return 1
end

return { init = init, func = func, fini = fini }
