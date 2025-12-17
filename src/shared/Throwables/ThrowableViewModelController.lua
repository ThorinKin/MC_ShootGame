-- ReplicatedStorage/Shared/Throwables/ThrowableViewModelController.lua
-- 总注释：投掷物第一人称视模控制器。
--!nocheck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local Workspace         = game:GetService("Workspace")

local Constants               = require(ReplicatedStorage.Blaster.Constants)
local disconnectAndClear      = require(ReplicatedStorage.Utility.disconnectAndClear)
local lerp                    = require(ReplicatedStorage.Utility.lerp)
local bindSoundsToAnimationEvents = require(ReplicatedStorage.Blaster.Utility.bindSoundsToAnimationEvents)

local AssetsRoot          = ReplicatedStorage:WaitForChild("Assets")
local ViewModelsFolder    = AssetsRoot:WaitForChild("ThrowablesViewModels")

local camera      = Workspace.CurrentCamera
local audioTarget = SoundService.Audio.Busses.World.AudioCompressor

local BIND_NAME = Constants.THROWABLE_VIEW_MODEL_BIND_NAME or "ThrowableViewModel"

local ThrowableViewModelController = {}
ThrowableViewModelController.__index = ThrowableViewModelController

-- 构造函数：传进来的是服务端克出来挂在角色下的那把 Tool
function ThrowableViewModelController.new(tool: Tool)
	-- 和 Blaster 一样，用 Handle 速度做 bobbing
	local handle = tool:WaitForChild("Handle") :: BasePart
	local sounds = tool:FindFirstChild("Sounds")

	local subType = tool:GetAttribute("SubType") or tool.Name
	local viewModelName = tool:GetAttribute("ThrowableViewModel") or subType

	local template = ViewModelsFolder:FindFirstChild(viewModelName)
	assert(template, (`[ThrowableViewModel] 找不到视模 "%s"`):format(viewModelName))

	local viewModel = template:Clone()

	local animController = viewModel:FindFirstChildOfClass("AnimationController")
	assert(animController, "[ThrowableViewModel] 视模缺少 AnimationController")
	local animator = animController:FindFirstChildOfClass("Animator")
	assert(animator, "[ThrowableViewModel] 视模缺少 Animator")

	local animationsFolder = viewModel:FindFirstChild("Animations")
	assert(animationsFolder, "[ThrowableViewModel] 视模缺少 Animations 文件夹")

	-- 先挂到 ReplicatedStorage，避免没挂 DataModel 时 LoadAnimation 报错
	viewModel.Parent = ReplicatedStorage

	local animations = {}
	for _, animation in ipairs(animationsFolder:GetChildren()) do
		if animation:IsA("Animation") then
			local track = animator:LoadAnimation(animation)
			animations[animation.Name] = track

			-- 声音用动画事件驱动，和枪保持一致
			if sounds then
				bindSoundsToAnimationEvents(track, sounds, audioTarget)
			end
		end
	end

	-- 视模偏移，优先用 Constants.THROWABLE_VIEW_MODEL_OFFSET，
	-- 再退回枪的 VIEW_MODEL_OFFSETS.Default，实在没有就给个保底
	local baseOffset = Constants.THROWABLE_VIEW_MODEL_OFFSET
		or (Constants.VIEW_MODEL_OFFSETS and Constants.VIEW_MODEL_OFFSETS.Default)
		or CFrame.new(0.8, -0.7, -1.5)

	local self = {
		enabled       = false,
		tool          = tool,
		handle        = handle,
		model         = viewModel,
		animations    = animations,
		toolInstances = {},   -- 被隐藏的 Tool 部件
		connections   = {},
		stride        = 0,
		bobbing       = 0,

		baseOffset    = baseOffset,
		currentOffset = baseOffset,
	}

	setmetatable(self, ThrowableViewModelController)
	return self
end

-- 工具：收集 / 隐藏 Tool 本体的部件
function ThrowableViewModelController:_checkToolInstance(instance: Instance)
	if not (instance:IsA("BasePart") or instance:IsA("Decal")) then
		return
	end

	local tool = instance:FindFirstAncestorOfClass("Tool")
	if not tool or tool ~= self.tool then
		return
	end

	table.insert(self.toolInstances, instance)
end

