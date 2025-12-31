-- StarterPlayer/StarterPlayerScripts/Client/BackpackUI/BackpackUi.client.lua
-- 总注释：背包界面客户端逻辑。
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")
local TweenSpring = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("Tween")) -- Tween弹簧模块
-- 3D 背景舞台控制器
local BackpackBgSceneController = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Backpack"):WaitForChild("BackpackBgSceneController"))
-- 1206：背包打开时临时 射击/投掷物开启全局锁
local GameplayLock = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ViewControl"):WaitForChild("DisableEnableLock"))
local UIController = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("UIController"))
-- 拿到当前活跃 HUD（HUD / HUD_Mobile）
local HudRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("HudRegistry"))

-- UI 实例路径
local BackpackMainFrame = playerGui:WaitForChild("Main"):WaitForChild("Backpack") -- 主 Frame
-- 槽位
local BackpackSlotsFrame   = BackpackMainFrame:WaitForChild("BackpackSlots")
local slotButton_Helmet    = BackpackSlotsFrame:WaitForChild("Helmet")
local slotButton_Armor     = BackpackSlotsFrame:WaitForChild("Armor")
local slotButton_Weapon    = BackpackSlotsFrame:WaitForChild("Weapon")
local slotButton_Throwable = BackpackSlotsFrame:WaitForChild("Throwable")
-- 物品栏
local InventoryFrame         = BackpackMainFrame:WaitForChild("Inventory")
local itemTemplatesFolder    = InventoryFrame:WaitForChild("UITemplates")
local InventoryListFrame     = InventoryFrame:WaitForChild("List")
local BackpackScrollingFrame = InventoryListFrame:WaitForChild("ScrollingFrame")
local equippedTemplate = itemTemplatesFolder:WaitForChild("Equiped")
-- 属性栏
local WeaponPropsFrame    = BackpackMainFrame:WaitForChild("WeaponProperties")
local ArmorPropsFrame     = BackpackMainFrame:WaitForChild("ArmorProperties")
local ThrowablePropsFrame = BackpackMainFrame:WaitForChild("ThrowableProperties")
-- 拖动旋转展示模型的命中框
local RotateHitbox = BackpackMainFrame:WaitForChild("RotateHitbox")
local UserInputService = game:GetService("UserInputService")
-- 初始全部隐藏，等有高亮物品再打开
WeaponPropsFrame.Visible    = false
ArmorPropsFrame.Visible     = false
ThrowablePropsFrame.Visible = false
-------------------------------------------------------------------------
-- 背包开关驱动 3D 舞台
local backpackSceneActive = false
local sceneOpenDelay = 0.06 -- 稍微等 HUD 开始缩回时间
-------------------------------------------------------------------------
-- 技能栏：Skill1 映射投掷物
local activeHudGui: ScreenGui? = nil
local Skill1Button: GuiButton? = nil
local function resolveSkill1FromHud(hudGui: ScreenGui?)
	activeHudGui = hudGui
	Skill1Button = nil
	if not hudGui then
		return
	end
	-- HUD / HUD_Mobile 的层级一致
	local bottom = hudGui:FindFirstChild("Bottom")
	local status = bottom and bottom:FindFirstChild("StatusBar")
	local player = status and status:FindFirstChild("Player")
	local skill1 = player and player:FindFirstChild("Skill1")
	if skill1 and (skill1:IsA("TextButton") or skill1:IsA("ImageButton")) then
		Skill1Button = skill1
	end
end
resolveSkill1FromHud(HudRegistry.wait()) -- 初始化：等 HudVariantSwitcher 注入活跃 HUD

-- 工具：死亡态判断（死亡但未重生时，禁止开背包）
local function isLocalDeadNow(): boolean
	local char = localPlayer.Character
	if not char then return true end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return true end
	if hum.Health <= 0 then return true end
	local ok, state = pcall(function()
		return hum:GetState()
	end)
	if ok and state == Enum.HumanoidStateType.Dead then
		return true
	end
	return false
end
-- 槽位名与服务器内部映射（服务器用 helmet/armor/weapon/throwable）
local SLOT_UI_MAP = {
    helmet    = slotButton_Helmet,
    armor     = slotButton_Armor,
    weapon    = slotButton_Weapon,
    throwable = slotButton_Throwable,
}

