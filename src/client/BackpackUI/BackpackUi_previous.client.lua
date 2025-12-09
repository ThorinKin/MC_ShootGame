-- StarterPlayer/StarterPlayerScripts/Client/BackpackUI/BackpackUi.client.lua
-- 总注释：背包界面客户端逻辑。当前版本：渲染服务器下发的库存 + 穿戴/脱下功能 + 简单飞行动画 + 悬浮浮窗信息
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

-- UI实例
local BackpackMainFrame = playerGui:WaitForChild("Main"):WaitForChild("Backpack"):WaitForChild("Main") -- 背包主Frame
local BackpackScrollingFrame = BackpackMainFrame:WaitForChild("BackpackScrollingFrame")  -- 背包库存 ScrollingFrame
local itemTemplatesFolder = BackpackScrollingFrame:WaitForChild("Templates")  -- 物品格子模板文件夹，内含品质模板
-- 已装备 5 个槽位按钮（Armor、Foot、Guns、Helmet、Pants）
local slotButton_Helmet = BackpackMainFrame:WaitForChild("Helmet")
local slotButton_Armor  = BackpackMainFrame:WaitForChild("Armor")
local slotButton_Pants  = BackpackMainFrame:WaitForChild("Pants")
local slotButton_Foot   = BackpackMainFrame:WaitForChild("Foot")
local slotButton_Guns   = BackpackMainFrame:WaitForChild("Guns")
-- 浮窗模板（FloatingWindow）
local TooltipTemplate = BackpackMainFrame:WaitForChild("FloatingWindow")

-- 槽位名与服务器内部 slotName 的映射（服务器用 helmet/clothes/pants/shoes/gun）
local SLOT_UI_MAP = {
    helmet  = slotButton_Helmet,
    clothes = slotButton_Armor,
    pants   = slotButton_Pants,
    shoes   = slotButton_Foot,
    gun     = slotButton_Guns,
}

-- 远程事件 
local RemotesRoot     = ReplicatedStorage:WaitForChild("Remotes")
local BackpackRemotes = RemotesRoot:WaitForChild("Backpack")
local RE_S2C_Full         = BackpackRemotes:WaitForChild("[S-C]BackpackFull")
local RE_S2C_Equipped     = BackpackRemotes:WaitForChild("[S-C]BackpackEquippedChanged")
local RE_CS_Request   = BackpackRemotes:WaitForChild("[C-S]BackpackRequestFull")
local RE_CS_Equip     = BackpackRemotes:WaitForChild("[C-S]BackpackEquip")
local RE_CS_Unequip   = BackpackRemotes:WaitForChild("[C-S]BackpackUnequip")
-- 目前不处理增删事件，后续扩展：
-- local RE_S2C_ItemsAdded    = BackpackRemotes:WaitForChild("[S-C]BackpackItemsAdded")
-- local RE_S2C_ItemsRemoved  = BackpackRemotes:WaitForChild("[S-C]BackpackItemsRemoved")

-- Tween（弹簧）模块：用来做 UI 平滑飞行动画
local TweenSpring = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("Tween"))

-- 品质模板映射
local QUALITY_TEMPLATE_MAP = {
    common     = "Common",
    normal     = "Common",
    rare       = "Rare",
    epic       = "Epic",
    legendary  = "Legendary",
    leg        = "Legendary",
    mysterious = "Mysterious",
    mythic     = "Mysterious",
}

-- 品质显示配置（浮窗 Name/Color 用）
local QUALITY_TEXT_STYLE = {
    common = {
        name  = "Common",
        color = Color3.fromRGB(255, 255, 255), -- 白
    },
    normal = {
        name  = "Common",
        color = Color3.fromRGB(255, 255, 255),
    },
    rare = {
        name  = "Rare",
        color = Color3.fromRGB(0, 162, 255),   -- 蓝
    },
    epic = {
        name  = "Epic",
        color = Color3.fromRGB(170, 0, 255),   -- 紫
    },
    legendary = {
        name  = "Legendary",
        color = Color3.fromRGB(255, 204, 0),   -- 金
    },
    leg = {
        name  = "Legendary",
        color = Color3.fromRGB(255, 204, 0),
    },
    mysterious = {
        name  = "Mysterious",
        color = Color3.fromRGB(255, 0, 0),     -- 红
    },
    mythic = {
        name  = "Mysterious",
        color = Color3.fromRGB(255, 0, 0),
    },
}

