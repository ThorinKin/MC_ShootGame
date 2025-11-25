-- StarterPlayer/StarterPlayerScripts/Client/ThirdPersonOverShoulder.client.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PlayerViewState"))

local localPlayer = Players.LocalPlayer

local character: Model? = nil
local currentCombatState: string? = nil

-- 过肩偏移参数（右肩为正，左肩为负，实际用 shoulderSide 控制方向）
local SHOULDER_RIGHT = 4   -- 向左右多少（studs）
local SHOULDER_UP    = 1.6   -- 向上多少
local SHOULDER_FWD   = 2     -- 向前后偏移

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

-- 输入模式识别
local InputMode = {
	MouseKeyboard = "MouseKeyboard",
	Touch         = "Touch",
	Gamepad       = "Gamepad",
}
local currentInputMode = InputMode.MouseKeyboard

-- 最近一次触摸的 X 坐标（屏幕坐标）
local lastTouchX: number? = nil
-- 最近一次右摇杆的 X 值（[-1,1]）
local lastStickX = 0

-- 输入模式 & 位置信息
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

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

local function onCharacterAdded(char: Model)
	character = char
	currentCombatState = char:GetAttribute("CombatState")

	char:GetAttributeChangedSignal("CombatState"):Connect(onCombatStateChanged)
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
		-- 切视角 tween 期间 CameraType 会设成 Scriptable，这时候不抢相机
		if cam.CameraType ~= Enum.CameraType.Custom then
			return
		end
		local char = character
		if not char then
			return
		end

        -- 只有第三人称持枪时开启过肩；开镜时偏移更贴，未开镜时略微偏一点
        local isTPArmed = (currentCombatState == PlayerViewState.CombatState.TP_Armed)
        local isAiming = (char:GetAttribute("IsAiming") == true)
        local targetAlpha
        if isTPArmed then
            -- 可微调参数：0.65 = 普通持枪时稍微偏一点，1 = 开镜时完全过肩
            targetAlpha = isAiming and 1 or 0.65
        else
            targetAlpha = 0
        end

		do -- 仅第三人称开镜时锁鼠标在屏幕中心
			-- 避免干扰第一人称和其它系统
			if isTPArmed then
				local shouldLock = isAiming
				local desiredBehavior = shouldLock and Enum.MouseBehavior.LockCenter or Enum.MouseBehavior.Default
				if UserInputService.MouseBehavior ~= desiredBehavior then
					UserInputService.MouseBehavior = desiredBehavior
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

		-- 决定「应该在左肩还是右肩」
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

		-- 应用偏移
		local baseCF = cam.CFrame
		local right = baseCF.RightVector
		local up = baseCF.UpVector
		local forward = baseCF.LookVector

		local offset =
			right   * (SHOULDER_RIGHT * offsetAlpha * shoulderSide)
			+ up    * (SHOULDER_UP    * offsetAlpha)
			+ forward * (SHOULDER_FWD * offsetAlpha)

		-- CFrame + Vector3 只改位置，不改朝向
		cam.CFrame = baseCF + offset
	end
)
