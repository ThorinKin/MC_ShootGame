-- ServerScriptService/Server/PetService/PetServer.server.lua
-- 总注释：Pet 数据同步给客户端、处理穿戴 / 解锁请求等 远程事件处理
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[PetServer] " .. string.format(fmt, ...))
    end
end

local PetModule = require(ServerScriptService.Server.PetService.PetModule)
local MAX_SLOTS = PetModule.MAX_SLOTS

-- 远程事件
local RemotesRoot    = ReplicatedStorage:WaitForChild("Remotes")
local PetRemotes     = RemotesRoot:WaitForChild("Pet")
-- S-C：单播给玩家
local RE_S2C_Full        = PetRemotes:WaitForChild("[S-C]PetFull")
local RE_S2C_PetsAdded   = PetRemotes:WaitForChild("[S-C]PetAdded")
local RE_S2C_PetsRemoved = PetRemotes:WaitForChild("[S-C]PetRemoved")
local RE_S2C_Equipped    = PetRemotes:WaitForChild("[S-C]PetEquippedChanged")
-- C-S：客户端请求
local RE_CS_Equip        = PetRemotes:WaitForChild("[C-S]PetEquip")
local RE_CS_Unequip      = PetRemotes:WaitForChild("[C-S]PetUnequip")
local RE_CS_RequestFull  = PetRemotes:WaitForChild("[C-S]PetRequestFull")
local RE_CS_UnlockSlot   = PetRemotes:WaitForChild("[C-S]PetUnlockSlot")
local RE_CS_UnlockNext   = PetRemotes:WaitForChild("[C-S]PetUnlockNext")
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
        for id, pet in pairs(state.backpack) do
            copy.backpack[id] = pet
        end
    end

    if state.equipped then
        for idx, slot in pairs(state.equipped) do
            copy.equipped[idx] = {
                unlocked = not not slot.unlocked,
                id       = slot.id,
            }
        end
    end

    return copy
end

-- 工具：diff 新旧状态，算出新增/删除/槽位变化
local function diffStates(oldState, newState)
    local addedPets     = {}
    local removedPetIds = {}
    local slotChanges   = {}

    local oldBackpack = (oldState and oldState.backpack) or {}
    local newBackpack = newState.backpack or {}

    -- 新增宠物
    for id, pet in pairs(newBackpack) do
        if not oldBackpack[id] then
            table.insert(addedPets, pet)
        end
    end

    -- 删除宠物
    if oldState then
        for id, _ in pairs(oldBackpack) do
            if not newBackpack[id] then
                table.insert(removedPetIds, id)
            end
        end
    end

    -- 槽位变化（unlocked / id 任一变化都算）
    local oldEquipped = (oldState and oldState.equipped) or {}
    local newEquipped = newState.equipped or {}

    for i = 1, MAX_SLOTS do
        local o = oldEquipped[i]
        local n = newEquipped[i]

        local oldUnlocked = o and o.unlocked or (i == 1)
        local newUnlocked = n and n.unlocked or (i == 1)
        local oldId       = o and o.id or nil
        local newId       = n and n.id or nil

        if oldUnlocked ~= newUnlocked or oldId ~= newId then
            table.insert(slotChanges, {
                index       = i,
                newId       = newId,
                oldId       = oldId,
                newUnlocked = newUnlocked,
                oldUnlocked = oldUnlocked,
            })
        end
    end

    return addedPets, removedPetIds, slotChanges
end

-- 缓存每个玩家上一次的快照
local lastStateByPlayer = {}
-- 玩家离开清空快照缓存
Players.PlayerRemoving:Connect(function(player)
    lastStateByPlayer[player] = nil
end)

