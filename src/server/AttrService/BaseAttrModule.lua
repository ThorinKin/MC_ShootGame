-- ServerScriptService/Server/AttrService/BaseAttrModule.lua
-- 总注释：基础属性模块与加点系统无关。落库到 DataStore2 的 Attr 子键里（同表不同字段）提供最基础的 get/set/add/mul 接口
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化

----------------------------------------------------------------
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[BaseAttrModule] " .. string.format(fmt, ...))
	end
end

-- 字段枚举：
local FIELDS = {
	baseHealth     = "baseHealth",     -- 基础生命
	critChance     = "critChance",     -- 基础暴击率（0~1）
	critDamage     = "critDamage",     -- 基础暴击伤害倍率（>=1）
	luck           = "luck",           -- 基础运气（>=0）
	moveSpeed      = "moveSpeed",      -- 基础移动速度（>=0）
	damageReduction= "damageReduction",-- 基础伤害减免（0~0.95）
	coinMultiplier = "coinMultiplier", -- 金币加成倍率（>=0）
	armor          = "armor",          -- 基础护甲（>=0）
	gunBonus       = "gunBonus",       -- 枪械加成（>=0）
}
table.freeze(FIELDS)

-- 默认值
local DEFAULT = {
	[FIELDS.baseHealth]      = 100,
	[FIELDS.critChance]      = 0.05,
	[FIELDS.critDamage]      = 1.5,
	[FIELDS.luck]            = 1,
	[FIELDS.moveSpeed]       = 16,
	[FIELDS.damageReduction] = 0,
	[FIELDS.coinMultiplier]  = 1,
	[FIELDS.armor]           = 0,
	[FIELDS.gunBonus]        = 0,
}
table.freeze(DEFAULT)

-- 别名：给外部系统传字符串用
local NAME_ALIAS = {
	basehealth      = FIELDS.baseHealth,
	hpbase          = FIELDS.baseHealth,
	critchance      = FIELDS.critChance,
	crit            = FIELDS.critChance,
	crit_rate       = FIELDS.critChance,
	critdamage      = FIELDS.critDamage,
	critdmg         = FIELDS.critDamage,
	crit_mult       = FIELDS.critDamage,
	luck            = FIELDS.luck,
	movespeed       = FIELDS.moveSpeed,
	speed           = FIELDS.moveSpeed,
	walkspeed       = FIELDS.moveSpeed,
	damagereduction = FIELDS.damageReduction,
	dr              = FIELDS.damageReduction,
	reduction       = FIELDS.damageReduction,
	coinmultiplier  = FIELDS.coinMultiplier,
	coinmul         = FIELDS.coinMultiplier,
	coinbonus       = FIELDS.coinMultiplier,
	armor           = FIELDS.armor,
	gunbonus        = FIELDS.gunBonus,
	gun             = FIELDS.gunBonus,
	weaponbonus     = FIELDS.gunBonus,
}
local function normalizeFieldName(name)
	if typeof(name) ~= "string" then return nil end
	return NAME_ALIAS[string.lower(name)]
end

----------------------------------------------------------------
-- 工具
local function clampIntNonNeg(n)
	n = math.floor(tonumber(n) or 0)
	if n < 0 then n = 0 end
	return n
end

local function clampNumber(minV, maxV, n, defaultV)
	n = tonumber(n)
	if n == nil then n = tonumber(defaultV) or 0 end
	if minV ~= nil and n < minV then n = minV end
	if maxV ~= nil and n > maxV then n = maxV end
	return n
end

local function getStore(player)
	return DataStore2(StoreRegistry.Attr, player) -- 用 Attr 这张表
end

-- 保证形状：只补/修基础属性字段，加点系统字段（attack/defense/health）不动
local function ensureShape(t)
	local x = (typeof(t) == "table") and table.clone(t) or {}
	x[FIELDS.baseHealth]      = clampIntNonNeg(x[FIELDS.baseHealth]      or DEFAULT[FIELDS.baseHealth])
	x[FIELDS.critChance]      = clampNumber(0, 1,    x[FIELDS.critChance],      DEFAULT[FIELDS.critChance])
	x[FIELDS.critDamage]      = clampNumber(1, nil,  x[FIELDS.critDamage],      DEFAULT[FIELDS.critDamage])
	x[FIELDS.luck]            = clampNumber(0, nil,  x[FIELDS.luck],            DEFAULT[FIELDS.luck])
	x[FIELDS.moveSpeed]       = clampNumber(0, nil,  x[FIELDS.moveSpeed],       DEFAULT[FIELDS.moveSpeed])
	-- 伤害减免上限 0.95
	x[FIELDS.damageReduction] = clampNumber(0, 0.95, x[FIELDS.damageReduction], DEFAULT[FIELDS.damageReduction])
	x[FIELDS.coinMultiplier]  = clampNumber(0, nil,  x[FIELDS.coinMultiplier],  DEFAULT[FIELDS.coinMultiplier])
	x[FIELDS.armor]           = clampIntNonNeg(x[FIELDS.armor]           or DEFAULT[FIELDS.armor])
	x[FIELDS.gunBonus]        = clampNumber(0, nil,  x[FIELDS.gunBonus],        DEFAULT[FIELDS.gunBonus])
	return x
