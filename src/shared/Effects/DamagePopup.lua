-- ReplicatedStorage/Shared/Effects/DamagePopup.lua
--!nocheck
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local DamagePopup = {}

-- 美术资产
local assets = ReplicatedStorage:WaitForChild("Assets")
local effectsFolder = assets:WaitForChild("Effects")
local popupTemplate = effectsFolder:WaitForChild("DamagePopUp") :: BasePart

-- 可调参数：
local BASE_HEIGHT_OFFSET = 1.2     -- 再往上抬多少 studs
local RANDOM_OFFSET_XZ   = 2.1     -- 平面随机偏移范围（越大越分散）
local FLOAT_UP_DISTANCE  = 2.1     -- 往上飘多高
local POPUP_DURATION     = 1.5     -- tween 时长
local POPUP_LIFETIME     = 1.9     -- 总存在时间，比 POPUP_DURATION 大点

-- 尺寸相关参数：
local BASE_SCALE         = 1.0     -- 基础缩放
local POP_SCALE_MULT     = 1.5     -- 放大跳字的放大比例

-- 距离缩放参数（远处太小）
local FAR_DIST_MIN       = 30      -- 超过这个距离开始放大
local FAR_DIST_MAX       = 150     -- 超过这个就按最大倍率算
local FAR_SCALE_MAX      = 3.0     -- 最远时的额外缩放倍率（和 BASE_SCALE 相乘）

-- 工具：寻找一个适合拿位置的部件（优先 Head / 上半身，再 HRP）
local function getRootPart(humanoid: Humanoid): BasePart?
	local model = humanoid.Parent
	if not model or not model:IsA("Model") then
		return nil
	end

	local root =
		model:FindFirstChild("Head")
		or model:FindFirstChild("UpperTorso")
		or model:FindFirstChild("Torso")
		or humanoid.RootPart
		or model:FindFirstChild("HumanoidRootPart")

	if root and root:IsA("BasePart") then
		return root
	end

	return nil
end

-- 工具：给某个 humanoid 播一次跳字
-- 入参：amount: 伤害（正数），isHeal: 是否是治疗
function DamagePopup.show(humanoid: Humanoid, amount: number, isHeal: boolean?)
	if not humanoid then
		return
	end

	local root = getRootPart(humanoid)
	if not root then
		return
	end

	amount = math.floor(math.abs(amount) + 0.5)
	if amount <= 0 then
		return
	end

	-- 克隆一个独立的特效 Part，挂在 Workspace，不再挂在敌人身上
	local popupPart = popupTemplate:Clone()
	popupPart.Anchored = true
	popupPart.CanCollide = false
	popupPart.CanQuery = false
	popupPart.CanTouch = false
	popupPart.CastShadow = false
	popupPart.Parent = Workspace

	-- 基础位置：以 root 为基准 + 往上抬一点
	local basePos = root.Position + Vector3.new(0, BASE_HEIGHT_OFFSET, 0)

	-- 平面随机偏移，避免多次伤害叠在同一点
	local offsetX = (math.random() - 0.5) * 2 * RANDOM_OFFSET_XZ
	local offsetZ = (math.random() - 0.5) * 2 * RANDOM_OFFSET_XZ
	local startPos = basePos + Vector3.new(offsetX, 0, offsetZ)
	popupPart.Position = startPos

	-- 找到挂在 Part 下面的 Attachment / BillboardGui / TextLabel
	local att = popupPart:FindFirstChild("DamageTextAtt", true)
	if not att or not att:IsA("Attachment") then
		popupPart:Destroy()
		return
	end

	local gui = att:FindFirstChild("DamageTextBGui")
	if not gui or not gui:IsA("BillboardGui") then
		popupPart:Destroy()
		return
	end

	local label = gui:FindFirstChild("DamageText")
	if not label or not label:IsA("TextLabel") then
		popupPart:Destroy()
		return
	end

	label.Text = tostring(amount)

	-- 颜色：预留 --
	-- if isHeal then
	-- 	label.TextColor3 = Color3.fromRGB(80, 255, 80)
	-- else
	-- 	label.TextColor3 = Color3.fromRGB(255, 80, 80)
	-- end

	label.TextTransparency = 0
	label.TextStrokeTransparency = 0

	-- 尺寸缩放逻辑↓
	-- 确保有 UIScale，没预放就补一个，我放了
	local uiScale = label:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Scale = 1
		uiScale.Parent = label
	end

	-- 基于摄像机距离的缩放，远处的字放大一点
	local distanceFactor = 1
	local cam = Workspace.CurrentCamera
	if cam then
		local dist = (cam.CFrame.Position - root.Position).Magnitude
		if dist > FAR_DIST_MIN then
			local t = math.clamp((dist - FAR_DIST_MIN) / (FAR_DIST_MAX - FAR_DIST_MIN), 0, 1)
			-- 线性插值 [1, FAR_SCALE_MAX]
			distanceFactor = 1 + t * (FAR_SCALE_MAX - 1)
		end
	end

	local targetScale = BASE_SCALE * distanceFactor

	-- 初始：比目标略大一点，配合 Back 缓动
	uiScale.Scale = targetScale * POP_SCALE_MULT
	-- 尺寸缩放逻辑结束↑

	-- 往上轻轻飘一下 + 渐隐
	local tweenInfo = TweenInfo.new(POPUP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local endPos = startPos + Vector3.new(0, FLOAT_UP_DISTANCE, 0)

	local posTween = TweenService:Create(popupPart, tweenInfo, {
		Position = endPos,
	})
	local textTween = TweenService:Create(label, tweenInfo, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})

	-- 尺寸 tween：从略大 → 正常
	local scaleTweenInfo = TweenInfo.new(POPUP_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local scaleTween = TweenService:Create(uiScale, scaleTweenInfo, {
		Scale = targetScale,
	})

	posTween:Play()
	textTween:Play()
	scaleTween:Play()

	task.delay(POPUP_LIFETIME, function()
		if popupPart.Parent then
			popupPart:Destroy()
		end
	end)
end

return DamagePopup
