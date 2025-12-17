-- StarterPlayer/StarterPlayerScripts/Client/Drops/EnemyDropClient.client.lua
-- 总注释：敌人掉落（客户端视觉）：Coin/Exp 爆出 + 吸附拾取 + 打包ACK（不用于发钱）
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local RunService        = game:GetService("RunService")

local localPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EnemyRewardDropRE = Remotes:WaitForChild("EnemyRewardDrop")

local Assets  = ReplicatedStorage:WaitForChild("Assets")
local Effects = Assets:WaitForChild("Effects")
local CoinFxTemplate = Effects:WaitForChild("Coin")
local ExpFxTemplate  = Effects:WaitForChild("Exp")

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

-----------------------------可调参数---------------------
local CFG = {
	VisualCapPerKind = 30,  -- 每种最多多少个球
	ScatterSpeedH    = 18,  -- 水平爆散速度
	ScatterSpeedVMin = 14,  -- 竖直最小速度
	ScatterSpeedVMax = 20,  -- 竖直最大速度

	MagnetRadius     = 14,  -- 多近开始吸附
	PickupRadius     = 1.6, -- 多近算拾取
	AttractSpeedBase = 30,  -- 吸附基础速度
	MaxLifeSeconds   = 12,  -- 掉落物最长存在时间（纯视觉）

    SpawnUpOffset    = 2.0,   -- 生成时向上抬一点
	MagnetDelay      = 0.20,  -- 出生后多久才开始吸附
	PickupDelay      = 0.35,  -- 出生后多久才允许拾取
}
---------------------------------------------------------

-- 掉落物根目录（仅本地）
local dropsFolder = Workspace:FindFirstChild("_ClientDrops")
if not dropsFolder then
	dropsFolder = Instance.new("Folder")
	dropsFolder.Name = "_ClientDrops"
	dropsFolder.Parent = Workspace
end
type Orb = {
	inst: Instance,
	root: BasePart,
	kind: string,  -- "coin" | "exp" | "item"
	value: number,
	token: string?,
	bornAt: number,
	attracting: boolean,
}
local orbs: { Orb } = {}

-- ACK：10秒一次批量上报（不真发钱）
local ackByToken: { [string]: { coin: number, exp: number } } = {}
local ackFlushTask = nil

local function getCharRoot(): BasePart?
	local char = localPlayer.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getRootPart(inst: Instance): BasePart?
	if inst:IsA("Model") then
		local pp = inst.PrimaryPart
		if pp then return pp end
		return inst:FindFirstChildWhichIsA("BasePart", true)
	end
	if inst:IsA("BasePart") then
		return inst
	end
	return nil
end

-- 出生阶段可碰撞防止穿地，不可 Touch/Query 省性能；吸附阶段关碰撞 + Anchor 手动移动
local function setDropPhysics(inst: Instance, collidable: boolean)
	if inst:IsA("BasePart") then
		inst.CanCollide = collidable
		inst.CanQuery   = false
		inst.CanTouch   = false
		inst.Massless   = true
		return
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = collidable
			d.CanQuery   = false
			d.CanTouch   = false
			d.Massless   = true
		end
	end
end

-- 工具：把 amount 拆成 count 份（尽量均匀）
local function splitAmount(amount: number, count: number): { number }
	amount = math.max(0, math.floor(amount + 0.5))
	count  = math.max(1, math.floor(count + 0.5))

	local arr = table.create(count, 0)
	if amount == 0 then
		return arr
	end

	local base = math.floor(amount / count)
	local rem  = amount - base * count
	for i = 1, count do
		arr[i] = base + (i <= rem and 1 or 0)
	end
	return arr
end

-- 工具：根据总量决定视觉球数量（上限 CFG.VisualCapPerKind）
local function calcVisualCount(amount: number): number
	amount = math.max(0, math.floor(amount + 0.5))
	if amount <= 0 then
		return 0
	end
	-- Minecraft 味道：数量随总量增长但有上限（sqrt 很稳）
	local c = math.ceil(math.sqrt(amount))
	return math.clamp(c, 1, CFG.VisualCapPerKind)
end

