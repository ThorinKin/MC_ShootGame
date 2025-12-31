-- StarterPlayer/StarterPlayerScripts/Client/View/ViewModeController.client.lua
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("PlayerViewState"))
-- 1226新：背包等 UI 打开时会挂 GameplayLocked，这里统一拦截切视角
local GameplayLock = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("DisableEnableLock"))

-- BindableEvent：给别的地方调，等价于按 V 
local viewControlFolder = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("View")
local toggleViewBE = viewControlFolder:WaitForChild("ToggleViewMode")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- 视角模式属性
local ViewMode = {
	FirstPerson = "FirstPerson",
	ThirdPerson = "ThirdPerson",
}

-----------------------------可调参数-----------------------------
-- 默认第一人称
local currentMode = ViewMode.FirstPerson
-- 第三人称参数
local THIRD_PERSON_DEFAULT_DIST = 6   -- 默认第三人称距离
local THIRD_PERSON_MIN_DIST = 6       -- 最靠近的第三人称距离
local THIRD_PERSON_MAX_DIST = 18      -- 最远的第三人称距离
local THIRD_PERSON_HEIGHT_OFFSET = 2  -- 相机比 HRP 高一点
local TRANSITION_TIME = 0.25          -- 切换时长
-----------------------------可调参数-----------------------------

local isTransitioning = false
local activeTweenValue: NumberValue? = nil

-- 工具：全局锁时不允许切视角
local function isViewToggleLockedNow(): boolean
	local char = player.Character
	return char ~= nil and GameplayLock.isLocked(char)
end

-- 工具：给角色挂 Attribute，调试/别的系统用
local function syncCharacterViewState(mode: string)
	local character = player.Character
	if not character then return end
	-- 基础视角标记
	character:SetAttribute("ViewMode", mode)
	-- 读取当前是否持枪 由 BlasterController 写
	local weaponEquipped = character:GetAttribute("WeaponEquipped") == true
	-- 计算并更新组合状态
	local combatState = PlayerViewState.computeCombatState(mode, weaponEquipped)
	character:SetAttribute("CombatState", combatState)
end

-- 第一人称：Classic + 距离锁死为 0
local function applyFirstPerson()
	if not camera then
		camera = workspace.CurrentCamera
		if not camera then return end
	end
	-- 统一用 Classic
	player.CameraMode = Enum.CameraMode.Classic
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	-- 锁死在 0 距离 即 第一人称
	player.CameraMinZoomDistance = 0
	player.CameraMaxZoomDistance = 0
    syncCharacterViewState(ViewMode.FirstPerson)
end

-- 第三人称：Classic + 先锁距再放开范围
local function applyThirdPerson()
	if not camera then
		camera = workspace.CurrentCamera
		if not camera then return end
	end
	player.CameraMode = Enum.CameraMode.Classic
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	UIS.MouseIconEnabled = true
	-- 先把距离拍配置指定的位置
	local desired = math.clamp(
		THIRD_PERSON_DEFAULT_DIST,
		THIRD_PERSON_MIN_DIST,
		THIRD_PERSON_MAX_DIST
	)
	-- 把 Min/Max 先都锁到指定位置，一帧后再放开区间
	player.CameraMinZoomDistance = desired
	player.CameraMaxZoomDistance = desired
	task.defer(function()
		-- 一帧之后，给玩家一定滚轮范围，但最近也只能到 MIN，滚不回第一人称
		player.CameraMinZoomDistance = THIRD_PERSON_MIN_DIST
		player.CameraMaxZoomDistance = THIRD_PERSON_MAX_DIST
	end)
	syncCharacterViewState(ViewMode.ThirdPerson)
end

