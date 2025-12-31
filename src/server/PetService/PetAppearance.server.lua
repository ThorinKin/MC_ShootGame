-- ServerScriptService/Server/PetService/PetAppearance.server.lua
-- 总注释：宠物外观同步（服务端）。把玩家已装备的宠物 kind 写入 Player Attributes 。客户端根据 Attributes 自己渲染宠物模型 服务端不生成宠物实例。
local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local PetModule = require(ServerScriptService.Server.PetService.PetModule)
local MAX_SLOTS = PetModule.MAX_SLOTS or 5

-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[PetAppearance] " .. string.format(fmt, ...))
	end
end

-- Attributes 命名：每个槽位一个 kind（string 或 nil）
local function attrKindName(i: number): string
	return ("PetSlot%dKind"):format(i)
end

local ATTR_VER = "PetSlotsVer"

-- 工具：把快照 equipped 写 Player Attributes
local function applyAppearanceAttrs(player: Player, snapshot)
	if not (player and player.Parent) then
		return
	end
	if typeof(snapshot) ~= "table" then
		return
	end

	local backpack = snapshot.backpack or {}
	local equipped = snapshot.equipped or {}

	for i = 1, MAX_SLOTS do
		local slot = equipped[i]
		local kind: string? = nil

		if typeof(slot) == "table" and slot.unlocked and slot.id then
			local petId = slot.id
			local pet = backpack[petId]
			if typeof(pet) == "table" then
				local k = pet.kind
				if type(k) == "string" and k ~= "" then
					kind = k
				end
			end
		end

		-- nil 会清掉 Attribute
		player:SetAttribute(attrKindName(i), kind)
	end

	-- 版本号：方便客户端只监听一个字段也能刷新
	local ver = player:GetAttribute(ATTR_VER)
	if type(ver) ~= "number" then
		ver = 0
	end
	player:SetAttribute(ATTR_VER, ver + 1)

	dprint("%s 外观 Attributes 已刷新 ver=%d", player.Name, ver + 1)
end

-- 监听 PetModule 变化：写 Attributes
PetModule.onChanged(function(player, snapshot)
	applyAppearanceAttrs(player, snapshot)
end)

-- 玩家加入兜底：确保数据初始化后 Attributes 不会空
local function onPlayerAdded(player: Player)
	task.delay(1, function()
		if not (player and player.Parent) then
			return
		end
		local ok, snapOrErr = pcall(function()
			-- 兜底：保证有 shape，并触发一次 onChanged
			return PetModule.ensureInitialized(player)
		end)

		if ok then
			applyAppearanceAttrs(player, snapOrErr)
		else
			warn(("[PetAppearance] ensureInitialized failed for %s: %s"):format(player.Name, tostring(snapOrErr)))
		end
	end)
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, plr in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, plr)
end
