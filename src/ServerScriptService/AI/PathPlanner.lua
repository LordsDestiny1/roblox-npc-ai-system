local PathfindingService = game:GetService("PathfindingService")

local PathPlanner = {}
PathPlanner.__index = PathPlanner

function PathPlanner.new()
	local self = setmetatable({}, PathPlanner)
	self._nextAllowedPlanAt = {}
	return self
end

function PathPlanner:TryPlan(agentId, origin, destination)
	local now = os.clock()
	local nextAllowed = self._nextAllowedPlanAt[agentId] or 0
	if now < nextAllowed then
		return nil, "Path plan is throttled"
	end

	self._nextAllowedPlanAt[agentId] = now + 0.75

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
	})

	local ok, errorMessage = pcall(function()
		path:ComputeAsync(origin, destination)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil, errorMessage or "Path planning failed"
	end

	return path:GetWaypoints()
end

function PathPlanner:Remove(agentId)
	self._nextAllowedPlanAt[agentId] = nil
end

return PathPlanner

