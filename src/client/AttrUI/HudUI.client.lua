-- StarterPlayer/StarterPlayerScripts/Client/AttrUI/HudUI.client.lua
-- 总注释：HUD 显示：金币 / 等级与经验条 / 血条（本地只读显示）
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local AbbNumber = require(ReplicatedStorage.Shared.Utility.AbbNumber)

-- HUD：金币显示
local coinText = playerGui:WaitForChild("HUD"):WaitForChild("Left"):WaitForChild("Menu"):WaitForChild("Coin"):WaitForChild("BG"):WaitForChild("TextLabel")
-- Players 服务：leaderstats/Cash
local leaderstats = localPlayer:WaitForChild("leaderstats")
local cashValue   = leaderstats:WaitForChild("Cash")

-- 工具：刷新金币显示
local function refreshCoinText()
	local amount = tonumber(cashValue.Value) or 0
	coinText.Text = AbbNumber.AbbreviateNumber(amount, 1)
end

-- HUD：等级 / 经验条（StatusBar）
local statusRoot = playerGui:WaitForChild("HUD"):WaitForChild("Bottom"):WaitForChild("StatusBar")
local levelFrame = statusRoot:WaitForChild("Level")
local expBar     = levelFrame:WaitForChild("ExpBar")
local levelText  = levelFrame:WaitForChild("TextLabel")

-- Players 服务：Exp 文件夹（只读）
local expFolder     = localPlayer:WaitForChild("Exp")
local expLevelVal   = expFolder:WaitForChild("Level")
local expXpInLevel  = expFolder:WaitForChild("XpInLevel")

-- 和服务端 ExpModule 保持一致的升级需求公式（客户端只用于显示进度条）
local function expRequiredForLevel(level)
	level = math.max(1, math.floor(tonumber(level) or 1))
	local need = 200 * (level ^ 1.6) + 500
	return math.floor(need)
end

-- 工具：刷新等级文本 + 经验条
local function refreshLevelExpUI()
	local lvl = tonumber(expLevelVal.Value) or 1
	local xil = tonumber(expXpInLevel.Value) or 0

	levelText.Text = "lv" .. tostring(lvl)

	local need = expRequiredForLevel(lvl)
	local pct = 0
	if need > 0 then
		pct = math.clamp(xil / need, 0, 1)
	end

	-- 经验条：0~0.95 代表 0%~100%
	local s = expBar.Size
	expBar.Size = UDim2.new(0.95 * pct, s.X.Offset, s.Y.Scale, s.Y.Offset)
end

-- HUD：血条（StatusBar）
local healthFrame = statusRoot:WaitForChild("Player"):WaitForChild("Health")
local hpBar = healthFrame:WaitForChild("HpBar") -- Size.X.Scale: 0~0.7 = 0%~100%
local hpNum1 = healthFrame:WaitForChild("Num1") -- 当前血量
local hpNum2 = healthFrame:WaitForChild("Num2") -- 血上限
local humanoidConn1, humanoidConn2
local currentHumanoid

local function disconnectHumanoid()
	if humanoidConn1 then humanoidConn1:Disconnect() humanoidConn1 = nil end
	if humanoidConn2 then humanoidConn2:Disconnect() humanoidConn2 = nil end
	currentHumanoid = nil
end

local function refreshHealthUI()
	if not currentHumanoid then
		-- 没 Humanoid 的时候别瞎显示
		hpNum1.Text = "0"
		hpNum2.Text = "0"
		local s = hpBar.Size
		hpBar.Size = UDim2.new(0, s.X.Offset, s.Y.Scale, s.Y.Offset)
		return
	end

	local hp  = tonumber(currentHumanoid.Health) or 0
	local max = tonumber(currentHumanoid.MaxHealth) or 0
	if max < 0 then max = 0 end
	if hp < 0 then hp = 0 end

	-- 数字显示
	hpNum1.Text = tostring(math.floor(hp + 0.5))
	hpNum2.Text = tostring(math.floor(max + 0.5))

	-- 血条：0~0.7 代表 0%~100%
	local pct = 0
	if max > 0 then
		pct = math.clamp(hp / max, 0, 1)
	end
	local s = hpBar.Size
	hpBar.Size = UDim2.new(0.7 * pct, s.X.Offset, s.Y.Scale, s.Y.Offset)
end

