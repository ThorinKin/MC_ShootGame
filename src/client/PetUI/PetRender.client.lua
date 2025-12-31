-- StarterPlayer/StarterPlayerScripts/Client/PetUI/PetRender.client.lua
-- 总注释：宠物渲染（客户端）。监听玩家 Player Attributes 本地 clone ReplicatedStorage/Assets/Pets/<kind> 模型，使用 Motor6D 绑定到 HumanoidRootPart，
-- 引擎负责跟随移动；装备变化时只更新一次偏移 对其他玩家做距离裁剪 远了不渲染
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local localPlayer = Players.LocalPlayer

-------------------------------可调参数-------------------------------
local MAX_SLOTS = 5  -- 最大槽位
-- 距离裁剪：仅影响其他玩家的宠物
local RENDER_DISTANCE = 160 -- studs
local CULL_CHECK_INTERVAL = 0.25 -- 0.25秒扫一次
-- 排布：横着排居中（相对 HumanoidRootPart 的局部坐标）
local SLOT_SPACING = 2.5 -- 横向间距
local OFFSET_Y     = 1.0 -- 抬高一点
local OFFSET_Z     = 7.0 -- 往后（+Z 是更后方）
-- 资产路径：ReplicatedStorage/Assets/Pets/<kind>
local PetsRoot = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Pets")
---------------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[PetRender] " .. string.format(fmt, ...))
	end
end

-- Attributes 命名
local function attrKindName(i: number): string
	return ("PetSlot%dKind"):format(i)
end

local ATTR_VER = "PetSlotsVer"

-- 内部状态：每个玩家一份渲染状态
type PlayerState = {
	player: Player,
	char: Model?,
	hrp: BasePart?,
	petsFolder: Folder?,
	petModels: {[number]: Model},
	motors: {[number]: Motor6D},
	desiredKinds: {[number]: string?},
	dirty: boolean,
	conns: {RBXScriptConnection},
}

local statesByPlayer: {[Player]: PlayerState} = {}

-- 工具：安全拿 Character + HRP
local function getHRP(char: Model?): BasePart?
	if not (char and char.Parent) then
		return nil
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

-- 工具：算当前玩家 Attributes 里的目标 kind 列表
local function readDesiredKinds(plr: Player): {[number]: string?}
	local desired = {}
	for i = 1, MAX_SLOTS do
		local v = plr:GetAttribute(attrKindName(i))
		if type(v) == "string" and v ~= "" then
			desired[i] = v
		else
			desired[i] = nil
		end
	end
	return desired
end

-- 工具：把有宠物的槽位按槽位顺序收集起来，用于横排居中
local function buildActiveSlots(desiredKinds: {[number]: string?}): {number}
	local slots = {}
	for i = 1, MAX_SLOTS do
		if desiredKinds[i] then
			table.insert(slots, i)
		end
	end
	return slots
end

-- 工具：按 activeSlots 的第几个算偏移（居中横排）
local function computeC0(indexInActive: number, activeCount: number): CFrame
	local totalWidth = (activeCount - 1) * SLOT_SPACING
	local x = -totalWidth / 2 + (indexInActive - 1) * SLOT_SPACING
	return CFrame.new(x, OFFSET_Y, OFFSET_Z)
end

-- 工具：给克隆出来的宠物模型做兜底处理（关碰撞/触碰/查询/开Massless/所有部件 Weld 到 PrimaryPart）
local function prepPetModel(model: Model)
	local root = model.PrimaryPart
	if not (root and root:IsA("BasePart")) then
		-- 没 PrimaryPart 就随便找一个 BasePart 当 root
		root = model:FindFirstChildWhichIsA("BasePart", true)
		if not root then
			return
		end
		pcall(function()
			model.PrimaryPart = root
		end)
	end
	-- 统一设置所有 BasePart
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") then
			inst.Anchored = false
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
			inst.Massless = true
			inst.CastShadow = false
		end
	end
	-- WeldConstraint：把非 root 的部件全焊到 root
	for _, inst in ipairs(model:GetDescendants()) do
		if inst:IsA("BasePart") and inst ~= root then
			local wc = Instance.new("WeldConstraint")
			wc.Part0 = root
			wc.Part1 = inst
			wc.Parent = root
		end
	end
