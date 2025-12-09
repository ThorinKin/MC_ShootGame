-- ServerScriptService/Server/DataCore/StoreRegistry.lua
-- 总注释：枚举所有 DataStore2.Combine() 的子键
local StoreRegistry = {
    Eco = "Eco",   -- 经济系统
    Exp = "Exp",   -- 经验系统
    Attr = "Attr",     -- 属性加点系统（攻击/防御/生命）
    Backpack = "Backpack", -- 背包系统
    Pet = "Pet",       -- 宠物系统
    -- ！可扩展
}
table.freeze(StoreRegistry)
return StoreRegistry