-- 远程事件
local RemotesRoot     = ReplicatedStorage:WaitForChild("Remotes")
local BackpackRemotes = RemotesRoot:WaitForChild("Backpack")
local RE_S2C_Full     = BackpackRemotes:WaitForChild("[S-C]BackpackFull")
local RE_S2C_Equipped = BackpackRemotes:WaitForChild("[S-C]BackpackEquippedChanged")
local RE_CS_Request   = BackpackRemotes:WaitForChild("[C-S]BackpackRequestFull")
local RE_CS_Equip     = BackpackRemotes:WaitForChild("[C-S]BackpackEquip")
local RE_CS_Unequip   = BackpackRemotes:WaitForChild("[C-S]BackpackUnequip")
-- 目前不处理增删事件，后续扩展：
-- local RE_S2C_ItemsAdded    = BackpackRemotes:WaitForChild("[S-C]BackpackItemsAdded")
-- local RE_S2C_ItemsRemoved  = BackpackRemotes:WaitForChild("[S-C]BackpackItemsRemoved")

-- 品质配置：模板名映射 + 属性栏显示样式
local QUALITY_TEMPLATE_MAP = {
    common     = "Common",
    normal     = "Common",
    rare       = "Rare",
    epic       = "Epic",
    legendary  = "Legendary",
    leg        = "Legendary",
    mysterious = "Mythic",    -- 兼容旧字段
    mythic     = "Mythic",
}

-- 品质显示配置（属性栏 RarityText 用）
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
        name  = "Mythic",
        color = Color3.fromRGB(255, 0, 0),     -- 红
    },
    mythic = {
        name  = "Mythic",
        color = Color3.fromRGB(255, 0, 0),
    },
}
-- 工具：根据物品拿一份品质样式（名字 + 颜色），给属性栏 / Equiped 共用
local function getItemQualityStyle(item)
    if typeof(item) ~= "table" then
        return QUALITY_TEXT_STYLE.common
    end
    local attrs = item.attrs
    local rawQuality
    if typeof(attrs) == "table" then
        rawQuality = attrs.quality or attrs.Quality or attrs.rarity or attrs.Rarity
    end
    local qualityKey = (type(rawQuality) == "string") and string.lower(rawQuality) or nil
    return (qualityKey and QUALITY_TEXT_STYLE[qualityKey]) or QUALITY_TEXT_STYLE.common
end
-- 工具：拿物品品质 common/rare/epic/legendary/mythic
local function getItemQualityKey(item)
    if typeof(item) ~= "table" then
        return "common"
    end
    local attrs = item.attrs
    local rawQuality
    if typeof(attrs) == "table" then
        rawQuality = attrs.quality or attrs.Quality or attrs.rarity or attrs.Rarity
    end
    local qualityKey = (type(rawQuality) == "string") and string.lower(rawQuality) or "common"
    return qualityKey
end
-- 工具：Equiped 模板（装备图标）按品质开Common/Rare/Epic/Legendary/Mythic
local EQUIP_RARITY_LABELS = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
local EQUIP_RARITY_LABEL_MAP = {
    common     = "Common",
    normal     = "Common",
    rare       = "Rare",
    epic       = "Epic",
    legendary  = "Legendary",
    leg        = "Legendary",
    mysterious = "Mythic",
    mythic     = "Mythic",
}
local function applyEquippedTemplateRarity(iconFrame: Instance, item)
    if not iconFrame then return end
    local key = getItemQualityKey(item)
    local targetName = EQUIP_RARITY_LABEL_MAP[key] or "Common"
    -- 只开对应的那个，其它全关
    for _, labelName in ipairs(EQUIP_RARITY_LABELS) do
        local node = iconFrame:FindFirstChild(labelName, true)
        if node and node:IsA("GuiObject") then
            node.Visible = (labelName == targetName)
        end
    end
end

-- 大类显示名（TypeText 用）
local TYPE_DISPLAY_NAME = {
    helmet    = "Helmet",
    armor     = "Armor",
    weapon    = "Weapon",
    throwable = "Throwable",
}

