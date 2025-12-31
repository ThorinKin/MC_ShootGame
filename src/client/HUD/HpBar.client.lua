-- StarterPlayer/StarterPlayerScripts/Client/HUD/HpBar.client.lua
-- 总注释：关闭 CoreGui 自带血条 UI + 受伤/低血量指示（HUD/HUD_Mobile 下 Injured 的 ImageLabel）
local Players      = game:GetService("Players")
local StarterGui   = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

---------------------可调参数----------------------
-- 低血阈值：<= 20% 进入循环闪烁
local LOW_HP_RATIO = 0.20
-- 挨打闪一下（0 -> 1）
local HIT_FADE_IN_TIME  = 0.06
local HIT_FADE_OUT_TIME = 0.18
-- 低血循环闪（0 <-> 1）
local LOW_FADE_IN_TIME  = 0.40
local LOW_FADE_OUT_TIME = 0.60
local LOW_GAP_TIME      = 0.10
--------------------------------------------------

-- 关闭 CoreGui 自带血条（太早调用会报错/不生效，用 pcall 重试）
repeat
	local ok = pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
	task.wait()
until ok

-- 寻找 HUD / HUD_Mobile 下 Injured 的 ImageLabel（两套一起处理）
local HUD_PC_NAME = "HUD"
local HUD_MOBILE_NAME = "HUD_Mobile"
local function findInjuredImage(screenGui: ScreenGui?): ImageLabel?
	if not screenGui then return nil end
	local injured = screenGui:FindFirstChild("Injured", true)
	if not injured then return nil end
	-- Injured 下带一个 ImageLabel（按你说的结构来找）
	local img = injured:FindFirstChildWhichIsA("ImageLabel", true)
	return img
end
local function getAllTargets(): {ImageLabel}
	local targets = {}

	local hudPC = playerGui:FindFirstChild(HUD_PC_NAME) :: ScreenGui?
	local hudMobile = playerGui:FindFirstChild(HUD_MOBILE_NAME) :: ScreenGui?

	local img1 = findInjuredImage(hudPC)
	local img2 = findInjuredImage(hudMobile)

	if img1 then table.insert(targets, img1) end
	if img2 and img2 ~= img1 then table.insert(targets, img2) end

	return targets
end

-- Tween 管理：避免多段 tween 互相打架
local activeTweens = {} :: {[Instance]: Tween}
local function cancelTween(inst: Instance)
	local tw = activeTweens[inst]
	if tw then
		pcall(function() tw:Cancel() end)
		activeTweens[inst] = nil
	end
end
local function tweenTransparency(img: ImageLabel, toValue: number, timeSec: number)
	cancelTween(img)
	local tw = TweenService:Create(
		img,
		TweenInfo.new(timeSec, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ ImageTransparency = toValue }
	)
	activeTweens[img] = tw
	tw:Play()
	return tw
end
local function setTransparencyInstant(img: ImageLabel, v: number)
	cancelTween(img)
	img.ImageTransparency = v
end

-- 挨打闪一下：tween 到 0 再回 1
local hitFlashNonce = 0
local function playHitFlash()
	hitFlashNonce += 1
	local myNonce = hitFlashNonce

	local targets = getAllTargets()
	if #targets == 0 then return end

	-- 先到 0
	for _, img in ipairs(targets) do
		tweenTransparency(img, 0, HIT_FADE_IN_TIME)
	end

	task.delay(HIT_FADE_IN_TIME, function()
		if myNonce ~= hitFlashNonce then return end
		-- 再回 1
		for _, img in ipairs(getAllTargets()) do
			tweenTransparency(img, 1, HIT_FADE_OUT_TIME)
		end
	end)
end

-- 低血循环闪：持续 0 <-> 1
local lowLoopNonce = 0
local lowLoopRunning = false
local function stopLowLoop()
	if not lowLoopRunning then return end
	lowLoopRunning = false
	lowLoopNonce += 1

	-- 停止后回到“透明”(1)
	for _, img in ipairs(getAllTargets()) do
		tweenTransparency(img, 1, 0.15)
	end
end
local function startLowLoop()
	if lowLoopRunning then return end
	lowLoopRunning = true
	lowLoopNonce += 1
	local myNonce = lowLoopNonce
	task.spawn(function()
		while lowLoopRunning and myNonce == lowLoopNonce do
			-- 到 0
			for _, img in ipairs(getAllTargets()) do
				tweenTransparency(img, 0, LOW_FADE_IN_TIME)
			end
			task.wait(LOW_FADE_IN_TIME + LOW_GAP_TIME)
			if not lowLoopRunning or myNonce ~= lowLoopNonce then break end

			-- 回 1
			for _, img in ipairs(getAllTargets()) do
				tweenTransparency(img, 1, LOW_FADE_OUT_TIME)
			end
			task.wait(LOW_FADE_OUT_TIME + LOW_GAP_TIME)
		end
	end)
end

-- 绑定 Humanoid：掉血触发闪一下；低血触发循环
local function bindCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	end
	if not humanoid then return end
	-- 初始化：确保 UI 默认透明
	for _, img in ipairs(getAllTargets()) do
		-- 默认透明是 1，这里再兜一层
		setTransparencyInstant(img, 1)
	end
	local lastHp = humanoid.Health
	local function updateLowHp(hp: number)
		local maxHp = math.max(humanoid.MaxHealth, 1)
		local ratio = hp / maxHp
		if ratio <= LOW_HP_RATIO then
			startLowLoop()
		else
			stopLowLoop()
		end
	end
	updateLowHp(lastHp)
	humanoid.HealthChanged:Connect(function(newHp)
		-- 掉血（挨打）判定
		if newHp < lastHp then
			playHitFlash()
		end
		lastHp = newHp
		updateLowHp(newHp)
	end)

	humanoid.Died:Connect(function()
		stopLowLoop()
	end)
end

-- 首次 & 重生
if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(function(char)
	-- 稍微等一下，确保 HUD / Humanoid 都加载好
	task.wait(0.1)
	bindCharacter(char)
end)

-- HUD 可能晚于脚本加载：监听一下 PlayerGui 变化，保证能抓到目标
playerGui.ChildAdded:Connect(function(child)
	if child:IsA("ScreenGui") and (child.Name == HUD_PC_NAME or child.Name == HUD_MOBILE_NAME) then
		for _, img in ipairs(getAllTargets()) do
			-- 新 HUD 进来时，默认回到透明
			setTransparencyInstant(img, 1)
		end
	end
end)
