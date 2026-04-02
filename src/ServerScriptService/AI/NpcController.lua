local UtilityScorer = require(script.Parent.UtilityScorer)

local NpcController = {}
NpcController.__index = NpcController

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart")
end

function NpcController.new(model, config, threatService, pathPlanner)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = getRoot(model)
	assert(humanoid and root, "NPC model requires Humanoid and HumanoidRootPart")

	local self = setmetatable({}, NpcController)
	self.Model = model
	self.Humanoid = humanoid
	self.Root = root
	self.Config = config
	self.ThreatService = threatService
	self.PathPlanner = pathPlanner
	self.State = "Patrol"
	self.SpawnPosition = root.Position
	self.CurrentTarget = nil
	self.CurrentPath = nil
	self.CurrentWaypointIndex = 1
	self.LastPlanClock = 0
	self.LastAttackClock = 0
	return self
end

function NpcController:_getContext()
	local targetCharacter = self.CurrentTarget and self.CurrentTarget.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	local targetDistance = if targetRoot then (targetRoot.Position - self.Root.Position).Magnitude else math.huge
	local leashDistance = (self.Root.Position - self.SpawnPosition).Magnitude

	return {
		TargetPlayer = self.CurrentTarget,
		TargetDistance = targetDistance,
		LeashDistance = leashDistance,
		MaxLeashDistance = self.Config.MaxLeashDistance,
		HealthRatio = self.Humanoid.Health / math.max(self.Humanoid.MaxHealth, 1),
	}
end

function NpcController:_refreshThreat()
	self.ThreatService:SeedFromNearbyPlayers(self.Model, self.Root.Position, self.Config.AggroRadius)
	local targetPlayer = self.ThreatService:GetBestTarget(self.Model, self.Root.Position, self.Config.AggroRadius)
	self.CurrentTarget = targetPlayer
end

function NpcController:_replan(destination)
	local waypoints = self.PathPlanner:TryPlan(self.Model:GetDebugId(), self.Root.Position, destination)
	if waypoints then
		self.CurrentPath = waypoints
		self.CurrentWaypointIndex = 1
	end
end

function NpcController:_followPath()
	if not self.CurrentPath then
		return
	end

	local waypoint = self.CurrentPath[self.CurrentWaypointIndex]
	if not waypoint then
		return
	end

	self.Humanoid:MoveTo(waypoint.Position)
	if (waypoint.Position - self.Root.Position).Magnitude <= 3 then
		self.CurrentWaypointIndex += 1
	end
end

function NpcController:_runPatrol()
	if not self.CurrentPath or self.CurrentWaypointIndex > #self.CurrentPath then
		local patrolOffset = Vector3.new(
			math.random(-self.Config.PatrolRadius, self.Config.PatrolRadius),
			0,
			math.random(-self.Config.PatrolRadius, self.Config.PatrolRadius)
		)

		self:_replan(self.SpawnPosition + patrolOffset)
	end

	self:_followPath()
end

function NpcController:_runChase()
	local targetCharacter = self.CurrentTarget and self.CurrentTarget.Character
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	if os.clock() - self.LastPlanClock > 0.8 then
		self.LastPlanClock = os.clock()
		self:_replan(targetRoot.Position)
	end

	self:_followPath()

	if (targetRoot.Position - self.Root.Position).Magnitude <= self.Config.AttackRange and os.clock() - self.LastAttackClock >= self.Config.AttackCooldown then
		local humanoid = targetCharacter:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			self.LastAttackClock = os.clock()
			humanoid:TakeDamage(self.Config.Damage)
			self.ThreatService:AddDamageThreat(self.Model, self.CurrentTarget, self.Config.Damage * 0.25)
		end
	end
end

function NpcController:_runRetreat()
	if not self.CurrentTarget or not self.CurrentTarget.Character then
		return
	end

	local targetRoot = self.CurrentTarget.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	local delta = self.Root.Position - targetRoot.Position
	local awayDirection = if delta.Magnitude > 0.01 then delta.Unit else Vector3.new(0, 0, -1)
	local retreatPoint = self.Root.Position + awayDirection * self.Config.RetreatDistance

	if os.clock() - self.LastPlanClock > 0.8 then
		self.LastPlanClock = os.clock()
		self:_replan(retreatPoint)
	end

	self:_followPath()
end

function NpcController:_runReturn()
	if os.clock() - self.LastPlanClock > 1 then
		self.LastPlanClock = os.clock()
		self:_replan(self.SpawnPosition)
	end

	self:_followPath()
end

function NpcController:Step(deltaTime)
	if not self.Model.Parent or self.Humanoid.Health <= 0 then
		return
	end

	self:_refreshThreat()

	local scores = UtilityScorer.Score(self:_getContext())
	self.State = UtilityScorer.Pick(scores)

	if self.State == "Patrol" then
		self:_runPatrol()
	elseif self.State == "Chase" then
		self:_runChase()
	elseif self.State == "Retreat" then
		self:_runRetreat()
	elseif self.State == "Return" then
		self:_runReturn()
	end
end

return NpcController