-- 本地状态缓存
-- 当前背包：来自服务器 snapshot.backpack，不在这里改，只当字典用
local currentBackpackState = {}   -- [itemId] = itemTable
-- 当前已装备：slotName -> itemId 或 nil（slotName = helmet/armor/weapon/throwable）
local currentEquippedState = {}   -- [slotName] = itemId|nil
-- 当前 UI 实例缓存：方便查到具体格子/图标
local itemSlotFrames      = {}    -- [itemId]   = Frame （在 ScrollingFrame 下）
local equippedSlotFrames  = {}    -- [slotName] = Frame （在槽位按钮下）
-- 技能槽 UI：Skill1 下的投掷物图标
local skill1ThrowableIconFrame = nil
-- Focus：属性栏 / 舞台展示用
local persistentFocusId: string? = nil -- 常驻主展示
local hoverFocusId: string? = nil --临时预览
-- 仅视觉：库存格子的高亮
local highlightedInventoryId: string? = nil


-- 射击/投掷物全局锁：角色可能死亡/重生：用弱表按 character 记 token，避免旧角色残留/报错
local gameplayLockTokens = setmetatable({}, { __mode = "k" }) -- [Model] = token
local function lockGameplayForCharacter(char: Model?)
    if not (char and char.Parent) then
        return
    end
    if gameplayLockTokens[char] then
        return
    end
    gameplayLockTokens[char] = GameplayLock.acquire(char, "BackpackUI")
end
local function unlockGameplayForAll()
    for char, tok in pairs(gameplayLockTokens) do
        if char and char.Parent and tok then
            GameplayLock.release(char, tok)
        end
        gameplayLockTokens[char] = nil
    end
end
-- 玩家重生：如果背包还开着，给新角色补锁
localPlayer.CharacterAdded:Connect(function(char: Model)
    if BackpackMainFrame and BackpackMainFrame.Parent and BackpackMainFrame.Visible then
        lockGameplayForCharacter(char)
    end
end)

-- 工具：背包背景舞台
local function onBackpackVisibleChanged()
    if not BackpackMainFrame or not BackpackMainFrame.Parent then
        return
    end
    local nowVisible = BackpackMainFrame.Visible == true
    -- 打开
    if nowVisible and not backpackSceneActive then
        -- 死亡态禁止开背包
        if isLocalDeadNow() then
            pcall(function()
                UIController.closeScreen("Backpack")
            end)
            return
        end
        backpackSceneActive = true
        -- 关键：先上锁（别等 sceneOpenDelay），先把射击/投掷物系统按住
        lockGameplayForCharacter(localPlayer.Character)
        task.delay(sceneOpenDelay, function()
            if backpackSceneActive and BackpackMainFrame
                and BackpackMainFrame.Parent
                and BackpackMainFrame.Visible
            then
                BackpackBgSceneController.enter()
            end
        end)
        return
    end
    -- 关闭
    if (not nowVisible) and backpackSceneActive then
        backpackSceneActive = false
        -- 解锁全局锁
        BackpackBgSceneController.exit(false, function()
            unlockGameplayForAll()
        end)
        return
    end
end
-- 监听 Visible 变化
BackpackMainFrame:GetPropertyChangedSignal("Visible"):Connect(onBackpackVisibleChanged)
-- 兜底：如果背包 UI 被销毁/移走（重生重建 Main 等），直接瞬间恢复相机
BackpackMainFrame.AncestryChanged:Connect(function(_, parent)
    if not parent and backpackSceneActive then
        backpackSceneActive = false
        BackpackBgSceneController.exit(true) -- instant：不闪屏，直接恢复
        unlockGameplayForAll()
    end
end)

-- 初始化时同步一次
onBackpackVisibleChanged()

-- 功能区：RotateHitbox 拖动/触屏滑动 旋转展示中模型
local rotating = false
local rotateInput: InputObject? = nil
local lastPos: Vector2? = nil
local function stopRotate()
	rotating = false
	rotateInput = nil
	lastPos = nil
