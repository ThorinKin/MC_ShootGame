-- ServerScriptService/Server/BackpackService/BackpackModule.lua
-- 总注释：Backpack 系统模块。主管业务，DataStore2 仅动 cache
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
        warn("[BackpackModule] " .. string.format(fmt, ...))
    end
end

-- 槽位 / 大类枚举（头、甲、武器、投掷物）
local ITEM_TYPE = {
    Helmet    = "helmet",    -- 头
    Armor     = "armor",     -- 甲（身体护甲）
    Weapon    = "weapon",    -- 主武器（枪）
    Throwable = "throwable", -- 投掷物（手雷等）
}
table.freeze(ITEM_TYPE)

-- 固定槽位顺序：equipped 一个数组
local SLOT_ORDER = {
    ITEM_TYPE.Helmet,
    ITEM_TYPE.Armor,
    ITEM_TYPE.Weapon,
    ITEM_TYPE.Throwable,
}

-- 默认值结构：
--   backpack: [itemId] = { id, type, subType, attrs }
--   equipped: 数组，每个元素 { slot = "helmet"/... , id = itemId|nil }
local DEFAULT = {
    backpack = {},
    equipped = {},
}
table.freeze(DEFAULT)
----------------------------------------------------------------

-- 工具：槽位名归一化
local function normalizeSlotName(slot)
    slot = string.lower(tostring(slot or ""))

    -- 头
    if slot == "helmet" or slot == "head" then
        return "helmet"
    end

    -- 甲
    if slot == "armor" or slot == "armour" or slot == "clothes" or slot == "body" then
        return "armor"
    end

    -- 主武器
    if slot == "weapon" or slot == "gun" or slot == "primary" then
        return "weapon"
    end

    -- 投掷物
    if slot == "throwable" or slot == "grenade" or slot == "nade" or slot == "throw" then
        return "throwable"
    end

    return nil
end

-- 工具：由物品大类型决定槽位（目前一一对应）
local function slotForType(itemType)
    return normalizeSlotName(itemType)
end

-- 工具：生成物品唯一 id
local function newItemId()
    -- GUID 字符串即可，玩家内唯一
    return HttpService:GenerateGUID(false)
end

-- 工具：DataStore2 句柄
local function getStore(player)
    return DataStore2(StoreRegistry.Backpack, player)
end

-- 工具：规范化单件物品表结构
-- {
--   id      = string,
--   type    = "helmet"|"armor"|"weapon"|"throwable",
--   subType = string,
--   attrs   = table, -- 目前不关心具体内容，方案没给
-- }
local function normalizeItem(raw)
    if typeof(raw) ~= "table" then
        return nil
    end

    local id = tostring(raw.id or "")
    if id == "" then
        return nil
    end

    local t = raw.type or raw.slot
    local slot = slotForType(t)
    if not slot then
        return nil
    end

    local subType = raw.subType
    if subType == nil then
        subType = ""
    else
        subType = tostring(subType)
    end

    local attrs = raw.attrs
    if typeof(attrs) ~= "table" then
        attrs = {}
    end

    return {
        id      = id,
        type    = slot,   -- 按槽位名存
        subType = subType,
        attrs   = attrs,
    }
end

-- 工具：深拷贝单件物品，防止外部误改内部状态
local function cloneItem(item)
    if not item then
        return nil
    end

    local attrsCopy = {}
    if typeof(item.attrs) == "table" then
        for k, v in pairs(item.attrs) do
            attrsCopy[k] = v
        end
    end

    return {
        id      = item.id,
        type    = item.type,
        subType = item.subType,
        attrs   = attrsCopy,
    }
end

-- 工具：深拷贝整个状态
local function cloneState(state)
    local copy = {
        backpack = {},
        equipped = {},
    }

    for id, item in pairs(state.backpack) do
        copy.backpack[id] = cloneItem(item)
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

