-- ReplicatedStorage/Shared/Backpack/BackpackBgSceneController.lua
-- 总注释：背包 UI 打开/关闭时的 3D 背景舞台功能
local Players            = game:GetService("Players")
local Workspace          = game:GetService("Workspace")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Spr = require(game.ReplicatedStorage.Shared.Effects.Tween)

---------------------------------------------------------------------------------------
-- 场景约定
-- Streaming 兼容版
local SCENE_ASSET_PATH   = {"Assets", "Scenes", "BackpackBgScene"} -- 相对 ReplicatedStorage
local DISPLAY_NAME       = "Display"
local START_ATTACH_NAME  = "CameraStartPos"
local SHOW_ATTACH_NAME   = "CameraShowPos"
-- 舞台放置：挪到玩家脚底 500 studs
local SCENE_OFFSET       = Vector3.new(0, -500, 0)
-- 相机弹簧参数
local SPRING_DAMPING_CAM = 0.75
local SPRING_FREQ_CAM    = 2.2
-- 1217：退出舞台回玩家时的相机弹簧（更利落一点）
local SPRING_DAMPING_CAM_BACK = 0.82
local SPRING_FREQ_CAM_BACK    = 2.6
-- 退出舞台时先靠后一点再回原位的距离（studs）
local EXIT_PULLBACK_STUDS     = 8
-- 1217：背包装备展示（3D 模型）
local EQUIP_ASSET_FOLDER   = {"Assets", "EquipmentModel4Display"} -- 相对 ReplicatedStorage
local EQUIP_START_ATTACH   = "EquipmentStartPos"
local EQUIP_SHOW_ATTACH    = "EquipmentShowPos"
local EQUIP_LEFT_ATTACH    = "EquipmentLeftPos"
local EQUIP_RIGHT_ATTACH   = "EquipmentRightPos"
-- 展示模型弹簧参数（比相机稍利落）
local SPRING_DAMPING_EQUIP = 0.78
local SPRING_FREQ_EQUIP = 2.8
-- 退出舞台时展示装备回起点
local SPRING_DAMPING_EQUIP_BACK = 0.82
local SPRING_FREQ_EQUIP_BACK = 3.0
-- 1218：展示模型切换左右滑动弹簧参数
local SPRING_DAMPING_EQUIP_SWAP = 1.15
local SPRING_FREQ_EQUIP_SWAP = 3.2
-- 兜底超时
local EQUIP_SWAP_TIMEOUT = 0.35
-- 背包装备展示（3D 模型）拖动旋转参数
local ROTATE_SENSITIVITY_YAW = 0.010 -- 水平拖动：每像素转多少弧度
local ROTATE_SENSITIVITY_PITCH = 0.008 -- 垂直拖动：每像素转多少弧度
local ROTATE_PITCH_LIMIT = math.rad(25) -- 上下最多抬/低 25 度（防止翻车）
---------------------------------------------------------------------------------------
local Controller = {}

-- 内部状态：防连点 / 防竞态
local token = 0
local inScene = false

-- 记录进入舞台前的相机信息用于恢复
local savedCamera = nil :: {
	camera: Camera,
	cameraType: Enum.CameraType,
	cameraSubject: Instance?,
	cframe: CFrame,
	fov: number,
}?

-- 1207：场景缓存（只 clone 一次）
local cachedScene: Model? = nil
local cachedDisplay: Instance? = nil
local cachedStartAtt: Attachment? = nil
local cachedShowAtt: Attachment? = nil
-- 1217：装备展示 Attach 缓存
local cachedEquipStartAtt: Attachment? = nil
local cachedEquipShowAtt: Attachment? = nil
local cachedEquipLeftAtt: Attachment? = nil
local cachedEquipRightAtt: Attachment? = nil
-- 1218：展示模型状态支持 old/new 同时存在
type DisplayModel = {
	subType: string,
	model: Model,
	pivot: CFrameValue,
	conn: RBXScriptConnection?,
}
local equipActive: DisplayModel? = nil   -- 当前在 Show 或正在去 Show 的模型
local equipOutgoing: DisplayModel? = nil -- 正在去 Left 的旧模型
-- 1218：展示切换防竞态 token
local equipToken = 0
-- 1217：当前展示的装备模型
local equipDesiredSubType: string? = nil
-- 1218：展示模型旋转偏移 不缓存，切换模型恢复默认
local previewYaw   = 0 -- Y 轴旋转（左右）
local previewPitch = 0 -- X 轴旋转（上下）
-- 1218：当前展示点位（Show）的基准 CFrame
local equipBaseShowCf: CFrame? = nil

