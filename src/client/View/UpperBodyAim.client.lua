--!nocheck
-- StarterPlayer/StarterPlayerScripts/Client/View/UpperBodyAim.client.lua
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerViewState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("PlayerViewState"))
local ThirdPersonShooter = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("ThirdPersonShooter"))

local localPlayer = Players.LocalPlayer

-- 上半身瞄准俯仰属性名（单位：度）
local AIM_PITCH_ATTR_NAME = "AimPitch"
-- 和过肩脚本保持一致： FreeAim 属性名
local FREE_AIM_ATTR_NAME = "FreeAim"
-- 角度限制参数：
local MAX_PITCH_UP   = 45   -- 往上最多 45°
local MAX_PITCH_DOWN = 45   -- 往下最多 45°
local PITCH_LERP_SPEED = 12 -- 平滑系数：越大越跟手

-- 记录每个角色上一次生效的 pitch（度）
local lastPitchDegByCharacter = {} :: { [Model]: number }

-- 工具：根据当前瞄准方式及 摄像机方向/看向方向 算出俯仰角（度）
local function getAimPitchDeg(character: Model): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return 0
	end

	local viewMode = character:GetAttribute("ViewMode")
	local freeAim  = character:GetAttribute(FREE_AIM_ATTR_NAME) == true

	-- 特例：第三人称 + FreeAim → 按鼠标射线落点算角度
	if viewMode == PlayerViewState.ViewMode.ThirdPerson and freeAim then
		local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso")
		if hrp then
			local origin = hrp.Position
			-- 复用 TPS 的鼠标射线函数，忽略自己角色
			local targetPos = ThirdPersonShooter.getMouseWorldTarget(cam, { character })

			local dir = targetPos - origin
			if dir.Magnitude > 0.1 then
				local horizMag = math.sqrt(dir.X * dir.X + dir.Z * dir.Z)
				if horizMag < 1e-4 then
					horizMag = 1e-4
				end

				local pitchRad = math.atan2(dir.Y, horizMag)
				local pitchDeg = math.deg(pitchRad)

				-- 限制一下范围
				if pitchDeg > MAX_PITCH_UP then
					pitchDeg = MAX_PITCH_UP
				elseif pitchDeg < -MAX_PITCH_DOWN then
					pitchDeg = -MAX_PITCH_DOWN
				end

				return pitchDeg
			end
		end
		-- 极端情况（没 HRP、dir 太短）就回退到摄像机角度
	end

	-- 默认：用摄像机 LookVector 算（FP + TPS 锁鼠标）
	local look = cam.CFrame.LookVector
	local horizMag = math.sqrt(look.X * look.X + look.Z * look.Z)
	if horizMag < 1e-4 then
		horizMag = 1e-4
	end

	local pitchRad = math.atan2(look.Y, horizMag)
	local pitchDeg = math.deg(pitchRad)

	if pitchDeg > MAX_PITCH_UP then
		pitchDeg = MAX_PITCH_UP
	elseif pitchDeg < -MAX_PITCH_DOWN then
		pitchDeg = -MAX_PITCH_DOWN
	end

	return pitchDeg
end

-- 每帧：更新「本地玩家」自己的 AimPitch 属性
local function updateLocalAimPitch(dt: number)
	local character = localPlayer.Character
	if not character then
		return
	end

	local state = character:GetAttribute("CombatState")
	-- 只在持枪状态下驱动上半身俯仰（FP / TP_Armed 都算）
	local isArmed = (
		state == PlayerViewState.CombatState.FP_Armed
		or state == PlayerViewState.CombatState.TP_Armed
	)

	-- 没持枪了就缓回 0°
	local targetPitchDeg = 0
	if isArmed then
		targetPitchDeg = getAimPitchDeg(character)
	end

	local last = lastPitchDegByCharacter[character] or 0
	local alpha = math.clamp(dt * PITCH_LERP_SPEED, 0, 1)
	local newPitch = last + (targetPitchDeg - last) * alpha
	lastPitchDegByCharacter[character] = newPitch

	-- 写回 Attribute，给别的客户端也用
	character:SetAttribute(AIM_PITCH_ATTR_NAME, newPitch)
end

