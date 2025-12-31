-- StarterPlayer/StarterPlayerScripts/Client/HUD/HudVariantSwitcher.client.lua
-- 总注释：根据设备输入能力启用 HUD / HUD_Mobile，并把活跃 HUD 注入 HudRegistry
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HudRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("HudRegistry"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------可调参数----------------------
-- 触屏/PC 的 HUD
local HUD_PC_NAME = "HUD"
local HUD_MOBILE_NAME = "HUD_Mobile"
-- 是否根据最近输入动态切换，暂时不开
local AUTO_SWITCH_BY_LAST_INPUT = false
--------------------------------------------------

local function isTouchInputType(t: Enum.UserInputType): boolean
	return t == Enum.UserInputType.Touch
end

local function wantMobileHud(lastInputType: Enum.UserInputType?): boolean
	-- TouchEnabled = 设备支持触屏（手机/平板/触屏本）
	if not UserInputService.TouchEnabled then
		return false
	end

	if not AUTO_SWITCH_BY_LAST_INPUT then
		-- 最稳：只要支持触摸，就用移动端 HUD
		return true
	end

	-- 动态：最近一次输入是 Touch 才切移动端
	if lastInputType then
		return isTouchInputType(lastInputType)
	end
	return true
end

local function applyHudVariant(useMobile: boolean)
	local hudPC = playerGui:FindFirstChild(HUD_PC_NAME) :: ScreenGui?
	local hudMobile = playerGui:FindFirstChild(HUD_MOBILE_NAME) :: ScreenGui?
	-- 兜底等一下（避免加载顺序偶发 nil）
	if not hudPC then
		hudPC = playerGui:WaitForChild(HUD_PC_NAME, 10) :: ScreenGui?
	end
	if not hudMobile then
		hudMobile = playerGui:WaitForChild(HUD_MOBILE_NAME, 10) :: ScreenGui?
	end

	if useMobile and hudMobile then
		if hudPC then hudPC.Enabled = false end
		hudMobile.Enabled = true
		HudRegistry.set(hudMobile)
	else
		if hudMobile then hudMobile.Enabled = false end
		if hudPC then
			hudPC.Enabled = true
			HudRegistry.set(hudPC)
		elseif hudMobile then
			-- 极端兜底：PC HUD 没有就用 mobile
			hudMobile.Enabled = true
			HudRegistry.set(hudMobile)
		end
	end
end

-- 初次应用
applyHudVariant(wantMobileHud(UserInputService:GetLastInputType()))

-- 动态切换，目前没开
if AUTO_SWITCH_BY_LAST_INPUT then
	UserInputService.LastInputTypeChanged:Connect(function(newType)
		applyHudVariant(wantMobileHud(newType))
	end)
end
