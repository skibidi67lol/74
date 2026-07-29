--[[
    DEADLINE 0.25.2 — RUNTIME ANTICHEAT BYPASS  v2  (Potassium)
    ======================================================================
    Запускается В ЛЮБОЙ МОМЕНТ (не autoexec). Ключевая идея:
      игра nil-parent'ит loading_gui и прячет детекторы, НО они живут в
      РАНТАЙМЕ — замыкания в GC и корутины в памяти. "Статически нет" != "нет".
      Поэтому находим их в живой памяти и глушим на месте.

    ЦЕЛИ (все вскрыты в дампе, все — рантайм-резиденты):
      [1] 3 freeze-детектора getfenv->rconsoleprint->"kill yourself"->while true do end
            module/caster/caster.lua   (u1.fire, каждый выстрел)
            module/namespace/NetworkEncode (write_exact_position/compress_* — каждый пакет)
            module/util/lua/util.lua   (map_clamped/copy_table/spherecast_between, шанс 1%)
          -> ищем по общей константе "kill yourself" через filtergc, no-op'аем.
      [2] report-канал actions.loading_status:FireServer(code)  (_genv/_i/_ri/_rt/_rq/_ls/_cpr/"1")
          + newproxy-приманка loading_gui (шлётся через одноразовый RemoteEvent)
          -> oth.hook на C-функцию FireServer (антидетект vs isfunctionhooked),
             глотаем строковые коды на loading_status и любой userdata-аргумент (приманку).
      [3] LogService.MessageOut блэклист {"Xeno.Scripts","aim toggled on"}
          -> getconnections -> :Disable() игровых коннектов.

    ГРАНИЦА: сервер (HitregManager, rollback 190мс) валидирует хиты сам —
    это снимает КЛИЕНТСКИЙ детект/фризы/бан-репорты, но не даёт слать
    невозможные хиты.
--]]

if getgenv().__dl_bypass_v4 then return end
getgenv().__dl_bypass_v4 = true

--// быстрые ссылки (захватываем ДО любых хуков)
local typeof, type      = typeof, type
local ipairs, pcall     = ipairs, pcall
local rawget, rawset    = rawget, rawset
local sfind             = string.find
local genv, renv        = getgenv(), getrenv()

--// приватные копии консоли — глобалку занулим, свой вывод оставим рабочим
local PRIV = {}
local function log(msg)
    local f = PRIV.rconsoleprint or rconsoleprint or print
    pcall(f, "[dl_bypass] " .. msg)
end

--// общий C-noop для замен (newcclosure = антидетект islclosure/isexecutorclosure)
local NOOP = newcclosure(function() end)
pcall(setstackhidden, NOOP, true)

