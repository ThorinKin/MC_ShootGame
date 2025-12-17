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
-- 展示模型弹簧参数（比相机稍利落）
local SPRING_DAMPING_EQUIP = 0.78
local SPRING_FREQ_EQUIP    = 2.8
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
-- 1217：当前展示的装备模型
local equipDesiredSubType: string? = nil
local equipActiveSubType: string? = nil
local equipModel: Model? = nil
-- 1217：用 CFrameValue 做 Pivot 的弹簧驱动
local equipPivot = Instance.new("CFrameValue")
equipPivot.Name = "BackpackEquipPivot"
local equipPivotConn: RBXScriptConnection? = nil

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
-- 工具：确保装备展示 Attachments 引用（只做一次，后续复用）
local function ensureEquipRefs(scene: Model)
	-- 引用还活着就不重复找
	if isAlive(cachedEquipStartAtt) and isAlive(cachedEquipShowAtt) then
		return
	end
	cachedEquipStartAtt = nil
	cachedEquipShowAtt = nil
	-- Display 依赖 ensureSceneRefs 先缓存
	if not isAlive(cachedDisplay) then
		ensureSceneRefs(scene)
	end
	if not isAlive(cachedDisplay) then
		return
	end

	local startAtt = cachedDisplay:FindFirstChild(EQUIP_START_ATTACH, true)
	local showAtt  = cachedDisplay:FindFirstChild(EQUIP_SHOW_ATTACH, true)

	if not (startAtt and startAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_START_ATTACH)
		return
	end
	if not (showAtt and showAtt:IsA("Attachment")) then
		warn("[BackpackBgSceneController] 装备展示 Attachment 缺失：" .. EQUIP_SHOW_ATTACH)
		return
	end
	cachedEquipStartAtt = startAtt
	cachedEquipShowAtt = showAtt
end
local function getEquipCFrames(): (CFrame?, CFrame?)
	local scene = ensureSceneInstance()
	if not scene then
		return nil, nil
	end
	-- 1217修复：预览装备时不要每次都挪舞台
	ensureEquipRefs(scene)
	if not (cachedEquipStartAtt and cachedEquipShowAtt) then
		return nil, nil
	end
	return cachedEquipStartAtt.WorldCFrame, cachedEquipShowAtt.WorldCFrame
end
-- 工具：清理当前展示模型
local function clearEquipModel()
	equipActiveSubType = nil
	if equipModel and isAlive(equipModel) then
		equipModel:Destroy()
	end
	equipModel = nil

	-- 停掉 Pivot 弹簧，避免还在拉
	pcall(function()
		Spr.stop(equipPivot, "Value")
	end)
end
-- 工具：把 equipPivot.Value 应用到当前模型 Pivot
local function ensureEquipPivotConn()
	if equipPivotConn then
		return
	end
	equipPivotConn = equipPivot:GetPropertyChangedSignal("Value"):Connect(function()
		if equipModel and isAlive(equipModel) then
			pcall(function()
				equipModel:PivotTo(equipPivot.Value)
			end)
		end
	end)