-- 工具：安全判断 Instance 是否还活着（被 Destroy 的对象直接视为无效）
local function isAlive(inst: Instance?): boolean
	if not inst then return false end
	local ok, parent = pcall(function()
		return inst.Parent
	end)
	return ok and parent ~= nil
end

-- 工具：从 ReplicatedStorage 取场景模板（Model）
local function getSceneTemplate(): Model?
	local node: Instance = ReplicatedStorage
	for _, name in ipairs(SCENE_ASSET_PATH) do
		node = node:FindFirstChild(name)
		if not node then
			warn("[BackpackBgSceneController] 场景资产缺失：" .. table.concat(SCENE_ASSET_PATH, "/"))
			return nil
		end
	end

	if not node:IsA("Model") then
		warn("[BackpackBgSceneController] 场景资产类型错误，需要 Model：" .. node.ClassName)
		return nil
	end

	return node
end

-- 工具：确保场景已 clone（只 clone 一次），并挂到 Workspace（客户端本地）
local function ensureSceneInstance(): Model?
	-- cachedScene 被 Destroy 了就清空
	if cachedScene and not isAlive(cachedScene) then
		cachedScene = nil
		cachedDisplay = nil
		cachedStartAtt = nil
		cachedShowAtt = nil
		cachedEquipStartAtt = nil 
		cachedEquipShowAtt = nil  
		cachedEquipLeftAtt = nil
		cachedEquipRightAtt = nil
	end

	-- 已缓存：确保在 Workspace
	if cachedScene then
		if not cachedScene.Parent then
			cachedScene.Parent = Workspace
		end
		return cachedScene
	end

	local template = getSceneTemplate()
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = "BackpackBgScene_Local" -- 客户端本地副本
	clone.Parent = Workspace

	-- PrimaryPart 只做校验，不做遍历改属性
	if not clone.PrimaryPart then
		warn("[BackpackBgSceneController] 场景 Model 未设置 PrimaryPart：BackpackBgScene")
		clone:Destroy()
		return nil
	end

	cachedScene = clone
	return cachedScene
end

-- 工具：拿玩家当前 HumanoidRootPart（用于放置舞台）
local function getRootPart(): BasePart?
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- 工具：把舞台挪到玩家附近（只改位置，不跟着玩家转向）
local function placeSceneNearPlayer(scene: Model)
	if not (scene and scene.Parent) then return end
	local hrp = getRootPart()
	if not hrp then
		return
	end

	-- 保留舞台自身的朝向，不套用玩家朝向（避免玩家转身导致舞台跟着旋转）
	local pivot = scene:GetPivot()
	local targetPos = hrp.Position + SCENE_OFFSET
	local newPivot = CFrame.fromMatrix(targetPos, pivot.RightVector, pivot.UpVector, pivot.LookVector)
	scene:PivotTo(newPivot)
end

