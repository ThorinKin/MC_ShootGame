-- StarterPlayer/StarterPlayerScripts/Client/Throwables/ThrowableInputBootstrap.client.lua
-- 总注释：投掷物输入模块启动脚本。
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThrowableInput = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Throwables"):WaitForChild("ThrowableInput"))

ThrowableInput.init()
