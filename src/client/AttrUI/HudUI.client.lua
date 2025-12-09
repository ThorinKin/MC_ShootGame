-- StarterPlayer/StarterPlayerScripts/Client/AttrUI/HudUI.client.lua
-- 总注释：暂时只从Players服务取金钱数值填客户端UI
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local AbbNumber = require(ReplicatedStorage.Shared.Utility.AbbNumber)

-- hud显示金币的textLabel直接填值
local coinText = playerGui:WaitForChild("HUD")
	:WaitForChild("Left")
	:WaitForChild("Menu")
	:WaitForChild("Coin")
	:WaitForChild("BG")
	:WaitForChild("TextLabel")

-- Players 服务：leaderstats/Cash
local leaderstats = localPlayer:WaitForChild("leaderstats")
local cashValue   = leaderstats:WaitForChild("Cash")

-- 工具：刷新金币显示
local function refreshCoinText()
	local amount = tonumber(cashValue.Value) or 0
	coinText.Text = AbbNumber.AbbreviateNumber(amount, 1)
end

-- 初始刷新一帧
refreshCoinText()

-- 监听金币变化，自动刷新 HUD
cashValue.Changed:Connect(refreshCoinText)
