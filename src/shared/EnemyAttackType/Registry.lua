-- ReplicatedStorage/Shared/EnemyAttackType/Registry.lua
-- 攻击类型注册表：字符串类型名 对应攻击类型 模块
local EnemyAttackTypeRegistry = {}
local folder = script.Parent

-- 登记枚举所有可用攻击类型：
EnemyAttackTypeRegistry.Types = {
	SingleMelee = require(folder:WaitForChild("SingleMelee")),
}

-- 工具：根据类型名拿到模块
function EnemyAttackTypeRegistry.get(typeName: string)
	return EnemyAttackTypeRegistry.Types[typeName]
end

return EnemyAttackTypeRegistry
