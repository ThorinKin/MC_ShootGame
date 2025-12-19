-- StarterPlayer/StarterPlayerScripts/Client/Effects/DamagePopup.client.lua
-- 通用伤害跳字监听：客户端观察 Humanoid.HealthChanged，纯本地特效
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamagePopup = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("DamagePopup"))

local player = Players.LocalPlayer

-- 记录已经监听过的 Humanoid
type TrackInfo = {
	lastHealth: number,
	conn: RBXScriptConnection?,
}

local tracked: { [Humanoid]: TrackInfo } = {}

-------------配置-------------
local MIN_DAMAGE = 0.5 -- 小于这个值就不跳字
local CRIT_THRESHOLD_MULT = 1.5 -- 大于这个值算暴击
-------------配置-------------

-- 工具取枪械基础伤害
local function getLocalEquippedBaseDamage(): number?
	local char = player.Character
	if not char then return nil end

	-- 你项目里可能同时有别的 Tool，这里就“随便抓一个 Tool”
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then return nil end

	local dmg = tool:GetAttribute("damage") -- 你也可以 require Constants 用 Constants.DAMAGE_ATTRIBUTE
	dmg = tonumber(dmg)
	if not dmg or dmg <= 0 then return nil end
	return dmg
end

local function stopTracking(humanoid: Humanoid)
	local info = tracked[humanoid]
	if not info then
		return
	end
	if info.conn then
		info.conn:Disconnect()
	end
	tracked[humanoid] = nil
end

local function startTracking(humanoid: Humanoid)
	if tracked[humanoid] then
		return
	end

	local info: TrackInfo = {
		lastHealth = humanoid.Health,
		conn = nil,
	}
	tracked[humanoid] = info

	info.conn = humanoid.HealthChanged:Connect(function(newHealth: number)
		local old = info.lastHealth or newHealth
		info.lastHealth = newHealth

		local delta = newHealth - old
		if delta == 0 then
			return
		end
		-- 生命下降 = 伤害
		if delta < 0 then
			local damage = -delta
			if damage < MIN_DAMAGE then
				return
			end
			local base = getLocalEquippedBaseDamage()
			local isCrit = (base ~= nil and damage >= base * CRIT_THRESHOLD_MULT)
			-- 纯客户端特效：服务器已经算好伤害并 TakeDamage 了
			DamagePopup.show(humanoid, damage, false, isCrit)
		else
			-- 生命上升 = 治疗
			local heal = delta
			if heal < MIN_DAMAGE then
				return
			end
			DamagePopup.show(humanoid, heal, true) -- isHeal=true，会走绿色
		end
	end)

	-- Humanoid 被 Destroy 时清理监听
	humanoid.Destroying:Connect(function()
		stopTracking(humanoid)
	end)
end

-- 初始扫描一次场景里的所有 Humanoid（玩家 / 敌人 / 刷怪）
local function scanExistingHumanoids()
	for _, inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Humanoid") then
			startTracking(inst)
		end
	end
end

scanExistingHumanoids()

-- 后续新增的 Humanoid 也要监听（玩家重生 / 新刷怪等）
Workspace.DescendantAdded:Connect(function(inst: Instance)
	if inst:IsA("Humanoid") then
		startTracking(inst)
	end
end)
