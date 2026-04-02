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

function NpcService.new()
	local PathPlanner = getPathPlanner()
	local ThreatService = getThreatService()

	local self = setmetatable({}, NpcService)
	self._controllers = {}
	self._pathPlanner = PathPlanner.new()
	self._threatService = ThreatService.new()
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
	local ok, controllerOrError = pcall(function()
		local NpcController = getNpcController()
		return NpcController.new(model, config, self._threatService, self._pathPlanner)
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

function NpcService:RemoveNpc(model)
	local controller = self._controllers[model]
	if controller then
		controller:Destroy()
	end

	self._controllers[model] = nil
	self._pathPlanner:Remove(model)
	self._threatService:RemoveNpc(model)
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
