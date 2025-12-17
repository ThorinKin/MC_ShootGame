-- ServerScriptService/Server/EnemyService/EnemyService.server.lua
-- 总注释：敌人系统/刷怪/仇恨/攻击
local Players   = game:GetService("Players")
local RS        = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")

-- 敌人预制体
local EnemyModelsFolder  = RS:WaitForChild("EnemyModels")
local EnemySpawnerRoot = Workspace:WaitForChild("EnemySpawner")
-- 刷出的敌人统一放到 Workspace/Enemies
local EnemiesFolder = Workspace:FindFirstChild("Enemies")
if not EnemiesFolder then
	EnemiesFolder = Instance.new("Folder")
	EnemiesFolder.Name = "Enemies"
	EnemiesFolder.Parent = Workspace
end
-- 远程：给武器用来打敌人
local Remotes = RS:FindFirstChild("Remotes")
local EnemyDamageRE = Remotes:FindFirstChild("EnemyDamage")
-- 攻击类型注册表
local EnemyAttackTypeRegistry = require(RS:WaitForChild("Shared"):WaitForChild("EnemyAttackType"):WaitForChild("Registry"))
local EcoModule = require(ServerScriptService.Server.EcoService.EcoModule)
local ExpModule = require(ServerScriptService.Server.ExpService.ExpModule)
local EnemyRewardDropRE = Remotes:FindFirstChild("EnemyRewardDrop") -- 远程：下发允许播放掉落视觉，防止find为空
if not EnemyRewardDropRE then
	EnemyRewardDropRE = Instance.new("RemoteEvent")
	EnemyRewardDropRE.Name = "EnemyRewardDrop"
	EnemyRewardDropRE.Parent = Remotes
end 
-- 敌人基础行为枚举和属性默认值
local DEFAULTS = {
	AggroRadius  = 30, -- 仇恨范围
	LeashRadius  = 50, -- 活动范围（以出生点为中心）
	WanderRadius = 20, -- 闲逛范围（以出生点为中心）
}
-----------------------------可调参数/默认值---------------------
local AI_TICK                   = 0.25          -- AI 更新间隔
local MAX_ENEMIES               = 30            -- 全局同屏最大敌人数（多区域总和）
local DEFAULT_RESPAWN_INTERVAL  = 5             -- 区域默认刷新间隔
local DEFAULT_MAX_PER_SPAWN     = 2             -- 区域默认：每个刷怪点最多几只
-- 掉落物效果参数
local DROP = {
	-- lastHit 有效期：敌人死前多少秒内最后一次伤害算击杀
	LastHitWindow = 8,
	-- 默认掉落（敌人模型上没配 Attribute 时用）
	DefaultCoinMin = 5,
	DefaultCoinMax = 15,
	DefaultExpMin  = 10,
	DefaultExpMax  = 30,
}
----------------------------------------------------------------

-- 敌人预制体缓存：列表 + 按名字索引
local EnemyPrefabs = {}
local EnemyPrefabsByName = {}
for _, m in ipairs(EnemyModelsFolder:GetChildren()) do
	if m:IsA("Model") and m:FindFirstChild("Humanoid") and m:FindFirstChild("HumanoidRootPart") then
		table.insert(EnemyPrefabs, m)
		EnemyPrefabsByName[m.Name] = m
	end
end
if #EnemyPrefabs == 0 then
	warn("[EnemyService] EnemyModels 里没有可用敌人模型")
end

-- 区域缓存
local regions = {}
-- 运行时：每个刷怪点当前有几只怪
local spawnCounts : { [BasePart]: number } = {}
-- 服务器内部使用的敌人状态数据
type EnemyAttackSlot = {
	module: any, -- 攻击模块
	state: any,  -- 攻击模块自己的状态表
}
type EnemyRuntimeData = {
	wanderTarget: Vector3?,
	nextWanderSwitch: number,
	attackSlots: { EnemyAttackSlot }?,
	spawnRegion: any?,
	spawnPart: BasePart?,
	-- 击杀归属
	lastDamagerId: number?,
	lastDamageTime: number?,
}
local enemyData : { [Model]: EnemyRuntimeData } = {}

