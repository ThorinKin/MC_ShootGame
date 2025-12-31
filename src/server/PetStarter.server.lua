-- ServerScriptService/Server/PetStarter.server.lua
-- 总注释：测试用 Pet Starter。玩家加入时如果宠物背包为空，则塞每个品质各 1 只宠物；
--       并且确保玩家 5 个宠物栏位全部解锁（方便测试）

local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PetModule = require(ServerScriptService.Server.PetService.PetModule)

---------------------------------------------------------------------
-- 工具：判断宠物背包是否为空
---------------------------------------------------------------------
local function isPetBackpackEmpty(player)
    local backpack = PetModule.getBackpack(player)
    return next(backpack) == nil
end

---------------------------------------------------------------------
-- 工具：确保玩家 5 个宠物槽位全部解锁（测试用）
---------------------------------------------------------------------
local function unlockAllPetSlots(player)
    if not player or not player.Parent then
        return
    end

    -- 直接把 2~5 解锁（1 默认就解锁）
    for i = 2, 5 do
        local ok, err = pcall(function()
            PetModule.unlockSlot(player, i, "starter_unlock_all_slots")
        end)
        if not ok then
            warn(("[PetStarter] 解锁玩家 %s 宠物槽位 %d 失败：%s"):format(player.Name, i, tostring(err)))
        end
    end
end

---------------------------------------------------------------------
-- 工具：给玩家塞 5 只不同品质宠物（测试数据）
---------------------------------------------------------------------
local function giveStarterPets(player)
    if not player or not player.Parent then
        return
    end

    -- 背包不空就别乱塞了
    if not isPetBackpackEmpty(player) then
        return
    end

    -- 每个品质一只，kind 统一叫 Pet_1，name 随便，attrs 里带 quality
    local qualities = { "Common", "Rare", "Epic", "Legendary", "Mysterious" }

    for _, q in ipairs(qualities) do
        local ok, err = pcall(function()
            PetModule.givePet(player, {
                kind = "Pet_1",
                name = q .. "_Pet",
                attrs = {
                    quality = q,
                },
            }, "starter_quality_pets")
        end)

        if not ok then
            warn(("[PetStarter] 给玩家 %s 塞宠物失败：%s"):format(player.Name, tostring(err)))
        end
    end
end

---------------------------------------------------------------------
-- 玩家加入回调
---------------------------------------------------------------------
local function onPlayerAdded(player)
    -- 稍微延迟一下，等 DataStore2 初始化更稳
    task.delay(1, function()
        if not player or not player.Parent then
            return
        end

        -- 先解锁全部槽位（不依赖背包是否为空）
        unlockAllPetSlots(player)

        -- 再塞测试宠物
        giveStarterPets(player)
    end)
end

Players.PlayerAdded:Connect(onPlayerAdded)

-- 处理服务器重载脚本时已经在场的玩家
for _, plr in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, plr)
end