----------------------------------------------------------------------
-- LAYER 1  — убить 3 freeze-детектора прямо в GC (рантайм-резиденты).
-- filtergc по общей константе "kill yourself"; IgnoreExecutor чтобы не
-- зацепить свои замыкания. Каждое найденное getenv-замыкание -> no-op.
----------------------------------------------------------------------
--[[
    ОЖИДАЕМОЕ ЧИСЛО — РОВНО 3. Проверено по дампу: константа "kill yourself"
    встречается в трёх файлах и по одному разу в каждом:
        module/namespace/NetworkEncode:12   (for i = 0, 9   + FireServer("_genv"))
        module/caster/caster:404            (for i = 1, 10, без доклада)
        module/util/lua/util:10             (for i = 1, 10  + FireServer("_genv"),
                                            но под if math.random(1,100) ~= 100)
    Если хукнули меньше трёх — часть ловушек ЖИВА, и та, что из util, рано или
    поздно выстрелит (1% на каждый map_clamped, то есть на каждое сжатие
    позиции). Поэтому об этом сообщаем явно, а не молчим.
--]]
local killed, seen = 0, 0
pcall(function()
    local found = filtergc("function", {
        Constants     = { "kill yourself" },
        IgnoreExecutor = true,
    }, false)
    if type(found) == "table" then
        for _, fn in ipairs(found) do
            if type(fn) == "function" then
                seen += 1
                --[[ Фильтры islclosure/isexecutorclosure применяем ТОЛЬКО если
                     они есть: иначе на сборках, где их нет, мы молча
                     пропускали бы все три ловушки. ]]
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

--[[
    ОБЩИЙ МАРКЕР ДЛЯ ОСТАЛЬНЫХ СКРИПТОВ.
    suite/movement/vision тоже умеют глушить эти ловушки (чтобы быть
    самодостаточными). Но хукать одни и те же три замыкания четыре раза —
    лишний риск на функциях горячего пути. Поэтому обход, отработав первым,
    оставляет метку, и остальные её просто читают.
--]]
pcall(rawset, genv, "__dl_genv_traps_killed", killed)

-- Сеть безопасности: вычистить сам tell из окружений (на случай копии,
-- которую filtergc не увидел). rconsoleprint для себя держим в PRIV.
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
-- LAYER 2  — report-канал + приманка через oth.hook(FireServer).
-- FireServer это C-функция -> oth.hook (off-thread) обходит isfunctionhooked.
-- Ловит ОБА вида вызова honeypot ( :FireServer и .FireServer(self,x) ).
----------------------------------------------------------------------
local base_fs
pcall(function()
    local t = Instance.new("RemoteEvent")
    base_fs = t.FireServer
    t:Destroy()
end)

local function fs_filter(self, first)
    -- приманка loading_gui: сырой newproxy -> typeof == "userdata"
    -- (легитимные remotes так не шлют: у них buffer/table/Vector3/Instance)
    if typeof(first) == "userdata" then
        return true
    end
    if type(first) == "string" then
        local ok, nm = pcall(function() return self.Name end)
        if ok and nm == "loading_status" then
            return true
        end
        if sfind(first, "ORGANIZATION", 1, true) then
            return true -- reparent-guard broadcast
        end
    end
    return false
end

-- 2a) DOT-форма .FireServer(self, x): хук самой C-функции.
--     oth.hook (off-thread, антидетект vs isfunctionhooked) с фолбэком на hookfunction.
local fs_mode = "none"
if base_fs and oth and oth.hook then
    local old_fs
    old_fs = oth.hook(base_fs, function(self, ...)
        if fs_filter(self, (...)) then return end
        return old_fs(self, ...)
    end)
    fs_mode = "oth.hook"
elseif base_fs then
    local old_fs
    old_fs = hookfunction(base_fs, newcclosure(function(self, ...)
        if fs_filter(self, (...)) then return end
        return old_fs(self, ...)
    end))
    fs_mode = "hookfunction"
end

-- 2b) COLON-форма self:FireServer(x) (namecall) — ИМЕННО так летит _cpr/_genv/_ls.
--     Это ОТДЕЛЬНЫЙ путь диспетчеризации; функцию-хук из 2a может его не ловить,
--     поэтому обязательный второй перехват через __namecall.
local nc_mode = "none"
pcall(function()
    local old_nc
    old_nc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if getnamecallmethod() == "FireServer" and fs_filter(self, (...)) then
            return
        end
        return old_nc(self, ...)
    end))
    nc_mode = "on"
end)

----------------------------------------------------------------------
-- LAYER 3  — заглушить LogService.MessageOut honeypot (logscan _ls).
-- Отключаем только НЕ-наши коннекты. После этого печатай что угодно.
----------------------------------------------------------------------
--[[
    ПОЧЕМУ ЭТО ТЕПЕРЬ В ЦИКЛЕ (нашлось по реальному логу: "logscan off: 1").
    Раньше слой выполнялся ОДИН раз при загрузке. Сколько коннектов он успеет
    отключить — зависит от того, когда ты запустил обход: в лобби игра ещё не
    зарегистрировала все свои обработчики MessageOut, поэтому и получалось 1
    вместо 2. Всё, что игра подключит ПОЗЖЕ (на спавне, при смене карты),
    оставалось живым — и первый же print мог уйти в докладный канал.
    Теперь пересканируем периодически: новые коннекты глушатся сразу.
--]]
local logscan_off = 0
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
            -- Enabled == false -> уже заглушён нами, второй раз не считаем
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

logscan_off = patch_logscan()

----------------------------------------------------------------------
-- LAYER 4 (recon)  — доказать, что loading_gui жив в рантайме,
-- хоть и nil-parented. Просто находим и логируем (без риск-действий:
-- репорты/приманка/logscan уже нейтрализованы выше).
----------------------------------------------------------------------
local honeypots = 0
pcall(function()
    if not getnilinstances then return end
    for _, inst in ipairs(getnilinstances()) do
        local ok, cls = pcall(function() return inst.ClassName end)
        if ok and cls == "LocalScript" then
            honeypots += 1
        end
    end
end)

