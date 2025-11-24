-- StarterPlayer/StarterPlayerScripts/Client/ThirdPersonFacing.client.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerViewState"))
local ThirdPersonShooter = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ThirdPersonShooter"))

local localPlayer = Players.LocalPlayer

local character: Model? = nil
local humanoid: Humanoid? = nil
local currentCombatState: string? = nil

-- 转身速度 越大越跟手，越小越平滑
local ROTATE_SPEED = 12

local function updateHumanoid()
	if not character then
		character = localPlayer.Character
	end
	if character then
		humanoid = character:FindFirstChildOfClass("Humanoid")
	else
		humanoid = nil
	end
end

local function onCombatStateChanged()
	if not character then return end

	currentCombatState = character:GetAttribute("CombatState")
	updateHumanoid()

	if humanoid then
		-- 只有第三人称持枪时关掉默认自动朝向
		humanoid.AutoRotate = (currentCombatState ~= PlayerViewState.CombatState.TP_Armed)
	end
end

local function onCharacterAdded(char: Model)
	character = char
	updateHumanoid()

	-- 初始化一次 CombatState / AutoRotate
	currentCombatState = character:GetAttribute("CombatState")
	if humanoid then
		humanoid.AutoRotate = (currentCombatState ~= PlayerViewState.CombatState.TP_Armed)
	end

	-- 监听 CombatState 变化（包括切视角 + 抽/收枪）
	character:GetAttributeChangedSignal("CombatState"):Connect(onCombatStateChanged)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

RunService:BindToRenderStep("TP_MouseFacing", Enum.RenderPriority.Character.Value + 1, function(dt)
	if not character or not humanoid then
		return
	end

	-- 只在「第三人称持枪」状态下做朝向
	if currentCombatState ~= PlayerViewState.CombatState.TP_Armed then
		return
	end

	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not hrp then
		return
	end

	-- 用 ThirdPersonShooter 的鼠标射线函数，拿到鼠标指向的世界坐标
	local targetPos = ThirdPersonShooter.getMouseWorldTarget(cam, { character })

	local rootPos = hrp.Position
	-- 只关心水平面上的方向，Y 轴置 0
	local dir = Vector3.new(targetPos.X - rootPos.X, 0, targetPos.Z - rootPos.Z)
	if dir.Magnitude < 0.1 then
		return
	end

	local desiredDir = dir.Unit

	-- 当前朝向（也投影到水平面）
	local currentLook = hrp.CFrame.LookVector
	local currentDir = Vector3.new(currentLook.X, 0, currentLook.Z)
	if currentDir.Magnitude < 0.001 then
		currentDir = desiredDir
	else
		currentDir = currentDir.Unit
	end

	-- 简单插值一下，避免瞬间 180° 折返
	local alpha = math.clamp(dt * ROTATE_SPEED, 0, 1)
	local blended = (currentDir * (1 - alpha) + desiredDir * alpha).Unit

	-- 用 lookAt 保证只转 Y 轴（因为我们已经把 Y 分量归零了）
	local newCF = CFrame.lookAt(rootPos, rootPos + blended)
	hrp.CFrame = newCF
end)
