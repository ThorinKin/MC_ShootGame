-- ReplicatedStorage/Shared/bulletHoleEffect.lua
-- 子弹孔效果（纯客户端，仅本机渲染）
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

-- Blaster 资源根目录
local BlasterFolder = ReplicatedStorage:WaitForChild("Blaster")
local ObjectsFolder = BlasterFolder:WaitForChild("Objects")

-- 预制子弹孔模型
local BulletHoleTemplate = ObjectsFolder:WaitForChild("BulletHole")

-- 子弹孔统一放在 Workspace/BulletHoles 下面，方便调试 / 清理
local BulletHolesFolder = Workspace:FindFirstChild("BulletHoles")
if not BulletHolesFolder then
	BulletHolesFolder = Instance.new("Folder")
	BulletHolesFolder.Name = "BulletHoles"
	BulletHolesFolder.Parent = Workspace
end

-- 参数：数量 & 生命周期
local MAX_BULLET_HOLES = 256   -- 单客户端最多保留多少个弹孔
local BULLET_HOLE_LIFETIME = 15 -- 每个弹孔多少秒后自动清理

local activeBulletHoles = {}

local function spawnBulletHole(position: Vector3, normal: Vector3, hitInstance: BasePart?)
	if not BulletHoleTemplate then
		return
	end

	if not hitInstance or not hitInstance:IsA("BasePart") then
		return
	end

	-- 只在环境物体上打孔：角色命中交给血花/击中特效，不贴弹孔
	local model = hitInstance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end

	-- 克隆预制
	local bulletHole = BulletHoleTemplate:Clone()
	bulletHole.Anchored = true
	bulletHole.CanCollide = false

	-- 沿着命中法线，往外微微抬一点，避免 Z-fighting
	local offsetPos = position + normal * 0.01

	-- Decal 贴在 Part 的 Front 面（正 Z 方向）：Part 的 LookVector 朝向外法线
	local cf = CFrame.lookAt(offsetPos, offsetPos + normal)
	bulletHole.CFrame = cf

	bulletHole.Parent = BulletHolesFolder

	table.insert(activeBulletHoles, bulletHole)
	Debris:AddItem(bulletHole, BULLET_HOLE_LIFETIME)

	-- 超出上限就干掉最早的那个，防止刷太多
	if #activeBulletHoles > MAX_BULLET_HOLES then
		local old = table.remove(activeBulletHoles, 1)
		if old and old.Parent then
			old:Destroy()
		end
	end
end

--- 子弹孔主入口，入参：
-- position         命中点（世界坐标）
-- normal           命中法线（来自 rayResult.normal）
-- isCharacterHit   是否命中角色（命中 Humanoid）
-- hitInstance      命中的 BasePart（环境物体）
local function bulletHoleEffect(position: Vector3, normal: Vector3, isCharacterHit: boolean, hitInstance: BasePart?)
	-- 人物命中不打弹孔（预留，可改别的逻辑飙血啥的）
	if isCharacterHit then
		return
	end

	spawnBulletHole(position, normal, hitInstance)
end

return bulletHoleEffect