-- 通用工具：把相机从当前 CFrame tween 到目标 CFrame
local function tweenCameraTo(targetCFrame: CFrame, onComplete: () -> ())
	if not camera then
		camera = workspace.CurrentCamera
		if not camera then return end
	end
	-- 打断之前的 tween
	if activeTweenValue then
		activeTweenValue:Destroy()
		activeTweenValue = nil
	end
	isTransitioning = true
	camera.CameraType = Enum.CameraType.Scriptable
	local startCFrame = camera.CFrame
	local value = Instance.new("NumberValue")
	value.Value = 0
	activeTweenValue = value
	local tween = TweenService:Create(
		value,
		TweenInfo.new(TRANSITION_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ Value = 1 }
	)
	value:GetPropertyChangedSignal("Value"):Connect(function()
		local alpha = value.Value
		camera.CFrame = startCFrame:Lerp(targetCFrame, alpha)
	end)
	tween.Completed:Connect(function()
		if activeTweenValue == value then
			activeTweenValue = nil
		end
		value:Destroy()
		isTransitioning = false
		onComplete()
	end)
	tween:Play()
end

-- 三 → 一：推近到头
local function smoothToFirstPerson()
	local character = player.Character
	if not character then return end
	local head = character:FindFirstChild("Head")
	if not head then return end
	local targetCF = head.CFrame
	tweenCameraTo(targetCF, function()
		currentMode = ViewMode.FirstPerson
		applyFirstPerson()
	end)
end

-- 一 → 三：拉远到角色后方
local function smoothToThirdPerson()
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Head")
	if not hrp then return end
	-- 在角色后方 DEFAULT_DIST，略高一点
	local targetCF = hrp.CFrame * CFrame.new(0, THIRD_PERSON_HEIGHT_OFFSET, THIRD_PERSON_DEFAULT_DIST)
	tweenCameraTo(targetCF, function()
		currentMode = ViewMode.ThirdPerson
		applyThirdPerson()
	end)
end

-- 工具：核心切换
local function setViewMode(mode: string)
	-- 1226新：背包打开等 UI 锁期间禁止切视角
	if isViewToggleLockedNow() then
		return
	end
	if mode == currentMode then return end
	if isTransitioning then return end
	if mode == ViewMode.FirstPerson then
		smoothToFirstPerson()
	else
		smoothToThirdPerson()
	end
end
local function toggleViewMode()
	if isTransitioning then return end
	if currentMode == ViewMode.FirstPerson then
		setViewMode(ViewMode.ThirdPerson)
	else
		setViewMode(ViewMode.FirstPerson)
	end
end

-- 工具：角色初始化加载时直接应用当前模式（不 tween）
local function onCharacterAdded(_character: Model)
	RunService.Heartbeat:Wait()
	if currentMode == ViewMode.FirstPerson then
		applyFirstPerson()
	else
		applyThirdPerson()
	end
end

-- 外部触发切视角：等价于按 V
toggleViewBE.Event:Connect(function()
	toggleViewMode()
end)

-- 玩家加入监听
player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

-- 按键绑定：键盘 V 切换监听
UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.V then
		toggleViewMode()
	end
end)
-- UI 按钮：StarterGui/TestGui/TestFrame/ViewButton
local function hookViewButtonIn(playerGui: PlayerGui)
	-- 如果已经有 TestGui 了，直接绑
	local testGui = playerGui:FindFirstChild("TestGui")
	if testGui then
		local frame = testGui:FindFirstChild("TestFrame")
		if frame then
			local button = frame:FindFirstChild("ViewButton")
			if button and (button:IsA("TextButton") or button:IsA("ImageButton")) then
				button.MouseButton1Click:Connect(function()
					toggleViewMode()
				end)
			end
		end
	end
	-- 监听后续 TestGui / ViewButton 的创建（比如 Reset 后重新 clone）
	playerGui.DescendantAdded:Connect(function(desc)
		if (desc.Name == "ViewButton")
			and (desc:IsA("TextButton") or desc:IsA("ImageButton")) then
			desc.MouseButton1Click:Connect(function()
				toggleViewMode()
			end)
		end
	end)
end
local function initGuiHook()
	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		hookViewButtonIn(playerGui)
	end
end
player.ChildAdded:Connect(function(child)
	if child:IsA("PlayerGui") then
		task.defer(function()
			hookViewButtonIn(child)
		end)
	end
end)
initGuiHook()