end
-- 工具：应用当前 desiredSubType
local function applyEquipDesired(animate: boolean?)
	-- 不在舞台就只记需求，不做任何 Clone，避免背包没开时浪费
	if not inScene then
		return
	end

	local subType = equipDesiredSubType
	if type(subType) ~= "string" or subType == "" then
		clearEquipModel()
		return
	end

	-- 同一个 subType 且模型还活着：不重复刷新
	if equipActiveSubType == subType and equipModel and isAlive(equipModel) then
		return
	end

	local startCf, showCf = getEquipCFrames()
	if not (startCf and showCf) then
		return
	end

	local folder = getEquipAssetFolder()
	if not folder then
		return
	end

	local template = folder:FindFirstChild(subType)
	if not (template and template:IsA("Model")) then
		warn("[BackpackBgSceneController] 装备展示模型缺失/类型错误：" .. tostring(subType))
		clearEquipModel()
		return
	end

	-- 清旧
	clearEquipModel()

	-- Clone 新模型，挂到 Display 下
	local scene = ensureSceneInstance()
	if not scene then
		return
	end
	if not isAlive(cachedDisplay) then
		ensureSceneRefs(scene)
	end
	if not isAlive(cachedDisplay) then
		return
	end

	local clone = template:Clone()
	clone.Name = ("EquipDisplay_%s"):format(subType)
	clone.Parent = cachedDisplay

	equipModel = clone
	equipActiveSubType = subType

	-- 启动 Pivot 驱动
	ensureEquipPivotConn()

	-- 先瞬移到起点
	equipPivot.Value = startCf
	pcall(function()
		clone:PivotTo(startCf)
	end)

	-- 再弹到展示位
	pcall(function()
		Spr.stop(equipPivot, "Value")
	end)

	if animate == false then
		equipPivot.Value = showCf
		pcall(function()
			clone:PivotTo(showCf)
		end)
		return
	end
	Spr.target(equipPivot, SPRING_DAMPING_EQUIP, SPRING_FREQ_EQUIP, { Value = showCf })
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
	clearEquipModel() 	-- 1217：退出舞台时清理装备展示
	if cachedScene and isAlive(cachedScene) then
		-- 直接 unparent：省渲染/省干扰，下一次打开再 parent 回 Workspace
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
	-- 已经在舞台就别重复搞
	if inScene then
		return
	end
	local startCf, showCf = getSceneCFrames()
	if not (startCf and showCf) then
		return
	end
	inScene = true
	saveCameraState(cam)
	-- 先停掉相机弹簧，避免被旧动画拉扯
	pcall(function()
		Spr.stop(cam, "CFrame")
	end)
	-- 切到 Scriptable，瞬移到起点，再弹到展示位
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CameraSubject = nil
	cam.CFrame = startCf
	-- 防竞态：如果这期间被 exit 抢先了，就别继续拉
	if myToken ~= token then
		return
	end
	Spr.target(cam, SPRING_DAMPING_CAM, SPRING_FREQ_CAM, { CFrame = showCf })
	-- 背包打开时展示当前选中物品
	applyEquipDesired(true)
end

-- 离开背包舞台 / 直接恢复相机
function Controller.exit(instant: boolean?, onDone: (() -> ())?)
	token += 1
	local myToken = token
	-- 不在舞台也把舞台隐藏一下，防止外部流程漏掉（兜底）
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
	-- 回玩家相机也弹一下，安全才弹避免错位
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
	-- 不安全就别秀操作：直接恢复避免错位
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
		-- 确保别停留在舞台镜头
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
	-- 别把 CameraSubject 置 nil
	local safeSubj = savedCamera.cameraSubject
	if not (safeSubj and safeSubj.Parent) then
		safeSubj = getCurrentHumanoid()
	end
	cam.CameraSubject = safeSubj
	-- 停掉旧相机弹簧，避免拉扯
	pcall(function()
		Spr.stop(cam, "CFrame")
	end)
	-- 目标位：进入舞台前保存的相机位
	local targetCf = savedCamera.cframe
	-- 直接把相机瞬移到目标位后方一点点，再弹回目标位
	local startCf = targetCf * CFrame.new(0, 0, EXIT_PULLBACK_STUDS)
	cam.CFrame = startCf
	-- 收尾只允许执行一次
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
	-- 正常回弹
	Spr.target(cam, SPRING_DAMPING_CAM_BACK, SPRING_FREQ_CAM_BACK, { CFrame = targetCf })
	Spr.completed(cam, finishOnce)
	-- 兜底：completed 可能被别的镜头系统打断导致永远不回调
	task.delay(0.3, finishOnce)
end

-- 设置当前要展示的装备
function Controller.setEquipPreview(subType: string?, animate: boolean?)
	if type(subType) ~= "string" or subType == "" then
		equipDesiredSubType = nil
	else
		equipDesiredSubType = subType
	end
	applyEquipDesired(animate ~= false)
end







function Controller.isActive()
	return inScene
end

return Controller