-- 本地状态缓存 
-- 当前背包：来自服务器 snapshot.backpack，不在这里改，只当字典用
local currentBackpackState = {}   -- [itemId] = itemTable
-- 当前已装备：slotName -> itemId 或 nil
local currentEquippedState = {}   -- [slotName] = itemId|nil
-- 当前 UI 实例缓存：方便查到具体格子/图标
local itemSlotFrames      = {}    -- [itemId] = Frame （在 BackpackScrollingFrame 下）
local equippedSlotFrames  = {}    -- [slotName] = Frame （在槽位按钮下）
-- 最近一次点击槽位按钮卸下的槽位，用来决定是否做渐隐动画
local lastClickedSlotForFade = nil  -- string|nil

-- 浮窗当前状态
local currentTooltip      -- Frame|nil
local tooltipTarget       -- GuiObject|nil
local tooltipUpdateConn   -- RBXScriptConnection|nil

-- 工具：根据品质字符串选择对应模板
local function pickTemplateForItem(item)
    if typeof(item) ~= "table" then
        return nil
    end

    local attrs = item.attrs
    local quality = nil

    if typeof(attrs) == "table" then
        -- 品质字段兼容：attrs.quality / attrs.Quality / attrs.rarity / attrs.Rarity
        quality = attrs.quality or attrs.Quality or attrs.rarity or attrs.Rarity
    end

    local templateName

    if type(quality) == "string" then
        local key = string.lower(quality)
        templateName = QUALITY_TEMPLATE_MAP[key]
    end

    -- 没有品质或映射不到模板，默认用 Common
    if not templateName then
        templateName = "Common"
    end

    local template = itemTemplatesFolder:FindFirstChild(templateName)
    if not template then
        -- 兜底：模板缺了就随便拿一个 Frame
        template = itemTemplatesFolder:FindFirstChild("Common")
            or itemTemplatesFolder:FindFirstChildWhichIsA("Frame")
    end

    return template
end

-- 工具：清空当前背包 UI
local function clearBackpackUI()
    -- 清空前顺手把浮窗收掉
    if currentTooltip then
        currentTooltip:Destroy()
        currentTooltip = nil
        tooltipTarget = nil
    end

    -- 只清理克隆出来的物品格子，不碰 Layout / Templates
    for itemId, frame in pairs(itemSlotFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
        itemSlotFrames[itemId] = nil
    end
end

-- 工具：清空已装备 UI 图标
local function clearEquippedUI()
    for slotName, frame in pairs(equippedSlotFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
        equippedSlotFrames[slotName] = nil
    end
end

-- 工具：浮窗淡入
local function fadeInTooltip(root: Instance)
    if not root or not root.Parent then
        return
    end

    local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tweens = {}

    local function addFadeIn(ui: Instance)
        -- Frame：背景
        if ui:IsA("Frame") then
            local target = ui.BackgroundTransparency
            if target < 1 then
                ui.BackgroundTransparency = 1
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    BackgroundTransparency = target,
                }))
            end
        end

        -- 图片
        if ui:IsA("ImageLabel") or ui:IsA("ImageButton") then
            local target = ui.ImageTransparency
            if target < 1 then
                ui.ImageTransparency = 1
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    ImageTransparency = target,
                }))
            end
        end

        -- 文本
        if ui:IsA("TextLabel") or ui:IsA("TextButton") then
            local target = ui.TextTransparency
            if target < 1 then
                ui.TextTransparency = 1
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    TextTransparency = target,
                }))
            end
        end

        -- 描边
        if ui:IsA("UIStroke") then
            local target = ui.Transparency
            if target < 1 then
                ui.Transparency = 1
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    Transparency = target,
                }))
            end
        end
    end

    addFadeIn(root)
    for _, ui in ipairs(root:GetDescendants()) do
        addFadeIn(ui)
    end

    for _, tw in ipairs(tweens) do
        tw:Play()
    end
