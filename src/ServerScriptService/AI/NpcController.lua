local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local NpcController = {}
NpcController.__index = NpcController

local cachedNpcAnimationController = nil
local cachedFlankPlanner = nil
local cachedParkourPlanner = nil
local cachedTacticalPlanner = nil
local cachedUtilityScorer = nil

local function requireChildModule(moduleName)
	local moduleScript = script.Parent:FindFirstChild(moduleName)
	if not moduleScript then
		error(("[NpcAI] Missing module %s"):format(moduleName))
	end

	local ok, moduleOrError = pcall(function()
		return require(moduleScript)
	end)

	if not ok then
		error(("[NpcAI] Failed to load %s: %s"):format(moduleName, tostring(moduleOrError)))
	end

	return moduleOrError
end

local function getNpcAnimationController()
	if not cachedNpcAnimationController then
		cachedNpcAnimationController = requireChildModule("NpcAnimationController")
	end

	return cachedNpcAnimationController
end

local function getParkourPlanner()
	if not cachedParkourPlanner then
		cachedParkourPlanner = requireChildModule("ParkourPlanner")
	end

	return cachedParkourPlanner
end

local function getFlankPlanner()
	if not cachedFlankPlanner then
		cachedFlankPlanner = requireChildModule("FlankPlanner")
	end

	return cachedFlankPlanner
end

local function getTacticalPlanner()
	if not cachedTacticalPlanner then
		cachedTacticalPlanner = requireChildModule("TacticalPlanner")
	end

	return cachedTacticalPlanner
end

local function getUtilityScorer()
	if not cachedUtilityScorer then
		cachedUtilityScorer = requireChildModule("UtilityScorer")
	end

	return cachedUtilityScorer
end

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart")
end

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function safeUnit(vector, fallback)
	if vector.Magnitude > 0.05 then
		return vector.Unit
	end

	return fallback
end

local function hashName(name)
	local total = 0
	for index = 1, #name do
		total = total + string.byte(name, index) * index
	end

	return total
end

local function getStableNameByte(name)
	local token = string.match(name or "", "([%w])$")
	if not token then
		return nil
	end

	return string.byte(string.upper(token))
end

local function derivePreferredSide(model, root)
	local stableByte = getStableNameByte(model.Name)
	if stableByte then
		return stableByte % 2 == 0 and "Right" or "Left"
	end

	return root.Position.X < 0 and "Right" or "Left"
end

local function getSurfaceTopY(result)
	if result.Instance and result.Instance:IsA("BasePart") then
		return result.Instance.Position.Y + result.Instance.Size.Y * 0.5
	end

	return result.Position.Y
end

local function round2(value)
	return math.floor(value * 100 + 0.5) / 100
end

local function angleBetween(left, right)
	local horizontalLeft = horizontal(left)
	local horizontalRight = horizontal(right)
	if horizontalLeft.Magnitude <= 0.05 or horizontalRight.Magnitude <= 0.05 then
		return 0
	end

	return math.deg(math.acos(math.clamp(horizontalLeft.Unit:Dot(horizontalRight.Unit), -1, 1)))
end

local SOUND_CUE_NAMES = {
	"Aggro",
	"LostTarget",
	"Flank",
	"Kill",
	"Return",
}

local function modeHasToken(mode, token)
	return string.find(mode or "", token, 1, true) ~= nil
end

local function isDetourMode(mode)
	return modeHasToken(mode, "Flank")
		or modeHasToken(mode, "Wide")
		or modeHasToken(mode, "Backdoor")
		or modeHasToken(mode, "Pinch")
		or modeHasToken(mode, "Cutoff")
		or mode == "InterceptLead"
end

function NpcController.new(model, config, threatService, pathPlanner, coordinator)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = getRoot(model)
	assert(humanoid and root, "NPC model requires Humanoid and HumanoidRootPart")

	local AnimationController = getNpcAnimationController()

	local self = setmetatable({}, NpcController)
	self.Model = model
	self.Humanoid = humanoid
	self.Root = root
	self.Config = config
	self.ThreatService = threatService
	self.PathPlanner = pathPlanner
	self.Coordinator = coordinator
	self.AnimationController = AnimationController.new(model, humanoid)
	self.State = "Patrol"
	self.SpawnPosition = root.Position
	self.SpawnCFrame = model:GetPivot()
	self.CurrentTarget = nil
	self.ActivePath = nil
	self.CurrentWaypoints = nil
	self.CurrentWaypointIndex = 1
	self.PathBlockedConnection = nil
	self.DirectMoveTarget = nil
	self.LastPlannedDestination = nil
	self.LastPlanClock = 0
	self.LastAttackClock = 0
	self.LastPathError = nil
	self.LastWaypointDistance = math.huge
	self.LastProgressClock = os.clock()
	self.RoutePlan = nil
	self.RouteMode = "Idle"
	self.JumpStateUntil = 0
	self.LastAssistJumpClock = 0
	self.TargetHoldUntil = 0
	self.LastParkourPlanClock = 0
	self.ParkourPlan = nil
	self.ParkourStepIndex = 1
	self.ParkourTarget = nil
	self.ParkourUntil = 0
	self.ParkourJumpProfile = nil
	self.ParkourJumpStartedAt = 0
	self.ParkourLandingInstance = nil
	self.ParkourLandingSurfaceY = nil
	self.LastParkourFailureClock = 0
	self.ParkourFailureCount = 0
	self.ParkourRetryDestination = nil
	self.ParkourSearchDestination = nil
	self.ParkourSearchTargetSnapshot = nil
	self.ParkourSearchOriginSnapshot = nil
	self.LastParkourSearchClock = 0
	self.KillResetPending = false
	self.KillResetCooldown = 0
	self.KillResetStartClock = 0
	self.LastMoveToPosition = nil
	self.LastMoveToClock = 0
	self.PreferredSide = derivePreferredSide(model, root)
	self.FlankHypothesis = nil
	self.FlankLikelihoodPercent = nil
	self.FlankInterceptMargin = nil
	self.FlankPriorityScore = nil
	self.FlankNpcTravelDistance = nil
	self.FlankTargetTravelDistance = nil
	self.LastCueClockByName = {}
	self.AudioFolder = nil
	self.LastSeenTargetPosition = nil
	self.LastSeenTargetDirection = nil
	self.LastSeenClock = 0
	self.LastKnownTargetPosition = nil
	self.LastKnownTargetClock = 0
	self.ForcePressureUntil = 0
	self.NavigationFailureCount = 0
	self.LastNavigationFailureClock = 0
	self.StuckLowProgressSamples = 0
	self.LastStuckSamplePosition = root.Position
	self.LastStuckSampleLook = horizontal(root.CFrame.LookVector)
	self.LastStuckSampleClock = os.clock()
	self.DebugOverlayRoot = nil
	self.Model:SetAttribute("PreferredSide", self.PreferredSide)
	self.Model:SetAttribute("ParkourPreferredSide", nil)
	self.Model:SetAttribute("EngagementRole", "Unassigned")
	self.AudioFolder = self:_ensureAudioFolder()

	return self
end

function NpcController:_publishState()
	if self.Config.EnableStrategicFlanking == false then
		self:_clearFlankDebug()
	end

	self.Model:SetAttribute("AiState", self.State)
	self.Model:SetAttribute("RouteMode", self.RouteMode)
	self.Model:SetAttribute("LastPathError", self.LastPathError or "")
	self.Model:SetAttribute("PreferredSide", self.PreferredSide)
	self.Model:SetAttribute("ParkourFailureCount", self.ParkourFailureCount or 0)

	local currentStep = self:_getParkourStep()
	self.Model:SetAttribute("ParkourHasPlan", self.ParkourPlan ~= nil)
	self.Model:SetAttribute("ParkourStepIndex", currentStep and self.ParkourStepIndex or 0)
	self.Model:SetAttribute("ParkourStepAction", currentStep and currentStep.Action or "")
	self.Model:SetAttribute("ParkourLaunchY", currentStep and round2(currentStep.LaunchPosition.Y) or nil)
	self.Model:SetAttribute("ParkourDestinationY", currentStep and round2(currentStep.Destination.Y) or nil)
	self.Model:SetAttribute("ParkourSearchY", self.ParkourSearchDestination and round2(self.ParkourSearchDestination.Y) or nil)
	self.Model:SetAttribute("ParkourRetryY", self.ParkourRetryDestination and round2(self.ParkourRetryDestination.Y) or nil)
	self.Model:SetAttribute("ParkourTargetY", self.ParkourTarget and round2(self.ParkourTarget.Y) or nil)
	self.Model:SetAttribute("FlankHypothesis", self.FlankHypothesis or "")
	self.Model:SetAttribute("FlankLikelihoodPercent", self.FlankLikelihoodPercent or nil)
	self.Model:SetAttribute("FlankInterceptMargin", self.FlankInterceptMargin and round2(self.FlankInterceptMargin) or nil)
	self.Model:SetAttribute("FlankPriorityScore", self.FlankPriorityScore and round2(self.FlankPriorityScore) or nil)
	self.Model:SetAttribute("FlankNpcTravel", self.FlankNpcTravelDistance and round2(self.FlankNpcTravelDistance) or nil)
	self.Model:SetAttribute("FlankTargetTravel", self.FlankTargetTravelDistance and round2(self.FlankTargetTravelDistance) or nil)
	self.Model:SetAttribute("SearchMemoryAge", self.LastSeenClock > 0 and round2(os.clock() - self.LastSeenClock) or nil)
	self.Model:SetAttribute("ForcePressure", os.clock() < (self.ForcePressureUntil or 0))
	self.Model:SetAttribute("NavigationFailureCount", self.NavigationFailureCount or 0)

	local targetCharacter = self.CurrentTarget and self.CurrentTarget.Character
	self.Model:SetAttribute("TargetGrounded", targetCharacter and self:_isCharacterGrounded(targetCharacter) or nil)

	local billboard = self.Model:FindFirstChild("StateBillboard")
	local label = billboard and billboard:FindFirstChildOfClass("TextLabel")
	if label then
		local role = self.Model:GetAttribute("EngagementRole") or "Unassigned"
		label.Text = ("%s\n%s | %s\n%s"):format(self.Model.Name, self.State, self.RouteMode, role)
	end

	self:_updateDebugOverlay()
end

function NpcController:_clearFlankDebug()
	self.FlankHypothesis = nil
	self.FlankLikelihoodPercent = nil
	self.FlankInterceptMargin = nil
	self.FlankPriorityScore = nil
	self.FlankNpcTravelDistance = nil
	self.FlankTargetTravelDistance = nil
