-- ReplicatedStorage/Shared/Throwables/ThrowableInput.lua
-- 总注释：投掷物输入与激活调度模块。
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer

-- Remotes
local RemotesRoot      = ReplicatedStorage:WaitForChild("Remotes")
local ThrowableRemotes = RemotesRoot:WaitForChild("Throwables")
local RE_CS_Begin      = ThrowableRemotes:WaitForChild("[C-S]ThrowableBegin")

-- PC/触屏 HUD
local HudRegistry = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UI"):WaitForChild("HudRegistry"))
-- 全局锁
local GameplayLock = require(ReplicatedStorage.Shared.ViewControl.DisableEnableLock)
-- 工具：是否全局锁定
local function isLocked()
	return GameplayLock.isLocked(localPlayer.Character)
end

-- 内部状态
local state = {
    inited           = false,
    activeController = nil,   -- 当前绑定的 ThrowableController
    skillButton      = nil,   -- HUD 里的 Skill1 按钮
    hasThrowable     = false, -- Skill1 上是否有投掷物
    currentItemId    = nil,   -- Skill1 映射的背包 itemId
    keyHeld          = false, -- 键盘 1 是否按住
    buttonHeld       = false, -- Skill1Button 是否按住
    isHeld           = false, -- 综合状态：keyHeld or buttonHeld
    connections      = {},
    lockConn         = nil,   -- 1216新：监听 GameplayLocked 全局锁
    holdStartTime = nil,
    pendingReleaseHeldTime = nil, -- 点按补偿
}

-- 1216新：锁住时强制取消投掷输入（不触发 Throw）
local function forceCancelForLock(reason: string?)
	-- 直接把“按住状态”清空，避免解锁后误触发
	state.keyHeld = false
	state.buttonHeld = false
	state.isHeld = false
    state.holdStartTime = nil
    state.pendingReleaseHeldTime = nil

	local controller = state.activeController
	if controller and controller.cancel then
		-- pcall 防止 controller 里 assert 把输入模块炸掉
		pcall(function()
			controller:cancel(reason or "ui_lock", true)
		end)
	end
end

-- 工具：统一处理按下 / 松开状态切换
local function onHeldStateChanged(newHeld: boolean)
	-- 1216新：全局锁
	if isLocked() then
		forceCancelForLock("ui_lock") 
		return
	end
	if state.isHeld == newHeld then
		return
	end
	state.isHeld = newHeld
	local controller = state.activeController
	if newHeld then
        state.pendingReleaseHeldTime = nil
        state.holdStartTime = tick() -- 记录按下时间
		-- 第一次从没按 → 按下
		-- 1）如果 Skill1 上有投掷物，通知服务器开始一轮使用
		if state.hasThrowable and state.currentItemId then
			RE_CS_Begin:FireServer(state.currentItemId)
		end
		-- 2）如果当前已经有 Controller，则立刻通知
		if controller and controller.onSkill1Pressed then
			controller:onSkill1Pressed()
		end
    else
        local heldTime = 0
        if state.holdStartTime then
            heldTime = math.max(0, tick() - state.holdStartTime)
        end
        state.holdStartTime = nil

        if controller and controller.onSkill1Released then
            controller:onSkill1Released()
            state.pendingReleaseHeldTime = nil  -- 关键：别留下脏 pending
        else
            state.pendingReleaseHeldTime = heldTime
        end
    end
end

local function recomputeHeld()
    local newHeld = state.keyHeld or state.buttonHeld
    onHeldStateChanged(newHeld)
end

-- Skill1 按钮路径
local function resolveSkillButtonFromHud(hudGui: ScreenGui?): GuiButton?
	if not hudGui then return nil end
	local bottom = hudGui:FindFirstChild("Bottom")
	local status = bottom and bottom:FindFirstChild("StatusBar")
	local player = status and status:FindFirstChild("Player")
	local skill1 = player and player:FindFirstChild("Skill1")

	if skill1 and skill1:IsA("GuiButton") then
		return skill1
	end
	return nil
end
local function unbindSkillButton()
	-- 断掉旧 Skill1 的监听
	if state.skillConns then
		for _, c in ipairs(state.skillConns) do
			pcall(function() c:Disconnect() end)
		end
	end
	state.skillConns = {}
	state.skillButton = nil
	state.currentItemId = nil
	state.hasThrowable = false
	state.buttonHeld = false
	recomputeHeld()