end
RotateHitbox.InputBegan:Connect(function(input: InputObject)
	-- 仅左键 / 触屏
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch
	then
		return
	end
	rotating = true
	rotateInput = input
	lastPos = input.Position
end)
RotateHitbox.InputEnded:Connect(function(input: InputObject)
	if rotateInput == input then
		stopRotate()
	end
end)
UserInputService.InputChanged:Connect(function(input: InputObject)
	if not rotating then return end
	if not rotateInput then return end
	-- 触屏：只认同一个 touch input
	if rotateInput.UserInputType == Enum.UserInputType.Touch then
		if input ~= rotateInput then return end
	end
	-- 鼠标：按住左键时，靠 MouseMovement 来更新
	if rotateInput.UserInputType == Enum.UserInputType.MouseButton1 then
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	end
	if not lastPos then
		lastPos = input.Position
		return
	end
	local newPos = input.Position
	local delta = newPos - lastPos
	lastPos = newPos
	BackpackBgSceneController.addPreviewRotationDelta(delta.X, delta.Y)
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if rotateInput == input then
		stopRotate()
	end
end)
-- 兜底：背包关掉时立刻停止旋转状态，避免残留
BackpackMainFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	if not BackpackMainFrame.Visible then
		stopRotate()
	end
end)

-- Focus 工具若干
-- 工具：切换属性栏显示为某个物品（item 可以为 nil） 
local function showPropertiesForItem(item) 
    -- 先关掉所有属性面板 
    WeaponPropsFrame.Visible = false 
    ArmorPropsFrame.Visible = false 
    ThrowablePropsFrame.Visible = false 
    if typeof(item) ~= "table" then 
        return 
    end 
    local rawType = tostring(item.type or "") 
    local t = string.lower(rawType) 
    -- 物品类型 → 属性面板 
    local panelKey 
    if t == "weapon" then 
        panelKey = "weapon" 
    elseif t == "throwable" then 
        panelKey = "throwable" 
    elseif t == "helmet" or t == "armor" then 
        -- 头和甲都归到 Armor 属性栏里显示 
        panelKey = "armor" 
    else -- 未知类型就不显示属性 
        return 
    end 
    local panelFrame 
    if panelKey == "weapon" then 
        panelFrame = WeaponPropsFrame 
    elseif panelKey == "armor" then 
        panelFrame = ArmorPropsFrame 
    else 
        panelFrame = ThrowablePropsFrame 
    end 
    panelFrame.Visible = true 
    -- Basic 下三行文本 
    local basic = panelFrame:FindFirstChild("Basic") 
    if not basic then 
        return 
    end 
    local typeLabel = basic:FindFirstChild("TypeText") 
    local rarityLabel = basic:FindFirstChild("RarityText") 
    local nameLabel = basic:FindFirstChild("NameText") 
    -- TypeText：填大类 
    local displayType = TYPE_DISPLAY_NAME[t] or rawType 
    if typeLabel and typeLabel:IsA("TextLabel") then 
        typeLabel.Text = tostring(displayType) 
    end 
    -- NameText：名字（subType / attrs.name / ...） 
    local attrs = item.attrs 
    local displayName = item.subType or item.type or "Item" 
    if typeof(attrs) == "table" then 
        displayName = attrs.name or attrs.Name or attrs.displayName or attrs.DisplayName or displayName 
    end 
    if nameLabel and nameLabel:IsA("TextLabel") then 
        nameLabel.Text = tostring(displayName) 
    end 
    -- RarityText：稀有度 + 颜色 
    local style = getItemQualityStyle(item) 
    if rarityLabel and rarityLabel:IsA("TextLabel") then
        rarityLabel.Text = style.name
        rarityLabel.TextColor3 = style.color
    end
end
-- 从一个库存格子 Frame 里找到 highlight 节点（槽位不需要）
local function getInventoryHighlightGui(slotFrame: Instance?): GuiObject?
    if not slotFrame then
        return nil
    end
    local highlight = slotFrame:FindFirstChild("highlight", true)
    if highlight and highlight:IsA("GuiObject") then
        return highlight
    end
    return nil
end
-- Focus 工具：可选步骤——点亮/关闭库存格子的高亮框
local function setInventoryHighlight(itemId: string?)
    -- 关掉旧的
    if highlightedInventoryId and highlightedInventoryId ~= itemId then
        local oldFrame = itemSlotFrames[highlightedInventoryId]
        local oldHighlight = getInventoryHighlightGui(oldFrame)
        if oldHighlight then
            oldHighlight.Visible = false
        end
    end
    highlightedInventoryId = nil
    -- 点亮新的（找不到就跳过，不报错）
    if type(itemId) == "string" and itemId ~= "" then
        local newFrame = itemSlotFrames[itemId]
        if newFrame then
            local newHighlight = getInventoryHighlightGui(newFrame)
            if newHighlight then
                newHighlight.Visible = true
                highlightedInventoryId = itemId
            end
        end
    end