-- 工具：修正整体数据 shape，防止旧档/脏数据
local function ensureShape(data)
    local src = (typeof(data) == "table") and data or {}

    local state = {
        backpack = {},
        equipped = {},
    }

    -- 把能读出来的物品全部塞入 map（以 id 为 key）
    local rawBackpack = src.backpack
    if typeof(rawBackpack) == "table" then
        for _, v in pairs(rawBackpack) do
            local item = normalizeItem(v)
            if item then
                state.backpack[item.id] = item
            end
        end
    end

    -- equipped：兼容字典和数组
    -- 目标结构：数组，每个元素 { slot = "helmet"/... , id = itemId|nil }
    local rawEquipped = src.equipped
    if typeof(rawEquipped) ~= "table" then
        rawEquipped = {}
    end

    local tempMap = {} -- slotName -> itemId

    -- 先判断是不是字典
    local hasStringKey = false
    for k, _ in pairs(rawEquipped) do
        if type(k) == "string" then
            hasStringKey = true
            break
        end
    end

    if hasStringKey then
        -- 字典
        for _, slotName in ipairs(SLOT_ORDER) do
            local rawId = rawEquipped[slotName]
            if type(rawId) == "string" and state.backpack[rawId] then
                tempMap[slotName] = rawId
            end
        end
    else
        -- 数组
        for _, slot in pairs(rawEquipped) do
            if typeof(slot) == "table" then
                local name = normalizeSlotName(slot.slot)
                if name then
                    local rawId = slot.id
                    if type(rawId) == "string" and state.backpack[rawId] then
                        tempMap[name] = rawId
                    end
                end
            end
        end
    end

    -- 按固定顺序生成数组结构
    for i, slotName in ipairs(SLOT_ORDER) do
        local id = tempMap[slotName]
        state.equipped[i] = {
            slot = slotName,
            id   = id or nil,
        }
    end

    return state
end

-- 工具：在 state.equipped 里按槽位名查找 index 和 slot 表
local function findSlotByName(equipped, slotName)
    if not equipped then
        return nil, nil
    end
    for i, slot in ipairs(equipped) do
        if slot.slot == slotName then
            return i, slot
        end
    end
    return nil, nil
end

-- 变更事件：给 UI / 其他服务用
local changedBE = Instance.new("BindableEvent")
local BackpackModule = {}
BackpackModule.ITEM_TYPE = ITEM_TYPE

function BackpackModule.onChanged(cb) -- cb(player, snapshotTable)
    return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStore2 写回 cache