-- 监听 PetModule 变化：同步给客户端
PetModule.onChanged(function(player, snapshot)
    if not player or not player.Parent then
        return
    end

    -- PetModule 已经保证 snapshot 是深拷贝，这里再 shallow 一层，以防后面误改
    local newState = shallowCopyState(snapshot)
    local oldState = lastStateByPlayer[player]

    -- 第一次看到这个玩家：直接发全量
    if not oldState then
        lastStateByPlayer[player] = newState
        dprint("%s Pet 首次同步，发送全量快照", player.Name)
        RE_S2C_Full:FireClient(player, newState)
        return
    end

    local addedPets, removedIds, slotChanges = diffStates(oldState, newState)
    lastStateByPlayer[player] = newState

    -- 有新增宠物
    if #addedPets > 0 then
        dprint("%s Pet 新增宠物 %d 只", player.Name, #addedPets)
        RE_S2C_PetsAdded:FireClient(player, addedPets)
    end

    -- 有删除宠物
    if #removedIds > 0 then
        dprint("%s Pet 删除宠物 %d 只", player.Name, #removedIds)
        RE_S2C_PetsRemoved:FireClient(player, removedIds)
    end

    -- 槽位变化（包含解锁和装备变化）
    for _, change in ipairs(slotChanges) do
        dprint("%s Pet 槽位变化 index=%d old=%s new=%s unlocked=%s",
            player.Name,
            change.index,
            tostring(change.oldId),
            tostring(change.newId),
            tostring(change.newUnlocked)
        )
        -- 第四个参数 newUnlocked，方便前端同步 UI 状态
        RE_S2C_Equipped:FireClient(player, change.index, change.newId, change.oldId, change.newUnlocked)
    end
end)

-- C-S：客户端请求全量同步
RE_CS_RequestFull.OnServerEvent:Connect(function(player)
    local snap = PetModule.getAll(player)
    lastStateByPlayer[player] = shallowCopyState(snap)
    dprint("%s 主动请求 Pet 全量同步", player.Name)
    RE_S2C_Full:FireClient(player, snap)
end)

-- C-S：穿戴宠物
-- 参数：petId:string, slotIndex:number? （可为空，nil = 自动找空槽）
RE_CS_Equip.OnServerEvent:Connect(function(player, petId, slotIndex)
    if type(petId) ~= "string" or #petId == 0 then
        sendMsg(player, "Invalid pet.", true)
        return
    end

    if slotIndex ~= nil and type(slotIndex) ~= "number" then
        slotIndex = nil
    end

    local ok, idx, prevId, errCode = PetModule.equip(player, petId, slotIndex, "client_equip")
    if not ok then
        local msg = "Cannot equip this pet."
        if errCode == "not_owned" then
            msg = "You don't own this pet."
        elseif errCode == "slot_locked" then
            msg = "This slot is locked."
        elseif errCode == "no_free_slot" then
            msg = "No free pet slot."
        elseif errCode == "invalid_slot" then
            msg = "Invalid pet slot."
        end
        sendMsg(player, msg, true)
        return
    end

    local tip = string.format("Pet equipped in slot %d.", idx)
    sendMsg(player, tip, false)
    -- 真正的 UI 更新交给 onChanged → diff → [S-C]PetEquippedChanged
end)

-- C-S：按槽位脱下宠物
RE_CS_Unequip.OnServerEvent:Connect(function(player, slotIndex)
    if type(slotIndex) ~= "number" then
        sendMsg(player, "Invalid pet slot.", true)
        return
    end

    local ok, removedId = PetModule.unequipSlot(player, slotIndex, "client_unequip")
    if not ok then
        sendMsg(player, "No pet to unequip in this slot.", true)
        return
    end

    local tip = string.format("Unequipped pet from slot %d.", math.floor(slotIndex))
    sendMsg(player, tip, false)
end)

-- C-S：解锁指定槽位
RE_CS_UnlockSlot.OnServerEvent:Connect(function(player, slotIndex)
    if type(slotIndex) ~= "number" then
        sendMsg(player, "Invalid pet slot.", true)
        return
    end

    local ok, idx = PetModule.unlockSlot(player, slotIndex, "client_unlock")
    if not ok then
        sendMsg(player, "This pet slot is already unlocked.", true)
        return
    end

    local tip = string.format("Pet slot %d unlocked.", idx)
    sendMsg(player, tip, false)
end)

-- C-S：解锁下一个宠物槽位
RE_CS_UnlockNext.OnServerEvent:Connect(function(player)
    local ok, idx = PetModule.unlockNextSlot(player, "client_unlock_next")
    if not ok then
        sendMsg(player, "No more pet slots to unlock.", true)
        return
    end

    local tip = string.format("Pet slot %d unlocked.", idx)
    sendMsg(player, tip, false)
end)