end
-- 工具：浮窗淡出后销毁
local function fadeOutAndDestroyTooltip(root: Instance)
    if not root or not root.Parent then
        return
    end

    local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local tweens = {}

    local function addFadeOut(ui: Instance)
        if ui:IsA("Frame") then
            if ui.BackgroundTransparency < 1 then
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    BackgroundTransparency = 1,
                }))
            end
        end

        if ui:IsA("ImageLabel") or ui:IsA("ImageButton") then
            if ui.ImageTransparency < 1 then
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    ImageTransparency = 1,
                }))
            end
        end

        if ui:IsA("TextLabel") or ui:IsA("TextButton") then
            if ui.TextTransparency < 1 then
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    TextTransparency = 1,
                }))
            end
        end

        if ui:IsA("UIStroke") then
            if ui.Transparency < 1 then
                table.insert(tweens, TweenService:Create(ui, tweenInfo, {
                    Transparency = 1,
                }))
            end
        end
    end

    addFadeOut(root)
    for _, ui in ipairs(root:GetDescendants()) do
        addFadeOut(ui)
    end

    if #tweens == 0 then
        root:Destroy()
        return
    end

    for _, tw in ipairs(tweens) do
        tw:Play()
    end

    -- 简单粗暴延迟销毁，避免逐个绑定 Completed
    task.delay(tweenInfo.Time + 0.05, function()
        if root and root.Parent then
            root:Destroy()
        end
    end)
end

-- 工具：销毁当前浮窗
local function destroyTooltip()
    if tooltipUpdateConn then
        tooltipUpdateConn:Disconnect()
        tooltipUpdateConn = nil
    end

    if not currentTooltip then
        return
    end

    local tooltip = currentTooltip
    currentTooltip = nil
    tooltipTarget = nil

    fadeOutAndDestroyTooltip(tooltip)
end

-- 工具：仅在目标一致时销毁浮窗，避免不同控件之间互相抢着关
local function hideTooltipForTarget(target: GuiObject)
    if tooltipTarget ~= target then
        return
    end
    destroyTooltip()
end

-- 工具：把绝对坐标转换到某个容器下的 UDim2
local function absToContainerPos(container: GuiObject, absCenter: Vector2): UDim2
    local delta = absCenter - container.AbsolutePosition
    return UDim2.fromOffset(delta.X, delta.Y)
end

-- 工具：根据当前鼠标位置更新浮窗位置
local function updateTooltipPositionFromMouse()
    if not currentTooltip or not currentTooltip.Parent or not BackpackMainFrame or not BackpackMainFrame.Parent then
        return
    end

    local mousePos = UserInputService:GetMouseLocation()
    -- 稍微右下偏一点
    local offsetPos = mousePos + Vector2.new(12, 12)
    currentTooltip.Position = absToContainerPos(BackpackMainFrame, offsetPos)
end

-- 工具：显示某个物品的浮窗
-- targetGui: 悬浮的控件（格子 Frame / 槽位按钮）
-- itemId   : 物品 id
-- item     : 物品数据 { id, type, subType, attrs }
local function showTooltipForItem(targetGui: GuiObject, itemId: string, item)
    if not targetGui or not targetGui.Parent then
        return
    end
    if typeof(item) ~= "table" then
        return
    end

    destroyTooltip()

    local tooltip = TooltipTemplate:Clone()
    tooltip.Visible = true
    tooltip.Parent = BackpackMainFrame
    tooltip.ZIndex = math.max((targetGui.ZIndex or 1) + 20, tooltip.ZIndex or 0)

    -- 填文案
    local textRoot = tooltip:FindFirstChild("Text")
    if textRoot then
        local nameLabel    = textRoot:FindFirstChild("Name")
        local qualityLabel = textRoot:FindFirstChild("Quality")
        local typeLabel    = textRoot:FindFirstChild("Type")

        local attrs = item.attrs
        -- 名字：优先 attrs.name / Name / displayName / DisplayName，其次 subType / type
        local displayName = "Item"
        if typeof(attrs) == "table" then
            displayName = attrs.name
                or attrs.Name
                or attrs.displayName
                or attrs.DisplayName
                or item.subType
                or item.type
                or displayName
        else
            displayName = item.subType or item.type or displayName
        end

        if nameLabel and nameLabel:IsA("TextLabel") then
            nameLabel.Text = tostring(displayName)
        end

        -- 品质：文字 + 颜色
        local rawQuality
        if typeof(attrs) == "table" then
            rawQuality = attrs.quality or attrs.Quality or attrs.rarity or attrs.Rarity
        end

        local qualityKey = (type(rawQuality) == "string") and string.lower(rawQuality) or nil
        local style = qualityKey and QUALITY_TEXT_STYLE[qualityKey] or QUALITY_TEXT_STYLE.common

        if qualityLabel and qualityLabel:IsA("TextLabel") then
            qualityLabel.Text = style.name
            qualityLabel.TextColor3 = style.color
        end

        -- 类型："Type:" + helmet/clothes/pants/shoes/gun
        local typeName = tostring(item.type or "unknown")
        if typeLabel and typeLabel:IsA("TextLabel") then
            typeLabel.Text = "Type: " .. typeName
        end
    end

    currentTooltip = tooltip
    tooltipTarget = targetGui

    -- 初次放到鼠标附近
    updateTooltipPositionFromMouse()
    -- 悬停时固定在第一次出现的位置
    if tooltipUpdateConn then
        tooltipUpdateConn:Disconnect()
        tooltipUpdateConn = nil
    end
    -- 做一次淡入
    fadeInTooltip(tooltip)