end

function NpcController:_ensureDebugOverlay()
	if self.Config.EnableDebugOverlay == false then
		return nil
	end

	if self.DebugOverlayRoot and self.DebugOverlayRoot.Parent then
		return self.DebugOverlayRoot
	end

	local overlayContainer = Workspace:FindFirstChild("NpcDebugOverlay")
	if not overlayContainer then
		overlayContainer = Instance.new("Folder")
		overlayContainer.Name = "NpcDebugOverlay"
		overlayContainer.Parent = Workspace
	end

	local overlayRoot = overlayContainer:FindFirstChild(self.Model.Name)
	if not overlayRoot then
		overlayRoot = Instance.new("Folder")
		overlayRoot.Name = self.Model.Name
		overlayRoot.Parent = overlayContainer
	end

	local function ensureMarker(name, color, size)
		local marker = overlayRoot:FindFirstChild(name)
		if not marker then
			marker = Instance.new("Part")
			marker.Name = name
			marker.Anchored = true
			marker.CanCollide = false
			marker.CanTouch = false
			marker.CanQuery = false
			marker.CastShadow = false
			marker.Material = Enum.Material.Neon
			marker.Shape = Enum.PartType.Ball
			marker.Size = Vector3.new(size, size, size)
			marker.Transparency = 1
			marker.Color = color
			marker.Parent = overlayRoot
		end

		return marker
	end

	local function ensureSegment(name, color)
		local segment = overlayRoot:FindFirstChild(name)
		if not segment then
			segment = Instance.new("Part")
			segment.Name = name
			segment.Anchored = true
			segment.CanCollide = false
			segment.CanTouch = false
			segment.CanQuery = false
			segment.CastShadow = false
			segment.Material = Enum.Material.Neon
			segment.Size = Vector3.new(0.12, 0.12, 0.12)
			segment.Transparency = 1
			segment.Color = color
			segment.Parent = overlayRoot
		end

		return segment
	end

	ensureMarker("InterceptMarker", Color3.fromRGB(255, 170, 75), 0.6)
	ensureMarker("TargetMarker", Color3.fromRGB(110, 185, 255), 0.45)
	for index = 1, 6 do
		ensureMarker(("PathPoint%d"):format(index), Color3.fromRGB(72, 225, 255), 0.35)
	end
	for index = 1, 6 do
		ensureSegment(("PathSegment%d"):format(index), Color3.fromRGB(72, 225, 255))
	end

	self.DebugOverlayRoot = overlayRoot
	return overlayRoot
end

function NpcController:_setDebugMarker(marker, position, color)
	if not marker then
		return
	end

	if not position then
		marker.Transparency = 1
		return
	end

	marker.Position = position
	marker.Color = color or marker.Color
	marker.Transparency = 0.2
end

function NpcController:_setDebugSegment(segment, fromPosition, toPosition, color)
	if not segment then
		return
	end

	if not fromPosition or not toPosition then
		segment.Transparency = 1
		return
	end

	local delta = toPosition - fromPosition
	local distance = delta.Magnitude
	if distance <= 0.05 then
		segment.Transparency = 1
		return
	end

	segment.Size = Vector3.new(0.1, 0.1, distance)
	segment.CFrame = CFrame.lookAt((fromPosition + toPosition) * 0.5, toPosition)
	segment.Color = color or segment.Color
	segment.Transparency = 0.32
end