function ThrowableViewModelController:_startHidingToolInstances()
	local character = self.tool.Parent
	if not character then
		return
	end

	table.insert(self.connections, character.DescendantAdded:Connect(function(descendant)
		self:_checkToolInstance(descendant)
	end))

	table.insert(self.connections, character.DescendantRemoving:Connect(function(descendant)
		local index = table.find(self.toolInstances, descendant)
		if index then
			table.remove(self.toolInstances, index)
		end
	end))

	for _, d in ipairs(character:GetDescendants()) do
		self:_checkToolInstance(d)
	end
end

function ThrowableViewModelController:_stopHidingToolInstances()
	for _, inst in ipairs(self.toolInstances) do
		if inst:IsA("BasePart") or inst:IsA("Decal") then
			inst.LocalTransparencyModifier = 0
		end
	end
	table.clear(self.toolInstances)
	disconnectAndClear(self.connections)
end

-- 每帧更新：bob 动 + 绑定到相机
function ThrowableViewModelController:update(deltaTime: number)
	-- 持续把真 Tool 隐形
	for _, inst in ipairs(self.toolInstances) do
		if inst:IsA("BasePart") or inst:IsA("Decal") then
			inst.LocalTransparencyModifier = 1
		end
	end

	-- 位移 bobbing
	local moveSpeed = (self.handle.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
	local bobbingSpeed = moveSpeed * Constants.VIEW_MODEL_BOBBING_SPEED
	local bobbing = math.min(bobbingSpeed, 1)

	self.stride = (self.stride + bobbingSpeed * deltaTime) % (math.pi * 2)
	self.bobbing = lerp(self.bobbing, bobbing, math.min(deltaTime * Constants.VIEW_MODEL_BOBBING_TRANSITION_SPEED, 1))

	local x = math.sin(self.stride)
	local y = math.sin(self.stride * 2)
	local bobbingOffset = Vector3.new(x, y, 0) * Constants.VIEW_MODEL_BOBBING_AMOUNT * self.bobbing
	local bobbingCFrame = CFrame.new(bobbingOffset)

	camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	-- 目前没有瞄准 / 冲刺就直接往 baseOffset lerp
	local t = math.min(deltaTime * Constants.VIEW_MODEL_BOBBING_TRANSITION_SPEED, 1)
	self.currentOffset = self.currentOffset:Lerp(self.baseOffset, t)

	self.model:PivotTo(camera.CFrame * self.currentOffset * bobbingCFrame)
end

-- 动画辅助：方便 Controller 调
function ThrowableViewModelController:playEquip()
	local equip = self.animations.Equip or self.animations.Pull or self.animations.Idle
	if equip then
		equip:Play(0.1)
	end
end

function ThrowableViewModelController:playChargeIdle()
	local idle = self.animations.ChargeIdle or self.animations.Idle
	if idle then
		idle.Looped = true
		if not idle.IsPlaying then
			idle:Play(0.1)
		end
	end
end

function ThrowableViewModelController:playThrow()
	local throw = self.animations.Throw
	if throw then
		throw.Looped = false
		throw:Play(0.05)
	end
end

function ThrowableViewModelController:stopAllAnimations()
	for _, track in pairs(self.animations) do
		track:Stop(0.05)
	end
end

-- 启用 / 停用
function ThrowableViewModelController:enable()
	if self.enabled then
		return
	end
	self.enabled = true

	RunService:BindToRenderStep(
		BIND_NAME,
		Enum.RenderPriority.Camera.Value + 2,
		function(dt: number)
			self:update(dt)
		end
	)

	self.model.Parent = Workspace
	self:_startHidingToolInstances()

	-- 默认播 Idle + Equip 一套
	if self.animations.Idle then
		self.animations.Idle.Looped = true
		self.animations.Idle:Play(0)
	end
	self:playEquip()
end

function ThrowableViewModelController:disable()
	if not self.enabled then
		return
	end
	self.enabled = false

	RunService:UnbindFromRenderStep(BIND_NAME)
	self.model.Parent = nil
	self:_stopHidingToolInstances()
	self:stopAllAnimations()
end

function ThrowableViewModelController:destroy()
	self:disable()
	if self.model then
		self.model:Destroy()
	end
end

return ThrowableViewModelController