end

-- 工具：播放一个从A飞到B的 UI 动画
-- fromGui: GuiObject 起点
-- toGui  : GuiObject 终点
-- onComplete: 动画结束回调
-- fadeOut: boolean? 是否在飞行过程中对整棵 UI 做渐隐
local function playFlyAnimation(fromGui: GuiObject, toGui: GuiObject, onComplete, fadeOut)
    if not fromGui or not toGui then
        if onComplete then
            onComplete()
        end
        return
    end

    local container = BackpackMainFrame
    if not container or not container.Parent then
        if onComplete then
            onComplete()
        end
        return
    end

    local clone = fromGui:Clone()
    clone.Visible = true
    clone.AnchorPoint = Vector2.new(0.5, 0.5)
    clone.Size = UDim2.fromOffset(fromGui.AbsoluteSize.X, fromGui.AbsoluteSize.Y)

    local startCenter = fromGui.AbsolutePosition + fromGui.AbsoluteSize / 2
    local endCenter   = toGui.AbsolutePosition + toGui.AbsoluteSize   / 2

    clone.Position = absToContainerPos(container, startCenter)
    clone.ZIndex = math.max(fromGui.ZIndex or 1, toGui.ZIndex or 1) + 10
    clone.Parent = container

    local targetPos = absToContainerPos(container, endCenter)

    -- 简单一点：临界阻尼 d=1，频率 f=6，看起来比较利落
    TweenSpring.target(clone, 1, 6, {
        Position = targetPos,
    })

    -- 只有需要渐隐时才做透明度 Tween，其它情况保持原样
    if fadeOut then
        local tweenInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local fades = {}

        local function addFade(ui: Instance)
            -- Frame：背景透明
            if ui:IsA("Frame") then
                if ui.BackgroundTransparency < 1 then
                    table.insert(fades, TweenService:Create(ui, tweenInfo, {
                        BackgroundTransparency = 1,
                    }))
                end
            end

            -- 图片：ImageLabel / ImageButton
            if ui:IsA("ImageLabel") or ui:IsA("ImageButton") then
                if ui.ImageTransparency < 1 then
                    table.insert(fades, TweenService:Create(ui, tweenInfo, {
                        ImageTransparency = 1,
                    }))
                end
            end

            -- 文本：TextLabel / TextButton
            if ui:IsA("TextLabel") or ui:IsA("TextButton") then
                if ui.TextTransparency < 1 then
                    table.insert(fades, TweenService:Create(ui, tweenInfo, {
                        TextTransparency = 1,
                    }))
                end
            end

            -- 描边：UIStroke
            if ui:IsA("UIStroke") then
                if ui.Transparency < 1 then
                    table.insert(fades, TweenService:Create(ui, tweenInfo, {
                        Transparency = 1,
                    }))
                end
            end
        end

        -- 根节点也做一遍
        addFade(clone)
        -- 所有子节点通杀
        for _, ui in ipairs(clone:GetDescendants()) do
            addFade(ui)
        end

        for _, tw in ipairs(fades) do
            tw:Play()
        end
    end

    TweenSpring.completed(clone, function()
        if clone.Parent then
            clone:Destroy()
        end
        if onComplete then
            onComplete()
        end
    end)
end

