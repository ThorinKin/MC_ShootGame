-- ServerScriptService/Server/BackpackService/BackpackAppearance.lua
-- 总注释：根据背包装备状态，把武器 / 防具 / 头盔 / 投掷物挂到玩家模型上
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local BackpackModule = require(ServerScriptService.Server.BackpackService.BackpackModule)

-- 资产路径：
-- ReplicatedStorage/Assets/Weapons/<subType>         -- Tool
-- ReplicatedStorage/Assets/Armors/<subType>          -- Model(下挂 Accessory)
-- ReplicatedStorage/Assets/Helmets/<subType>         -- Model(下挂 Accessory)
-- ReplicatedStorage/Assets/Throwables/<subType>      -- Tool（预留）

local AssetsRoot       = ReplicatedStorage:WaitForChild("Assets")
local WeaponAssets     = AssetsRoot:WaitForChild("Weapons")
local ArmorAssets      = AssetsRoot:WaitForChild("Armors")
local HelmetAssets     = AssetsRoot:WaitForChild("Helmets")

-- 每个玩家当前挂在角色身上的“我们自己创建的”实例
local visualStateByPlayer = {} :: {
    [Player]: {
        weaponTool: Tool?,
        armorAccessories: { Instance },
        helmetAccessories: { Instance },
    }
}

local BackpackAppearance = {}

-- 工具：拿/创建玩家的视觉状态表
local function getVisualState(player: Player)
    local st = visualStateByPlayer[player]
    if not st then
        st = {
            weaponTool        = nil,
            armorAccessories  = {},
            helmetAccessories = {},
        }
        visualStateByPlayer[player] = st
    end
    return st
end

-- 工具：销毁一批 Accessory
local function clearAccessoryList(list: { Instance })
    for i, inst in ipairs(list) do
        if inst and inst.Parent then
            inst:Destroy()
        end
        list[i] = nil
    end
end

-- 工具：按槽位清空旧外观
local function clearSlotVisual(player: Player, slotName: string)
    slotName = string.lower(slotName)
    local st = getVisualState(player)
    if slotName == "weapon" then
        if st.weaponTool and st.weaponTool.Parent then
            st.weaponTool:Destroy()
        end
        st.weaponTool = nil

    elseif slotName == "armor" then
        clearAccessoryList(st.armorAccessories)

    elseif slotName == "helmet" then
        clearAccessoryList(st.helmetAccessories)
    end
end

-- 工具：把某个槽位的一件 item 映射到角色上（会自动清掉旧的）
local function equipSlotOnCharacter(player: Player, character: Model, slotName: string, item: any?)
    slotName = string.lower(slotName)
    -- 不认识的槽位不处理
    if slotName ~= "weapon"
        and slotName ~= "armor"
        and slotName ~= "helmet"
        and slotName ~= "throwable"
    then
        return
    end
    -- 先把旧外观清掉
    clearSlotVisual(player, slotName)
    -- 没有新 item，就只是卸下
    if typeof(item) ~= "table" then
        return
    end
    local subType = tostring(item.subType or "")
    if subType == "" then
        -- 没配 subtype 的不挂外观，纯数据也行
        return
    end
    local st = getVisualState(player)
    -- 武器：克隆 Tool 到角色身上
    if slotName == "weapon" then
        local template = WeaponAssets:FindFirstChild(subType)
        if not (template and template:IsA("Tool")) then
            warn(("[BackpackAppearance] 武器资产缺失：%s"):format(subType))
            return
        end
        local tool = template:Clone()
        -- 名字统一用资产名
        tool.Name = template.Name
        tool.Parent = character
        st.weaponTool = tool
    -- 防具：Model 下挂一串 Accessory，全 clone 到角色身上
    elseif slotName == "armor" then
        local model = ArmorAssets:FindFirstChild(subType)
        if not (model and model:IsA("Model")) then
            warn(("[BackpackAppearance] 防具资产缺失：%s"):format(subType))
            return
        end
        clearAccessoryList(st.armorAccessories)
        for _, child in ipairs(model:GetChildren()) do
            if child:IsA("Accessory") then
                local clone = child:Clone()
                -- 模型和 Accessory 都统一用映射名字
                clone.Name = model.Name
                clone.Parent = character
                table.insert(st.armorAccessories, clone)
            end
        end
    -- 头盔：同防具，只是来自 Helmets
    elseif slotName == "helmet" then
        local model = HelmetAssets:FindFirstChild(subType)
        if not (model and model:IsA("Model")) then
            warn(("[BackpackAppearance] 头盔资产缺失：%s"):format(subType))
            return
        end
        clearAccessoryList(st.helmetAccessories)
        for _, child in ipairs(model:GetChildren()) do
            if child:IsA("Accessory") then
                local clone = child:Clone()
                clone.Name = model.Name
                clone.Parent = character
                table.insert(st.helmetAccessories, clone)
            end
        end
    -- 投掷物交给 ThrowableService 处理
    elseif slotName == "throwable" then
        return -- 故意留空
    end
end

-- 对外 API ----------------------------------------------------------------

-- 装备变化：由 BackpackServer 在 diff equipped 时调用
-- newItem = newState.backpack[newId] 或 nil
function BackpackAppearance.applyEquipChange(player: Player, slotName: string, newItem: any?)
    if not player or not player.Parent then
        return
    end

    local character = player.Character
    if not character or not character.Parent then
        -- 人还没生成，等 CharacterAdded 时会统一 refresh 一次，这里就算了
        return
    end

    equipSlotOnCharacter(player, character, slotName, newItem)
end

-- 整个角色重挂一遍装备（用于 CharacterAdded）
function BackpackAppearance.refreshCharacter(player: Player, character: Model)
    -- 声明式：直接从 BackpackModule 拿一份快照照抄
    local snap = BackpackModule.getAll(player)
    local backpack = snap.backpack or {}
    local equippedArr = snap.equipped or {}

    for _, slot in ipairs(equippedArr) do
        if typeof(slot) == "table" then
            local slotName = slot.slot
            local itemId   = slot.id
            if type(slotName) == "string"
                and type(itemId) == "string"
                and itemId ~= ""
            then
                local item = backpack[itemId]
                equipSlotOnCharacter(player, character, slotName, item)
            end
        end
    end
end

-- 初始化：挂 Player / Character 监听
function BackpackAppearance.init()
    local function onPlayerAdded(player: Player)
        -- 玩家重生：把当前装备重新挂到新角色身上
        player.CharacterAdded:Connect(function(char: Model)
            -- 旧角色销毁时，Accessory/Tool 会一起 Destroy，这里只需要把引用表清空
            visualStateByPlayer[player] = {
                weaponTool        = nil,
                throwableTool     = nil,
                armorAccessories  = {},
                helmetAccessories = {},
            }
            BackpackAppearance.refreshCharacter(player, char)
        end)
    end

    for _, p in ipairs(Players:GetPlayers()) do
        onPlayerAdded(p)
    end

    Players.PlayerAdded:Connect(onPlayerAdded)
    Players.PlayerRemoving:Connect(function(p)
        visualStateByPlayer[p] = nil
    end)
end

return BackpackAppearance