----------------------------------------------------------------------
-- LAYER 5  — ВТОРАЯ СИСТЕМА ДЕТЕКТА (FirstPersonController_extend стр.680-800)
-- Каждые 5с secondary_replication_timer собирает детект-пакеты и ВШИВАЕТ их
-- в основной пакет репликации (replication:FireServer) — дропать нельзя,
-- сломается движение. Поэтому глушим сам таймер:
--   Timer.expired() = (next_time < Timescale.get_time())
--   -> next_time = math.huge => блок не выполнится НИКОГДА.
-- Это убивает пакеты: 1 (скан PlayerGui на чужие GUI), 2 (bodymovers на своём
-- torso), 4 (collective_weight), 5/6 (velocity аномалии), 7 (rpm>1500),
-- 8 (dirty_properties), 9 (_G.actor_started), 10 (stop).
-- Пакет 3 (torso_hitbox) проверяется вне таймера -> просто не трогаем хитбокс.
-- Контроллер пересоздаётся на респавне -> переставляем в цикле.
----------------------------------------------------------------------
local HUGE = math.huge
local sec_patched = 0

local function patch_secondary()
    local ok, found = pcall(filtergc, "table", {
        Keys = { "secondary_replication_timer" },
    }, false)
    if not ok or type(found) ~= "table" then return end
    for _, ctrl in ipairs(found) do
        local t = rawget(ctrl, "secondary_replication_timer")
        if type(t) == "table" and rawget(t, "next_time") ~= HUGE then
            pcall(function()
                t.next_time = HUGE
                t.timeout = HUGE
            end)
            sec_patched += 1
        end
    end
end

-- маркер, который ищет packet 9
pcall(function() if _G.actor_started then _G.actor_started = nil end end)

pcall(patch_secondary)

--[[
    ПОЧЕМУ В ЛОГЕ МОЖЕТ БЫТЬ "2nd-detect timers: 0" И ЭТО НОРМАЛЬНО.
    secondary_replication_timer живёт внутри FirstPersonController, а он
    создаётся только когда ты ЗАСПАВНИЛСЯ. Запустил обход в лобби или на
    экране смерти — filtergc честно не находит ни одного, и в строке ноль.
    Цикл ниже пересканирует каждые 2 секунды, поэтому на спавне таймер будет
    заглушён сам. Раньше об этом никак не сообщалось, и ноль выглядел как
    поломка — теперь печатаем отдельную строку, когда таймер реально найден.
--]]
task.spawn(function()
    local announced = sec_patched > 0
    while true do
        task.wait(2)
        local before = sec_patched
        pcall(patch_secondary)
        if sec_patched > before then
            -- нашли новый контроллер: либо первый спавн, либо респавн
            if not announced then
                announced = true
                log(("2nd-detect timers patched on spawn: %d (packets 1,2,4-10 dead)")
                    :format(sec_patched))
            end
        end
        -- новые коннекты MessageOut игра добавляет по ходу матча
        local extra = patch_logscan()
        if extra > 0 then
            logscan_off += extra
            log(("logscan: disabled %d new MessageOut connection(s), total %d")
                :format(extra, logscan_off))
        end
        if rawget(_G, "actor_started") then pcall(function() _G.actor_started = nil end) end
    end
end)

log(("armed | freeze no-op: %d/%d (want 3) | FireServer(dot): %s | namecall(colon): %s | logscan off: %d | 2nd-detect timers: %d | nil LS: %d")
    :format(killed, seen, fs_mode, nc_mode, logscan_off, sec_patched, honeypots))
log("2nd-detect neutralized: PlayerGui-scan / dirty_properties / rpm / actor_started")
if sec_patched == 0 then
    log("note: 2nd-detect timers = 0 is EXPECTED in lobby / while dead - the " ..
        "controller does not exist yet. It gets patched on spawn (rescan every 2s) " ..
        "and you will see a 'patched on spawn' line then.")
end
if killed < 3 then
    log("WARNING: killed fewer than 3 freeze traps. The dangerous one is " ..
        "util.getenv - it sits behind math.random(1,100)==100, so it fires " ..
        "1 time in 100 on every position compress. Symptoms: random freezes, " ..
        "random deaths, rubber-banding. Re-run the bypass FIRST, before the " ..
        "other scripts.")
end

--======================================================================
--  LOADER MODULE  (Syllinse Project)
--======================================================================
-- No UI: this runs once at load. stop() intentionally keeps the hooks —
-- un-hooking the freeze traps would re-arm them and the report channel.
return {
    start = function() end,
    stop  = function() end,
}