end

-- 只导出基础属性那一段给外部
local function pickBaseSnapshot(state)
	return {
		[FIELDS.baseHealth]      = state[FIELDS.baseHealth],
		[FIELDS.critChance]      = state[FIELDS.critChance],
		[FIELDS.critDamage]      = state[FIELDS.critDamage],
		[FIELDS.luck]            = state[FIELDS.luck],
		[FIELDS.moveSpeed]       = state[FIELDS.moveSpeed],
		[FIELDS.damageReduction] = state[FIELDS.damageReduction],
		[FIELDS.coinMultiplier]  = state[FIELDS.coinMultiplier],
		[FIELDS.armor]           = state[FIELDS.armor],
		[FIELDS.gunBonus]        = state[FIELDS.gunBonus],
	}
end

----------------------------------------------------------------
-- 变更事件（给同步脚本/别的系统订阅）
local changedBE = Instance.new("BindableEvent")

local BaseAttrModule = {}
BaseAttrModule.FIELDS  = FIELDS
BaseAttrModule.DEFAULT = DEFAULT

function BaseAttrModule.onChanged(cb) -- cb(player, snapshotTable)
	return changedBE.Event:Connect(cb)
end

local function commit(player, fullState, reason)
	local store = getStore(player)
	store:Set(fullState)

	local snap = pickBaseSnapshot(fullState)
	changedBE:Fire(player, table.clone(snap))

	dprint("%s BaseAttr commit(%s)", player.Name, reason or "no_reason")
	return snap
end

local function mutate(player, reason, mutator)
	local store = getStore(player)
	local full = ensureShape(store:Get({})) -- 用 {} 拿到整张表
	mutator(full)
	full = ensureShape(full)
	return commit(player, full, reason)
end

----------------------------------------------------------------
-- 对外 API

-- 初始化：补齐默认值（不会影响加点字段）
function BaseAttrModule.initPlayer(player)
	local store = getStore(player)
	local full  = ensureShape(store:Get({}))
	commit(player, full, "init")
	return pickBaseSnapshot(full)
end

function BaseAttrModule.ensureInitialized(player)
	local store = getStore(player)
	local full  = ensureShape(store:Get({}))
	commit(player, full, "ensureInit")
	return pickBaseSnapshot(full)
end

function BaseAttrModule.getAll(player)
	local store = getStore(player)
	local full  = ensureShape(store:Get({}))
	return pickBaseSnapshot(full)
end

-- 获取玩家特定字段值（字段key）
function BaseAttrModule.get(player, fieldKey)
	assert(type(fieldKey) == "string", "[BaseAttrModule] fieldKey must be string")
	local store = getStore(player)
	local full  = ensureShape(store:Get({}))
	return full[fieldKey]
end
-- 获取玩家特定字段值（原始字段名）
function BaseAttrModule.getByName(player, rawName)
	local fk = normalizeFieldName(rawName)
	if not fk then return nil end
	return BaseAttrModule.get(player, fk)
end

-- 指定玩家特定字段数值
function BaseAttrModule.set(player, fieldKey, value, reason)
	return mutate(player, "set:" .. fieldKey .. " " .. (reason or ""), function(s)
		s[fieldKey] = value
	end)[fieldKey]
end

-- 增加玩家特定字段数值
function BaseAttrModule.add(player, fieldKey, delta, reason)
	delta = tonumber(delta) or 0
	return mutate(player, "add:" .. fieldKey .. " " .. (reason or ""), function(s)
		s[fieldKey] = (tonumber(s[fieldKey]) or 0) + delta
	end)[fieldKey]
end

-- 减少玩家特定字段数值
function BaseAttrModule.sub(player, fieldKey, delta, reason)
	delta = tonumber(delta) or 0
	return mutate(player, "sub:" .. fieldKey .. " " .. (reason or ""), function(s)
		s[fieldKey] = (tonumber(s[fieldKey]) or 0) - delta
	end)[fieldKey]
end

-- 乘算玩家特定字段数值
function BaseAttrModule.mul(player, fieldKey, factor, reason)
	factor = tonumber(factor) or 1
	return mutate(player, "mul:" .. fieldKey .. " " .. (reason or ""), function(s)
		s[fieldKey] = (tonumber(s[fieldKey]) or 0) * factor
	end)[fieldKey]
end

return BaseAttrModule