end

-- 工具：创建/确保 PetsFolder
local function ensurePetsFolder(st: PlayerState)
	if not (st.char and st.char.Parent) then
		return
	end
	if st.petsFolder and st.petsFolder.Parent == st.char then
		return
	end
	-- 重建
	if st.petsFolder then
		st.petsFolder:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "PetsFolder"
	folder.Parent = st.char
	st.petsFolder = folder
end

-- 工具：销毁某个槽位的渲染（模型 + Motor6D）
local function destroySlotRender(st: PlayerState, slotIndex: number)
	local m = st.motors[slotIndex]
	if m then
		m:Destroy()
		st.motors[slotIndex] = nil
	end
	local model = st.petModels[slotIndex]
	if model then
		model:Destroy()
		st.petModels[slotIndex] = nil
	end
end

-- 工具：创建或更新某个槽位渲染
local function ensureSlotRender(st: PlayerState, slotIndex: number, kind: string, c0: CFrame)
	if not (st.hrp and st.hrp.Parent) then
		return
	end
	ensurePetsFolder(st)
	if not (st.petsFolder and st.petsFolder.Parent) then
		return
	end

	local existing = st.petModels[slotIndex]
	local sameKind = false
	if existing and existing.Parent then
		local k = existing:GetAttribute("Kind")
		if type(k) == "string" and k == kind then
			sameKind = true
		end
	end

	-- kind 不同：先干掉旧的
	if existing and (not sameKind) then
		destroySlotRender(st, slotIndex)
	end

	-- 有旧的同 kind：只更新偏移
	if sameKind then
		local motor = st.motors[slotIndex]
		if motor and motor.Parent then
			motor.C0 = c0
		end
		return
	end

	-- 创建新模型
	local template = PetsRoot:FindFirstChild(kind)
	if not (template and template:IsA("Model")) then
		warn(("[PetRender] Missing pet asset model: %s"):format(tostring(kind)))
		return
	end

	local model = template:Clone()
	model.Name = ("PetSlot_%d_%s"):format(slotIndex, kind)
	model:SetAttribute("Kind", kind)
	model.Parent = st.petsFolder

	prepPetModel(model)

	local root = model.PrimaryPart
	if not (root and root:IsA("BasePart")) then
		model:Destroy()
		return
	end

	-- 初次摆到目标位置，减少创建瞬间弹一下
	pcall(function()
		model:PivotTo(st.hrp.CFrame * c0)
	end)

	-- 建 Motor6D：Part0=HRP, Part1=petRoot
	local motor = Instance.new("Motor6D")
	motor.Name = ("PetMotor_%d"):format(slotIndex)
	motor.Part0 = st.hrp
	motor.Part1 = root
	motor.C0 = c0
	motor.C1 = CFrame.new()
	motor.Parent = st.hrp

	st.petModels[slotIndex] = model
	st.motors[slotIndex] = motor
end

-- 工具：是否需要渲染（距离裁剪）
local function shouldRenderForPlayer(targetPlayer: Player, targetHrp: BasePart?): boolean
	-- 自己永远渲染
	if targetPlayer == localPlayer then
		return true
	end
	if not targetHrp then
		return false
	end

	local myChar = localPlayer.Character
	local myHrp = getHRP(myChar)
	if not myHrp then
		return false
	end

	local dist = (myHrp.Position - targetHrp.Position).Magnitude
	return dist <= RENDER_DISTANCE
end

