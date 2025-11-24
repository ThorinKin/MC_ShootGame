-- StarterPlayer/StarterPlayerScripts/Client/ThirdPersonOverShoulder.client.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerViewState"))

local localPlayer = Players.LocalPlayer

local character: Model? = nil
local currentCombatState: string? = nil

-- 过肩偏移参数
local SHOULDER_RIGHT = 3.2   -- 向右多少（studs）
local SHOULDER_UP    = 1.4   -- 向上多少
local SHOULDER_FWD   = 0     -- 前后偏移 滚轮

-- 进出过肩视角的平滑速度
local LERP_SPEED = 10

-- 0 = 完全无偏移（居中）、1 = 完全过肩
local offsetAlpha = 0

local function onCombatStateChanged()
	if not character then
		return
	end
	currentCombatState = character:GetAttribute("CombatState")
end

local function onCharacterAdded(char: Model)
	character = char
	currentCombatState = char:GetAttribute("CombatState")

	char:GetAttributeChangedSignal("CombatState"):Connect(onCombatStateChanged)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

RunService:BindToRenderStep(
	"TPS_OverShoulder",
	Enum.RenderPriority.Camera.Value + 1, -- 在默认相机之后，在视模之前
	function(dt)
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		-- 切视角 tween 期间 CameraType 会设成 Scriptable，这时候不抢相机
		if cam.CameraType ~= Enum.CameraType.Custom then
			return
		end

		local char = character
		if not char then
			return
		end

		-- 只有第三人称 + 持枪时目标是 1，其它状态目标是 0
		local isTPArmed = (currentCombatState == PlayerViewState.CombatState.TP_Armed)
		local targetAlpha = isTPArmed and 1 or 0

		-- 简单指数插值，避免镜头瞬移
		local t = math.clamp(dt * LERP_SPEED, 0, 1)
		offsetAlpha = offsetAlpha + (targetAlpha - offsetAlpha) * t

		-- 几乎是 0 就不用写相机了，省一点运算
		if offsetAlpha < 0.001 then
			return
		end

		local baseCF = cam.CFrame
		local right = baseCF.RightVector
		local up = baseCF.UpVector
		local forward = baseCF.LookVector

		local offset =
			right * (SHOULDER_RIGHT * offsetAlpha)
			+ up * (SHOULDER_UP * offsetAlpha)
			+ forward * (SHOULDER_FWD * offsetAlpha)

		-- CFrame + Vector3 只改位置，不改朝向
		cam.CFrame = baseCF + offset
	end
)
