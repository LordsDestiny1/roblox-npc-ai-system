local RunService = game:GetService("RunService")

local NpcService = {}
NpcService.__index = NpcService

local cachedNpcController = nil
local cachedPathPlanner = nil
local cachedThreatService = nil

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

local function getNpcController()
	if not cachedNpcController then
		cachedNpcController = requireChildModule("NpcController")
	end

	return cachedNpcController
end

local function getPathPlanner()
	if not cachedPathPlanner then
		cachedPathPlanner = requireChildModule("PathPlanner")
	end

	return cachedPathPlanner
end

local function getThreatService()
	if not cachedThreatService then
		cachedThreatService = requireChildModule("ThreatService")
	end

	return cachedThreatService
end

local function isFlankMode(mode)
	return string.find(mode or "", "Flank", 1, true) ~= nil
		or string.find(mode or "", "Wide", 1, true) ~= nil
		or string.find(mode or "", "Backdoor", 1, true) ~= nil
		or string.find(mode or "", "Pinch", 1, true) ~= nil
		or string.find(mode or "", "Cutoff", 1, true) ~= nil
end

local function isAssignmentValid(assignment)
	if not assignment or assignment.ExpiresAt <= os.clock() then
		return false
	end

	local model = assignment.Model
	if not model or not model.Parent then
		return false
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function getStableNameByte(name)
	local token = string.match(name or "", "([%w])$")
	if not token then
		return nil
	end

	return string.byte(string.upper(token))
end

local function buildPressureLanePlan(model, targetRoot)
	local modelRoot = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	local toTarget = modelRoot and horizontal(targetRoot.Position - modelRoot.Position) or Vector3.zero
	local approachDirection = toTarget.Magnitude > 0.1 and toTarget.Unit or Vector3.new(0, 0, -1)
	local right = Vector3.new(-approachDirection.Z, 0, approachDirection.X)
	local preferredSide = model:GetAttribute("PreferredSide")
	local shoulder = preferredSide == "Left" and -right or right
	local stableByte = getStableNameByte(model.Name) or 0
	local laneBand = stableByte % 2
	local lateralDistance = laneBand == 0 and 0.55 or 0.95
	local trailDistance = laneBand == 0 and 0.3 or 0.55
	local destination = targetRoot.Position + shoulder * lateralDistance - approachDirection * trailDistance

	return {
		Mode = preferredSide == "Left" and "PressureLeft" or "PressureRight",
		Destination = destination,
		ExpiresAt = os.clock() + 0.55,
		TargetSnapshot = targetRoot.Position,
	}
end

function NpcService.new()
	local PathPlanner = getPathPlanner()
	local ThreatService = getThreatService()

	local self = setmetatable({}, NpcService)
	self._controllers = {}
	self._pathPlanner = PathPlanner.new()
	self._threatService = ThreatService.new()
	self._flankAssignments = {}
	self._flankLeaseSeconds = 2.4
	self._flankReassignAdvantage = 4
	self._strategicFlankingEnabled = true
	self._running = false
	return self
end

function NpcService:_markControllerError(model, message)
	model:SetAttribute("AiState", "Error")
	model:SetAttribute("LastPathError", tostring(message or "Unknown controller error"))
	model:SetAttribute("NpcControllerReady", false)
	model:SetAttribute("NpcControllerError", tostring(message or "Unknown controller error"))
end

function NpcService:RegisterNpc(model, config)
	if config and config.EnableStrategicFlanking == false then
		self._strategicFlankingEnabled = false
	end

	local ok, controllerOrError = pcall(function()
		local NpcController = getNpcController()
		return NpcController.new(model, config, self._threatService, self._pathPlanner, self)
	end)

	if not ok then
		self:_markControllerError(model, controllerOrError)
		warn(("[NpcAI] Failed to register %s: %s"):format(model:GetFullName(), tostring(controllerOrError)))
		return nil
	end

	local controller = controllerOrError
	self._controllers[model] = controller
	model:SetAttribute("NpcControllerReady", true)
	model:SetAttribute("NpcControllerError", "")
	return controller
