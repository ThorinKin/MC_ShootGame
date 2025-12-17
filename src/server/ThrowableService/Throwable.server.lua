-- ServerScriptService/Server/ThrowableService/Throwable.server.lua
-- 总注释：投掷物服务器逻辑。
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")

local BackpackModule = require(ServerScriptService.Server.BackpackService.BackpackModule)
local ThrowableConfig = require(script.Parent:WaitForChild("ThrowableConfig"))

local RemotesRoot      = ReplicatedStorage:WaitForChild("Remotes")
local ThrowableRemotes = RemotesRoot:WaitForChild("Throwables")
local RE_CS_Begin      = ThrowableRemotes:WaitForChild("[C-S]ThrowableBegin")
local RE_CS_Throw      = ThrowableRemotes:WaitForChild("[C-S]ThrowableThrow")

-- 资产路径
local AssetsRoot          = ReplicatedStorage:WaitForChild("Assets")
local ThrowablesTools     = AssetsRoot:WaitForChild("Throwables")
local ThrowablesPhysics   = AssetsRoot:WaitForChild("ThrowablesPhysics")

-- 调试开关
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[ThrowableServer] " .. string.format(fmt, ...))
    end
end

-- 每个玩家当前一轮投掷的状态
local usingStateByPlayer = {} :: {
    [Player]: {
        itemId: string?,
        subType: string?,
        tool: Tool?,
        prevWeaponTool: Tool?,
        thrown: boolean?,
    }
}

-- 工具：安全拿到玩家当前 Humanoid
local function getHumanoid(player: Player)
    local char = player.Character
    if not char or not char.Parent then
        return nil, nil
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return nil, char
    end

    return hum, char
end

local function clearPlayerState(player: Player)
    local st = usingStateByPlayer[player]
    if not st then
        return
    end
    -- 先拿一份 Humanoid
    local humanoid, _ = getHumanoid(player)
    -- 把临时投掷物 Tool 清掉
    if st.tool and st.tool.Parent then
        st.tool:Destroy()
    end
    -- 用官方接口恢复之前的武器
    if humanoid and st.prevWeaponTool and st.prevWeaponTool.Parent then
        local ok, err = pcall(function()
            humanoid:EquipTool(st.prevWeaponTool)
        end)
        if not ok then
            warn(("[ThrowableServer] 恢复武器 EquipTool 失败：%s"):format(tostring(err)))
        end
    end
    usingStateByPlayer[player] = nil
end

Players.PlayerRemoving:Connect(function(player)
    clearPlayerState(player)
end)

-- 工具：按 subType 拿配置
local function getConfigForSubType(subType: string)
    if type(subType) ~= "string" or subType == "" then
        return ThrowableConfig.Default
    end
    return ThrowableConfig[subType] or ThrowableConfig.Default
end

-- 工具：生成物理实体 + 安排爆炸
local function spawnThrowableAndExplode(player: Player, subType: string, origin: Vector3, direction: Vector3, chargeRatio: number)
    local config = getConfigForSubType(subType)
    dprint("spawnThrowableAndExplode begin, subType=%s", tostring(subType))

    local template = ThrowablesPhysics:FindFirstChild(subType)
    if not (template and template:IsA("Model")) then
        warn(("[ThrowableServer] 找不到 ThrowablesPhysics 模板：%s"):format(subType))
        return
    end

    local model = template:Clone()
    model.Name = template.Name

    local rootPart = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
    if not rootPart then
        warn("[ThrowableServer] Physics 模型缺少 PrimaryPart/BasePart：", model.Name)
        model:Destroy()
        return
    end

    local dir = direction
    if typeof(dir) ~= "Vector3" or dir.Magnitude < 0.001 then
        dir = Vector3.new(0, 1, 0)
    else
        dir = dir.Unit
    end

    local minV = config.MinThrowSpeed or 40
    local maxV = config.MaxThrowSpeed or 80
    local r = math.clamp(chargeRatio or 0, 0, 1)
    local speed = minV + (maxV - minV) * r

    model:PivotTo(CFrame.new(origin))
    model.Parent = workspace

    rootPart.AssemblyLinearVelocity = dir * speed

    local success, err = pcall(function()
        rootPart:SetNetworkOwner(player)
    end)
    if not success then
        dprint("SetNetworkOwner 失败：%s", tostring(err))
    end

    -- 这里开始找行为模块ThrowableBehavior ThrowableBehavior
    local behaviorModule: ModuleScript? = model:FindFirstChild("ThrowableBehavior", true)
    -- -- 调试日志
    -- dprint("Physics model descendants for %s:", subType)
    -- for _, inst in ipairs(model:GetDescendants()) do
    --     dprint("  - %s (%s)", inst:GetFullName(), inst.ClassName)
    -- end
    -- -- 调试日志
    if behaviorModule and behaviorModule:IsA("ModuleScript") then
        dprint("找到 ThrowableBehavior 模块：%s", behaviorModule:GetFullName())
        local okBehavior, behavior = pcall(require, behaviorModule)
        if not okBehavior then
            warn(("[ThrowableServer] require ThrowableBehavior 失败：%s"):format(tostring(behavior)))
        elseif type(behavior) == "table" and type(behavior.start) == "function" then
            dprint("调用 ThrowableBehavior.start()")
            behavior.start({
                model    = model,
                rootPart = rootPart,
                owner    = player,
                config   = config,
                subType  = subType,
            })
        else
            warn("[ThrowableServer] ThrowableBehavior 模块缺少 start(ctx) 函数：", behaviorModule:GetFullName())
        end
    else
        -- 兜底逻辑：没有行为模块时最简版爆炸
        warn(("[ThrowableServer] 未找到 ThrowableBehavior 模块，使用兜底逻辑，subType=%s"):format(subType))

        local fuseTime      = config.FuseTime          or 3
        local explosionLife = config.ExplosionLifeTime or 4

        task.spawn(function()
            task.wait(fuseTime)
            if not model.Parent then
                return
            end
            for _, descendant in ipairs(model:GetDescendants()) do
                if descendant:IsA("ParticleEmitter") then
                    descendant.Enabled = true
                elseif descendant:IsA("Sound") then
                    if not descendant.Playing then
                        descendant:Play()
                    end
                end
            end
            task.wait(explosionLife)
            if model and model.Parent then
                model:Destroy()
            end
        end)
    end
