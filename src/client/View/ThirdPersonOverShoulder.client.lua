-- StarterPlayer/StarterPlayerScripts/Client/View/ThirdPersonOverShoulder.client.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("PlayerViewState"))

local localPlayer = Players.LocalPlayer

local character: Model? = nil
local currentCombatState: string? = nil
local currentViewMode: string? = nil -- 前 ViewMode
local FREE_AIM_ATTR_NAME = "FreeAim" -- 1129新：Ctrl 呼出鼠标的状态同步到角色 Attribute

-- 过肩偏移参数（studs）
local SHOULDER_RIGHT = 4.1   -- 向左右多少，右市政
local SHOULDER_UP    = 0.1   -- 向上多少
local SHOULDER_FWD   = 2     -- 向前后多少 前市政
local SHOULDER_RIGHT_AIM_MULT = 0.75   -- 开镜时角色往中间收点，越小越靠中
-- 进出过肩视角的平滑速度（0→1）
local LERP_SPEED       = 10
-- 左右肩之间平滑切换的速度
local SIDE_LERP_SPEED  = 10
-- 鼠标 / 触摸 屏幕中线死区，避免来回抖
local SWITCH_DEADZONE  = 350
-- 0 = 完全无偏移（居中）、1 = 完全过肩
local offsetAlpha = 0
-- 右肩 = 1，左肩 = -1，中间状态在 [-1,1] 之间平滑过渡
local shoulderSide = 1
-- 当前实际使用的横向偏移（用于平滑）
local currentShoulderRight = SHOULDER_RIGHT

-- 输入模式识别
local InputMode = {
	MouseKeyboard = "MouseKeyboard",
	Touch         = "Touch",
	Gamepad       = "Gamepad",
}
local currentInputMode = InputMode.MouseKeyboard

local useFreeAimTPS = false -- 第三人称瞄准模式：false 锁鼠标；true不锁
local isOverridingMouse = false -- 由本脚本是否在接管 MouseBehavior
-- 1129新：记录是不是UI模式接管了相机
local uiCameraOverrideActive = false
local previousCameraType: Enum.CameraType? = nil

-- 最近一次触摸的 X 坐标（屏幕坐标）
local lastTouchX: number? = nil
-- 最近一次右摇杆的 X 值（[-1,1]）
local lastStickX = 0

-- 输入模式 & 位置信息
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	-- Ctrl 切换第三人称 / 第一人称共用的 FreeAim 状态
	if input.KeyCode == Enum.KeyCode.LeftControl
		or input.KeyCode == Enum.KeyCode.RightControl
	then
		useFreeAimTPS = not useFreeAimTPS
		-- 同步给角色 Attribute，方便 Blaster / GUI 等其它系统识别
		if character then
			character:SetAttribute(FREE_AIM_ATTR_NAME, useFreeAimTPS)
		end
		-- 调试日志
		-- print("[TPS] FreeAim =", useFreeAimTPS)
		return
	end

	local t = input.UserInputType
	if t == Enum.UserInputType.MouseMovement
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseButton2
		or t == Enum.UserInputType.MouseButton3
	then
		currentInputMode = InputMode.MouseKeyboard

	elseif t == Enum.UserInputType.Touch then
		currentInputMode = InputMode.Touch
		lastTouchX = input.Position.X

	elseif t == Enum.UserInputType.Gamepad1 then
		currentInputMode = InputMode.Gamepad
	end
end)

UserInputService.InputChanged:Connect(function(input, _processed)
	local t = input.UserInputType

	if t == Enum.UserInputType.Touch then
		lastTouchX = input.Position.X

	elseif t == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick2 then
		-- 右摇杆 X 轴控制左右肩
		lastStickX = input.Position.X
	end
end)

-- CombatState 监听
local function onCombatStateChanged()
	if not character then
		return
	end
	currentCombatState = character:GetAttribute("CombatState")
end

-- ViewMode 监听：从任何 ThirdPerson → FirstPerson 时，自动关掉 FreeAim
local function onViewModeChanged()
	if not character then
		return
	end

	local newMode = character:GetAttribute("ViewMode")
	if newMode == currentViewMode then
		return
	end

	local oldMode = currentViewMode
	currentViewMode = newMode

	if oldMode == PlayerViewState.ViewMode.ThirdPerson
		and newMode == PlayerViewState.ViewMode.FirstPerson
	then
		-- 从任何第三人称状态切回第一人称：强制把 FreeAim 复位
		useFreeAimTPS = false
		character:SetAttribute(FREE_AIM_ATTR_NAME, false)

		-- 如果之前是 UI 接管了相机，这里也保险恢复一次
		local cam = Workspace.CurrentCamera
		if cam and uiCameraOverrideActive then
			cam.CameraType = Enum.CameraType.Custom
			uiCameraOverrideActive = false
			previousCameraType = nil
		end

		-- 调试日志
		-- print("[TPS] ViewMode ThirdPerson -> FirstPerson, FreeAim reset to false")
	end
end

local function onCharacterAdded(char: Model)
	character = char
	currentCombatState = char:GetAttribute("CombatState")
	currentViewMode = char:GetAttribute("ViewMode")
	-- 同步当前 FreeAim 状态 （大多数情况是 false）
	character:SetAttribute(FREE_AIM_ATTR_NAME, useFreeAimTPS)

	char:GetAttributeChangedSignal("CombatState"):Connect(onCombatStateChanged)
	char:GetAttributeChangedSignal("ViewMode"):Connect(onViewModeChanged)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

