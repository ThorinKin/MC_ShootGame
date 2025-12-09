-- ServerScriptService/Server/ExpService/ExpModule.lua
-- 总注释：Exp 系统模块。主管业务，DataStore2 仅动 cache
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化

----------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[ExpModule] " .. string.format(fmt, ...))
    end
end

-- 字段枚举
local FIELDS = {
    xp        = "xp",
    level     = "level",
    xpInLevel = "xpInLevel",
    usedSp    = "usedSp",
}
table.freeze(FIELDS)

-- 默认值
local DEFAULT = {
    [FIELDS.xp]        = 0,
    [FIELDS.level]     = 1,
    [FIELDS.xpInLevel] = 0,
    [FIELDS.usedSp]    = 0,
}
table.freeze(DEFAULT)
----------------------------------------------------------------

-- 4个格式工具
local function clampNonNegInt(n)
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end
    return n
end
-- 技能点上限/升级公式需要替换方案没给
local function expRequiredForLevel(level)
    level = math.max(1, math.floor(level or 1))
    local need = 200 * (level ^ 1.6) + 500
    return math.floor(need)
end
local function totalSkillPointsForLevel(level)
    level = math.max(1, math.floor(level or 1))
    return level * 3
end
local function ensureShape(t)
    local x = (typeof(t) == "table") and table.clone(t) or {}
    x[FIELDS.xp]        = clampNonNegInt(x[FIELDS.xp] or 0)
    x[FIELDS.level]     = math.max(1, math.floor(x[FIELDS.level] or 1))
    x[FIELDS.xpInLevel] = clampNonNegInt(x[FIELDS.xpInLevel] or 0)
    x[FIELDS.usedSp]    = clampNonNegInt(x[FIELDS.usedSp] or 0)
    local cap = totalSkillPointsForLevel(x[FIELDS.level])
    if x[FIELDS.usedSp] > cap then x[FIELDS.usedSp] = cap end
    return x
end

-- 工具：处理升级
local function resolveLevelUps(state)
    local ups = 0
    while true do
        local need = expRequiredForLevel(state[FIELDS.level])
        if state[FIELDS.xpInLevel] >= need then
            state[FIELDS.xpInLevel] -= need
            state[FIELDS.level] += 1
            ups += 1
        else
            break
        end
    end
    local cap = totalSkillPointsForLevel(state[FIELDS.level])
    if state[FIELDS.usedSp] > cap then state[FIELDS.usedSp] = cap end
    return state, ups
end

-- 工具：查玩家数据
local function getStore(player)
    return DataStore2(StoreRegistry.Exp, player)
end

-- 变更事件：给 UI / 其他逻辑用
local changedBE = Instance.new("BindableEvent")
local ExpModule = {}
ExpModule.FIELDS                   = FIELDS
ExpModule.expRequiredForLevel      = expRequiredForLevel
ExpModule.totalSkillPointsForLevel = totalSkillPointsForLevel
function ExpModule.onChanged(cb) -- cb(player, snapshotTable)
    return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStroe2 写回 cache
local function commit(player, state, reason)
    local store = getStore(player)
    store:Set(state)
    changedBE:Fire(player, table.clone(state))

    dprint("%s Exp commit（%s）→ lvl=%d, xp=%d, xpInLevel=%d, usedSp=%d",
        player.Name, reason or "无原因",
        state[FIELDS.level], state[FIELDS.xp], state[FIELDS.xpInLevel], state[FIELDS.usedSp])

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

-- 初始化
function ExpModule.initPlayer(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "init")
    return table.clone(state)
end

function ExpModule.ensureInitialized(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "ensureInit")
    return table.clone(state)
end

