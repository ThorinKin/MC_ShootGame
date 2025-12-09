-- ReplicatedStorage/Shared/EnemyAttackType/SingleMelee.lua
-- 单体近战攻击模块：进入攻击距离 → 前摇 → 对当前目标造成一次伤害
local SingleMelee = {}

-- 配置字段名常量
local FIELD_RANGE    = "Range"
local FIELD_DAMAGE   = "Damage"
local FIELD_COOLDOWN = "Cooldown"
local FIELD_WINDUP   = "WindupTime"

-- 工具：兼容子节点 NumberValue，兼容 Attribute
local function getNumberConfig(node: Instance, name: string, default: number): number
	local child = node:FindFirstChild(name)
	if child and child:IsA("NumberValue") then
		return child.Value
	end
	if child and child:IsA("IntValue") then
		return child.Value
	end

	local attr = node:GetAttribute(name)
	if typeof(attr) == "number" then
		return attr :: number
	end

	return default
end

-- init：在敌人生成时调用，读取 AttackConfigs/AttackX 里的参数
-- 返回的 state 完全由本模块管理
function SingleMelee.init(enemy: Model, configNode: Instance)
	local cfg = {
		range      = getNumberConfig(configNode, FIELD_RANGE,    4),    -- 攻击距离
		damage     = getNumberConfig(configNode, FIELD_DAMAGE,   10),   -- 伤害
		cooldown   = getNumberConfig(configNode, FIELD_COOLDOWN, 1.5),  -- 冷却（秒）
		windupTime = getNumberConfig(configNode, FIELD_WINDUP,   0.3),  -- 前摇时长（秒）
	}

	local state = {
		enemy          = enemy,
		config         = cfg,
		lastAttackTime = 0,     -- 上一次攻击真正生效的时间戳
		windupEndTime  = nil,   -- nil = 不在前摇中，否则为前摇结束时间戳
		targetHumanoid = nil,   -- 当前这次攻击锁定的目标
	}

	return state
end

-- 攻击触发范围：给 EnemyService 用来判断进没进攻击距离
function SingleMelee.getRange(state): number
	return state.config.range
end

-- update：在 AI 判定目标在攻击距离里时，每个 AI_TICK 调用一次
-- ctx = {
--    now: number,
--    enemy: Model,
--    humanoid: Humanoid,
--    hrp: BasePart,
--    targetHumanoid: Humanoid?, -- 不在攻击距离/丢失目标时可能为 nil
--    targetRoot: BasePart?,
--    distance: number,
-- }
function SingleMelee.update(state, dt: number, ctx)
	local cfg  = state.config
	local now  = ctx.now
	local targetHumanoid: Humanoid? = ctx.targetHumanoid

	-- 目标已经死了 / 不存在：清空前摇
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		state.windupEndTime  = nil
		state.targetHumanoid = nil
		return
	end

	-- 安全兜底：如果距离超过配置 Range，也清前摇
	if ctx.distance > cfg.range then
		state.windupEndTime  = nil
		state.targetHumanoid = nil
		return
	end

	-- 当前不在前摇阶段：检查冷却是否已结束，决定要不要发起一次攻击
	if state.windupEndTime == nil then
		if now - state.lastAttackTime < cfg.cooldown then
			return
		end

		-- 进入前摇：锁定当前目标
		state.windupEndTime  = now + cfg.windupTime
		state.targetHumanoid = targetHumanoid
		return
	end

	-- 在前摇中，但时间还没到：继续蓄力
	if now < state.windupEndTime then
		return
	end

	-- 前摇结束：真正结算伤害
	state.windupEndTime  = nil
	state.lastAttackTime = now

	local hitHumanoid = state.targetHumanoid
	state.targetHumanoid = nil

	if hitHumanoid and hitHumanoid.Health > 0 then
		hitHumanoid:TakeDamage(cfg.damage)
	end
end

return SingleMelee
