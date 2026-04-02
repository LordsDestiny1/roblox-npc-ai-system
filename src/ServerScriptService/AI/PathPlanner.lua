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
	return self
end

function PathPlanner:TryPlan(agentId, origin, destination, overrides)
	local now = os.clock()
	local nextAllowed = self._nextAllowedPlanAt[agentId] or 0
	if now < nextAllowed then
		return nil, "Path plan is throttled"
	end

	self._nextAllowedPlanAt[agentId] = now + 0.35

	local options = cloneTable(DEFAULT_PATH_OPTIONS)
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end

	local path = PathfindingService:CreatePath(options)

	local ok, errorMessage = pcall(function()
		path:ComputeAsync(origin, destination)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil, errorMessage or "Path planning failed"
	end

	local waypoints = path:GetWaypoints()
	if #waypoints == 0 then
		return nil, "Path generated no waypoints"
	end

	return {
		Path = path,
		Waypoints = waypoints,
		Destination = destination,
	}
end

function PathPlanner:Remove(agentId)
	self._nextAllowedPlanAt[agentId] = nil
end

return PathPlanner
