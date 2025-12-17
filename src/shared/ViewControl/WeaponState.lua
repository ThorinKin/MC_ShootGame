-- ReplicatedStorage/Shared/ViewControl/WeaponState.lua
-- 总注释：统一维护角色的战斗状态（是否持武器 / 武器类型），供 Blaster / 投掷物 等调用。
local PlayerViewState = require(script.Parent:WaitForChild("PlayerViewState"))
local WeaponState = {}

-- weaponKind：Gun / Throwable，后续扩展
function WeaponState.setEquipped(character: Model, equipped: boolean, weaponKind: string?)
	if not character or not character:IsA("Model") then
		return
	end

	character:SetAttribute("WeaponEquipped", equipped)

	if weaponKind then
		character:SetAttribute("WeaponKind", weaponKind)
	end

	-- 统一根据当前 ViewMode + 是否持武器 计算 CombatState
	local viewMode = character:GetAttribute("ViewMode")
	local combatState = PlayerViewState.computeCombatState(viewMode, equipped)
	character:SetAttribute("CombatState", combatState)
end

return WeaponState
