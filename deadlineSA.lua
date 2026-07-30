--[[
    DEADLINE 0.25.2 — SUITE v5  (Potassium)
    ======================================================================
    Обход (deadline_bypass.lua) запускается ОТДЕЛЬНО и ПЕРВЫМ.

    АРХИТЕКТУРА ESP (переписана против мелькания/лага):
      • Drawing-объекты закреплены ЗА МОДЕЛЬЮ игрока (espByModel), а НЕ
        переиспользуются по индексу слота. Создаются при первом появлении
        врага, уничтожаются когда модель исчезла. Ноль перетасовки = ноль
        мелькания.
      • Bounding box стабильный: строится из humanoid_root_part + верх головы
        + ноги, шириной height*aspect. Проекция проверяет только Z>0 (точка
        перед камерой), БЕЗ гейта "в пределах вьюпорта" — поэтому враг у края
        экрана не пропадает и бокс не прыгает от махов рук/ног.
      • Скелет и все элементы красятся ЦВЕТОМ БОКСА (видим/скрыт).

    ПРОИЗВОДИТЕЛЬНОСТЬ:
      • SilentAim-резолв (дорогие raycast'ы MultiPoint/Resolver) троттлится
        до AimResolveInterval (20 Гц), между резолвами цель кэшируется и
        только проверяется на живость. Визуалы обновляются каждый кадр.
      • Видимость ESP кэшируется на VisCacheTtl (1 raycast на игрока/кадр).
      • filtergc метаданных — раз в MetaRefresh; реестр сущностей мёржится
        (не пересобирается), игрок не мигает между рефрешами.

    MULTIPOINT (как в BRM5Lib): бинарный поиск смещения дула по
      {cam.Right, -cam.Right, cam.Up}, из которого к кости есть прямой путь.
      Визуализация: линия дуло->цель; при спуфе дуло->спуф (жёлтая) +
      спуф->цель (зелёная).

    Выключить: getgenv().DL.unload()   |   Конфиг: getgenv().DL.config
--]]

if getgenv().DL and getgenv().DL.unload then
    pcall(getgenv().DL.unload)
end

local DL = {}
getgenv().DL = DL

local function log(msg)
    local out = rconsoleprint or print
    pcall(out, "[dl] " .. tostring(msg))
end

--======================================================================
--  CONFIG
--======================================================================
local CFG = {
    -- ── ESP ──────────────────────────────────────────────────────────
    ESP                = true,
    EspEnemyOnly       = true,
    EspMaxDistance     = 1500,
    EspBox             = true,
    EspBoxMode         = "Corner",      -- "Corner" | "Box"
    EspCornerScale     = 0.28,          -- доля стороны на уголок
    EspBoxAspect       = 0.62,          -- ширина = высота * aspect
    EspBoxThickness    = 1.6,
    EspShowName        = true,
    EspShowDistance    = true,
    EspShowWeapon      = true,
    EspShowStates      = true,
    EspHpBar           = true,
    EspSkeleton        = true,
    EspSkeletonMaxDist = 450,
    EspHeadCircle      = true,
    EspChams           = true,
    EspChamsFillTrans  = 0.72,
    EspChamsOutTrans   = 0.15,
    EspSmooth          = true,
    EspSmoothAlpha     = 0.5,
    EspVisibleCheck    = true,

    -- ── SILENT AIM ───────────────────────────────────────────────────
    SilentAim          = true,
    SilentAimFOV       = 120,           -- ПОЛНЫЙ конус (градусы)
    SilentAimMaxDist   = 600,
    AimBone            = "head",        -- "head" | "torso" | "auto"
    IgnoreTeammates    = true,
    SkipBlocked        = true,          -- не целиться в полностью закрытых
    --[[ Цена резолва = цели * направления * шаги * 2 луча. При 20 Гц и трёх
         целях выходило ~1200 raycast'ов в секунду — отсюда просадки. Теперь
         реже, и дорогой поиск идёт только пока не найден годный вариант. ]]
    AimResolveInterval = 0.09,          -- ~11 Гц

    -- ── MULTIPOINT (muzzle peek) ─────────────────────────────────────
    --[[ Скорость MultiPoint. Каждый шаг бинарного поиска = 1-2 raycast'а,
         поэтому цена = dirs * steps * targets. Ускорено: 3 базовых направления
         (как в BRM5), 3 шага, меньше целей и длиннее кэш. Диагонали и перебор
         второй кости — по желанию, они и были главным тормозом. ]]
    MultiPoint         = true,
    MPMaxOffset        = 6,
    MPBinarySteps      = 3,
    MPExtraDirs        = false,         -- true = +низ и 4 диагонали (дороже)
    MPTryOtherBone     = false,         -- true = пробовать вторую кость (дороже)
    MPCacheSec         = 0.8,
    MPDistScale        = 200,
    MPStickySec        = 0.35,
    MPMaxTargets       = 3,

    -- ── RESOLVER ─────────────────────────────────────────────────────
    -- В этой игре толком не нужен (хитбоксы простые, R6) — по умолчанию выкл,
    -- заодно экономит raycast'ы. Включай, если хочется добивать «выглядывающих».
    Resolver           = false,
    ResolverInset      = 0.08,

    -- ── ПРЕДИКТ (упреждение, которое ожидает сервер) ──────────────────
    Prediction          = true,
    PredictIterations   = 3,        -- итераций сходимости дистанция<->время
    PredictVertical     = false,    -- учитывать вертикальную скорость цели
    PredictWind         = true,     -- компенсировать GlobalWind
    PredictMaxTime      = 1.2,      -- предел времени полёта (сек), 0 = без
    PredictFallbackSpeed = 900,     -- если не удалось прочитать патрон

    --[[ ── КОМПЕНСАЦИЯ ОТКАТА РЕПЛИКАЦИИ ────────────────────────────────
        ВОТ ПОЧЕМУ ПО БЫСТРЫМ ВРАГАМ НЕ ПРИНИМАЛО ПОПАДАНИЕ.
        Чужие модели рисуются НЕ в текущем положении, а в прошлом:
            ReplicationBuffer.get_position(t):
                v8 = t - SHARED_STATE.plr_replication_rollback_time_ms.value
            shared_state:140  plr_replication_rollback_time_ms = 190
        То есть всё, что мы видим (и куда наводимся), отстаёт на 190 мс.
        Для врага на 25 ст/с это 4.75 студа — шире торса, поэтому по бегущим
        заявка на попадание и отлетала, а по стоящим работала.

        Поэтому в общее время предикта добавляем откат: суммарный лид =
        время полёта пули + rollback. Значение читаем из самого SHARED_STATE,
        так что если разработчик его поменяет — подстроимся автоматически.
        Factor оставлен для подгонки: 1.0 = полная компенсация. Если начнёт
        перелетать вперёд по бегущим — снижай до 0.5. ]]
    PredictRollback       = true,
    PredictRollbackFactor = 1.0,

    --[[ Отсечка мусорных скоростей: респавн/телепорт дают гигантский рывок
         позиции, из которого получается бессмысленный лид. ]]
    PredictMaxTargetSpeed = 120,

    -- ── ПРОБИТИЕ ─────────────────────────────────────────────────────
    AllowPenetrable    = true,
    MaxPenetration     = 2.5,

    -- ── FORCE HIT ────────────────────────────────────────────────────
    ForceHit           = true,
    ForceHitPart       = "auto",        -- "auto" = наведённая кость, иначе имя части
    ForceHitDelay      = 0.03,

    -- ── ЛОКАЛЬНЫЙ ВИЗУАЛ СПУФА ───────────────────────────────────────
    -- OFF: MultiPoint работает на уровне пакета; локальную пулю не трогаем
    SpoofLocalVisual   = false,

    -- Бэктрек убран: сервер не засчитывал попадания по прошлым тикам,
    -- поэтому и прицеливание, и визуализация призрака удалены целиком.
    ClientRollbackMs   = nil,           -- nil = не трогать; 0 = видеть врага «сейчас»

    -- ── ВИЗУАЛЫ ──────────────────────────────────────────────────────
    FovCircle          = true,
    FovCircleColor     = Color3.fromRGB(255, 255, 255),
    FovCircleThick     = 1,
    FovCircleFilled    = false,
    FovCircleTrans     = 0.6,

    MuzzleVisual       = true,
    MuzzleLineColor    = Color3.fromRGB(80, 220, 255),
    MuzzleLineThick    = 2.0,
    MuzzleLineTrans    = 0.15,

    ShotTracers        = true,
    TracerColor        = Color3.fromRGB(255, 90, 35),
    TracerDuration     = 1.4,
    TracerFadeIn       = 0.12,
    TracerThickness    = 0.9,

    AimVisuals         = true,
    AimVisualStyle     = "Diamond",     -- "Default" | "CrossGap" | "DefaultV2" | "Diamond"
    AimVisualScale     = 1.0,
    AimVisualColor     = nil,           -- nil = цвет по тиру

    HitParticles       = true,
    HitParticleType    = "Wireframe",   -- "Wireframe" | "Orbs" | "Sparks"
    HitParticleCount   = 18,
    HitParticleDur     = 1.1,
    HitParticleGrav    = -32,
    HitParticleSpdMin  = 2,
    HitParticleSpdMax  = 32,
    HitParticleColorA  = Color3.fromRGB(88, 165, 255),
    HitParticleColorB  = Color3.fromRGB(165, 95, 255),
    HitParticleOpMin   = 0.45,
    HitParticleOpMax   = 1.0,
    HitParticleWireS   = 0.4,
    HitParticleMaxSys  = 4,

    HitSound           = true,
    HitSoundId         = 106586644436584,
    --[[ ПОЧЕМУ БЫЛО ТИХО. Я сам зажимал громкость в clamp(v, 0, 1), тогда как
         у Roblox Sound.Volume диапазон 0..10 (ползунок в студии кончается на
         1, но свойство принимает до 10). То есть звук играл на максимуме моего
         же искусственного потолка. Теперь потолок настоящий. ]]
    HitSoundVolume     = 3.5,       -- 0..10
    HitSoundPitch      = 1.0,
    --[[ Если и этого мало: несколько одновременных копий складываются по
         амплитуде. 1 = обычно достаточно, 2-3 = заметно жёстче. ]]
    HitSoundStack      = 1,

    -- ── WEAPON MODS ──────────────────────────────────────────────────
    NoRecoil           = true,
    NoSpread           = true,
    NoSway             = true,
    FullAuto           = true,

    -- ── ВНУТРЕННЕЕ ───────────────────────────────────────────────────
    MetaRefresh        = 1.0,
    ModsInterval       = 2.0,
    VisCacheTtl        = 0.12,
}
DL.config = CFG

--======================================================================
--  ОФОРМЛЕНИЕ (константы BRM5ESP)
--======================================================================
local LABEL_SIZE = 14
local LINE_STEP  = 0.52
local STACK_GAP  = 3
local CHIP_GAP   = 2

local COL_VISIBLE = Color3.fromRGB(70, 255, 90)
local COL_HIDDEN  = Color3.fromRGB(255, 55, 55)
local COL_WEAPON  = Color3.fromRGB(255, 165, 60)
local COL_DIST    = Color3.fromRGB(235, 235, 245)

-- цвет чипа состояния по категории
local CHIP_COLOR = {
    fire   = Color3.fromRGB(255, 70, 70),
    aim    = Color3.fromRGB(255, 210, 90),
    reload = Color3.fromRGB(255, 160, 45),
    run    = Color3.fromRGB(90, 200, 255),
    walk   = Color3.fromRGB(90, 200, 255),
    crouch = Color3.fromRGB(190, 170, 255),
    prone  = Color3.fromRGB(190, 170, 255),
    idle   = Color3.fromRGB(150, 150, 165),
    nvg    = Color3.fromRGB(170, 255, 150),
}

local POSE_NAME = { [1] = "idle", [2] = "prone", [3] = "crouch", [4] = "run" }
local R6_PARTS  = { "head", "torso", "left_arm_vis", "right_arm_vis", "left_leg_vis", "right_leg_vis" }
local TIER_WEIGHT = { [0] = 0, [1] = 750, [2] = 2100, [3] = 3800 }

--======================================================================
--  SERVICES / ЛОКАЛИ
--======================================================================
local Players     = cloneref and cloneref(game:GetService("Players"))    or game:GetService("Players")
local RunService  = cloneref and cloneref(game:GetService("RunService")) or game:GetService("RunService")
local RS          = cloneref and cloneref(game:GetService("ReplicatedStorage")) or game:GetService("ReplicatedStorage")
local SoundSvc    = cloneref and cloneref(game:GetService("SoundService")) or game:GetService("SoundService")
local Debris      = game:GetService("Debris")
local Workspace   = cloneref and cloneref(workspace) or workspace
local LocalPlayer = Players.LocalPlayer

local clock = os.clock
local sqrt  = math.sqrt
local floor = math.floor
local abs   = math.abs
local min   = math.min
local max   = math.max
local clamp = math.clamp
local rad   = math.rad
local deg   = math.deg
local tan   = math.tan
local sin   = math.sin
local cos   = math.cos
local acos  = math.acos
local pi    = math.pi
local rnd   = math.random
local V2    = Vector2.new
local V3    = Vector3.new
local CF    = CFrame.new
local ZERO3 = V3()

local running = true
local conns = {}

--======================================================================
--  СТРАХОВКА ОТ ЛОВУШЕК getenv  (обязательна именно для этого скрипта)
--======================================================================
--[[
    В игре три функции-ловушки с одинаковой начинкой (все с константой
    "kill yourself", поэтому находятся одним filtergc):

      module/namespace/NetworkEncode:12   getenv()  for i = 0, 9
          вызывается из write_exact_position, write_time, write_pose,
          compress_position, compress_velocity
      module/caster/caster:404            getenv()  for i = 1, 10
      module/util/lua/util:10             getenv()  for i = 1, 10
          НО с предохранителем: if math.random(1,100) ~= 100 then return end
          -> срабатывает 1 раз из 100, вызывается из map_clamped и copy_table

    Каждая обходит pcall(getfenv, i) по уровням стека и, если в чьём-то
    окружении есть rconsoleprint, делает:
        loading_status:FireServer("_genv")   -- доклад серверу
        rconsoleprint("kill yourself")
        while true do end                    -- вешает поток

    Почему это критично ИМЕННО здесь: мы хукаем write_exact_position и функции
    caster'а. Когда игра их вызывает, НАШ хук лежит на стеке — и getfenv
    находит окружение экзекутора. Вероятностный вариант из util объясняет
    «иногда всё ломается без причины»: 1% на каждое сжатие позиции.

    deadline_bypass делает то же самое, но suite обязан быть самодостаточным:
    если обход не загружен или загружен позже, мы всё равно не подставляемся.
--]]
--[[
    ИДЕМПОТЕНТНОСТЬ — ВАЖНО.
    Обход и каждый из скриптов раньше хукали ОДНИ И ТЕ ЖЕ три замыкания getenv.
    Получалось до четырёх слоёв hookfunction на функциях, которые вызываются из
    самого горячего пути (write_time / compress_position / map_clamped) — лишний
    риск на пустом месте. Ставим общий маркер в getgenv(): кто первый пришёл,
    тот и глушит, остальные только читают результат.
--]]
local GENV_MARK = "__dl_genv_traps_killed"
local genvKilled = 0
do
    local g = getgenv()
    local already = g and rawget(g, GENV_MARK)
    if type(already) == "number" then
        genvKilled = already                 -- уже заглушено другим скриптом
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
    -- второй слой (дешёвый, можно и повторно): убираем то, за что цепляется ловушка
    for _, envGetter in ipairs({ getgenv, getrenv }) do
        pcall(function()
            local env = envGetter and envGetter()
            if type(env) == "table" and rawget(env, "rconsoleprint") ~= nil then
                rawset(env, "rconsoleprint", nil)
            end
        end)
    end
end

--[[
    SHARED_STATE читают и предикт (plr_replication_rollback_time_ms), и weapon
    mods (plr_recoil и т.д.), поэтому забираем его сразу — иначе внутри
    predict_point ссылка была бы глобальной и всегда nil.
--]]
local SHARED
pcall(function()
    SHARED = require(RS.module.shared_state).SHARED_STATE
end)

--======================================================================
--  СОКРАЩЕНИЯ ИМЁН ОРУЖИЯ
--======================================================================
local WEAPON_SHORT = {
    ["Kazarov Group AK-12"]          = "AK-12",
    ["Kazarov Group AK-308"]         = "AK-308",
    ["Kazarov Group AK 5.45 Carbine"]= "AK5.45C",
    ["Kazarov Group AK 5.45"]        = "AK-5.45",
    ["Kazarov Group AK 7.62"]        = "AK-7.62",
    ["Kazarov Group PP-19-01"]       = "PP-19",
    ["Kazarov Type 1"]               = "AKM-1",
    ["Kazarov Type 2"]               = "AKM-2",
    ["Löwenherz AUG A3"]             = "AUG-A3",
    ["Whitner Defense EDC X9"]       = "EDC-X9",
    ["KF KG-31"]                     = "KG-31",
    ["KF 416"]                       = "KF416",
    ["KF MPi-54"]                    = "MP5",
    ["KF UMC-45"]                    = "UMP-45",
    ["M11 EOD"]                      = "M11",
    ["AR-15"]                        = "AR-15",
    ["AR-9"]                         = "AR-9",
    ["Ladoga MP133"]                 = "MP133",
    ["Pistolet Makarova"]            = "PM",
    ["Mosin Nagant M91/30 PU"]       = "MOSIN",
    ["Sic Stürmer P320"]             = "P320",
    ["Sanxian QBZ-95"]               = "QBZ-95",
    ["Roosevelt M700"]               = "M700",
    ["Roosevelt M870 Express"]       = "M870",
    ["RSA SG-58"]                    = "SG-58",
    ["HILT Defense MK-76"]           = "MK-76",
    ["AFT MK-17"]                    = "MK-17",
    ["AFT MK-16"]                    = "MK-16",
    ["Tokarev TT-33"]                = "TT-33",
    ["KALIS Scalar Gen II"]          = "VECTOR",
    ["M9 Bayonet"]                   = "M9",
    ["RPG-7"]                        = "RPG-7",
}
local WEAPON_VENDORS = {
    "Kazarov Group", "Kazarov", "Whitner Defense", "HILT Defense", "Löwenherz",
    "Sic Stürmer", "Roosevelt", "Sanxian", "Ladoga", "Tokarev", "KALIS", "RSA", "AFT", "KF",
}
local weaponShortCache = {}

local function short_weapon(fullName)
    if not fullName then
        return nil
    end
    local cached = weaponShortCache[fullName]
    if cached then
        return cached
    end
    local result = WEAPON_SHORT[fullName]
    if not result then
        result = fullName
        for _, vendor in ipairs(WEAPON_VENDORS) do
            if result:sub(1, #vendor) == vendor then
                result = result:sub(#vendor + 2)
                break
            end
        end
        result = result:gsub("^%s+", ""):upper()
        if #result > 9 then
            result = result:sub(1, 9)
        end
    end
    weaponShortCache[fullName] = result
    return result
end

--======================================================================
--  МЕТАДАННЫЕ ИГРОКОВ  (реестр мёржится, не пересобирается -> нет миганий)
--======================================================================
local entByModel   = {}   -- [characterModel] = entity
local entByIngame  = {}   -- [tostring(ingame_id)] = entity
local ctrl                -- локальный fp_controller
local framework           -- ClientFramework (синглтон, живёт через смерти)
local myCharacter         -- НАША модель; LocalPlayer.Character здесь всегда nil
local ignoreDirty = true  -- пересобрать список исключений для лучей
local ent_count = 0

--[[
    ДЕШЁВОЕ ОБНОВЛЕНИЕ «КТО МЫ» — вызывается КАЖДЫЙ КАДР.
    Раньше и сущности, и наш контроллер обновлялись одним filtergc раз в
    MetaRefresh (1 сек). Из-за этого после респавна до целой секунды работали
    мёртвые ctrl/myCharacter: muzzle-трейсер уходил не оттуда, лучи не
    исключали наше тело, моды не переставлялись. Теперь framework ищется один
    раз, а живое тело читается прямым rawget — это бесплатно, поэтому делаем
    каждый кадр. Дорогой filtergc сущностей остался в refresh_meta.
--]]
--[[
    КРИТИЧНО: ПОИСК framework ОБЯЗАН БЫТЬ ЗАДРОССЕЛИРОВАН.
    ЭТО БЫЛА ПРИЧИНА КРАША ИГРЫ. refresh_local зовётся КАЖДЫЙ КАДР, и в первой
    версии, если framework ещё не найден, прямо здесь запускался filtergc — то
    есть полный проход по ВСЕЙ куче GC 60 раз в секунду. Пока ты в лобби или
    ещё не заспавнился, framework не существует в принципе, поэтому
    сканирование шло непрерывно и клиент вставал насмерть.

    Покадрово теперь выполняется ТОЛЬКО дешёвый rawget по уже найденному
    объекту. Сам поиск — не чаще одного раза в FRAMEWORK_SCAN_INTERVAL, и это
    жёсткий предел, а не «желательно».
--]]
local FRAMEWORK_SCAN_INTERVAL = 1.0
local lastFrameworkScan = -math.huge

local function find_framework_throttled()
    local now = clock()
    if now - lastFrameworkScan < FRAMEWORK_SCAN_INTERVAL then
        return nil
    end
    lastFrameworkScan = now

    local okf, foundf = pcall(filtergc, "table", {
        Keys = { "lifetime_maid", "ui_bindings" },
    }, false)
    if not okf or type(foundf) ~= "table" then
        return nil
    end
    local fallback = nil
    for _, cand in ipairs(foundf) do
        if rawget(cand, "output") ~= nil or rawget(cand, "framework_store") ~= nil then
            local lt = rawget(cand, "lifetime_state")
            if type(lt) == "table" and rawget(lt, "fp_controller") ~= nil then
                return cand
            end
            fallback = fallback or cand
        end
    end
    return fallback
end

local function refresh_local()
    if framework == nil then
        framework = find_framework_throttled()
        if framework == nil then
            return
        end
    end

    local lt = rawget(framework, "lifetime_state")
    if type(lt) == "table" then
        local fpc = rawget(lt, "fp_controller")
        if type(fpc) == "table" and fpc ~= ctrl then
            ctrl = fpc
            ignoreDirty = true          -- новое тело -> пересобрать список лучей
        end
        local ch = rawget(lt, "character")
        if ch ~= myCharacter then
            myCharacter = ch
            ignoreDirty = true
        end
    else
        -- мертвы: контроллер и тело больше не наши, иначе будем целиться трупом
        ctrl = nil
        if myCharacter ~= nil then
            myCharacter = nil
            ignoreDirty = true
        end
    end
end

local function refresh_meta()
    local ok, found = pcall(filtergc, "table", {
        Keys = { "replicated_team", "player_name", "spawn_data" },
    }, false)

    if ok and type(found) == "table" then
        local seenModel = {}
        local n = 0
        table.clear(entByIngame)
        for _, ent in ipairs(found) do
            local model = rawget(ent, "character")
            if model ~= nil and rawget(ent, "player_name") ~= nil then
                -- живая сущность вытесняет устаревшую мёртвую по той же модели
                local prev = entByModel[model]
                if prev == nil or (rawget(prev, "dead") == true and rawget(ent, "dead") ~= true) then
                    entByModel[model] = ent
                end
                seenModel[model] = true
                local iid = rawget(ent, "ingame_id")
                if iid ~= nil and rawget(ent, "dead") ~= true then
                    entByIngame[tostring(iid)] = ent
                end
                n += 1
            end
        end
        -- прунинг: убираем записи для исчезнувших моделей
        for model in pairs(entByModel) do
            if model.Parent == nil then
                entByModel[model] = nil
            end
        end
        ent_count = n
    end

    --[[
        ЛОКАЛЬНЫЙ КОНТРОЛЛЕР — ИСПРАВЛЕН КОРНЕВОЙ БАГ.
        Прошлый вариант сверял cand.character с LocalPlayer.Character. Но в этой
        игре LocalPlayer.Character НЕ присваивается никогда (в дампе нет ни
        одного присваивания — модель парентится в Workspace.characters, а игроку
        ставится только ReplicationFocus). Значит проверка не срабатывала, и мы
        уходили в запасной критерий, который после респавна мог вернуть СТАРЫЙ
        контроллер. Отсюда «после смерти muzzle/моды отваливаются».

        Правильный источник — ClientFramework.lifetime_state: он создаётся при
        спавне (ClientFramework:828) и ОБНУЛЯЕТСЯ при смерти (234, 1133, 1142),
        поэтому труп подхватить невозможно. Сам framework — синглтон и живёт
        через смерти, ищем его один раз по постоянным ключам.
    --]]
    refresh_local()
end

local function is_enemy(ent)
    if not ent then
        return false
    end
    if rawget(ent, "dead") == true then
        return false
    end
    if CFG.IgnoreTeammates and rawget(ent, "is_player_friendly") == true then
        return false
    end
    return true
end

--======================================================================
--  AIM / FIRE ИЗ REPLICATION-СТРИМА  (aiming, стрельба)
--======================================================================
local netState = {}
local hookedStreams = {}

--[[
    Входящий стрим (сервер -> клиент) отличается от исходящего!
    Клиент шлёт последовательность write_bool, а сервер переупаковывает
    состояние в БИТОВОЕ ПОЛЕ u16 (parallel_replicator: read_time -> read_u16
    -> unpack_number16). Раскладка бит (LSB-first, 1-индексация оригинала):
        [1] nvg   [2] aiming   [3] climbing  [4] laser   [5] flashlight
        [6] есть байт fire_multiplier        [7] позиция [8] lean
        [9] look  [10] barrel_look           [11] поза
    Читаем напрямую нативным buffer — БЕЗ зависимости от игрового BitBuffer
    (его import() всё равно делает buffer.fromstring).
--]]
local function decode_stream(data)
    local buf
    if type(data) == "string" then
        buf = buffer.fromstring(data)
    elseif type(data) == "buffer" then
        buf = data
    else
        return nil
    end
    if buffer.len(buf) < 6 then
        return nil
    end
    local bits = buffer.readu16(buf, 4)          -- пропускаем u32 time
    local aiming = bit32.extract(bits, 1) == 1   -- бит [2]
    local hasFire = bit32.extract(bits, 5) == 1  -- бит [6]
    local fire = 0
    if hasFire and buffer.len(buf) >= 7 then
        fire = buffer.readu8(buf, 6) / 64
    end
    return aiming, fire
end

local function hook_stream(child)
    if not child:IsA("UnreliableRemoteEvent") then
        return
    end
    if hookedStreams[child.Name] then
        return
    end
    hookedStreams[child.Name] = true
    local streamId = child.Name                  -- = tostring(ingame_id)
    conns[#conns + 1] = child.OnClientEvent:Connect(function(data)
        if not running then
            return
        end
        local ok, aiming, fire = pcall(decode_stream, data)
        if not ok or aiming == nil then
            return
        end
        local state = netState[streamId]
        if not state then
            state = {}
            netState[streamId] = state
        end
        state.aim = aiming
        state.fire = fire or 0
        state.t = clock()
    end)
end

pcall(function()
    local actions = RS:WaitForChild("actions", 10)
    local streams = actions and actions:FindFirstChild("replication_streams")
    if not streams then
        return
    end
    for _, child in ipairs(streams:GetChildren()) do
        hook_stream(child)
    end
    conns[#conns + 1] = streams.ChildAdded:Connect(hook_stream)
end)

--======================================================================
--  RAYCAST / LOS / ПРОБИТИЕ
--======================================================================
local rayForward, rayBackward
pcall(function()
    rayForward = RaycastParams.new()
    rayForward.FilterType = Enum.RaycastFilterType.Exclude
    rayBackward = RaycastParams.new()
    rayBackward.FilterType = Enum.RaycastFilterType.Exclude
end)

--[[
    СПИСОК ИСКЛЮЧЕНИЙ ДЛЯ ЛУЧЕЙ — ИСПРАВЛЕНЫ ДВЕ ПРОБЛЕМЫ.

    1) КОРРЕКТНОСТЬ. Раньше сюда шёл LocalPlayer.Character, который в этой игре
       ВСЕГДА nil. То есть наше собственное тело из лучей не исключалось: луч из
       камеры/дула нередко попадал в наш же торс или руки, path_tier возвращал 3
       («закрыто»), и цель считалась невидимой. Отсюда и «ForceHit не форсит», и
       «MultiPoint не работает», и пропадающий muzzle-трейсер. Теперь берём
       настоящую модель из lifetime_state.character.

    2) ПРОИЗВОДИТЕЛЬНОСТЬ. Раньше на КАЖДЫЙ луч создавалась новая таблица и
       дёргался Workspace:FindFirstChild("ignore"). При резолве по костям это
       сотни аллокаций в секунду. Теперь статическая часть (наше тело, ignore,
       камера) собирается один раз и обновляется только при смене тела, а
       модель цели просто подставляется в первый слот.
--]]
local ignoreStatic = {}
local ignoreScratch = {}

local function refresh_ignore_static()
    table.clear(ignoreStatic)
    if myCharacter then
        ignoreStatic[#ignoreStatic + 1] = myCharacter
    end
    local ignoreFolder = Workspace:FindFirstChild("ignore")
    if ignoreFolder then
        ignoreStatic[#ignoreStatic + 1] = ignoreFolder
    end
    local cam = Workspace.CurrentCamera
    if cam then
        ignoreStatic[#ignoreStatic + 1] = cam
    end
    ignoreDirty = false
end

local ignoreStaticAt = 0

local function build_ignore(model)
    -- камера/папка ignore могут смениться без смены тела: подстраховываемся
    local nowI = clock()
    if ignoreDirty or (nowI - ignoreStaticAt) > 2 then
        ignoreStaticAt = nowI
        refresh_ignore_static()
    end
    table.clear(ignoreScratch)
    if model then
        ignoreScratch[1] = model
    end
    for i = 1, #ignoreStatic do
        ignoreScratch[#ignoreScratch + 1] = ignoreStatic[i]
    end
    return ignoreScratch
end

-- тир пути: 0 = чистая видимость, 1 = пробиваемо (тонкая преграда), 3 = закрыто
local function path_tier(fromPos, toPos, model)
    if not rayForward then
        return 0
    end
    local dir = toPos - fromPos
    if dir.Magnitude < 0.05 then
        return 0
    end
    local ignore = build_ignore(model)
    rayForward.FilterDescendantsInstances = ignore
    local ok, hit = pcall(function()
        return Workspace:Raycast(fromPos, dir, rayForward)
    end)
    if not ok then
        return 0
    end
    if hit == nil then
        return 0
    end
    if not CFG.AllowPenetrable then
        return 3
    end
    -- обратный луч: толщина преграды
    rayBackward.FilterDescendantsInstances = ignore
    local ok2, back = pcall(function()
        return Workspace:Raycast(toPos, fromPos - toPos, rayBackward)
    end)
    if not ok2 or back == nil then
        return 3
    end
    local thickness = (hit.Position - back.Position).Magnitude
    if thickness <= CFG.MaxPenetration then
        return 1
    end
    return 3
end

local function direct_path(fromPos, toPos, model)
    return path_tier(fromPos, toPos, model) == 0
end

-- кэш видимости: один raycast на игрока за VisCacheTtl
local visCache = {}

local function is_visible(fromPos, model)
    local now = clock()
    local cached = visCache[model]
    if cached and (now - cached.t) < CFG.VisCacheTtl then
        return cached.v
    end
    local part = model:FindFirstChild("torso") or model:FindFirstChild("humanoid_root_part")
    local vis = false
    if part then
        vis = direct_path(fromPos, part.Position, model)
    end
    visCache[model] = { t = now, v = vis }
    return vis
end

-- сэмплы кости: центр + грань, обращённая к стрелку (0.72 полуразмера по доминантной оси)
local function core_samples(bone, origin)
    if not bone then
        return {}
    end
    local cf = bone.CFrame
    local halfSize = bone.Size * 0.5
    local center = cf.Position
    local toObserver = origin - center
    if toObserver.Magnitude < 0.05 then
        return { center }
    end
    local localDir = cf:VectorToObjectSpace(toObserver.Unit)
    local ax, ay, az = abs(localDir.X), abs(localDir.Y), abs(localDir.Z)
    local rel
    if ax >= ay and ax >= az then
        rel = V3((localDir.X >= 0 and 1 or -1) * halfSize.X * 0.72, 0, 0)
    elseif ay >= az then
        rel = V3(0, (localDir.Y >= 0 and 1 or -1) * halfSize.Y * 0.72, 0)
    else
        rel = V3(0, 0, (localDir.Z >= 0 and 1 or -1) * halfSize.Z * 0.72)
    end
    return { center, cf:PointToWorldSpace(rel) }
end

local function apply_inset(bone, point)
    local inset = CFG.ResolverInset
    if not bone or inset <= 0 then
        return point
    end
    local dir = bone.CFrame.Position - point
    if dir.Magnitude < 0.04 then
        return point
    end
    return point + dir.Unit * min(inset, dir.Magnitude * 0.35)
end

--======================================================================
--  ЛОКАЛЬНОЕ ДУЛО
--======================================================================
local function muzzle_cframe()
    if not ctrl then
        return nil
    end
    local ok, cf = pcall(function()
        return ctrl.weapon.viewmodel.receiver.barrel.WorldCFrame
    end)
    if ok and typeof(cf) == "CFrame" then
        return cf
    end
    return nil
end

local function aim_origin()
    local m = muzzle_cframe()
    if m then
        return m.Position
    end
    local cam = Workspace.CurrentCamera
    if cam then
        return cam.CFrame.Position
    end
    return ZERO3
end

--======================================================================
--  MULTIPOINT = ПОИСК СМЕЩЕНИЯ ДУЛА (binary peek), как в BRM5Lib
--======================================================================
local mpCache = {}

local function mp_cache_key(origin, part)
    local partId = part and tostring(part) or "nil"
    return string.format("lite|%.1f|%.1f|%.1f|%s", origin.X, origin.Y, origin.Z, partId)
end

--[[
    Направления «выглядывания» стволом. В BRM5 их всего три (право/лево/вверх).
    Расширено: добавлены низ и четыре диагонали — заметно больше шансов найти
    щель у угла/укрытия. Порядок важен: сначала дешёвые горизонтальные (чаще
    всего именно они и срабатывают у угла), затем вертикаль, потом диагонали.
--]]
local function mp_dirs(cam)
    local cf = cam and cam.CFrame
    local right = cf and cf.RightVector or V3(1, 0, 0)
    local up    = cf and cf.UpVector or V3(0, 1, 0)
    if not CFG.MPExtraDirs then
        return { right, -right, up }
    end
    local diagUR = (right + up)
    local diagUL = (-right + up)
    local diagDR = (right - up)
    local diagDL = (-right - up)
    return {
        right, -right, up, -up,
        diagUR.Magnitude > 0.001 and diagUR.Unit or right,
        diagUL.Magnitude > 0.001 and diagUL.Unit or -right,
        diagDR.Magnitude > 0.001 and diagDR.Unit or right,
        diagDL.Magnitude > 0.001 and diagDL.Unit or -right,
    }
end

local function binary_peek(origin, aimPoint, part, dir, maxOffset, steps)
    local lo = 0.25
    local hi = maxOffset
    local best = nil
    local model = part and part.Parent
    for _ = 1, steps do
        local mid = (lo + hi) * 0.5
        local candidate = origin + dir * mid
        if (candidate - origin).Magnitude <= maxOffset + 0.05
            and direct_path(candidate, aimPoint, model) then
            best = candidate
            hi = mid
        else
            lo = mid
        end
    end
    return best
end

-- возвращает spoofOrigin, ok
local function find_multipoint(origin, aimPoint, part, cam)
    local model = part and part.Parent
    if not CFG.MultiPoint then
        return origin, direct_path(origin, aimPoint, model)
    end
    local now = clock()
    local key = mp_cache_key(origin, part)
    local cached = mpCache[key]
    local dist = part and (part.Position - origin).Magnitude or 0
    local ttl = CFG.MPCacheSec * (1 + dist / CFG.MPDistScale)

    if cached then
        if cached.ok and (now - cached.t) < ttl
            and cached.spoof and direct_path(cached.spoof, aimPoint, model) then
            return cached.spoof, true
        elseif not cached.ok and (now - cached.t) < 0.08 then
            return nil, false
        end
    end

    if direct_path(origin, aimPoint, model) then
        mpCache[key] = { ok = true, spoof = origin, t = now }
        return origin, true
    end

    for _, dir in ipairs(mp_dirs(cam)) do
        local best = binary_peek(origin, aimPoint, part, dir, CFG.MPMaxOffset, CFG.MPBinarySteps)
        if best then
            mpCache[key] = { ok = true, spoof = best, t = now }
            return best, true
        end
    end

    mpCache[key] = { ok = false, t = now }
    return nil, false
end

--======================================================================
--  RESOLVER LITE  (кость, выглядывающая из укрытия)
--======================================================================
local RESOLVER_BONES = { "head", "torso" }

local function resolve_lite(origin, model)
    if not CFG.Resolver then
        return nil, nil
    end
    for _, boneName in ipairs(RESOLVER_BONES) do
        local bone = model:FindFirstChild(boneName)
        if bone then
            local samples = core_samples(bone, origin)
            local center = samples[1]
            local edge = samples[2]
            if center and direct_path(origin, center, model) then
                return bone, center
            end
            if edge and direct_path(origin, edge, model) then
                return bone, apply_inset(bone, edge)
            end
        end
    end
    return nil, nil
end

--======================================================================
--  ПРЕДИКТ  (упреждение по реальной модели полёта пули этой игры)
--======================================================================
--[[
    Движок считает позицию пули так (caster.path_position_at_lifetime):

        pos(t) = origin
               + dir.Unit * (velocity * t) / (t * velocity_drop + 1)
               + gravity * t^2
               + GlobalWind * t^2 * 4

    где gravity = Vector3.new(0, -workspace.Gravity, 0).
    Пройденная вдоль ствола дистанция: d(t) = v*t / (t*vd + 1).
    Отсюда время до дистанции D в замкнутом виде:
        v*t = D*(t*vd + 1)  ->  t = D / (v - D*vd)     (при v > D*vd)

    Упреждение: цель за это время уедет на targetVel * t, а саму пулю снесёт
    вниз и ветром — эти члены компенсируем, поднимая точку прицела.
    Дистанция зависит от смещённой точки, поэтому пара итераций сходимости.
--]]
local velTrack = {}          -- [model] = { pos, t, vel }

local function track_velocity(model)
    local hrp = model:FindFirstChild("humanoid_root_part")
    if not hrp then
        return ZERO3
    end
    local now = clock()
    local pos = hrp.Position
    local rec = velTrack[model]
    if not rec then
        velTrack[model] = { pos = pos, t = now, vel = ZERO3 }
        return ZERO3
    end
    local dt = now - rec.t
    --[[
        Порог снижен с 0.03 до 0.016 (кадр), а сглаживание поднято до 0.6.
        Причина: прошлый вариант сам добавлял 50-70 мс запаздывания к оценке
        скорости — поверх и без того 190 мс отката репликации. По бегущим это
        складывалось в промах. Позиция чужой модели уже интерполирована
        буфером, поэтому она гладкая и часто семплировать её безопасно.
    --]]
    if dt >= 0.016 then
        local raw = (pos - rec.pos) / dt
        --[[
            Отсечка рывков. При респавне/телепорте модель прыгает на десятки
            студов за кадр, и raw получается сотнями — такой лид уводил
            прицел в пустоту. Считаем это не движением, а сменой позиции.
        --]]
        if raw.Magnitude > CFG.PredictMaxTargetSpeed then
            rec.vel = ZERO3
        else
            rec.vel = rec.vel + (raw - rec.vel) * 0.6
        end
        rec.pos = pos
        rec.t = now
    end
    return rec.vel
end

--[[
    Откат репликации в СЕКУНДАХ, прочитанный из живого SHARED_STATE.
    Читаем через кэш: значение статичное, а обращение к SHARED_STATE на каждую
    кость каждой цели — лишняя работа в самом горячем месте.
--]]
local rollbackSec = 0.19
local rollbackReadAt = 0

local function replication_rollback()
    if not CFG.PredictRollback then
        return 0
    end
    local now = clock()
    if now - rollbackReadAt > 2 then
        rollbackReadAt = now
        pcall(function()
            local ms = SHARED and SHARED.plr_replication_rollback_time_ms
            if ms and type(ms.value) == "number" and ms.value > 0 then
                rollbackSec = ms.value / 1000
            end
        end)
    end
    return rollbackSec * CFG.PredictRollbackFactor
end

--[[
    ПАРАМЕТРЫ БОЕПРИПАСА — ИСПРАВЛЕН ПУТЬ (вторая причина непопаданий).
    Раньше читалось ctrl.weapon.build_result.ammunition. Такое поле в игре
    ЕСТЬ, но только у редактора обвесов (BallisticsPanel), а не у живого
    оружия. Рантайм читает иначе:
        FPC_extend:730        weapon.build.result.ammunition
        dl_replicator:636,699 build.result.ammunition
    Обращение было в pcall, поэтому падало ТИХО, и предикт всегда работал на
    запасных 900 ст/с с нулевым падением. Для пистолета (~350) или снайперки
    это давало заметно неверный лид — по движущимся мы просто не попадали.
    Основной путь теперь верный, старый оставлен как запасной.
--]]
local function ammo_ballistics()
    local velocity, drop = CFG.PredictFallbackSpeed, 0
    if not ctrl then
        return velocity, drop
    end
    local ammo = nil
    pcall(function()
        ammo = ctrl.weapon.build.result.ammunition
    end)
    if ammo == nil then
        pcall(function()
            ammo = ctrl.weapon.build_result.ammunition
        end)
    end
    if type(ammo) == "table" then
        local v = rawget(ammo, "velocity")
        if type(v) == "number" and v > 1 then
            velocity = v
        end
        local d = rawget(ammo, "velocity_drop")
        if type(d) == "number" then
            drop = d
        end
    end
    return velocity, drop
end

-- время полёта до дистанции D
local function travel_time(dist, velocity, drop)
    local denom = velocity - dist * drop
    if denom <= 1 then
        return dist / max(velocity, 1)      -- вне разумного диапазона
    end
    return dist / denom
end

local function predict_point(model, origin, basePoint)
    if not CFG.Prediction then
        return basePoint
    end
    local targetVel = track_velocity(model)
    local velocity, drop = ammo_ballistics()
    local gravY = -Workspace.Gravity
    local wind = ZERO3
    if CFG.PredictWind then
        local okw, w = pcall(function() return Workspace.GlobalWind end)
        if okw and typeof(w) == "Vector3" then
            wind = w
        end
    end

    --[[
        Откат репликации добавляется к ЛИДУ ЦЕЛИ, но НЕ к компенсации падения
        пули. Это принципиально: пуля летит travel_time и падает именно за это
        время, а вот цель за прошедшие 190 мс уже уехала — то есть её надо
        доводить дальше, а траекторию пули считать как есть. Раньше эти 190 мс
        не учитывались вообще, поэтому по бегущим мы стреляли им в спину.
    --]]
    local rb = replication_rollback()

    local aim = basePoint
    for _ = 1, CFG.PredictIterations do
        local dist = (aim - origin).Magnitude
        local t = travel_time(dist, velocity, drop)
        if CFG.PredictMaxTime > 0 and t > CFG.PredictMaxTime then
            t = CFG.PredictMaxTime
        end
        local lead = targetVel * (t + rb)
        if not CFG.PredictVertical then
            lead = V3(lead.X, 0, lead.Z)
        end
        -- компенсация падения пули и ветра (в модели именно t^2, без 1/2)
        local dropComp = V3(0, -(gravY * t * t), 0) - wind * (t * t * 4)
        aim = basePoint + lead + dropComp
    end
    return aim
end

--======================================================================
--  ВЫБОР ЦЕЛИ  (веса BRM5, FOV по УГЛУ, sticky) — вызывается ТРОТТЛЕННО
--======================================================================
local Target = {
    pos = nil,
    model = nil,
    ent = nil,
    tier = 3,
    spoof = nil,
    bone = nil,
    t = 0,
}

local function fov_half_deg()
    return clamp(CFG.SilentAimFOV, 1, 179) * 0.5
end

local function fov_radius_px(cam)
    local vp = cam.ViewportSize
    local focal = (vp.Y * 0.5) / tan(rad((cam.FieldOfView or 70) * 0.5))
    return max(tan(rad(clamp(CFG.SilentAimFOV, 1, 179) * 0.5)) * focal, 1)
end

local function angle_from_look(cam, worldPos)
    local look = cam.CFrame.LookVector
    local toTarget = worldPos - cam.CFrame.Position
    if toTarget.Magnitude < 0.01 then
        return 0
    end
    return deg(acos(clamp(look:Dot(toTarget.Unit), -1, 1)))
end

local function bone_name_for(depth)
    local bone = CFG.AimBone
    if bone == "auto" then
        return (depth <= 140) and "head" or "torso"
    end
    return bone
end

-- полный резолв цели (дорогой); вызывается не чаще AimResolveInterval
local function resolve_target()
    local prev = {
        pos = Target.pos, model = Target.model, ent = Target.ent, tier = Target.tier,
        spoof = Target.spoof, bone = Target.bone, t = Target.t,
    }
    Target.pos = nil
    Target.model = nil
    Target.ent = nil
    Target.tier = 3
    Target.spoof = nil
    Target.bone = nil

    if not CFG.SilentAim then
        return
    end
    local cam = Workspace.CurrentCamera
    local folder = Workspace:FindFirstChild("characters")
    if not cam or not folder then
        return
    end

    local origin = aim_origin()
    local maxAngle = fov_half_deg()
    -- LocalPlayer.Character в этой игре всегда nil: берём модель из lifetime_state
    local myChar = myCharacter
    local now = clock()

    -- ФАЗА 1: дешёвый гейт (FOV-угол + дистанция), собираем кандидатов
    local candidates = {}
    for _, model in ipairs(folder:GetChildren()) do
        if model ~= myChar then
            local ent = entByModel[model]
            if is_enemy(ent) then
                local hrp = model:FindFirstChild("humanoid_root_part")
                if hrp then
                    local dist = (origin - hrp.Position).Magnitude
                    if dist <= CFG.SilentAimMaxDist then
                        local anchor = model:FindFirstChild("torso") or hrp
                        local angle = angle_from_look(cam, anchor.Position)
                        if angle <= maxAngle then
                            candidates[#candidates + 1] = {
                                model = model, ent = ent, dist = dist, angle = angle,
                            }
                        end
                    end
                end
            end
        end
    end

    -- сортировка кандидатов по грубому приоритету (угол важнее, дистанция вторична)
    table.sort(candidates, function(a, b)
        return (a.angle + a.dist * 0.02) < (b.angle + b.dist * 0.02)
    end)

    -- ФАЗА 2: дорогой резолв (MultiPoint / Resolver) только для топ-N
    local bestScore = math.huge
    local best = nil
    local resolved = 0
    for _, cand in ipairs(candidates) do
        if resolved >= CFG.MPMaxTargets then
            break
        end
        resolved += 1

        local model = cand.model
        local ent = cand.ent
        local dist = cand.dist
        local angle = cand.angle

        local boneName = bone_name_for(dist)
        local bone = model:FindFirstChild(boneName) or model:FindFirstChild("torso")
        if bone then
            -- ПРЕДИКТ: сервер симулирует пулю сам, поэтому целимся туда, где
            -- цель окажется к моменту прилёта (с учётом скорости патрона,
            -- падения и ветра). Проверки видимости идут уже по этой точке.
            local aimPt = predict_point(model, origin, bone.Position)
            local tier = 3
            local spoof = nil

            if direct_path(origin, aimPt, model) then
                tier = 0
                spoof = origin
            else
                local sp, ok = find_multipoint(origin, aimPt, bone, cam)
                -- MultiPoint по альтернативной кости: голова закрыта -> торс
                -- (и наоборот). Часто щель есть только к одной из них.
                if not ok and CFG.MPTryOtherBone then
                    local altName = (boneName == "head") and "torso" or "head"
                    local altBone = model:FindFirstChild(altName)
                    if altBone then
                        local altPt = altBone.Position
                        if direct_path(origin, altPt, model) then
                            tier = 0
                            spoof = origin
                            aimPt = altPt
                            bone = altBone
                        else
                            local sp2, ok2 = find_multipoint(origin, altPt, altBone, cam)
                            if ok2 and sp2 then
                                sp, ok = sp2, true
                                aimPt = altPt
                                bone = altBone
                            end
                        end
                    end
                end
                if tier == 0 then
                    -- альтернативная кость оказалась в прямой видимости
                elseif ok and sp then
                    tier = 1
                    spoof = sp
                else
                    local rBone, rPoint = resolve_lite(origin, model)
                    if rBone and rPoint then
                        tier = 2
                        spoof = origin
                        aimPt = rPoint
                        bone = rBone
                    else
                        local pt = path_tier(origin, aimPt, model)
                        if pt == 1 and CFG.AllowPenetrable then
                            tier = 1
                            spoof = origin
                        end
                    end
                end
            end

            if tier < 3 or not CFG.SkipBlocked then
                local playerBias = -500
                local score = (TIER_WEIGHT[tier] or 3800) + angle * 12 + dist * 0.008 + playerBias
                if score < bestScore and aimPt then
                    bestScore = score
                    best = {
                        pos = aimPt, model = model, ent = ent, tier = tier,
                        spoof = spoof, bone = bone,
                    }
                end
            end

            --[[
                РАННИЙ ВЫХОД (главная экономия).
                Кандидаты уже отсортированы по «углу + дистанции», поэтому
                первый, у кого прямая видимость (tier 0), почти всегда и есть
                нужная цель. Раньше мы всё равно прогоняли дорогой MultiPoint
                по остальным — это и создавало лаги.
            --]]
            if tier == 0 then
                break
            end
        end
    end

    if best then
        Target.pos = best.pos
        Target.model = best.model
        Target.ent = best.ent
        Target.tier = best.tier
        Target.spoof = best.spoof
        Target.bone = best.bone
        Target.t = now
    elseif prev.model and prev.model.Parent ~= nil
        and (now - (prev.t or 0)) < CFG.MPStickySec and is_enemy(prev.ent) then
        -- sticky: держим прошлую цель, если она ещё в FOV И путь ещё открыт
        local anchor = prev.model:FindFirstChild("torso") or prev.model:FindFirstChild("humanoid_root_part")
        if anchor and angle_from_look(cam, anchor.Position) <= maxAngle
            and direct_path(prev.spoof or origin, prev.pos or anchor.Position, prev.model) then
            Target.pos = prev.pos
            Target.model = prev.model
            Target.ent = prev.ent
            Target.tier = prev.tier
            Target.spoof = prev.spoof
            Target.bone = prev.bone
            Target.t = prev.t
        end
    end
end

-- лёгкая покадровая проверка живости цели (без raycast)
local function validate_target()
    if Target.model and Target.model.Parent == nil then
        Target.pos = nil
        Target.model = nil
        Target.ent = nil
        Target.tier = 3
        Target.spoof = nil
        Target.bone = nil
    end
end

--======================================================================
--  ПАТЧ ПАКЕТА ВЫСТРЕЛА  (origin + direction)
--======================================================================
local NetEnc
pcall(function()
    NetEnc = require(RS.module.namespace.NetworkEncode).NetworkEncode
end)

local Caster
pcall(function()
    Caster = require(RS.module.caster.caster)
end)

local shotOrigin = nil
local packet_hooked = false

local function hook_packet()
    if packet_hooked or not NetEnc then
        return
    end
    local original = rawget(NetEnc, "write_exact_position")
    if type(original) ~= "function" then
        return
    end
    rawset(NetEnc, "write_exact_position", function(buffer, vec)
        pcall(function()
            if typeof(vec) ~= "Vector3" then
                return
            end
            if vec.Magnitude > 1.01 then
                -- ORIGIN (мировая точка)
                shotOrigin = vec
                if CFG.SilentAim and Target.pos and Target.spoof then
                    shotOrigin = Target.spoof
                    vec = Target.spoof
                end
            else
                -- DIRECTION (unit-вектор)
                if CFG.SilentAim and Target.pos and shotOrigin then
                    local toTarget = Target.pos - shotOrigin
                    if toTarget.Magnitude > 0.001 then
                        vec = toTarget.Unit
                    end
                end
            end
        end)
        return original(buffer, vec)
    end)
    packet_hooked = true
end

--======================================================================
--  ЗВУК ПОПАДАНИЯ
--======================================================================
--[[
    HIT SOUND — по шаблону самой игры.

    Почему прошлые версии молчали (разобрано по дампу):
      1) Звук создавался ЗАНОВО на каждое попадание и проигрывался сразу.
         Ассет в этот момент ещё не загружен -> Play() уходит в пустоту.
      2) Sound не попадал в микшер игры. Игра ведёт весь звук через SoundGroup'ы
         (client/controller/misc/volume: SoundService.master.Volume =
         client_vol), а свои звуки создаёт так
         (insitux/luau/lib/luau_client_library, sound.create):
             Sound.SoundGroup = SoundService.master.ingame.main
             Sound.Parent     = Workspace
         затем Timescale.play_sound -> Sound:Play().
      Поэтому делаем ровно так же: ОДИН предзагруженный Sound в нужной группе,
      на попадании просто перезапускаем его.
--]]
--[[
    HIT SOUND — вернул РОВНО тот вариант, который работал.

    Что я сломал «улучшениями»:
      • один переиспользуемый Sound вместо нового на каждый хит: при частых
        попаданиях перезапуск через TimePosition вместо Play() глушил звук,
        а если игра чистила Workspace — инстанс терялся;
      • SoundGroup = SoundService.master.ingame.main: звук уходил в микшер
        игры, где группа может быть тихой/выключенной (в лобби — точно);
      • родитель Workspace вместо SoundService.
    Рабочая схема простая: НОВЫЙ Sound на каждое попадание, родитель
    SoundService, БЕЗ SoundGroup, обычный :Play(), уборка через Debris.
--]]
local lastHitSoundAt = 0
local hitSoundRoute = "?"          -- какой способ реально сработал
local warmSound = nil              -- держим ассет прогретым

--[[
    ПОЧЕМУ ЗВУКА НЕ БЫЛО — две ошибки сразу, обе мои:

    1) sound.Parent = SoundSvc, где SoundSvc это cloneref-ПРОКСИ сервиса.
       Назначение Parent на прокси может не сработать: инстанс остаётся без
       родителя, а Play() у беспарентного Sound молчит.
    2) Вся цепочка стояла в ОДНОМ pcall. Если падало назначение Parent, то
       sound:Play() уже не вызывался — и ошибку глотал pcall. Тишина без следов.

    Теперь: сырой сервис (без cloneref), каждый шаг в своём pcall, основной
    путь — PlayLocalSound (ему родитель вообще не нужен), плюс запасной путь
    через Parent+Play. SoundGroup не ставим: в микшере игры группа может быть
    приглушена (в прошлой версии это добивало и PlayLocalSound).
--]]
local RawSoundService = game:GetService("SoundService")

local function build_hit_sound()
    local s = nil
    pcall(function()
        s = Instance.new("Sound")
        s.SoundId = "rbxassetid://" .. tostring(CFG.HitSoundId)
        s.Volume = clamp(CFG.HitSoundVolume, 0, 10)
        s.PlaybackSpeed = clamp(CFG.HitSoundPitch, 0.5, 2)
        s.Looped = false
    end)
    return s
end

-- прогреваем ассет заранее, чтобы первое попадание уже звучало
local function warm_hit_sound()
    if warmSound and warmSound.Parent then
        return
    end
    local s = build_hit_sound()
    if not s then
        return
    end
    pcall(function()
        s.Volume = 0
        s.Parent = RawSoundService
    end)
    warmSound = s
end

local function play_hit_sound()
    if not CFG.HitSound then
        return
    end
    -- защита от дубля: звук зовётся и из network_hit, и из ForceHit
    local now = clock()
    if now - lastHitSoundAt < 0.04 then
        return
    end
    lastHitSoundAt = now

    --[[
        РОВНО КАК В BRM5 (silentaim.lua:950 playLocalHitSound):
            s.Parent = game:GetService("SoundService")
            s:Play()
            Debris:AddItem(s, 4)
        Никакого PlayLocalSound. Моя прошлая версия пробовала его ПЕРВЫМ и при
        успехе выходила — а он fire-and-forget: если ассет не в кэше именно в
        этот момент, звука нет, и до рабочего пути дело уже не доходило.
        Parent+Play держит Sound в дереве 4 секунды (Debris), поэтому ассет
        успевает догрузиться и звук всё равно играет.
    --]]
    local copies = clamp(CFG.HitSoundStack or 1, 1, 4)
    for _ = 1, copies do
        pcall(function()
            local s = Instance.new("Sound")
            s.SoundId = "rbxassetid://" .. tostring(CFG.HitSoundId)
            -- 0..10 — настоящий диапазон Roblox, раньше здесь стоял потолок 1
            s.Volume = clamp(CFG.HitSoundVolume, 0, 10)
            s.PlaybackSpeed = clamp(CFG.HitSoundPitch, 0.5, 2)
            s.Parent = RawSoundService
            s:Play()
            Debris:AddItem(s, 4)
            hitSoundRoute = "Parent+Play"
        end)
    end
end

--======================================================================
--  HIT PARTICLES  (Wireframe / Orbs / Sparks)
--======================================================================
--======================================================================
--  ПУЛ Drawing для частиц (переиспользование вместо Drawing.new на выстрел)
--======================================================================
local drawPool = { Line = {}, Circle = {} }

local function acquire_draw(kind)
    local free = drawPool[kind]
    local obj = free[#free]
    if obj then
        free[#free] = nil
        obj.Visible = false
        return obj
    end
    obj = Drawing.new(kind)
    obj.ZIndex = 9
    obj.Visible = false
    return obj
end

local function release_draw(kind, obj)
    obj.Visible = false
    local free = drawPool[kind]
    if #free < 512 then
        free[#free + 1] = obj
    else
        pcall(function() obj:Remove() end)
    end
end

local function release_particle(particle)
    local kind = (particle.kind == "Line") and "Line" or particle.kind
    for _, drawing in ipairs(particle.draw) do
        release_draw(particle.kind, drawing)
    end
end

local TETRA_VERTS = { V3(1, 1, 1), V3(1, -1, -1), V3(-1, 1, -1), V3(-1, -1, 1) }
local TETRA_EDGES = { {1, 2}, {1, 3}, {1, 4}, {2, 3}, {2, 4}, {3, 4} }
local particleSystems = {}

local function lerp_color(a, b, t)
    return Color3.new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t)
end

local function spawn_particles(pos, normal)
    if not CFG.HitParticles then
        return
    end
    if #particleSystems >= CFG.HitParticleMaxSys then
        local old = table.remove(particleSystems, 1)
        if old then
            for _, particle in ipairs(old.parts) do
                release_particle(particle)
            end
        end
    end

    normal = (typeof(normal) == "Vector3" and normal.Magnitude > 0.01) and normal.Unit or V3(0, 1, 0)
    local right = normal:Cross(V3(0, 1, 0))
    if right.Magnitude < 0.01 then
        right = normal:Cross(V3(1, 0, 0))
    end
    right = right.Unit
    local fwd = normal:Cross(right).Unit

    local sys = { t = clock(), parts = {} }
    local count = clamp(CFG.HitParticleCount, 8, 48)
    for _ = 1, count do
        local theta = rnd() * pi * 2
        local phi = acos(clamp(1 - rnd() * 1.85, -1, 1))
        local dir = normal * cos(phi)
            + right * (sin(phi) * cos(theta))
            + fwd * (sin(phi) * sin(theta))
            + V3((rnd() - 0.5) * 0.35, (rnd() - 0.2) * 0.25, (rnd() - 0.5) * 0.35)
        if dir.Magnitude < 0.001 then
            dir = normal
        end
        dir = dir.Unit
        local z = rnd()
        local speed = CFG.HitParticleSpdMin + z * (CFG.HitParticleSpdMax - CFG.HitParticleSpdMin)
        local particle = {
            pos = pos + dir * rnd() * 0.12,
            vel = dir * speed + V3((rnd() - 0.5) * 5, rnd() * 4, (rnd() - 0.5) * 5),
            z = z,
            phase = rnd(),
            ang = rnd() * pi * 2,
            angVel = (rnd() - 0.5) * 4,
            scale = CFG.HitParticleWireS * (0.6 + z * 0.8),
            draw = {},
        }
        if CFG.HitParticleType == "Wireframe" then
            particle.kind = "Line"
            for _ = 1, #TETRA_EDGES do
                local line = acquire_draw("Line")
                line.Thickness = 0.7
                particle.draw[#particle.draw + 1] = line
            end
        elseif CFG.HitParticleType == "Orbs" then
            particle.kind = "Circle"
            local circle = acquire_draw("Circle")
            circle.Filled = true
            circle.NumSides = 12
            particle.draw[1] = circle
        else
            particle.kind = "Line"
            local line = acquire_draw("Line")
            line.Thickness = 1.5
            particle.draw[1] = line
        end
        sys.parts[#sys.parts + 1] = particle
    end
    particleSystems[#particleSystems + 1] = sys
end

local function update_particles(cam, dt)
    local duration = CFG.HitParticleDur
    local gravity = V3(0, CFG.HitParticleGrav, 0)
    local now = clock()
    for si = #particleSystems, 1, -1 do
        local sys = particleSystems[si]
        local age = now - sys.t
        if age > duration then
            for _, particle in ipairs(sys.parts) do
                release_particle(particle)
            end
            table.remove(particleSystems, si)
        else
            local fadeIn = duration * 0.15
            local fadeOut = duration * 0.75
            local fade
            if age < fadeIn then
                local t = age / fadeIn
                fade = t * (2 - t)
            elseif age > fadeOut then
                local t = (age - fadeOut) / (duration - fadeOut)
                fade = (1 - t) * (1 - t)
            else
                fade = 1
            end
            local pulseT = (sin(age * 3.2) + 1) * 0.5
            local step = min(dt, 0.05)
            local drag = clamp(1 - step * 0.35, 0.55, 1)
            for _, particle in ipairs(sys.parts) do
                particle.vel = (particle.vel + gravity * step) * drag
                particle.pos = particle.pos + particle.vel * step
                particle.ang = particle.ang + particle.angVel * step
                local screen, onScreen = cam:WorldToViewportPoint(particle.pos)
                local opacity = (CFG.HitParticleOpMin + (CFG.HitParticleOpMax - CFG.HitParticleOpMin) * particle.z) * fade
                local color = lerp_color(CFG.HitParticleColorA, CFG.HitParticleColorB, (pulseT + particle.phase) % 1)
                if onScreen and screen.Z > 0 then
                    if CFG.HitParticleType == "Wireframe" then
                        local s = particle.scale * (0.85 + 0.15 * sin(age * 4 + particle.phase))
                        local ca, sa = cos(particle.ang), sin(particle.ang)
                        local proj = {}
                        for vi, v in ipairs(TETRA_VERTS) do
                            local rotated = V3(v.X * ca - v.Z * sa, v.Y, v.X * sa + v.Z * ca) * s
                            local q, qo = cam:WorldToViewportPoint(particle.pos + rotated)
                            proj[vi] = qo and V2(q.X, q.Y) or nil
                        end
                        for ei, edge in ipairs(TETRA_EDGES) do
                            local line = particle.draw[ei]
                            local a, b = proj[edge[1]], proj[edge[2]]
                            if line and a and b then
                                line.Visible = true
                                line.Color = color
                                line.Thickness = 0.65 + particle.z * 0.45
                                line.Transparency = opacity
                                line.From = a
                                line.To = b
                            elseif line then
                                line.Visible = false
                            end
                        end
                    elseif CFG.HitParticleType == "Orbs" then
                        local circle = particle.draw[1]
                        if circle then
                            circle.Visible = true
                            circle.Color = color
                            circle.Transparency = opacity
                            circle.Position = V2(screen.X, screen.Y)
                            circle.Radius = max(0.45, (0.28 + particle.z * 0.62) * 17 / max(screen.Z, 1))
                        end
                    else
                        local line = particle.draw[1]
                        if line then
                            local tail = clamp(particle.vel.Magnitude * 0.035, 0.05, 0.9)
                            local q, qo = cam:WorldToViewportPoint(particle.pos - particle.vel.Unit * tail)
                            if qo then
                                line.Visible = true
                                line.Color = color
                                line.Transparency = opacity
                                line.From = V2(screen.X, screen.Y)
                                line.To = V2(q.X, q.Y)
                            else
                                line.Visible = false
                            end
                        end
                    end
                else
                    for _, drawing in ipairs(particle.draw) do
                        drawing.Visible = false
                    end
                end
            end
        end
    end
end

--======================================================================
--  SHOT TRACERS  (fade-кривая BRM5)
--======================================================================
local tracers = {}
local TRACER_MAX = 20
local tracerLines = {}
for i = 1, TRACER_MAX do
    local line = Drawing.new("Line")
    line.ZIndex = 30
    line.Visible = false
    tracerLines[i] = line
end

local function tracer_alpha(age, life, fadeIn)
    if age < fadeIn then
        local t = age / fadeIn
        return t * t
    end
    local tail = life - fadeIn
    if tail <= 0.01 then
        return 0
    end
    local t = (age - fadeIn) / tail
    return (1 - t) * (1 - t)
end

--======================================================================
--  FORCE HIT  +  отлов id пули  (ТОЛЬКО СВОИ выстрелы)
--======================================================================
local claimedBullets = {}
local fire_hooked = false
local nh_hooked = false

local function hook_network_hit()
    if nh_hooked or not Caster then
        return
    end
    local original = rawget(Caster, "network_hit")
    if type(original) ~= "function" then
        return
    end
    rawset(Caster, "network_hit", function(id, targetId, parts, ...)
        --[[
            ВАЖНО: каждый эффект в СВОЁМ pcall.
            Раньше звук стоял последним в общем pcall вместе с поиском сущности
            и частицами — любая ошибка выше (нет сущности, сбой частиц) съедала
            вызов, и HitSound молчал.
        --]]
        pcall(function()
            claimedBullets[id] = true
        end)

        -- звук — первым и независимо: он должен играть на любое попадание
        pcall(play_hit_sound)

        local hitName = nil
        pcall(function()
            local ent = entByIngame[tostring(targetId)]
            if not ent then
                return
            end
            local dmg = 0
            if type(parts) == "table" then
                for _, partName in pairs(parts) do
                    hitName = hitName or partName
                    if partName == "head" then
                        dmg += 100
                    elseif partName == "torso" then
                        dmg += 40
                    else
                        dmg += 22
                    end
                end
            end
            ent.__hp = max(0, (ent.__hp or 100) - (dmg > 0 and dmg or 22))
        end)

        -- частицы отдельно: их сбой не должен глушить звук/урон
        pcall(function()
            if not CFG.HitParticles then
                return
            end
            local ent = entByIngame[tostring(targetId)]
            local model = ent and rawget(ent, "character")
            local part = model and (model:FindFirstChild(hitName or "torso") or model:FindFirstChild("torso"))
            if part then
                spawn_particles(part.Position, aim_origin() - part.Position)
            end
        end)

        return original(id, targetId, parts, ...)
    end)
    nh_hooked = true
end

local function hook_fire()
    if fire_hooked or not Caster then
        return
    end
    local original = rawget(Caster, "fire")
    if type(original) ~= "function" then
        return
    end
    rawset(Caster, "fire", function(player, origin, direction, user_data, character, ...)
        -- ТОЛЬКО наши пули: чужие идут с другим player и флагом replicated
        local isLocalShot = (player == LocalPlayer)
            and not (type(user_data) == "table" and user_data.replicated == true)

        if isLocalShot then
            local id = type(user_data) == "table" and user_data.id or nil
            local targetPos = Target.pos
            local targetEnt = Target.ent

            --[[
                ЛОКАЛЬНЫЙ ВИЗУАЛ СПУФА.
                Патч пакета меняет только то, что уходит на сервер. Локальная
                симуляция (трассер/пуля движка) стреляет из НАСТОЯЩЕГО ствола,
                поэтому "визуально пуля летит с того же места". Подменяем origin
                и направление и для локального вызова — тогда MultiPoint видно.
            --]]
            if CFG.SpoofLocalVisual and CFG.SilentAim and targetPos and Target.spoof then
                if typeof(Target.spoof) == "Vector3" then
                    origin = Target.spoof
                    local toTarget = targetPos - Target.spoof
                    if toTarget.Magnitude > 0.001 then
                        direction = toTarget.Unit
                    end
                end
            end

            pcall(function()
                local from = (CFG.SpoofLocalVisual and Target.spoof) or shotOrigin or origin
                if CFG.ShotTracers and typeof(from) == "Vector3" then
                    local dest = targetPos
                    if not dest and typeof(direction) == "Vector3" then
                        dest = from + direction * 400
                    end
                    if dest then
                        tracers[#tracers + 1] = { a = from, b = dest, t = clock() }
                    end
                end
            end)

            --[[
                FORCE HIT.
                Движок формирует таблицу попаданий как parts[floor(distance)] = partName
                (caster.penetrate_humanoid_char: v61[floor(mag)] = имя части), а целью
                служит tonumber(model.Name) == ingame_id. Раньше слали {[0]="torso"} —
                ключ 0 и всегда торс: и часть не та, и форма таблицы нетипичная.
                Теперь: часть = реально наведённая кость (или CFG.ForceHitPart),
                ключ = целочисленная дистанция от ствола до этой части.
            --]]
            if CFG.ForceHit and id and targetPos and targetEnt then
                local ingameId = rawget(targetEnt, "ingame_id")
                local model = rawget(targetEnt, "character")
                if ingameId and model then
                    local partName = CFG.ForceHitPart
                    if partName == "auto" or partName == nil then
                        partName = (Target.bone and Target.bone.Name) or CFG.AimBone or "torso"
                    end
                    local hitPart = model:FindFirstChild(partName) or model:FindFirstChild("torso")
                    local partPos = hitPart and hitPart.Position or targetPos
                    local shotFrom = Target.spoof or shotOrigin or origin
                    local distKey = 0
                    if typeof(shotFrom) == "Vector3" and typeof(partPos) == "Vector3" then
                        distKey = floor((partPos - shotFrom).Magnitude)
                    end
                    local parts = {}
                    parts[distKey] = (hitPart and hitPart.Name) or partName
                    local targetId = tonumber(ingameId) or tonumber(model.Name) or ingameId
                    task.delay(CFG.ForceHitDelay, function()
                        if not running or claimedBullets[id] then
                            return
                        end
                        --[[
                            HIT SOUND и здесь тоже.
                            При SilentAim ЛОКАЛЬНАЯ пуля летит по исходному
                            направлению (мы правим только пакет), поэтому в цель
                            она обычно не попадает и caster.network_hit локально
                            НЕ вызывается — из-за этого звук и молчал.
                            Заявку о попадании шлём мы сами, значит и звук
                            воспроизводим здесь.
                        --]]
                        pcall(play_hit_sound)
                        pcall(function()
                            local nh = rawget(Caster, "network_hit")
                            if type(nh) == "function" then
                                nh(id, targetId, parts)
                            end
                        end)
                    end)
                end
            end

            if id then
                task.delay(3, function()
                    claimedBullets[id] = nil
                end)
            end
        end

        return original(player, origin, direction, user_data, character, ...)
    end)
    fire_hooked = true
end

--======================================================================
--  ВИЗУАЛЫ ПРИЦЕЛА  (FOV circle, muzzle lines, reticle)
--======================================================================
local fovCircle = Drawing.new("Circle")
fovCircle.NumSides = 64
fovCircle.ZIndex = 10
fovCircle.Visible = false

local muzzleLine = Drawing.new("Line")
muzzleLine.ZIndex = 44
muzzleLine.Visible = false

local spoofLineA = Drawing.new("Line")  -- дуло -> спуф (жёлтая)
spoofLineA.ZIndex = 43
spoofLineA.Visible = false

local spoofLineB = Drawing.new("Line")  -- спуф -> цель (зелёная)
spoofLineB.ZIndex = 45
spoofLineB.Visible = false

local RETICLE_MAX = 16
local reticleLines = {}
for i = 1, RETICLE_MAX do
    local line = Drawing.new("Line")
    line.ZIndex = 45
    line.Visible = false
    reticleLines[i] = line
end

local function tier_color(tier)
    if CFG.AimVisualColor then
        return CFG.AimVisualColor
    end
    if tier == 0 then
        return Color3.fromRGB(120, 255, 120)
    elseif tier == 1 then
        return Color3.fromRGB(255, 220, 80)
    elseif tier == 2 then
        return Color3.fromRGB(120, 180, 255)
    end
    return Color3.fromRGB(255, 90, 90)
end

local function draw_reticle(cx, cy, color, now)
    for _, line in ipairs(reticleLines) do
        line.Visible = false
    end
    local sc = CFG.AimVisualScale
    local style = CFG.AimVisualStyle
    local baseAlpha = 0.95

    local function seg(i, x1, y1, x2, y2, thickness, alpha)
        local line = reticleLines[i]
        if not line then
            return
        end
        line.Visible = true
        line.From = V2(x1, y1)
        line.To = V2(x2, y2)
        line.Thickness = thickness
        line.Color = color
        line.Transparency = alpha or baseAlpha
    end

    if style == "Default" then
        local arm = 9 * sc
        seg(1, cx - arm, cy, cx + arm, cy, 1.4)
        seg(2, cx, cy - arm, cx, cy + arm, 1.4)
    elseif style == "CrossGap" then
        local gap = 5 * sc
        local arm = 9 * sc
        seg(1, cx - arm, cy, cx - gap, cy, 1.3)
        seg(2, cx + gap, cy, cx + arm, cy, 1.3)
        seg(3, cx, cy - arm, cx, cy - gap, 1.3)
        seg(4, cx, cy + gap, cx, cy + arm, 1.3)
    elseif style == "DefaultV2" then
        local spin = now * 2.8
        local gap = 4 * sc
        local arm = 8 * sc
        for i = 0, 3 do
            local ang = spin + i * pi * 0.5
            seg(i + 1,
                cx + cos(ang) * gap, cy + sin(ang) * gap,
                cx + cos(ang) * (gap + arm), cy + sin(ang) * (gap + arm), 1.35)
        end
    else -- Diamond (пульсирующий)
        local pulse = 0.5 + 0.5 * sin(now * 5.8)
        local r = (6.5 + pulse * 3.5) * sc
        local outerSpin = now * 1.6
        local idx = 0
        for i = 0, 5 do
            local a1 = outerSpin + i * pi / 3
            local a2 = outerSpin + (i + 1) * pi / 3
            idx += 1
            seg(idx, cx + cos(a1) * r, cy + sin(a1) * r,
                     cx + cos(a2) * r, cy + sin(a2) * r, 1.15 + pulse * 0.35)
        end
        local innerSpin = -now * 3.4
        local ig = (2.5 + pulse * 1.2) * sc
        local ia = (5.5 + pulse * 1.8) * sc
        for i = 0, 3 do
            local ang = innerSpin + i * pi * 0.5
            idx += 1
            seg(idx, cx + cos(ang) * ig, cy + sin(ang) * ig,
                     cx + cos(ang) * (ig + ia), cy + sin(ang) * (ig + ia), 1.5)
        end
        local accSpin = now * 4.2
        local tr = r + 2.2 + pulse * 1.5
        for i = 0, 5 do
            if idx >= RETICLE_MAX then
                break
            end
            local ang = accSpin + i * pi / 3
            idx += 1
            seg(idx, cx + cos(ang) * tr, cy + sin(ang) * tr,
                     cx + cos(ang) * (tr + 2.5), cy + sin(ang) * (tr + 2.5), 0.9, baseAlpha * 0.55 * pulse)
        end
    end
end

--======================================================================
--  ESP  —  Drawing-объекты ЗА МОДЕЛЬЮ (без переиспользования по индексу)
--======================================================================
local espByModel = {}

local function make_text(zindex, centered)
    local text = Drawing.new("Text")
    text.Outline = true
    text.Center = centered
    text.ZIndex = zindex
    text.Visible = false
    return text
end

local function new_esp()
    local o = {}
    o.boxLines = {}
    for i = 1, 8 do
        local line = Drawing.new("Line")
        line.ZIndex = 20
        line.Visible = false
        o.boxLines[i] = line
    end
    o.name = make_text(22, true)
    o.dist = make_text(23, true)
    o.weapon = make_text(23, true)
    o.chips = {}
    for i = 1, 6 do
        o.chips[i] = make_text(23, false)
    end
    o.skel = {}
    for i = 1, 12 do
        local line = Drawing.new("Line")
        line.Thickness = 1.4
        line.ZIndex = 19
        line.Visible = false
        o.skel[i] = line
    end
    o.hpOutline = Drawing.new("Square")
    o.hpOutline.Filled = false
    o.hpOutline.Thickness = 1
    o.hpOutline.ZIndex = 17
    o.hpOutline.Color = Color3.fromRGB(8, 8, 8)
    o.hpOutline.Visible = false
    o.hpBg = Drawing.new("Square")
    o.hpBg.Filled = true
    o.hpBg.ZIndex = 18
    o.hpBg.Color = Color3.fromRGB(22, 22, 22)
    o.hpBg.Visible = false
    o.hpFill = Drawing.new("Square")
    o.hpFill.Filled = true
    o.hpFill.ZIndex = 19
    o.hpFill.Visible = false
    o.headCircle = Drawing.new("Circle")
    o.headCircle.Filled = false
    o.headCircle.Thickness = 1.4
    o.headCircle.NumSides = 16
    o.headCircle.ZIndex = 19
    o.headCircle.Visible = false
    o.smooth = nil
    return o
end

local function hide_esp(o)
    for _, line in ipairs(o.boxLines) do
        line.Visible = false
    end
    for _, chip in ipairs(o.chips) do
        chip.Visible = false
    end
    for _, line in ipairs(o.skel) do
        line.Visible = false
    end
    o.name.Visible = false
    o.dist.Visible = false
    o.weapon.Visible = false
    o.hpOutline.Visible = false
    o.hpBg.Visible = false
    o.hpFill.Visible = false
    o.headCircle.Visible = false
end

local function free_esp(o)
    for _, line in ipairs(o.boxLines) do
        pcall(function() line:Remove() end)
    end
    for _, chip in ipairs(o.chips) do
        pcall(function() chip:Remove() end)
    end
    for _, line in ipairs(o.skel) do
        pcall(function() line:Remove() end)
    end
    for _, drawing in ipairs({ o.name, o.dist, o.weapon, o.hpOutline, o.hpBg, o.hpFill, o.headCircle }) do
        pcall(function() drawing:Remove() end)
    end
end

local function adaptive_label_size(lineCount)
    if lineCount >= 5 then
        return LABEL_SIZE - 2
    end
    if lineCount >= 3 then
        return LABEL_SIZE - 1
    end
    return LABEL_SIZE
end

local function weapon_of(ent)
    local ok, name = pcall(function()
        local weapon = ent.equipped_weapon
        if not weapon then
            return nil
        end
        local props = weapon.build and weapon.build.result and weapon.build.result.properties
        if props then
            local general = props.generalData
            if general and general.name then
                return general.name
            end
            return props.name
        end
        return nil
    end)
    if ok and type(name) == "string" then
        return name
    end
    return nil
end

local function states_of(ent)
    local out = {}
    local ns = ent.ingame_id and netState[tostring(ent.ingame_id)]
    local fresh = ns and (clock() - (ns.t or 0) < 1.5)
    if fresh and (ns.fire or 0) > 0.05 then
        out[#out + 1] = "fire"
    end
    if fresh and ns.aim then
        out[#out + 1] = "aim"
    end
    local pose = POSE_NAME[ent.pose]
    if pose == "idle" and (ent.cached_velocity_magnitude or 0) > 2 then
        pose = "walk"
    end
    if pose then
        out[#out + 1] = pose
    end
    if ent.using_nvg then
        out[#out + 1] = "nvg"
    end
    return out
end

-- СТАБИЛЬНЫЙ bbox: HRP + верх головы + ноги, ширина = height*aspect, только Z>0
local function compute_bounds(cam, model)
    local hrp = model:FindFirstChild("humanoid_root_part")
    if not hrp then
        return nil
    end
    local head = model:FindFirstChild("head")
    local headWorld
    if head then
        headWorld = head.Position + V3(0, head.Size.Y * 0.5 + 0.3, 0)
    else
        headWorld = hrp.Position + V3(0, 2.6, 0)
    end
    local feetWorld = hrp.Position - V3(0, 3.0, 0)

    local topScreen, topInFront = cam:WorldToViewportPoint(headWorld)
    local botScreen = cam:WorldToViewportPoint(feetWorld)

    -- отбрасываем только если точка ЗА камерой (не по краю экрана)
    if topScreen.Z <= 0 or botScreen.Z <= 0 then
        return nil
    end

    local topY = min(topScreen.Y, botScreen.Y)
    local botY = max(topScreen.Y, botScreen.Y)
    local height = botY - topY
    if height < 1 then
        return nil
    end
    local width = height * CFG.EspBoxAspect
    local centerX = (topScreen.X + botScreen.X) * 0.5

    return {
        minX = centerX - width * 0.5,
        maxX = centerX + width * 0.5,
        minY = topY,
        maxY = botY,
        centerX = centerX,
        headTopY = topScreen.Y,
        height = height,
        width = width,
    }
end

local function draw_box(o, r, color)
    for _, line in ipairs(o.boxLines) do
        line.Visible = false
    end
    local w = r.maxX - r.minX
    local h = r.maxY - r.minY

    local function ln(i, x1, y1, x2, y2)
        local line = o.boxLines[i]
        if not line then
            return
        end
        line.Visible = true
        line.Color = color
        line.Thickness = CFG.EspBoxThickness
        line.From = V2(x1, y1)
        line.To = V2(x2, y2)
    end

    if CFG.EspBoxMode == "Corner" then
        -- длина уголка = доля стороны, но не длиннее половины (иначе углы сойдутся).
        -- НЕ используем clamp с фикс. min: у мелкого бокса w*0.5 < min -> min>max -> ошибка.
        local cx = min(w * CFG.EspCornerScale, w * 0.5)
        local cy = min(h * CFG.EspCornerScale, h * 0.5)
        -- верх-лево
        ln(1, r.minX, r.minY, r.minX + cx, r.minY)
        ln(2, r.minX, r.minY, r.minX, r.minY + cy)
        -- верх-право
        ln(3, r.maxX - cx, r.minY, r.maxX, r.minY)
        ln(4, r.maxX, r.minY, r.maxX, r.minY + cy)
        -- низ-лево
        ln(5, r.minX, r.maxY - cy, r.minX, r.maxY)
        ln(6, r.minX, r.maxY, r.minX + cx, r.maxY)
        -- низ-право
        ln(7, r.maxX, r.maxY - cy, r.maxX, r.maxY)
        ln(8, r.maxX - cx, r.maxY, r.maxX, r.maxY)
    else
        ln(1, r.minX, r.minY, r.maxX, r.minY)
        ln(2, r.maxX, r.minY, r.maxX, r.maxY)
        ln(3, r.maxX, r.maxY, r.minX, r.maxY)
        ln(4, r.minX, r.maxY, r.minX, r.minY)
    end
end

-- настоящие суставы R6 (шея/таз/плечи/бёдра), красятся ЦВЕТОМ БОКСА
local function skeleton_segments(model)
    local torso = model:FindFirstChild("torso")
    if not torso then
        return nil
    end
    local tc = torso.CFrame
    local ts = torso.Size
    local neck   = (tc * CF(0,  ts.Y * 0.5, 0)).Position
    local pelvis = (tc * CF(0, -ts.Y * 0.5, 0)).Position
    local shoulderL = (tc * CF(-ts.X * 0.5, ts.Y * 0.42, 0)).Position
    local shoulderR = (tc * CF( ts.X * 0.5, ts.Y * 0.42, 0)).Position
    local hipL = (tc * CF(-ts.X * 0.25, -ts.Y * 0.5, 0)).Position
    local hipR = (tc * CF( ts.X * 0.25, -ts.Y * 0.5, 0)).Position

    local function tip(part)
        if not part then
            return nil
        end
        return (part.CFrame * CF(0, -part.Size.Y * 0.5, 0)).Position
    end

    local head = model:FindFirstChild("head")
    local armL = model:FindFirstChild("left_arm_vis")
    local armR = model:FindFirstChild("right_arm_vis")
    local legL = model:FindFirstChild("left_leg_vis")
    local legR = model:FindFirstChild("right_leg_vis")

    return {
        { head and head.Position or neck, neck },
        { neck, pelvis },
        { shoulderL, shoulderR },
        { neck, shoulderL }, { shoulderL, tip(armL) },
        { neck, shoulderR }, { shoulderR, tip(armR) },
        { pelvis, hipL }, { hipL, tip(legL) },
        { pelvis, hipR }, { hipR, tip(legR) },
    }
end

local function update_esp(cam, camPos, vp, model, ent, vis)
    local o = espByModel[model]
    if not o then
        o = new_esp()
        espByModel[model] = o
    end

    local hrp = model:FindFirstChild("humanoid_root_part")
    if not hrp then
        hide_esp(o)
        return
    end
    local depth = (camPos - hrp.Position).Magnitude
    if depth > CFG.EspMaxDistance or depth < 3 then
        hide_esp(o)
        return
    end
    local raw = compute_bounds(cam, model)
    if not raw then
        hide_esp(o)
        return
    end

    -- сглаживание, привязанное к объекту модели
    local r = raw
    if CFG.EspSmooth then
        local sm = o.smooth
        if not sm then
            sm = { minX = raw.minX, maxX = raw.maxX, minY = raw.minY, maxY = raw.maxY, headTopY = raw.headTopY }
            o.smooth = sm
        else
            local a = CFG.EspSmoothAlpha
            sm.minX = sm.minX + (raw.minX - sm.minX) * a
            sm.maxX = sm.maxX + (raw.maxX - sm.maxX) * a
            sm.minY = sm.minY + (raw.minY - sm.minY) * a
            sm.maxY = sm.maxY + (raw.maxY - sm.maxY) * a
            sm.headTopY = sm.headTopY + (raw.headTopY - sm.headTopY) * a
        end
        r = {
            minX = sm.minX, maxX = sm.maxX, minY = sm.minY, maxY = sm.maxY,
            centerX = (sm.minX + sm.maxX) * 0.5, headTopY = sm.headTopY,
        }
    end

    local color = vis and COL_VISIBLE or COL_HIDDEN

    local st = (CFG.EspShowStates and ent) and states_of(ent) or {}
    local lineCount = 1
        + (CFG.EspShowDistance and 1 or 0)
        + (CFG.EspShowWeapon and 1 or 0)
        + #st
    local labelSize = adaptive_label_size(lineCount)

    -- бокс
    if CFG.EspBox then
        draw_box(o, r, color)
    else
        for _, line in ipairs(o.boxLines) do
            line.Visible = false
        end
    end

    -- имя над боксом
    if CFG.EspShowName then
        o.name.Visible = true
        o.name.Size = labelSize + 1
        o.name.Color = color
        o.name.Text = tostring((ent and ent.player_name) or model.Name)
        o.name.Position = V2(r.centerX, r.headTopY - (labelSize + 1) - 4)
    else
        o.name.Visible = false
    end

    -- под боксом: строка 1 = дистанция, строка 2 = [ОРУЖИЕ] оранжевым
    local ly = r.maxY + STACK_GAP
    if CFG.EspShowDistance then
        o.dist.Visible = true
        o.dist.Size = labelSize
        o.dist.Color = COL_DIST
        o.dist.Text = floor(depth) .. "m"
        o.dist.Position = V2(r.centerX, ly)
        ly = ly + labelSize * LINE_STEP + STACK_GAP
    else
        o.dist.Visible = false
    end
    if CFG.EspShowWeapon then
        local wname = ent and short_weapon(weapon_of(ent))
        if wname then
            o.weapon.Visible = true
            o.weapon.Size = labelSize
            o.weapon.Color = COL_WEAPON
            o.weapon.Text = "[" .. wname .. "]"
            o.weapon.Position = V2(r.centerX, ly)
        else
            o.weapon.Visible = false
        end
    else
        o.weapon.Visible = false
    end

    -- HP bar слева
    local hp = ent and rawget(ent, "__hp")
    if CFG.EspHpBar and hp then
        local barW = 4
        local bx = r.minX - barW - 3
        local by = r.minY
        local bh = max(r.maxY - r.minY, 8)
        local pct = clamp(hp / 100, 0, 1)
        o.hpOutline.Visible = true
        o.hpOutline.Size = V2(barW + 2, bh + 2)
        o.hpOutline.Position = V2(bx - 1, by - 1)
        o.hpOutline.Transparency = 0.85
        o.hpBg.Visible = true
        o.hpBg.Size = V2(barW, bh)
        o.hpBg.Position = V2(bx, by)
        o.hpBg.Transparency = 0.7
        local fillH = max(bh * pct, 1)
        o.hpFill.Visible = true
        o.hpFill.Size = V2(barW, fillH)
        o.hpFill.Position = V2(bx, by + bh - fillH)
        o.hpFill.Transparency = 0.98
        o.hpFill.Color = Color3.fromRGB(floor(255 * (1 - pct) + 55 * pct), floor(70 + 185 * pct), 50)
    else
        o.hpOutline.Visible = false
        o.hpBg.Visible = false
        o.hpFill.Visible = false
    end

    -- чипы состояний: столбик сверху вниз у правого края, с клампом в экран
    for i = 1, #o.chips do
        o.chips[i].Visible = false
    end
    if CFG.EspShowStates and #st > 0 then
        local chipSize = labelSize
        local sx = r.maxX + 6
        if sx + 44 > vp.X then
            sx = r.minX - 6 - 40
        end
        if sx < 2 then
            sx = 2
        end
        for i, label in ipairs(st) do
            local chip = o.chips[i]
            if not chip then
                break
            end
            local y = r.minY + (i - 1) * (chipSize + CHIP_GAP)
            if y + chipSize > vp.Y then
                break
            end
            chip.Visible = true
            chip.Size = chipSize
            chip.Text = label
            chip.Color = CHIP_COLOR[label] or COL_DIST
            chip.Center = false
            chip.Position = V2(sx, y)
        end
    end

    -- скелет (цвет = цвет бокса)
    for _, line in ipairs(o.skel) do
        line.Visible = false
    end
    o.headCircle.Visible = false
    if CFG.EspSkeleton and depth <= CFG.EspSkeletonMaxDist then
        local segs = skeleton_segments(model)
        local k = 0
        if segs then
            for _, seg in ipairs(segs) do
                local a = seg[1]
                local b = seg[2]
                if a and b and k < #o.skel then
                    local p1 = cam:WorldToViewportPoint(a)
                    local p2 = cam:WorldToViewportPoint(b)
                    if p1.Z > 0 and p2.Z > 0 then
                        k = k + 1
                        local line = o.skel[k]
                        line.Visible = true
                        line.Color = color
                        line.Thickness = 1.4
                        line.From = V2(p1.X, p1.Y)
                        line.To = V2(p2.X, p2.Y)
                    end
                end
            end
        end
        local head = model:FindFirstChild("head")
        if CFG.EspHeadCircle and head then
            local hp2 = cam:WorldToViewportPoint(head.Position)
            if hp2.Z > 0 then
                local viewScale = (vp.Y * 0.5) / tan(rad((cam.FieldOfView or 70) * 0.5))
                o.headCircle.Visible = true
                o.headCircle.Color = color
                o.headCircle.Position = V2(hp2.X, hp2.Y)
                o.headCircle.Radius = clamp((head.Size.Y * 0.6) * viewScale / max(depth, 1), 2, 11)
            end
        end
    end
end

--======================================================================
--  CHAMS
--======================================================================
local hlHolder
local hlByModel = {}
pcall(function()
    hlHolder = Instance.new("Folder")
    hlHolder.Name = "\0"
    hlHolder.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)

local function set_chams(model, enabled, color)
    if not hlHolder then
        return
    end
    local hl = hlByModel[model]
    if enabled and CFG.EspChams then
        if not hl then
            pcall(function()
                hl = Instance.new("Highlight")
                hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                hl.FillTransparency = CFG.EspChamsFillTrans
                hl.OutlineTransparency = CFG.EspChamsOutTrans
                hl.Adornee = model
                hl.Parent = hlHolder
                hlByModel[model] = hl
            end)
        end
        if hl then
            hl.Enabled = true
            hl.FillColor = color
            hl.OutlineColor = color
        end
    elseif hl then
        hl.Enabled = false
    end
end

--======================================================================
--  СБОРКА МУСОРА КЭШЕЙ  (по исчезнувшим моделям)
--======================================================================
local function gc_caches()
    for model, hl in pairs(hlByModel) do
        if not model or model.Parent == nil then
            pcall(function() hl:Destroy() end)
            hlByModel[model] = nil
        end
    end
    for model, o in pairs(espByModel) do
        if not model or model.Parent == nil then
            free_esp(o)
            espByModel[model] = nil
        end
    end
    for model in pairs(visCache) do
        if not model or model.Parent == nil then
            visCache[model] = nil
        end
    end
    for model in pairs(velTrack) do
        if not model or model.Parent == nil then
            velTrack[model] = nil
        end
    end
    local now = clock()
    for key, entry in pairs(mpCache) do
        if now - (entry.t or 0) > 2 then
            mpCache[key] = nil
        end
    end
end

--======================================================================
--  ГЛАВНЫЙ ЦИКЛ РЕНДЕРА
--======================================================================
local lastFrame = clock()
local lastResolve = 0

conns[#conns + 1] = RunService.RenderStepped:Connect(function()
    if not running then
        return
    end
    local cam = Workspace.CurrentCamera
    if not cam then
        return
    end
    local now = clock()
    local dt = now - lastFrame
    lastFrame = now
    local camPos = cam.CFrame.Position
    local vp = cam.ViewportSize

    --[[ Кто мы — каждый кадр. Это чистый rawget по lifetime_state, поэтому
         бесплатно, зато после респавна ствол/лучи/моды сразу берут живое тело
         (раньше до секунды работал труп). ]]
    refresh_local()

    -- резолв цели ТРОТТЛИТСЯ; между резолвами — только проверка живости
    validate_target()
    if now - lastResolve >= CFG.AimResolveInterval then
        lastResolve = now
        pcall(resolve_target)
    end

    -- FOV circle
    if CFG.FovCircle and CFG.SilentAim then
        fovCircle.Visible = true
        fovCircle.Radius = fov_radius_px(cam)
        fovCircle.Position = V2(vp.X * 0.5, vp.Y * 0.5)
        fovCircle.Color = Target.pos and tier_color(Target.tier) or CFG.FovCircleColor
        fovCircle.Transparency = 1 - CFG.FovCircleTrans
        fovCircle.Thickness = CFG.FovCircleThick
        fovCircle.Filled = CFG.FovCircleFilled
    else
        fovCircle.Visible = false
    end

    -- muzzle / spoof линии (визуализация MultiPoint)
    muzzleLine.Visible = false
    spoofLineA.Visible = false
    spoofLineB.Visible = false
    if CFG.MuzzleVisual and Target.pos then
        -- фолбэк: если ствол/вьюмодель ещё не готовы, берём точку чуть ниже
        -- камеры — иначе линия периодически пропадала при аиме
        local mcf = muzzle_cframe()
        local muzzlePos = mcf and mcf.Position
        if not muzzlePos then
            muzzlePos = camPos - V3(0, 1, 0)
        end
        if muzzlePos then
            --[[
                ВАЖНО: второй возврат WorldToViewportPoint — это "точка внутри
                прямоугольника экрана", а НЕ "перед камерой". Дуло проецируется
                у самого низа/края экрана и часто даёт false -> линия пропадала.
                Для ЛИНИЙ нужен только признак "перед камерой" = screen.Z > 0,
                выход за край экрана нормален.
            --]]
            local mScreen = cam:WorldToViewportPoint(muzzlePos)
            local tScreen = cam:WorldToViewportPoint(Target.pos)
            local mFront = mScreen.Z > 0
            local tFront = tScreen.Z > 0
            local spoofed = Target.spoof and (Target.spoof - muzzlePos).Magnitude > 0.05
            if not spoofed then
                if mFront and tFront then
                    muzzleLine.Visible = true
                    muzzleLine.Color = CFG.MuzzleLineColor
                    muzzleLine.Thickness = CFG.MuzzleLineThick
                    muzzleLine.Transparency = 1 - CFG.MuzzleLineTrans
                    muzzleLine.From = V2(mScreen.X, mScreen.Y)
                    muzzleLine.To = V2(tScreen.X, tScreen.Y)
                end
            else
                local sScreen = cam:WorldToViewportPoint(Target.spoof)
                local sFront = sScreen.Z > 0
                if mFront and sFront then
                    spoofLineA.Visible = true
                    spoofLineA.Color = Color3.fromRGB(255, 200, 60)
                    spoofLineA.Thickness = 1.4
                    spoofLineA.Transparency = 0.7
                    spoofLineA.From = V2(mScreen.X, mScreen.Y)
                    spoofLineA.To = V2(sScreen.X, sScreen.Y)
                end
                if sFront and tFront then
                    spoofLineB.Visible = true
                    spoofLineB.Color = Color3.fromRGB(120, 255, 180)
                    spoofLineB.Thickness = 2.2
                    spoofLineB.Transparency = 0.8
                    spoofLineB.From = V2(sScreen.X, sScreen.Y)
                    spoofLineB.To = V2(tScreen.X, tScreen.Y)
                end
                -- фолбэк: спуф не спроецировался — показываем обычную линию,
                -- чтобы визуал прицела не пропадал
                if not spoofLineA.Visible and not spoofLineB.Visible and mFront and tFront then
                    muzzleLine.Visible = true
                    muzzleLine.Color = CFG.MuzzleLineColor
                    muzzleLine.Thickness = CFG.MuzzleLineThick
                    muzzleLine.Transparency = 1 - CFG.MuzzleLineTrans
                    muzzleLine.From = V2(mScreen.X, mScreen.Y)
                    muzzleLine.To = V2(tScreen.X, tScreen.Y)
                end
            end
        end
    end

    -- reticle на цели
    if CFG.AimVisuals and Target.pos then
        local tScreen = cam:WorldToViewportPoint(Target.pos)
        if tScreen.Z > 0 then
            draw_reticle(tScreen.X, tScreen.Y, tier_color(Target.tier), now)
        else
            for _, line in ipairs(reticleLines) do
                line.Visible = false
            end
        end
    else
        for _, line in ipairs(reticleLines) do
            line.Visible = false
        end
    end

    -- shot tracers c fade
    if CFG.ShotTracers then
        local li = 0
        for i = #tracers, 1, -1 do
            local tr = tracers[i]
            local age = now - tr.t
            if age > CFG.TracerDuration then
                table.remove(tracers, i)
            elseif li < TRACER_MAX then
                local p1 = cam:WorldToViewportPoint(tr.a)
                local p2 = cam:WorldToViewportPoint(tr.b)
                if p1.Z > 0 and p2.Z > 0 then
                    li = li + 1
                    local line = tracerLines[li]
                    local alpha = tracer_alpha(age, CFG.TracerDuration, CFG.TracerFadeIn)
                    line.Visible = true
                    line.Thickness = CFG.TracerThickness + alpha * 0.5
                    line.Color = CFG.TracerColor:Lerp(Color3.new(1, 1, 1), alpha * 0.18)
                    line.Transparency = alpha
                    line.From = V2(p1.X, p1.Y)
                    line.To = V2(p2.X, p2.Y)
                end
            end
        end
        for i = li + 1, TRACER_MAX do
            tracerLines[i].Visible = false
        end
    else
        for i = 1, TRACER_MAX do
            tracerLines[i].Visible = false
        end
    end

    pcall(update_particles, cam, dt)

    -- ESP
    if not CFG.ESP then
        for _, o in pairs(espByModel) do
            hide_esp(o)
        end
        return
    end
    local folder = Workspace:FindFirstChild("characters")
    if not folder then
        for _, o in pairs(espByModel) do
            hide_esp(o)
        end
        return
    end
    -- LocalPlayer.Character в этой игре всегда nil: берём модель из lifetime_state
    local myChar = myCharacter
    local seen = {}
    for _, model in ipairs(folder:GetChildren()) do
        if model ~= myChar then
            local ent = entByModel[model]
            if is_enemy(ent) then
                seen[model] = true
                local vis = true
                if CFG.EspVisibleCheck then
                    vis = is_visible(camPos, model)
                end
                pcall(update_esp, cam, camPos, vp, model, ent, vis)
                set_chams(model, true, vis and COL_VISIBLE or COL_HIDDEN)
            end
        end
    end
    -- гасим тех, кого не рисовали в этом кадре
    for model, o in pairs(espByModel) do
        if not seen[model] then
            hide_esp(o)
            set_chams(model, false)
        end
    end
end)

--======================================================================
--  WEAPON MODS
--======================================================================
-- SHARED поднят к началу файла: его читает предикт (replication_rollback)

local function set_shared(key, value)
    if not SHARED then
        return false
    end
    local obj = rawget(SHARED, key)
    if type(obj) ~= "table" then
        return false
    end
    return (pcall(function()
        if type(obj.set_client) == "function" then
            obj:set_client(value)
        else
            obj.value = value
        end
    end))
end

local RECOIL_KEYS = {
    "vertical_recoil", "horizontal_recoil", "camera_recoil", "camera_lag_recoil",
    "roll_recoil", "rotation_recoil", "weapon_roll_recoil", "knockback",
    "progressive_increment", "animation_weight",
}
local SWAY_KEYS = { "sway_recoil", "aim_sway_recoil" }

local function patch_debug_values()
    local ok, found = pcall(filtergc, "table", { Keys = { "vertical_recoil", "camera_recoil" } }, false)
    if not ok or type(found) ~= "table" then
        return
    end
    for _, tbl in ipairs(found) do
        local probe = rawget(tbl, "vertical_recoil")
        if type(probe) == "table" and rawget(probe, "changed") ~= nil then
            if CFG.NoRecoil then
                for _, key in ipairs(RECOIL_KEYS) do
                    local field = rawget(tbl, key)
                    if type(field) == "table" and rawget(field, "changed") ~= nil then
                        pcall(function()
                            field.value = 0
                            field.changed = true
                        end)
                    end
                end
            end
            if CFG.NoSway then
                for _, key in ipairs(SWAY_KEYS) do
                    local field = rawget(tbl, key)
                    if type(field) == "table" and rawget(field, "changed") ~= nil then
                        pcall(function()
                            field.value = 0
                            field.changed = true
                        end)
                    end
                end
            end
        end
    end
end

local SWAY_SPRINGS = {
    "aim_sway", "sway", "slow_sway", "sway_recoil", "aim_sway_recoil",
    "main_bobbing", "sideways_bobbing",
}
local blockedSprings = setmetatable({}, { __mode = "k" })
local spring_hooked = false

local function hook_springs()
    if spring_hooked or not ctrl then
        return
    end
    local springs = rawget(ctrl, "springs")
    if type(springs) ~= "table" then
        return
    end
    local sample = springs.aim_sway or springs.sway
    if type(sample) ~= "table" then
        return
    end
    local mt = getmetatable(sample)
    if type(mt) ~= "table" then
        return
    end
    pcall(function()
        local origUpdate = rawget(mt, "update")
        local origShove = rawget(mt, "shove")
        if type(origUpdate) == "function" then
            rawset(mt, "update", function(self, dt)
                if blockedSprings[self] then
                    self.velocity = ZERO3
                    self.position = ZERO3
                    return ZERO3
                end
                return origUpdate(self, dt)
            end)
        end
        if type(origShove) == "function" then
            rawset(mt, "shove", function(self, v)
                if blockedSprings[self] then
                    return
                end
                return origShove(self, v)
            end)
        end
        spring_hooked = true
    end)
end

local function apply_mods()
    if CFG.NoRecoil then
        set_shared("plr_recoil", 0)
    end
    if CFG.NoSpread then
        set_shared("plr_barrel_deviation", 0)
        set_shared("plr_buck_barrel_deviation", 0)
    end
    if CFG.ClientRollbackMs ~= nil then
        set_shared("plr_replication_rollback_time_ms", CFG.ClientRollbackMs)
    end
    patch_debug_values()
    if ctrl then
        local springs = rawget(ctrl, "springs")
        if type(springs) == "table" then
            for _, key in ipairs(SWAY_SPRINGS) do
                local spring = rawget(springs, key)
                if type(spring) == "table" then
                    blockedSprings[spring] = CFG.NoSway or nil
                end
            end
        end
        local smooth = rawget(ctrl, "smooth_values")
        if type(smooth) == "table" and CFG.NoSway then
            for _, key in ipairs({ "swayLagX", "swayLagY" }) do
                local obj = rawget(smooth, key)
                if type(obj) == "table" then
                    pcall(function()
                        obj.value = 0
                        obj.target = 0
                    end)
                end
            end
        end
        hook_springs()
        if CFG.FullAuto then
            pcall(function()
                local weapon = rawget(ctrl, "weapon")
                if type(weapon) == "table" and weapon.firemode == "semi" then
                    weapon.firemode = "auto"
                end
            end)
        end
    end
end

--======================================================================
--  ФОНОВЫЕ ЦИКЛЫ
--======================================================================
task.spawn(function()
    while running do
        pcall(refresh_meta)
        pcall(hook_packet)
        pcall(hook_fire)
        pcall(hook_network_hit)
        pcall(gc_caches)
        task.wait(CFG.MetaRefresh)
    end
end)

task.spawn(function()
    while running do
        pcall(apply_mods)
        task.wait(CFG.ModsInterval)
    end
end)

--======================================================================
--  ВЫГРУЗКА
--======================================================================
--[[
    ДИАГНОСТИКА: getgenv().DL.debug()
    Показывает ровно то, что раньше приходилось угадывать: нашли ли мы живой
    контроллер и НАШУ модель (LocalPlayer.Character тут всегда nil, поэтому это
    главный источник тихих поломок), сколько сущностей видно, есть ли цель и
    какой откат репликации реально прочитан.
--]]
DL.debug = function()
    local tgt = Target and Target.model
    local s = ("ctrl=%s myChar=%s ents=%d esp=%d target=%s rollback=%.0fms genv-traps=%d"):format(
        tostring(ctrl ~= nil),
        myCharacter and tostring(myCharacter.Name) or "nil",
        ent_count,
        (function() local n = 0; for _ in pairs(espByModel) do n += 1 end; return n end)(),
        tgt and tostring(tgt.Name) or "none",
        replication_rollback() * 1000,
        genvKilled)
    log(s)
    return s
end

-- диагностика: getgenv().DL.testsound() — проверить, слышен ли HitSound
DL.testsound = function()
    local saved = CFG.HitSound
    CFG.HitSound = true
    lastHitSoundAt = 0
    play_hit_sound()
    CFG.HitSound = saved
    log(("testsound: route=%s id=%s vol=%.2f"):format(
        hitSoundRoute, tostring(CFG.HitSoundId), CFG.HitSoundVolume))
end

DL.unload = function()
    running = false
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    for model, o in pairs(espByModel) do
        free_esp(o)
        espByModel[model] = nil
    end
    pcall(function()
        fovCircle:Remove()
        muzzleLine:Remove()
        spoofLineA:Remove()
        spoofLineB:Remove()
    end)
    for _, line in ipairs(reticleLines) do
        pcall(function() line:Remove() end)
    end
    for _, line in ipairs(tracerLines) do
        pcall(function() line:Remove() end)
    end
    for _, sys in ipairs(particleSystems) do
        for _, particle in ipairs(sys.parts) do
            for _, drawing in ipairs(particle.draw) do
                pcall(function() drawing:Remove() end)
            end
        end
    end
    particleSystems = {}
    for model, hl in pairs(hlByModel) do
        pcall(function() hl:Destroy() end)
        hlByModel[model] = nil
    end
    pcall(function()
        if hlHolder then
            hlHolder:Destroy()
        end
    end)
    table.clear(visCache)
    table.clear(mpCache)
    for spring in pairs(blockedSprings) do
        blockedSprings[spring] = nil
    end
    pcall(function()
        set_shared("plr_recoil", 1)
        set_shared("plr_barrel_deviation", 1)
        set_shared("plr_buck_barrel_deviation", 1)
        set_shared("plr_replication_rollback_time_ms", 190)
    end)
    if getgenv().DL == DL then
        getgenv().DL = nil
    end
    log("unloaded")
end

--======================================================================
--  СТАРТ
--======================================================================
task.wait(0.2)
refresh_meta()
warm_hit_sound()      -- прогреть ассет, чтобы первый хит уже звучал
hook_packet()
hook_fire()
hook_network_hit()
apply_mods()

log(("suite v5 | ents=%d ctrl=%s | packet=%s fire=%s nh=%s | bone=%s"):format(
    ent_count, tostring(ctrl ~= nil), tostring(packet_hooked),
    tostring(fire_hooked), tostring(nh_hooked), tostring(CFG.AimBone)))
log("off: getgenv().DL.unload()  |  cfg: getgenv().DL.config")

--======================================================================
--  LOADER MODULE  (Syllinse Project / MacLib)
--======================================================================
return {
    -- everything starts OFF; the user enables it from the UI
    start = function()
        CFG.ESP, CFG.SilentAim, CFG.MultiPoint = false, false, false
        CFG.Prediction, CFG.Resolver, CFG.ForceHit = false, false, false
        CFG.FovCircle, CFG.MuzzleVisual, CFG.ShotTracers = false, false, false
        CFG.AimVisuals, CFG.HitParticles, CFG.HitSound = false, false, false
        CFG.NoRecoil, CFG.NoSpread, CFG.NoSway, CFG.FullAuto = false, false, false, false
        CFG.EspBox, CFG.EspShowName, CFG.EspShowDistance = false, false, false
        CFG.EspShowWeapon, CFG.EspShowStates, CFG.EspHpBar = false, false, false
        CFG.EspSkeleton, CFG.EspHeadCircle, CFG.EspChams = false, false, false
    end,

    stop = function()
        if DL and type(DL.unload) == "function" then pcall(DL.unload) end
    end,

    buildUI = function(ctx)
        local ready = false
        task.defer(function() ready = true end)
        local function note(t, b) if ready then pcall(ctx.notify, t, b) end end

        local function feature(sec, o)
            local guard, el = false, nil
            local function commit(v)
                v = v and true or false
                o.set(v)
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

        local function bool(sec, name, o)
            sec:Toggle({ Name = name, Default = o.Default == true,
                Callback = function(v) o.set(v and true or false); note(name, v and "Enabled" or "Disabled") end },
                ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
        end

        local function slider(sec, o)
            sec:Slider({ Name = o.Name, Default = o.Default, Minimum = o.Min, Maximum = o.Max,
                Precision = o.Precision or 0, Suffix = o.Suffix, Prefix = o.Prefix,
                Callback = o.Callback }, ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
        end

        local function dropdown(sec, o)
            sec:Dropdown({ Name = o.Name, Options = o.Options, Default = o.Default, Required = true,
                Callback = function(v) if type(v) == "string" and v ~= "" then o.Callback(v) end end },
                ctx.flag(o.Flag))
            if o.Desc then sec:SubLabel({ Text = o.Desc }) end
        end

        local function color(sec, o)
            sec:Colorpicker({ Name = o.Name, Default = o.Default,
                Callback = function(c) o.Callback(c) end }, ctx.flag(o.Flag))
        end

        --==============================================================
        -- TAB: SILENT AIM
        --==============================================================
        local A = ctx.tabs.SilentAim

        local a1 = A:Section({ Side = "Left" })
        a1:Header({ Name = "Silent Aim" })
        feature(a1, { Title = "Silent Aim", Flag = "SA_Enabled",
            get = function() return CFG.SilentAim end,
            set = function(v) CFG.SilentAim = v end,
            Desc = "rewrites the bullet direction on fire, crosshair never moves" })

        a1:Divider()
        a1:Header({ Name = "Targeting" })
        slider(a1, { Name = "FOV", Flag = "SA_FOV", Default = 60,
            Min = 5, Max = 180, Suffix = "°",
            Callback = function(v) CFG.SilentAimFOV = v end })
        slider(a1, { Name = "Max Distance", Flag = "SA_MaxDist", Default = 500,
            Min = 50, Max = 2000, Suffix = " st",
            Callback = function(v) CFG.SilentAimMaxDist = v end })
        dropdown(a1, { Name = "Aim Bone", Flag = "SA_Bone",
            Options = { "Head", "Torso", "Nearest" }, Default = "Head",
            Callback = function(v) CFG.AimBone = v end })
        bool(a1, "Ignore Teammates", { Flag = "SA_NoTeam", Default = true,
            set = function(v) CFG.IgnoreTeammates = v end })
        bool(a1, "Skip Blocked", { Flag = "SA_SkipBlocked", Default = true,
            set = function(v) CFG.SkipBlocked = v end,
            Desc = "off = shoot through walls too (obvious)" })
        slider(a1, { Name = "Resolve Rate", Flag = "SA_Resolve", Default = 50,
            Min = 16, Max = 200, Suffix = " ms",
            Callback = function(v) CFG.AimResolveInterval = v / 1000 end,
            Desc = "higher = less work per frame" })

        local a2 = A:Section({ Side = "Left" })
        a2:Header({ Name = "Prediction" })
        feature(a2, { Title = "Prediction", Flag = "SA_Predict",
            get = function() return CFG.Prediction end,
            set = function(v) CFG.Prediction = v end,
            Desc = "leads the target using bullet speed and drop" })
        bool(a2, "Rollback Compensation", { Flag = "SA_PredRB", Default = true,
            set = function(v) CFG.PredictRollback = v end,
            Desc = "enemies render 190ms in the past = 4.75 studs at 25 st/s" })
        slider(a2, { Name = "Rollback Factor", Flag = "SA_PredRBF", Default = 100,
            Min = 0, Max = 150, Suffix = " %",
            Callback = function(v) CFG.PredictRollbackFactor = v / 100 end,
            Desc = "lower it if you overshoot runners" })
        bool(a2, "Vertical Lead", { Flag = "SA_PredVert", Default = false,
            set = function(v) CFG.PredictVertical = v end,
            Desc = "jumps are unpredictable, usually hurts" })
        bool(a2, "Wind Compensation", { Flag = "SA_PredWind", Default = true,
            set = function(v) CFG.PredictWind = v end })
        slider(a2, { Name = "Max Lead Time", Flag = "SA_PredMax", Default = 1200,
            Min = 200, Max = 2000, Suffix = " ms",
            Callback = function(v) CFG.PredictMaxTime = v / 1000 end })

        local a3 = A:Section({ Side = "Left" })
        a3:Header({ Name = "MultiPoint" })
        feature(a3, { Title = "MultiPoint", Flag = "SA_MP",
            get = function() return CFG.MultiPoint end,
            set = function(v) CFG.MultiPoint = v end,
            Desc = "finds a muzzle angle whose bullet clears the cover" })
        slider(a3, { Name = "Max Offset", Flag = "SA_MPOff", Default = 6,
            Min = 2, Max = 14, Suffix = " st",
            Callback = function(v) CFG.MPMaxOffset = v end })
        slider(a3, { Name = "Search Steps", Flag = "SA_MPSteps", Default = 3,
            Min = 1, Max = 6,
            Callback = function(v) CFG.MPBinarySteps = v end })
        slider(a3, { Name = "Max Targets", Flag = "SA_MPTargets", Default = 3,
            Min = 1, Max = 8,
            Callback = function(v) CFG.MPMaxTargets = v end,
            Desc = "most expensive setting, lower it if you lag" })

        ------------------------------------------ Force Hit (own section)
        local a3b = A:Section({ Side = "Left" })
        a3b:Header({ Name = "Force Hit" })
        feature(a3b, { Title = "Force Hit", Flag = "SA_FH",
            get = function() return CFG.ForceHit end,
            set = function(v) CFG.ForceHit = v end,
            Desc = "client claims the hit; server still validates it" })
        dropdown(a3b, { Name = "Hit Part", Flag = "SA_FHPart",
            Options = { "Head", "Torso" }, Default = "Head",
            Callback = function(v) CFG.ForceHitPart = v end })
        slider(a3b, { Name = "Delay", Flag = "SA_FHDelay", Default = 0,
            Min = 0, Max = 120, Suffix = " ms",
            Callback = function(v) CFG.ForceHitDelay = v / 1000 end,
            Desc = "wait before claiming, helps the server accept it" })

        ---------------------------------------- Penetration (own section)
        local a3c = A:Section({ Side = "Left" })
        a3c:Header({ Name = "Penetration" })
        feature(a3c, { Title = "Penetration", Flag = "SA_Pen",
            get = function() return CFG.AllowPenetrable end,
            set = function(v) CFG.AllowPenetrable = v end,
            Desc = "allow targets behind thin cover" })
        slider(a3c, { Name = "Max Thickness", Flag = "SA_PenMax", Default = 3,
            Min = 1, Max = 12, Suffix = " st",
            Callback = function(v) CFG.MaxPenetration = v end })

        --------------------------------------- FOV Circle (own section)
        local a5 = A:Section({ Side = "Right" })
        a5:Header({ Name = "FOV Circle" })
        feature(a5, { Title = "FOV Circle", Flag = "SA_FovC",
            get = function() return CFG.FovCircle end,
            set = function(v) CFG.FovCircle = v end })
        color(a5, { Name = "Color", Flag = "SA_FovCol", Default = Color3.fromRGB(255, 255, 255),
            Callback = function(c) CFG.FovCircleColor = c end })
        slider(a5, { Name = "Thickness", Flag = "SA_FovThick", Default = 1,
            Min = 1, Max = 5, Callback = function(v) CFG.FovCircleThick = v end })
        bool(a5, "Filled", { Flag = "SA_FovFill", Default = false,
            set = function(v) CFG.FovCircleFilled = v end })

        ------------------------------------ Bullet Tracer (own section)
        local a5b = A:Section({ Side = "Right" })
        a5b:Header({ Name = "Bullet Tracer" })
        feature(a5b, { Title = "Bullet Tracer", Flag = "SA_Tracer",
            get = function() return CFG.ShotTracers end,
            set = function(v) CFG.ShotTracers = v end,
            Desc = "your shots only" })
        color(a5b, { Name = "Color", Flag = "SA_TracerCol", Default = Color3.fromRGB(120, 200, 255),
            Callback = function(c) CFG.TracerColor = c end })
        slider(a5b, { Name = "Duration", Flag = "SA_TracerDur", Default = 400,
            Min = 100, Max = 1500, Suffix = " ms",
            Callback = function(v) CFG.TracerDuration = v / 1000 end })
        slider(a5b, { Name = "Thickness", Flag = "SA_TracerThick", Default = 2,
            Min = 1, Max = 6, Callback = function(v) CFG.TracerThickness = v end })

        -------------------------------------- Muzzle Line (own section)
        local a5c = A:Section({ Side = "Right" })
        a5c:Header({ Name = "Muzzle Line" })
        feature(a5c, { Title = "Muzzle Line", Flag = "SA_Muzzle",
            get = function() return CFG.MuzzleVisual end,
            set = function(v) CFG.MuzzleVisual = v end,
            Desc = "shows where the muzzle actually points" })
        color(a5c, { Name = "Color", Flag = "SA_MuzzleCol", Default = Color3.fromRGB(255, 170, 60),
            Callback = function(c) CFG.MuzzleLineColor = c end })

        ------------------------------------------ Reticle (own section)
        local a5d = A:Section({ Side = "Right" })
        a5d:Header({ Name = "Reticle" })
        feature(a5d, { Title = "Reticle", Flag = "SA_Reticle",
            get = function() return CFG.AimVisuals end,
            set = function(v) CFG.AimVisuals = v end,
            Desc = "marker on the selected target" })
        dropdown(a5d, { Name = "Style", Flag = "SA_ReticleStyle",
            Options = { "Cross", "Dot", "Box", "Diamond" }, Default = "Cross",
            Callback = function(v) CFG.AimVisualStyle = v end })
        color(a5d, { Name = "Color", Flag = "SA_ReticleCol", Default = Color3.fromRGB(255, 80, 80),
            Callback = function(c) CFG.AimVisualColor = c end })
        slider(a5d, { Name = "Scale", Flag = "SA_ReticleScale", Default = 100,
            Min = 30, Max = 250, Suffix = " %",
            Callback = function(v) CFG.AimVisualScale = v / 100 end })

        ----------------------------------------- Hit Sound (own section)
        local a6 = A:Section({ Side = "Right" })
        a6:Header({ Name = "Hit Sound" })
        feature(a6, { Title = "Hit Sound", Flag = "SA_HitSnd",
            get = function() return CFG.HitSound end,
            set = function(v) CFG.HitSound = v end })
        slider(a6, { Name = "Volume", Flag = "SA_HitVol", Default = 3.5,
            Min = 0.5, Max = 10, Precision = 1,
            Callback = function(v) CFG.HitSoundVolume = v end,
            Desc = "Roblox range is 0-10, not 0-1" })
        slider(a6, { Name = "Pitch", Flag = "SA_HitPitch", Default = 1,
            Min = 0.5, Max = 2, Precision = 2,
            Callback = function(v) CFG.HitSoundPitch = v end })
        slider(a6, { Name = "Stack", Flag = "SA_HitStack", Default = 1,
            Min = 1, Max = 4,
            Callback = function(v) CFG.HitSoundStack = v end,
            Desc = "simultaneous copies = louder" })
        a6:Button({ Name = "Test Sound", Callback = function() pcall(DL.testsound) end },
            ctx.flag("SA_BtnSound"))

        ------------------------------------- Hit Particles (own section)
        local a6b = A:Section({ Side = "Right" })
        a6b:Header({ Name = "Hit Particles" })
        feature(a6b, { Title = "Hit Particles", Flag = "SA_HitPart",
            get = function() return CFG.HitParticles end,
            set = function(v) CFG.HitParticles = v end })
        dropdown(a6b, { Name = "Type", Flag = "SA_HitPartType",
            Options = { "Wireframe", "Orbs", "Sparks" }, Default = "Sparks",
            Callback = function(v) CFG.HitParticleType = v end })
        slider(a6, { Name = "Count", Flag = "SA_HitPartCount", Default = 8,
            Min = 2, Max = 24,
            Callback = function(v) CFG.HitParticleCount = v end })
        slider(a6b, { Name = "Duration", Flag = "SA_HitPartDur", Default = 400,
            Min = 100, Max = 1200, Suffix = " ms",
            Callback = function(v) CFG.HitParticleDur = v / 1000 end })
        color(a6b, { Name = "Color A", Flag = "SA_HitPartA", Default = Color3.fromRGB(255, 240, 150),
            Callback = function(c) CFG.HitParticleColorA = c end })
        color(a6b, { Name = "Color B", Flag = "SA_HitPartB", Default = Color3.fromRGB(255, 120, 40),
            Callback = function(c) CFG.HitParticleColorB = c end })

        --==============================================================
        -- TAB: GUN MODS
        --==============================================================
        local G = ctx.tabs.GunMods

        local g1 = G:Section({ Side = "Left" })
        g1:Header({ Name = "No Recoil" })
        feature(g1, { Title = "No Recoil", Flag = "GM_NoRecoil",
            get = function() return CFG.NoRecoil end,
            set = function(v) CFG.NoRecoil = v end,
            Desc = "camera and viewmodel kick only, direction is computed before it" })

        local g2 = G:Section({ Side = "Left" })
        g2:Header({ Name = "No Spread" })
        feature(g2, { Title = "No Spread", Flag = "GM_NoSpread",
            get = function() return CFG.NoSpread end,
            set = function(v) CFG.NoSpread = v end,
            Desc = "barrel deviation affects the real bullet direction" })

        local g3 = G:Section({ Side = "Left" })
        g3:Header({ Name = "No Sway" })
        feature(g3, { Title = "No Sway", Flag = "GM_NoSway",
            get = function() return CFG.NoSway end,
            set = function(v) CFG.NoSway = v end,
            Desc = "removes the idle aim wobble" })

        local g4 = G:Section({ Side = "Right" })
        g4:Header({ Name = "Full Auto" })
        feature(g4, { Title = "Full Auto", Flag = "GM_FullAuto",
            get = function() return CFG.FullAuto end,
            set = function(v) CFG.FullAuto = v end,
            Desc = "fire mode is switched locally, rpm is never raised" })

        local g5 = G:Section({ Side = "Right" })
        g5:Header({ Name = "Notes" })
        g5:SubLabel({ Text = "bullet speed, drop and rpm are checked every tick by the anticheat, so they are never touched" })

        --==============================================================
        -- TAB: DEBUG  (created by the loader)
        --==============================================================
        local D = ctx.tabs.Debug

        local d1 = D:Section({ Side = "Right" })
        d1:Header({ Name = "Silent Aim" })
        d1:Button({ Name = "Print Aim Debug", Callback = function()
            pcall(DL.debug); note("Silent Aim", "debug -> console")
        end }, ctx.flag("SA_BtnDebug"))
        d1:Button({ Name = "Test Hit Sound", Callback = function()
            pcall(DL.testsound)
        end }, ctx.flag("SA_BtnSound2"))

        --==============================================================
        -- TAB: VISUALS  (ESP)
        --==============================================================
        local V = ctx.tabs.Visuals

        local v1 = V:Section({ Side = "Left" })
        v1:Header({ Name = "ESP" })
        feature(v1, { Title = "ESP", Flag = "VZ_ESP",
            get = function() return CFG.ESP end,
            set = function(v) CFG.ESP = v end })

        v1:Divider()
        v1:Header({ Name = "Filtering" })
        bool(v1, "Enemies Only", { Flag = "VZ_EnemyOnly", Default = true,
            set = function(v) CFG.EspEnemyOnly = v end })
        slider(v1, { Name = "Max Distance", Flag = "VZ_MaxDist", Default = 500,
            Min = 50, Max = 2000, Suffix = " st",
            Callback = function(v) CFG.EspMaxDistance = v end })
        bool(v1, "Visibility Check", { Flag = "VZ_VisCheck", Default = false,
            set = function(v) CFG.EspVisibleCheck = v end,
            Desc = "dims targets you cannot see directly" })
        bool(v1, "Smooth Movement", { Flag = "VZ_Smooth", Default = true,
            set = function(v) CFG.EspSmooth = v end })

        --------------------------------------------- Box (own section)
        local v2 = V:Section({ Side = "Left" })
        v2:Header({ Name = "Box" })
        feature(v2, { Title = "Box", Flag = "VZ_Box",
            get = function() return CFG.EspBox end,
            set = function(v) CFG.EspBox = v end })
        dropdown(v2, { Name = "Style", Flag = "VZ_BoxMode",
            Options = { "Corner", "Full" }, Default = "Corner",
            Callback = function(v) CFG.EspBoxMode = v end })
        slider(v2, { Name = "Corner Length", Flag = "VZ_BoxCorner", Default = 28,
            Min = 10, Max = 50, Suffix = " %",
            Callback = function(v) CFG.EspCornerScale = v / 100 end })
        slider(v2, { Name = "Thickness", Flag = "VZ_BoxThick", Default = 1,
            Min = 1, Max = 4,
            Callback = function(v) CFG.EspBoxThickness = v end })

        ------------------------------------- Head Circle (own section)
        local v2b = V:Section({ Side = "Left" })
        v2b:Header({ Name = "Head Circle" })
        feature(v2b, { Title = "Head Circle", Flag = "VZ_HeadCircle",
            get = function() return CFG.EspHeadCircle end,
            set = function(v) CFG.EspHeadCircle = v end })

        ------------------------------------- Information (own section)
        local v3 = V:Section({ Side = "Left" })
        v3:Header({ Name = "Information" })
        bool(v3, "Name", { Flag = "VZ_Name", Default = false,
            set = function(v) CFG.EspShowName = v end })
        bool(v3, "Distance", { Flag = "VZ_Dist", Default = false,
            set = function(v) CFG.EspShowDistance = v end })
        bool(v3, "Weapon", { Flag = "VZ_Weapon", Default = false,
            set = function(v) CFG.EspShowWeapon = v end,
            Desc = "weapon and ammo under the box" })
        bool(v3, "States", { Flag = "VZ_States", Default = false,
            set = function(v) CFG.EspShowStates = v end,
            Desc = "Aiming / Reloading / Prone / NVG" })

        ----------------------------------------- HP Bar (own section)
        local v3b = V:Section({ Side = "Left" })
        v3b:Header({ Name = "HP Bar" })
        feature(v3b, { Title = "HP Bar", Flag = "VZ_HP",
            get = function() return CFG.EspHpBar end,
            set = function(v) CFG.EspHpBar = v end,
            Desc = "bar on the left of the box, green to red" })

        --------------------------------------- Skeleton (own section)
        local v4 = V:Section({ Side = "Right" })
        v4:Header({ Name = "Skeleton" })
        feature(v4, { Title = "Skeleton", Flag = "VZ_Skel",
            get = function() return CFG.EspSkeleton end,
            set = function(v) CFG.EspSkeleton = v end,
            Desc = "R6 rig, built from the real joints" })
        slider(v4, { Name = "Max Distance", Flag = "VZ_SkelDist", Default = 150,
            Min = 30, Max = 500, Suffix = " st",
            Callback = function(v) CFG.EspSkeletonMaxDist = v end })

        ------------------------------------------ Chams (own section)
        local v5 = V:Section({ Side = "Right" })
        v5:Header({ Name = "Chams" })
        feature(v5, { Title = "Chams", Flag = "VZ_Chams",
            get = function() return CFG.EspChams end,
            set = function(v) CFG.EspChams = v end,
            Desc = "highlights bodies through walls" })
        slider(v5, { Name = "Fill", Flag = "VZ_ChamsFill", Default = 72,
            Min = 0, Max = 100, Suffix = " %",
            Callback = function(v) CFG.EspChamsFillTrans = 1 - v / 100 end })
        slider(v5, { Name = "Outline", Flag = "VZ_ChamsOut", Default = 85,
            Min = 0, Max = 100, Suffix = " %",
            Callback = function(v) CFG.EspChamsOutTrans = 1 - v / 100 end })
    end,
}