end

function NpcService:HasNpc(model)
	return self._controllers[model] ~= nil
end

function NpcService:ClearFlankReservation(model)
	for userId, assignment in pairs(self._flankAssignments) do
		if assignment.Model == model then
			self._flankAssignments[userId] = nil
		end
	end
	if model and model.Parent then
		model:SetAttribute("EngagementRole", "Unassigned")
	end
end

function NpcService:AuthorizeRoute(model, targetPlayer, routePlan, targetRoot)
	if not routePlan then
		model:SetAttribute("EngagementRole", "Unassigned")
		return nil
	end

	if self._strategicFlankingEnabled == false then
		self:ClearFlankReservation(model)
		model:SetAttribute("EngagementRole", "Pressure")
		return routePlan
	end

	if not targetPlayer or not targetRoot or not isFlankMode(routePlan.Mode) then
		self:ClearFlankReservation(model)
		model:SetAttribute("EngagementRole", "Pressure")
		return routePlan
	end

	local userId = targetPlayer.UserId
	local assignment = self._flankAssignments[userId]
	if assignment and not isAssignmentValid(assignment) then
		self._flankAssignments[userId] = nil
		assignment = nil
	end

	if assignment and assignment.Model ~= model then
		local currentPriority = assignment.PriorityScore or 0
		local incomingPriority = routePlan.PriorityScore or 0
		if incomingPriority > currentPriority + self._flankReassignAdvantage then
			if assignment.Model and assignment.Model.Parent then
				assignment.Model:SetAttribute("EngagementRole", "Pressure")
			end
			self._flankAssignments[userId] = nil
			assignment = nil
		else
			model:SetAttribute("EngagementRole", "Pressure")
			return {
				Mode = "DirectPressure",
				Destination = targetRoot.Position,
				ExpiresAt = os.clock() + 0.5,
				TargetSnapshot = targetRoot.Position,
			}
		end
	end

	self._flankAssignments[userId] = {
		Model = model,
		ExpiresAt = os.clock() + self._flankLeaseSeconds,
		PriorityScore = routePlan.PriorityScore or 0,
	}
	model:SetAttribute("EngagementRole", "Flank")
	return routePlan
end

function NpcService:RemoveNpc(model)
	local controller = self._controllers[model]
	if controller then
		controller:Destroy()
	end

	self:ClearFlankReservation(model)
	self._controllers[model] = nil
	self._pathPlanner:Remove(model)
	self._threatService:RemoveNpc(model)
end

function NpcService:ResetNpc(model, cooldownSeconds)
	local controller = self._controllers[model]
	if not controller then
		return false
	end

	self:ClearFlankReservation(model)
	self._pathPlanner:Remove(model)
	self._threatService:RemoveNpc(model)
	controller:ResetAfterKill(cooldownSeconds)
	return true
end

function NpcService:Start()
	if self._running then
		return
	end

	self._running = true
	self._connection = RunService.Heartbeat:Connect(function(deltaTime)
		self._threatService:Decay(deltaTime)

		for model, controller in pairs(self._controllers) do
			if not model.Parent then
				self:RemoveNpc(model)
			else
				local ok, errorMessage = pcall(function()
					controller:Step(deltaTime)
				end)

				if not ok then
					self:_markControllerError(model, errorMessage)
					warn(("[NpcAI] Controller step failed for %s: %s"):format(model:GetFullName(), tostring(errorMessage)))
				end
			end
		end
	end)
end

function NpcService:Destroy()
	self._running = false
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end

	for model, controller in pairs(self._controllers) do
		controller:Destroy()
		self._pathPlanner:Remove(model)
		self._threatService:RemoveNpc(model)
	end

	table.clear(self._controllers)
end

return NpcService