-- 工具：读敌人掉落配置（敌人模型 Attribute 配：DropCoinMin/Max, DropExpMin/Max 或 固定值 DropCoin / DropExp）
local function getDropInt(enemy: Model, key: string, defMin: number, defMax: number): number
	local fixed = enemy:GetAttribute(key)
	if typeof(fixed) == "number" then
		return math.max(0, math.floor(fixed + 0.5))
	end
	local minV = enemy:GetAttribute(key .. "Min")
	local maxV = enemy:GetAttribute(key .. "Max")
	local minN = (typeof(minV) == "number") and math.floor(minV + 0.5) or defMin
	local maxN = (typeof(maxV) == "number") and math.floor(maxV + 0.5) or defMax
	if maxN < minN then
		minN, maxN = maxN, minN
	end
	minN = math.max(0, minN)
	maxN = math.max(0, maxN)
	if maxN == minN then
		return minN
	end
	return math.random(minN, maxN)
end
-- 工具：敌人死亡 → 服务器结算奖励 + 下发客户端视觉
local pendingRewardTokens = {} :: {
	[string]: { userId: number, coin: number, exp: number, expireAt: number }
}
-- 工具：敌人死亡 → 服务器结算奖励 + 下发客户端视觉
local function handleEnemyDrops(enemy: Model, deathPos: Vector3)
	local data = enemyData[enemy]
	-- 判定击杀者（lastHit）
	local now = time()
	local killerIdAttr = enemy:GetAttribute("LastDamagerId")
	local lastTAttr    = enemy:GetAttribute("LastDamageTime")
	local killerId = (typeof(killerIdAttr) == "number") and killerIdAttr or (data and data.lastDamagerId)
	local lastT    = (typeof(lastTAttr)    == "number") and lastTAttr    or (data and data.lastDamageTime)
	-- 调试日志
	warn(("[EnemyService] DropsCheck enemy=%s killerId=%s lastT=%s now=%s"):format(enemy.Name, tostring(killerId), tostring(lastT), tostring(now)))
	if not killerId or not lastT or (now - lastT) > DROP.LastHitWindow then
		warn("[EnemyService] handleEnemyDrops：击杀归属无效（LastHitWindow）")
		return
	end
	local killer = Players:GetPlayerByUserId(killerId)
	if not killer then
		warn("[EnemyService] 未获取到击杀者玩家ID")
		return
	end
	-- 服务器权威掉落数值
	local coin = getDropInt(enemy, "DropCoin", DROP.DefaultCoinMin, DROP.DefaultCoinMax)
	local exp  = getDropInt(enemy, "DropExp",  DROP.DefaultExpMin,  DROP.DefaultExpMax)
	-- 装备掉落预留：先留空
	local items = {}
	-- 权威服务器发钱发经验
	if coin > 0 then
		EcoModule.add(killer, EcoModule.CURRENCY.Cash, coin, "enemyDrop:" .. enemy.Name)
	end
	if exp > 0 then
		ExpModule.addExp(killer, exp, "enemyDrop:" .. enemy.Name)
	end
	-- 下发客户端视觉许可（只给击杀者）
	local token = HttpService:GenerateGUID(false)
	pendingRewardTokens[token] = {
		userId   = killerId,
		coin     = coin,
		exp      = exp,
		expireAt = now + 25,
	}
	EnemyRewardDropRE:FireClient(killer, {
		token = token,
		pos   = deathPos,
		coin  = coin,
		exp   = exp,
		items = items, -- 预留
		enemy = enemy.Name,
		t     = now,
	})
end

-- 工具：读 Attribute 里的 number
local function getAttrNumber(obj: Instance, name: string, default: number): number
	local v = obj:GetAttribute(name)
	if typeof(v) == "number" then
		return v :: number
	end
	return default
end

-- 构建某个区域的怪物池
local function buildEnemyPoolForRegion(regionFolder: Instance)
	local pool = {}
	local totalWeight = 0
	for name, value in pairs(regionFolder:GetAttributes()) do
		if typeof(value) == "number" and value > 0 then
			local prefab = EnemyPrefabsByName[name]
			if prefab then
				table.insert(pool, {
					prefab = prefab,
					weight = value,
				})
				totalWeight += value
			end
		end
	end
	if #pool == 0 then
		warn("[EnemyService] 区域", regionFolder.Name,
			"没有合法的敌人ID属性，将退回全局 EnemyPrefabs 随机")
	end
	return pool, totalWeight
