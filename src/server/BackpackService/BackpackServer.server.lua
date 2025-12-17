-- ServerScriptService/Server/BackpackService/BackpackServer.server.lua
-- 总注释：Backpack 数据同步给客户端、处理穿戴请求等 远程事件处理
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[BackpackServer] " .. string.format(fmt, ...))
    end
end

local BackpackModule = require(ServerScriptService.Server.BackpackService.BackpackModule)
local BackpackAppearance = require(ServerScriptService.Server.BackpackService.BackpackAppearance)

-- 远程事件
local RemotesRoot      = ReplicatedStorage:WaitForChild("Remotes")
local BackpackRemotes  = RemotesRoot:WaitForChild("Backpack")
-- S-C：单播给玩家
local RE_S2C_Full          = BackpackRemotes:WaitForChild("[S-C]BackpackFull")
local RE_S2C_ItemsAdded    = BackpackRemotes:WaitForChild("[S-C]BackpackItemsAdded")
local RE_S2C_ItemsRemoved  = BackpackRemotes:WaitForChild("[S-C]BackpackItemsRemoved")
local RE_S2C_Equipped      = BackpackRemotes:WaitForChild("[S-C]BackpackEquippedChanged") -- (slotName, slotIndex, newId, oldId)
-- C-S：客户端请求
local RE_CS_Equip          = BackpackRemotes:WaitForChild("[C-S]BackpackEquip")
local RE_CS_Unequip        = BackpackRemotes:WaitForChild("[C-S]BackpackUnequip")
local RE_CS_RequestFull    = BackpackRemotes:WaitForChild("[C-S]BackpackRequestFull")
-- Message 提示
local MessageRemotes   = RemotesRoot:WaitForChild("Message")
local RemoteMessageBar = MessageRemotes:WaitForChild("[S-C]Message")
local RemoteMessageNo  = MessageRemotes:WaitForChild("[S-C]MessageNo")

-- 工具：发提示信息
local function sendMsg(player, text, noBar)
    if not player or not player.Parent then
        return
    end
    if noBar then
        RemoteMessageNo:FireClient(player, text)
    else
        RemoteMessageBar:FireClient(player, text)
    end
end

-- 工具：拷贝一个 state（保险起见，这里再做一层浅拷贝）
local function shallowCopyState(state)
    local copy = {
        backpack = {},
        equipped = {},
    }

    if state.backpack then
        for id, item in pairs(state.backpack) do
            copy.backpack[id] = item
        end
    end

    if state.equipped then
        for i, slot in ipairs(state.equipped) do
            copy.equipped[i] = {
                slot = slot.slot,
                id   = slot.id,
            }
        end
    end

    return copy
end