end
local function bindSkillButton(btn: GuiButton?)
	unbindSkillButton()
	state.skillButton = btn
	if not btn then
		return
	end
	-- 初始读一次 attrs
	state.currentItemId = btn:GetAttribute("ThrowableItemId")
	state.hasThrowable = (btn:GetAttribute("HasThrowable") == true)
	-- attrs 变化监听
	table.insert(state.skillConns, btn:GetAttributeChangedSignal("ThrowableItemId"):Connect(function()
		state.currentItemId = btn:GetAttribute("ThrowableItemId")
	end))
	table.insert(state.skillConns, btn:GetAttributeChangedSignal("HasThrowable"):Connect(function()
		state.hasThrowable = (btn:GetAttribute("HasThrowable") == true)
	end))
	-- 移动端更稳：InputBegan / InputEnded
	table.insert(state.skillConns, btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
			state.buttonHeld = true
			recomputeHeld()
		end
	end))
	table.insert(state.skillConns, btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1 then
			state.buttonHeld = false
			recomputeHeld()
		end
	end))
	-- 兜底：有些手机“点一下”InputEnded 会丢，这个当补刀
	table.insert(state.skillConns, btn.Activated:Connect(function()
		-- 点按：模拟一次按下+松开
		state.buttonHeld = true
		recomputeHeld()
		state.buttonHeld = false
		recomputeHeld()
	end))
end

-- 对外：给 ThrowableController 用的接口
local ThrowableInput = {}

-- 初始化
function ThrowableInput.init()
    if state.inited then
        return
    end
    state.inited = true
    -- 解析 Skill1 按钮
    state.skillConns = {}
    -- 初始化绑定当前活跃 HUD 的 Skill1
    local hudGui = HudRegistry.wait()
    bindSkillButton(resolveSkillButtonFromHud(hudGui))
    -- 运行中 HUD 切换（PC/移动切换、重生重建等）自动重绑
    table.insert(state.connections, HudRegistry.changed():Connect(function(newHud)
        -- 切换 HUD 时，清掉旧按住状态，避免粘住
        forceCancelForLock("hud_switch")
        bindSkillButton(resolveSkillButtonFromHud(newHud))
    end))

    -- 键盘 1：对应 Skill1
    table.insert(state.connections, UserInputService.InputBegan:Connect(function(input, gp)
        if gp then
            return
        end
        if input.KeyCode == Enum.KeyCode.One then
            state.keyHeld = true
            recomputeHeld()
        end
    end))

    table.insert(state.connections, UserInputService.InputEnded:Connect(function(input, gp)
        if gp then
            return
        end
        if input.KeyCode == Enum.KeyCode.One then
            state.keyHeld = false
            recomputeHeld()
        end
    end))

    -- 1216新：监听 GameplayLocked，UI/舞台期间强制 cancel 输入
    local function hookLockSignal(character: Model?)
        if state.lockConn then
            state.lockConn:Disconnect()
            state.lockConn = nil
        end
        if not character then
            return
        end
        state.lockConn = character:GetAttributeChangedSignal("GameplayLocked"):Connect(function()
            if isLocked() then
                forceCancelForLock("ui_lock")
            end
        end)
        -- 如果 init 时就处于锁定，立刻收一次
        if isLocked() then
            forceCancelForLock("ui_lock")
        end
    end
    hookLockSignal(localPlayer.Character)
    table.insert(state.connections, localPlayer.CharacterAdded:Connect(function(char)
        hookLockSignal(char)
    end))
end

-- 由 ThrowableController 调用：成为当前激活 Controller
function ThrowableInput.setActiveController(controller)
	state.activeController = controller
    -- 网络延迟，点按补偿
    if controller and state.pendingReleaseHeldTime and not isLocked() then
        local held = state.pendingReleaseHeldTime
        state.pendingReleaseHeldTime = nil
        if controller.onSkill1Pressed then
            controller:onSkill1Pressed()
        end
        -- 把蓄力起点往回拨，模拟真实按住 held 秒
        controller.chargeStartTime = tick() - held
        if controller.onSkill1Released then
            controller:onSkill1Released()
        end
        return
    end
	-- 如果此时 Skill1 已经按着，让新 Controller 立刻收到按下事件
	if controller and state.isHeld and not isLocked() and controller.onSkill1Pressed then
		controller:onSkill1Pressed()
	end
end

-- 由 ThrowableController 调用：自己销毁时解绑
function ThrowableInput.clearController(controller)
    if state.activeController == controller then
        state.activeController = nil
    end
end

-- 查询当前是否有投掷物（方便 Controller / 其他模块判断）
function ThrowableInput.hasThrowable()
    return state.hasThrowable and state.currentItemId ~= nil and state.currentItemId ~= ""
end

function ThrowableInput.getCurrentItemId()
    return state.currentItemId
end

return ThrowableInput
