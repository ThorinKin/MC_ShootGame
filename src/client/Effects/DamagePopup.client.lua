-- StarterPlayer/StarterPlayerScripts/Client/Effects/DamagePopup.client.lua
-- 通用伤害跳字监听：客户端观察 Humanoid.HealthChanged，纯本地特效
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamagePopup = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("DamagePopup"))

-- 记录已经监听过的 Humanoid
type TrackInfo = {
	lastHealth: number,
	conn: RBXScriptConnection?,
}

local tracked: { [Humanoid]: TrackInfo } = {}

local MIN_DAMAGE = 0.5 -- 小于这个值就不跳字

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

			-- 纯客户端特效：服务器已经算好伤害并 TakeDamage 了
			DamagePopup.show(humanoid, damage, false)

		else
			-- 生命上升 = 治疗 预留的，暂时没有
			-- DamagePopup.show(humanoid, delta, true)
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
