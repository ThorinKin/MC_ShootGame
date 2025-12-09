-- ServerScriptService/Server/AttrService/AttrModule.lua
-- 总注释：属性加点系统模块。主管业务，保存攻击/防御/生命值的加点分配，DataStore2 仅动 cache
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)
local ExpModule     = require(ServerScriptService.Server.ExpService.ExpModule)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化

----------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[AttrModule] " .. string.format(fmt, ...))
    end
end

-- 字段枚举：存档里真实的 key
-- state = {
--   attack  = number,
--   defense = number,
--   health  = number,
-- }
local FIELDS = {
    attack  = "attack",
    defense = "defense",
    health  = "health",
}
table.freeze(FIELDS)

-- 展示字段名
local DISPLAY_NAME = {
    [FIELDS.attack]  = "Attack",
    [FIELDS.defense] = "Defense",
    [FIELDS.health]  = "Health",
}

-- 默认值
local DEFAULT = {
    [FIELDS.attack]  = 0,
    [FIELDS.defense] = 0,
    [FIELDS.health]  = 0,
}
table.freeze(DEFAULT)
----------------------------------------------------------------

-- 小工具
local function clampNonNegInt(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    return n
end
local function getStore(player)
    return DataStore2(StoreRegistry.Attr, player)
end

-- 把任意脏数据修成标准形状
local function ensureShape(t)
    local x = (typeof(t) == "table") and table.clone(t) or {}
    x[FIELDS.attack]  = clampNonNegInt(x[FIELDS.attack]  or 0)
    x[FIELDS.defense] = clampNonNegInt(x[FIELDS.defense] or 0)
    x[FIELDS.health]  = clampNonNegInt(x[FIELDS.health]  or 0)
    return x
end

-- 属性名归一化：支持多种写法
local NAME_ALIAS = {
    attack  = FIELDS.attack,
    atk     = FIELDS.attack,

    defense = FIELDS.defense,
    defence = FIELDS.defense,
    def     = FIELDS.defense,

    health  = FIELDS.health,
    hp      = FIELDS.health,
}

local function normalizeFieldName(name)
    if typeof(name) ~= "string" then
        return nil
    end
    local key = string.lower(name)
    return NAME_ALIAS[key]
end

-- 变更事件：给 UI / 其他服务用
local changedBE = Instance.new("BindableEvent")
local AttrModule = {}
AttrModule.FIELDS       = FIELDS
AttrModule.DISPLAY_NAME = DISPLAY_NAME

function AttrModule.onChanged(cb) -- cb(player, snapshotTable)
    return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStore2 写回 cache
local function commit(player, state, reason)
    local store = getStore(player)
    store:Set(state)

    changedBE:Fire(player, table.clone(state))

    dprint("%s Attr commit（%s）→ atk=%d, def=%d, hp=%d",
        player.Name,
        reason or "无原因",
        state[FIELDS.attack],
        state[FIELDS.defense],
        state[FIELDS.health]
    )

    return state
end

local function mutate(player, reason, mutator)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    mutator(state)
    state = ensureShape(state)
    return commit(player, state, reason)
end

-- 对外 API ----------------------------------------------------------↓

-- 初始化：只保证数据 shape 正常，顺带发一次 changed 方便 UI 初始化
function AttrModule.initPlayer(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "init")
    return table.clone(state)
end

function AttrModule.ensureInitialized(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "ensureInit")
    return table.clone(state)
end

-- 基本查询
function AttrModule.getAll(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return table.clone(state)
end

function AttrModule.get(player, fieldKey)
    assert(fieldKey == FIELDS.attack or fieldKey == FIELDS.defense or fieldKey == FIELDS.health,
        "[AttrModule] 非法的属性键")
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state[fieldKey] or 0
end

-- GM 用：直接设置某个属性的总点数
function AttrModule.set(player, fieldKey, value, reason)
    assert(fieldKey == FIELDS.attack or fieldKey == FIELDS.defense or fieldKey == FIELDS.health,
        "[AttrModule] 非法的属性键")
    assert(type(value) == "number", "[AttrModule] 目标值必须为数字")

    local state = mutate(player, "set:" .. fieldKey .. " " .. (reason or ""), function(s)
        s[fieldKey] = clampNonNegInt(value)
    end)

    return state[fieldKey]
end

-- 加点工具：尝试消耗技能点并给某个属性加点
-- 入参：player, rawFieldName任意写法(attack/atk/def/defense/hp/health)，amount加多少点，reason
-- 返回：ok，属性名，新的属性值，用了多少sp，还剩多少sp，错误信息
function AttrModule.spendPoints(player, rawFieldName, amount, reason)
    local fieldKey = normalizeFieldName(rawFieldName)
    if not fieldKey then
        return false, nil, nil, nil, nil, "invalid_attr"
    end

    amount = clampNonNegInt(amount)
    if amount <= 0 then
        return false, nil, nil, nil, nil, "invalid_amount"
    end

    -- 先让 ExpModule 检查并消耗技能点
    local ok, usedSp, freeSp = ExpModule.trySpendSkillPoints(player, amount, "attr:" .. fieldKey .. " " .. (reason or ""))
    if not ok then
        return false, nil, nil, nil, freeSp, "not_enough_sp"
    end

    -- 技能点已经被标记为已用，这里再把点数分配到具体属性上
    local state = mutate(player, "add:" .. fieldKey .. " " .. (reason or ""), function(s)
        local cur = clampNonNegInt(s[fieldKey] or 0)
        s[fieldKey] = cur + amount
    end)

    local newValue = state[fieldKey]

    dprint("%s 属性加点 %s +%d → %d（已用技能点 %d，可用 %d）（%s）",
        player.Name,
        fieldKey,
        amount,
        newValue,
        usedSp or -1,
        freeSp or -1,
        reason or "无原因"
    )

    return true, fieldKey, newValue, usedSp, freeSp, nil
end

return AttrModule