-- 工具：缓存 Display/Attachments 引用（只做一次，后续复用）
local function ensureSceneRefs(scene: Model)
	-- 引用还活着就不重复找
	if isAlive(cachedDisplay) and isAlive(cachedStartAtt) and isAlive(cachedShowAtt) then
		return
	end

	cachedDisplay = nil
	cachedStartAtt = nil
	cachedShowAtt = nil

	local display = scene:FindFirstChild(DISPLAY_NAME)
	if not display then
		warn("[BackpackBgSceneController] 场景缺失：Display")
		return
	end
	local startAtt = display:FindFirstChild(START_ATTACH_NAME, true)
	local showAtt  = display:FindFirstChild(SHOW_ATTACH_NAME, true)

	if not (startAtt and startAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] Attachment 缺失：CameraStartPos")
		return
	end
	if not (showAtt and showAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] Attachment 缺失：CameraShowPos")
		return
	end
	cachedDisplay = display
	cachedStartAtt = startAtt
	cachedShowAtt = showAtt
end

-- 若干展示模型相关工具 --
-- 工具：从 ReplicatedStorage 取 EquipmentModel4Display 文件夹
local function getEquipAssetFolder(): Folder?
	local node: Instance = ReplicatedStorage
	for _, name in ipairs(EQUIP_ASSET_FOLDER) do
		node = node:FindFirstChild(name)
		if not node then
			warn("[BackpackBgSceneController] 装备展示资产缺失：" .. table.concat(EQUIP_ASSET_FOLDER, "/"))
			return nil
		end
	end
	if not node:IsA("Folder") then
		warn("[BackpackBgSceneController] 装备展示资产类型错误，需要 Folder：" .. node.ClassName)
		return nil
	end
	return node
end
-- 工具：销毁一个 DisplayModel（安全）
local function destroyDisplay(dm: DisplayModel?)
	if not dm then return end
	pcall(function()
		if dm.conn then dm.conn:Disconnect() end
	end)
	pcall(function()
		if dm.pivot then
			Spr.stop(dm.pivot, "Value")
			dm.pivot:Destroy()
		end
	end)
	pcall(function()
		if dm.model and isAlive(dm.model) then
			dm.model:Destroy()
		end
	end)
end
-- 工具：创建一个展示模型 + pivot 弹簧驱动
local function createDisplayModel(subType: string, initialCf: CFrame): DisplayModel?
	local scene = ensureSceneInstance()
	if not scene then return nil end
	if not isAlive(cachedDisplay) then
		ensureSceneRefs(scene)
	end
	if not isAlive(cachedDisplay) then return nil end
	local folder = getEquipAssetFolder()
	if not folder then return nil end
	local template = folder:FindFirstChild(subType)
	if not (template and template:IsA("Model")) then
		warn("[BackpackBgSceneController] 装备展示模型缺失/类型错误：" .. tostring(subType))
		return nil
	end
	local clone = template:Clone()
	clone.Name = ("EquipDisplay_%s"):format(subType)
	clone.Parent = cachedDisplay
	pcall(function()
		clone:PivotTo(initialCf)
	end)
	local pv = Instance.new("CFrameValue")
	pv.Name = ("BackpackEquipPivot_%s"):format(subType)
	pv.Value = initialCf
	pv.Parent = cachedDisplay -- 方便调试/随场景一起收纳

	local conn = pv:GetPropertyChangedSignal("Value"):Connect(function()
		if clone and isAlive(clone) then
			pcall(function()
				clone:PivotTo(pv.Value)
			end)
		end
	end)
	return {
		subType = subType,
		model = clone,
		pivot = pv,
		conn = conn,
	}
end
-- 工具：弹簧移动 DisplayModel 到目标 CFrame（带 completed + delay 兜底）
local function springDisplayTo(dm: DisplayModel, damping: number, freq: number, targetCf: CFrame, onDone: (() -> ())?)
	if not (dm and dm.pivot) then
		if typeof(onDone) == "function" then pcall(onDone) end
		return
	end
	pcall(function()
		Spr.stop(dm.pivot, "Value")
	end)
	local finished = false
	local function doneOnce()
		if finished then return end
		finished = true
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
	end
	Spr.target(dm.pivot, damping, freq, { Value = targetCf })
	Spr.completed(dm.pivot, doneOnce)
	task.delay(EQUIP_SWAP_TIMEOUT, doneOnce)
