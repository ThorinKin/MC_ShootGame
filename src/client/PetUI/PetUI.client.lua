-- StarterPlayer/StarterPlayerScripts/Client/PetUI/PetUI.client.lua
-- 总注释：宠物客户端UI逻辑
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local RunService       = game:GetService("RunService")

-- 宠物 UI 打开时临时 射击/投掷物开启全局锁
local GameplayLock = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("DisableEnableLock"))

-- UI实例引用
local MainGui = playerGui:WaitForChild("Main") -- ScreenGui
local PetRootFrame = MainGui:WaitForChild("Pet")    -- 宠物界面根（开关的是这个）
local PetMainFrame = PetRootFrame:WaitForChild("Main") -- 宠物界面内容根
local PetScrollingFrame = PetMainFrame:WaitForChild("ScrollingFrame") -- 宠物背包列表
local PetIconTemplatesFolder = PetScrollingFrame:WaitForChild("Templates") -- 宠物根据品质分类的icon按钮模板
local CommonImageButton = PetIconTemplatesFolder:WaitForChild("Common") -- Common品质imagebutton模板
local RareImageImageButton = PetIconTemplatesFolder:WaitForChild("Rare") -- Rare品质imagebutton模板
local EpicImageImageButton = PetIconTemplatesFolder:WaitForChild("Epic") -- Epic品质imagebutton模板
local LegendaryImageButton = PetIconTemplatesFolder:WaitForChild("Legendary") -- Legendary品质imagebutton模板
local MysteriousImageButton = PetIconTemplatesFolder:WaitForChild("Mysterious") -- Mysterious品质imagebutton模板
local FloatingWindowTemplate = PetIconTemplatesFolder:WaitForChild("floatingWindow") -- 悬浮浮窗模板（Frame）
local PetPropertiesFrame = PetMainFrame:WaitForChild("Properties") -- 左侧属性面板
local PetSelectedNameLabel = PetPropertiesFrame:WaitForChild("Name") -- 属性面板宠物名称 TextLabel
local PetEquipedFrame = PetMainFrame:WaitForChild("Equiped") -- 已装备区
local PetEquipedScrollingFrame = PetEquipedFrame:WaitForChild("ScrollingFrame") -- 已装备列表
local PetEquipButtonsFrame = PetPropertiesFrame:WaitForChild("Equip") -- 属性面板的 Equip 目录
local BtnEquip   = PetEquipButtonsFrame:WaitForChild("Equip")   -- 装备按钮 ImageButton
local BtnUnEquip = PetEquipButtonsFrame:WaitForChild("UnEquip") -- 卸下按钮 ImageButton

-- 远程事件：拉全量 + 收增量 + 装备变化 + 发请求
local RemotesRoot = ReplicatedStorage:WaitForChild("Remotes")
local PetRemotes  = RemotesRoot:WaitForChild("Pet")
local RE_S2C_Full      = PetRemotes:WaitForChild("[S-C]PetFull")
local RE_S2C_PetsAdded = PetRemotes:WaitForChild("[S-C]PetAdded")
local RE_CS_RequestFull = PetRemotes:WaitForChild("[C-S]PetRequestFull")
local RE_S2C_EquippedChanged = PetRemotes:WaitForChild("[S-C]PetEquippedChanged")
local RE_CS_Equip   = PetRemotes:WaitForChild("[C-S]PetEquip")
local RE_CS_Unequip = PetRemotes:WaitForChild("[C-S]PetUnequip")

