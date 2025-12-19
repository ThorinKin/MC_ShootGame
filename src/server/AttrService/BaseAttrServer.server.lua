-- ServerScriptService/Server/AttrService/BaseAttrServer.server.lua
-- 总注释：基础属性同步桥。把 BaseAttrModule 的值同步到 player.Attr 下的只读节点，供前端/别的系统读
local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[BaseAttrServer] " .. string.format(fmt, ...))
	end
end

local BaseAttrModule = require(ServerScriptService.Server.AttrService.BaseAttrModule)
local F = BaseAttrModule.FIELDS

-- 确保 player.Attr 文件夹存在（不跟原 AttrServer 冲突 是同一个 Folder）
local function ensureAttrFolder(player)
	local folder = player:FindFirstChild("Attr")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Attr"
		folder.Parent = player
	end
	return folder
end

local function ensureNumber(folder, name)
	local v = folder:FindFirstChild(name)
	if not v then
		v = Instance.new("NumberValue")
		v.Name = name
		v.Parent = folder
	end
	return v
end

local function ensureInt(folder, name)
	local v = folder:FindFirstChild(name)
	if not v then
		v = Instance.new("IntValue")
		v.Name = name
		v.Parent = folder
	end
	return v
end

local function syncFromSnapshot(player, snap)
	if not player or not player.Parent then return end
	snap = snap or BaseAttrModule.getAll(player)
	local folder = ensureAttrFolder(player)
	-- 命名带 Base 前缀，避免跟加点的 三个字段 混
	ensureInt(folder,    "BaseHealth").Value      = math.floor((snap[F.baseHealth] or 0) + 0.5)
	ensureNumber(folder, "CritChance").Value      = snap[F.critChance] or 0
	ensureNumber(folder, "CritDamage").Value      = snap[F.critDamage] or 1
	ensureNumber(folder, "Luck").Value            = snap[F.luck] or 0
	ensureNumber(folder, "MoveSpeed").Value       = snap[F.moveSpeed] or 16
	ensureNumber(folder, "DamageReduction").Value = snap[F.damageReduction] or 0
	ensureNumber(folder, "CoinMultiplier").Value  = snap[F.coinMultiplier] or 1
	ensureInt(folder,    "Armor").Value           = math.floor((snap[F.armor] or 0) + 0.5)
	ensureNumber(folder, "GunBonus").Value        = snap[F.gunBonus] or 0
	dprint("%s sync base attrs ok", player.Name)
end

Players.PlayerAdded:Connect(function(player)
	ensureAttrFolder(player)

	local ok, err = pcall(function()
		-- 主动 ensureInit 一下，保证旧数据补齐默认字段
		BaseAttrModule.ensureInitialized(player)
		syncFromSnapshot(player)
	end)
	if not ok then
		warn(("[BaseAttrServer] 初始化 %s 失败：%s"):format(player.Name, tostring(err)))
	end
end)

BaseAttrModule.onChanged(function(player, snap)
	local ok, err = pcall(function()
		syncFromSnapshot(player, snap)
	end)
	if not ok then
		warn(("[BaseAttrServer] syncFromSnapshot 出错：%s"):format(tostring(err)))
	end
end)
