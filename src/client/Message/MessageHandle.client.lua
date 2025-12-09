-- StarterPlayer/StarterPlayerScripts/Client/Message/MessageHandle.client.lua
-- 总注释：客户端接收 服务器/客户端 下发通知文本并UI气泡显示文本
local Debirs = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local Players  = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local RemoteMessageBar   = game.ReplicatedStorage.Remotes.Message:WaitForChild("[S-C]Message")
local RemoteMessageNoBar = game.ReplicatedStorage.Remotes.Message:WaitForChild("[S-C]MessageNo")
local LocalMessageBar    = game.ReplicatedStorage.Remotes.Message:WaitForChild("[C-C]Message")
local LocalMessageNoBar  = game.ReplicatedStorage.Remotes.Message:WaitForChild("[C-C]MessageNo")

local TempleFrame = playerGui:WaitForChild("Message"):WaitForChild("MessagePrompt"):WaitForChild("Temple"):WaitForChild("Tip")
local TempleNoFrame = playerGui:WaitForChild("Message"):WaitForChild("MessagePrompt"):WaitForChild("Temple"):WaitForChild("TipNo")
local MessagePrompt = TempleFrame.Parent.Parent

function doMessage(message)
    local Temple = TempleFrame:Clone()
    Temple.TextLabel.Text = message
    Temple.Parent = MessagePrompt   
    Temple.Visible = true
    task.delay(2,function()
        TweenService:Create(Temple.TextLabel, TweenInfo.new(1), {TextTransparency = 1}):Play()
    end)
    Debirs:AddItem(Temple, 3)
end

function doNoMessage(message)
    local Temple = TempleNoFrame:Clone()
    Temple.TextLabel.Text = message
    Temple.Parent = MessagePrompt
    Temple.Visible = true
    task.delay(2,function()
        TweenService:Create(Temple.TextLabel, TweenInfo.new(1), {TextTransparency = 1}):Play()
    end)
    Debirs:AddItem(Temple, 3)
end

RemoteMessageBar.OnClientEvent:Connect(doMessage)
RemoteMessageNoBar.OnClientEvent:Connect(doNoMessage)
LocalMessageBar.Event:Connect(doMessage)
LocalMessageNoBar.Event:Connect(doNoMessage)
