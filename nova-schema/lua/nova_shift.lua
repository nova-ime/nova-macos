-- nova_shift -- 全拼时用 Shift 切英文，先上屏用户实际打的字母。
-- 全拼在引擎里的输入已经换成了双拼码（git 会变成 yi+t），ascii_composer 的
-- commit_code 会把 yit 写进正文。这里放在 ascii_composer 前面，只接管
-- “正在打全拼、按 Shift”的情况；其他情况原样交给 ascii_composer。

local SHIFT_L, SHIFT_R = 0xffe1, 0xffe2

local function func(key, env)
    local code = key.keycode
    local ctx = env.engine.context
    if code ~= SHIFT_L and code ~= SHIFT_R then
        -- Shift 按住时又按了别的键（比如 Shift+字母打大写辅助码），
        -- 这次 Shift 就不是切换英文。
        if env.shift and not key:release() then env.shift.used = true end
        return 2
    end
    if key:ctrl() or key:alt() or key:super() then
        env.shift = nil
        return 2
    end
    -- 只接管全拼正在输入的时候；其余（双拼、英文模式、没在输入）交给 ascii_composer。
    if not ctx:get_option("quanpin") or ctx:get_option("ascii_mode") or not ctx:is_composing() then
        env.shift = nil
        return 2
    end
    if key:release() then
        local shift = env.shift
        env.shift = nil
        if not shift then return 2 end
        if shift.used then return 1 end
        local raw = ctx:get_property("nova_qp_raw") or ""
        env.engine:commit_text(raw ~= "" and raw or ctx.input)
        ctx:clear()
        ctx:set_option("ascii_mode", true)
        return 1
    end
    env.shift = { used = false }
    return 1
end

return { func = func }
