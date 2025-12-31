-- ReplicatedStorage/Shared/UI/HudRegistry.lua
-- 总注释：HUD 注册表（客户端）。负责告诉业务脚本当前活跃 HUD 是哪个，并提供切换通知。
local HudRegistry = {}

local changedBE = Instance.new("BindableEvent")
local currentHud: ScreenGui? = nil

function HudRegistry.set(hudGui: ScreenGui)
	currentHud = hudGui
	changedBE:Fire(hudGui)
end

function HudRegistry.get(): ScreenGui?
	return currentHud
end

function HudRegistry.changed()
	return changedBE.Event
end

function HudRegistry.wait(): ScreenGui
	if currentHud then
		return currentHud
	end
	return changedBE.Event:Wait()
end

return HudRegistry
