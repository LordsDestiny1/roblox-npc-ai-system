local PathfindingService = game:GetService("PathfindingService")

local PathPlanner = {}
PathPlanner.__index = PathPlanner

local function cloneTable(source)
	local clone = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			local inner = {}
			for innerKey, innerValue in pairs(value) do
				inner[innerKey] = innerValue
			end
			clone[key] = inner
		else
			clone[key] = value
		end
	end
	return clone
end

local DEFAULT_PATH_OPTIONS = {
	AgentRadius = 2,
	AgentHeight = 5,
	AgentCanJump = true,
	AgentCanClimb = true,
	WaypointSpacing = 4,
	Costs = {},
}

function PathPlanner.new()
	local self = setmetatable({}, PathPlanner)
	self._nextAllowedPlanAt = {}
	self._throttleSeconds = 0.08
	return self
end

function PathPlanner:TryPlan(agentId, origin, destination, overrides)
	local now = os.clock()
	local nextAllowed = self._nextAllowedPlanAt[agentId] or 0
	if now < nextAllowed then
		return nil, "Path plan is throttled"
	end

	self._nextAllowedPlanAt[agentId] = now + self._throttleSeconds

	local options = cloneTable(DEFAULT_PATH_OPTIONS)
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end

	local path = PathfindingService:CreatePath(options)

	local ok, errorMessage = pcall(function()
		path:ComputeAsync(origin, destination)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		pcall(function()
			path:Destroy()
		end)
		return nil, errorMessage or "Path planning failed"
	end

	local waypoints = path:GetWaypoints()
	if #waypoints == 0 then
		pcall(function()
			path:Destroy()
		end)
		return nil, "Path generated no waypoints"
	end

	return {
		Path = path,
		Waypoints = waypoints,
		Destination = destination,
	}
end

function PathPlanner:Measure(agentId, origin, destination, overrides)
	local plan, errorMessage = self:TryPlan(agentId, origin, destination, overrides)
	if not plan then
		return nil, errorMessage
	end

	local totalDistance = 0
	local previousPosition = origin
	for _, waypoint in ipairs(plan.Waypoints) do
		totalDistance = totalDistance + (waypoint.Position - previousPosition).Magnitude
		previousPosition = waypoint.Position
	end

	pcall(function()
		plan.Path:Destroy()
	end)

	return totalDistance, nil, plan.Waypoints
end

function PathPlanner:Remove(agentId)
	self._nextAllowedPlanAt[agentId] = nil
end

return PathPlanner
