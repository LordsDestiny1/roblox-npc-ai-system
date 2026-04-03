local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local NPC_COLLISION_GROUP = "CombatNpcAgents"

pcall(function()
	PhysicsService:RegisterCollisionGroup(NPC_COLLISION_GROUP)
end)

pcall(function()
	PhysicsService:CollisionGroupSetCollidable(NPC_COLLISION_GROUP, NPC_COLLISION_GROUP, false)
end)

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
	AggroRadius = 20000,
	MaxLeashDistance = 25000,
	PatrolRadius = 22,
	AttackRange = 4.75,
	AttackVerticalTolerance = 5,
	AttackCooldown = 2,
	AttackHealthFraction = 1 / 12,
	AttackApproachStandOff = 2.2,
	RetreatDistance = 22,
	Damage = 8,
	DirectEngageDistance = 12,
	FlankMinimumDistance = 20,
	RespawnAggroCooldown = 5,
	KillResetReturnTimeout = 5,
	TargetMemorySeconds = 8.5,
	PathReplanInterval = 0.1,
	PathDestinationChangeThreshold = 3.2,
	WaypointReachedDistance = 2.75,
	StuckReplanSeconds = 0.38,
	PatrolWalkSpeed = 10,
	ChaseWalkSpeed = 15,
	ReturnWalkSpeed = 12,
	ParkourWalkSpeed = 10.5,
	MaxJumpRise = 8.5,
	ParkourSearchMaxRise = 12,
	ParkourMaxDrop = 8,
	ParkourSearchDistance = 40,
	ParkourSearchForwardOvershoot = 10,
	ParkourSearchHeight = 26,
	ParkourSurfaceInset = 0.55,
	ParkourSurfaceNormalMin = 0.72,
	ParkourNodeLimit = 56,
	ParkourExpansionDepth = 3,
	ParkourExpansionFrontierLimit = 8,
	ParkourExpansionForwardStep = 3.4,
	ParkourExpansionMaxForwardSteps = 3,
	ParkourExpansionLateralSteps = 2,
	ParkourExpansionLateralSpacing = 2.25,
	ParkourWallClimbVerticalStep = 2.5,
	ParkourSearchWidth = 16,
	ParkourCandidateLimit = 6,
	ParkourGoalDistance = 6,
	ParkourGoalHeightTolerance = 4.5,
	ParkourWalkLinkDistance = 8,
	ParkourWalkSupportTolerance = 1.1,
	ParkourWalkRise = 2.8,
	ParkourWalkDrop = 4.5,
	ParkourWalkStepRise = 0.95,
	ParkourHopLinkDistance = 11.25,
	ParkourHopDrop = 5.5,
	ParkourHopPenalty = 2.2,
	ParkourBacktrackAllowance = 4,
	ParkourProgressThreshold = 2,
	ParkourPlanInterval = 0.36,
	ParkourPathReplanDistance = 4,
	ParkourOriginReplanDistance = 2.5,
	ParkourTargetSampleRadius = 3,
	ParkourTargetSampleRings = 5,
	ForwardJumpProbeDistance = 7,
	AssistJumpRiseThreshold = 1.1,
	AssistJumpDistance = 24,
	AssistJumpCooldown = 0.55,
	ParkourProbeDistance = 12,
	ParkourLowProbeHeight = 2,
	ParkourClearanceHeight = 9,
	ParkourLandingProbeHeight = 10,
	ParkourLandingProbeDepth = 26,
	ParkourLandingForwardOffset = 1.5,
	ParkourMinRise = 1,
	ParkourSampleStep = 2,
	ParkourMaxSamples = 7,
	ParkourLandingYOffset = 0.75,
	ParkourLandingTolerance = 1.6,
	ParkourCommitSeconds = 1.2,
	ParkourLaunchApproachRadius = 0.95,
	ParkourLaunchAssistDistance = 8.5,
	ParkourLaunchVerticalTolerance = 1.25,
	ParkourSearchEntryMaxRise = 5.5,
	ParkourSearchBlindDirectDistance = 12,
	ParkourStepReachDistance = 1.55,
	ParkourMinFootprint = 0.45,
	ParkourPrecisionHopMaxRise = 4.4,
	ParkourPrecisionHopDistance = 8.25,
	ParkourSideBiasScale = 0.03,
	ParkourSearchOriginStickDistance = 6,
	ParkourSearchReplanInterval = 0.24,
	ParkourSearchArrivalDistance = 2.8,
	ParkourDirectApproachDistance = 5.5,
	ParkourHorizontalSpeedMin = 6.5,
	ParkourHorizontalSpeedMax = 18.5,
	ParkourVerticalSpeedMin = 12,
	ParkourVerticalSpeedMax = 70,
	ParkourNominalHorizontalSpeed = 13.5,
	ParkourFlightTimeMin = 0.48,
	ParkourFlightTimeMax = 0.92,
	ParkourArcSamples = 9,
	ParkourJumpAirControl = 0.02,
	ParkourLateralProbeCount = 2,
	ParkourLateralSpacing = 1.2,
	AllowDirectMoveFallback = true,
	PathOptions = {
		AgentRadius = 1.2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = true,
		WaypointSpacing = 1,
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
	RouteLifetimeMin = 5.2,
	RouteLifetimeMax = 7.8,
	RouteRefreshDistance = 12,
	RouteJitterMax = 0.2,
	FlankRouteLifetime = 1.8,
	EnableStrategicFlanking = true,
	EnableDebugOverlay = true,
	SearchMemorySeconds = 4.5,
	SearchMemoryLeadDistance = 18,
	StuckFailureThreshold = 2,
	StuckPressureSeconds = 1.8,
	StuckSampleInterval = 0.22,
	StuckMinProgress = 0.25,
	SpinRecoverAngle = 45,
	FlankMinPathGain = 4,
	FlankCatchMargin = 1.5,
	FlankStrongLead = 6,
	FlankDirectCostAllowance = 10,
	FlankMinPlayerTravel = 6,
	FlankMaxPlayerTravel = 90,
	FlankIntersectionOpenness = 0.52,
	FlankCornerAngle = 26,
	FlankWaypointLookahead = 6,
	FlankProbeDistances = { 10, 18, 28, 38 },
	FlankProbeLateralOffsets = { 0, 8, -8, 14, -14 },
	EnableCloneSpawning = false,
	CloneSpawnInterval = 10,
	MaxSpawnedClones = 0,
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
	model:SetAttribute("ParkourPreferredSide", nil)
	model:SetAttribute("NpcControllerError", "")
	model:SetAttribute("NpcControllerReady", false)
	model:SetAttribute("NpcRegistrationState", "PendingSpawn")
	model:SetAttribute("NpcAggroHoldUntil", 0)
	model:SetAttribute("NpcKillResetPending", false)
end

local function registerNpc(model)
	model:SetAttribute("NpcRegistrationState", "Registering")
	model:SetAttribute("ParkourPreferredSide", nil)

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
			pcall(function()
				descendant.CollisionGroup = NPC_COLLISION_GROUP
			end)

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

local function isSpawnedClone(model)
	return (model:GetAttribute("NpcSpawnGeneration") or 0) > 0
end

local function despawnAllClones()
	for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
		if npcModel:IsA("Model") and isSpawnedClone(npcModel) then
			npcService:RemoveNpc(npcModel)
			pcall(function()
				CollectionService:RemoveTag(npcModel, "CombatNpc")
			end)
			npcModel:Destroy()
		end
	end
end

local function resetTemplateNpcs()
	despawnAllClones()

	for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
		if npcModel:IsA("Model") and npcModel:GetAttribute("NpcSpawnTemplate") == true then
			npcService:ResetNpc(npcModel, defaultConfig.RespawnAggroCooldown)
		end
	end
end

local function spawnCloneFromTemplate(template)
	if not defaultConfig.EnableCloneSpawning then
		return
	end

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

despawnAllClones()

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

if defaultConfig.EnableCloneSpawning and defaultConfig.MaxSpawnedClones > 0 then
	task.spawn(function()
		while true do
			task.wait(defaultConfig.CloneSpawnInterval)
			for _, npcModel in ipairs(CollectionService:GetTagged("CombatNpc")) do
				if npcModel:IsA("Model") and npcModel:GetAttribute("NpcSpawnTemplate") == true then
					local holdUntil = npcModel:GetAttribute("NpcAggroHoldUntil")
					local killResetPending = npcModel:GetAttribute("NpcKillResetPending") == true
					local humanoid = npcModel:FindFirstChildOfClass("Humanoid")
					if humanoid and humanoid.Health > 0 and npcModel.Parent and not killResetPending and (type(holdUntil) ~= "number" or holdUntil <= os.clock()) then
						spawnCloneFromTemplate(npcModel)
					end
				end
			end
		end
	end)
end

local function bindCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	humanoid.Died:Connect(function()
		resetTemplateNpcs()
	end)
end

local function bindPlayer(player)
	if player.Character then
		bindCharacter(player.Character)
	end

	player.CharacterAdded:Connect(bindCharacter)
end

for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end

Players.PlayerAdded:Connect(bindPlayer)

npcService:Start()

game:BindToClose(function()
	npcService:Destroy()
end)
