-- StarterPlayer/StarterPlayerScripts/Client/AttrUI/AttrUI.client.lua
-- 总注释：属性加点界面逻辑。监听玩家属性/技能点变化并刷新 UI，处理加点按钮点击。
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- UI 实例引用
local attrMainFrame = playerGui:WaitForChild("Main"):WaitForChild("Upgrade"):WaitForChild("Main"):WaitForChild("BG"):WaitForChild("Page") -- 界面主Frame
local playerLevelText = attrMainFrame:WaitForChild("playerLevel")  -- 玩家等级文本TextLabel，填值如：Lv1
local remainingSpText = attrMainFrame:WaitForChild("RemainingSp")  -- 玩家剩余sp点数TextLabel，填值如：3
local atkFrame     = attrMainFrame:WaitForChild("Attack")          -- 攻击属性Frame
local atkAttrText  = atkFrame:WaitForChild("Total"):WaitForChild("TextLabel") -- 当前攻击属性值，填值如：1
local atkAddButton = atkFrame:WaitForChild("Add")                  -- 消耗sp加点攻击1点按钮
local defFrame     = attrMainFrame:WaitForChild("Defence")         -- 防御属性Frame
local defAttrText  = defFrame:WaitForChild("Total"):WaitForChild("TextLabel") -- 当前防御属性值，填值如：1
local defAddButton = defFrame:WaitForChild("Add")                  -- 消耗sp加点防御1点按钮
local hpFrame      = attrMainFrame:WaitForChild("Hp")              -- 生命值属性Frame
local hpAttrText   = hpFrame:WaitForChild("Total"):WaitForChild("TextLabel")  -- 当前生命值属性值，填值如：1
local hpAddButton  = hpFrame:WaitForChild("Add")                   -- 消耗sp加点生命值1点按钮

-- Players服务：Exp 文件夹：等级 + 剩余技能点
local expFolder    = localPlayer:WaitForChild("Exp")
local expLevelVal  = expFolder:WaitForChild("Level")
local expSkillFree = expFolder:WaitForChild("SkillFree")

-- Players服务：Attr 文件夹：Attack / Defense / Health
local attrFolder   = localPlayer:WaitForChild("Attr")
local attrAtkVal   = attrFolder:WaitForChild("Attack")
local attrDefVal   = attrFolder:WaitForChild("Defense")
local attrHpVal    = attrFolder:WaitForChild("Health")

-- Remotes：属性加点 + 本地消息
local RemotesRoot   = ReplicatedStorage:WaitForChild("Remotes")
-- C-S：尝试给某个属性加点
local AttrRemotes   = RemotesRoot:WaitForChild("Attr")
local RE_CS_Add     = AttrRemotes:WaitForChild("[C-S]AttrAddPoints")
local LocalMessageBar    = ReplicatedStorage.Remotes.Message:WaitForChild("[C-C]Message")
local LocalMessageNoBar  = ReplicatedStorage.Remotes.Message:WaitForChild("[C-C]MessageNo")

-- 工具：刷新 UI 文本
local function refreshUI()
    -- 等级：格式 Lv1 / Lv2 ...
    local lvl = tonumber(expLevelVal.Value) or 1
    playerLevelText.Text = "Lv" .. tostring(lvl)

    -- 剩余技能点
    local freeSp = tonumber(expSkillFree.Value) or 0
    remainingSpText.Text = tostring(freeSp)

    -- 属性点：Attack / Defense / Health
    atkAttrText.Text = tostring(tonumber(attrAtkVal.Value) or 0)
    defAttrText.Text = tostring(tonumber(attrDefVal.Value) or 0)
    hpAttrText.Text  = tostring(tonumber(attrHpVal.Value) or 0)
end

-- 初始刷新一帧
refreshUI()

-- 监听所有相关数值变化，自动刷新 UI
expLevelVal.Changed:Connect(refreshUI)
expSkillFree.Changed:Connect(refreshUI)

attrAtkVal.Changed:Connect(refreshUI)
attrDefVal.Changed:Connect(refreshUI)
attrHpVal.Changed:Connect(refreshUI)

-- 工具：尝试加点
local function tryAddPoints(attrName)
    -- 简单本地校验一下，节省无效请求；真正判定以后端为准
    local freeSp = tonumber(expSkillFree.Value) or 0
    if freeSp <= 0 then
        LocalMessageNoBar:Fire("Not enough skill points.")
        return
    end

    -- 每次加 1 点
    RE_CS_Add:FireServer(attrName, 1)
end

-- 按钮事件绑定：攻击加点
atkAddButton.MouseButton1Click:Connect(function()
    -- 后端会接受 attack / atk / ATTACK 等多种写法，这里保持统一
    tryAddPoints("attack")
end)

-- 按钮事件绑定：防御加点
defAddButton.MouseButton1Click:Connect(function()
    tryAddPoints("defense")
end)

-- 按钮事件绑定：生命值加点
hpAddButton.MouseButton1Click:Connect(function()
    tryAddPoints("health")
end)