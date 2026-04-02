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
	AttackRange = 4.75,
	AttackVerticalTolerance = 5,
	AttackCooldown = 2,
	AttackHealthFraction = 0.25,
	RetreatDistance = 22,
	Damage = 8,
	PathReplanInterval = 0.7,
	PathDestinationChangeThreshold = 6,
	WaypointReachedDistance = 3.5,
	StuckReplanSeconds = 1.5,
	MaxJumpRise = 7.5,
	ForwardJumpProbeDistance = 7,
	AssistJumpRiseThreshold = 2,
	AssistJumpDistance = 24,
	AssistJumpCooldown = 0.55,
	ParkourProbeDistance = 8,
	ParkourLowProbeHeight = 2,
	ParkourClearanceHeight = 9,
	ParkourLandingProbeHeight = 10,
	ParkourLandingProbeDepth = 18,
	ParkourLandingForwardOffset = 2.5,
	ParkourMinRise = 1,
	ParkourSampleStep = 2,
	ParkourMaxSamples = 5,
	ParkourLandingYOffset = 1,
	AllowDirectMoveFallback = true,
	PathOptions = {
		AgentRadius = 1.5,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		WaypointSpacing = 2,
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
	RouteLifetimeMin = 4.5,
	RouteLifetimeMax = 7.2,
	RouteRefreshDistance = 18,
	RouteJitterMax = 1,
	CloneSpawnInterval = 10,
	MaxSpawnedClones = 4,
	CloneSpawnRadius = 8,
}

local cloneSerial = 0

local function setSpawnIdentity(model, isTemplate, generation, cloneSource)
	model:SetAttribute("NpcSpawnTemplate", isTemplate)
	model:SetAttribute("NpcSpawnGeneration", generation)
	model:SetAttribute("NpcCloneSource", cloneSource)

	if generation == 0 and model:GetAttribute("NpcTemplateSpawnX") == nil then
		local origin = model:GetPivot().Position
		model:SetAttribute("NpcTemplateSpawnX", origin.X)
		model:SetAttribute("NpcTemplateSpawnY", origin.Y)
		model:SetAttribute("NpcTemplateSpawnZ", origin.Z)
	end
end

local function resetRuntimeAttributes(model)
	model:SetAttribute("AiState", "Spawning")
	model:SetAttribute("RouteMode", "Spawn")
	model:SetAttribute("LastPathError", "")
	model:SetAttribute("NpcControllerError", "")
	model:SetAttribute("NpcControllerReady", false)
	model:SetAttribute("NpcRegistrationState", "PendingSpawn")
end

local function registerNpc(model)
	model:SetAttribute("NpcRegistrationState", "Registering")

	if model:GetAttribute("NpcSpawnGeneration") == nil then
		setSpawnIdentity(model, true, 0, model.Name)
	end

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
		humanoid.JumpPower = math.max(humanoid.JumpPower, 60)
	else
		humanoid.JumpHeight = math.max(humanoid.JumpHeight, 10)
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

local function getTemplateSpawnCFrame(template)
	local x = template:GetAttribute("NpcTemplateSpawnX")
	local y = template:GetAttribute("NpcTemplateSpawnY")
	local z = template:GetAttribute("NpcTemplateSpawnZ")

	if type(x) == "number" and type(y) == "number" and type(z) == "number" then
		return CFrame.new(x, y, z)
	end

	return template:GetPivot()
end

local function countAllSpawnedClones()
	local count = 0
	for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
		if npcModel:IsA("Model") and (npcModel:GetAttribute("NpcSpawnGeneration") or 0) > 0 then
			local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 and npcModel.Parent then
				count = count + 1
			end
		end
	end

	return count
end

local function spawnCloneFromTemplate(template)
	local cloneSource = template:GetAttribute("NpcCloneSource") or template.Name
	if countAllSpawnedClones() >= defaultConfig.MaxSpawnedClones then
		return
	end

	local clone = template:Clone()
	cloneSerial = cloneSerial + 1
	clone.Name = ("%sClone%d"):format(template.Name, cloneSerial)

	local nextGeneration = (template:GetAttribute("NpcSpawnGeneration") or 0) + 1
	setSpawnIdentity(clone, false, nextGeneration, cloneSource)
	resetRuntimeAttributes(clone)

	local pivot = getTemplateSpawnCFrame(template)
	local spawnOffset = Vector3.new(
		math.random(-defaultConfig.CloneSpawnRadius, defaultConfig.CloneSpawnRadius),
		0,
		math.random(-defaultConfig.CloneSpawnRadius, defaultConfig.CloneSpawnRadius)
	)

	pcall(function()
		CollectionService:RemoveTag(clone, "CombatNpc")
	end)

	clone:PivotTo(pivot + spawnOffset + Vector3.new(0, 1, 0))
	clone.Parent = template.Parent
	CollectionService:AddTag(clone, "CombatNpc")
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

task.spawn(function()
	while true do
		task.wait(defaultConfig.CloneSpawnInterval)
		for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
			if npcModel:IsA("Model") and npcModel:GetAttribute("NpcSpawnTemplate") == true then
				local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 and npcModel.Parent then
					spawnCloneFromTemplate(npcModel)
				end
			end
		end
	end
end)

npcService:Start()

game:BindToClose(function()
	npcService:Destroy()
end)
