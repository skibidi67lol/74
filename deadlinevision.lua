--[[
    DEADLINE 0.25.2 — VISION / ENVIRONMENT  (Potassium)
    ======================================================================
    Отдельный скрипт под ОДИН класс уязвимости: SHARED_STATE.

    ПОЧЕМУ ЭТО РАБОТАЕТ (разбор, а не догадка).
    Модуль module/shared_state реплицируется ТОЛЬКО в одну сторону:
    сервер -> клиент (FireAllClients). Метод :set_client(v) пишет значение
    исключительно в ЛОКАЛЬНУЮ копию — обратно на сервер не уходит ничего.
    Сервер держит собственную копию и о нашей не знает.

    А клиентский античит (FirstPersonController_extend:680-790) проверяет
    строго конечный список:
        packet 1  посторонние ScreenGui в PlayerGui
        packet 3  torso_hitbox.CanCollide / CollisionGroup   (каждый тик!)
        packet 4  char_data.collective_weight < 0
        packet 5  ammunition.velocity_drop <= 0
        packet 6  ammunition.velocity > 10000
        packet 7  properties.firing.rpm > 1500
        packet 8  build.result.dirty_properties ~= nil
        packet 9  _G.actor_started
        packet 10 controller.stop
        + illegal bodymovers на torso
    Ни одного из флагов ниже в этом списке НЕТ. Поэтому это именно обход:
    мы меняем то, что сервер не наблюдает и не может наблюдать.

    ЧЕГО ЗДЕСЬ СОЗНАТЕЛЬНО НЕТ:
      • ammunition.velocity / velocity_drop  -> packet 5/6
      • properties.firing.rpm                -> packet 7
      • любая запись в properties            -> packet 8 (dirty_properties)
    Их трогать нельзя, и мы не трогаем.

    Запуск в любой момент. Выключить: getgenv().DLV.unload()
--]]

if getgenv().DLV and getgenv().DLV.unload then
    pcall(getgenv().DLV.unload)
end

local DLV = {}
getgenv().DLV = DLV

local function log(msg)
    local out = rconsoleprint or print
    pcall(out, "[dlv] " .. tostring(msg))
end

--======================================================================
--  СТРАХОВКА ОТ ЛОВУШЕК getenv
--======================================================================
--[[
    Те же три ловушки, что и в остальных скриптах (константа "kill yourself"):
        NetworkEncode:12  caster:404  util:10
    Последняя — под if math.random(1,100) ~= 100, то есть стреляет 1 раз из
    100 на каждый map_clamped. Мы читаем SHARED_STATE, а не хукаем горячие
    функции, но защита стоит копейки и снимает целый класс случайных фризов.
--]]
--[[
    ИДЕМПОТЕНТНОСТЬ: если ловушки уже заглушил другой скрипт (обход, suite,
    movement) — не хукаем повторно. Четыре слоя hookfunction на функциях
    горячего пути не нужны никому.
--]]
local GENV_MARK = "__dl_genv_traps_killed"
local genvKilled = 0
do
    local g = getgenv()
    local already = g and rawget(g, GENV_MARK)
    if type(already) == "number" and already >= 3 then
        genvKilled = already                 -- РЕАЛЬНО заглушено (все 3), доверяем
    else
        local NOOP = function() end
        local okf, found = pcall(filtergc, "function", {
            Constants      = { "kill yourself" },
            IgnoreExecutor = true,
        }, false)
        if okf and type(found) == "table" then
            for _, fn in ipairs(found) do
                if type(fn) == "function" and pcall(hookfunction, fn, NOOP) then
                    genvKilled = genvKilled + 1
                end
            end
        end
        if g then pcall(rawset, g, GENV_MARK, genvKilled) end
    end
    for _, envGetter in ipairs({ getgenv, getrenv }) do
        pcall(function()
            local env = envGetter and envGetter()
            if type(env) == "table" and rawget(env, "rconsoleprint") ~= nil then
                rawset(env, "rconsoleprint", nil)
            end
        end)
    end
end

