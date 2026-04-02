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

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then
		warn(("[NpcAI] Skipping %s because it is missing Humanoid or HumanoidRootPart"):format(model:GetFullName()))
		return
	end

	if model.PrimaryPart == nil then
		model.PrimaryPart = root
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end

	if humanoid.WalkSpeed <= 0 then
		humanoid.WalkSpeed = 10
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
