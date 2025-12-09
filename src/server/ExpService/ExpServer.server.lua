-- ServerScriptService/Server/ExpService/ExpServer.server.lua
-- 总注释：Exp 数据同步到 leaderstats / 玩家下的 Exp 文件夹（只读）
local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ExpModule = require(ServerScriptService.Server.ExpService.ExpModule)
local F = ExpModule.FIELDS

-- 工具：确保 leaderstats/Level 存在
local function ensureLeaderstats(player)
    local stats = player:FindFirstChild("leaderstats")
    if not stats then
        stats = Instance.new("Folder")
        stats.Name = "leaderstats"
        stats.Parent = player
    end

    local lvl = stats:FindFirstChild("Level")
    if not lvl then
        lvl = Instance.new("IntValue")
        lvl.Name = "Level"
        lvl.Parent = stats
    end

    return stats, lvl
end

-- 工具：确保 Exp 文件夹及子节点
local function ensureExpFolder(player)
    local folder = player:FindFirstChild("Exp")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Exp"
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

    local lvl       = ensureNode("Level",      "IntValue")
    local xp        = ensureNode("Xp",         "NumberValue")
    local xpInLv    = ensureNode("XpInLevel",  "IntValue")
    local skillUsed = ensureNode("SkillUsed",  "IntValue")
    local skillFree = ensureNode("SkillFree",  "IntValue")

    return folder, lvl, xp, xpInLv, skillUsed, skillFree
end

-- 工具：根据快照同步所有 UI
local function syncFromSnapshot(player, state)
    if not player or not player.Parent then return end

    state = state or ExpModule.getAll(player)

    local lvl  = state[F.level]     or 1
    local xp   = state[F.xp]        or 0
    local xil  = state[F.xpInLevel] or 0
    local used = state[F.usedSp]    or 0

    local cap  = ExpModule.totalSkillPointsForLevel(lvl)
    if used > cap then used = cap end
    local free = math.max(0, cap - used)

    -- leaderstats
    local _, statsLevel = ensureLeaderstats(player)
    statsLevel.Value = lvl

    -- Exp 文件夹
    local _, fLvl, fXp, fXpInLv, fSkillUsed, fSkillFree = ensureExpFolder(player)
    fLvl.Value       = lvl
    fXp.Value        = xp
    fXpInLv.Value    = xil
    fSkillUsed.Value = used
    fSkillFree.Value = free
end

-- 玩家加入：建节点 + 同步一帧
Players.PlayerAdded:Connect(function(player)
    ensureLeaderstats(player)
    ensureExpFolder(player)

    local ok, err = pcall(function()
        syncFromSnapshot(player)
    end)
    if not ok then
        warn(("[ExpServer] 初始化 %s Exp UI 失败：%s"):format(player.Name, tostring(err)))
    end
end)

-- 监听 ExpModule 的变更事件：即时刷新 UI
ExpModule.onChanged(function(player, snapshot)
    local ok, err = pcall(function()
        syncFromSnapshot(player, snapshot)
    end)
    if not ok then
        warn(("[ExpServer] syncFromSnapshot 出错：%s"):format(tostring(err)))
    end
end)