-- 工具：diff 新旧状态，算出新增/删除/装备变化 
local function diffStates(oldState, newState)
    local addedItems      = {}
    local removedItemIds  = {}
    local equippedChanges = {}

    local oldBackpack = (oldState and oldState.backpack) or {}
    local newBackpack = newState.backpack or {}

    -- 新增物品
    for id, item in pairs(newBackpack) do
        if not oldBackpack[id] then
            table.insert(addedItems, item)
        end
    end

    -- 删除物品
    if oldState then
        for id, _ in pairs(oldBackpack) do
            if not newBackpack[id] then
                table.insert(removedItemIds, id)
            end
        end
    end

    -- 装备变化（按数组下标算）
    local oldEquipped = (oldState and oldState.equipped) or {}
    local newEquipped = newState.equipped or {}
    local maxLen = math.max(#oldEquipped, #newEquipped)

    for i = 1, maxLen do
        local o = oldEquipped[i]
        local n = newEquipped[i]

        local oldId    = o and o.id or nil
        local newId    = n and n.id or nil
        local slotName = (n and n.slot) or (o and o.slot) or nil

        if slotName and oldId ~= newId then
            table.insert(equippedChanges, {
                slotIndex = i,
                slotName  = slotName,
                newId     = newId,
                oldId     = oldId,
            })
        end
    end

    return addedItems, removedItemIds, equippedChanges
end

-- 缓存每个玩家上一次的快照
local lastStateByPlayer = {}
-- 玩家离开清空快照缓存
Players.PlayerRemoving:Connect(function(player)
    lastStateByPlayer[player] = nil
end)

-- 监听 BackpackModule 变化：同步给客户端
BackpackModule.onChanged(function(player, snapshot)
    if not player or not player.Parent then
        return
    end
    -- BackpackModule 已经保证 snapshot 是深拷贝，这里再 shallow 一层，以防后面误改
    local newState = shallowCopyState(snapshot)
    local oldState = lastStateByPlayer[player]
    -- 第一次看到这个玩家：直接发全量
    if not oldState then
        lastStateByPlayer[player] = newState
        dprint("%s Backpack 首次同步，发送全量快照", player.Name)
        RE_S2C_Full:FireClient(player, newState)
        return
    end
    local addedItems, removedIds, equipChanges = diffStates(oldState, newState)
    lastStateByPlayer[player] = newState
    -- 有新增物品
    if #addedItems > 0 then
        dprint("%s Backpack 新增物品 %d 个", player.Name, #addedItems)
        RE_S2C_ItemsAdded:FireClient(player, addedItems)
    end
    -- 有删除物品
    if #removedIds > 0 then
        dprint("%s Backpack 删除物品 %d 个", player.Name, #removedIds)
        RE_S2C_ItemsRemoved:FireClient(player, removedIds)
    end
    -- 槽位变化
    for _, change in ipairs(equipChanges) do
        dprint("%s Backpack 槽位变化 slot=%s index=%d old=%s new=%s",
            player.Name,
            tostring(change.slotName),
            change.slotIndex,
            tostring(change.oldId),
            tostring(change.newId)
        )
        RE_S2C_Equipped:FireClient(player, change.slotName, change.slotIndex, change.newId, change.oldId)
        -- 新增：驱动服务器挂/卸装备外观
        local newItem = nil
        if change.newId and change.newId ~= "" then
            newItem = newState.backpack[change.newId]
        end
        BackpackAppearance.applyEquipChange(player, change.slotName, newItem)
    end
end)

BackpackAppearance.init() -- 根据背包渲染玩家装备初始化

-- C-S：客户端请求全量同步 
RE_CS_RequestFull.OnServerEvent:Connect(function(player)
    local snap = BackpackModule.getAll(player)
    lastStateByPlayer[player] = shallowCopyState(snap)
    dprint("%s 主动请求 Backpack 全量同步", player.Name)
    RE_S2C_Full:FireClient(player, snap)
end)

-- C-S：穿戴单个装备 
RE_CS_Equip.OnServerEvent:Connect(function(player, itemId)
    if type(itemId) ~= "string" or #itemId == 0 then
        -- 英文提示给玩家
        sendMsg(player, "Invalid equipment.", true)
        return
    end

    local ok, slotName, prevId = BackpackModule.equip(player, itemId, "client_equip")
    if not ok then
        sendMsg(player, "Cannot equip this item.", true)
        return
    end

    -- 真正的 UI 更新交给 onChanged → diff → [S-C]BackpackEquippedChanged
    local tip = string.format("Equipped slot %s.", tostring(slotName))
    sendMsg(player, tip, false)
end)

-- C-S：脱下单个装备（按槽位）
RE_CS_Unequip.OnServerEvent:Connect(function(player, slotName)
    dprint("收到卸下请求，玩家=%s, slotName=%s", player.Name, tostring(slotName))

    if type(slotName) ~= "string" or #slotName == 0 then
        sendMsg(player, "Invalid slot.", true)
        return
    end

    local ok, removedId
    local success, err = pcall(function()
        ok, removedId = BackpackModule.unequipSlot(player, slotName, "client_unequip")
    end)

    if not success then
        warn(("[BackpackServer] unequipSlot 运行时错误：%s"):format(tostring(err)))
        sendMsg(player, "Internal error when unequipping.", true)
        return
    end

    if not ok then
        dprint("卸下失败：槽位本来就是空的，slot=%s", tostring(slotName))
        sendMsg(player, "No equipment to unequip in this slot.", true)
        return
    end

    local tip = string.format("Unequipped slot %s.", tostring(slotName))
    dprint("卸下成功：slot=%s, removedId=%s", tostring(slotName), tostring(removedId))
    sendMsg(player, tip, false)
end)
