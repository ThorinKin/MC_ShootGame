-- ReplicatedStorage/Shared/TPSCameraKick.lua
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TPSCameraKick = {}
local offset = Vector3.zero

RunService:BindToRenderStep("TPSCameraKick", Enum.RenderPriority.Camera.Value + 2, function(dt)
    local cam = Workspace.CurrentCamera
    if not cam then return end
    -- 指数衰减
    offset = offset * math.exp(-dt * 10)
    if offset.Magnitude < 0.001 then return end
    cam.CFrame = cam.CFrame + offset
end)

function TPSCameraKick.kick(strength)
    local cam = Workspace.CurrentCamera
    if not cam then return end

    strength = strength or 0.2 -- 可再调小点
    local look = cam.CFrame.LookVector
    local up   = cam.CFrame.UpVector

    -- 往后 + 往上抖一点
    offset += (-look * strength * 0.5) + (up * strength * 0.5)
end

return TPSCameraKick
