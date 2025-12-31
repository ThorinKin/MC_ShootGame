-- ReplicatedStorage/Shared/ThirdPersonShooter.lua
-- 总注释：第三人称射击工具：PC 用鼠标点；移动端默认用屏幕中心点（准星）来瞄准
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local getRayDirections = require(ReplicatedStorage.Blaster.Utility.getRayDirections)
local castRays = require(ReplicatedStorage.Blaster.Utility.castRays)

local ThirdPersonShooter = {}

local MAX_MOUSE_DISTANCE = 1000

-- 1227工具：拿瞄准屏幕点
local function getAimScreenPoint(camera: Camera): (number, number)
	if UserInputService.TouchEnabled then
		-- 移动端：默认准星在屏幕中心
		local vp = camera.ViewportSize
		return vp.X * 0.5, vp.Y * 0.5
	end
	-- PC：鼠标位置
	local mousePos = UserInputService:GetMouseLocation()
	return mousePos.X, mousePos.Y
end

-- 从屏幕瞄准点，打出一条 ray，找到世界坐标
function ThirdPersonShooter.getMouseWorldTarget(camera: Camera, ignoreList: {Instance}?): Vector3
	local x, y = getAimScreenPoint(camera)
	local viewportRay = camera:ViewportPointToRay(x, y)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList or {}

	local result = Workspace:Raycast(viewportRay.Origin, viewportRay.Direction * MAX_MOUSE_DISTANCE, params)
	if result then
		return result.Position
	else
		return viewportRay.Origin + viewportRay.Direction * MAX_MOUSE_DISTANCE
	end
end

-- 找到世界空间的枪口 CFrame
function ThirdPersonShooter.getMuzzleCFrame(blaster: Tool): CFrame?
	if not blaster then
		return nil
	end
	-- 递归在整个 Tool 下找 MuzzleAttachment
	local muzzle = blaster:FindFirstChild("MuzzleAttachment", true)
	if muzzle and muzzle:IsA("Attachment") then
		-- print("[TPS] MuzzleAttachment found at", muzzle:GetFullName())
		return muzzle.WorldCFrame
	end
	-- 找不到就退回 Handle
	local handle = blaster:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		-- warn("[TPS] MuzzleAttachment not found, fallback to Handle:", handle:GetFullName())
		return handle.CFrame
	end
	warn("[TPS] No Handle or MuzzleAttachment on blaster:", blaster:GetFullName())
	return nil
end

-- 核心：第三人称模拟一发子弹。返回：
-- originCFrame, rayResults, tagged, muzzlePos, didTag
function ThirdPersonShooter.simulateShot(
	player: Player,
	blaster: Tool,
	camera: Camera,
	spread: number,
	raysPerShot: number,
	range: number,
	rayRadius: number,
	timestamp: number
)
	local character = player.Character
	if not character then return end
	local muzzleCF = ThirdPersonShooter.getMuzzleCFrame(blaster)
	if not muzzleCF then return end
	-- 鼠标射到的世界坐标（忽略自己角色和当前武器）
	local targetPos = ThirdPersonShooter.getMouseWorldTarget(camera, { character, blaster })
	-- 枪口看向目标点
	local originCF = CFrame.new(muzzleCF.Position, targetPos)

	local spreadAngle = math.rad(spread)
	local rayDirections = getRayDirections(originCF, raysPerShot, spreadAngle, timestamp)
	for index, direction in rayDirections do
		rayDirections[index] = direction * range
	end

	-- 用和 FPS 一样的 castRays 做命中判定（客户端版，包含角色）
	local rayResults = castRays(player, originCF.Position, rayDirections, rayRadius)

	local tagged = {}
	local didTag = false
	for index, rayResult in rayResults do
		if rayResult.taggedHumanoid then
			tagged[tostring(index)] = rayResult.taggedHumanoid
			didTag = true
		end
	end

	return {
		origin = originCF,
		rayResults = rayResults,
		tagged = tagged,
		muzzlePosition = muzzleCF.Position,
		didTag = didTag,
	}
end

return ThirdPersonShooter
