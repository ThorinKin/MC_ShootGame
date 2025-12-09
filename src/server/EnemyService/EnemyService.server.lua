-- ServerScriptService/Server/EnemyService/EnemyService.server.lua
local Players   = game:GetService("Players")
local RS        = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- 敌人预制体
local EnemyModelsFolder  = RS:WaitForChild("EnemyModels")
-- 刷怪点
local EnemySpawnerFolder = Workspace:WaitForChild("EnemySpawner")

-- 刷出的敌人放至Wrokspace/Enemies
local EnemiesFolder = Workspace:FindFirstChild("Enemies")
if not EnemiesFolder then
	EnemiesFolder = Instance.new("Folder")
	EnemiesFolder.Name = "Enemies"
	EnemiesFolder.Parent = Workspace
end

-- 远程：给武器用来打敌人
local Remotes = RS:FindFirstChild("Remotes")
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = RS
end
local EnemyDamageRE = Remotes:FindFirstChild("EnemyDamage")
if not EnemyDamageRE then
	EnemyDamageRE = Instance.new("RemoteEvent")
	EnemyDamageRE.Name = "EnemyDamage"
	EnemyDamageRE.Parent = Remotes
end

-- 攻击类型注册表
local EnemyAttackTypeRegistry = require(RS:WaitForChild("Shared"):WaitForChild("EnemyAttackType"):WaitForChild("Registry"))

-- 敌人基础行为属性默认值（AI / 行为层）
local DEFAULTS = {
	AggroRadius  = 30, -- 仇恨范围
	LeashRadius  = 50, -- 营地范围
	WanderRadius = 20, -- 闲逛范围
}

local AI_TICK          = 0.25          -- AI 更新间隔
local MAX_ENEMIES      = 30            -- 同屏最大敌人数
local RESPAWN_INTERVAL = 5             -- 刷新间隔5秒

-- 当前版本仅 EnemySpawner，里面一个 Middle + 一堆 location_*
local SpawnerInfo = {
	centerPart = EnemySpawnerFolder:WaitForChild("Middle"),
	spawnParts = {},
}

for _, child in ipairs(EnemySpawnerFolder:GetChildren()) do
	if child:IsA("BasePart") and child.Name:match("^location_") then
		table.insert(SpawnerInfo.spawnParts, child)
	end
end

if #SpawnerInfo.spawnParts == 0 then
	warn("[EnemyService] EnemySpawner 下没有任何 location_x 刷怪点")
end

-- 所有可用敌人预制
local EnemyPrefabs = {}
for _, m in ipairs(EnemyModelsFolder:GetChildren()) do
	if m:IsA("Model") and m:FindFirstChild("Humanoid") and m:FindFirstChild("HumanoidRootPart") then
		table.insert(EnemyPrefabs, m)
	end
end

if #EnemyPrefabs == 0 then
	warn("[EnemyService] EnemyModels 里没有可用敌人模型")
end

-- 服务器内部使用的敌人状态数据，不同步给客户端
type EnemyAttackSlot = {
	module: any, -- 攻击模块
	state: any,  -- 攻击模块自己的状态表
}

type EnemyRuntimeData = {
	wanderTarget: Vector3?,
	nextWanderSwitch: number,
	attackSlots: { EnemyAttackSlot }?,
}

local enemyData : { [Model]: EnemyRuntimeData } = {}

-- 工具：读敌人身上的数值 Attribute
local function getAttrNumber(model: Instance, name: string, default: number): number
	local v = model:GetAttribute(name)
	if typeof(v) == "number" then
		return v :: number
	end
	return default
end

-- 工具：从 AttackConfigs 里初始化攻击槽
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
		-- Attack1 等是啥都行，我用的StringValue，配置一堆属性
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
				-- init 返回一个 state 表，由模块自己管理内部字段
				local state = attackModule.init(enemy, slotNode)
				if state then
					table.insert(data.attackSlots, {
						module = attackModule,
						state = state,
					})
				end
			end
		end
	end
end

