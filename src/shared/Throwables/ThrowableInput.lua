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

-- 全局锁
local GameplayLock = require(ReplicatedStorage.Shared.ViewControl.DisableEnableLock)
-- 工具：是否全局锁定
local function isLocked()
	return GameplayLock.isLocked(localPlayer.Character)
end

-- Skill1 按钮路径（和 BackpackUi 一致）
local function resolveSkillButton(): ImageButton?
    local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
    if not playerGui then
        return nil
    end
    local ok, HUDGui = pcall(function()
        return playerGui:WaitForChild("HUD", 5)
    end)
    if not ok or not HUDGui then
        return nil
    end

    local success, Skill1Button = pcall(function()
        local HUD_Bottom = HUDGui:WaitForChild("Bottom")
        local HUD_Frame = HUD_Bottom:WaitForChild("StatusBar")
        local HUD_Player = HUD_Frame:WaitForChild("Player")
        return HUD_Player:WaitForChild("Skill1")
    end)

    if success and Skill1Button and Skill1Button:IsA("ImageButton") then
        return Skill1Button
    end

    return nil
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
}

-- 1216新：锁住时强制取消投掷输入（不触发 Throw）
local function forceCancelForLock(reason: string?)
	-- 直接把“按住状态”清空，避免解锁后误触发
	state.keyHeld = false
	state.buttonHeld = false
	state.isHeld = false

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
		-- 从按住 → 松开
		if controller and controller.onSkill1Released then
			controller:onSkill1Released()
		end
	end
end

local function recomputeHeld()
    local newHeld = state.keyHeld or state.buttonHeld
    onHeldStateChanged(newHeld)
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
    state.skillButton = resolveSkillButton()
    local btn = state.skillButton
    if btn then
        -- 初始属性读一次
        state.currentItemId = btn:GetAttribute("ThrowableItemId")
        local has = btn:GetAttribute("HasThrowable")
        state.hasThrowable = (has == true)
        -- 监听属性变化
        table.insert(state.connections, btn:GetAttributeChangedSignal("ThrowableItemId"):Connect(function()
            state.currentItemId = btn:GetAttribute("ThrowableItemId")
        end))

        table.insert(state.connections, btn:GetAttributeChangedSignal("HasThrowable"):Connect(function()
            local hasNow = btn:GetAttribute("HasThrowable")
            state.hasThrowable = (hasNow == true)
        end))
        -- 按钮按下 / 松开视为 Skill1 按下 / 松开
        table.insert(state.connections, btn.MouseButton1Down:Connect(function()
            state.buttonHeld = true
            recomputeHeld()
        end))

        table.insert(state.connections, btn.MouseButton1Up:Connect(function()
            state.buttonHeld = false
            recomputeHeld()
        end))

        -- 防止按下后鼠标移出不触发 MouseButton1Up：用 InputEnded 兜底
        table.insert(state.connections, btn.MouseLeave:Connect(function()
            -- 如果鼠标离开时仍按着，可以自行扩展判断；先简单起见不处理
        end))
    end
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
