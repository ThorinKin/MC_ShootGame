-- ServerScriptService/Server/PetService/PetModule.lua
-- 总注释：Pet 系统模块。主管业务，DataStore2 仅动 cache
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化

----------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[PetModule] " .. string.format(fmt, ...))
    end
end

-- 槽位配置
local MAX_SLOTS = 5  -- 最大可解锁槽位数

-- 默认值结构：
--   backpack: [petId] = { id, kind, name, attrs }
--   equipped: [index] = { unlocked = bool, id = petId|nil }
local DEFAULT = {
    backpack = {},
    equipped = {},
}
table.freeze(DEFAULT)
----------------------------------------------------------------

-- 工具：生成宠物唯一 id
local function newPetId()
    return HttpService:GenerateGUID(false)
end

-- 工具：DataStore2 句柄
local function getStore(player)
    return DataStore2(StoreRegistry.Pet, player)
end

-- 工具：规范化宠物表结构
-- 期望结构：
-- {
--   id    = string,
--   kind  = string, -- 宠物类型，指定使用哪个具体的宠物模型
--   name  = string, -- 显示名，可为空串
--   attrs = table,  -- 任意属性表
-- }
local function normalizePet(raw)
    if typeof(raw) ~= "table" then
        return nil
    end

    local id = tostring(raw.id or "")
    if id == "" then
        return nil
    end

    local kind = tostring(raw.kind or "")
    if kind == "" then
        kind = "pet"
    end

    local name = raw.name
    if name ~= nil then
        name = tostring(name)
    else
        name = ""
    end

    local attrs = raw.attrs
    if typeof(attrs) ~= "table" then
        attrs = {}
    end

    return {
        id    = id,
        kind  = kind,
        name  = name,
        attrs = attrs,
    }
end

-- 工具：深拷贝宠物，防止外部误改内部状态
local function clonePet(pet)
    if not pet then
        return nil
    end

    local attrsCopy = {}
    if typeof(pet.attrs) == "table" then
        for k, v in pairs(pet.attrs) do
            attrsCopy[k] = v
        end
    end

    return {
        id    = pet.id,
        kind  = pet.kind,
        name  = pet.name,
        attrs = attrsCopy,
    }
end

-- 工具：深拷贝整个状态
local function cloneState(state)
    local copy = {
        backpack = {},
        equipped = {},
    }

    for id, pet in pairs(state.backpack) do
        copy.backpack[id] = clonePet(pet)
    end

    for index, slot in pairs(state.equipped) do
        copy.equipped[index] = {
            unlocked = not not slot.unlocked,
            id       = slot.id,
        }
    end

    return copy
end

-- 工具：修正整体数据 shape，防止旧档/脏数据
local function ensureShape(data)
    local src = (typeof(data) == "table") and data or {}

    local state = {
        backpack = {},
        equipped = {},
    }

    -- 修正 backpack：把能读出来的宠物全部塞入 map（以 id 为 key）
    local rawBackpack = src.backpack
    if typeof(rawBackpack) == "table" then
        for _, v in pairs(rawBackpack) do
            local pet = normalizePet(v)
            if pet then
                state.backpack[pet.id] = pet
            end
        end
    end

    -- 修正 equipped：1 ~ MAX_SLOTS，每个槽位带 unlocked + id
    local rawEquipped = src.equipped
    if typeof(rawEquipped) ~= "table" then
        rawEquipped = {}
    end

    for i = 1, MAX_SLOTS do
        local slot = rawEquipped[i]
        local unlocked = false
        local petId    = nil

        if typeof(slot) == "table" then
            unlocked = not not slot.unlocked
            local rawId = slot.id
            if type(rawId) == "string" and rawId ~= "" and state.backpack[rawId] then
                petId = rawId
            end
        end

        -- 新玩家保证第一个槽位必定解锁
        if i == 1 and not unlocked then
            unlocked = true
        end

        state.equipped[i] = {
            unlocked = unlocked,
            id       = petId,
        }
    end

    return state
end

-- 变更事件：给 UI / 其他服务用
local changedBE = Instance.new("BindableEvent")
local PetModule = {}
PetModule.MAX_SLOTS = MAX_SLOTS

function PetModule.onChanged(cb) -- cb(player, snapshotTable)
    return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStore2 写回 cache
local function commit(player, state, reason)
    local store = getStore(player)
    store:Set(state)

    -- 对外发深拷贝快照，避免外部误改
    changedBE:Fire(player, cloneState(state))

    -- 调试日志：只打数量和装备情况
    local count = 0
    for _ in pairs(state.backpack) do
        count += 1
    end

    dprint("%s Pet commit（%s）→ count=%d",
        player.Name,
        reason or "无原因",
        count
    )

    return state
end