local function commit(player, state, reason)
    local store = getStore(player)
    store:Set(state)

    -- 对外发深拷贝快照，避免外部误改
    changedBE:Fire(player, cloneState(state))

    -- 调试日志：别把完整 attrs 打出来，简单看一下数量和装备情况就行
    local count = 0
    for _ in pairs(state.backpack) do
        count += 1
    end

    dprint("%s Backpack commit（%s）→ count=%d, equipped=%s",
        player.Name,
        reason or "无原因",
        count,
        HttpService:JSONEncode(state.equipped)
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

-- 对外 API ----------------------------------------------------------↓

-- 初始化：只保证数据 shape 正常，顺带发一次 changed 方便 UI 初始化
function BackpackModule.initPlayer(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "init")
    return cloneState(state)
end

-- 确保已初始化（手动补档时用）
function BackpackModule.ensureInitialized(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "ensureInit")
    return cloneState(state)
end

-- 读全部：返回整份快照
function BackpackModule.getAll(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return cloneState(state)
end

-- 读背包：返回 [itemId] = itemTable
function BackpackModule.getBackpack(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local snap = cloneState(state)
    return snap.backpack
end

-- 读已装备：返回数组 [{ slot="helmet", id=itemId|nil }, ...]
function BackpackModule.getEquipped(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local snap = cloneState(state)
    return snap.equipped
end

-- 查询：是否拥有某件物品（按 id）
function BackpackModule.hasItem(player, itemId)
    if type(itemId) ~= "string" or #itemId == 0 then
        return false
    end
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return state.backpack[itemId] ~= nil
end

-- 查询：获取某件物品详情（快照）
function BackpackModule.getItem(player, itemId)
    if type(itemId) ~= "string" or #itemId == 0 then
        return nil
    end

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local item = state.backpack[itemId]
    if not item then
        return nil
    end

    return cloneItem(item)
end

-- 查询：按大类型获取所有物品 id 列表
function BackpackModule.getItemsByType(player, itemType)
    local slot = slotForType(itemType)
    if not slot then
        return {}
    end

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))

    local result = {}
    for id, item in pairs(state.backpack) do
        if item.type == slot then
            table.insert(result, id)
        end
    end

    return result
end

-- 获得物品：
--   info = {
--      type    = "helmet"/"armor"/"weapon"/"throwable",
--      subType = string?         -- 小类型，随便填
--      attrs   = table?          -- 属性表
--   }
-- 返回：itemId, itemSnapshot
function BackpackModule.giveItem(player, info, reason)
    assert(typeof(info) == "table", "[BackpackModule] info 必须为 table")

    local slot = slotForType(info.type)
    assert(slot, "[BackpackModule] 非法的物品大类")

    local attrs = {}
    if typeof(info.attrs) == "table" then
        for k, v in pairs(info.attrs) do
            attrs[k] = v
        end
    end

    local newItem = {
        id      = newItemId(),
        type    = slot,
        subType = tostring(info.subType or ""),
        attrs   = attrs,
    }

    local state = mutate(player, "giveItem " .. (reason or ""), function(s)
        s.backpack[newItem.id] = newItem
    end)

    dprint("%s 获得物品 %s（type=%s, subType=%s，%s）",
        player.Name, newItem.id, newItem.type, newItem.subType, reason or "无原因")

    -- 从最新 state 里再拿一份，保证返回的是最终形态
    local item = state.backpack[newItem.id]
    return newItem.id, cloneItem(item)
end

-- 失去（删除）物品：同时清理已装备中引用
-- 返回：ok:boolean
function BackpackModule.removeItem(player, itemId, reason)
    assert(type(itemId) == "string" and #itemId > 0, "[BackpackModule] itemId 必须为非空字符串")

    local removed = false

    mutate(player, "removeItem " .. (reason or ""), function(s)
        if not s.backpack[itemId] then
            return
        end

        s.backpack[itemId] = nil
        removed = true

        for _, slot in ipairs(s.equipped) do
            if slot.id == itemId then
                slot.id = nil
            end
        end
    end)

    if removed then
        dprint("%s 移除物品 %s（%s）", player.Name, itemId, reason or "无原因")
    else
        dprint("%s 移除物品失败，未找到 %s（%s）", player.Name, itemId, reason or "无原因")
    end

    return removed
end

-- 穿戴：从背包中装备到对应槽位（如果该槽已有装备，则替换）
-- 返回：ok:boolean, slotName:string|nil, prevItemId:string|nil
function BackpackModule.equip(player, itemId, reason)
    assert(type(itemId) == "string" and #itemId > 0, "[BackpackModule] itemId 必须为非空字符串")

    local slotName
    local prevId

    mutate(player, "equip " .. (reason or ""), function(s)
        local item = s.backpack[itemId]
        if not item then
            return
        end

        local slot = slotForType(item.type)
        if not slot then
            return
        end

        local _, slotRecord = findSlotByName(s.equipped, slot)
        if not slotRecord then
            return
        end

        slotName = slot
        prevId = slotRecord.id
        slotRecord.id = itemId
    end)

    if not slotName then
        dprint("%s 装备物品失败 %s（%s）", player.Name, itemId, reason or "无原因")
        return false, nil, nil
    end

    dprint("%s 装备物品 %s → 槽位 %s（原先 %s）（%s）",
        player.Name, itemId, slotName, tostring(prevId), reason or "无原因")

    return true, slotName, prevId
end

-- 脱下：按槽位卸下（不会删物品，只是从 equipped 清掉）
-- 返回：ok:boolean, removedItemId:string|nil
function BackpackModule.unequipSlot(player, slot, reason)
    local norm = normalizeSlotName(slot)
    assert(norm, "[BackpackModule] 非法的槽位")

    local removedId

    mutate(player, "unequipSlot " .. (reason or ""), function(s)
        local _, slotRecord = findSlotByName(s.equipped, norm)
        if not slotRecord then
            return
        end
        removedId = slotRecord.id
        slotRecord.id = nil
    end)

    if removedId then
        dprint("%s 卸下槽位 %s 中物品 %s（%s）", player.Name, norm, removedId, reason or "无原因")
        return true, removedId
    else
        dprint("%s 卸下槽位 %s 失败：原本为空（%s）", player.Name, norm, reason or "无原因")
        return false, nil
    end
end

-- 脱下：按物品 id 卸下
-- 返回：ok:boolean, slotName:string|nil
function BackpackModule.unequipItem(player, itemId, reason)
    assert(type(itemId) == "string" and #itemId > 0, "[BackpackModule] itemId 必须为非空字符串")

    local clearedSlot

    mutate(player, "unequipItem " .. (reason or ""), function(s)
        for _, slot in ipairs(s.equipped) do
            if slot.id == itemId then
                slot.id = nil
                clearedSlot = slot.slot
                break
            end
        end
    end)

    if clearedSlot then
        dprint("%s 卸下物品 %s（槽位 %s）（%s）", player.Name, itemId, clearedSlot, reason or "无原因")
        return true, clearedSlot
    else
        dprint("%s 卸下物品失败，物品 %s 未处于装备状态（%s）", player.Name, itemId, reason or "无原因")
        return false, nil
    end
end

return BackpackModule
