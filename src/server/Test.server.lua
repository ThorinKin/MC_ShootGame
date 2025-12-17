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

    -- 每个部位 2 件，品质不一样，用来测试外观映射：
    -- Helmet_1 / Helmet_2
    -- Armor_1 / Armor_2
    -- AKM / M4A1
    -- Grenade_1 / Grenade_2
    local starterItems = {
        -- Helmet：common + rare
        {
            type    = ITEM_TYPE.Helmet,
            subType = "Helmet_1",
            attrs   = {
                quality = "common",
                name    = "Helmet_1",
            },
        },
        {
            type    = ITEM_TYPE.Helmet,
            subType = "Helmet_2",
            attrs   = {
                quality = "rare",
                name    = "Helmet_2",
            },
        },

        -- Armor：common + epic
        {
            type    = ITEM_TYPE.Armor,
            subType = "Armor_1",
            attrs   = {
                quality = "common",
                name    = "Armor_1",
            },
        },
        {
            type    = ITEM_TYPE.Armor,
            subType = "Armor_2",
            attrs   = {
                quality = "epic",
                name    = "Armor_2",
            },
        },

        -- Weapon：AKM + M4A1，品质不一样
        {
            type    = ITEM_TYPE.Weapon,
            subType = "AKM",
            attrs   = {
                quality = "common",
                name    = "AKM",
            },
        },
        {
            type    = ITEM_TYPE.Weapon,
            subType = "M4A1",
            attrs   = {
                quality = "legendary",
                name    = "M4A1",
            },
        },

        -- Throwable：随便两个，主要是占坑测试
        {
            type    = ITEM_TYPE.Throwable,
            subType = "Throwable_1",
            attrs   = {
                quality = "common",
                name    = "Grenade_1",
            },
        },
        {
            type    = ITEM_TYPE.Throwable,
            subType = "Throwable_1",
            attrs   = {
                quality = "mythic",
                name    = "Grenade_2",
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