end
-- 工具：确保装备展示 Attachments 引用（只做一次，后续复用）
local function ensureEquipRefs(scene: Model)
	if isAlive(cachedEquipStartAtt) and isAlive(cachedEquipShowAtt)
		and isAlive(cachedEquipLeftAtt) and isAlive(cachedEquipRightAtt)
	then
		return
	end
	cachedEquipStartAtt = nil
	cachedEquipShowAtt  = nil
	cachedEquipLeftAtt  = nil
	cachedEquipRightAtt = nil
	if not isAlive(cachedDisplay) then
		ensureSceneRefs(scene)
	end
	if not isAlive(cachedDisplay) then
		return
	end
	local startAtt = cachedDisplay:FindFirstChild(EQUIP_START_ATTACH, true)
	local showAtt  = cachedDisplay:FindFirstChild(EQUIP_SHOW_ATTACH, true)
	local leftAtt  = cachedDisplay:FindFirstChild(EQUIP_LEFT_ATTACH, true)
	local rightAtt = cachedDisplay:FindFirstChild(EQUIP_RIGHT_ATTACH, true)

	if not (startAtt and startAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_START_ATTACH)
		return
	end
	if not (showAtt and showAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_SHOW_ATTACH)
		return
	end
	if not (leftAtt and leftAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_LEFT_ATTACH)
		return
	end
	if not (rightAtt and rightAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_RIGHT_ATTACH)
		return
	end
	cachedEquipStartAtt = startAtt
	cachedEquipShowAtt  = showAtt
	cachedEquipLeftAtt  = leftAtt
	cachedEquipRightAtt = rightAtt
end
-- 工具：返回 4 个点位（Start / Show / Left / Right）
local function getEquipCFrames(): (CFrame?, CFrame?, CFrame?, CFrame?)
	local scene = ensureSceneInstance()
	if not scene then
		return nil, nil, nil, nil
	end
	-- 预览装备时不要每次都挪舞台
	ensureEquipRefs(scene)
	if not (cachedEquipStartAtt and cachedEquipShowAtt and cachedEquipLeftAtt and cachedEquipRightAtt) then
		return nil, nil, nil, nil
	end
	return cachedEquipStartAtt.WorldCFrame,
		cachedEquipShowAtt.WorldCFrame,
		cachedEquipLeftAtt.WorldCFrame,
		cachedEquipRightAtt.WorldCFrame
end
-- 工具：把旋转偏移应用到当前展示模型（只影响 equipActive）
local function applyPreviewRotation()
	if not inScene then return end
	if not equipActive or not equipActive.pivot then return end
	if typeof(equipBaseShowCf) ~= "CFrame" then
		-- 没拿到 show 点位就不转
		return
	end
	-- 注意：旋转叠在 Show 点位上（默认展示姿态）
	local rot = CFrame.Angles(previewPitch, previewYaw, 0)
	local target = equipBaseShowCf * rot
	-- 旋转期间不走弹簧，直接控制
	pcall(function()
		Spr.stop(equipActive.pivot, "Value")
	end)
	equipActive.pivot.Value = target
end
-- 工具：重置旋转偏移。允许只清状态，不立刻写 pivot，避免把弹簧动画打断/瞬移
local function resetPreviewRotation(applyNow: boolean?)
	previewYaw = 0
	previewPitch = 0
	if applyNow ~= false then
		applyPreviewRotation()
	end