-- 每帧相机调整
RunService:BindToRenderStep(
	"TPS_OverShoulder",
	Enum.RenderPriority.Camera.Value + 1, -- 在默认相机之后，在视模之前
	function(dt)
		local cam = Workspace.CurrentCamera
		if not cam then
			return
		end
		local char = character
		if not char then
			return
		end

		-- 只有第三人称持枪时开启过肩；开镜时偏移更贴，未开镜时略微偏一点
		local isTPArmed = (currentCombatState == PlayerViewState.CombatState.TP_Armed)
		local isFPArmed = (currentCombatState == PlayerViewState.CombatState.FP_Armed)
		local isAiming = (char:GetAttribute("IsAiming") == true)

		-- 1129：第一人称 FreeAim = 纯 UI 模式，这里不再接管 CameraType，只靠 MouseBehavior 来防止视角旋转
		local inFirstPersonFreeAim = isFPArmed and useFreeAimTPS
		-- uiCameraOverrideActive / previousCameraType 保留变量，不再使用

		local targetAlpha
		if isTPArmed then
			-- 可微调参数：0.65 = 普通持枪时稍微偏一点，1 = 开镜时完全过肩
			targetAlpha = isAiming and 1 or 0.65
		else
			targetAlpha = 0
		end

		-- 第一 / 第三人称下的 MouseBehavior 统一控制
		do
			local desiredBehavior: Enum.MouseBehavior? = nil

			if isTPArmed then
				-- 第三人称持枪：原有逻辑
				local shouldLock
				if useFreeAimTPS then
					-- 自由鼠标模式：未开镜自由，开镜锁中心
					shouldLock = isAiming
				else
					-- 默认：全程锁中心
					shouldLock = true
				end

				desiredBehavior = shouldLock
					and Enum.MouseBehavior.LockCenter
					or Enum.MouseBehavior.Default

			elseif isFPArmed then
				-- 第一人称持枪
				if useFreeAimTPS then
					-- 第一人称 FreeAim：解锁鼠标（只用来点 UI），相机已交给 Scriptable 固定
					desiredBehavior = Enum.MouseBehavior.Default
				else
					-- 默认第一人称：锁中心
					desiredBehavior = Enum.MouseBehavior.LockCenter
				end
			end

			if desiredBehavior then
				if UserInputService.MouseBehavior ~= desiredBehavior then
					UserInputService.MouseBehavior = desiredBehavior
				end
				isOverridingMouse = true
			else
				-- 未持枪时，恢复默认一次，然后不再干预
				if isOverridingMouse then
					UserInputService.MouseBehavior = Enum.MouseBehavior.Default
					isOverridingMouse = false
				end
			end
		end

		-- 进/出过肩的平滑
		do
			local t = math.clamp(dt * LERP_SPEED, 0, 1)
			offsetAlpha = offsetAlpha + (targetAlpha - offsetAlpha) * t
		end

		-- 几乎是 0 就不写相机，省运算
		if offsetAlpha < 0.001 then
			return
		end

		-- 只有第三人称持枪 + CameraType.Custom 时才做过肩偏移（Tween / UI 模式都不抢相机）
		if not isTPArmed or cam.CameraType ~= Enum.CameraType.Custom then
			return
		end

		-- 决定 应该在左肩还是右肩
		local targetSide = shoulderSide
		if isTPArmed then
			local vpSize = cam.ViewportSize
			local halfX = vpSize.X * 0.5

			if currentInputMode == InputMode.MouseKeyboard then
				-- 鼠标 X 小于屏幕中线偏一点 → 左肩
				local mousePos = UserInputService:GetMouseLocation()
				local dx = mousePos.X - halfX
				if math.abs(dx) > SWITCH_DEADZONE then
					targetSide = (dx < 0) and -1 or 1
				end

			elseif currentInputMode == InputMode.Touch and lastTouchX then
				-- 最近一次触摸在左半屏 / 右半屏
				local dx = lastTouchX - halfX
				if math.abs(dx) > SWITCH_DEADZONE then
					targetSide = (dx < 0) and -1 or 1
				end

			elseif currentInputMode == InputMode.Gamepad then
				-- 右摇杆 X < 0 → 左肩，> 0 → 右肩
				if math.abs(lastStickX) > 0.15 then
					targetSide = (lastStickX < 0) and -1 or 1
				end
			end
		end
		-- 左右肩之间也做个平滑，不要瞬移
		do
			local t = math.clamp(dt * SIDE_LERP_SPEED, 0, 1)
			shoulderSide = shoulderSide + (targetSide - shoulderSide) * t
		end

		-- 平滑肩部左右偏移量
		local targetShoulderRight = SHOULDER_RIGHT
		if isAiming then
			targetShoulderRight = SHOULDER_RIGHT * SHOULDER_RIGHT_AIM_MULT
		end
		do
			local t = math.clamp(dt * SIDE_LERP_SPEED, 0, 1)
			currentShoulderRight = currentShoulderRight + (targetShoulderRight - currentShoulderRight) * t
		end

		-- 应用偏移
		local baseCF = cam.CFrame
		local right = baseCF.RightVector
		local up = baseCF.UpVector
		local forward = baseCF.LookVector

		local offset =
			right   * (currentShoulderRight * offsetAlpha * shoulderSide)
			+ up    * (SHOULDER_UP    * offsetAlpha)
			+ forward * (SHOULDER_FWD * offsetAlpha)

		-- CFrame + Vector3 只改位置，不改朝向
		cam.CFrame = baseCF + offset
	end
)