--======================================================================
--  CONFIG
--======================================================================
local CFG = {
    --[[ ── ДЫМ НАСКВОЗЬ ────────────────────────────────────────────────
        Самое сильное из всего списка. Дым — клиентская ECS-система частиц
        (client/module/ecs/system/update_smokes:120-137). Прозрачность,
        скорость появления и время жизни пыжа берутся из SHARED_STATE и
        нигде не проверяются. Ставим прозрачность 0 — дымовые гранаты
        противника перестают работать против нас, для него всё как обычно. ]]
    SeeThroughSmoke  = true,

    --[[ ── БЕЗ ПОДАВЛЕНИЯ ──────────────────────────────────────────────
        caster:676: подавление применяется только если
        SHARED_STATE.plr_suppression.value истинно. Ставим false — пули
        рядом больше не дают размытие и не сбивают прицел.
        Само подавление считается НАШИМ клиентом (caster вызывает
        u1.suppress, зарегистрированный клиентским фреймворком), поэтому
        отключение полностью в нашей власти. ]]
    NoSuppression    = true,

    --[[ ── ПОГОДА И ОСВЕЩЕНИЕ ──────────────────────────────────────────
        weather:61 — весь апдейт Lighting (ClockTime, туман, дождь, пресеты)
        идёт под флагом dbg_disable_weather. НО этот же heartbeat — ЕДИНСТВЕННОЕ,
        что инициализирует Lighting/VOLUMIKA из тёмного загрузочного состояния.
        Если выставить флаг ДО загрузки (как делал верхнеуровневый apply на
        строке ~331 ещё до loader.start()), heartbeat умирает на первой строке
        и сцена НИКОГДА не подсвечивается -> ЧЁРНЫЙ ЭКРАН перед загрузкой.

        ФИКС: по умолчанию OFF; сам флаг пишется ТОЛЬКО после спавна персонажа
        (weather_ready) — к этому моменту weather уже осветил сцену, поэтому
        «заморозка» будет СВЕТЛОЙ, а не чёрной. Выключение тумблера возвращает
        погоду (пишем dbg_disable_weather = false). ]]
    DisableWeather   = false,

    --[[ ── ТРАЕКТОРИИ ПУЛЬ ─────────────────────────────────────────────
        caster:303/397 берут dbg_projectile и рисуют gizmo-линии
        (caster:590-603). Важно, что кастер на нашем клиенте обрабатывает и
        ЧУЖИЕ выстрелы (dl_replicator создаёт кастеры для реплицированных
        выстрелов) — значит видно траектории входящих пуль, то есть откуда
        по нам стреляют. ]]
    ShowProjectiles  = false,

    --[[ dbg_show_shot_trajectory (rifle_methods:145): зелёная линия — куда
         смотрит ствол, красная — фактическое направление с разбросом.
         Удобно для проверки, работает ли no-spread. ]]
    ShowShotVector   = false,

    --[[ dbg_char_gizmos (DebugVisualize:15,66): точки и цилиндры коллизии
         персонажей — фактически показ хитбоксов симуляции. ]]
    ShowCharGizmos   = false,

    --[[ ── МГНОВЕННЫЙ ЗВУК ─────────────────────────────────────────────
        dl_replicator:604/661/731 задерживают звук выстрела на
        distance / sv_sound_speed. Снижаем задержку почти до нуля — выстрелы
        слышны сразу, направление читается точнее. 1120 -> 20000. ]]
    InstantSound     = true,
    SoundSpeed       = 20000,

    --[[ ── СТАБИЛЬНЫЙ ПРИЦЕЛ ───────────────────────────────────────────
        Всё это живёт только в клиентском fp_controller и в UI:
          plr_recoil                        rifle_methods:211 (пружины камеры)
          plr_stamina_shake_multiplier      rifle_methods:1900
        Направление выстрела считается ДО применения отдачи, поэтому это
        именно визуальная/эргономическая часть — сервер её не видит. ]]
    SteadyAim        = true,

    --[[ ── БЕСКОНЕЧНАЯ СТАМИНА (правильным способом) ────────────────────
        ВАЖНО, ЧЕМУ Я УЧЁЛСЯ: первым делом я раздул plr_max_stamina и
        plr_max_arm_stamina до 100000 — и это БЫЛО ОШИБКОЙ.
        Текущее значение stamina берётся из максимума только ОДИН РАЗ, на
        спавне (FPC:122/149). Если поднять максимум позже, текущее так и
        останется 60, а UI считает заполнение как current/max
        (StaminaBar:52) — полоска выглядит пустой, плюс FPC_extend:441
        начинает считать, что полоску надо показывать.

        Правильнее обнулить сами РАСХОДЫ — тогда стамина просто не убывает,
        а максимум и полоска остаются нормальными:
          plr_stamina_run_drain    1.4  FPC:1578   (бег)
          plr_stamina_jump_drain   3    FPC_ext:197 (прыжок)
          plr_stamina_lean_drain   0.25 FPC:696    (наклон)
          plr_vault_stamina_drain  7    FPC_ext:228 (вольт)
          plr_arm_stamina_drain    2    FPC:1589/1598 (прицеливание)
          plr_arm_stamina_drain_hold_breath 3 FPC:1590/1601 (задержка дыхания)
        Бонусом: FPC_extend:154 запрещает вольт при
        stamina < plr_vault_stamina_drain. С нулём условие stamina < 0 никогда
        не выполняется — вольт больше не блокируется усталостью.
        Регенерацию тоже поднимаем, чтобы добрать то, что снимает
        нефлаговый расход в FPC:751 (там значение зашито в код). ]]
    InfStamina       = true,

    --[[ ── ЗАЩИТА ОТ ОСЛЕПЛЕНИЯ ────────────────────────────────────────
        plr_lens_flare (lens_flare:91) — вспышки от фонарей и лазеров
        противника рисует наш клиент. Выключаем. ]]
    NoLensFlare      = true,

    --[[ ── НОЧНОЕ ВИДЕНИЕ ЯРЧЕ ─────────────────────────────────────────
        plr_nv_color (NightVisionEffects:37) — только ColorCorrection на
        клиенте. Белый вместо зелёного = максимальная различимость.
        ВАЖНО: сам факт включённого ПНВ реплицируется битом
        nv_head_gear_enabled в пакете, поэтому «ПНВ без прибора» здесь НЕ
        делается — это была бы уже подделка пакета. Меняем только цвет. ]]
    BrightNVG        = false,

    --[[ ── ПРИЦЕЛИВАНИЕ В КУСТАХ ───────────────────────────────────────
        plr_aim_in_bushes (rifle:26,302) — запрет прицеливаться в зоне
        кустарника проверяется ТОЛЬКО клиентом, по локальному
        slow_movement_zone_type, который серверу не уходит. ]]
    AimInBushes      = true,

    --[[ ── УТОПЛЕНИЕ ───────────────────────────────────────────────────
        Второй слой к тому, что делает movement-скрипт. Смерть в воде
        докладывает САМ КЛИЕНТ (ClientFramework:1329-1332):
            if water_time < 0.1 then u18:SendToServer() end
        Здесь просто задираем предел, до которого water_time восстанавливается
        (ClientFramework:1336 clamp(water_time, 0, plr_drown_time)). ]]
    NoDrown          = true,
    DrownTime        = 100000,

    KeepAlive        = true,   -- сервер может переслать значения -> переставляем
    Interval         = 2.0,
}
DLV.config = CFG