local function bindHumanoidFromCharacter(char)
	disconnectHumanoid()

	if not char then
		refreshHealthUI()
		return
	end

	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	if not hum then
		refreshHealthUI()
		return
	end

	currentHumanoid = hum

	-- 监听血量变化 + 血上限变化
	humanoidConn1 = hum.HealthChanged:Connect(function()
		refreshHealthUI()
	end)
	humanoidConn2 = hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		refreshHealthUI()
	end)

	refreshHealthUI()
end

-- 初始刷新一帧 + 监听
refreshCoinText()
refreshLevelExpUI()
bindHumanoidFromCharacter(localPlayer.Character)

cashValue.Changed:Connect(refreshCoinText)

expLevelVal.Changed:Connect(refreshLevelExpUI)
expXpInLevel.Changed:Connect(refreshLevelExpUI)

localPlayer.CharacterAdded:Connect(function(char)
	bindHumanoidFromCharacter(char)
end)
localPlayer.CharacterRemoving:Connect(function()
	disconnectHumanoid()
	refreshHealthUI()
end)

-- HUD：RewardEffect（金币/经验飘字 + 音效，客户端本地表现）
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Debris       = game:GetService("Debris")

local rewardRoot = playerGui:WaitForChild("HUD"):WaitForChild("RewardEffect")
local plusCoin   = rewardRoot:WaitForChild("PlusCoin")
local plusExp    = rewardRoot:WaitForChild("PlusExp")
local plusItem   = rewardRoot:WaitForChild("PlusItem") -- 预留

plusCoin.Visible = false
plusExp.Visible  = false
plusItem.Visible = false

local soundFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Sound")
local coinSoundT  = soundFolder:WaitForChild("Coin")
local expSoundT   = soundFolder:WaitForChild("Exp")

-- BindbleEvent：掉落物UI效果同步，防止加载顺序导致nil
local clientSignals = ReplicatedStorage:FindFirstChild("ClientSignals")
if not clientSignals then
	clientSignals = Instance.new("Folder")
	clientSignals.Name = "ClientSignals"
	clientSignals.Parent = ReplicatedStorage
end
local rewardBE = clientSignals:FindFirstChild("RewardEffect")
if not rewardBE then
	rewardBE = Instance.new("BindableEvent")
	rewardBE.Name = "RewardEffect"
	rewardBE.Parent = clientSignals
end

-- 小型合并：短时间内不断拾取，只显示一个飘字但数值累加
local uiAcc = {
	coin = 0,
	exp  = 0,
	item = 0,
}
local uiSeq = { coin = 0, exp = 0, item = 0 }

local startPos = {
	coin = plusCoin.Position,
	exp  = plusExp.Position,
	item = plusItem.Position,
}

local activeTween = { coin = nil, exp = nil, item = nil }

local function playSound(template: Sound)
	local s = template:Clone()
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 5)
end

local function kickLabel(kind: string, label: TextLabel, amount: number, soundT: Sound?)
	uiSeq[kind] += 1
	local seq = uiSeq[kind]

	-- 重置 & 显示
	label.Visible = true
	label.Position = startPos[kind]
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0

	-- 文字
	if kind == "coin" then
		label.Text = "+ " .. AbbNumber.AbbreviateNumber(amount, 1) .. "Coins"
	elseif kind == "exp" then
		label.Text = "+ " .. AbbNumber.AbbreviateNumber(amount, 1) .. "Exp"
	else
		label.Text = "+ " .. tostring(amount)
	end

	-- 音效
	if soundT then
		playSound(soundT)
	end

	-- 取消上一个 tween
	local tw = activeTween[kind]
	if tw then
		tw:Cancel()
	end

	-- 平滑向上飘一点 + 淡出
	local goal = {
		Position = startPos[kind] - UDim2.new(0, 0, 0.03, 0),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	}
	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(label, info, goal)
	activeTween[kind] = tween
	tween:Play()

	tween.Completed:Connect(function()
		-- 若期间又触发了新的奖励，就别把它关了
		if uiSeq[kind] == seq then
			label.Visible = false
			uiAcc[kind] = 0
		end
	end)
end

-- 监听：掉落拾取触发（来自 EnemyDropClient）
(rewardBE :: BindableEvent).Event:Connect(function(kind: string, amount: number)
	if typeof(kind) ~= "string" then
		return
	end
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return
	end

	if kind == "coin" then
		uiAcc.coin += amount
		kickLabel("coin", plusCoin, uiAcc.coin, coinSoundT)
	elseif kind == "exp" then
		uiAcc.exp += amount
		kickLabel("exp", plusExp, uiAcc.exp, expSoundT)
	elseif kind == "item" then
		uiAcc.item += amount
		kickLabel("item", plusItem, uiAcc.item, nil)
	end
end)
