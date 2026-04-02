local CollectionService = game:GetService("CollectionService")

local NpcService = require(script.Parent.AI.NpcService)

local npcService = NpcService.new()

local defaultConfig = {
	AggroRadius = 65,
	MaxLeashDistance = 90,
	PatrolRadius = 18,
	AttackRange = 6,
	AttackCooldown = 1.2,
	RetreatDistance = 20,
	Damage = 8,
}

local function registerNpc(model)
	if npcService:HasNpc(model) then
		return
	end

	npcService:RegisterNpc(model, defaultConfig)
end

for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
	registerNpc(npcModel)
end

CollectionService:GetInstanceAddedSignal("CombatNpc"):Connect(function(instance)
	if instance:IsA("Model") then
		registerNpc(instance)
	end
end)

CollectionService:GetInstanceRemovedSignal("CombatNpc"):Connect(function(instance)
	if instance:IsA("Model") then
		npcService:RemoveNpc(instance)
	end
end)

npcService:Start()

game:BindToClose(function()
	npcService:Destroy()
end)
