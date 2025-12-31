-- StarterPlayer/StarterPlayerScripts/Client/HUD/HudUI.client.lua
-- 总注释：HUD 显示：金币 / 等级与经验条 / 血条（本地只读显示）
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AbbNumber = require(ReplicatedStorage.Shared.Utility.AbbNumber)
local HudRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("HudRegistry"))

local localPlayer = Players.LocalPlayer
-- 当前活跃 HUD 渲染移动端或PC端 UI
local hudGui = HudRegistry.wait()

-- HUD：金币显示
local coinText = hudGui:WaitForChild("Left"):WaitForChild("Menu"):WaitForChild("Coin"):WaitForChild("BG"):WaitForChild("TextLabel")
-- Players 服务：leaderstats/Cash
local leaderstats = localPlayer:WaitForChild("leaderstats")
local cashValue   = leaderstats:WaitForChild("Cash")

-- 工具：刷新金币显示
local function refreshCoinText()
	local amount = tonumber(cashValue.Value) or 0
	coinText.Text = AbbNumber.AbbreviateNumber(amount, 1)
end

-- HUD：等级 / 经验条（StatusBar）
local statusRoot = hudGui:WaitForChild("Bottom"):WaitForChild("StatusBar")
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
local hpBar = healthFrame:WaitForChild("HpBar")
local hpGrad = hpBar:WaitForChild("UIGradient") :: UIGradient -- 改用渐变
local hpNum1 = healthFrame:WaitForChild("Num1")
local hpNum2 = healthFrame:WaitForChild("Num2")
local humanoidConn1, humanoidConn2
local currentHumanoid
local function disconnectHumanoid()
	if humanoidConn1 then humanoidConn1:Disconnect() humanoidConn1 = nil end
	if humanoidConn2 then humanoidConn2:Disconnect() humanoidConn2 = nil end
	currentHumanoid = nil
end
-- 工具：用 UIGradient 的 Transparency 做血量遮罩 pct=0 => 全空；pct=1 => 全满
local function setHpPercent(pct: number)
	pct = math.clamp(tonumber(pct) or 0, 0, 1)
	hpGrad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0,   0), -- 左侧不透明
		NumberSequenceKeypoint.new(pct, 0), -- 到 pct 之前都不透明
		NumberSequenceKeypoint.new(pct, 1), -- 从 pct 开始直接透明
		NumberSequenceKeypoint.new(1,   1), -- 右侧透明
	})
end
local function refreshHealthUI()
	if not currentHumanoid then
		hpNum1.Text = "0"
		hpNum2.Text = "0"
		setHpPercent(0) -- 以前是改 Size，现在改渐变
		return
	end
	local hp  = tonumber(currentHumanoid.Health) or 0
	local max = tonumber(currentHumanoid.MaxHealth) or 0
	if max < 0 then max = 0 end
	if hp < 0 then hp = 0 end

	hpNum1.Text = tostring(math.floor(hp + 0.5))
	hpNum2.Text = tostring(math.floor(max + 0.5))

	local pct = 0
	if max > 0 then
		pct = math.clamp(hp / max, 0, 1)
	end
	setHpPercent(pct) -- 不动 hpBar.Size
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

local rewardRoot = hudGui:WaitForChild("RewardEffect")
local templates  = rewardRoot:WaitForChild("Templates")

local tplCoin = templates:WaitForChild("PlusCoin") :: TextLabel
local tplExp  = templates:WaitForChild("PlusExp")  :: TextLabel
local tplItem = templates:FindFirstChild("PlusItem") :: TextLabel?

tplCoin.Visible = false
tplExp.Visible  = false
if tplItem then tplItem.Visible = false end

local soundFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Sound")
local coinSoundT  = soundFolder:WaitForChild("Coin") :: Sound
local expSoundT   = soundFolder:WaitForChild("Exp")  :: Sound

-- BindableEvent：掉落物UI效果同步，防止加载顺序导致nil
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

local function playSound(template: Sound)
	local s = template:Clone()
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 5)
end

-- clone 模板 -> parent -> delay 淡出 -> debris
local layoutSeq = 0
local function spawnReward(kind: string, amount: number)
	local tpl: TextLabel? = nil
	local soundT: Sound? = nil

	if kind == "coin" then
		tpl = tplCoin
		soundT = coinSoundT
	elseif kind == "exp" then
		tpl = tplExp
		soundT = expSoundT
	elseif kind == "item" then
		tpl = tplItem
	end

	if not tpl then return end

	local label = tpl:Clone()
	label.Visible = true
	label.Parent = rewardRoot

	-- 让 UIListLayout 排序更稳定
	layoutSeq += 1
	label.LayoutOrder = layoutSeq

	-- 重置透明度
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0

	-- 文案
	if kind == "coin" then
		label.Text = "+ " .. AbbNumber.AbbreviateNumber(amount, 1) .. " Coins"
	elseif kind == "exp" then
		label.Text = "+ " .. AbbNumber.AbbreviateNumber(amount, 1) .. " Exp"
	else
		label.Text = "+ " .. tostring(amount)
	end

	-- 音效
	if soundT then
		playSound(soundT)
	end

	-- 延迟淡出
	task.delay(2, function()
		if label and label.Parent then
			TweenService:Create(label, TweenInfo.new(1), {
				TextTransparency = 1,
				TextStrokeTransparency = 1
			}):Play()
		end
	end)

	Debris:AddItem(label, 3)
end

-- 监听：掉落拾取触发（来自 EnemyDropClient）
(rewardBE :: BindableEvent).Event:Connect(function(kind: string, amount: number)
	if typeof(kind) ~= "string" then return end
	amount = tonumber(amount) or 0
	if amount <= 0 then return end

	spawnReward(kind, amount)
end)