-- 模板映射
local TemplateByQuality = {
    Common     = CommonImageButton,
    Rare       = RareImageImageButton,
    Epic       = EpicImageImageButton,
    Legendary  = LegendaryImageButton,
    Mysterious = MysteriousImageButton,
}
-- 品质颜色映射
local QUALITY_META = {
    common = {
        name  = "Common",
        color = Color3.fromRGB(255, 255, 255), -- 白
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
    mysterious = {
        name  = "Mythic",
        color = Color3.fromRGB(255, 0, 0),     -- 红
    },
}
-- 品质映射 mysterious 的模板叫 Mysterious，但显示名叫 Mythic
local TEMPLATE_KEY_BY_QUALITY = {
    common     = "Common",
    rare       = "Rare",
    epic       = "Epic",
    legendary  = "Legendary",
    mysterious = "Mysterious",
}

-- 选中状态：同一时间只能选中一个
local selectedPetId = nil
local selectedBtn   = nil
-- 悬浮浮窗状态：同一时间只显示一个浮窗
local floatingWindow = nil
local floatingFollowConn = nil
-- 本地缓存：全量宠物库
local petsByIdAll = {}
-- 本地缓存：背包库存
local backpackById = {}
-- 本地缓存：已装备槽位（[index] = { unlocked, id }）
local equippedSlots = {}
-- 反查表：petId -> slotIndex
local equippedSlotByPetId = {}
-- 是否触屏设备
local IS_TOUCH = UserInputService.TouchEnabled

-- 透明全屏挡板吃输入↓↓↓↓↓↓
MainGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local blocker = Instance.new("TextButton")
blocker.Name = "PetInputBlocker"
blocker.BackgroundTransparency = 1
blocker.Text = ""
blocker.TextTransparency = 1
blocker.AutoButtonColor = false
blocker.Size = UDim2.fromScale(1, 1)
blocker.Position = UDim2.fromScale(0, 0)
blocker.Active = true
blocker.Modal = true
blocker.ZIndex = 0
-- 放到 PetRootFrame 里，而不是 MainGui 里
blocker.Parent = PetRootFrame
-- Pet 的主内容建议确保在 blocker 上面
PetMainFrame.ZIndex = 1
local function syncBlocker()
    blocker.Visible = PetRootFrame.Visible == true
end
PetRootFrame:GetPropertyChangedSignal("Visible"):Connect(syncBlocker)
syncBlocker()
-- 透明全屏挡板吃输入↑↑↑↑↑

-- 宠物UI开关驱动 射击/投掷物全局锁↓
-- local petUiActive = false
-- -- 全局锁：角色可能死亡/重生：用弱表按 character 记 token，避免旧角色残留/报错
-- local gameplayLockTokens = setmetatable({}, { __mode = "k" }) -- [Model] = token
-- local function lockGameplayForCharacter(char: Model?)
--     if not (char and char.Parent) then
--         return
--     end
--     if gameplayLockTokens[char] then
--         return
--     end
--     gameplayLockTokens[char] = GameplayLock.acquire(char, "PetUI")
-- end
-- local function unlockGameplayForAll()
--     for char, tok in pairs(gameplayLockTokens) do
--         if char and char.Parent and tok then
--             GameplayLock.release(char, tok)
--         end
--         gameplayLockTokens[char] = nil
--     end
-- end
-- -- 玩家重生：如果宠物 UI 还开着，给新角色补锁
-- localPlayer.CharacterAdded:Connect(function(char: Model)
--     if PetRootFrame and PetRootFrame.Parent and PetRootFrame.Visible then
--         lockGameplayForCharacter(char)
--     end
-- end)
-- -- 工具：宠物 UI Visible 变化时上锁/解锁
-- local function onPetVisibleChanged()
--     if not PetRootFrame or not PetRootFrame.Parent then
--         return
--     end
--     local nowVisible = PetRootFrame.Visible == true
--     -- 打开：上锁
--     if nowVisible and not petUiActive then
--         petUiActive = true
--         lockGameplayForCharacter(localPlayer.Character)
--         return
--     end
--     -- 关闭：解锁
--     if (not nowVisible) and petUiActive then
--         petUiActive = false
--         unlockGameplayForAll()
--         return
--     end
-- end
-- -- 监听 Visible 变化
-- PetRootFrame:GetPropertyChangedSignal("Visible"):Connect(onPetVisibleChanged)
-- -- 兜底 Pet UI 被销毁/移走 直接解锁
-- PetRootFrame.AncestryChanged:Connect(function(_, parent)
--     if not parent and petUiActive then
--         petUiActive = false
--         unlockGameplayForAll()
--     end
-- end)
-- -- 初始化时同步一次
-- onPetVisibleChanged()
-- 宠物全局锁↑------------

-- 工具：把 quality 统一成 lower key
local function normalizeQualityKey(rawQuality)
    local q = tostring(rawQuality or "common")
    q = string.lower(q)
    -- 兼容以后存成 Mysterious / Mythic 之类
    if q == "mythic" then
        q = "mysterious"
    end
    if not QUALITY_META[q] then
        q = "common"
    end
    return q
end

-- 工具：获取鼠标在 ScreenGui 坐标
local function getMousePosInGui()
    local inset = GuiService:GetGuiInset()
    local p = UserInputService:GetMouseLocation() - inset
    return p
end

-- 悬浮浮窗：触屏用 touch 位置驱动
local floatingTouchPosInGui: Vector2? = nil -- 已经减过 inset 的坐标
local function setFloatingTouchPos(screenPos: Vector2)
    local inset = GuiService:GetGuiInset()
    floatingTouchPosInGui = screenPos - inset
end

-- 工具：隐藏并销毁浮窗
local function hideFloatingWindow()
    if floatingFollowConn then
        floatingFollowConn:Disconnect()
        floatingFollowConn = nil
    end
    if floatingWindow then
        floatingWindow:Destroy()
        floatingWindow = nil
    end
    floatingTouchPosInGui = nil
end

-- 工具：显示浮窗（克隆模板）并跟随指针
local function showFloatingWindow(pet, initialScreenPos: Vector2?)
    hideFloatingWindow()
    floatingWindow = FloatingWindowTemplate:Clone()
    floatingWindow.Visible = true
    floatingWindow.Parent = PetRootFrame -- 放到 Pet 层
    -- 填充内容：Name / Quality
    local page = floatingWindow:FindFirstChild("Page")
    if page then
        local nameLabel = page:FindFirstChild("Name")
        local qualityLabel = page:FindFirstChild("Quality")
        if nameLabel and nameLabel:IsA("TextLabel") then
            nameLabel.Text = tostring(pet.name or "")
        end
        local qKey = normalizeQualityKey((typeof(pet.attrs) == "table") and pet.attrs.quality or nil)
        local meta = QUALITY_META[qKey] or QUALITY_META.common
        if qualityLabel and qualityLabel:IsA("TextLabel") then
            qualityLabel.Text = meta.name
            qualityLabel.TextColor3 = meta.color
        end
    end
    -- 初次定位
    if initialScreenPos then
        setFloatingTouchPos(initialScreenPos)
    end
    local p0 = (IS_TOUCH and floatingTouchPosInGui) or getMousePosInGui()
    if p0 then
        floatingWindow.Position = UDim2.fromOffset(p0.X, p0.Y)
    end
    -- 跟随指针：PC 用鼠标；触屏用缓存 touchPos
    floatingFollowConn = RunService.RenderStepped:Connect(function()
        if not floatingWindow then
            return
        end
        local p = (IS_TOUCH and floatingTouchPosInGui) or getMousePosInGui()
        if p then
            floatingWindow.Position = UDim2.fromOffset(p.X, p.Y)
        end
    end)
end

-- 工具：设置某个按钮的高亮显示（highlight Visible）
local function setHighlight(btn, on)
    if not btn then
        return
    end
    -- 允许 highlight 在任意层级
    local hl = btn:FindFirstChild("highlight", true)
    if hl and hl:IsA("GuiObject") then
        hl.Visible = not not on
    end
end

-- 工具：选中某只宠物同一时间只能选中一个
local function selectPet(petId, btn, pet)
    -- 清掉旧选中
    if selectedBtn then
        setHighlight(selectedBtn, false)
    end
    selectedPetId = petId
    selectedBtn = btn
    -- 点亮新选中
    setHighlight(btn, true)
    -- 同步右侧属性
    PetSelectedNameLabel.Text = tostring(pet.name or "")
    -- 选中变化 更新 Equip/UnEquip 显示
    refreshEquipButtons()
end

-- 工具：重建 petId -> slotIndex 映射
local function rebuildEquippedIndexMap()
    equippedSlotByPetId = {}
    for i = 1, 5 do
        local slot = equippedSlots[i]
        if slot and slot.unlocked and slot.id then
            equippedSlotByPetId[tostring(slot.id)] = i
        end
    end
end

-- 工具：重建背包库存 = 全量 - 已装备
local function rebuildBackpackInventory()
    backpackById = {}
    for petId, pet in pairs(petsByIdAll) do
        local idStr = tostring(petId)
        if not equippedSlotByPetId[idStr] then
            backpackById[idStr] = pet
        end
    end
end

-- 触屏：浮窗按住显示，滑动就立刻隐藏
local TOUCH_FLOAT_MOVE_THRESHOLD = 14 -- 像素
local activeFloatTouchId: number? = nil
local floatStartPos: Vector2? = nil

-- 全局监听：更新触屏浮窗位置 + 判断是否在拖动
UserInputService.InputChanged:Connect(function(input: InputObject)
    if not IS_TOUCH then
        return
    end
    if input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    if not activeFloatTouchId then
        return
    end
    if input.TouchId ~= activeFloatTouchId then
        return
    end
    -- 更新浮窗位置
    setFloatingTouchPos(input.Position)
    -- 拖动判定：拖了就把浮窗收掉
    if floatStartPos and (input.Position - floatStartPos).Magnitude > TOUCH_FLOAT_MOVE_THRESHOLD then
        hideFloatingWindow()
        activeFloatTouchId = nil
        floatStartPos = nil
    end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
    if not IS_TOUCH then
        return
    end
    if input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    if activeFloatTouchId and input.TouchId == activeFloatTouchId then
        hideFloatingWindow()
        activeFloatTouchId = nil
        floatStartPos = nil
    end
end)

-- 工具：统一绑定一个宠物按钮
local function bindPetButton(btn: GuiButton, petIdStr: string, pet)
    if not btn then
        return
    end
    -- 默认关掉高亮
    setHighlight(btn, false)
    -- 保险：把 petId / qualityKey 存起来
    pcall(function()
        btn:SetAttribute("PetId", petIdStr)
    end)
    -- 选中：统一走 Roblox 默认 Activated
    btn.Activated:Connect(function()
        selectPet(petIdStr, btn, pet)
    end)
    -- 浮窗：PC 用 Hover；触屏用 按住显示/抬手消失
    if IS_TOUCH then
        btn.InputBegan:Connect(function(input: InputObject)
            if input.UserInputType ~= Enum.UserInputType.Touch then
                return
            end
            activeFloatTouchId = input.TouchId
            floatStartPos = input.Position
            setFloatingTouchPos(input.Position)
            showFloatingWindow(pet, input.Position)
        end)
    else
        btn.MouseEnter:Connect(function()
            showFloatingWindow(pet, nil)
        end)
        btn.MouseLeave:Connect(function()
            hideFloatingWindow()
        end)
    end
end

-- 工具：清空旧渲染 保留 Templates 文件夹
local function clearRenderedIcons()
    for _, child in ipairs(PetScrollingFrame:GetChildren()) do
        if child ~= PetIconTemplatesFolder then
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
    end
    hideFloatingWindow()
end

-- 工具：渲染背包列表 按品质选模板，clone 后 Visible=true
local function renderBackpack()
    clearRenderedIcons()
    selectedBtn = nil -- 重新渲染后需要重新找回按钮引用
    for petId, pet in pairs(backpackById) do
        local petIdStr = tostring(petId)
        local qRaw = (typeof(pet.attrs) == "table") and pet.attrs.quality or nil
        local qKey = normalizeQualityKey(qRaw)

        local templateKey = TEMPLATE_KEY_BY_QUALITY[qKey] or "Common"
        local template = TemplateByQuality[templateKey] or TemplateByQuality.Common

        local btn = template:Clone()
        btn.Name = petIdStr
        btn.Visible = true
        btn.Parent = PetScrollingFrame

        -- 绑定交互（选中走 Activated，浮窗按设备分支）
        bindPetButton(btn, petIdStr, pet)

        -- 如果这只就是当前选中 恢复高亮
        if selectedPetId ~= nil and tostring(selectedPetId) == petIdStr then
            selectedBtn = btn
            setHighlight(btn, true)
        end
    end
end

-- 工具：清空已装备区旧渲染保留 Templates 文件夹
local function clearRenderedEquippedIcons()
    local templatesFolder = PetEquipedScrollingFrame:FindFirstChild("Templates")
    for _, child in ipairs(PetEquipedScrollingFrame:GetChildren()) do
        if child ~= templatesFolder then
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
    end
end

-- 工具：刷新 Equip / UnEquip 按钮显示状态
function refreshEquipButtons()
    -- 没选中就都不显示
    if not selectedPetId then
        BtnEquip.Visible = false
        BtnUnEquip.Visible = false
        return
    end
    local petId = tostring(selectedPetId)
    local slotIdx = equippedSlotByPetId[petId]
    -- 已装备：显示 UnEquip
    if slotIdx then
        BtnEquip.Visible = false
        BtnUnEquip.Visible = true
    else
        BtnEquip.Visible = true
        BtnUnEquip.Visible = false
    end
end

-- 工具：渲染已装备区（按槽位 1~5，把已装备宠物克隆品质模板塞进去）
local function renderEquipped()
    clearRenderedEquippedIcons()

    for i = 1, 5 do
        local slot = equippedSlots[i]
        if slot and slot.unlocked and slot.id then
            local petId = tostring(slot.id)
            -- 这里从全量库取
            local pet = petsByIdAll[petId]
            -- 防御：极少数情况下背包还没同步过来
            if pet then
                local qRaw = (typeof(pet.attrs) == "table") and pet.attrs.quality or nil
                local qKey = normalizeQualityKey(qRaw)
                local templateKey = TEMPLATE_KEY_BY_QUALITY[qKey] or "Common"
                local template = TemplateByQuality[templateKey] or TemplateByQuality.Common

                local btn = template:Clone()
                btn.Name = ("Slot_%d_%s"):format(i, petId)
                btn.Visible = true
                btn.Parent = PetEquipedScrollingFrame

                -- 保险：标记一下槽位
                pcall(function()
                    btn:SetAttribute("PetId", petId)
                    btn:SetAttribute("Quality", qKey)
                    btn:SetAttribute("SlotIndex", i)
                end)

                -- 绑定交互
                bindPetButton(btn, petId, pet)

                -- 恢复选中高亮
                if selectedPetId ~= nil and tostring(selectedPetId) == petId then
                    selectedBtn = btn
                    setHighlight(btn, true)
                end
            end
        end
    end
end

-- S-C：全量快照 → 覆盖本地缓存 → 渲染
RE_S2C_Full.OnClientEvent:Connect(function(state)
    petsByIdAll = {}
    equippedSlots = {}

    -- 全量宠物库
    local bp = state and state.backpack
    if typeof(bp) == "table" then
        for id, pet in pairs(bp) do
            petsByIdAll[tostring(id)] = pet
        end
    end

    -- 已装备
    local eq = state and state.equipped
    if typeof(eq) == "table" then
        for i = 1, 5 do
            local slot = eq[i]
            if typeof(slot) == "table" then
                equippedSlots[i] = {
                    unlocked = not not slot.unlocked,
                    id       = slot.id,
                }
            else
                equippedSlots[i] = { unlocked = (i == 1), id = nil }
            end
        end
    else
        for i = 1, 5 do
            equippedSlots[i] = { unlocked = (i == 1), id = nil }
        end
    end

    rebuildEquippedIndexMap()
    rebuildBackpackInventory()

    -- 渲染：背包 + 已装备
    renderBackpack()
    renderEquipped()
    refreshEquipButtons()
end)

-- S-C：新增宠物 → 合并到本地缓存 → 渲染
RE_S2C_PetsAdded.OnClientEvent:Connect(function(addedPets)
    if typeof(addedPets) ~= "table" then
        return
    end
    for _, pet in ipairs(addedPets) do
        if typeof(pet) == "table" and type(pet.id) == "string" and pet.id ~= "" then
            petsByIdAll[tostring(pet.id)] = pet
        end
    end
    rebuildEquippedIndexMap()
    rebuildBackpackInventory()
    renderBackpack()
    renderEquipped()
    refreshEquipButtons()
end)

-- Equip / UnEquip 点击回调：发服务器请求
BtnEquip.Activated:Connect(function()
    if not selectedPetId then return end
    RE_CS_Equip:FireServer(tostring(selectedPetId))
end)

BtnUnEquip.Activated:Connect(function()
    if not selectedPetId then return end
    local petId = tostring(selectedPetId)
    local slotIdx = equippedSlotByPetId[petId]
    if not slotIdx then return end
    RE_CS_Unequip:FireServer(slotIdx)
end)

-- S-C：装备槽位变化（包含解锁/装备变化）
-- 参数：index:number, newId:string|nil, oldId:string|nil, newUnlocked:boolean
RE_S2C_EquippedChanged.OnClientEvent:Connect(function(index, newId, oldId, newUnlocked)
    local idx = tonumber(index)
    if not idx then
        return
    end
    idx = math.floor(idx)
    if idx < 1 or idx > 5 then
        return
    end

    equippedSlots[idx] = {
        unlocked = not not newUnlocked,
        id       = newId,
    }

    -- 关键：装备变化后，背包库存要重新变成 全量 - 已装备
    rebuildEquippedIndexMap()
    rebuildBackpackInventory()
    renderBackpack()
    renderEquipped()
    refreshEquipButtons()
end)

-- 关浮窗兜底
PetRootFrame:GetPropertyChangedSignal("Visible"):Connect(function()
    if not PetRootFrame.Visible then
        hideFloatingWindow()
        activeFloatTouchId = nil
        floatStartPos = nil
    end
end)

-- 启动：主动拉一次全量
task.defer(function()
    BtnEquip.Visible = false
    BtnUnEquip.Visible = false
    RE_CS_RequestFull:FireServer()
end)
