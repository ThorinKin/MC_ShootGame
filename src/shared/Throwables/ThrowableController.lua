-- ReplicatedStorage/Shared/Throwables/ThrowableController.lua
-- 总注释：单个投掷物 Tool 的客户端控制器。
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Workspace         = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer

local ThrowableInput = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Throwables"):WaitForChild("ThrowableInput"))
-- 视模控制器
local ThrowableViewModelController = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Throwables"):WaitForChild("ThrowableViewModelController"))
local PlayerViewState = require(ReplicatedStorage.Shared.ViewControl.PlayerViewState)
local WeaponState = require(ReplicatedStorage.Shared.ViewControl.WeaponState)
local GameplayLock = require(ReplicatedStorage.Shared.ViewControl.DisableEnableLock) -- 全局锁

-- Remotes
local RemotesRoot      = ReplicatedStorage:WaitForChild("Remotes")
local ThrowableRemotes = RemotesRoot:WaitForChild("Throwables")
local RE_CS_Throw      = ThrowableRemotes:WaitForChild("[C-S]ThrowableThrow")

local camera = Workspace.CurrentCamera

local ThrowableController = {}
ThrowableController.__index = ThrowableController

-- 构造函数
function ThrowableController.new(tool: Tool)
    local self = {
        tool                 = tool,
        state                = "Idle",   -- Idle / Charging / Throwing / Finished
        chargeStartTime      = nil,
        maxChargeTime        = tool:GetAttribute("MaxChargeTime") or 1.0,
        characterAnimations  = {},       -- name -> AnimationTrack
        releaseConn          = nil,
        humanoidDiedConn     = nil,
        subType              = tool:GetAttribute("SubType") or tool.Name,
        itemId               = tool:GetAttribute("BackpackItemId"),
        viewModelController  = nil,
        viewModeConn         = nil, -- 视角变化监听
        lockConn             = nil, -- 1216新：全局锁监听（UI/舞台）
    }
    setmetatable(self, ThrowableController)
    -- 初始化视模控制器（如视模缺失，内部 assert 报错）
    local ok, vmOrErr = pcall(function()
        return ThrowableViewModelController.new(tool)
    end)
    if ok then
        self.viewModelController = vmOrErr
    else
        warn("[ThrowableController] 初始化视模失败：", vmOrErr)
    end
    -- 告诉输入模块：我现在是激活控制器
    ThrowableInput.setActiveController(self)
    return self
end

-- 1216新：是否全局锁定
function ThrowableController:isGameplayLocked(): boolean
	local character = self.tool.Parent
	return character and character:IsA("Model") and GameplayLock.isLocked(character)
end

-- 当这把投掷物 Tool 被 Humanoid 装备时调用
function ThrowableController:onEquipped()
    local character = self.tool.Parent
    if character and character:IsA("Model") then
        -- 这里认为拿着雷也是战斗状态，视为 Armed
        WeaponState.setEquipped(character, true, "Throwable")
        -- 第一次真正拿在手上时再加载动画 / 绑定死亡事件
        if not next(self.characterAnimations) then
            self:_loadCharacterAnimations()
        end
        if not self.humanoidDiedConn then
            self:_hookHumanoidDied()
        end
        -- 监听 ViewMode 变化：切视角时同步开关视模
        if self.viewModeConn then
            self.viewModeConn:Disconnect()
            self.viewModeConn = nil
        end
        self.viewModeConn = character:GetAttributeChangedSignal("ViewMode"):Connect(function()
            self:_updateForViewMode()
        end)
    end
    -- 1216新：监听 GameplayLocked，UI/舞台期间强制取消本轮投掷（不丢出）
    if self.lockConn then
        self.lockConn:Disconnect()
        self.lockConn = nil
    end
    -- 只有在 character 是 Model 时才监听 GameplayLocked
    if character and character:IsA("Model") then
        self.lockConn = character:GetAttributeChangedSignal("GameplayLocked"):Connect(function()
            if self:isGameplayLocked() then
                self:cancel("ui_lock", true) -- keepEquipped=true
            end
        end)
        -- 如果装备瞬间 UI 已经开着，立刻收一次
        if self:isGameplayLocked() then
            self:cancel("ui_lock", true)
        end
    end
    -- 立刻按当前视角状态刷新一次视模启用/禁用
    self:_updateForViewMode()
end