local function mutate(player, reason, mutator)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    mutator(state)
    state = ensureShape(state)
    return commit(player, state, reason)
end

-- 对外 API ----------------------------------------------------↓

-- 初始化：只保证数据 shape 正常，顺带发一次 changed 方便 UI 初始化
function PetModule.initPlayer(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "init")
    return cloneState(state)
end

-- 确保已初始化（手动补档时用）
function PetModule.ensureInitialized(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "ensureInit")
    return cloneState(state)
end

-- 读全部：返回整份快照
function PetModule.getAll(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return cloneState(state)
end

-- 读背包：返回 [petId] = petTable
function PetModule.getBackpack(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local snap = cloneState(state)
    return snap.backpack
end

-- 读已装备：返回 [index] = { unlocked = bool, id = petId|nil }
function PetModule.getEquipped(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local snap = cloneState(state)
    return snap.equipped
end

-- 查询：是否拥有某只宠物（按 id）
function PetModule.hasPet(player, petId)
    if type(petId) ~= "string" or #petId == 0 then
        return false
    end
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state.backpack[petId] ~= nil
end

-- 查询：获取某只宠物详情（快照）
function PetModule.getPet(player, petId)
    if type(petId) ~= "string" or #petId == 0 then
        return nil
    end

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local pet = state.backpack[petId]
    if not pet then
        return nil
    end

    return clonePet(pet)
end

-- 查询：按 kind 获取所有宠物 id 列表
function PetModule.getPetsByKind(player, kind)
    kind = tostring(kind or "")
    if kind == "" then
        return {}
    end

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))

    local result = {}
    for id, pet in pairs(state.backpack) do
        if pet.kind == kind then
            table.insert(result, id)
        end
    end

    return result
end

-- 查询：已解锁槽位数
function PetModule.getUnlockedSlotCount(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local count = 0
    for i = 1, MAX_SLOTS do
        local slot = state.equipped[i]
        if slot and slot.unlocked then
            count += 1
        end
    end
    return count
end

-- 获得宠物：
--   info = {
--      kind  = string, -- 宠物类型
--      name  = string?, -- 显示名
--      attrs = table?,  -- 任意属性表（暂不关心具体结构）
--   }
-- 返回：petId, petSnapshot
function PetModule.givePet(player, info, reason)
    assert(typeof(info) == "table", "[PetModule] info 必须为 table")

    local attrs = {}
    if typeof(info.attrs) == "table" then
        for k, v in pairs(info.attrs) do
            attrs[k] = v
        end
    end

    local newPet = {
        id    = newPetId(),
        kind  = tostring(info.kind or "pet"),
        name  = tostring(info.name or ""),
        attrs = attrs,
    }

    local state = mutate(player, "givePet " .. (reason or ""), function(s)
        s.backpack[newPet.id] = newPet
    end)

    dprint("%s 获得宠物 %s（kind=%s, name=%s，%s）",
        player.Name, newPet.id, newPet.kind, newPet.name, reason or "无原因")

    local pet = state.backpack[newPet.id]
    return newPet.id, clonePet(pet)
end

-- 删除宠物：同时清理装备槽中引用
-- 返回：ok:boolean
function PetModule.removePet(player, petId, reason)
    assert(type(petId) == "string" and #petId > 0, "[PetModule] petId 必须为非空字符串")

    local removed = false

    mutate(player, "removePet " .. (reason or ""), function(s)
        if not s.backpack[petId] then
            return
        end

        s.backpack[petId] = nil
        removed = true

        for i = 1, MAX_SLOTS do
            local slot = s.equipped[i]
            if slot and slot.id == petId then
                slot.id = nil
            end
        end
    end)

    if removed then
        dprint("%s 移除宠物 %s（%s）", player.Name, petId, reason or "无原因")
    else
        dprint("%s 移除宠物失败，未找到 %s（%s）", player.Name, petId, reason or "无原因")
    end

    return removed
end

-- 穿戴宠物：
--   petId: string
--   slotIndex: number? （nil 时自动找第一个解锁且为空的槽）
-- 返回：ok:boolean, usedIndex:number|nil, prevPetId:string|nil, errCode:string|nil
function PetModule.equip(player, petId, slotIndex, reason)
    assert(type(petId) == "string" and #petId > 0, "[PetModule] petId 必须为非空字符串")

    local ok      = false
    local usedIdx = nil
    local prevId  = nil
    local errCode = nil

    mutate(player, "equip " .. (reason or ""), function(s)
        local pet = s.backpack[petId]
        if not pet then
            errCode = "not_owned"
            return
        end

        local idx

        if slotIndex ~= nil then
            local n = tonumber(slotIndex)
            n = n and math.floor(n)
            if not n or n < 1 or n > MAX_SLOTS then
                errCode = "invalid_slot"
                return
            end
            local slot = s.equipped[n]
            if not slot or not slot.unlocked then
                errCode = "slot_locked"
                return
            end
            idx = n
        else
            -- 自动模式：找第一个解锁 & 空的槽位
            for i = 1, MAX_SLOTS do
                local slot = s.equipped[i]
                if slot and slot.unlocked and slot.id == nil then
                    idx = i
                    break
                end
            end
            if not idx then
                errCode = "no_free_slot"
                return
            end
        end

        local slot = s.equipped[idx]
        prevId = slot.id
        slot.id = petId

        usedIdx = idx
        ok = true
    end)

    if not ok then
        return false, nil, nil, errCode
    end

    dprint("%s 装备宠物 %s → 槽位 %d（原先 %s）（%s）",
        player.Name, petId, usedIdx, tostring(prevId), reason or "无原因")

    return true, usedIdx, prevId, nil
end

-- 脱下：按槽位卸下（不会删宠物，只是从 equipped 清掉）
-- 返回：ok:boolean, removedPetId:string|nil
function PetModule.unequipSlot(player, slotIndex, reason)
    local idx = tonumber(slotIndex)
    assert(idx and idx >= 1 and idx <= MAX_SLOTS, "[PetModule] 非法的槽位索引")
    idx = math.floor(idx)

    local removedId

    mutate(player, "unequipSlot " .. (reason or ""), function(s)
        local slot = s.equipped[idx]
        if not slot or not slot.unlocked then
            return
        end

        removedId = slot.id
        slot.id = nil
    end)

    if removedId then
        dprint("%s 卸下宠物槽位 %d 中宠物 %s（%s）", player.Name, idx, removedId, reason or "无原因")
        return true, removedId
    else
        dprint("%s 卸下宠物槽位 %d 失败：原本为空或未解锁（%s）",
            player.Name, idx, reason or "无原因")
        return false, nil
    end
end

-- 脱下：按宠物 id 卸下
-- 返回：ok:boolean, slotIndex:number|nil
function PetModule.unequipPet(player, petId, reason)
    assert(type(petId) == "string" and #petId > 0, "[PetModule] petId 必须为非空字符串")

    local clearedIdx

    mutate(player, "unequipPet " .. (reason or ""), function(s)
        for i = 1, MAX_SLOTS do
            local slot = s.equipped[i]
            if slot and slot.id == petId then
                slot.id = nil
                clearedIdx = i
                break
            end
        end
    end)

    if clearedIdx then
        dprint("%s 卸下宠物 %s（槽位 %d）（%s）",
            player.Name, petId, clearedIdx, reason or "无原因")
        return true, clearedIdx
    else
        dprint("%s 卸下宠物失败，宠物 %s 未处于装备状态（%s）",
            player.Name, petId, reason or "无原因")
        return false, nil
    end
end

-- 解锁指定槽位
-- 返回：ok:boolean, slotIndex:number
function PetModule.unlockSlot(player, slotIndex, reason)
    local idx = tonumber(slotIndex)
    assert(idx and idx >= 1 and idx <= MAX_SLOTS, "[PetModule] 非法的槽位索引")
    idx = math.floor(idx)

    local unlocked = false

    mutate(player, "unlockSlot " .. (reason or ""), function(s)
        local slot = s.equipped[idx]
        if not slot then
            s.equipped[idx] = {
                unlocked = true,
                id       = nil,
            }
            unlocked = true
            return
        end

        if slot.unlocked then
            unlocked = false
            return
        end

        slot.unlocked = true
        unlocked = true
    end)

    if unlocked then
        dprint("%s 解锁宠物槽位 %d（%s）", player.Name, idx, reason or "无原因")
        return true, idx
    else
        dprint("%s 解锁宠物槽位失败：槽位 %d 已解锁（%s）", player.Name, idx, reason or "无原因")
        return false, idx
    end
end

-- 解锁下一个锁定槽位
-- 返回：ok:boolean, slotIndex:number|nil
function PetModule.unlockNextSlot(player, reason)
    local targetIdx

    mutate(player, "unlockNextSlot " .. (reason or ""), function(s)
        for i = 1, MAX_SLOTS do
            local slot = s.equipped[i]
            if not slot or not slot.unlocked then
                if not slot then
                    s.equipped[i] = {
                        unlocked = true,
                        id       = nil,
                    }
                else
                    slot.unlocked = true
                end
                targetIdx = i
                break
            end
        end
    end)

    if targetIdx then
        dprint("%s 解锁下一个宠物槽位 → %d（%s）", player.Name, targetIdx, reason or "无原因")
        return true, targetIdx
    else
        dprint("%s 解锁下一个宠物槽位失败：已无可解锁槽位（%s）",
            player.Name, reason or "无原因")
        return false, nil
    end
end

return PetModule