-- 工具：创建一个背包装备格子
local function createInventorySlot(itemId: string, item)
    local template = pickTemplateForItem(item)
    if not template then
        return
    end

    -- 避免重复
    local old = itemSlotFrames[itemId]
    if old and old.Parent then
        old:Destroy()
    end

    local slot = template:Clone()
    slot.Name = tostring(itemId)
    slot.Visible = true
    slot.Parent = BackpackScrollingFrame

    itemSlotFrames[itemId] = slot

    -- 悬浮：显示物品信息浮窗
    slot.MouseEnter:Connect(function()
        local data = currentBackpackState[itemId] or item
        showTooltipForItem(slot, itemId, data)
    end)

    slot.MouseLeave:Connect(function()
        hideTooltipForTarget(slot)
    end)

    -- 交互：格子里的 ImageButton
    local button = slot:FindFirstChild("ImageButton") 
        or slot:FindFirstChildWhichIsA("ImageButton", true)

    if button then
        button.MouseButton1Click:Connect(function()
            -- 点击背包装备 → 请求服务器穿戴
            RE_CS_Equip:FireServer(itemId)
        end)
    end
end

-- 工具：创建一个已装备图标（放在槽位按钮下面）
local function createEquippedIcon(slotName: string, itemId: string, item)
    local btn = SLOT_UI_MAP[slotName]
    if not btn then
        return
    end

    local template = pickTemplateForItem(item)
    if not template then
        return
    end

    -- 清理旧图标
    local old = equippedSlotFrames[slotName]
    if old and old.Parent then
        old:Destroy()
    end

    local icon = template:Clone()
    icon.Name = tostring(itemId)
    icon.Visible = true
    icon.AnchorPoint = Vector2.new(0.5, 0.5)
    icon.Position = UDim2.fromScale(0.5, 0.5)
    -- 拉满一点
    icon.Size = UDim2.fromScale(1, 1)
    icon.Parent = btn

    -- 把它下面所有 ImageButton 的交互都关掉
    for _, descendant in ipairs(icon:GetDescendants()) do
        if descendant:IsA("ImageButton") then
            -- 不要高亮
            descendant.AutoButtonColor = false

            -- Active/ Interactable 全关
            pcall(function()
                (descendant :: any).Active = false
            end)
            pcall(function()
                (descendant :: any).Interactable = false
            end)
        end
    end

    equippedSlotFrames[slotName] = icon
end

-- 用一份 snapshot 渲染全部 UI（全量刷新用）
local function renderFromSnapshot(snapshot)
    clearBackpackUI()
    clearEquippedUI()

    if typeof(snapshot) ~= "table" then
        return
    end

    currentBackpackState = snapshot.backpack or {}

    -- 处理已装备数组：[{slot="helmet", id=itemId|nil}, ...]
    currentEquippedState = {}
    local equippedArr = snapshot.equipped or {}
    for _, slot in ipairs(equippedArr) do
        if typeof(slot) == "table" and type(slot.slot) == "string" then
            local name = string.lower(slot.slot)
            local id   = slot.id
            if id ~= nil and id ~= "" then
                currentEquippedState[name] = id
            else
                currentEquippedState[name] = nil
            end
        end
    end

    -- 先算一份被装备的itemId集合，背包不要再显示这些
    local equippedIdSet = {}
    for _, id in pairs(currentEquippedState) do
        if id then
            equippedIdSet[id] = true
        end
    end

    -- 已装备 UI
    for slotName, id in pairs(currentEquippedState) do
        if id and currentBackpackState[id] then
            createEquippedIcon(slotName, id, currentBackpackState[id])
        end
    end

    -- 背包 UI：只显示没被装备的物品
    for id, item in pairs(currentBackpackState) do
        if not equippedIdSet[id] then
            createInventorySlot(id, item)
        end
    end
end

-- S-C：全量背包 snapshot
RE_S2C_Full.OnClientEvent:Connect(function(snapshot)
    -- snapshot 结构：
    -- {
    --   backpack = { [itemId] = { id, type, subType, attrs }, ... },
    --   equipped = { { slot="helmet", id=itemId|nil }, ... }
    -- }
    renderFromSnapshot(snapshot)
end)

