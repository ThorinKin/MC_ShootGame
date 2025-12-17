-- StarterPlayer/StarterPlayerScripts/Client/BackpackUI/DisableCoreBackpack.client.lua
-- 总注释：暴力关闭 Roblox 自带背包 / 快捷栏，只使用自定义背包 UI ！！！
local Players    = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local localPlayer = Players.LocalPlayer

local function setBackpackEnabled(enabled: boolean)
    local ok, result = pcall(function()
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, enabled)
        return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
    end)

    if not ok then
        warn("[DisableCoreBackpack] SetCoreGuiEnabled 失败：", result)
    else
        -- 调试：看看当前到底是啥状态
        -- print(("[DisableCoreBackpack] BackpackEnabled = %s"):format(tostring(result)))
    end
end

local function hardDisableBackpack()
    -- 多试几次，防止 CoreScript 还没起来
    setBackpackEnabled(false)

    -- 再后面多打一轮，防止其它脚本晚点把它打开
    for i = 1, 10 do
        task.delay(0.5 * i, function()
            setBackpackEnabled(false)
        end)
    end
end

-- 玩家一上线就关一次
hardDisableBackpack()

-- 角色每次重生后再关一轮
localPlayer.CharacterAdded:Connect(function()
    -- 先等一帧，给 CoreScript 反应时间
    task.defer(hardDisableBackpack)
end)
