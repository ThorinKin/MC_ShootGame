-- ReplicatedStorage/Shared/EnemyAttackType/SingleMelee.lua
-- 单体近战攻击模块：进入攻击距离 → 前摇 → 对当前锁定目标造成一次伤害(指向性攻击)
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

-- init：在敌人生成时调用，读取 AttackConfigs/AttackX 里的参数；返回的 state 完全由本模块管理
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

-- update：在 AI 判定可以攻击时，每个 AI_TICK 调用一次
function SingleMelee.update(state, dt: number, ctx)
	local cfg = state.config
	local now = ctx.now
	-- 已经锁定的目标（用于前摇中）
	local lockedHumanoid: Humanoid? = state.targetHumanoid
	-- AI 这帧提供的目标（用于决定要不要起手）
	local ctxTargetHumanoid: Humanoid? = ctx.targetHumanoid

	-- 情况一：当前不在前摇，尝试发起一次新的攻击
	if state.windupEndTime == nil then
		-- 必须有合法目标才考虑出手
		if not ctxTargetHumanoid or ctxTargetHumanoid.Health <= 0 then
			return
		end
		-- 还没进攻击距离：不出手
		if ctx.distance > cfg.range then
			return
		end
		-- 冷却未结束：不出手
		if now - state.lastAttackTime < cfg.cooldown then
			return
		end
		-- 进入前摇：锁定当前目标
		state.windupEndTime  = now + cfg.windupTime
		state.targetHumanoid = ctxTargetHumanoid
		-- 通知客户端这一刀已经抬手了：用 AttackTick 驱动攻击动画
		local enemy = state.enemy
		if enemy and enemy:IsA("Model") then
			local cur = enemy:GetAttribute("AttackTick")
			if typeof(cur) ~= "number" then
				cur = 0
			end
			enemy:SetAttribute("AttackTick", cur + 1)
		end
		return
	end

	-- 情况二：已经在前摇中（锁定了目标）；只要前摇时间到，就结算伤害
	-- 除非：目标已经死了 / 不存在：这次攻击作废
	if not lockedHumanoid or lockedHumanoid.Health <= 0 then
		state.windupEndTime  = nil
		state.targetHumanoid = nil
		return
	end
	-- 指向性攻击
	if now < state.windupEndTime then
		return
	end
	-- 前摇结束：真正结算伤害
	state.windupEndTime  = nil
	state.lastAttackTime = now
	state.targetHumanoid = nil

	if lockedHumanoid.Health > 0 then
		lockedHumanoid:TakeDamage(cfg.damage)
	end
end

return SingleMelee