local running = true
local applied = 0

--======================================================================
--  ДОСТУП К SHARED_STATE
--======================================================================
local RS = cloneref and cloneref(game:GetService("ReplicatedStorage"))
    or game:GetService("ReplicatedStorage")

local SHARED
pcall(function()
    SHARED = require(RS.module.shared_state).SHARED_STATE
end)

--[[
    weather_ready(): истинно, когда игрок заспавнен в карту, т.е. weather-heartbeat
    уже отработал и осветил Lighting/VOLUMIKA. Отключать погоду можно ТОЛЬКО после
    этого — иначе замораживаем чёрное загрузочное состояние. Пока не готово,
    dbg_disable_weather держим в false (KeepAlive-цикл переприменит, когда спавн).
--]]
local Players = game:GetService("Players")
local function weather_ready()
    local plr = Players.LocalPlayer
    if not plr then return false end
    local char = plr.Character
    return char ~= nil and char:FindFirstChild("HumanoidRootPart") ~= nil
end

--[[
    set_client — штатный путь смены значения на клиенте. Он существует именно
    для того, чтобы обойти readonly-обёртку значения, поэтому пользуемся им, а
    не прямой записью в .value. Прямая запись оставлена запасным вариантом.
--]]
local original = {}

local function set_shared(key, value)
    if not SHARED then
        return false
    end
    local obj = rawget(SHARED, key)
    if type(obj) ~= "table" then
        return false
    end
    if original[key] == nil then
        original[key] = rawget(obj, "value")
    end
    local ok = pcall(function()
        if type(obj.set_client) == "function" then
            obj:set_client(value)
        else
            obj.value = value
        end
    end)
    if ok then
        applied = applied + 1
    end
    return ok