-- 当 Tool 被卸下 / 销毁时调用
function ThrowableController:onUnequipped()
    local character = self.tool.Parent
    if character and character:IsA("Model") then
        -- 手里不再拿武器（接下来 Humanoid 会去 Equip 别的）
        WeaponState.setEquipped(character, false)
    end
    -- 关掉视模
    if self.viewModelController and self.viewModelController.disable then
        self.viewModelController:disable()
    end
    if self.viewModeConn then
        self.viewModeConn:Disconnect()
        self.viewModeConn = nil
    end
    -- 1216新：断开全局锁监听
    if self.lockConn then
        self.lockConn:Disconnect()
        self.lockConn = nil
    end
end

-- 内部：加载角色动画（来自 Tool.Animations）
function ThrowableController:_loadCharacterAnimations()
    if next(self.characterAnimations) ~= nil then
        return -- 已经加载过就不重复
    end
    local animationsFolder = self.tool:FindFirstChild("Animations")
    if not animationsFolder then
        warn("[ThrowableController] Tool 缺少 Animations 文件夹：", self.tool.Name)
        return
    end
    local character = self.tool.Parent
    if not character then
        return
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        warn("[ThrowableController] 找不到 Humanoid，无法加载投掷动画")
        return
    end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    local tracks = {}
    for _, anim in ipairs(animationsFolder:GetChildren()) do
        if anim:IsA("Animation") then
            local track = animator:LoadAnimation(anim)
            tracks[anim.Name] = track
        end
    end
    self.characterAnimations = tracks
    -- Throw 上挂载 Release 事件
    local throwTrack = tracks.Throw
    if throwTrack then
        self.releaseConn = throwTrack:GetMarkerReachedSignal("Release"):Connect(function()
            self:_onReleaseMarker()
        end)
    else
        warn("[ThrowableController] 投掷动画 Throw 缺失，Release Marker 将无法触发服务器")
    end
end

-- 内部：角色死亡时中断本次投掷
function ThrowableController:_hookHumanoidDied()
    if self.humanoidDiedConn then
        self.humanoidDiedConn:Disconnect()
        self.humanoidDiedConn = nil
    end
    local character = self.tool.Parent
    if not character then
        return
    end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid then
        return
    end
    self.humanoidDiedConn = humanoid.Died:Connect(function()
        self:cancel("humanoid_died")
    end)
end

-- 工具：根据 ViewMode + 当前状态 开关第一人称视模
function ThrowableController:_updateForViewMode()
    if not self.viewModelController then
        return
    end
    local character = self.tool.Parent
    if not character or not character:IsA("Model") then
        -- 不在角色身上的时候，兜底关掉视模
        if self.viewModelController.disable then
            self.viewModelController:disable()
        end
        return
    end
    local mode = character:GetAttribute("ViewMode")
    -- 没打标默认按第一人称处理，跟 Blaster 一致
    local isFP = (mode == nil or mode == PlayerViewState.ViewMode.FirstPerson)
    -- 仅 蓄力 / 投掷 时才允许显示视模，避免单纯装备就进 Idle
    local inUse = (self.state == "Charging" or self.state == "Throwing")

    if isFP and inUse then
        if self.viewModelController.enable then
            self.viewModelController:enable()
        end
    else
        if self.viewModelController.disable then
            self.viewModelController:disable()
        end
    end
end

-- 输入模块回调：按下 Skill1（或键盘 1）
function ThrowableController:onSkill1Pressed()
    -- 1216新：全局锁
    if self:isGameplayLocked() then
        return
    end
    -- 已经在投掷流程中就不重复开始
    if self.state ~= "Idle" and self.state ~= "Finished" then
        return
    end
    self.state = "Charging"
    self.chargeStartTime = tick()
    local anims = self.characterAnimations
    -- 掏出 / 拉环：优先 Pull，没有就直接 ChargeIdle
    local pullTrack = anims.Pull or anims.Equip
    if pullTrack then
        pullTrack:Play(0.1)
    end
    -- 蓄力待机：ChargeIdle，没有就用 Idle 顶上
    local chargeTrack = anims.ChargeIdle or anims.Idle
    if chargeTrack then
        chargeTrack.Looped = true
        if not chargeTrack.IsPlaying then
            chargeTrack:Play(0.1)
        end
    end
    -- 视模：仅在第一人称 + 正在蓄力时显示，由状态机统一控制
    if self.viewModelController then
        self:_updateForViewMode()
        if self.viewModelController.playChargeIdle then
            self.viewModelController:playChargeIdle()
        end
    end
end

