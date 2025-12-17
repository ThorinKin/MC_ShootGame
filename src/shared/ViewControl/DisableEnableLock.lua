--!strict
-- ReplicatedStorage/Shared/ViewControl/DisableEnableLock.lua
-- 总注释：临时停用启用FPS/TPS/投掷物系统开关
local HttpService = game:GetService("HttpService")

local GameplayLock = {}

local ATTR_LOCKED = "GameplayLocked"
local ATTR_LOCK_COUNT = "GameplayLockCount"

type LockState = {
	tokens: {[string]: string},
}

-- 弱表：角色销毁后自动释放内存
local locksByCharacter = setmetatable({} :: {[Model]: LockState}, { __mode = "k" })

local function canTouchChar(character: Model): boolean
	return character ~= nil and character.Parent ~= nil
end

local function getState(character: Model): LockState
	local st = locksByCharacter[character]
	if not st then
		st = { tokens = {} }
		locksByCharacter[character] = st
	end
	return st
end

local function refreshAttrs(character: Model, st: LockState)
    if not canTouchChar(character) then return end
	local count = 0
	for _ in pairs(st.tokens) do
		count += 1
	end
	character:SetAttribute(ATTR_LOCK_COUNT, count)
	character:SetAttribute(ATTR_LOCKED, count > 0)
end

function GameplayLock.acquire(character: Model, reason: string?): string
	local st = getState(character)
	local token = HttpService:GenerateGUID(false)
	st.tokens[token] = reason or "unknown"
	refreshAttrs(character, st)
	return token
end

function GameplayLock.release(character: Model, token: string)
	local st = locksByCharacter[character]
	if not st then
		return
	end
	st.tokens[token] = nil
	refreshAttrs(character, st)
end

function GameplayLock.isLocked(character: Model?): boolean
	if not character then
		return false
	end
	return character:GetAttribute(ATTR_LOCKED) == true
end

function GameplayLock.clear(character: Model)
	locksByCharacter[character] = nil
	if not canTouchChar(character) then return end
	character:SetAttribute(ATTR_LOCK_COUNT, 0)
	character:SetAttribute(ATTR_LOCKED, false)
end

return GameplayLock
