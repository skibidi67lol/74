--[[
    DEADLINE 0.25.2 — RUNTIME ANTICHEAT BYPASS  v3  (Potassium / Syllinse)
    ======================================================================
    Запускается В ЛЮБОЙ МОМЕНТ (FirstLoad, до MacLib:Window).

    ЧТО ИЗМЕНИЛОСЬ ПРОТИВ v2 (почему раньше чернел экран при MacLib UI):
      * Корень чёрного экрана — цепочка _cpr:
          MacLib -> его иконки живут в CoreGui/gethui ->
          loading_gui корутина зовёт ContentProvider:PreloadAsync({CoreGui})
          -> на каждый rbxassetid:// шлёт loading_status:FireServer("_cpr "..id)
          -> сервер флагует -> тамперит loading_status
          -> reparent-guard видит (loading_status.Parent).Parent ~= ReplicatedStorage
          -> Workspace:ClearAllChildren() + troll()  = ЧЁРНЫЙ ЭКРАН + фриз.
      * ClearAllChildren и PreloadAsync в loading_gui вызываются COLON-формой
        (self:Method(...)) -> идут через NAMECALL. Хук на function-value их
        пропускает. Теперь оба ловятся в едином __namecall-хуке (как FireServer).
      * Убран SANCTION_MARKS(filtergc+hookfunction по "_cpr"/"ORGANIZATION"/":D"):
        это тела УЖЕ запущенных корутин, хук по ссылке на них = no-op.
        Заменено на надёжный перехват самих вызовов -> сервер про MacLib не узнаёт,
        значит reparent-guard/troll/ClearAllChildren не срабатывают в принципе.

    ЧТО ОСТАЁТСЯ (проверено рабочим в v2 — сохранено):
      [L1] 3 freeze-трапа getfenv->"kill yourself"->while true (caster/NetworkEncode/util)
           — это ПЕРЕвызываемые функции горячего пути, hookfunction по ним валиден.
      [L2] report-канал loading_status:FireServer(code) + userdata-приманка + logscan.
      [L5] secondary_replication_timer (FPC_extend) — packet 1,2,4-10 глушим через next_time=huge.

    ГРАНИЦА: серверная валидация хитов (HitregManager rollback 190мс) остаётся —
    снимаем клиентский детект/фризы/бан-репорты, но не даём невозможные хиты.
--]]

if getgenv().__dl_bypass_v4 then
    -- уже активен — НЕ рисуем арт заново, только короткая строка статуса
    local s = getgenv().__dl_bypass_status
    if s then pcall(s, "bypass already active") end
    return
end
getgenv().__dl_bypass_v4 = true

--// быстрые ссылки (захватываем ДО любых хуков)
local typeof, type      = typeof, type
local ipairs, pairs     = ipairs, pairs
local pcall             = pcall
local rawget, rawset    = rawget, rawset
local sfind             = string.find
local genv, renv        = getgenv(), getrenv()

--======================================================================
--  КОНСОЛЬНЫЙ ВЫВОД  —  ТОЛЬКО ASCII-баннер + короткий статус.
--  Приватные копии консоли: глобалку rconsole* занулим (это tell-канал),
--  а свой вывод оставим рабочим через PRIV.
--======================================================================
local PRIV = {}
local function raw_out(s)
    local f = PRIV.rconsoleprint or rconsoleprint
    if f then pcall(f, s) else pcall(print, s) end
end
local function line(s) raw_out(tostring(s) .. "\n") end