-- 输入模块回调：松开 Skill1（或键盘 1）
function ThrowableController:onSkill1Released()
    -- 1216新：全局锁
    if self:isGameplayLocked() then
        return
    end
    if self.state ~= "Charging" then
        return -- 没有处于蓄力状态，忽略
    end
    self.state = "Throwing"
    local anims = self.characterAnimations
    -- 停掉 ChargeIdle，让 Throw 接管
    local chargeTrack = anims.ChargeIdle or anims.Idle
    if chargeTrack and chargeTrack.IsPlaying then
        chargeTrack:Stop(0.05)
    end
    local throwTrack = anims.Throw
    if throwTrack then
        throwTrack.Looped = false
        throwTrack:Play(0.1)
    else
        -- 没有 Throw 动画：直接走 Release 逻辑
        self:_onReleaseMarker()
    end
    -- 视模：根据当前视角刷新一次，再播 Throw
    if self.viewModelController then
        self:_updateForViewMode()
        if self.viewModelController.playThrow then
            self.viewModelController:playThrow()
        end
    end
end

-- 内部：Throw 动画的 Release Marker 回调
-- 负责计算投掷力度 / 方向，并请求服务器生成实体
function ThrowableController:_onReleaseMarker()
    -- 1216新：全局锁
    if self:isGameplayLocked() then
        return
    end
    if self.state ~= "Throwing" and self.state ~= "Charging" then
        -- 防御：意外状态下不重复丢
        return
    end
    self.state = "Finished"
    -- 计算蓄力比例（0~1）
    local now = tick()
    local heldTime = 0
    if self.chargeStartTime then
        heldTime = math.max(0, now - self.chargeStartTime)
    end
    local maxCharge = self.maxChargeTime > 0 and self.maxChargeTime or 1
    local chargeRatio = math.clamp(heldTime / maxCharge, 0, 1)

    -- 起点：默认用 Handle 位置
    local handle = self.tool:FindFirstChild("Handle")
    local origin = handle and handle.Position or (self.tool.Parent and self.tool.Parent.PrimaryPart and self.tool.Parent.PrimaryPart.Position) or Vector3.new()

    -- 方向：默认用当前摄像机朝向（比较符合 FPS 向前扔的感觉）
    camera = Workspace.CurrentCamera
    local dir = camera and camera.CFrame.LookVector or Vector3.new(0, 1, 0)

    -- 服务器需要知道：是哪件背包物品、什么子类型、起点 / 方向 / 蓄力比例
    local itemId  = self.itemId
    local subType = self.subType

    if not itemId or itemId == "" then
        -- 如果服务器没在 Tool 上写 BackpackItemId，也能靠 subType 做兜底，但最好写
        warn("[ThrowableController] Tool 上缺少 BackpackItemId 属性，建议在服务端生成 Tool 时 SetAttribute")
    end
    RE_CS_Throw:FireServer(itemId, subType, origin, dir, chargeRatio)
    -- 客户端这边的 Tool 不用自己 Destroy，交给服务器来删，避免不同步
end

-- 外部：取消本轮投掷（角色死亡 / 服务器强制中断 / UI锁定）
function ThrowableController:cancel(reason: string?, keepEquipped: boolean?)
    self.state = "Finished"
    self.chargeStartTime = nil
    for _, track in pairs(self.characterAnimations) do
        if track.IsPlaying then
            track:Stop(0.05)
        end
    end
    if self.viewModelController and self.viewModelController.disable then
        self.viewModelController:disable()
    end
    -- 1216新：UI锁定属于临时停用，不应该把 WeaponEquipped 清掉，否则解锁后状态错乱
    if not keepEquipped then
        -- 同步一份不持武器兜底避免死在半路上 WeaponEquipped 卡住
        self:onUnequipped()
    end
end


-- 销毁
function ThrowableController:destroy()
    ThrowableInput.clearController(self)
    if self.releaseConn then
        self.releaseConn:Disconnect()
        self.releaseConn = nil
    end
    if self.humanoidDiedConn then
        self.humanoidDiedConn:Disconnect()
        self.humanoidDiedConn = nil
    end
    if self.viewModeConn then
        self.viewModeConn:Disconnect()
        self.viewModeConn = nil
    end
    if self.lockConn then
        self.lockConn:Disconnect()
        self.lockConn = nil
    end
    for _, track in pairs(self.characterAnimations) do
        track:Stop(0)
    end
    self.characterAnimations = {}
    if self.viewModelController and self.viewModelController.destroy then
        self.viewModelController:destroy()
    end
    self:onUnequipped() -- 兜底再来一次
end

return ThrowableController
