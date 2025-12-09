-- ServerScriptService/Server/AttrService/AttrServer.server.lua
-- 总注释：属性加点系统服务器桥。同步到 player.Attr 下的只读节点，并处理客户端加点请求
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[AttrServer] " .. string.format(fmt, ...))
    end
end

local AttrModule = require(ServerScriptService.Server.AttrService.AttrModule)
local F          = AttrModule.FIELDS
local DISPLAY    = AttrModule.DISPLAY_NAME

-- 远程事件：只做 C-S，加点请求
local RemotesRoot   = ReplicatedStorage:WaitForChild("Remotes")
local AttrRemotes   = RemotesRoot:WaitForChild("Attr")
local RE_CS_Add     = AttrRemotes:WaitForChild("[C-S]AttrAddPoints")
-- Message 提示
local MessageRemotes   = RemotesRoot:WaitForChild("Message")
local RemoteMessageBar = MessageRemotes:WaitForChild("[S-C]Message")
local RemoteMessageNo  = MessageRemotes:WaitForChild("[S-C]MessageNo")

-- 工具：发提示信息
local function sendMsg(player, text, noBar)
    if not player or not player.Parent then
        return
    end
    if noBar then
        RemoteMessageNo:FireClient(player, text)
    else
        RemoteMessageBar:FireClient(player, text)
    end
end

-- 同步到 player.Attr 文件夹（只读，给前端/别的系统看）
-- 工具：确保 Attr 文件夹及子节点
local function ensureAttrFolder(player)
    local folder = player:FindFirstChild("Attr")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Attr"
        folder.Parent = player
    end

    local function ensureNode(name: string, className: string)
        local n = folder:FindFirstChild(name)
        if not n then
            n = Instance.new(className)
            n.Name = name
            n.Parent = folder
        end
        return n
    end

    -- Attack / Defense / Health 三个显示用数值
    local atk = ensureNode("Attack",  "IntValue")
    local def = ensureNode("Defense", "IntValue")
    local hp  = ensureNode("Health",  "IntValue")

    return folder, atk, def, hp
end

-- 工具：根据快照同步 UI
local function syncFromSnapshot(player, state)
    if not player or not player.Parent then
        return
    end

    state = state or AttrModule.getAll(player)

    local atk = state[F.attack]  or 0
    local def = state[F.defense] or 0
    local hp  = state[F.health]  or 0

    local _, fAtk, fDef, fHp = ensureAttrFolder(player)
    fAtk.Value = atk
    fDef.Value = def
    fHp.Value  = hp
end

-- 玩家加入：建节点 + 同步一帧
Players.PlayerAdded:Connect(function(player)
    ensureAttrFolder(player)

    local ok, err = pcall(function()
        syncFromSnapshot(player)
    end)
    if not ok then
        warn(("[AttrServer] 初始化 %s Attr UI 失败：%s"):format(player.Name, tostring(err)))
    end
end)

-- 监听 AttrModule 的变更事件：即时刷新 UI
AttrModule.onChanged(function(player, snapshot)
    local ok, err = pcall(function()
        syncFromSnapshot(player, snapshot)
    end)
    if not ok then
        warn(("[AttrServer] syncFromSnapshot 出错：%s"):format(tostring(err)))
    end
end)


-- C-S：加点 Remote 处理
RE_CS_Add.OnServerEvent:Connect(function(player, attrName, amount)
    -- 基本参数校验
    if type(attrName) ~= "string" or #attrName == 0 then
        sendMsg(player, "Invalid attribute.", true)
        return
    end

    amount = tonumber(amount) or 0
    amount = math.floor(amount)
    if amount <= 0 then
        sendMsg(player, "Invalid point amount.", true)
        return
    end

    local ok, fieldKey, newValue, usedSp, freeSp, errCode =
        AttrModule.spendPoints(player, attrName, amount, "client_add")

    if not ok then
        local msg = "Cannot allocate points."
        if errCode == "invalid_attr" then
            msg = "Invalid attribute."
        elseif errCode == "invalid_amount" then
            msg = "Invalid point amount."
        elseif errCode == "not_enough_sp" then
            msg = "Not enough skill points."
        end
        sendMsg(player, msg, true)
        return
    end

    local displayName = DISPLAY[fieldKey] or tostring(fieldKey)
    freeSp = freeSp or 0

    dprint("%s 成功给 %s 加点 +%d → %d（剩余技能点 %d）",
        player.Name, displayName, amount, newValue or -1, freeSp)

    local tip = string.format("%s +%d (free skill points: %d).",
        displayName, amount, freeSp)

    sendMsg(player, tip, false)
    -- 真正的数值同步交给 AttrModule.onChanged → syncFromSnapshot
end)
