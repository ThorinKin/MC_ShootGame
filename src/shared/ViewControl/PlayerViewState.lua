-- ReplicatedStorage/Shared/PlayerViewState.lua
local PlayerViewState = {}

PlayerViewState.ViewMode = {
	FirstPerson = "FirstPerson",
	ThirdPerson = "ThirdPerson",
}

PlayerViewState.CombatState = {
	FP_Unarmed = "FP_Unarmed",
	FP_Armed   = "FP_Armed",
	TP_Unarmed = "TP_Unarmed",
	TP_Armed   = "TP_Armed",
}

function PlayerViewState.computeCombatState(viewMode: string?, weaponEquipped: boolean?): string
	local armed = weaponEquipped == true
	local mode = viewMode or PlayerViewState.ViewMode.FirstPerson

	if mode == PlayerViewState.ViewMode.ThirdPerson then
		return armed and PlayerViewState.CombatState.TP_Armed or PlayerViewState.CombatState.TP_Unarmed
	else
		-- 默认第一人称
		return armed and PlayerViewState.CombatState.FP_Armed or PlayerViewState.CombatState.FP_Unarmed
	end
end

return PlayerViewState
