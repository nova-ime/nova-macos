-- 反引号引导的小写辅助码：ni`re 和 niRE 一样，是「你」。
-- 正在输入时按 ` 不上屏，接下来的两个小写字母换成大写，再交给后面的处理器，
-- 走的是大写辅助码原来的路径（全拼、别家双拼的换键层，词块树，选字）。
-- 只接两个字母：辅助码是两分。中途按了别的键（数字、空格、退格等），引导作废，那个键照常处理。
-- 没在输入时按 `，不拦，照旧出符号。

local GRAVE = 0x60

local function init(env)
    env.pending = 0
end

local function func(key, env)
    -- 自己换出来的大写字母重入时直接放行，不动 pending。
    if env.injecting or key:release() then return 2 end
    local ctx = env.engine.context
    local code = key.keycode
    if key:alt() or key:super() or key:ctrl() or ctx:get_option("ascii_mode") then
        env.pending = 0
        return 2
    end
    if code == GRAVE and not key:shift() then
        if not ctx:is_composing() then
            env.pending = 0
            return 2
        end
        env.pending = 2
        return 1
    end
    if env.pending > 0 and code >= 0x61 and code <= 0x7a and not key:shift() then
        env.pending = env.pending - 1
        -- 换成大写重新送进引擎，走大写辅助码原来的路径。
        env.injecting = true
        env.engine:process_key(KeyEvent(string.upper(string.char(code))))
        env.injecting = false
        return 1
    end
    -- Shift 单独按下也会经过这里，不算打断。
    if code ~= 0xffe1 and code ~= 0xffe2 then env.pending = 0 end
    return 2
end

return { init = init, func = func }