end
-- 工具：应用当前 desiredSubType
local function applyEquipDesired(animate: boolean?, fromEnter: boolean?)
	-- 不在舞台就只记需求，不做任何 Clone
	if not inScene then
		return
	end
	equipToken += 1
	local myToken = equipToken
	local subType = equipDesiredSubType
	local startCf, showCf, leftCf, rightCf = getEquipCFrames()
	equipBaseShowCf = showCf
	if not (startCf and showCf and leftCf and rightCf) then
		return
	end
	-- 先清掉上一轮还没销毁完的 outgoing（防连点堆模型）
	if equipOutgoing then
		destroyDisplay(equipOutgoing)
		equipOutgoing = nil
	end
	-- 目标为空：当前模型滑到 Left 然后销毁
	if type(subType) ~= "string" or subType == "" then
		if equipActive then
			local old = equipActive
			equipActive = nil
			equipOutgoing = old
			local function done()
				if myToken ~= equipToken then return end
				destroyDisplay(old)
				if equipOutgoing == old then
					equipOutgoing = nil
				end
			end
			if animate ~= false then
				springDisplayTo(old, SPRING_DAMPING_EQUIP_SWAP, SPRING_FREQ_EQUIP_SWAP, leftCf, done)
			else
				done()
			end
		end
		return
	end
	-- 同一个 subType：不重复刷新
	if equipActive and equipActive.subType == subType and equipActive.model and isAlive(equipActive.model) then
		return
	end
	-- 创建新模型：开背包从 Start 出现，其它切换从 Right 出现
	local spawnCf = (fromEnter == true) and startCf or rightCf
	local nextDm = createDisplayModel(subType, spawnCf)
	if not nextDm then
		return
	end
	-- 没旧模型：新模型直接去 Show 
	if not equipActive then
		equipActive = nextDm
		resetPreviewRotation(false) -- 不顺以
		if animate ~= false then
			local damping = (fromEnter == true) and SPRING_DAMPING_EQUIP or SPRING_DAMPING_EQUIP_SWAP
			local freq    = (fromEnter == true) and SPRING_FREQ_EQUIP    or SPRING_FREQ_EQUIP_SWAP
			springDisplayTo(nextDm, damping, freq, showCf)
		else
			nextDm.pivot.Value = showCf
			pcall(function() nextDm.model:PivotTo(showCf) end)
		end
		return
	end
	-- 有旧模型：同步换场
	local oldDm = equipActive
	equipActive = nextDm
	resetPreviewRotation(false)  -- 不顺以
	equipOutgoing = oldDm
	local function maybeDestroyOld()
		if myToken ~= equipToken then return end
		-- oldDm 可能已经被别的切换提前干掉了，destroyDisplay 自己是安全的
		destroyDisplay(oldDm)
		if equipOutgoing == oldDm then
			equipOutgoing = nil
		end
	end
	if animate ~= false then
		-- old: Show -> Left
		springDisplayTo(oldDm, SPRING_DAMPING_EQUIP_SWAP, SPRING_FREQ_EQUIP_SWAP, leftCf, maybeDestroyOld)
		-- new: Right -> Show
		springDisplayTo(nextDm, SPRING_DAMPING_EQUIP_SWAP, SPRING_FREQ_EQUIP_SWAP, showCf)
	else
		-- 瞬切：直接杀旧，放新到 Show
		maybeDestroyOld()
		nextDm.pivot.Value = showCf
		pcall(function() nextDm.model:PivotTo(showCf) end)
	end
end

-- 工具：退出舞台时让展示模型回起点
local function springEquipBackToStart(myToken: number, onDone: (() -> ())?)
	if typeof(onDone) ~= "function" then
		return
	end
	-- 没模型就直接 done
	if not equipActive then
		onDone()
		return
	end
	local startCf, showCf, leftCf, rightCf = getEquipCFrames()
	if not startCf then
		onDone()
		return
	end
	-- 退出时不允许再切换
	equipToken += 1
	local myEquipToken = equipToken
	-- 先清掉 outgoing，避免屏幕里还留着一个旧模型在左边
	if equipOutgoing then
		destroyDisplay(equipOutgoing)
		equipOutgoing = nil
	end
	local dm = equipActive
	-- Show -> Start（退出更像“收回去”）
	springDisplayTo(dm, SPRING_DAMPING_EQUIP_BACK, SPRING_FREQ_EQUIP_BACK, startCf, function()
		if myToken ~= token then return end
		if myEquipToken ~= equipToken then return end
		pcall(onDone)
	end)
end