end

-- C-S：玩家请求开始一次投掷（按下 Skill1）
RE_CS_Begin.OnServerEvent:Connect(function(player, itemId)
    if type(itemId) ~= "string" or #itemId == 0 then
        return
    end
    local humanoid, char = getHumanoid(player)
    if not humanoid or not char then
        return
    end
    -- 校验这个 itemId 属于该玩家，并且类型是 throwable
    local item = BackpackModule.getItem(player, itemId)
    if not item then
        dprint("%s 请求使用投掷物失败：背包中找不到 itemId=%s", player.Name, itemId)
        return
    end
    if item.type ~= BackpackModule.ITEM_TYPE.Throwable then
        dprint("%s 请求使用投掷物失败：物品类型不是 throwable。itemId=%s, type=%s",
            player.Name, itemId, tostring(item.type))
        return
    end
    local subType = tostring(item.subType or "")
    if subType == "" then
        subType = "Throwable_1"
    end
    -- 防止重复请求：如果上一轮还没完，先清掉（里面会尝试恢复之前那把枪）
    if usingStateByPlayer[player] then
        clearPlayerState(player)
    end
    -- 记录当前已经装备的武器（还在角色身上的那把 Tool）
    local prevWeaponTool: Tool? = nil
    for _, child in ipairs(char:GetChildren()) do
        if child:IsA("Tool") then
            prevWeaponTool = child
            break
        end
    end
    -- 克隆投掷物 Tool 到背包，交给 Humanoid:EquipTool 去处理切换
    local toolTemplate = ThrowablesTools:FindFirstChild(subType)
    if not (toolTemplate and toolTemplate:IsA("Tool")) then
        warn(("[ThrowableServer] 找不到 Throwables Tool 模板：%s"):format(subType))
        return
    end
    local tool = toolTemplate:Clone()
    tool.Name = toolTemplate.Name
    tool:SetAttribute("BackpackItemId", itemId)
    tool:SetAttribute("SubType", subType)
    tool.Parent = player.Backpack
    -- 官方接口：由 Humanoid 来做卸下旧武器 → 装上手雷的全流程
    local ok, err = pcall(function()
        humanoid:EquipTool(tool)
    end)
    if not ok then
        warn(("[ThrowableServer] EquipTool 失败：%s"):format(tostring(err)))
        tool:Destroy()
        return
    end
    usingStateByPlayer[player] = {
        itemId         = itemId,
        subType        = subType,
        tool           = tool,
        prevWeaponTool = prevWeaponTool,
        thrown         = false,
    }
    dprint("%s 开始使用投掷物：itemId=%s, subType=%s", player.Name, itemId, subType)
end)

-- C-S：真正丢出（Throw 动画 Release 帧触发）
RE_CS_Throw.OnServerEvent:Connect(function(player, itemId, subType, origin, direction, chargeRatio)
    if typeof(origin) ~= "Vector3" or typeof(direction) ~= "Vector3" then
        return
    end

    local st = usingStateByPlayer[player]
    if not st then
        dprint("%s ThrowableThrow 失败：玩家当前没有投掷状态", player.Name)
        return
    end

    -- 防止重复 Throw
    if st.thrown then
        return
    end
    st.thrown = true

    -- 简单一致性校验：itemId / subType
    if type(itemId) == "string" and itemId ~= "" and st.itemId and st.itemId ~= itemId then
        dprint("%s ThrowableThrow 警告：客户端传入 itemId=%s 和服务器记录不一致=%s",
            player.Name, itemId, st.itemId)
    end

    if type(subType) ~= "string" or subType == "" then
        subType = st.subType or "Throwable_1"
    end

    chargeRatio = tonumber(chargeRatio) or 0
    chargeRatio = math.clamp(chargeRatio, 0, 1)

    dprint("%s 丢出投掷物：subType=%s, charge=%.2f", player.Name, subType, chargeRatio)

    spawnThrowableAndExplode(player, subType, origin, direction, chargeRatio)

    -- 配置里如果要求消耗物品，就从背包删掉那件
    local config = getConfigForSubType(subType)
    if config.UseInventory and st.itemId then
        BackpackModule.removeItem(player, st.itemId, "throwable_used")
    end

    -- 清掉 Tool & 尝试恢复之前武器
    clearPlayerState(player)
end)
