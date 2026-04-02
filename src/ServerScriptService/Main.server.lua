local CollectionService = game:GetService("CollectionService")

local function markTaggedNpc(attributeName, value)
	for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
		if npcModel:IsA("Model") then
			npcModel:SetAttribute(attributeName, value)
		end
	end
end

markTaggedNpc("NpcBootScriptLoaded", true)

local ok, NpcServiceOrError = pcall(function()
	return require(script.Parent.AI.NpcService)
end)

if not ok then
	markTaggedNpc("NpcBootError", tostring(NpcServiceOrError))
	error(("[NpcAI] Failed to boot NpcService: %s"):format(tostring(NpcServiceOrError)))
end

local NpcService = NpcServiceOrError

local newOk, npcServiceOrError = pcall(function()
	return NpcService.new()
end)

if not newOk then
	markTaggedNpc("NpcBootError", tostring(npcServiceOrError))
	error(("[NpcAI] Failed to construct NpcService: %s"):format(tostring(npcServiceOrError)))
end

local npcService = npcServiceOrError
markTaggedNpc("NpcBootError", "")

local defaultConfig = {
	AggroRadius = 80,
	MaxLeashDistance = 120,
	PatrolRadius = 22,
	AttackRange = 8,
	AttackVerticalTolerance = 7,
	AttackCooldown = 2,
	AttackHealthFraction = 0.25,
	RetreatDistance = 22,
	Damage = 8,
	PathReplanInterval = 0.45,
	PathDestinationChangeThreshold = 4,
	WaypointReachedDistance = 3.5,
	StuckReplanSeconds = 1.2,
	MaxJumpRise = 6.5,
	ForwardJumpProbeDistance = 5.5,
	AllowDirectMoveFallback = true,
	PathOptions = {
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		WaypointSpacing = 3,
	},
	MinFlankOffset = 7,
	MaxFlankOffset = 16,
	MinWideOffset = 12,
	MaxWideOffset = 24,
	MinCutoffDepth = 6,
	MaxCutoffDepth = 16,
	MinBackdoorDepth = 10,
	MaxBackdoorDepth = 24,
	MinPincerDepth = 5,
	MaxPincerDepth = 12,
	InterceptDistanceDivisor = 16,
	MinInterceptSeconds = 0.35,
	MaxInterceptSeconds = 1.1,
	RouteLifetimeMin = 1.2,
	RouteLifetimeMax = 2.4,
	RouteRefreshDistance = 8,
	RouteJitterMax = 2,
}

local function registerNpc(model)
	model:SetAttribute("NpcRegistrationState", "Registering")

	if npcService:HasNpc(model) then
		model:SetAttribute("NpcRegistrationState", "Active")
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")

	if not humanoid or not root then
		model:SetAttribute("NpcRegistrationState", "MissingParts")
		model:SetAttribute("NpcControllerError", "Humanoid or HumanoidRootPart missing")
		warn(("[NpcAI] Skipping %s because it is missing Humanoid or HumanoidRootPart"):format(model:GetFullName()))
		return
	end

	if model.PrimaryPart == nil then
		model.PrimaryPart = root
	end

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false

			if descendant.Name == "HumanoidRootPart" or descendant:IsA("MeshPart") then
				descendant.CanCollide = false
			end

			if descendant.Parent and descendant.Parent:IsA("Accessory") then
				descendant.CanCollide = false
				descendant.Massless = true
			end
		end
	end

	if humanoid.WalkSpeed <= 0 then
		humanoid.WalkSpeed = 10
	end

	humanoid.AutoRotate = true
	humanoid.PlatformStand = false
	humanoid.Sit = false
	if humanoid.UseJumpPower then
		humanoid.JumpPower = math.max(humanoid.JumpPower, 46)
	else
		humanoid.JumpHeight = math.max(humanoid.JumpHeight, 7.5)
	end

	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	local controller = npcService:RegisterNpc(model, defaultConfig)
	if controller then
		model:SetAttribute("NpcRegistrationState", "Active")
	else
		model:SetAttribute("NpcRegistrationState", "ControllerFailed")
	end
end

for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
	registerNpc(npcModel)
end

CollectionService:GetInstanceAddedSignal("CombatNpc"):Connect(function(instance)
	if instance:IsA("Model") then
		instance:SetAttribute("NpcBootScriptLoaded", true)
		registerNpc(instance)
	end
end)

CollectionService:GetInstanceRemovedSignal("CombatNpc"):Connect(function(instance)
	if instance:IsA("Model") then
		npcService:RemoveNpc(instance)
	end
end)

task.spawn(function()
	while true do
		task.wait(1)
		for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
			if npcModel:IsA("Model") then
				registerNpc(npcModel)
			end
		end
	end
end)

npcService:Start()

game:BindToClose(function()
	npcService:Destroy()
end)