end
type FocusOptions = {
    highlight: boolean?,       -- 是否点亮库存高亮框（槽位传 false）
    animatePreview: boolean?,  -- 舞台预览是否弹簧（库存悬浮传 true）
}
local UI = {}
-- Focus 工具：设置临时预览（槽位用）
local function setHoverFocus(itemId: string?)
    hoverFocusId = itemId
    -- 槽位悬浮也成为最近焦点，但不点库存高亮框
    persistentFocusId = itemId
    UI.setFocus(itemId, {
        highlight = false,
        animatePreview = true, -- 槽位悬浮做左右滑动切换
    })
end
-- 工具：槽位 MouseLeave 回到常驻焦点
local function restorePersistentFocus()
    hoverFocusId = nil
    UI.setFocus(persistentFocusId, {
        highlight = false,
        animatePreview = false,
    })
end
-- 统一入口：拿 item → 刷属性栏 → 刷舞台展示；高亮框是可选
function UI.setFocus(itemId: string?, opts: FocusOptions?)
    opts = (typeof(opts) == "table") and opts or {}
    local doHighlight = (opts.highlight == true)
    local doAnimate   = (opts.animatePreview == true)
    -- itemId -> item
    local item = nil
    if type(itemId) == "string" and itemId ~= "" then
        item = currentBackpackState[itemId]
    else
        itemId = nil
    end
    if typeof(item) ~= "table" then
        item = nil
        itemId = nil
    end
    -- 库存高亮框
    if doHighlight then
        setInventoryHighlight(itemId)
    end
    -- 属性栏
    showPropertiesForItem(item)
    -- 舞台展示（subType 映射 EquipmentModel4Display）
    if item then
        BackpackBgSceneController.setEquipPreview(tostring(item.subType or ""), doAnimate)
    else
        BackpackBgSceneController.setEquipPreview(nil, false)
    end
end
-- 工具：设置常驻焦点（库存用）
local function setPersistentFocus(itemId: string?, animatePreview: boolean?)
	persistentFocusId = itemId
	hoverFocusId = nil
	UI.setFocus(itemId, {
		highlight = true,
		-- 库存悬浮不弹
		animatePreview = animatePreview == true,
	})
end

-- 工具：默认高亮第一个/高亮物品被装备移除时兜底
local function pickAnyInventoryItemId()
    for id, frame in pairs(itemSlotFrames) do
        if frame and frame.Parent == BackpackScrollingFrame then
            return id
        end
    end
    return nil
end

-- 技能槽 UI：清理 Skill1 里的投掷物图标
local function clearSkill1UI()
    if skill1ThrowableIconFrame and skill1ThrowableIconFrame.Parent then
        skill1ThrowableIconFrame:Destroy()
    end
    skill1ThrowableIconFrame = nil

    if Skill1Button then
        -- 给其他系统一点可用的状态标记
        Skill1Button:SetAttribute("ThrowableItemId", "")
        Skill1Button:SetAttribute("HasThrowable", false)
    end
end
-- 技能槽 UI：根据当前已装备状态刷新 Skill1 图标
local function refreshSkill1FromEquipped()
    if not Skill1Button or not Skill1Button.Parent then
        return
    end
    -- 先清掉旧的
    clearSkill1UI()
    -- 只关心投掷物槽位
    local throwableId = currentEquippedState["throwable"]
    if not throwableId or throwableId == "" then
        return
    end
    local item = currentBackpackState[throwableId]
    if typeof(item) ~= "table" then
        return
    end
    -- Skill1 里也挂一份 Equiped 模板
    local iconFrame = equippedTemplate:Clone()
    iconFrame.Name = tostring(throwableId)
    iconFrame.Visible = true
    iconFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    iconFrame.Position = UDim2.fromScale(0.5, 0.5)
    iconFrame.Size = UDim2.fromScale(1, 1)
    iconFrame.Parent = Skill1Button
    -- 根据品质打开Common/Rare/Epic/Legendary/Mythic
    applyEquippedTemplateRarity(iconFrame, item)
    -- Skill1 里这份模板只是提示，不允许点里面的按钮
    for _, descendant in ipairs(iconFrame:GetDescendants()) do
        if descendant:IsA("ImageButton") then
            descendant.AutoButtonColor = false
            pcall(function()
                (descendant :: any).Active = false
            end)
            pcall(function()
                (descendant :: any).Interactable = false
            end)
        end
    end
    skill1ThrowableIconFrame = iconFrame
    -- 给其他系统一个可读的标记
    Skill1Button:SetAttribute("ThrowableItemId", throwableId)
    Skill1Button:SetAttribute("HasThrowable", true)
