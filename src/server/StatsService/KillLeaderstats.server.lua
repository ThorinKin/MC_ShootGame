-- ServerScriptService/Server/StatsService/KillLeaderstats.server.lua
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local BlasterFolder = ServerScriptService:WaitForChild("Blaster")
local EventsFolder = BlasterFolder:WaitForChild("Events")
local EliminatedEvent = EventsFolder:WaitForChild("Eliminated") :: BindableEvent

local EnemiesFolder = Workspace:WaitForChild("Enemies")

local function ensureLeaderstats(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local kills = leaderstats:FindFirstChild("Kills")
	if not kills then
		kills = Instance.new("IntValue")
		kills.Name = "Kills"
		kills.Value = 0
		kills.Parent = leaderstats
	end

	return kills
end

Players.PlayerAdded:Connect(function(player)
	ensureLeaderstats(player)
end)
for _, plr in ipairs(Players:GetPlayers()) do
	ensureLeaderstats(plr)
end

EliminatedEvent.Event:Connect(function(killer: Player, victimHumanoid: Humanoid, _damage: number)
	if not killer or not killer:IsA("Player") then
		return
	end

	local model = victimHumanoid:FindFirstAncestorOfClass("Model")
	if not model then
		return
	end

	-- 1）敌人：在 EnemiesFolder 下面
	local isEnemy = (EnemiesFolder ~= nil and model.Parent == EnemiesFolder)

	-- 2）玩家：角色 Model 绑定到某个 Player
	local victimPlayer = Players:GetPlayerFromCharacter(model)
	local isOtherPlayer = victimPlayer ~= nil and victimPlayer ~= killer

	-- 既不是敌人又不是其他玩家，就不计数（比如某些 NPC、装饰 Humanoid）
	if not isEnemy and not isOtherPlayer then
		return
	end

	local kills = ensureLeaderstats(killer)
	kills.Value += 1
end)