local BANNER = {
    [[ .oooooo..o             oooo  oooo   o8o                                 ]],
    [[d8P'    `Y8             `888  `888   `"'                                 ]],
    [[Y88bo.      oooo    ooo  888   888  oooo  ooo. .oo.    .oooo.o  .ooooo.  ]],
    [[ `"Y8888o.   `88.  .8'   888   888  `888  `888P"Y88b  d88(  "8 d88' `88b ]],
    [[     `"Y88b   `88..8'    888   888   888   888   888  `"Y88b.  888ooo888 ]],
    [[oo     .d8P    `888'     888   888   888   888   888  o.  )88b 888    .o ]],
    [[8""88888P'      .8'     o888o o888o o888o o888o o888o 8""888P' `Y8bod8P' ]],
    [[            .o..P'                                                       ]],
    [[            `Y8P'                                                        ]],
}
-- ASCII-арт печатаем РОВНО ОДИН РАЗ за сессию (глобальный флаг).
local function banner_art()
    if rawget(genv, "__dl_banner_shown") then return end
    pcall(rawset, genv, "__dl_banner_shown", true)
    for _, l in ipairs(BANNER) do line(l) end
end
-- статус-строки — простой текст под артом (init / done / warn / already)
local function status(msg) line(tostring(msg)) end
pcall(rawset, genv, "__dl_bypass_status", status)

banner_art()
status("bypass init")

--// общий C-noop для замен (newcclosure = антидетект islclosure/isexecutorclosure)
local NOOP = newcclosure(function() end)
pcall(setstackhidden, NOOP, true)

-- накопитель проблем: если критичное не встало — скажем "warn" внизу
local warns = {}
local function warn(s) warns[#warns + 1] = s end

----------------------------------------------------------------------
-- L1 — убить 3 freeze-детектора прямо в GC (переизобретаемые функции).
-- filtergc по общей константе "kill yourself"; каждое getenv-замыкание -> no-op.
-- Это функции горячего пути (u1.fire на выстрел, compress_* на пакет,
-- map_clamped на сжатие позиции) — они ПЕРЕвызываются, значит hookfunction валиден.
----------------------------------------------------------------------
local killed, seen = 0, 0
pcall(function()
    local found = filtergc("function", {
        Constants      = { "kill yourself" },
        IgnoreExecutor = true,
    }, false)
    if type(found) == "table" then
        for _, fn in ipairs(found) do
            if type(fn) == "function" then
                seen += 1
                local skip = false
                if isexecutorclosure then
                    local okE, isOurs = pcall(isexecutorclosure, fn)
                    if okE and isOurs then skip = true end
                end
                if not skip and pcall(hookfunction, fn, NOOP) then
                    killed += 1
                end
            end
        end
    end
end)
-- общий маркер: suite/movement/vision не хукают эти же 3 замыкания повторно
pcall(rawset, genv, "__dl_genv_traps_killed", killed)
if killed < 3 then
    warn(("freeze traps %d/3 (util-trap fires 1%% per position compress; re-run FIRST)")
        :format(killed))
end

-- вычистить tell-канал rconsole* из окружений (свои копии держим в PRIV)
local TELLS = {
    "rconsoleprint","rconsolewarn","rconsoleinfo","rconsoleerr","rconsoleerror",
    "rconsolename","rconsolesettitle","rconsolecreate","rconsoledestroy",
    "rconsoleclear","rconsoleinput","printconsole","consoleprint",
}
local function scrub(tbl)
    if type(tbl) ~= "table" then return end
    for _, k in ipairs(TELLS) do
        local v = rawget(tbl, k)
        if v ~= nil then
            PRIV[k] = PRIV[k] or v
            rawset(tbl, k, nil)
        end
    end
end
pcall(scrub, genv)
pcall(scrub, renv)

----------------------------------------------------------------------
-- L2 — единый перехват: report-канал + приманка + ЧЁРНЫЙ ЭКРАН.
-- Ловим ДВА пути диспетчеризации:
--   (a) dot-форма  self.Method(self, x)  -> хук function-value (oth.hook / hookfunction)
--   (b) colon-форма self:Method(x)       -> __namecall  (в loading_gui именно так!)
-- Через один __namecall закрываем р��зом:
--   FireServer      : report-коды (_genv/_i/_ri/_rt/_rq/_ls/_cpr/"1"), userdata-приманка,
--                     reparent-broadcast "THE ORGANIZATION HAS FOUND US"
--   PreloadAsync    : скан {CoreGui} -> ЭТО источник _cpr про MacLib. Режем в корне.
--   ClearAllChildren: на Workspace -> сам чёрный экран. Режем как fallback.
----------------------------------------------------------------------
local ws = workspace

-- список аргументов PreloadAsync содержит CoreGui? (сравнение по ClassName —
-- устойчиво к cloneref, ссылки могут не совпасть)
local function list_has_coregui(list)
    if type(list) ~= "table" then return false end
    for _, inst in ipairs(list) do
        local ok, cn = pcall(function() return inst.ClassName end)
        if ok and cn == "CoreGui" then return true end
    end
    return false
end

-- фильтр FireServer: true => проглотить вызов (не пускать на сервер)
local function fs_swallow(self, first)
    -- ВАЖНО: не typeof() — у приманки loading_gui есть __type, дёргающий troll().
    -- type() метаметоды не читает и для newproxy честно даёт "userdata".
    if type(first) == "userdata" then
        return true -- newproxy-приманка
    end
    if type(first) == "string" then
        local ok, nm = pcall(function() return self.Name end)
        if ok and nm == "loading_status" then
            return true -- любой report-код на honeypot-канал
        end
        if sfind(first, "ORGANIZATION", 1, true) then
            return true -- reparent-guard broadcast
        end
    end
    return false
end

-- (a) dot-форма FireServer: хук самой C-функции (oth.hook = антидетект vs isfunctionhooked)
local base_fs
pcall(function()
    local t = Instance.new("RemoteEvent")
    base_fs = t.FireServer
    t:Destroy()
end)
local fs_mode = "none"
if base_fs and oth and oth.hook then
    local old_fs
    old_fs = oth.hook(base_fs, function(self, ...)
        if fs_swallow(self, (...)) then return end
        return old_fs(self, ...)
    end)
    fs_mode = "oth.hook"
elseif base_fs then
    local old_fs
    old_fs = hookfunction(base_fs, newcclosure(function(self, ...)
        if fs_swallow(self, (...)) then return end
        return old_fs(self, ...)
    end))
    fs_mode = "hookfunction"
end

-- (b) ЕДИНЫЙ __namecall: FireServer(colon) + PreloadAsync(colon) + ClearAllChildren(colon)
local nc_mode = "none"
pcall(function()
    local old_nc
    old_nc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local m = getnamecallmethod()
        if m == "FireServer" then
            if fs_swallow(self, (...)) then return end
        elseif m == "PreloadAsync" then
            -- скан интерфейса в CoreGui: не выполняем -> нет _cpr про MacLib,
            -- сервер не флагует, вся цепочка чёрного экрана обрывается здесь.
            if list_has_coregui((...)) then return end
        elseif m == "ClearAllChildren" then
            if self == ws then return end -- не даём стереть мир
        end
        return old_nc(self, ...)
    end))
    nc_mode = "on"
end)
if nc_mode ~= "on" then
    warn("namecall hook failed — colon-form guards inactive")
end

-- (c) dot-форма fallback для PreloadAsync и ClearAllChildren
--     (на случай, если игра где-то зовёт их не через namecall)
local preload_guard = "none"
pcall(function()
    local CP = cloneref and cloneref(game:GetService("ContentProvider"))
        or game:GetService("ContentProvider")
    local base_pre = CP.PreloadAsync
    if type(base_pre) ~= "function" then return end
    local old_pre
    local function guard(self, list, ...)
        if list_has_coregui(list) then return end
        return old_pre(self, list, ...)
    end
    if oth and oth.hook then
        old_pre = oth.hook(base_pre, guard); preload_guard = "oth.hook"
    else
        old_pre = hookfunction(base_pre, newcclosure(guard)); preload_guard = "hookfunction"
    end
end)

local clear_guard = "none"
pcall(function()
    local probe = Instance.new("Folder")
    local base_clear = probe.ClearAllChildren
    probe:Destroy()
    if type(base_clear) ~= "function" then return end
    local old_clear
    local function guard(self, ...)
        if self == ws then return end
        return old_clear(self, ...)
    end
    if oth and oth.hook then
        old_clear = oth.hook(base_clear, guard); clear_guard = "oth.hook"
    else
        old_clear = hookfunction(base_clear, newcclosure(guard)); clear_guard = "hookfunction"
    end
end)

-- чистильщик: если troll успел раскидать BodyVelocity "lolidiot" ДО запуска обхода
local function sweep_lolidiot()
    local n = 0
    pcall(function()
        for _, d in ipairs(ws:GetDescendants()) do
            if d.Name == "lolidiot" and d:IsA("BodyMover") then
                pcall(function() d:Destroy() end)
                n += 1
            end
        end
    end)
    return n
end

----------------------------------------------------------------------
-- L3 — LogService.MessageOut honeypot (logscan _ls). Глушим НЕ-наши коннекты.
-- В цикле: игра регистрирует новые обработчики на спавне/смене карты.
----------------------------------------------------------------------
local LogSvc
pcall(function()
    LogSvc = cloneref and cloneref(game:GetService("LogService")) or game:GetService("LogService")
end)
local function patch_logscan()
    if not LogSvc then return 0 end
    local n = 0
    pcall(function()
        for _, c in ipairs(getconnections(LogSvc.MessageOut)) do
            local mine = isourthread and c.Thread and isourthread(c.Thread)
            local live = true
            local okE, en = pcall(function() return c.Enabled end)
            if okE and en == false then live = false end
            if not mine and live then
                if pcall(function() c:Disable() end) then n += 1 end
            end
        end
    end)
    return n
end
patch_logscan()

----------------------------------------------------------------------
-- L5 — вторая система детекта (FirstPersonController_extend, ~стр.680-800).
-- secondary_replication_timer каждые ~5с вшивает детект-пакеты в
-- replication:FireServer. Дропать нельзя (сломается движение) -> глушим таймер:
--   Timer.expired() = (next_time < get_time())  -> next_time=huge => НИКОГДА.
-- Убивает packet 1 (скан PlayerGui), 2 (bodymovers на torso), 4 (вес),
-- 5/6 (velocity), 7 (rpm>1500), 8 (dirty_properties), 9 (_G.actor_started), 10 (stop).
-- Packet 3 (torso_hitbox) вне таймера -> просто не трогаем хитбокс.
-- Контроллер пересоздаётся на респавне -> переставляем в цикле.
----------------------------------------------------------------------
local HUGE = math.huge
local sec_patched = 0
local function patch_secondary()
    local ok, found = pcall(filtergc, "table", { Keys = { "secondary_replication_timer" } }, false)
    if not ok or type(found) ~= "table" then return end
    for _, ctrl in ipairs(found) do
        local t = rawget(ctrl, "secondary_replication_timer")
        if type(t) == "table" and rawget(t, "next_time") ~= HUGE then
            pcall(function() t.next_time = HUGE; t.timeout = HUGE end)
            sec_patched += 1
        end
    end
end
pcall(function() if _G.actor_started then _G.actor_started = nil end end)
pcall(patch_secondary)
sweep_lolidiot()

-- фоновый резервный цикл (БЕЗ вывода в консоль — тихо держит оборону)
task.spawn(function()
    while true do
        task.wait(2)
        pcall(patch_secondary)
        patch_logscan()
        if rawget(_G, "actor_started") then pcall(function() _G.actor_started = nil end) end
        sweep_lolidiot()
    end
end)

----------------------------------------------------------------------
--  ИТОГ  —  один короткий статус. Всё зелёное => "bypass done".
----------------------------------------------------------------------
-- критичное для чёрного экрана: namecall-хук обязан стоять
if nc_mode ~= "on" then
    warn("black-screen guard weak (no namecall)")
end

if #warns == 0 then
    status("bypass done")
else
    -- арт уже нарисован при init; печатаем только строки статуса
    status("bypass done (with warnings):")
    for _, w in ipairs(warns) do status("  warn: " .. w) end
end

--======================================================================
--  LOADER MODULE (Syllinse) — без UI. stop() намеренно НЕ снимает хуки:
--  un-hook пере-взвёл бы freeze-трапы и report-канал.
--======================================================================
return {
    start = function() end,
    stop  = function() end,
}
