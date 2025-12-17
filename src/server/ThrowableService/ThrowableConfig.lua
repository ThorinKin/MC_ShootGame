-- ServerScriptService/Server/ThrowableService/ThrowableConfig.lua
-- 总注释：投掷物配置表。按 subType 配置基础参数
local ThrowableConfig = {
    -- subType = "Throwable_1" 破片手雷
    Throwable_1 = {
        MinThrowSpeed      = 40,  -- 最小初速度（m/s）
        MaxThrowSpeed      = 80,  -- 最大初速度（m/s）
        FuseTime           = 3,   -- 引信时间（秒）
        ExplosionLifeTime  = 1,   -- 爆炸粒子存活时间（秒）
        UseInventory       = false,-- 是否消耗背包里的物品
        Damage             = 60,  -- 伤害值
        DamageRadius       = 10,  -- 伤害半径（stud）
    },
}

-- 默认配置，无配置用这个
ThrowableConfig.Default = {
    MinThrowSpeed      = 40,
    MaxThrowSpeed      = 80,
    FuseTime           = 3,
    ExplosionLifeTime  = 1,
    UseInventory       = false,
    Damage             = 40,
    DamageRadius       = 10,
}

return ThrowableConfig