end

local function restore_shared(key)
    local prev = original[key]
    if prev == nil then
        return
    end
    set_shared(key, prev)
end

--======================================================================
--  ПРИМЕНЕНИЕ
--======================================================================
local function apply()
    applied = 0

    if CFG.SeeThroughSmoke then
        -- три параметра вместе: не набирает плотность, сразу тает, прозрачен
        set_shared("cfg_smoke_max_opacity", 0)
        set_shared("cfg_smoke_fade_in_end", 1)
        set_shared("cfg_smoke_fade_out_start", 0)
        set_shared("cfg_smoke_emit_rate", 0)
    end

    if CFG.NoSuppression then
        set_shared("plr_suppression", false)
    end

    -- Пишем ВСЕГДА явное значение: выключение тумблера -> погода возвращается.
    -- true разрешён ТОЛЬКО когда сцена уже освещена (персонаж заспавнен),
    -- иначе оставляем false, чтобы не заморозить чёрный загрузочный кадр.
    -- Пока не готово — KeepAlive-цикл переприменит true после спавна.
    set_shared("dbg_disable_weather", (CFG.DisableWeather and weather_ready()) and true or false)

    set_shared("dbg_projectile", CFG.ShowProjectiles and true or false)
    set_shared("dbg_show_shot_trajectory", CFG.ShowShotVector and true or false)
    set_shared("dbg_char_gizmos", CFG.ShowCharGizmos and true or false)

    if CFG.InstantSound then
        set_shared("sv_sound_speed", CFG.SoundSpeed)
    end

    if CFG.SteadyAim then
        set_shared("plr_recoil", 0)
        set_shared("plr_stamina_shake_multiplier", 0)
    end

    if CFG.InfStamina then
        -- расходы в ноль (максимум и полоску НЕ трогаем, см. комментарий выше)
        set_shared("plr_stamina_run_drain", 0)
        set_shared("plr_stamina_jump_drain", 0)
        set_shared("plr_stamina_lean_drain", 0)
        set_shared("plr_vault_stamina_drain", 0)
        set_shared("plr_arm_stamina_drain", 0)
        set_shared("plr_arm_stamina_drain_hold_breath", 0)
        -- регенерация с запасом: добирает нефлаговый расход из FPC:751
        set_shared("plr_stamina_regen", 60)
        set_shared("plr_stamina_crouch_regen", 60)
        set_shared("plr_arm_stamina_regen", 60)
        set_shared("plr_arm_stamina_regen_crouch", 60)
    end

    if CFG.NoLensFlare then
        set_shared("plr_lens_flare", false)
    end

    if CFG.BrightNVG then
        set_shared("plr_nv_color", Color3.fromRGB(255, 255, 255))
    end

    if CFG.AimInBushes then
        set_shared("plr_aim_in_bushes", false)
    end

    if CFG.NoDrown then
        set_shared("plr_drown_time", CFG.DrownTime)
    end
end

apply()

if CFG.KeepAlive then
    task.spawn(function()
        while running do
            task.wait(CFG.Interval)
            pcall(apply)
        end
    end)
end

--======================================================================
--  ДИАГНОСТИКА / ВЫГРУЗКА
--======================================================================
DLV.debug = function()
    local s = ("shared=%s applied=%d genv-traps=%d")
        :format(tostring(SHARED ~= nil), applied, genvKilled)
    log(s)
    return s
end