local function spawnOrb(template: Instance, pos: Vector3, kind: string, value: number, token: string?)
	if value <= 0 then
		return
	end
    local inst = template:Clone()
    inst.Parent = dropsFolder
    -- 出生确认开碰撞
    setDropPhysics(inst, true)
	local root = getRootPart(inst)
	if not root then
		inst:Destroy()
		return
	end
	-- 初始化位置
    local spawnPos = pos + Vector3.new(
        (math.random() - 0.5) * 2,
        CFG.SpawnUpOffset,
        (math.random() - 0.5) * 2
    )
    if inst:IsA("Model") then
        if not inst.PrimaryPart then
            inst.PrimaryPart = root
        end
        inst:PivotTo(CFrame.new(spawnPos))
    else
        root.CFrame = CFrame.new(spawnPos)
    end
	-- 爆散初速度
	root.AssemblyLinearVelocity = Vector3.new(
		(math.random() - 0.5) * 2 * CFG.ScatterSpeedH,
		math.random(CFG.ScatterSpeedVMin, CFG.ScatterSpeedVMax),
		(math.random() - 0.5) * 2 * CFG.ScatterSpeedH
	)
	table.insert(orbs, {
		inst = inst,
		root = root,
		kind = kind,
		value = value,
		token = token,
		bornAt = time(),
		attracting = false,
	})
end

-- 工具：拾取，通知 HUD
local function fireHudReward(kind: string, value: number)
	rewardBE:Fire(kind, value)
end

-- 服务器下发：本次击杀允许播放掉落
EnemyRewardDropRE.OnClientEvent:Connect(function(payload)
	-- payload = { token, pos, coin, exp, items, enemy, t }
	if typeof(payload) ~= "table" then
		return
	end
	local pos   = payload.pos
	local token = payload.token
	local coin  = payload.coin
	local exp   = payload.exp

	if typeof(pos) ~= "Vector3" then
		return
	end
	if typeof(token) ~= "string" then
		token = ""
	end
	coin = (typeof(coin) == "number") and coin or 0
	exp  = (typeof(exp)  == "number") and exp  or 0

	-- 生成金币球
	local coinCount = calcVisualCount(coin)
	if coinCount > 0 then
		local parts = splitAmount(coin, coinCount)
		for _, v in ipairs(parts) do
			spawnOrb(CoinFxTemplate, pos, "coin", v, token)
		end
	end

	-- 生成经验球
	local expCount = calcVisualCount(exp)
	if expCount > 0 then
		local parts = splitAmount(exp, expCount)
		for _, v in ipairs(parts) do
			spawnOrb(ExpFxTemplate, pos, "exp", v, token)
		end
	end

	-- 装备掉落预留：payload.items（你以后扩展）
end)

-- 主循环：吸附 & 拾取
RunService.Heartbeat:Connect(function(dt)
	local root = getCharRoot()
	if not root then
		return
	end
	local targetPos = root.Position + Vector3.new(0, 1.5, 0)
	local now = time()
	for i = #orbs, 1, -1 do
		local orb = orbs[i]
		if not orb.inst.Parent or not orb.root.Parent then
			table.remove(orbs, i)
			continue
		end
		-- 超时兜底删
		if (now - orb.bornAt) >= CFG.MaxLifeSeconds then
			orb.inst:Destroy()
			table.remove(orbs, i)
			continue
		end
		local p = orb.root.Position
		local dist = (targetPos - p).Magnitude
        -- 出生延迟：先让它自己弹跳/飞一会，保证肉眼能看到
        local bornDt = now - orb.bornAt
        if bornDt < CFG.MagnetDelay then
            continue
        end
        -- 进入吸附
        if not orb.attracting and dist <= CFG.MagnetRadius then
            orb.attracting = true
            -- 吸附阶段：关碰撞 + Anchor，避免卡地形/穿模
            setDropPhysics(orb.inst, false)
            orb.root.Anchored = true
        end

		if orb.attracting then
            -- 拾取迟一下，避免秒捡只听声
            if bornDt >= CFG.PickupDelay and dist <= CFG.PickupRadius then
                fireHudReward(orb.kind, orb.value)
                orb.inst:Destroy()
                table.remove(orbs, i)
            else
                -- 拾取判定
                if dist <= CFG.PickupRadius then
                    fireHudReward(orb.kind, orb.value)
                    orb.inst:Destroy()
                    table.remove(orbs, i)
                else
                    -- 吸附移动（越近越快一点）
                    local dir = (targetPos - p)
                    local d   = dir.Magnitude
                    if d > 0.001 then
                        local speed = CFG.AttractSpeedBase + (CFG.MagnetRadius - math.min(d, CFG.MagnetRadius)) * 6
                        local step  = math.min(d, speed * dt)
                        local newPos = p + dir.Unit * step

                        if orb.inst:IsA("Model") then
                            (orb.inst :: Model):PivotTo(CFrame.new(newPos))
                        else
                            orb.root.CFrame = CFrame.new(newPos)
                        end
                    end
                end
            end
		end
	end
end)