-- 工具：生成一只敌人
local function spawnOneEnemy()
	if #EnemyPrefabs == 0 or #SpawnerInfo.spawnParts == 0 then
		return
	end

	local prefab    = EnemyPrefabs[math.random(1, #EnemyPrefabs)]
	local spawnPart = SpawnerInfo.spawnParts[math.random(1, #SpawnerInfo.spawnParts)]

	local enemy = prefab:Clone()
	enemy.Parent = EnemiesFolder

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	local hrp      = enemy:FindFirstChild("HumanoidRootPart") :: BasePart
	if not (humanoid and hrp) then
		warn("[EnemyService] 敌人缺少 Humanoid 或 HumanoidRootPart：", prefab.Name)
		enemy:Destroy()
		return
	end

	-- 刷新初始位置
	hrp.CFrame = spawnPart.CFrame

	enemy:SetAttribute("HomePos", spawnPart.Position)
	enemy:SetAttribute("State", "Idle")
	enemy:SetAttribute("TargetId", 0)

	enemyData[enemy] = {
		wanderTarget     = nil,
		nextWanderSwitch = time() + math.random(2, 5),
		attackSlots      = {},
	}

	-- 初始化攻击槽
	setupEnemyAttacks(enemy)

	-- 死亡处理
	humanoid.Died:Connect(function()
		local data = enemyData[enemy]
		if not data then return end

		enemy:SetAttribute("State", "Dead")
		enemy:SetAttribute("TargetId", 0)

		data.wanderTarget     = nil
		data.nextWanderSwitch = math.huge
		data.attackSlots      = nil

		-- 留尸体 3s 再删
		task.delay(3, function()
			if enemy.Parent then
				enemyData[enemy] = nil
				enemy:Destroy()
			end
		end)
	end)

	enemy.AncestryChanged:Connect(function(_, parent)
		if not parent then
			enemyData[enemy] = nil
		end
	end)
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

-- 工具：拿一只怪的主要攻击槽（当前版本默认用 Attack1 / 第一个）
local function getPrimaryAttackSlot(data: EnemyRuntimeData): EnemyAttackSlot?
	local slots = data.attackSlots
	if not slots or #slots == 0 then
		return nil
	end
	return slots[1]
end

-- 工具：单个敌人 AI 更新（仇恨 + 移动 + 攻击）
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

	local centerPos   = SpawnerInfo.centerPart.Position
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
		local plr = Players:GetPlayerByUserId(targetId)
		local char = plr and plr.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart

		if plr and char and hum and root and hum.Health > 0 then
			-- 脱战逻辑：玩家离中心超过 LeashRadius 直接清空仇恨
			local distPlayerToCenter = (root.Position - centerPos).Magnitude
			if distPlayerToCenter <= leashRadius then
				targetPlayer, targetRoot, targetHumanoid = plr, root, hum
			end
		end
	end

	-- 没有合法目标：寻找新目标
	if not targetPlayer then
		enemy:SetAttribute("TargetId", 0)

		local nearestPlr, nearestRoot, nearestHum
		local nearestDist = math.huge

		for _, info in ipairs(playersInfo) do
			local distPlayerToCenter = (info.root.Position - centerPos).Magnitude
			if distPlayerToCenter <= leashRadius then
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

	local primarySlot = getPrimaryAttackSlot(data)
	local attackRange = 0
	if primarySlot and primarySlot.module and primarySlot.module.getRange then
		attackRange = primarySlot.module.getRange(primarySlot.state)
	end

	-- 如果有目标：追击 / 攻击
	if targetPlayer and targetRoot and targetHumanoid then
		local distEnemyToPlayer = (targetRoot.Position - hrp.Position).Magnitude
		local distEnemyToHome   = (hrp.Position - homePos).Magnitude

		-- 敌人本身也不能离家太远
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

			-- 通知攻击模块：当前不在攻击距离内，可以用 ctx.targetHumanoid = nil 清理内部状态
			if primarySlot and primarySlot.module and primarySlot.module.update then
				primarySlot.module.update(primarySlot.state, dt, {
					now = now,
					enemy = enemy,
					humanoid = humanoid,
					hrp = hrp,
					targetHumanoid = nil,
					targetRoot = targetRoot,
					distance = distEnemyToPlayer,
				})
			end
		else
			-- 进攻击距离：交给攻击模块判断是否应该出手 / 生效伤害
			enemy:SetAttribute("State", "Attack")

			if primarySlot and primarySlot.module and primarySlot.module.update then
				primarySlot.module.update(primarySlot.state, dt, {
					now = now,
					enemy = enemy,
					humanoid = humanoid,
					hrp = hrp,
					targetHumanoid = targetHumanoid,
					targetRoot = targetRoot,
					distance = distEnemyToPlayer,
				})
			end
		end

		return
	end

	-- 没有目标：闲逛 / 回家 / 发呆
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

-- 远程：玩家攻击敌人
-- 客户端用：EnemyDamageRE:FireServer(enemyModel, damage)
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

	humanoid:TakeDamage(amount)
end)

-- 主循环：定时刷怪 + AI 更新
local lastSpawnTime = 0
task.spawn(function()
	while true do
		-- 刷怪
		local currentCount = #EnemiesFolder:GetChildren()
		if currentCount < MAX_ENEMIES and (time() - lastSpawnTime) >= RESPAWN_INTERVAL then
			spawnOneEnemy()
			lastSpawnTime = time()
		end

		-- AI 更新
		for enemy, _ in pairs(enemyData) do
			if enemy.Parent == EnemiesFolder then
				updateEnemy(enemy, AI_TICK)
			else
				enemyData[enemy] = nil
			end
		end

		task.wait(AI_TICK)
	end
end)