DLV.unload = function()
    running = false
    for key in pairs(original) do
        pcall(restore_shared, key)
    end
    if getgenv().DLV == DLV then
        getgenv().DLV = nil
    end
    log("unloaded (original values restored)")
end

if not SHARED then
    log("ERROR: could not get SHARED_STATE - run after the game has loaded")
else
    log(("armed | flags set: %d | genv-traps: %d"):format(applied, genvKilled))
    log("see-thru-smoke: " .. tostring(CFG.SeeThroughSmoke) ..
        " | no-suppression: " .. tostring(CFG.NoSuppression) ..
        " | no-weather: " .. tostring(CFG.DisableWeather))
    log("NOT touching: velocity / velocity_drop / rpm / properties = packets 5/6/7/8")
end

--======================================================================
--  LOADER MODULE  (Syllinse Project / MacLib)
--======================================================================
return {
    -- everything starts OFF and is applied immediately
    start = function()
        CFG.SeeThroughSmoke, CFG.NoSuppression, CFG.DisableWeather = false, false, false
        CFG.ShowProjectiles, CFG.ShowShotVector, CFG.ShowCharGizmos = false, false, false
        CFG.InstantSound, CFG.SteadyAim, CFG.InfStamina = false, false, false
        CFG.NoLensFlare, CFG.BrightNVG, CFG.AimInBushes, CFG.NoDrown = false, false, false, false
        pcall(apply)
    end,

    stop = function()
        if DLV and type(DLV.unload) == "function" then pcall(DLV.unload) end
    end,

    buildUI = function(ctx)
        local ready = false
        task.defer(function() ready = true end)
        local function note(t, b) if ready then pcall(ctx.notify, t, b) end end

        -- every toggle re-applies immediately: these are plain state flags
        local function bool(sec, name, o)
            sec:Toggle({ Name = name, Default = o.Default == true,
                Callback = function(v)
                    o.set(v and true or false)
                    pcall(apply)
                    note(name, v and "Enabled" or "Disabled")
                end }, ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
        end

        local function slider(sec, o)
            sec:Slider({ Name = o.Name, Default = o.Default, Minimum = o.Min, Maximum = o.Max,
                Precision = o.Precision or 0, Suffix = o.Suffix,
                Callback = function(v) o.Callback(v); pcall(apply) end }, ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
        end

        --==============================================================
        -- TAB: VISUALS  (world flags; ESP sections come from the suite)
        --==============================================================
        -- master switch + empty keybind, one per feature section
        local function feature(sec, o)
            local guard, el = false, nil
            local function commit(v)
                v = v and true or false
                o.set(v)
                pcall(apply)
                note(o.Title, v and "Enabled" or "Disabled")
                guard = true
                if el then pcall(function() el:UpdateState(v) end) end
                guard = false
            end
            el = sec:Toggle({ Name = "Enabled", Default = false,
                Callback = function(v) if not guard then commit(v) end end },
                ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
            ctx.keybind(sec, { Name = "Keybind", Flag = ctx.flag(o.Flag .. "_KB"),
                Toggle = function() commit(not o.get()) end })
        end

        --==============================================================
        -- TAB: VISUALS  (world flags; ESP sections come from the suite)
        --==============================================================
        local V = ctx.tabs.Visuals

        local w1 = V:Section({ Side = "Right" })
        w1:Header({ Name = "See Through Smoke" })
        feature(w1, { Title = "See Through Smoke", Flag = "WD_Smoke",
            get = function() return CFG.SeeThroughSmoke end,
            set = function(v) CFG.SeeThroughSmoke = v end,
            Desc = "smoke opacity 0 = enemy smokes stop working on you" })

        local w2 = V:Section({ Side = "Right" })
        w2:Header({ Name = "Disable Weather" })
        feature(w2, { Title = "Disable Weather", Flag = "WD_Weather",
            get = function() return CFG.DisableWeather end,
            set = function(v) CFG.DisableWeather = v end,
            Desc = "flat bright lighting instead of night, fog and rain" })

        local w3 = V:Section({ Side = "Right" })
        w3:Header({ Name = "No Lens Flare" })
        feature(w3, { Title = "No Lens Flare", Flag = "WD_Flare",
            get = function() return CFG.NoLensFlare end,
            set = function(v) CFG.NoLensFlare = v end,
            Desc = "no blinding from enemy flashlights and lasers" })

        local w4 = V:Section({ Side = "Right" })
        w4:Header({ Name = "Bright NVG" })
        feature(w4, { Title = "Bright NVG", Flag = "WD_NVG",
            get = function() return CFG.BrightNVG end,
            set = function(v) CFG.BrightNVG = v end,
            Desc = "white night vision instead of green" })

        --==============================================================
        -- TAB: MISC
        --==============================================================
        local X = ctx.tabs.Misc

        local x1 = X:Section({ Side = "Left" })
        x1:Header({ Name = "No Suppression" })
        feature(x1, { Title = "No Suppression", Flag = "MS_NoSupp",
            get = function() return CFG.NoSuppression end,
            set = function(v) CFG.NoSuppression = v end,
            Desc = "no blur or aim shake from nearby bullets" })

        local x2 = X:Section({ Side = "Right" })
        x2:Header({ Name = "Steady Aim" })
        feature(x2, { Title = "Steady Aim", Flag = "MS_Steady",
            get = function() return CFG.SteadyAim end,
            set = function(v) CFG.SteadyAim = v end,
            Desc = "zero camera recoil and fatigue shake" })

        local x3 = X:Section({ Side = "Left" })
        x3:Header({ Name = "Infinite Stamina" })
        feature(x3, { Title = "Infinite Stamina", Flag = "MS_InfStam",
            get = function() return CFG.InfStamina end,
            set = function(v) CFG.InfStamina = v end,
            Desc = "zeroes every stamina drain and raises regen" })

        local x4 = X:Section({ Side = "Right" })
        x4:Header({ Name = "Aim In Bushes" })
        feature(x4, { Title = "Aim In Bushes", Flag = "MS_Bushes",
            get = function() return CFG.AimInBushes end,
            set = function(v) CFG.AimInBushes = v end,
            Desc = "the bush aim block is client-only" })

        local x5 = X:Section({ Side = "Left" })
        x5:Header({ Name = "Instant Sound" })
        feature(x5, { Title = "Instant Sound", Flag = "MS_Sound",
            get = function() return CFG.InstantSound end,
            set = function(v) CFG.InstantSound = v end,
            Desc = "removes the distance delay on gunshots" })
        slider(x5, { Name = "Sound Speed", Flag = "MS_SoundSpd", Default = 20000,
            Min = 1120, Max = 40000,
            Callback = function(v) CFG.SoundSpeed = v end,
            Desc = "game default is 1120" })

        local x6 = X:Section({ Side = "Right" })
        x6:Header({ Name = "No Drown" })
        feature(x6, { Title = "No Drown", Flag = "MS_NoDrown",
            get = function() return CFG.NoDrown end,
            set = function(v) CFG.NoDrown = v end,
            Desc = "keeps the breath timer topped up" })

        --==============================================================
        -- TAB: DEBUG  (created by the loader)
        --==============================================================
        local D = ctx.tabs.Debug

        local d1 = D:Section({ Side = "Right" })
        d1:Header({ Name = "Show Projectiles" })
        feature(d1, { Title = "Show Projectiles", Flag = "WD_Proj",
            get = function() return CFG.ShowProjectiles end,
            set = function(v) CFG.ShowProjectiles = v end,
            Desc = "all bullet paths, incoming ones too" })

        local d2 = D:Section({ Side = "Left" })
        d2:Header({ Name = "Show Shot Vector" })
        feature(d2, { Title = "Show Shot Vector", Flag = "WD_ShotVec",
            get = function() return CFG.ShowShotVector end,
            set = function(v) CFG.ShowShotVector = v end,
            Desc = "green = barrel, red = real direction with spread" })

        local d3 = D:Section({ Side = "Right" })
        d3:Header({ Name = "Show Hitboxes" })
        feature(d3, { Title = "Show Hitboxes", Flag = "WD_Gizmos",
            get = function() return CFG.ShowCharGizmos end,
            set = function(v) CFG.ShowCharGizmos = v end,
            Desc = "character collision cylinders" })
    end,
}