-- 工具：同步一次（dirty 时调用）
local function syncPlayerPets(st: PlayerState)
	local plr = st.player
	if not (plr and plr.Parent) then
		return
	end

	-- 刷新 char/hrp
	st.char = plr.Character
	st.hrp = getHRP(st.char)

	-- 距离裁剪：不渲染就直接清空 保留 desiredKinds 缓存，靠下一次 near 再重建
	local renderOk = shouldRenderForPlayer(plr, st.hrp)
	if not renderOk then
		for i = 1, MAX_SLOTS do
			destroySlotRender(st, i)
		end
		-- PetsFolder 也顺手清掉，省一点
		if st.petsFolder then
			st.petsFolder:Destroy()
			st.petsFolder = nil
		end
		return
	end

	if not st.hrp then
		-- 角色还没 HRP，等下次循环再来
		return
	end

	-- 读目标 kinds
	st.desiredKinds = readDesiredKinds(plr)
	local activeSlots = buildActiveSlots(st.desiredKinds)
	local activeCount = #activeSlots

	-- 没宠物：清空并返回
	if activeCount == 0 then
		for i = 1, MAX_SLOTS do
			destroySlotRender(st, i)
		end
		return
	end

	-- 先把应该存在的槽位渲染出来
	for idxInActive, slotIndex in ipairs(activeSlots) do
		local kind = st.desiredKinds[slotIndex]
		if kind then
			local c0 = computeC0(idxInActive, activeCount)
			ensureSlotRender(st, slotIndex, kind, c0)
		end
	end

	-- 把应该不存在的槽位清掉
	for i = 1, MAX_SLOTS do
		if not st.desiredKinds[i] then
			destroySlotRender(st, i)
		end
	end
end

-- 两个工具：玩家追踪：绑定事件
local function cleanupState(st: PlayerState)
	for _, c in ipairs(st.conns) do
		c:Disconnect()
	end
	st.conns = {}

	for i = 1, MAX_SLOTS do
		destroySlotRender(st, i)
	end
	if st.petsFolder then
		st.petsFolder:Destroy()
		st.petsFolder = nil
	end
end
local function trackPlayer(plr: Player)
	if statesByPlayer[plr] then
		return
	end

	local st: PlayerState = {
		player = plr,
		char = plr.Character,
		hrp = nil,
		petsFolder = nil,
		petModels = {},
		motors = {},
		desiredKinds = {},
		dirty = true,
		conns = {},
	}
	st.hrp = getHRP(st.char)

	statesByPlayer[plr] = st

	-- 角色重生：重建 PetsFolder + 重新渲染
	table.insert(st.conns, plr.CharacterAdded:Connect(function(char)
		st.char = char
		st.hrp = nil
		st.dirty = true
	end))

	-- Attributes 变化：标记 dirty
	for i = 1, MAX_SLOTS do
		local attr = attrKindName(i)
		table.insert(st.conns, plr:GetAttributeChangedSignal(attr):Connect(function()
			st.dirty = true
		end))
	end
	-- 版本号变化也算 服务端每次刷新都会 +1
	table.insert(st.conns, plr:GetAttributeChangedSignal(ATTR_VER):Connect(function()
		st.dirty = true
	end))

	-- 初次同步
	st.dirty = true
end

-- 初始化：追踪所有玩家
Players.PlayerAdded:Connect(trackPlayer)
Players.PlayerRemoving:Connect(function(plr)
	local st = statesByPlayer[plr]
	if st then
		cleanupState(st)
		statesByPlayer[plr] = nil
	end
end)

for _, plr in ipairs(Players:GetPlayers()) do
	trackPlayer(plr)
end

-- 主循环：合并 dirty + 距离裁剪
task.spawn(function()
	while true do
		for plr, st in pairs(statesByPlayer) do
			-- 如果玩家对象都没了，清掉
			if not (plr and plr.Parent) then
				cleanupState(st)
				statesByPlayer[plr] = nil
			else
				-- 定时也会触发距离裁剪（即使没 dirty，也可能从远变近/近变远）
				if st.dirty then
					st.dirty = false
					syncPlayerPets(st)
				else
					-- 不 dirty 也做一次轻同步：主要用于距离裁剪和 HRP 延迟出现
					syncPlayerPets(st)
				end
			end
		end
		task.wait(CULL_CHECK_INTERVAL)
	end
end)

dprint("PetRender started. RENDER_DISTANCE=%d", RENDER_DISTANCE)