-- 基本查询
function ExpModule.getAll(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return table.clone(state)
end

function ExpModule.getLevel(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state[FIELDS.level]
end

function ExpModule.getTotalExp(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state[FIELDS.xp]
end

function ExpModule.getTotalSkillPoints(player)
    return totalSkillPointsForLevel(ExpModule.getLevel(player))
end

function ExpModule.getUsedSkillPoints(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state[FIELDS.usedSp]
end

function ExpModule.getFreeSkillPoints(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local cap = totalSkillPointsForLevel(state[FIELDS.level])
    return math.max(0, cap - state[FIELDS.usedSp])
end

-- 增加经验：返回 totalExp, level, leveledUp
function ExpModule.addExp(player, amount, reason)
    assert(type(amount) == "number" and amount >= 0, "[ExpModule] 经验增量必须为非负数")
    local leveledUp = 0

    local state = mutate(player, "addExp " .. (reason or ""), function(s)
        local add = clampNonNegInt(amount)
        s[FIELDS.xp]        += add
        s[FIELDS.xpInLevel] += add
        s, leveledUp = resolveLevelUps(s)
    end)

    dprint("%s 获得经验 +%d → 等级 %d，总经验 %d（%s，升了%d级）",
        player.Name, amount, state[FIELDS.level], state[FIELDS.xp], reason or "无原因", leveledUp)

    return state[FIELDS.xp], state[FIELDS.level], leveledUp
end

-- 设总经验（GM）
function ExpModule.setTotalExp(player, totalExp, reason)
    local state = mutate(player, "setTotalExp " .. (reason or ""), function(s)
        s[FIELDS.xp]        = clampNonNegInt(totalExp)
        s[FIELDS.level]     = 1
        s[FIELDS.xpInLevel] = s[FIELDS.xp]
        s, _ = resolveLevelUps(s)
    end)

    return state[FIELDS.xp], state[FIELDS.level]
end

-- 设等级（GM）
function ExpModule.setLevel(player, targetLevel, reason)
    local state = mutate(player, "setLevel " .. (reason or ""), function(s)
        local lvl = math.max(1, math.floor(targetLevel or 1))
        s[FIELDS.level]     = lvl
        s[FIELDS.xpInLevel] = 0
        local cap = totalSkillPointsForLevel(lvl)
        if s[FIELDS.usedSp] > cap then s[FIELDS.usedSp] = cap end
    end)

    return state[FIELDS.level]
end

-- 设已用技能点（GM）
function ExpModule.setUsedSkillPoints(player, amount, reason)
    assert(type(amount) == "number" and amount >= 0, "[ExpModule] usedSp 必须为非负数")

    local state = mutate(player, "setUsedSp " .. (reason or ""), function(s)
        s[FIELDS.usedSp] = clampNonNegInt(amount)
    end)

    local cap  = totalSkillPointsForLevel(state[FIELDS.level])
    local used = state[FIELDS.usedSp]
    local free = math.max(0, cap - used)
    return used, free
end

-- 消耗技能点
function ExpModule.trySpendSkillPoints(player, amount, reason)
    assert(type(amount) == "number" and amount >= 0, "[ExpModule] 技能点消耗必须为非负数")
    amount = clampNonNegInt(amount)

    local ok, used, free

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))

    if amount == 0 then
        local cap = totalSkillPointsForLevel(state[FIELDS.level])
        used = state[FIELDS.usedSp]
        free = math.max(0, cap - used)
        return true, used, free
    end

    local cap = totalSkillPointsForLevel(state[FIELDS.level])
    local canUse = math.max(0, cap - state[FIELDS.usedSp])

    if amount <= canUse then
        state[FIELDS.usedSp] += amount
        ok = true
    else
        ok = false
    end

    state = ensureShape(state)

    used = state[FIELDS.usedSp]
    free = math.max(0, cap - used)

    if ok then
        commit(player, state, "spendSp " .. (reason or ""))
        dprint("%s 消耗技能点 -%d（%s）→ 已用 %d，可用 %d",
            player.Name, amount, reason or "无原因", used, free)
    else
        dprint("%s 消耗技能点失败，需要 %d，可用不足（%s）", player.Name, amount, reason or "无原因")
    end

    return ok, used, free
end

-- 返还技能点
function ExpModule.refundSkillPoints(player, amount, reason)
    assert(type(amount) == "number" and amount >= 0, "[ExpModule] 技能点返还必须为非负数")
    amount = clampNonNegInt(amount)

    local state = mutate(player, "refundSp " .. (reason or ""), function(s)
        if amount > 0 then
            if amount >= s[FIELDS.usedSp] then
                s[FIELDS.usedSp] = 0
            else
                s[FIELDS.usedSp] -= amount
            end
        end
    end)

    local cap  = totalSkillPointsForLevel(state[FIELDS.level])
    local used = state[FIELDS.usedSp]
    local free = math.max(0, cap - used)

    return used, free
end

return ExpModule