end
-- 工具：背包 UI / 已装备 UI 清理
local function clearBackpackUI()
    -- 清掉 Focus 状态 + 属性栏/舞台
    persistentFocusId = nil
    hoverFocusId = nil
    highlightedInventoryId = nil
    UI.setFocus(nil, { highlight = true, animatePreview = false })
    -- 只清理克隆出来的物品格子，不碰 Layout / UITemplates
    for itemId, frame in pairs(itemSlotFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
        itemSlotFrames[itemId] = nil
    end
end
local function clearEquippedUI()
    for slotName, frame in pairs(equippedSlotFrames) do
        if frame and frame.Parent then
            frame:Destroy()
        end
        equippedSlotFrames[slotName] = nil
    end
    -- 已装备清空时顺带清掉 Skill1 的提示
    clearSkill1UI()
end

-- 工具：播放一个从 A 飞到 B 的 UI 动画
-- fromGui: GuiObject 起点
-- toGui  : GuiObject 终点
-- onComplete: 动画结束回调
-- fadeOut: boolean? 是否在飞行过程中对 Equiped 的 Border/Icon 做渐隐
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
    -- 固定成起点当前像素尺寸，避免父级空间差异导致变形
    clone.Size = UDim2.fromOffset(fromGui.AbsoluteSize.X, fromGui.AbsoluteSize.Y)
    local startCenter = fromGui.AbsolutePosition + fromGui.AbsoluteSize / 2
    local endCenter   = toGui.AbsolutePosition + toGui.AbsoluteSize   / 2
    local function absToContainerPos(containerGui: GuiObject, absCenter: Vector2): UDim2
        local delta = absCenter - containerGui.AbsolutePosition
        return UDim2.fromOffset(delta.X, delta.Y)
    end
    clone.Position = absToContainerPos(container, startCenter)
    clone.ZIndex = math.max(fromGui.ZIndex or 1, toGui.ZIndex or 1) + 10
    clone.Parent = container
    -- 只在「背包 → 槽位」的情况下，把 AspectRatio 从长条（2.96）拉到 1
    local goingFromInventory = fromGui:IsDescendantOf(BackpackScrollingFrame)
    local goingToSlot        = toGui:IsDescendantOf(BackpackSlotsFrame)
    if goingFromInventory and goingToSlot then
        local aspectConstraint
        for _, ui in ipairs(clone:GetDescendants()) do
            if ui:IsA("UIAspectRatioConstraint") then
                aspectConstraint = ui
                break
            end
        end
        if aspectConstraint then
            -- 不管原来多少，统一 tween 到 1，看着就是方的
            local tweenInfo = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local tween = TweenService:Create(aspectConstraint, tweenInfo, {
                AspectRatio = 1,
            })
            tween:Play()
        end
    end
    -- 位移动画：保持原来的弹簧 Position，不动
    local targetPos = absToContainerPos(container, endCenter)
    -- 简单一点：临界阻尼 d=1，频率 f=6，看起来比较利落
    TweenSpring.target(clone, 1, 6, {
        Position = targetPos,
    })
    -- 渐隐 Equiped: 
    if fadeOut then
        local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        -- 1226新：Equiped Frame 本身的背景也淡出
        if clone and clone:IsA("GuiObject") then
            TweenService:Create(clone, tweenInfo, { BackgroundTransparency = 1 }):Play()
        end
        -- 1226新：Equiped 下的 UIStroke 也淡出
        for _, ui in ipairs(clone:GetDescendants()) do
            if ui:IsA("UIStroke") then
                TweenService:Create(ui, tweenInfo, { Transparency = 1 }):Play()
            end
        end
        -- Border：只管 ImageTransparency
        local border = clone:FindFirstChild("Border", true)
        if border and (border:IsA("ImageLabel") or border:IsA("ImageButton")) then
            local goals = { ImageTransparency = 1 }
            TweenService:Create(border, tweenInfo, goals):Play()
        end
        -- Icon：ImageTransparency + BackgroundTransparency
        local icon = clone:FindFirstChild("Icon", true)
        if icon and icon:IsA("GuiObject") then
            local goals = {} :: { [string]: any }
            if icon:IsA("ImageLabel") or icon:IsA("ImageButton") then
                goals.ImageTransparency = 1
            end
            -- 不管原来有没有背景色，直接 tween 到 1
            goals.BackgroundTransparency = 1

            if next(goals) ~= nil then
                TweenService:Create(icon, tweenInfo, goals):Play()
            end
        end
        -- 1226新：补充渐隐品质标签Common/Rare/Epic/Legendary/Mythic
        for _, labelName in ipairs(EQUIP_RARITY_LABELS) do
            local tag = clone:FindFirstChild(labelName, true)
            if tag and (tag:IsA("ImageLabel") or tag:IsA("ImageButton")) then
                TweenService:Create(tag, tweenInfo, { ImageTransparency = 1 }):Play()
            end
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

-- 工具：创建背包装备格子 / 已装备图标
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
    -- 库存悬浮：更新常驻焦点（粘住）+ 舞台预览弹一下
    slot.MouseEnter:Connect(function()
        setPersistentFocus(itemId, true) -- 库存悬浮做左右滑动切换
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
-- 创建一个已装备图标（放在槽位按钮下面）
local function createEquippedIcon(slotName: string, itemId: string, item)
    local btn = SLOT_UI_MAP[slotName]
    if not btn then
        return
    end
    -- 清理旧图标
    local old = equippedSlotFrames[slotName]
    if old and old.Parent then
        old:Destroy()
    end
    -- 统一用 UITemplates/Equiped 这个模板，比例已经调好适配槽位
    local iconFrame = equippedTemplate:Clone()
    iconFrame.Name = tostring(itemId)
    iconFrame.Visible = true
    iconFrame.AnchorPoint = Vector2.new(0.5, 0.5)
    iconFrame.Position = UDim2.fromScale(0.5, 0.5)
    -- 拉满一点
    iconFrame.Size = UDim2.fromScale(1, 1)
    iconFrame.Parent = btn
    -- 根据品质打开对应 Common/Rare/Epic/Legendary/Mythic
    applyEquippedTemplateRarity(iconFrame, item)
    -- 把它下面所有 ImageButton 的交互都关掉（槽位只点外面的大按钮）
    for _, descendant in ipairs(iconFrame:GetDescendants()) do
        if descendant:IsA("ImageButton") then
            descendant.AutoButtonColor = false
            pcall(function()
                (descendant :: any).Active = false
            end)
            pcall(function()
                (descendant :: any).Interactable = false
            end)
        end
    end
    equippedSlotFrames[slotName] = iconFrame
end

-- 渲染：用一份 snapshot 渲染全部 UI（全量刷新用）
local function renderFromSnapshot(snapshot)
    -- 调试日志
    -- print("[BackpackUi] renderFromSnapshot, BackpackMainFrame =", BackpackMainFrame, "parent =", BackpackMainFrame and BackpackMainFrame.Parent)
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
    -- 先算一份被装备的 itemId 集合，背包不要再显示这些
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
    -- Skill1：根据当前投掷物装备情况刷新一次技能提示
    refreshSkill1FromEquipped()
    -- 默认高亮物品栏第一个物品
    local firstItemId = pickAnyInventoryItemId()
    setPersistentFocus(firstItemId, false)
end

-- 如果允许运行中切换 HUD 自动重绑，刷一次图标
HudRegistry.changed():Connect(function(newHud)
    clearSkill1UI()              -- 清 icon、旧按钮 attrs
    resolveSkill1FromHud(newHud) -- 重绑新 HUD
    refreshSkill1FromEquipped()  -- 重新挂图标
end)

-- S-C：全量背包 / 槽位变更事件
RE_S2C_Full.OnClientEvent:Connect(function(snapshot)
    -- snapshot 结构：
    -- {
    --   backpack = { [itemId] = { id, type, subType, attrs }, ... },
    --   equipped = { { slot="helmet", id=itemId|nil }, ... }
    -- }
    renderFromSnapshot(snapshot)
end)

RE_S2C_Equipped.OnClientEvent:Connect(function(slotName, slotIndex, newId, oldId)
    if type(slotName) ~= "string" or #slotName == 0 then
        return
    end
    slotName = string.lower(slotName)
    local btn = SLOT_UI_MAP[slotName]
    if not btn then
        return
    end
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
            -- 不管是替换还是脱下，只要从槽位飞回背包，都做渐隐
            playFlyAnimation(oldIcon, BackpackScrollingFrame, function()
                -- 动画结束后再插回背包
                if oldItemSnapshot and not itemSlotFrames[oldId] then
                    createInventorySlot(oldId, oldItemSnapshot)
                end
            end, true)

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
        else -- 找不到背包格子直接刷
            createEquippedIcon(slotName, newId, newItem)
        end
    else
        -- 没有 newId，说明槽位被清空（纯卸下）
        local icon = equippedSlotFrames[slotName]
        if icon then
            -- 这里理论上 oldId 分支已经处理过大部分情况了 兜底
            playFlyAnimation(icon, BackpackScrollingFrame, nil, true)
            icon:Destroy()
            equippedSlotFrames[slotName] = nil
        end
    end
    -- 如果是投掷物槽位变化，刷新 Skill1 上的投掷物提示
    if slotName == "throwable" then
        refreshSkill1FromEquipped()
    end
end)

-- 槽位按钮点击：卸下逻辑 + 悬浮查看属性
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
        -- 发请求：按槽位卸下
        print("[BackpackUi] 向服务器请求卸下槽位：", slotName)
        RE_CS_Unequip:FireServer(slotName)
    end)
    -- 槽位悬浮：临时预览（不点库存高亮框，不弹）
    btn.MouseEnter:Connect(function()
        local equippedId = currentEquippedState[slotName]
        local item = equippedId and currentBackpackState[equippedId] or nil
        if item then
            setHoverFocus(equippedId)
        end
    end)
    -- 槽位移出什么都不做显示最近悬浮物品
    btn.MouseLeave:Connect(function()
        hoverFocusId = nil -- 清一下临时标记，不影响展示
    end)
end
-- 开局：向服务器请求一次全量背包数据，避免错过首次 onChanged
RE_CS_Request:FireServer()

-- 调试日志
-- BackpackMainFrame.AncestryChanged:Connect(function(child, parent)
--     print("[BackpackUi] BackpackMainFrame.AncestryChanged, newParent =", parent)
-- end)

-- 玩家角色生命周期监听，死亡时刷新背包
-- 记录 Humanoid.Died 的连接，防止挂一堆
local humanoidDiedConn: RBXScriptConnection? = nil
-- 工具：玩家死亡时回调
local function onLocalHumanoidDied()
	-- 死了就向服务器要一份最新快照
	RE_CS_Request:FireServer()
	-- 1207：死亡强制关背包，防止舞台/射击相机跨旧角色状态打架
	pcall(function()
		UIController.closeScreen("Backpack")
	end)
end
-- 工具：绑定当前角色的 Humanoid.Died
local function hookCharacter(char: Model)
    -- 先把旧角色的监听断掉
    if humanoidDiedConn then
        humanoidDiedConn:Disconnect()
        humanoidDiedConn = nil
    end
    -- 角色里找 Humanoid
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        humanoidDiedConn = hum.Died:Connect(onLocalHumanoidDied)
    else
        -- 极端情况：Humanoid 还没挂上来，等 ChildAdded 一次
        char.ChildAdded:Connect(function(child)
            if humanoidDiedConn then
                return
            end
            if child:IsA("Humanoid") then
                humanoidDiedConn = child.Died:Connect(onLocalHumanoidDied)
            end
        end)
    end
end
-- 玩家当前角色
if localPlayer.Character then
    hookCharacter(localPlayer.Character)
end
-- 后续重生也要重新挂一次
localPlayer.CharacterAdded:Connect(hookCharacter)