end
local function pickEnemyFromPool(pool, totalWeight)
	if not pool or #pool == 0 or totalWeight <= 0 then
		return nil
	end

	local r = math.random() * totalWeight
	local acc = 0
	for _, entry in ipairs(pool) do
		acc += entry.weight
		if r <= acc then
			return entry.prefab
		end
	end

	return pool[#pool].prefab
end

-- 初始化所有区域
for _, regionFolder in ipairs(EnemySpawnerRoot:GetChildren()) do
	if regionFolder:IsA("Folder") then
		local spawnParts = {}
		for _, child in ipairs(regionFolder:GetChildren()) do
			if child:IsA("BasePart") then
				table.insert(spawnParts, child)
			end
		end

		if #spawnParts == 0 then
			warn("[EnemyService] 区域", regionFolder.Name, "下没有任何刷怪点 BasePart")
		end

		local respawnInterval = getAttrNumber(regionFolder, "RespawnInterval", DEFAULT_RESPAWN_INTERVAL)
		local maxRegionEnemies = getAttrNumber(regionFolder, "MaxRegionEnemies", MAX_ENEMIES)
		local defaultMaxPerPoint = getAttrNumber(regionFolder, "DefaultMaxAlivePerPoint", DEFAULT_MAX_PER_SPAWN)

		local enemyPool, totalWeight = buildEnemyPoolForRegion(regionFolder)

		table.insert(regions, {
			folder                   = regionFolder,
			spawnParts               = spawnParts,
			enemyPool                = enemyPool,
			totalWeight              = totalWeight,
			respawnInterval          = respawnInterval,
			maxRegionEnemies         = maxRegionEnemies,
			defaultMaxAlivePerPoint  = defaultMaxPerPoint,
			lastSpawnTime            = 0,
			aliveCount               = 0,
		})
	end
end
if #regions == 0 then
	warn("[EnemyService] EnemySpawner 根下没有任何区域 Folder")
end

-- 敌人攻击槽初始化：从 AttackConfigs 里读
local function setupEnemyAttacks(enemy: Model)
	local data = enemyData[enemy]
	if not data then
		return
	end
	data.attackSlots = {}
	local cfgRoot = enemy:FindFirstChild("AttackConfigs")
	if not cfgRoot or not cfgRoot:IsA("Folder") then
		-- 没有 AttackConfigs：这只怪物不会攻击，只会追人/闲逛
		return
	end
	for _, slotNode in ipairs(cfgRoot:GetChildren()) do
		local typeName: string? = nil
		local typeChild = slotNode:FindFirstChild("Type")
		if typeChild and typeChild:IsA("StringValue") then
			typeName = typeChild.Value
		else
			local attr = slotNode:GetAttribute("Type")
			if typeof(attr) == "string" then
				typeName = attr :: string
			end
		end

		if not typeName or typeName == "" then
			warn("[EnemyService] 攻击槽缺少 Type 配置：", slotNode:GetFullName())
		else
			local attackModule = EnemyAttackTypeRegistry.get(typeName)
			if not attackModule or type(attackModule) ~= "table" then
				warn("[EnemyService] 未知攻击类型：", typeName, " 敌人：", enemy.Name)
			elseif not attackModule.init or not attackModule.update or not attackModule.getRange then
				warn("[EnemyService] 攻击模块接口不完整：", typeName)
			else
				local state = attackModule.init(enemy, slotNode)
				if state then
					table.insert(data.attackSlots, {
						module = attackModule,
						state  = state,
					})
				end
			end
		end
	end
end

-- 清理一只敌人：更新计数 + 清 enemyData
local function cleanupEnemy(enemy: Model)
	local data = enemyData[enemy]
	if not data then
		return
	end

	if data.spawnRegion then
		local region = data.spawnRegion
		region.aliveCount = math.max(0, (region.aliveCount or 0) - 1)
	end

	if data.spawnPart then
		local part = data.spawnPart
		local current = spawnCounts[part] or 0
		if current > 0 then
			spawnCounts[part] = current - 1
		end
	end

	enemyData[enemy] = nil
end

-- 工具：拿这个点允许的最大怪物数
local function getMaxAliveForPart(region, spawnPart: BasePart)
	local v = spawnPart:GetAttribute("MaxAlive")
	if typeof(v) == "number" then
		return v :: number
	end
	return region.defaultMaxAlivePerPoint
end

-- 工具：在某个区域刷一只怪
local function spawnOneEnemyInRegion(region)
	if #EnemyPrefabs == 0 or #region.spawnParts == 0 then
		return nil
	end
	-- 全局上限
	if #EnemiesFolder:GetChildren() >= MAX_ENEMIES then
		return nil
	end
	-- 区域上限
	if region.aliveCount >= region.maxRegionEnemies then
		return nil
	end
	-- 找一个还有空位的刷怪点
	local candidates = {}
	for _, spawnPart in ipairs(region.spawnParts) do
		local maxAlive = getMaxAliveForPart(region, spawnPart)
		if maxAlive > 0 then
			local current = spawnCounts[spawnPart] or 0
			if current < maxAlive then
				table.insert(candidates, spawnPart)
			end
		end
	end
	if #candidates == 0 then
		-- 所有点都爆满了，该区域暂时不刷
		return nil
	end
	local spawnPart = candidates[math.random(1, #candidates)]
	-- 选择敌人 prefab（先看区域配置，没有的话用全局 EnemyPrefabs）
	local prefab
	if region.enemyPool and #region.enemyPool > 0 and region.totalWeight > 0 then
		prefab = pickEnemyFromPool(region.enemyPool, region.totalWeight)
	else
		prefab = EnemyPrefabs[math.random(1, #EnemyPrefabs)]
	end

	if not prefab then
		return nil
	end

	local enemy = prefab:Clone()
	enemy.Parent = EnemiesFolder

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp      = enemy:FindFirstChild("HumanoidRootPart") :: BasePart
	if not (humanoid and hrp) then
		warn("[EnemyService] 敌人缺少 Humanoid 或 HumanoidRootPart：", prefab.Name)
		enemy:Destroy()
		return nil
	end
	-- 刷新初始位置
	hrp.CFrame = spawnPart.CFrame
	-- 出生点就是它的营地中心
	enemy:SetAttribute("HomePos", spawnPart.Position)
	enemy:SetAttribute("State", "Idle")
	enemy:SetAttribute("TargetId", 0)
	enemy:SetAttribute("LastDamagerId", 0)
	enemy:SetAttribute("LastDamageTime", 0)

	local data: EnemyRuntimeData = {
		wanderTarget     = nil,
		nextWanderSwitch = time() + math.random(2, 5),
		attackSlots      = {},
		spawnRegion      = region,
		spawnPart        = spawnPart,
	}
	enemyData[enemy] = data
	-- 计数
	spawnCounts[spawnPart] = (spawnCounts[spawnPart] or 0) + 1
	region.aliveCount      = (region.aliveCount or 0) + 1
	-- 初始化攻击槽
	setupEnemyAttacks(enemy)
	-- 死亡处理
	humanoid.Died:Connect(function()
		enemy:SetAttribute("State", "Dead")
		enemy:SetAttribute("TargetId", 0)
		local d = enemyData[enemy]
		if d then
			d.wanderTarget     = nil
			d.nextWanderSwitch = math.huge
			d.attackSlots      = nil
		end
		-- 掉落结算
		handleEnemyDrops(enemy, hrp.Position)
		-- 清计数 + enemyData
		cleanupEnemy(enemy)
		-- 留尸体 3s 再删
		task.delay(3, function()
			if enemy.Parent then
				enemy:Destroy()
			end
		end)
	end)
	enemy.AncestryChanged:Connect(function(_, parent)
		if not parent then
			-- 被外部 Destroy 之类，兜底清理
			cleanupEnemy(enemy)
		end
	end)
	return enemy
end

-- 工具：获取当前所有活着的玩家
local function getLivingPlayers()
	local result = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if hum and root and hum.Health > 0 then
			table.insert(result, {
				player   = plr,
				humanoid = hum,
				root     = root :: BasePart,
			})
		end
	end
	return result
end

-- 工具：拿一只怪的主要攻击槽（当前版本默认用 attackSlots[1]）
local function getPrimaryAttackSlot(data: EnemyRuntimeData): EnemyAttackSlot?
	local slots = data.attackSlots
	if not slots or #slots == 0 then
		return nil
	end
	return slots[1]
end

-- 单个敌人 AI 更新（仇恨 + 移动 + 攻击）
local function updateEnemy(enemy: Model, dt: number)
	local data = enemyData[enemy]
	if not data then return end
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp      = enemy:FindFirstChild("HumanoidRootPart") :: BasePart
	if not (humanoid and hrp) then return end
	if humanoid.Health <= 0 then return end
	local homePosAttr = enemy:GetAttribute("HomePos")
	local homePos     = if typeof(homePosAttr) == "Vector3" then homePosAttr :: Vector3 else hrp.Position
	local aggroRadius  = getAttrNumber(enemy, "AggroRadius",  DEFAULTS.AggroRadius)
	local leashRadius  = getAttrNumber(enemy, "LeashRadius",  DEFAULTS.LeashRadius)
	local wanderRadius = getAttrNumber(enemy, "WanderRadius", DEFAULTS.WanderRadius)
	local playersInfo = getLivingPlayers()
	local now         = time()
	-- 没玩家：全体回家
	if #playersInfo == 0 then
		enemy:SetAttribute("TargetId", 0)
		local distHome = (hrp.Position - homePos).Magnitude
		if distHome > 2 then
			humanoid:MoveTo(homePos)
			enemy:SetAttribute("State", "Return")
		else
			enemy:SetAttribute("State", "Idle")
		end
		return
	end
	-- 先尝试沿用当前 TargetId
	local targetId = enemy:GetAttribute("TargetId")
	if typeof(targetId) ~= "number" then
		targetId = 0
	end
	local targetPlayer, targetRoot, targetHumanoid
	if targetId ~= 0 then
		local plr  = Players:GetPlayerByUserId(targetId)
		local char = plr and plr.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart
		if plr and char and hum and root and hum.Health > 0 then
			-- 脱战逻辑：玩家离这只怪的出生点超过 LeashRadius 直接清空仇恨
			local distPlayerToHome = (root.Position - homePos).Magnitude
			if distPlayerToHome <= leashRadius then
				targetPlayer, targetRoot, targetHumanoid = plr, root, hum
			end
		end
	end
	-- 没有合法目标：寻找新目标（以 HomePos 为中心）
	if not targetPlayer then
		enemy:SetAttribute("TargetId", 0)
		local nearestPlr, nearestRoot, nearestHum
		local nearestDist = math.huge
		for _, info in ipairs(playersInfo) do
			local distPlayerToHome = (info.root.Position - homePos).Magnitude
			if distPlayerToHome <= leashRadius then
				local distEnemyToPlayer = (info.root.Position - hrp.Position).Magnitude
				if distEnemyToPlayer <= aggroRadius and distEnemyToPlayer < nearestDist then
					nearestDist = distEnemyToPlayer
					nearestPlr  = info.player
					nearestRoot = info.root
					nearestHum  = info.humanoid
				end
			end
		end
		if nearestPlr then
			enemy:SetAttribute("TargetId", nearestPlr.UserId)
			targetPlayer, targetRoot, targetHumanoid = nearestPlr, nearestRoot, nearestHum
		end
	end
	-- 拿攻击范围
	local primarySlot = getPrimaryAttackSlot(data)
	local attackRange = 0
	if primarySlot and primarySlot.module and primarySlot.module.getRange then
		attackRange = primarySlot.module.getRange(primarySlot.state)
	end
	-- 如果有目标：追击 / 攻击
	if targetPlayer and targetRoot and targetHumanoid then
		local distEnemyToPlayer = (targetRoot.Position - hrp.Position).Magnitude
		local distEnemyToHome   = (hrp.Position - homePos).Magnitude
		-- 敌人本身也不能离出生点太远（以 homePos 为中心）
		if distEnemyToHome > leashRadius * 1.2 then
			enemy:SetAttribute("TargetId", 0)
			enemy:SetAttribute("State", "Return")
			humanoid:MoveTo(homePos)
			return
		end
		if attackRange <= 0 or distEnemyToPlayer > attackRange then
			-- 还没进攻击距离：追击
			enemy:SetAttribute("State", "Walk")
			humanoid:MoveTo(targetRoot.Position)
			-- 通知攻击模块：当前不在攻击距离内，可以用 targetHumanoid = nil 清理内部状态
			if primarySlot and primarySlot.module and primarySlot.module.update then
				primarySlot.module.update(primarySlot.state, dt, {
					now            = now,
					enemy          = enemy,
					humanoid       = humanoid,
					hrp            = hrp,
					targetHumanoid = nil,
					targetRoot     = targetRoot,
					distance       = distEnemyToPlayer,
				})
			end
		else
			-- 进攻击距离：交给攻击模块判断是否应该出手 / 生效伤害
			enemy:SetAttribute("State", "Attack")
			if primarySlot and primarySlot.module and primarySlot.module.update then
				primarySlot.module.update(primarySlot.state, dt, {
					now            = now,
					enemy          = enemy,
					humanoid       = humanoid,
					hrp            = hrp,
					targetHumanoid = targetHumanoid,
					targetRoot     = targetRoot,
					distance       = distEnemyToPlayer,
				})
			end
		end

		return
	end
	-- 没有目标：闲逛 / 回家 / 发呆（以 HomePos 为中心）
	enemy:SetAttribute("TargetId", 0)
	local distHome = (hrp.Position - homePos).Magnitude
	-- 如果走得太远，强制回家
	if distHome > wanderRadius * 1.5 then
		enemy:SetAttribute("State", "Return")
		humanoid:MoveTo(homePos)
		data.wanderTarget = nil
		return
	end
	-- 闲逛状态机
	if not data.wanderTarget or now >= data.nextWanderSwitch then
		-- 40% 概率原地发呆，60% 概率去随机点走一走
		if math.random() < 0.4 then
			data.wanderTarget     = nil
			data.nextWanderSwitch = now + math.random(2, 4)
			enemy:SetAttribute("State", "Idle")
		else
			local angle  = math.random() * math.pi * 2
			local radius = math.random() * wanderRadius
			local offset = Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
			local dest   = homePos + offset

			data.wanderTarget     = dest
			data.nextWanderSwitch = now + math.random(4, 7)
			humanoid:MoveTo(dest)
			enemy:SetAttribute("State", "Walk")
		end
	else
		-- 已经有 wanderTarget：继续走或者到达后发呆
		if data.wanderTarget then
			local dist = (hrp.Position - data.wanderTarget).Magnitude
			if dist <= 2 then
				data.wanderTarget = nil
				enemy:SetAttribute("State", "Idle")
			else
				humanoid:MoveTo(data.wanderTarget)
				enemy:SetAttribute("State", "Walk")
			end
		else
			enemy:SetAttribute("State", "Idle")
		end
	end
end

-- 远程：玩家攻击敌人 / 客户端用：EnemyDamageRE:FireServer(enemyModel, damage)
EnemyDamageRE.OnServerEvent:Connect(function(player, enemyModel, amount)
	if typeof(amount) ~= "number" or amount <= 0 then
		return
	end
	if not (enemyModel and enemyModel:IsA("Model") and enemyModel.Parent == EnemiesFolder) then
		return
	end
	local humanoid = enemyModel:FindFirstChildOfClass("Humanoid")
	local hrp      = enemyModel:FindFirstChild("HumanoidRootPart")
	if not (humanoid and hrp) then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	-- 反作弊：限制最大射程
	local maxHitDistance = 150
	if (hrp.Position - root.Position).Magnitude > maxHitDistance then
		return
	end
	-- 记录 lastHit：用于死亡时判定击杀者
	local d = enemyData[enemyModel]
	if d then
		d.lastDamagerId  = player.UserId
		d.lastDamageTime = time()
	end
	enemyModel:SetAttribute("LastDamagerId", player.UserId)
	enemyModel:SetAttribute("LastDamageTime", time())
	humanoid:TakeDamage(amount)
end)

-- 清理过期 token，防止 pendingRewardTokens 长期增长
task.spawn(function()
	while true do
		local now = time()
		for token, rec in pairs(pendingRewardTokens) do
			if not rec or now > (rec.expireAt or 0) then
				pendingRewardTokens[token] = nil
			end
		end
		task.wait(30)
	end
end)

-- 主循环：多区域刷怪 + AI 更新
task.spawn(function()
	while true do
		-- 多区域刷怪
		for _, region in ipairs(regions) do
			if #region.spawnParts > 0 then
				if region.aliveCount < region.maxRegionEnemies then
					if (time() - region.lastSpawnTime) >= region.respawnInterval then
						local enemy = spawnOneEnemyInRegion(region)
						if enemy then
							region.lastSpawnTime = time()
						end
					end
				end
			end
		end
		-- AI 更新（只对还在 enemyData 里的敌人）
		for enemy, _ in pairs(enemyData) do
			if enemy.Parent == EnemiesFolder then
				updateEnemy(enemy, AI_TICK)
			else
				-- 敌人不在 EnemiesFolder 下了，兜底清理
				cleanupEnemy(enemy)
			end
		end
		task.wait(AI_TICK)
	end
end)
