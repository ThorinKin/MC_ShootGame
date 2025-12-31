-- StarterPlayer/StarterPlayerScripts/Client/View/ViewToggleTopbarIcon.client.lua
-- 总注释：用 TopbarPlus 在右上角创建Roblox 风格的顶栏按钮（视角切换按钮外壳）
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("PlayerViewState"))
-- BindableEvent：触发切视角等价于按 V
local viewControlFolder = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("View")
local toggleViewBE = viewControlFolder:WaitForChild("ToggleViewMode")
-- 依赖：TopbarPlus
local localPlayer = Players.LocalPlayer
local playerScripts = localPlayer:WaitForChild("PlayerScripts")
local TopbarPlus = require(playerScripts:WaitForChild("Satchel"):WaitForChild("Satchel"):WaitForChild("Packages"):WaitForChild("_Index"):WaitForChild("legitatx_topbarplus@3.0.5"):WaitForChild("topbarplus"))

-- 创建按钮
local viewIcon = TopbarPlus.new()
viewIcon:setName("ViewToggle")     -- 仅用于你自己识别/调试
viewIcon:setRight()                -- 右上角
viewIcon:setOrder(1)               -- 右侧通常 order 越小越靠边（如果位置不对就改大/改小）

viewIcon:setImage("rbxassetid://0") -- 预留图标资产ID
viewIcon:setImageScale(0.9)         -- 图标缩放看着更顶栏
viewIcon:setImageRatio(1)           -- 正方形图标
-- 或用文字 备选
-- viewIcon:setLabel("视角")

-- 点击回调，切视角
viewIcon:bindEvent("toggled", function(icon, isSelected, fromSource, sourceIcon)
    toggleViewBE:Fire()
end)