--------------------------其他角色应用上半身俯仰：----------------------------------------------------
-- 一起缓存原始 C0，方便在其基础上叠加
local jointCache = {} :: {
	[Model]: {
		Neck: Motor6D,
		RightShoulder: Motor6D,
		LeftShoulder: Motor6D,
		NeckC0: CFrame,
		RightShoulderC0: CFrame,
		LeftShoulderC0: CFrame,
	}
}

-- 工具：拿到 R6 角色的脖子和双肩 Motor6D
local function getUpperBodyJoints(character: Model)
	local cached = jointCache[character]
	if cached then
		return cached
	end

	-- 保险：只处理 R6
	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum or hum.RigType ~= Enum.HumanoidRigType.R6 then
		return nil
	end

	-- R6 基本零件
	local torso = character:FindFirstChild("Torso")
	local head = character:FindFirstChild("Head")
	local rightArm = character:FindFirstChild("Right Arm")
	local leftArm = character:FindFirstChild("Left Arm")

	if not (torso and head and rightArm and leftArm) then
		return nil
	end

	local neck = torso:FindFirstChild("Neck")
	local rightShoulder = torso:FindFirstChild("Right Shoulder")
	local leftShoulder = torso:FindFirstChild("Left Shoulder")

	if not (neck and rightShoulder and leftShoulder) then
		return nil
	end
	if not (neck:IsA("Motor6D") and rightShoulder:IsA("Motor6D") and leftShoulder:IsA("Motor6D")) then
		return nil
	end

	local joints = {
		Neck = neck,
		RightShoulder = rightShoulder,
		LeftShoulder = leftShoulder,
		NeckC0 = neck.C0,
		RightShoulderC0 = rightShoulder.C0,
		LeftShoulderC0 = leftShoulder.C0,
	}
	jointCache[character] = joints
	return joints
end

-- 工具：根据 AimPitch 给一个角色套上上半身俯仰
local function applyAimPitchToCharacter(character: Model)
	local joints = getUpperBodyJoints(character)
	if not joints then
		return
	end

	local pitchDeg = character:GetAttribute(AIM_PITCH_ATTR_NAME)
	if typeof(pitchDeg) ~= "number" then
		pitchDeg = 0
	end

	local pitchRad = math.rad(pitchDeg)

	-- 微调参数：头少一点，手多一点，看起来更自然
	local neckAngle = pitchRad * 0.7    -- 70% 给脖子
	local armAngle  = pitchRad * 0.9    -- 90% 给手臂

	-- 在原始 C0 上叠加俯仰，而不是写 Transform
	local neckBase = joints.NeckC0
	local rsBase   = joints.RightShoulderC0
	local lsBase   = joints.LeftShoulderC0

	-- 头：绕 X 轴抬头/低头
	joints.Neck.C0 = neckBase * CFrame.Angles(-neckAngle, 0, 0)
	-- 手臂：R6 里肩关节本身已经在 Z 轴上转过 90° / -90°
    -- 当前 Idle 位置/旋转：Right Arm的坐标旋转分别是(-0.066, -0.148, -0.366)(-0.099, 12.263, 90.481)
    -- Left Arm的坐标和旋转分别是(-0.925, 0.148, -0.554)(1.708, -41.583, -87.425)
	--  右手C0.Orientation.Z：Z 正向是上，左手C0.Orientation.Z：Z 负向是上
	joints.RightShoulder.C0 = rsBase * CFrame.Angles(0, 0,  armAngle)
	joints.LeftShoulder.C0  = lsBase * CFrame.Angles(0, 0, -armAngle)
end

-- 角色销毁时顺便清一下缓存，防止 table 越堆越多
local function hookCharacterLifecycle(player: Player)
	player.CharacterRemoving:Connect(function(char)
		jointCache[char] = nil
		lastPitchDegByCharacter[char] = nil
	end)
end

for _, p in ipairs(Players:GetPlayers()) do
	hookCharacterLifecycle(p)
end
Players.PlayerAdded:Connect(hookCharacterLifecycle)

-- 核心循环：每帧写本地玩家的Attribute/对所有玩家角色应用上半身 Transform
RunService:BindToRenderStep(
	"UpperBodyAim",
	Enum.RenderPriority.Character.Value + 2, -- 比角色更新稍晚一点，跟动画叠加
	function(dt)
		updateLocalAimPitch(dt)

		for _, p in ipairs(Players:GetPlayers()) do
			local character = p.Character
			if character then
				applyAimPitchToCharacter(character)
			end
		end
	end
)
