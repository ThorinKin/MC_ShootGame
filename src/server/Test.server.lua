-- ServerScriptService/Server/BackpackService/BackpackStarter.server.lua
-- 总注释：玩家加入游戏时，如果背包是空的，发一套默认装备
-- 各类型 2 件（Helmet / Armor / Weapon / Throwable），且同一部位品质不同

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local BackpackModule = require(ServerScriptService.Server.BackpackService.BackpackModule)

-- 方便书写：转一手枚举
local ITEM_TYPE = BackpackModule.ITEM_TYPE

---------------------------------------------------------------------
-- 工具：判断背包是否为空
---------------------------------------------------------------------
local function isBackpackEmpty(player)
    local backpack = BackpackModule.getBackpack(player)
    for _, _ in pairs(backpack) do
        -- 有任意一条记录就不是空
        return false
    end
    return true
end

---------------------------------------------------------------------
-- 工具：给玩家发默认一套装备
---------------------------------------------------------------------
local function giveStarterItems(player)
    if not player or not player.Parent then
        return
    end

    -- 背包不空就不要瞎塞了
    if not isBackpackEmpty(player) then
        return
    end

    -- 每个部位 2 件，品质不一样，小类/名字随便起
    -- 品质字段用 attrs.quality，跟 UI 里 QUALITY_TEMPLATE_MAP 对得上
    local starterItems = {
        -- Helmet：common + rare
        {
            type    = ITEM_TYPE.Helmet,
            subType = "Training Helmet",
            attrs   = {
                quality = "common",
                name    = "Rusty Helmet",
            },
        },
        {
            type    = ITEM_TYPE.Helmet,
            subType = "Combat Helmet",
            attrs   = {
                quality = "rare",
                name    = "Kevlar Helmet",
            },
        },

        -- Armor：common + epic
        {
            type    = ITEM_TYPE.Armor,
            subType = "Training Armor",
            attrs   = {
                quality = "common",
                name    = "Old Vest",
            },
        },
        {
            type    = ITEM_TYPE.Armor,
            subType = "Assault Armor",
            attrs   = {
                quality = "epic",
                name    = "Titan Plate",
            },
        },

        -- Weapon：common + legendary
        {
            type    = ITEM_TYPE.Weapon,
            subType = "Practice Rifle",
            attrs   = {
                quality = "common",
                name    = "Training Rifle",
            },
        },
        {
            type    = ITEM_TYPE.Weapon,
            subType = "Battle Rifle",
            attrs   = {
                quality = "legendary",
                name    = "Dragon Fury",
            },
        },

        -- Throwable：common + mythic
        {
            type    = ITEM_TYPE.Throwable,
            subType = "Practice Grenade",
            attrs   = {
                quality = "common",
                name    = "Dummy Grenade",
            },
        },
        {
            type    = ITEM_TYPE.Throwable,
            subType = "Shock Grenade",
            attrs   = {
                quality = "mythic",
                name    = "Void Pulse",
            },
        },
    }

    for _, info in ipairs(starterItems) do
        local ok, err = pcall(function()
            -- 第三个参数 reason 随便写个字符串方便调试
            BackpackModule.giveItem(player, info, "starter_default")
        end)

        if not ok then
            warn(("[BackpackStarter] 给玩家 %s 发默认装备失败：%s")
                :format(player.Name, tostring(err)))
        end
    end
end

---------------------------------------------------------------------
-- 玩家加入回调
---------------------------------------------------------------------
local function onPlayerAdded(player)
    -- 稍微等一会，给 DataController / DataStore2 初始化时间（稳一点）
    task.delay(1, function()
        if not player or not player.Parent then
            return
        end
        giveStarterItems(player)
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

-- 处理服务器重载脚本时已经在场的玩家（Studio 里常见）
for _, plr in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, plr)
end