RE_S2C_Equipped.OnClientEvent:Connect(function(slotName, slotIndex, newId, oldId)
    -- print("[BackpackUi] 收到装备变更：", slotName, slotIndex, "new=", newId, "old=", oldId)
    if type(slotName) ~= "string" or #slotName == 0 then
        return
    end

    slotName = string.lower(slotName)
    local btn = SLOT_UI_MAP[slotName]
    if not btn then
        return
    end

    -- 本次事件是否来自刚才玩家点了这个槽位按钮
    local shouldFade = (lastClickedSlotForFade == slotName)
    -- 用过一次就清掉，避免影响后续别的事件
    lastClickedSlotForFade = nil

    -- 更新本地 equipped 状态
    if newId ~= nil and newId ~= "" then
        currentEquippedState[slotName] = newId
    else
        currentEquippedState[slotName] = nil
    end

    -- 旧的物品被踢出该槽位：飞回背包区域 + 动画结束后再插回背包
    if oldId ~= nil and oldId ~= "" then
        local oldIcon = equippedSlotFrames[slotName]
        if oldIcon and oldIcon.Name == tostring(oldId) then
            -- 拿一份当前物品快照，避免动画过程中 state 被改坏
            local oldItemSnapshot = currentBackpackState[oldId]

            -- 只有点槽位按钮卸下的情况才渐隐，其他情况保持原来那种干脆飞行
            playFlyAnimation(oldIcon, BackpackScrollingFrame, function()
                -- 动画结束后再插回背包
                if oldItemSnapshot and not itemSlotFrames[oldId] then
                    createInventorySlot(oldId, oldItemSnapshot)
                end
            end, shouldFade)

            oldIcon:Destroy()
            equippedSlotFrames[slotName] = nil
        else
            -- 找不到 icon 的兜底：直接补回背包
            local oldItem = currentBackpackState[oldId]
            if oldItem and not itemSlotFrames[oldId] then
                createInventorySlot(oldId, oldItem)
            end
        end
    end

    -- 新的物品被装备进来：从背包格子飞到槽位
    if newId ~= nil and newId ~= "" then
        local newItem = currentBackpackState[newId]
        if not newItem then
            -- 理论上不应该发生，安全兜底：直接刷在槽位里
            createEquippedIcon(slotName, newId, { attrs = {} })
            return
        end

        local fromSlot = itemSlotFrames[newId]
        if fromSlot then
            -- 飞过去再在槽位里生成 icon（这里不用渐隐）
            itemSlotFrames[newId] = nil

            playFlyAnimation(fromSlot, btn, function()
                createEquippedIcon(slotName, newId, newItem)
            end)

            fromSlot:Destroy()
        else
            -- 找不到背包格子（例如刚进游戏时只收到了装备变更），直接刷
            createEquippedIcon(slotName, newId, newItem)
        end
    else
        -- 没有 newId，说明槽位被清空（纯卸下）
        local icon = equippedSlotFrames[slotName]
        if icon then
            -- 这里理论上 oldId 分支已经处理过大部分情况了；谨慎起见保留兜底
            playFlyAnimation(icon, BackpackScrollingFrame, nil, shouldFade)
            icon:Destroy()
            equippedSlotFrames[slotName] = nil
        end
    end
end)

-- 槽位按钮点击：卸下逻辑 + 悬浮提示逻辑
for slotName, btn in pairs(SLOT_UI_MAP) do
    -- 槽位点击：卸下
    btn.MouseButton1Click:Connect(function()
        local equippedId = currentEquippedState[slotName]
        print(("[BackpackUi] 点击槽位 %s，当前 equippedId = %s"):format(
            slotName, tostring(equippedId))
        )

        if not equippedId then
            -- 槽位本来就是空的，啥也不干，真正的提示服务器会发
            print("[BackpackUi] 槽位是空的~")
            return
        end

        -- 记录一下：这次是点槽位卸下，等服务端回包时用来判断是否做渐隐
        lastClickedSlotForFade = slotName

        -- 发请求：按槽位卸下
        print("[BackpackUi] 向服务器请求卸下槽位：", slotName)
        RE_CS_Unequip:FireServer(slotName)
    end)

    -- 槽位悬浮：如果有装备，显示浮窗
    btn.MouseEnter:Connect(function()
        local equippedId = currentEquippedState[slotName]
        if not equippedId then
            return
        end

        local item = currentBackpackState[equippedId]
        if not item then
            return
        end

        showTooltipForItem(btn, equippedId, item)
    end)

    btn.MouseLeave:Connect(function()
        hideTooltipForTarget(btn)
    end)
end

-- 开局向服务器请求一次全量背包数据，避免错过首次 onChanged
RE_CS_Request:FireServer()