local function getSceneCFrames(): (CFrame?, CFrame?)
	local scene = ensureSceneInstance()
	if not scene then
		return nil, nil
	end
	-- 每次打开都把舞台挪到玩家附近，避免 Streaming 因距离过远加载不出
	placeSceneNearPlayer(scene)
	-- 缓存引用
	ensureSceneRefs(scene)
	if not (cachedStartAtt and cachedShowAtt) then
		return nil, nil
	end
	return cachedStartAtt.WorldCFrame, cachedShowAtt.WorldCFrame
end

local function getCurrentHumanoid(): Humanoid?
	local char = player.Character
	if not char then return nil end
	return char:FindFirstChildOfClass("Humanoid")
end

local function saveCameraState(cam: Camera)
	savedCamera = {
		camera = cam,
		cameraType = cam.CameraType,
		cameraSubject = cam.CameraSubject,
		cframe = cam.CFrame,
		fov = cam.FieldOfView,
	}
end

-- 工具：关闭舞台恢复相机
local function restoreCameraState()
	if not savedCamera then
		return
	end
	local cam = savedCamera.camera
	if not (cam and cam.Parent) then
		savedCamera = nil
		return
	end
	-- 先停掉相机弹簧，避免回去还被拉扯
	pcall(function()
		Spr.stop(cam, "CFrame")
	end)
	cam.FieldOfView = savedCamera.fov or cam.FieldOfView
	cam.CameraType = savedCamera.cameraType or Enum.CameraType.Custom

	-- Subject：旧 humanoid 可能已经没了（重生），兜底找当前 humanoid
	local subj = savedCamera.cameraSubject
	if not (subj and subj.Parent) then
		subj = getCurrentHumanoid()
	end
	cam.CameraSubject = subj

	-- 1207修复：玩家死亡/重生后，只有当 Subject 还是当初保存的那个对象才允许恢复 CFrame
	local canRestoreCFrame = false
	if savedCamera.cameraSubject and subj then
		canRestoreCFrame = (subj == savedCamera.cameraSubject)
	end
	if canRestoreCFrame then
		pcall(function()
			cam.CFrame = savedCamera.cframe or cam.CFrame
		end)
	end

	savedCamera = nil
end

-- 1208：隐藏舞台（不销毁，缓存保留）
local function hideSceneInstance()
	-- 退出舞台时清理展示模型（active + outgoing）
	if equipActive then
		destroyDisplay(equipActive)
		equipActive = nil
	end
	if equipOutgoing then
		destroyDisplay(equipOutgoing)
		equipOutgoing = nil
	end

	if cachedScene and isAlive(cachedScene) then
		cachedScene.Parent = nil
	end
end

-- 工具：判断是否第一人称（角色属性 ViewMode == "FirstPerson"）
local function isFirstPersonNow(): boolean
	local char = player.Character
	if not char then return false end
	local mode = char:GetAttribute("ViewMode")
	if type(mode) ~= "string" then
		return false
	end
	return string.lower(mode) == "firstperson"
end

----------对外函数-------------------------------------------------------------

-- 进入背包舞台（相机弹簧）
function Controller.enter()
	token += 1
	local myToken = token
	local cam = Workspace.CurrentCamera
	if not cam then return end
	if inScene then return end
	local startCf, showCf = getSceneCFrames()
	if not (startCf and showCf) then
		return
	end
	inScene = true
	saveCameraState(cam)
	pcall(function()
		Spr.stop(cam, "CFrame")
	end)
	-- 切到 Scriptable，瞬移到起点，再弹到展示位
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	cam.CFrame = startCf
	if myToken ~= token then
		return
	end
	Spr.target(cam, SPRING_DAMPING_CAM, SPRING_FREQ_CAM, { CFrame = showCf })
	-- 开背包时：装备从 Start 弹到 Show
	applyEquipDesired(true, true) 
end