function NpcController:_getDebugPathPoints()
	local points = {}
	local maxPoints = 6
	if self.CurrentWaypoints then
		for index = self.CurrentWaypointIndex, math.min(#self.CurrentWaypoints, self.CurrentWaypointIndex + maxPoints - 1) do
			table.insert(points, self.CurrentWaypoints[index].Position + Vector3.new(0, 0.2, 0))
		end
	elseif self.DirectMoveTarget then
		table.insert(points, self.DirectMoveTarget + Vector3.new(0, 0.2, 0))
	elseif self.RoutePlan and self.RoutePlan.Destination then
		table.insert(points, self.RoutePlan.Destination + Vector3.new(0, 0.2, 0))
	end

	return points
end

function NpcController:_updateDebugOverlay()
	local overlayRoot = self:_ensureDebugOverlay()
	if not overlayRoot then
		return
	end

	local pathPoints = self:_getDebugPathPoints()
	local previousPoint = self.Root.Position + Vector3.new(0, 1.2, 0)
	for index = 1, 6 do
		local marker = overlayRoot:FindFirstChild(("PathPoint%d"):format(index))
		local segment = overlayRoot:FindFirstChild(("PathSegment%d"):format(index))
		local point = pathPoints[index]
		self:_setDebugMarker(marker, point, Color3.fromRGB(72, 225, 255))
		self:_setDebugSegment(segment, point and previousPoint or nil, point, Color3.fromRGB(72, 225, 255))
		if point then
			previousPoint = point
		end
	end

	local interceptMarker = overlayRoot:FindFirstChild("InterceptMarker")
	local interceptDestination = self.RoutePlan and isDetourMode(self.RoutePlan.Mode) and self.RoutePlan.Destination or nil
	self:_setDebugMarker(interceptMarker, interceptDestination and (interceptDestination + Vector3.new(0, 0.3, 0)) or nil, Color3.fromRGB(255, 170, 75))

	local targetMarker = overlayRoot:FindFirstChild("TargetMarker")
	local targetPosition = self.LastKnownTargetPosition or (self.CurrentTarget and self.CurrentTarget.Character and self:_getTargetNavigationPosition(self.CurrentTarget.Character, self.CurrentTarget.Character:FindFirstChild("HumanoidRootPart")))
	self:_setDebugMarker(targetMarker, targetPosition and (targetPosition + Vector3.new(0, 0.2, 0)) or nil, Color3.fromRGB(110, 185, 255))
end

function NpcController:_updateTargetMemory(targetCharacter, targetRoot, hasLineOfSight)
	if not targetRoot then
		return
	end

	local now = os.clock()
	local targetPosition = self:_getTargetNavigationPosition(targetCharacter, targetRoot) or targetRoot.Position
	local velocity = horizontal(targetRoot.AssemblyLinearVelocity)
	local look = horizontal(targetRoot.CFrame.LookVector)
	local direction = velocity.Magnitude > 1.2 and velocity.Unit or safeUnit(look, self.LastSeenTargetDirection or Vector3.new(0, 0, -1))

	if hasLineOfSight then
		self.LastSeenTargetPosition = targetPosition
		self.LastSeenTargetDirection = direction
		self.LastSeenClock = now
		self.LastKnownTargetPosition = targetPosition
		self.LastKnownTargetClock = now
		return
	end

	local rememberedPosition = self.LastSeenTargetPosition or targetPosition
	local rememberedDirection = self.LastSeenTargetDirection or direction
	local searchAnchor = targetPosition
	if now - self.LastSeenClock <= (self.Config.SearchMemorySeconds or self.Config.TargetMemorySeconds) then
		local leadDistance = math.min(
			self.Config.SearchMemoryLeadDistance or 18,
			math.max(5, velocity.Magnitude * 0.45 + 6)
		)
		searchAnchor = rememberedPosition + rememberedDirection * leadDistance
		searchAnchor = Vector3.new(searchAnchor.X, targetPosition.Y, searchAnchor.Z)
	end

	self.LastKnownTargetPosition = searchAnchor
	self.LastKnownTargetClock = now
end

function NpcController:_getSearchAnchorPosition(targetRoot)
	if not targetRoot then
		return nil
	end

	if self.LastKnownTargetPosition
		and os.clock() - (self.LastKnownTargetClock or 0) <= (self.Config.SearchMemorySeconds or self.Config.TargetMemorySeconds)
	then
		return self.LastKnownTargetPosition
	end

	return targetRoot.Position
end

function NpcController:_registerNavigationFailure(reason)
	local now = os.clock()
	if now - (self.LastNavigationFailureClock or 0) > 2.2 then
		self.NavigationFailureCount = 0
	end

	self.LastNavigationFailureClock = now
	self.NavigationFailureCount = math.min((self.NavigationFailureCount or 0) + 1, 6)
	self.LastPathError = reason or self.LastPathError or "Navigation failure"

	if reason == "Stuck recovery" then
		self.RoutePlan = nil
		self.LastPlannedDestination = nil
		self.LastPlanClock = 0
		self:_clearNavigation()
	end

	if self.NavigationFailureCount >= (self.Config.StuckFailureThreshold or 2) then
		self:_forcePressureRecovery(reason or "Pressure recovery")
	end
end

function NpcController:_forcePressureRecovery(reason)
	self.RoutePlan = nil
	self.LastPlannedDestination = nil
	self.LastPlanClock = 0
	self.ForcePressureUntil = os.clock() + (self.Config.StuckPressureSeconds or 1.8)
	self.StuckLowProgressSamples = 0
	self:_clearFlankDebug()
	self:_clearNavigation()
	if self.Coordinator then
		self.Coordinator:ClearFlankReservation(self.Model)
	end
	self.Model:SetAttribute("EngagementRole", "Pressure")
	self.LastPathError = reason or "Pressure recovery"
end

function NpcController:_updateStuckRecovery()
	if self.State ~= "Chase" or self:_isParkourActive() or self.ParkourPlan then
		self.StuckLowProgressSamples = 0
		self.LastStuckSamplePosition = self.Root.Position
		self.LastStuckSampleLook = horizontal(self.Root.CFrame.LookVector)
		self.LastStuckSampleClock = os.clock()
		return
	end

	local hasNavigationIntent = self.ActivePath or self.DirectMoveTarget or (self.RoutePlan and isDetourMode(self.RoutePlan.Mode))
	if not hasNavigationIntent then
		self.StuckLowProgressSamples = 0
		return
	end

	local now = os.clock()
	if now - self.LastStuckSampleClock < (self.Config.StuckSampleInterval or 0.45) then
		return
	end

	local progress = horizontal(self.Root.Position - self.LastStuckSamplePosition).Magnitude
	local currentLook = horizontal(self.Root.CFrame.LookVector)
	local spinAngle = angleBetween(self.LastStuckSampleLook, currentLook)
	self.LastStuckSamplePosition = self.Root.Position
	self.LastStuckSampleLook = currentLook
	self.LastStuckSampleClock = now

	if progress < (self.Config.StuckMinProgress or 0.55) then
		self.StuckLowProgressSamples = self.StuckLowProgressSamples + 1
	else
		self.StuckLowProgressSamples = 0
	end

	if self.StuckLowProgressSamples >= 2 or (progress < 0.25 and spinAngle >= (self.Config.SpinRecoverAngle or 45)) then
		self:_registerNavigationFailure("Stuck recovery")
	end
end

function NpcController:_resolveStrategicFlankRoute(targetCharacter, targetRoot, searchAnchorPosition, hasLineOfSight, targetDistance)
	if os.clock() < (self.ForcePressureUntil or 0) then
		self:_clearFlankDebug()
		return nil
	end

	if targetDistance <= self.Config.FlankMinimumDistance or not targetRoot then
		self:_clearFlankDebug()
		return nil
	end

	local FlankPlanner = getFlankPlanner()
	local flankRoute = FlankPlanner.FindBestRoute(
		self.Root.Position,
		targetRoot,
		targetCharacter,
		self.Model,
		self.Config,
		self.PathPlanner,
		{
			PreferredSide = self.PreferredSide,
			SearchAnchorPosition = searchAnchorPosition,
			HasLineOfSight = hasLineOfSight,
			LastSeenDirection = self.LastSeenTargetDirection,
			TargetMotionDirection = self.LastSeenTargetDirection,
		}
	)

	if not flankRoute then
		self:_clearFlankDebug()
		return nil
	end

	self.FlankHypothesis = flankRoute.Hypothesis
	self.FlankLikelihoodPercent = flankRoute.LikelihoodPercent
	self.FlankInterceptMargin = flankRoute.InterceptMargin
	self.FlankPriorityScore = flankRoute.PriorityScore
	self.FlankNpcTravelDistance = flankRoute.NpcTravelDistance
	self.FlankTargetTravelDistance = flankRoute.TargetTravelDistance
	return flankRoute
end

function NpcController:_ensureAudioFolder()
	local folder = self.Model:FindFirstChild("NpcAudio")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "NpcAudio"
		folder.Parent = self.Model
	end

	for _, soundName in ipairs(SOUND_CUE_NAMES) do
		local sound = folder:FindFirstChild(soundName)
		if not sound then
			sound = Instance.new("Sound")
			sound.Name = soundName
			sound.RollOffMaxDistance = 60
			sound.Volume = 0.55
			sound.Parent = folder
		end
	end

	return folder
end

function NpcController:_playCue(cueName, cooldownSeconds)
	self.AudioFolder = self.AudioFolder or self:_ensureAudioFolder()
	local sound = self.AudioFolder and self.AudioFolder:FindFirstChild(cueName)
	local now = os.clock()
	local lastPlayedAt = self.LastCueClockByName[cueName] or 0
	if cooldownSeconds and now - lastPlayedAt < cooldownSeconds then
		return
	end

	self.LastCueClockByName[cueName] = now
	self.Model:SetAttribute("LastSoundCue", cueName)

	if sound and sound:IsA("Sound") and sound.SoundId ~= "" then
		pcall(function()
			sound:Play()
		end)
	end
end

function NpcController:_clearParkourPlan()
	self.ParkourPlan = nil
	self.ParkourStepIndex = 1
end

function NpcController:_clearParkourSearchState()
	self.ParkourSearchDestination = nil
	self.ParkourSearchTargetSnapshot = nil
	self.ParkourSearchOriginSnapshot = nil
	self.LastParkourSearchClock = 0
end

function NpcController:_clearParkourJumpState()
	self.ParkourTarget = nil
	self.ParkourUntil = 0
	self.ParkourJumpProfile = nil
	self.ParkourJumpStartedAt = 0
	self.ParkourLandingInstance = nil
	self.ParkourLandingSurfaceY = nil
end

function NpcController:_captureParkourRetryDestination()
	if not self.ParkourPlan or not self.ParkourPlan.Steps then
		return nil
	end

	for _, step in ipairs(self.ParkourPlan.Steps) do
		local retryDestination = step.Action == "Hop" and step.LaunchPosition or step.Destination
		if retryDestination then
			return self:_clampToLeash(retryDestination)
		end
	end

	return nil
end

function NpcController:_markParkourFailure(reason)
	self.LastParkourFailureClock = os.clock()
	self.ParkourFailureCount = math.min((self.ParkourFailureCount or 0) + 1, 6)
	self.ParkourRetryDestination = self:_captureParkourRetryDestination()
	self.LastPathError = reason or "Parkour failure"
	self:_clearParkourJumpState()
	self:_clearParkourSearchState()
	self.LastParkourPlanClock = 0
	self:_clearNavigation()
	self:_clearParkourPlan()
end

function NpcController:_issueMoveTo(destination, force)
	local now = os.clock()
	if not force and self.LastMoveToPosition then
		local delta = (destination - self.LastMoveToPosition).Magnitude
		if delta <= 0.85 and now - self.LastMoveToClock <= 0.22 then
			return
		end
	end

	self.LastMoveToPosition = destination
	self.LastMoveToClock = now
	self.Humanoid:MoveTo(destination)
end

function NpcController:_getParkourStep()
	if not self.ParkourPlan or not self.ParkourPlan.Steps then
		return nil
	end

	return self.ParkourPlan.Steps[self.ParkourStepIndex]
end

function NpcController:_advanceParkourPlan()
	local step = self:_getParkourStep()
	while step do
		local reachedStep = self:_isOnParkourStep(step)

		if not reachedStep then
			break
		end

		self.ParkourStepIndex = self.ParkourStepIndex + 1
		step = self:_getParkourStep()
	end

	if not step then
		self:_clearParkourPlan()
		return false
	end

	return true
end

function NpcController:_setStateWalkSpeed(stateName)
	if stateName == "Chase" then
		self.Humanoid.WalkSpeed = self.Config.ChaseWalkSpeed
	elseif stateName == "Recover" or stateName == "Return" then
		self.Humanoid.WalkSpeed = self.Config.ReturnWalkSpeed
	else
		self.Humanoid.WalkSpeed = self.Config.PatrolWalkSpeed
	end
end

function NpcController:_forceRespawnToSpawn(holdSeconds)
	self.KillResetPending = false
	self.KillResetCooldown = 0
	self.KillResetStartClock = 0
	self.TargetHoldUntil = 0
	self.RoutePlan = nil
	self.LastPlannedDestination = nil
	self.LastPathError = ""
	self:_clearNavigation()
	self:_clearParkourPlan()
	self:_clearParkourSearchState()
	self.ParkourRetryDestination = nil

	self.Model:PivotTo(self.SpawnCFrame)
	self.Root = getRoot(self.Model) or self.Root

	for _, descendant in ipairs(self.Model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end

	pcall(function()
		self.Root:SetNetworkOwner(nil)
	end)

	self.State = "Recover"
	self.RouteMode = "SpawnHold"
	self:_playCue("Return", 1.4)
	self.Model:SetAttribute("NpcAggroHoldUntil", os.clock() + holdSeconds)
	self.Model:SetAttribute("NpcKillResetPending", false)
	self:_issueMoveTo(self.SpawnPosition, true)
end

function NpcController:_getContext()
	local targetCharacter = self.CurrentTarget and self.CurrentTarget.Character
	local targetRoot = nil
	local targetDistance = math.huge

	if targetCharacter then
		targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	end

	if targetRoot then
		targetDistance = (targetRoot.Position - self.Root.Position).Magnitude
	end

	local leashDistance = (self.Root.Position - self.SpawnPosition).Magnitude

	return {
		TargetPlayer = self.CurrentTarget,
		TargetDistance = targetDistance,
		LeashDistance = leashDistance,
		MaxLeashDistance = self.Config.MaxLeashDistance,
		HealthRatio = self.Humanoid.Health / math.max(self.Humanoid.MaxHealth, 1),
	}
end

function NpcController:_getAggroHoldUntil()
	local holdUntil = self.Model:GetAttribute("NpcAggroHoldUntil")
	if type(holdUntil) == "number" then
		return holdUntil
	end

	return 0
end

function NpcController:_refreshThreat()
	if os.clock() < self:_getAggroHoldUntil() then
		self.CurrentTarget = nil
		self.RoutePlan = nil
		self.LastPlannedDestination = nil
		self:_clearParkourPlan()
		self:_clearParkourSearchState()
		self.ParkourRetryDestination = nil
		if self.Coordinator then
			self.Coordinator:ClearFlankReservation(self.Model)
		end
		return
	end

	local previousTarget = self.CurrentTarget

	self.ThreatService:SeedFromNearbyPlayers(self.Model, self.Root.Position, self.Config.AggroRadius)
	local nextTarget = self.ThreatService:GetBestTarget(self.Model, self.Root.Position, self.Config.AggroRadius)

	if nextTarget then
		self.CurrentTarget = nextTarget
		self.TargetHoldUntil = os.clock() + self.Config.TargetMemorySeconds
	elseif previousTarget and os.clock() < self.TargetHoldUntil then
		local character = previousTarget.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 and (root.Position - self.Root.Position).Magnitude <= self.Config.AggroRadius * 1.35 then
			self.CurrentTarget = previousTarget
		else
			self.CurrentTarget = nil
		end
	else
		self.CurrentTarget = nil
	end

	if previousTarget ~= self.CurrentTarget then
		if self.CurrentTarget and not previousTarget then
			self:_playCue("Aggro", 1.2)
		elseif previousTarget and not self.CurrentTarget then
			self:_playCue("LostTarget", 1.2)
			self.Model:SetAttribute("EngagementRole", "Unassigned")
		end

		self.RoutePlan = nil
		self.LastPlannedDestination = nil
		self:_clearParkourPlan()
		self:_clearParkourSearchState()
		self.ParkourFailureCount = 0
		self.ParkourRetryDestination = nil
		if not self.CurrentTarget and self.Coordinator then
			self.Coordinator:ClearFlankReservation(self.Model)
		end
	end
end

function NpcController:_disconnectPathBlocked()
	if self.PathBlockedConnection then
		self.PathBlockedConnection:Disconnect()
		self.PathBlockedConnection = nil
	end
end

function NpcController:_clearNavigation(clearDirectMove)
	self:_disconnectPathBlocked()

	if self.ActivePath then
		pcall(function()
			self.ActivePath:Destroy()
		end)
	end

	self.ActivePath = nil
	self.CurrentWaypoints = nil
	self.CurrentWaypointIndex = 1
	self.LastWaypointDistance = math.huge
	self.LastProgressClock = os.clock()
	self:_clearParkourJumpState()

	if clearDirectMove ~= false then
		self.DirectMoveTarget = nil
	end
end

function NpcController:_suspendNavigationForParkour()
	self:_disconnectPathBlocked()

	if self.ActivePath then
		pcall(function()
			self.ActivePath:Destroy()
		end)
	end

	self.ActivePath = nil
	self.CurrentWaypoints = nil
	self.CurrentWaypointIndex = 1
	self.DirectMoveTarget = nil
	self.LastWaypointDistance = math.huge
	self.LastProgressClock = os.clock()
	self.LastMoveToPosition = nil
	self.LastMoveToClock = 0
	pcall(function()
		self.Humanoid:Move(Vector3.zero, false)
	end)
end

function NpcController:_isParkourActive()
	return self.ParkourTarget ~= nil
end

function NpcController:_setDirectMoveTarget(destination)
	if not self.ActivePath and self.DirectMoveTarget and horizontal(destination - self.DirectMoveTarget).Magnitude <= 1 then
		self.DirectMoveTarget = destination
		return
	end

	if self.ActivePath then
		self:_disconnectPathBlocked()
		pcall(function()
			self.ActivePath:Destroy()
		end)
	end

	self.ActivePath = nil
	self.CurrentWaypoints = nil
	self.CurrentWaypointIndex = 1
	self.DirectMoveTarget = destination
	self.LastWaypointDistance = (destination - self.Root.Position).Magnitude
	self.LastProgressClock = os.clock()
end

function NpcController:_canDirectApproach(destination, targetCharacter, directDistance)
	directDistance = directDistance or self.Config.ParkourDirectApproachDistance or 5.5
	local delta = destination - self.Root.Position
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance > directDistance then
		return false
	end

	if math.abs(delta.Y) > self.Config.ParkourGoalHeightTolerance then
		return false
	end

	return self:_hasLineOfSight(destination, targetCharacter)
end

function NpcController:_canBlindParkourDirectApproach(destination, directDistance)
	directDistance = directDistance or self.Config.ParkourSearchBlindDirectDistance or 12
	local delta = destination - self.Root.Position
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance > directDistance then
		return false
	end

	if delta.Y > (self.Config.MaxJumpRise + 1.5) then
		return false
	end

	if delta.Y < -(self.Config.ParkourHopDrop or self.Config.ParkourWalkDrop or 4) - 1 then
		return false
	end

	return true
end

function NpcController:_navigateToward(destination, targetCharacter, options)
	options = options or {}
	destination = self:_clampToLeash(destination)

	local preferDirect = options.PreferDirect ~= false
	local allowBlindParkourDirect = options.AllowBlindParkourDirect == true
	local clearNavigation = options.ClearNavigation == true
	local replanThreshold = options.ReplanThreshold or self.Config.PathDestinationChangeThreshold
	local replanInterval = options.ReplanInterval or self.Config.PathReplanInterval

	if clearNavigation then
		self:_clearNavigation()
	end

	if preferDirect and (
		self:_canDirectApproach(destination, targetCharacter, options.DirectDistance)
		or (allowBlindParkourDirect and self:_canBlindParkourDirectApproach(destination, options.BlindDirectDistance))
	) then
		if self.ActivePath or not self.DirectMoveTarget or horizontal(destination - self.DirectMoveTarget).Magnitude > 0.45 then
			self:_clearNavigation()
			self:_setDirectMoveTarget(destination)
		end
	else
		if self:_needsReplan(destination, replanThreshold) and os.clock() - self.LastPlanClock >= replanInterval then
			self.LastPlanClock = os.clock()
			self:_replan(destination, targetCharacter)
		elseif not self.ActivePath and not self.DirectMoveTarget and not self:_isParkourActive() then
			self.LastPlanClock = 0
			self:_replan(destination, targetCharacter)
		end
	end

	self:_followNavigation(targetCharacter, options.DisableAssistJump == true)
end

function NpcController:_getPressureDestination(targetReference)
	local targetPosition = typeof(targetReference) == "Vector3" and targetReference or targetReference.Position
	local toTarget = horizontal(targetPosition - self.Root.Position)
	if toTarget.Magnitude <= 0.1 then
		return targetPosition
	end

	local standOff = math.min(
		self.Config.AttackApproachStandOff or math.max(1.8, self.Config.AttackRange * 0.5),
		math.max(1.2, toTarget.Magnitude - 0.4)
	)

	return Vector3.new(
		targetPosition.X - toTarget.Unit.X * standOff,
		targetPosition.Y,
		targetPosition.Z - toTarget.Unit.Z * standOff
	)
end

function NpcController:_getElevationSearchDestination(targetCharacter, targetRoot)
	local now = os.clock()
	local planningTargetPosition = self:_getTargetNavigationPosition(targetCharacter, targetRoot) or targetRoot.Position
	local searchTargetPosition = planningTargetPosition
	local searchEntryMaxRise = self.Config.ParkourSearchEntryMaxRise or math.min(self.Config.MaxJumpRise, 5.5)
	local maxSearchY = self.Root.Position.Y + searchEntryMaxRise
	if searchTargetPosition.Y > maxSearchY then
		searchTargetPosition = Vector3.new(searchTargetPosition.X, maxSearchY, searchTargetPosition.Z)
	end
	local cachedDestination = self.ParkourSearchDestination
	local targetSnapshot = self.ParkourSearchTargetSnapshot
	local originSnapshot = self.ParkourSearchOriginSnapshot
	if cachedDestination and targetSnapshot and originSnapshot then
		local targetDrift = horizontal(searchTargetPosition - targetSnapshot).Magnitude
		local originDrift = horizontal(self.Root.Position - originSnapshot).Magnitude
		if targetDrift <= self.Config.ParkourPathReplanDistance
			and originDrift <= (self.Config.ParkourSearchOriginStickDistance or 6)
			and now - self.LastParkourSearchClock < (self.Config.ParkourSearchReplanInterval or self.Config.PathReplanInterval)
		then
			return cachedDestination
		end
	end

	local ParkourPlanner = getParkourPlanner()
	local searchDestination = ParkourPlanner.FindSearchAnchor(
		self.Root.Position,
		searchTargetPosition,
		targetCharacter,
		self.Model,
		self.Config
	)
	if searchDestination then
		self.ParkourSearchDestination = self:_clampToLeash(searchDestination)
		self.ParkourSearchTargetSnapshot = searchTargetPosition
		self.ParkourSearchOriginSnapshot = self.Root.Position
		self.LastParkourSearchClock = now
		return self.ParkourSearchDestination
	end

	local TacticalPlanner = getTacticalPlanner()
	local searchRoute = TacticalPlanner.BuildRoute(self.Root.Position, {
		Position = searchTargetPosition,
		AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity,
	}, self.Config, {
		HasLineOfSight = false,
		PreviousMode = self.RouteMode,
		PreferredSide = self.PreferredSide,
		LastPathError = self.LastPathError,
	})
	if searchRoute and searchRoute.Destination then
		self.ParkourSearchDestination = self:_clampToLeash(searchRoute.Destination)
		self.ParkourSearchTargetSnapshot = searchTargetPosition
		self.ParkourSearchOriginSnapshot = self.Root.Position
		self.LastParkourSearchClock = now
		return self.ParkourSearchDestination
	end

	local toTarget = horizontal(searchTargetPosition - self.Root.Position)
	local right = toTarget.Magnitude > 0.1 and Vector3.new(-toTarget.Unit.Z, 0, toTarget.Unit.X) or Vector3.new(1, 0, 0)
	local sideSign = self.PreferredSide == "Left" and -1 or 1
	local lateralDistance = math.max(6, math.min(12, toTarget.Magnitude * 0.45))
	local fallback = searchTargetPosition + right * sideSign * lateralDistance
	searchDestination = Vector3.new(fallback.X, self.Root.Position.Y, fallback.Z)

	self.ParkourSearchDestination = self:_clampToLeash(searchDestination)
	self.ParkourSearchTargetSnapshot = searchTargetPosition
	self.ParkourSearchOriginSnapshot = self.Root.Position
	self.LastParkourSearchClock = now
	return self.ParkourSearchDestination
end

function NpcController:_computeParkourJumpProfile(landingTarget)
	local delta = landingTarget - self.Root.Position
	local horizontalDelta = horizontal(delta)
	local horizontalDistance = horizontalDelta.Magnitude
	if horizontalDistance < 0.35 then
		return nil
	end

	local nominalSpeed = math.clamp(
		self.Config.ParkourNominalHorizontalSpeed or ((self.Config.ParkourHorizontalSpeedMin + self.Config.ParkourHorizontalSpeedMax) * 0.5),
		self.Config.ParkourHorizontalSpeedMin,
		self.Config.ParkourHorizontalSpeedMax
	)
	local minFlightTime = self.Config.ParkourFlightTimeMin or 0.42
	local maxFlightTime = self.Config.ParkourFlightTimeMax or 0.9
	local bestProfile = nil
	local bestScore = math.huge

	for stepIndex = 0, 12 do
		local alpha = stepIndex / 12
		local flightTime = minFlightTime + (maxFlightTime - minFlightTime) * alpha
		local horizontalSpeed = horizontalDistance / flightTime
		local verticalSpeed = (delta.Y + 0.5 * Workspace.Gravity * flightTime * flightTime) / flightTime

		if horizontalSpeed >= self.Config.ParkourHorizontalSpeedMin
			and horizontalSpeed <= self.Config.ParkourHorizontalSpeedMax
			and verticalSpeed >= self.Config.ParkourVerticalSpeedMin
			and verticalSpeed <= self.Config.ParkourVerticalSpeedMax
		then
			local score = math.abs(horizontalSpeed - nominalSpeed) + math.abs(verticalSpeed - self.Config.ParkourVerticalSpeedMin) * 0.02
			if score < bestScore then
				bestScore = score
				bestProfile = {
					Direction = horizontalDelta.Unit,
					FlightTime = flightTime,
					HorizontalSpeed = horizontalSpeed,
					VerticalSpeed = verticalSpeed,
				}
			end
		end
	end

	return bestProfile
end

function NpcController:_startParkourJump(stepOrTarget, commitSeconds)
	local landingTarget = typeof(stepOrTarget) == "Vector3" and stepOrTarget or stepOrTarget.Destination
	if typeof(landingTarget) ~= "Vector3" then
		return false
	end

	local jumpProfile = self:_computeParkourJumpProfile(landingTarget)
	if not jumpProfile then
		return false
	end

	if not self:_triggerJump(0.75) then
		return false
	end

	self:_suspendNavigationForParkour()

	local now = os.clock()
	self.ParkourTarget = landingTarget
	self.ParkourJumpProfile = jumpProfile
	self.ParkourJumpStartedAt = now
	self.ParkourLandingInstance = typeof(stepOrTarget) == "table" and stepOrTarget.DestinationInstance or nil
	self.ParkourLandingSurfaceY = typeof(stepOrTarget) == "table" and stepOrTarget.DestinationSurfaceY or nil
	self.ParkourUntil = now + math.max(commitSeconds or self.Config.ParkourCommitSeconds, jumpProfile.FlightTime + 0.25)
	self.LastAssistJumpClock = now
	self.LastPathError = "Parkour jump"
	self.Root.AssemblyAngularVelocity = Vector3.zero
	self.Root.AssemblyLinearVelocity = jumpProfile.Direction * jumpProfile.HorizontalSpeed + Vector3.new(0, jumpProfile.VerticalSpeed, 0)
	return true
end

function NpcController:_updateParkour()
	if not self.ParkourTarget then
		return false
	end

	local remaining = horizontal(self.ParkourTarget - self.Root.Position).Magnitude
	local verticalDelta = math.abs(self.ParkourTarget.Y - self.Root.Position.Y)
	local grounded = self.Humanoid.FloorMaterial ~= Enum.Material.Air
	local now = os.clock()
	local elapsed = now - self.ParkourJumpStartedAt

	if grounded
		and elapsed >= 0.08
		and self:_isOnParkourSurface(
			self.ParkourTarget,
			self.Config.ParkourLandingTolerance,
			self.ParkourLandingInstance,
			self.ParkourLandingSurfaceY
		)
	then
		self:_clearParkourJumpState()
		self.ParkourFailureCount = 0
		return false
	end

	if grounded and elapsed >= 0.14 then
		local expectedFlight = self.ParkourJumpProfile and self.ParkourJumpProfile.FlightTime or 0
		if expectedFlight > 0 and elapsed >= math.max(0.3, expectedFlight * 0.55) then
			self:_markParkourFailure("Parkour landing missed")
			return false
		end
	end

	if now >= self.ParkourUntil then
		self:_markParkourFailure("Parkour landing missed")
		return false
	end

	if not grounded and self.ParkourJumpProfile then
		local currentVelocity = self.Root.AssemblyLinearVelocity
		local desiredHorizontal = self.ParkourJumpProfile.Direction * self.ParkourJumpProfile.HorizontalSpeed
		local correctedVelocity = Vector3.new(desiredHorizontal.X, currentVelocity.Y, desiredHorizontal.Z)
		if elapsed <= (self.ParkourJumpProfile.FlightTime * 0.32) then
			local blend = self.Config.ParkourJumpAirControl or 0.02
			self.Root.AssemblyLinearVelocity = currentVelocity:Lerp(correctedVelocity, blend)
		end

		self.Root.AssemblyAngularVelocity = self.Root.AssemblyAngularVelocity:Lerp(Vector3.zero, 0.12)
	end

	return true
end

function NpcController:_clampToLeash(destination)
	local offset = horizontal(destination - self.SpawnPosition)
	if offset.Magnitude <= self.Config.MaxLeashDistance then
		return destination
	end

	local safeRadius = math.max(4, self.Config.MaxLeashDistance - 4)
	local clamped = offset.Unit * safeRadius
	return Vector3.new(self.SpawnPosition.X + clamped.X, destination.Y, self.SpawnPosition.Z + clamped.Z)
end

function NpcController:_createRaycastParams(extraIgnored)
	local ignored = {}
	for _, taggedNpc in ipairs(CollectionService:GetTagged("CombatNpc")) do
		table.insert(ignored, taggedNpc)
	end

	table.insert(ignored, self.Model)
	if extraIgnored then
		table.insert(ignored, extraIgnored)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	return params
end

function NpcController:_getCurrentGroundSupport()
	if self.Humanoid.FloorMaterial == Enum.Material.Air then
		return nil
	end

	local params = self:_createRaycastParams()
	local origin = self.Root.Position + Vector3.new(0, 1.5, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -8, 0), params)
	if not result or result.Normal.Y < 0.55 then
		return nil
	end

	return {
		Instance = result.Instance,
		TopY = getSurfaceTopY(result),
		Position = result.Position,
	}
end

function NpcController:_isOnParkourSurface(destination, precisionRadius, destinationInstance, destinationSurfaceY)
	local support = self:_getCurrentGroundSupport()
	if not support then
		return false
	end

	local horizontalDistance = horizontal(destination - support.Position).Magnitude
	if horizontalDistance > (precisionRadius or self.Config.ParkourStepReachDistance) then
		return false
	end

	if destinationInstance and support.Instance == destinationInstance then
		return true
	end

	if type(destinationSurfaceY) == "number" and math.abs(support.TopY - destinationSurfaceY) <= 0.45 then
		return true
	end

	return false
end

function NpcController:_isOnParkourStep(step)
	if not step then
		return false
	end

	return self:_isOnParkourSurface(
		step.Destination,
		step.PrecisionRadius,
		step.DestinationInstance,
		step.DestinationSurfaceY
	)
end

function NpcController:_hasLineOfSight(destination, targetCharacter)
	local direction = destination - self.Root.Position
	if direction.Magnitude <= 0.5 then
		return true
	end

	local params = self:_createRaycastParams()
	local result = Workspace:Raycast(self.Root.Position + Vector3.new(0, 1.5, 0), direction, params)
	if not result then
		return true
	end

	if targetCharacter and result.Instance:IsDescendantOf(targetCharacter) then
		return true
	end

	return false
end

function NpcController:_needsReplan(destination, distanceThreshold)
	if self:_isParkourActive() then
		return false
	end

	if not self.LastPlannedDestination then
		return true
	end

	if not self.ActivePath and not self.DirectMoveTarget then
		return true
	end

	local delta = horizontal(destination - self.LastPlannedDestination)
	return delta.Magnitude >= distanceThreshold
end

function NpcController:_resolveRoutePlan(targetCharacter, targetRoot)
	local strategicFlankingEnabled = self.Config.EnableStrategicFlanking ~= false
	local hasLineOfSight = self:_hasLineOfSight(targetRoot.Position, targetCharacter)
	self:_updateTargetMemory(targetCharacter, targetRoot, hasLineOfSight)
	local searchAnchorPosition = self:_getSearchAnchorPosition(targetRoot) or targetRoot.Position
	local targetDistance = (targetRoot.Position - self.Root.Position).Magnitude
	local needsNewRoute = self.RoutePlan == nil or os.clock() >= self.RoutePlan.ExpiresAt

	if not needsNewRoute and self.RoutePlan.TargetSnapshot then
		local comparisonSnapshot = isDetourMode(self.RoutePlan.Mode) and searchAnchorPosition or targetRoot.Position
		local routeDrift = horizontal(comparisonSnapshot - self.RoutePlan.TargetSnapshot).Magnitude
		if routeDrift >= self.Config.RouteRefreshDistance then
			needsNewRoute = true
		end
	end

	if not needsNewRoute and targetDistance <= self.Config.DirectEngageDistance and self.RoutePlan.Mode ~= "DirectPressure" then
		needsNewRoute = true
	end

	if needsNewRoute then
		local previousMode = self.RoutePlan and self.RoutePlan.Mode or ""
		local pressureDestination = (hasLineOfSight and targetDistance <= math.max(self.Config.DirectEngageDistance + 4, 9))
			and self:_getPressureDestination(targetRoot)
			or searchAnchorPosition
		local pressureRoute = {
			Mode = "DirectPressure",
			Destination = pressureDestination,
			ExpiresAt = os.clock() + 0.55,
			TargetSnapshot = pressureDestination,
		}
		local routePlan = pressureRoute

		if strategicFlankingEnabled then
			local flankRoute = self:_resolveStrategicFlankRoute(
				targetCharacter,
				targetRoot,
				searchAnchorPosition,
				hasLineOfSight,
				targetDistance
			)
			if flankRoute then
				routePlan = flankRoute
			end
		else
			self:_clearFlankDebug()
		end

		if self.Coordinator then
			routePlan = self.Coordinator:AuthorizeRoute(self.Model, self.CurrentTarget, routePlan, targetRoot)
		end

		if not routePlan then
			self:_clearFlankDebug()
			routePlan = pressureRoute
		end

		if routePlan.Mode == "DirectPressure" or not isDetourMode(routePlan.Mode) then
			self:_clearFlankDebug()
		end

		self.RoutePlan = routePlan
		if strategicFlankingEnabled and isDetourMode(routePlan.Mode)
			and not isDetourMode(previousMode)
		then
			self:_playCue("Flank", 1.8)
		end
	end

	if not strategicFlankingEnabled or (self.RoutePlan and not isDetourMode(self.RoutePlan.Mode)) then
		self:_clearFlankDebug()
	end

	self.RouteMode = self.RoutePlan.Mode
	return self.RoutePlan
end

function NpcController:_resolveParkourPlan(targetCharacter, targetRoot)
	local now = os.clock()
	local planningTargetPosition = self:_getTargetNavigationPosition(targetCharacter, targetRoot) or targetRoot.Position
	local hasDirectLine = self:_hasLineOfSight(planningTargetPosition, targetCharacter)
	local verticalDelta = planningTargetPosition.Y - self.Root.Position.Y
	local needsParkourSearch = self.ParkourPlan ~= nil
		or verticalDelta > self.Config.AssistJumpRiseThreshold
		or (verticalDelta > 0.5 and not hasDirectLine)
		or self.LastPathError == "Path blocked"
		or self.LastPathError == "Navigation stalled"
		or self.LastPathError == "Direct movement stalled"
		or self.LastPathError == "Parkour search stalled"

	if not needsParkourSearch then
		self:_clearParkourPlan()
		self:_clearParkourSearchState()
		return nil
	end

	if self.ParkourPlan then
		local targetDrift = horizontal(planningTargetPosition - self.ParkourPlan.TargetSnapshot).Magnitude
		local originDrift = horizontal(self.Root.Position - self.ParkourPlan.OriginSnapshot).Magnitude
		if self:_getParkourStep()
			and now - self.LastParkourFailureClock > 0.08
			and now - self.LastParkourPlanClock < self.Config.ParkourPlanInterval
			and targetDrift <= self.Config.ParkourPathReplanDistance
			and originDrift <= self.Config.ParkourOriginReplanDistance
		then
			return self.ParkourPlan
		end
	end

	local ParkourPlanner = getParkourPlanner()
	self.LastParkourPlanClock = now
	self.ParkourPlan = ParkourPlanner.FindRoute(
		self.Root.Position,
		planningTargetPosition,
		targetCharacter,
		self.Model,
		self.Config
	)

	if self.ParkourPlan then
		self.ParkourStepIndex = 1
		self.ParkourRetryDestination = nil
		self:_clearParkourSearchState()
	end

	return self.ParkourPlan
end

function NpcController:_replan(destination, targetCharacter)
	destination = self:_clampToLeash(destination)
	self.LastPlannedDestination = destination

	local plan, errorMessage = self.PathPlanner:TryPlan(
		self.Model,
		self.Root.Position,
		destination,
		self.Config.PathOptions
	)

	if plan then
		self:_clearNavigation()
		self.ActivePath = plan.Path
		self.CurrentWaypoints = plan.Waypoints
		self.CurrentWaypointIndex = 1
		self.LastWaypointDistance = math.huge
		self.LastProgressClock = os.clock()
		self.LastPathError = nil

		if self.CurrentWaypoints[1] and (self.CurrentWaypoints[1].Position - self.Root.Position).Magnitude <= self.Config.WaypointReachedDistance then
			self.CurrentWaypointIndex = 2
		end

		self.PathBlockedConnection = self.ActivePath.Blocked:Connect(function(blockedWaypointIndex)
			if blockedWaypointIndex >= self.CurrentWaypointIndex then
				self.LastPathError = "Path blocked"
				self:_clearNavigation()
				self:_registerNavigationFailure("Path blocked")
				self.LastPlanClock = 0
			end
		end)

		return true
	end

	if errorMessage == "Path plan is throttled" then
		if self.ActivePath or self.DirectMoveTarget or self:_isParkourActive() then
			return true
		end

		if self.Config.AllowDirectMoveFallback and self:_hasLineOfSight(destination, targetCharacter) then
			self:_setDirectMoveTarget(destination)
			return true
		end

		return true
	end

	if self.Config.AllowDirectMoveFallback and self:_hasLineOfSight(destination, targetCharacter) then
		self:_setDirectMoveTarget(destination)
		self.LastPathError = "Direct fallback"
		return true
	end

	if self.ActivePath or self.DirectMoveTarget or self:_isParkourActive() then
		self.LastPathError = tostring(errorMessage or "Holding previous route")
		return true
	end

	self.LastPathError = tostring(errorMessage or "No valid path")
	self:_registerNavigationFailure(self.LastPathError)
	return false
end

function NpcController:_advanceWaypoint()
	local waypoint = nil
	if self.CurrentWaypoints then
		waypoint = self.CurrentWaypoints[self.CurrentWaypointIndex]
	end

	while waypoint and (waypoint.Position - self.Root.Position).Magnitude <= self.Config.WaypointReachedDistance do
		self.CurrentWaypointIndex = self.CurrentWaypointIndex + 1
		self.LastWaypointDistance = math.huge
		self.LastProgressClock = os.clock()
		waypoint = self.CurrentWaypoints[self.CurrentWaypointIndex]
	end

	if not waypoint then
		self:_clearNavigation(false)
	end

	return waypoint
end

function NpcController:_triggerJump(duration)
	if self.Humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end

	self.Humanoid.Jump = true
	self.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	self.JumpStateUntil = math.max(self.JumpStateUntil, os.clock() + duration)
	return true
end

function NpcController:_isCharacterGrounded(character)
	if not character then
		return true
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return true
	end

	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Jumping
		or state == Enum.HumanoidStateType.Freefall
		or state == Enum.HumanoidStateType.FallingDown
	then
		return false
	end

	return humanoid.FloorMaterial ~= Enum.Material.Air
end

function NpcController:_getTargetNavigationPosition(targetCharacter, targetRoot)
	if not targetRoot then
		return nil
	end

	if self:_isCharacterGrounded(targetCharacter) then
		return targetRoot.Position
	end

	local params = self:_createRaycastParams(targetCharacter)
	local probeOrigin = targetRoot.Position + Vector3.new(0, 3.5, 0)
	local result = Workspace:Raycast(probeOrigin, Vector3.new(0, -32, 0), params)
	if not result or result.Normal.Y < 0.55 then
		return targetRoot.Position
	end

	local rootHeightOffset = math.max(2.5, targetRoot.Size.Y * 0.5)
	local projectedY = getSurfaceTopY(result) + rootHeightOffset
	return Vector3.new(targetRoot.Position.X, projectedY, targetRoot.Position.Z)
end

function NpcController:_findParkourLanding(destination, targetCharacter)
	local direction = horizontal(destination - self.Root.Position)
	if direction.Magnitude < 2 then
		return nil
	end

	local directionUnit = direction.Unit
	local right = Vector3.new(-directionUnit.Z, 0, directionUnit.X)
	local params = self:_createRaycastParams(targetCharacter)
	local bestLanding = nil
	local bestScore = -math.huge

	for sampleIndex = 1, self.Config.ParkourMaxSamples do
		local forwardDistance = math.min(
			direction.Magnitude,
			self.Config.ParkourProbeDistance,
			sampleIndex * self.Config.ParkourSampleStep
		)
		for lateralIndex = -self.Config.ParkourLateralProbeCount, self.Config.ParkourLateralProbeCount do
			local lateralOffset = lateralIndex * self.Config.ParkourLateralSpacing
			local sampleOrigin = self.Root.Position
				+ Vector3.new(0, self.Config.ParkourLandingProbeHeight, 0)
				+ directionUnit * forwardDistance
				+ right * lateralOffset

			local landingHit = Workspace:Raycast(sampleOrigin, Vector3.new(0, -self.Config.ParkourLandingProbeDepth, 0), params)
			if landingHit and landingHit.Normal.Y >= 0.55 and (not targetCharacter or not landingHit.Instance:IsDescendantOf(targetCharacter)) then
				local landingY = getSurfaceTopY(landingHit)
				local rise = landingY - self.Root.Position.Y
				if rise >= self.Config.ParkourMinRise and rise <= self.Config.MaxJumpRise then
					local headOrigin = self.Root.Position + Vector3.new(0, self.Config.ParkourClearanceHeight, 0)
					local headHit = Workspace:Raycast(headOrigin, directionUnit * forwardDistance + right * lateralOffset, params)
					if not headHit or (headHit.Position - headOrigin).Magnitude >= forwardDistance - 0.35 then
						local landing = Vector3.new(
							landingHit.Position.X,
							landingY + self.Config.ParkourLandingYOffset,
							landingHit.Position.Z
						)
						local forwardOffset = math.min(self.Config.ParkourLandingForwardOffset, forwardDistance * 0.25)
						landing = landing + directionUnit * forwardOffset
						local remainingDistance = horizontal(destination - landing).Magnitude
						local progress = math.max(0, direction.Magnitude - remainingDistance)
						local lateralPenalty = math.abs(lateralOffset) * 0.2
						local score = progress * 2.3 + rise * 1.85 - lateralPenalty
						if score > bestScore then
							bestScore = score
							bestLanding = landing
						end
					end
				end
			end
		end
	end

	return bestLanding
end

function NpcController:_tryParkourJump(destination, targetCharacter, requireGroundedTarget)
	local now = os.clock()
	if now - self.LastAssistJumpClock < self.Config.AssistJumpCooldown then
		return false
	end

	if self:_isParkourActive() then
		return true
	end

	local delta = destination - self.Root.Position
	local horizontalDistance = horizontal(delta).Magnitude
	local verticalDelta = delta.Y

	if verticalDelta < self.Config.AssistJumpRiseThreshold then
		return false
	end

	if verticalDelta > self.Config.MaxJumpRise + 1.5 then
		return false
	end

	if horizontalDistance > self.Config.AssistJumpDistance then
		return false
	end

	if requireGroundedTarget and not self:_isCharacterGrounded(targetCharacter) then
		return false
	end

	local moveTarget = self:_findParkourLanding(destination, targetCharacter)
	if not moveTarget then
		return false
	end

	return self:_startParkourJump(moveTarget, self.Config.ParkourCommitSeconds)
end

function NpcController:_maybeJumpForWaypoint(waypoint)
	if waypoint.Action ~= Enum.PathWaypointAction.Jump then
		return "None"
	end

	local rise = waypoint.Position.Y - self.Root.Position.Y
	if rise > self.Config.MaxJumpRise then
		self.LastPathError = ("Jump too high (%.1f)"):format(rise)
		self:_clearNavigation()
		return "Blocked"
	end

	if rise > 0.75 and self:_startParkourJump(waypoint.Position, self.Config.ParkourCommitSeconds) then
		return "Launched"
	end

	if self:_triggerJump(0.45) then
		return "Launched"
	end

	return "None"
end

function NpcController:_probeForwardJump(destination, targetCharacter)
	local direction = horizontal(destination - self.Root.Position)
	if direction.Magnitude < 2 then
		return "None"
	end

	local probeDistance = math.min(self.Config.ForwardJumpProbeDistance, direction.Magnitude)
	local directionUnit = direction.Unit
	local params = self:_createRaycastParams(targetCharacter)
	local lowOrigin = self.Root.Position + Vector3.new(0, 2, 0)
	local lowHit = Workspace:Raycast(lowOrigin, directionUnit * probeDistance, params)
	if not lowHit then
		return "None"
	end

	if targetCharacter and lowHit.Instance:IsDescendantOf(targetCharacter) then
		return "None"
	end

	local hitDistance = (lowHit.Position - lowOrigin).Magnitude
	if hitDistance > 4 then
		return "None"
	end

	local obstacleTop = lowHit.Position.Y
	if lowHit.Instance:IsA("BasePart") then
		obstacleTop = lowHit.Instance.Position.Y + lowHit.Instance.Size.Y * 0.5
	end

	local rise = obstacleTop - self.Root.Position.Y
	if rise > self.Config.MaxJumpRise then
		self.LastPathError = ("Obstacle too tall (%.1f)"):format(rise)
		return "Blocked"
	end

	local highOrigin = self.Root.Position + Vector3.new(0, self.Config.MaxJumpRise + 2, 0)
	local highHit = Workspace:Raycast(highOrigin, directionUnit * probeDistance, params)
	if highHit and highHit.Instance == lowHit.Instance then
		self.LastPathError = "Obstacle blocks jump lane"
		return "Blocked"
	end

	if rise > 1 then
		local landing = Vector3.new(
			lowHit.Position.X,
			obstacleTop + self.Config.ParkourLandingYOffset,
			lowHit.Position.Z
		) + directionUnit * math.min(self.Config.ParkourLandingForwardOffset, probeDistance * 0.35)

		if self:_startParkourJump(landing, self.Config.ParkourCommitSeconds) then
			return "Launched"
		end

		if self:_triggerJump(0.5) then
			return "Launched"
		end
	end

	return "None"
end

function NpcController:_followNavigation(targetCharacter, disableAssistJump)
	if self:_updateParkour() then
		return
	end

	if self.CurrentWaypoints then
		local waypoint = self:_advanceWaypoint()
		if not waypoint then
			return
		end

		local jumpResult = self:_maybeJumpForWaypoint(waypoint)
		if jumpResult == "Blocked" or jumpResult == "Launched" then
			return
		end

		local riseToWaypoint = waypoint.Position.Y - self.Root.Position.Y
		if not disableAssistJump and riseToWaypoint > 0.8 and self:_tryParkourJump(waypoint.Position, targetCharacter, false) then
			return
		end

		if not disableAssistJump and riseToWaypoint > 0.8 then
			local forwardJumpResult = self:_probeForwardJump(waypoint.Position, targetCharacter)
			if forwardJumpResult == "Blocked" or forwardJumpResult == "Launched" then
				return
			end
		end

		local distance = (waypoint.Position - self.Root.Position).Magnitude
		if distance < self.LastWaypointDistance - 0.25 then
			self.LastProgressClock = os.clock()
			self.NavigationFailureCount = 0
		end
		self.LastWaypointDistance = distance

		if os.clock() - self.LastProgressClock > self.Config.StuckReplanSeconds then
			self.LastPathError = "Navigation stalled"
			self:_clearNavigation()
			self:_registerNavigationFailure("Navigation stalled")
			return
		end

		self:_issueMoveTo(waypoint.Position)
		return
	end

	if self.DirectMoveTarget then
		local riseToTarget = self.DirectMoveTarget.Y - self.Root.Position.Y
		if not disableAssistJump and riseToTarget > 0.8 and self:_tryParkourJump(self.DirectMoveTarget, targetCharacter, false) then
			return
		end

		if not disableAssistJump and riseToTarget > 0.8 then
			local forwardJumpResult = self:_probeForwardJump(self.DirectMoveTarget, targetCharacter)
			if forwardJumpResult == "Blocked" or forwardJumpResult == "Launched" then
				return
			end
		end

		local distance = (self.DirectMoveTarget - self.Root.Position).Magnitude
		if distance < self.LastWaypointDistance - 0.25 then
			self.LastProgressClock = os.clock()
			self.NavigationFailureCount = 0
		end
		self.LastWaypointDistance = distance

		if os.clock() - self.LastProgressClock > self.Config.StuckReplanSeconds then
			self.LastPathError = "Direct movement stalled"
			self.DirectMoveTarget = nil
			self:_registerNavigationFailure("Direct movement stalled")
			return
		end

		if distance <= self.Config.WaypointReachedDistance then
			self.DirectMoveTarget = nil
			return
		end

		self:_issueMoveTo(self.DirectMoveTarget)
	end
end

function NpcController:_runParkourPlan(targetCharacter)
	if not self.ParkourPlan then
		return false
	end

	if self:_updateParkour() then
		self.RouteMode = "ParkourHop"
		self.Humanoid.WalkSpeed = self.Config.ParkourWalkSpeed
		return true
	end

	if not self:_advanceParkourPlan() then
		return false
	end

	local step = self:_getParkourStep()
	if not step then
		return false
	end

	self.Humanoid.WalkSpeed = self.Config.ParkourWalkSpeed

	if step.Action == "Walk" then
		self.RouteMode = "ParkourWalk"
		local walkDestination = self:_clampToLeash(step.Destination)
		self:_navigateToward(walkDestination, targetCharacter, {
			PreferDirect = true,
			DirectDistance = self.Config.ParkourDirectApproachDistance,
			AllowBlindParkourDirect = true,
			BlindDirectDistance = self.Config.ParkourSearchBlindDirectDistance or 12,
			ReplanThreshold = 0.9,
			ReplanInterval = self.Config.ParkourSearchReplanInterval or self.Config.PathReplanInterval,
			DisableAssistJump = false,
		})
		if self.LastPathError == "Direct movement stalled"
			or self.LastPathError == "Navigation stalled"
			or self.LastPathError == "Path blocked"
		then
			self:_markParkourFailure("Parkour approach stalled")
		end

		return true
	end

	self.RouteMode = "ParkourHop"

	local launchPosition = self:_clampToLeash(step.LaunchPosition)
	local launchRise = launchPosition.Y - self.Root.Position.Y
	local onLaunchSurface = self:_isOnParkourSurface(
		launchPosition,
		self.Config.ParkourLaunchApproachRadius,
		step.LaunchInstance,
		step.LaunchSurfaceY
	)

	if not onLaunchSurface or math.abs(launchPosition.Y - self.Root.Position.Y) > (self.Config.ParkourLaunchVerticalTolerance or self.Config.ParkourGoalHeightTolerance) then
		self.RouteMode = "ParkourLaunch"

		if launchRise > 0.55
			and horizontal(launchPosition - self.Root.Position).Magnitude <= (self.Config.ParkourLaunchAssistDistance or 8.5)
			and self:_tryParkourJump(launchPosition, targetCharacter, false)
		then
			self.LastPathError = "Launch assist jump"
			return true
		end

		self:_navigateToward(launchPosition, targetCharacter, {
			PreferDirect = true,
			DirectDistance = math.min(self.Config.ParkourDirectApproachDistance or 5.5, 3.75),
			AllowBlindParkourDirect = true,
			BlindDirectDistance = self.Config.ParkourLaunchAssistDistance or 8.5,
			ReplanThreshold = 0.55,
			ReplanInterval = self.Config.ParkourSearchReplanInterval or self.Config.PathReplanInterval,
			DisableAssistJump = false,
		})
		if self.LastPathError == "Direct movement stalled"
			or self.LastPathError == "Navigation stalled"
			or self.LastPathError == "Path blocked"
		then
			self:_markParkourFailure("Parkour launch stalled")
		end

		return true
	end

	if self.Humanoid.FloorMaterial == Enum.Material.Air then
		return true
	end

	if self:_startParkourJump(step, self.Config.ParkourCommitSeconds) then
		self.LastPathError = "Parkour hop"
		return true
	end

	self:_markParkourFailure("Parkour hop rejected")
	return true
end

function NpcController:_runPatrol()
	self:_setStateWalkSpeed("Patrol")

	if not self.RoutePlan or os.clock() >= self.RoutePlan.ExpiresAt then
		local patrolOffset = Vector3.new(
			math.random(-self.Config.PatrolRadius, self.Config.PatrolRadius),
			0,
			math.random(-self.Config.PatrolRadius, self.Config.PatrolRadius)
		)

		self.RoutePlan = {
			Mode = "PatrolArc",
			Destination = self.SpawnPosition + patrolOffset,
			ExpiresAt = os.clock() + math.random(150, 300) / 100,
		}
	end

	self.RouteMode = self.RoutePlan.Mode

	if self:_needsReplan(self.RoutePlan.Destination, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(self.RoutePlan.Destination)
	end

	self:_followNavigation(nil)
end

function NpcController:_runChase()
	local targetCharacter = self.CurrentTarget and self.CurrentTarget.Character
	local targetRoot = nil
	if targetCharacter then
		targetRoot = targetCharacter:FindFirstChild("HumanoidRootPart")
	end
	if not targetRoot then
		return
	end

	self:_setStateWalkSpeed("Chase")

	local targetNavigationPosition = self:_getTargetNavigationPosition(targetCharacter, targetRoot) or targetRoot.Position
	local targetDistance = (targetNavigationPosition - self.Root.Position).Magnitude
	local hasDirectLine = self:_hasLineOfSight(targetNavigationPosition, targetCharacter)
	local verticalDelta = targetNavigationPosition.Y - self.Root.Position.Y
	local strategicFlankingEnabled = self.Config.EnableStrategicFlanking ~= false
		and os.clock() >= (self.ForcePressureUntil or 0)
	local wantsElevationRoute = verticalDelta > self.Config.AssistJumpRiseThreshold
		or (verticalDelta > 0.5 and not hasDirectLine)

	if self.ParkourPlan and not wantsElevationRoute and (hasDirectLine or verticalDelta <= 0.2) then
		self.ParkourRetryDestination = nil
		self.LastPathError = ""
		self.LastPlanClock = 0
		self.LastPlannedDestination = nil
		self:_clearNavigation()
		self:_clearParkourPlan()
	end

	if wantsElevationRoute or self.ParkourPlan then
		if self.Coordinator then
			self.Coordinator:ClearFlankReservation(self.Model)
		end
		self.Model:SetAttribute("EngagementRole", "Pressure")

		if self.ParkourRetryDestination then
			local retryDistance = horizontal(self.ParkourRetryDestination - self.Root.Position).Magnitude
			local retryVerticalDistance = math.abs(self.ParkourRetryDestination.Y - self.Root.Position.Y)
			if retryDistance <= (self.Config.ParkourSearchArrivalDistance or 2.8)
				and retryVerticalDistance <= self.Config.ParkourGoalHeightTolerance
			then
				self.ParkourRetryDestination = nil
				self.LastPlanClock = 0
			else
				self.RouteMode = "ParkourRetry"
				self.Humanoid.WalkSpeed = self.Config.ParkourWalkSpeed
				self:_navigateToward(self.ParkourRetryDestination, targetCharacter, {
					PreferDirect = false,
					ReplanThreshold = 0.8,
					ReplanInterval = self.Config.ParkourSearchReplanInterval or self.Config.PathReplanInterval,
					DisableAssistJump = false,
				})
				if self.LastPathError == "Direct movement stalled"
					or self.LastPathError == "Navigation stalled"
					or self.LastPathError == "Path blocked"
				then
					self.ParkourRetryDestination = nil
					self.LastPlanClock = 0
					self:_clearNavigation()
				end
				self:_tryAttackTarget(targetCharacter, targetRoot)
				return
			end
		end

		local parkourPlan = self:_resolveParkourPlan(targetCharacter, targetRoot)
		if parkourPlan then
			if self:_runParkourPlan(targetCharacter) then
				self:_tryAttackTarget(targetCharacter, targetRoot)
				return
			end
		end

		self.RouteMode = "ParkourSearch"
		self.Humanoid.WalkSpeed = self.Config.ParkourWalkSpeed
		local searchDestination = self:_getElevationSearchDestination(targetCharacter, targetRoot)
		self:_navigateToward(searchDestination, targetCharacter, {
			PreferDirect = true,
			DirectDistance = math.max(self.Config.ParkourDirectApproachDistance or 5.5, 9),
			AllowBlindParkourDirect = true,
			BlindDirectDistance = self.Config.ParkourSearchBlindDirectDistance or 12,
			ReplanThreshold = 0.85,
			ReplanInterval = self.Config.ParkourSearchReplanInterval or self.Config.PathReplanInterval,
			DisableAssistJump = false,
		})
		if self.LastPathError == "Direct movement stalled"
			or self.LastPathError == "Navigation stalled"
			or self.LastPathError == "Path blocked"
		then
			self.LastPathError = "Parkour search stalled"
			self.LastPlanClock = 0
			self:_clearNavigation()
		end
		self:_tryAttackTarget(targetCharacter, targetRoot)
		return
	end

	if not strategicFlankingEnabled then
		if self.Coordinator then
			self.Coordinator:ClearFlankReservation(self.Model)
		end
		self:_clearFlankDebug()
		self.Model:SetAttribute("EngagementRole", "Pressure")
		self.RouteMode = "DirectPressure"
		self:_navigateToward(self:_getPressureDestination(targetRoot), targetCharacter, {
			PreferDirect = true,
			DirectDistance = self.Config.DirectEngageDistance,
		})
		self:_tryAttackTarget(targetCharacter, targetRoot)
		return
	end

	if targetDistance <= self.Config.DirectEngageDistance + 2
		and hasDirectLine
		and math.abs(verticalDelta) <= self.Config.ParkourGoalHeightTolerance
	then
		if self.Coordinator then
			self.Coordinator:ClearFlankReservation(self.Model)
		end
		self.Model:SetAttribute("EngagementRole", "Pressure")
		self.RouteMode = "DirectPressure"
		self:_navigateToward(self:_getPressureDestination(targetRoot), targetCharacter, {
			PreferDirect = true,
			DirectDistance = self.Config.DirectEngageDistance,
		})
		self:_tryAttackTarget(targetCharacter, targetRoot)
		return
	end

	local routePlan = self:_resolveRoutePlan(targetCharacter, targetRoot)
	local destination = self:_clampToLeash(routePlan.Destination)

	if self:_needsReplan(destination, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(destination, targetCharacter)
	end

	self:_followNavigation(targetCharacter)

	if not self.ActivePath
		and not self.DirectMoveTarget
		and not self:_isParkourActive()
		and hasDirectLine
		and targetDistance <= math.max(self.Config.DirectEngageDistance + 1.5, 8)
	then
		self:_issueMoveTo(self:_getPressureDestination(targetRoot))
	end

	self:_tryAttackTarget(targetCharacter, targetRoot)
end

function NpcController:_runRetreat()
	if not self.CurrentTarget or not self.CurrentTarget.Character then
		return
	end

	self:_setStateWalkSpeed("Return")

	local targetRoot = self.CurrentTarget.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	self.RouteMode = "Retreat"

	local delta = self.Root.Position - targetRoot.Position
	local awayDirection = Vector3.new(0, 0, -1)
	if delta.Magnitude > 0.01 then
		awayDirection = delta.Unit
	end

	local retreatPoint = self:_clampToLeash(self.Root.Position + awayDirection * self.Config.RetreatDistance)

	if self:_needsReplan(retreatPoint, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(retreatPoint, self.CurrentTarget.Character)
	end

	self:_followNavigation(self.CurrentTarget.Character)
end

function NpcController:_runReturn()
	self:_setStateWalkSpeed("Return")
	self.RouteMode = "Return"

	if self:_needsReplan(self.SpawnPosition, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(self.SpawnPosition)
	end

	self:_followNavigation(nil)
end

function NpcController:Step(deltaTime)
	if not self.Model.Parent or self.Humanoid.Health <= 0 then
		if self.AnimationController then
			self.AnimationController:Update("Idle", 0, "Idle")
		end
		return
	end

	if self.KillResetPending then
		self.CurrentTarget = nil
		self.Model:SetAttribute("EngagementRole", "Unassigned")
		self.RoutePlan = nil
		self.LastPlannedDestination = nil
		self.State = "Recover"
		self.RouteMode = "ReturnHome"
		self:_clearParkourPlan()
		self:_setStateWalkSpeed("Recover")

		local distanceToSpawn = (self.Root.Position - self.SpawnPosition).Magnitude
		if os.clock() - self.KillResetStartClock >= self.Config.KillResetReturnTimeout then
			self:_forceRespawnToSpawn(self.KillResetCooldown)
		elseif distanceToSpawn > self.Config.WaypointReachedDistance + 1 then
			if self:_needsReplan(self.SpawnPosition, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
				self.LastPlanClock = os.clock()
				self:_replan(self.SpawnPosition)
			end

			self:_followNavigation(nil)
		else
			self:_forceRespawnToSpawn(self.KillResetCooldown)
		end

		self:_publishState()
		if self.AnimationController then
			self.AnimationController:Update(self.State, self.Root.AssemblyLinearVelocity.Magnitude, "Grounded")
		end
		return
	end

	local holdUntil = self:_getAggroHoldUntil()
	if os.clock() < holdUntil then
		self.CurrentTarget = nil
		self.Model:SetAttribute("EngagementRole", "Unassigned")
		self.RoutePlan = nil
		self.LastPlannedDestination = nil
		self.State = "Recover"
		self.RouteMode = "SpawnHold"
		self.LastPathError = ""
		self:_clearParkourPlan()
		self:_setStateWalkSpeed("Recover")
		self:_clearNavigation()
		self:_issueMoveTo(self.SpawnPosition)
		self:_publishState()

		if self.AnimationController then
			self.AnimationController:Update(self.State, 0, "Idle")
		end
		return
	elseif holdUntil > 0 then
		self.Model:SetAttribute("NpcAggroHoldUntil", 0)
	end

	self:_refreshThreat()
	if self.Config.EnableStrategicFlanking == false then
		self:_clearFlankDebug()
	end

	local UtilityScorer = getUtilityScorer()
	local scores = UtilityScorer.Score(self:_getContext())
	self.State = UtilityScorer.Pick(scores)
	self:_setStateWalkSpeed(self.State)

	if self.Config.EnableStrategicFlanking == false then
		if self.State == "Chase" then
			self.Model:SetAttribute("EngagementRole", "Pressure")
		else
			self.Model:SetAttribute("EngagementRole", "Unassigned")
		end
	end

	if self.State == "Patrol" then
		self:_runPatrol()
	elseif self.State == "Chase" then
		self:_runChase()
	elseif self.State == "Retreat" then
		self:_runRetreat()
	elseif self.State == "Return" then
		self:_runReturn()
	end

	self:_updateStuckRecovery()

	self:_publishState()

	if self.AnimationController then
		local humanoidState = self.Humanoid:GetState()
		local movementState = "Grounded"
		if os.clock() <= self.JumpStateUntil
			or humanoidState == Enum.HumanoidStateType.Jumping
			or humanoidState == Enum.HumanoidStateType.Freefall
		then
			movementState = "Jump"
		end

		self.AnimationController:Update(self.State, self.Root.AssemblyLinearVelocity.Magnitude, movementState)
	end
end

function NpcController:_tryAttackTarget(targetCharacter, targetRoot)
	if not targetCharacter or not targetRoot then
		return false
	end

	if os.clock() - self.LastAttackClock < self.Config.AttackCooldown then
		return false
	end

	local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end

	local delta = targetRoot.Position - self.Root.Position
	local horizontalDistance = horizontal(delta).Magnitude
	local verticalDistance = math.abs(delta.Y)
	if horizontalDistance > self.Config.AttackRange or verticalDistance > self.Config.AttackVerticalTolerance then
		return false
	end

	local hasClearSwing = self:_hasLineOfSight(targetRoot.Position + Vector3.new(0, 1, 0), targetCharacter)
	if not hasClearSwing and delta.Magnitude > self.Config.AttackRange * 0.7 then
		return false
	end

	self.LastAttackClock = os.clock()
	self:_issueMoveTo(self.Root.Position, true)

	local damage = math.max(1, math.floor(humanoid.MaxHealth * self.Config.AttackHealthFraction + 0.5))
	humanoid:TakeDamage(damage)
	if humanoid.Health <= 0 then
		self:_playCue("Kill", 1.4)
	end
	self.ThreatService:AddDamageThreat(self.Model, self.CurrentTarget, damage)
	return true
end

function NpcController:ResetAfterKill(cooldownSeconds)
	cooldownSeconds = cooldownSeconds or 5

	self.CurrentTarget = nil
	self.State = "Recover"
	self.RoutePlan = nil
	self.RouteMode = "Recover"
	self.LastPlannedDestination = nil
	self.LastAttackClock = 0
	self.LastPathError = ""
	self.JumpStateUntil = 0
	self:_clearNavigation()
	self:_clearParkourPlan()
	self:_clearParkourSearchState()
	self.TargetHoldUntil = 0
	self.KillResetPending = true
	self.KillResetCooldown = cooldownSeconds
	self.KillResetStartClock = os.clock()
	self:_playCue("Return", 1.2)
	self.ParkourRetryDestination = nil

	if self.Humanoid.Health > 0 then
		self.Humanoid.Health = self.Humanoid.MaxHealth
	end

	if self.Coordinator then
		self.Coordinator:ClearFlankReservation(self.Model)
	end

	pcall(function()
		self.Root:SetNetworkOwner(nil)
	end)

	self.Model:SetAttribute("NpcAggroHoldUntil", 0)
	self.Model:SetAttribute("NpcKillResetPending", true)
	self:_publishState()
end

function NpcController:Destroy()
	self:_clearNavigation()
	self:_clearParkourPlan()

	if self.Coordinator then
		self.Coordinator:ClearFlankReservation(self.Model)
	end

	if self.AnimationController then
		self.AnimationController:Destroy()
		self.AnimationController = nil
	end

	if self.DebugOverlayRoot and self.DebugOverlayRoot.Parent then
		self.DebugOverlayRoot:Destroy()
		self.DebugOverlayRoot = nil
	end
end

return NpcController