-- 离开背包舞台 / 直接恢复相机
function Controller.exit(instant: boolean?, onDone: (() -> ())?)
	token += 1
	local myToken = token
	if not inScene then
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
		return
	end
	inScene = false
	local cam = Workspace.CurrentCamera
	if not cam then
		restoreCameraState()
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
		return
	end
	if instant then
		restoreCameraState()
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
		return
	end
	-- 安全回弹逻辑，只在安全时才做相机回弹
	local allowSpringBack = false
	if savedCamera and savedCamera.cameraSubject then
		local subj = savedCamera.cameraSubject
		if not (subj and subj.Parent) then
			subj = getCurrentHumanoid()
		end
		if subj and savedCamera.cameraSubject and subj == savedCamera.cameraSubject then
			allowSpringBack = true
		end
	end
	if not (savedCamera and allowSpringBack) then
		restoreCameraState()
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
		return
	end
	-- 第一人称不做回弹
	if savedCamera and isFirstPersonNow() then
		local targetCf = savedCamera.cframe
		pcall(function()
			cam.CFrame = targetCf
		end)
		restoreCameraState()
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
		return
	end
	-- 自己掌控这段时间，不让默认相机脚本抢控制
	cam.CameraType = Enum.CameraType.Scriptable
	local safeSubj = savedCamera.cameraSubject
	if not (safeSubj and safeSubj.Parent) then
		safeSubj = getCurrentHumanoid()
	end
	cam.CameraSubject = safeSubj
	pcall(function()
		Spr.stop(cam, "CFrame")
	end)
	local targetCf = savedCamera.cframe
	local startBackCf = targetCf * CFrame.new(0, 0, EXIT_PULLBACK_STUDS)
	cam.CFrame = startBackCf
	-- 相机回弹同时，让装备 Show 弹到 Start
	local camDone = false
	local equipDone = false
	local finished = false
	local function finishOnce()
		if finished then return end
		finished = true
		if myToken ~= token then return end
		restoreCameraState()
		hideSceneInstance()
		if typeof(onDone) == "function" then
			pcall(onDone)
		end
	end
	local function tryFinish()
		if camDone and equipDone then
			finishOnce()
		end
	end
	-- 装备回起点（并发）
	equipDone = (equipActive == nil)
	if not equipDone then
		springEquipBackToStart(myToken, function()
			equipDone = true
			tryFinish()
		end)
	end
	-- 相机回弹
	Spr.target(cam, SPRING_DAMPING_CAM_BACK, SPRING_FREQ_CAM_BACK, { CFrame = targetCf })
	Spr.completed(cam, function()
		camDone = true
		tryFinish()
	end)
	task.delay(0.3, function()
		camDone = true
		tryFinish()
	end)
end

-- 公开接口：展示模型拖动旋转（入参是屏幕像素 delta）
function Controller.addPreviewRotationDelta(deltaX: number, deltaY: number)
	if not inScene then return end
	if not equipActive then return end
	if typeof(equipBaseShowCf) ~= "CFrame" then return end
	-- 水平拖动 → yaw；垂直拖动 → pitch
	previewYaw   += (deltaX) * ROTATE_SENSITIVITY_YAW
	previewPitch += (deltaY) * ROTATE_SENSITIVITY_PITCH
	-- 限制上下角度，避免翻过去像断头台
	if previewPitch > ROTATE_PITCH_LIMIT then
		previewPitch = ROTATE_PITCH_LIMIT
	elseif previewPitch < -ROTATE_PITCH_LIMIT then
		previewPitch = -ROTATE_PITCH_LIMIT
	end
	applyPreviewRotation()
end

-- 公开接口：外部强制重置旋转（暂时没用）
function Controller.resetPreviewRotation()
	resetPreviewRotation()
end

-- 设置当前要展示的装备
function Controller.setEquipPreview(subType: string?, animate: boolean?)
	if type(subType) ~= "string" or subType == "" then
		equipDesiredSubType = nil
	else
		equipDesiredSubType = subType
	end
	applyEquipDesired(animate ~= false, false)
end

function Controller.isActive()
	return inScene
end

return Controller
