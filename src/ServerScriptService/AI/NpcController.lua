local Workspace = game:GetService("Workspace")

local NpcAnimationController = require(script.Parent.NpcAnimationController)
local TacticalPlanner = require(script.Parent.TacticalPlanner)
local UtilityScorer = require(script.Parent.UtilityScorer)

local NpcController = {}
NpcController.__index = NpcController

local function getRoot(model)
	return model:FindFirstChild("HumanoidRootPart")
end

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function hashName(name)
	local total = 0
	for index = 1, #name do
		total += string.byte(name, index) * index
	end

	return total
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
	self.AnimationController = NpcAnimationController.new(model, humanoid)
	self.State = "Patrol"
	self.SpawnPosition = root.Position
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
	self.PreferredSide = if hashName(model.Name) % 2 == 0 then "Left" else "Right"
	return self
end

function NpcController:_publishState()
	self.Model:SetAttribute("AiState", self.State)
	self.Model:SetAttribute("RouteMode", self.RouteMode)
	self.Model:SetAttribute("LastPathError", self.LastPathError or "")
	self.Model:SetAttribute("PreferredSide", self.PreferredSide)

	local billboard = self.Model:FindFirstChild("StateBillboard")
	local label = billboard and billboard:FindFirstChildOfClass("TextLabel")
	if label then
		label.Text = ("%s\n%s | %s"):format(self.Model.Name, self.State, self.RouteMode)
	end
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
	local previousTarget = self.CurrentTarget

	self.ThreatService:SeedFromNearbyPlayers(self.Model, self.Root.Position, self.Config.AggroRadius)
	local targetPlayer = self.ThreatService:GetBestTarget(self.Model, self.Root.Position, self.Config.AggroRadius)
	self.CurrentTarget = targetPlayer

	if previousTarget ~= targetPlayer then
		self.RoutePlan = nil
		self.LastPlannedDestination = nil
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

	if clearDirectMove ~= false then
		self.DirectMoveTarget = nil
	end
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
	local ignored = { self.Model }
	if extraIgnored then
		table.insert(ignored, extraIgnored)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	return params
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

	return targetCharacter ~= nil and result.Instance:IsDescendantOf(targetCharacter)
end

function NpcController:_needsReplan(destination, distanceThreshold)
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
	local hasLineOfSight = self:_hasLineOfSight(targetRoot.Position, targetCharacter)
	local needsNewRoute = self.RoutePlan == nil or os.clock() >= self.RoutePlan.ExpiresAt

	if not needsNewRoute and self.RoutePlan.TargetSnapshot then
		local routeDrift = horizontal(targetRoot.Position - self.RoutePlan.TargetSnapshot).Magnitude
		if routeDrift >= self.Config.RouteRefreshDistance then
			needsNewRoute = true
		end
	end

	if not needsNewRoute and self.RoutePlan.Mode == "DirectPressure" and not hasLineOfSight then
		needsNewRoute = true
	end

	if needsNewRoute then
		self.RoutePlan = TacticalPlanner.BuildRoute(self.Root.Position, targetRoot, self.Config, {
			HasLineOfSight = hasLineOfSight,
			PreviousMode = self.RouteMode,
			PreferredSide = self.PreferredSide,
			LastPathError = self.LastPathError,
		})
	end

	self.RouteMode = self.RoutePlan.Mode
	return self.RoutePlan
end

function NpcController:_replan(destination, targetCharacter)
	destination = self:_clampToLeash(destination)
	self.LastPlannedDestination = destination
	self:_clearNavigation()

	local plan, errorMessage = self.PathPlanner:TryPlan(
		self.Model:GetDebugId(),
		self.Root.Position,
		destination,
		self.Config.PathOptions
	)

	if plan then
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
			end
		end)

		return true
	end

	if self.Config.AllowDirectMoveFallback then
		self.DirectMoveTarget = destination
		self.LastWaypointDistance = (destination - self.Root.Position).Magnitude
		self.LastProgressClock = os.clock()
		self.LastPathError = if self:_hasLineOfSight(destination, targetCharacter) then "Direct fallback" else "Blind direct fallback"
		return true
	end

	self.LastPathError = tostring(errorMessage or "No valid path")
	return false
end

function NpcController:_advanceWaypoint()
	local waypoint = self.CurrentWaypoints and self.CurrentWaypoints[self.CurrentWaypointIndex]
	while waypoint and (waypoint.Position - self.Root.Position).Magnitude <= self.Config.WaypointReachedDistance do
		self.CurrentWaypointIndex += 1
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

	self.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	self.JumpStateUntil = math.max(self.JumpStateUntil, os.clock() + duration)
	return true
end

function NpcController:_maybeJumpForWaypoint(waypoint)
	if waypoint.Action ~= Enum.PathWaypointAction.Jump then
		return true
	end

	local rise = waypoint.Position.Y - self.Root.Position.Y
	if rise > self.Config.MaxJumpRise then
		self.LastPathError = ("Jump too high (%.1f)"):format(rise)
		self:_clearNavigation()
		return false
	end

	self:_triggerJump(0.45)
	return true
end

function NpcController:_probeForwardJump(destination, targetCharacter)
	local direction = horizontal(destination - self.Root.Position)
	if direction.Magnitude < 2 then
		return true
	end

	local probeDistance = math.min(self.Config.ForwardJumpProbeDistance, direction.Magnitude)
	local directionUnit = direction.Unit
	local params = self:_createRaycastParams(targetCharacter)
	local lowOrigin = self.Root.Position + Vector3.new(0, 2, 0)
	local lowHit = Workspace:Raycast(lowOrigin, directionUnit * probeDistance, params)
	if not lowHit then
		return true
	end

	if targetCharacter and lowHit.Instance:IsDescendantOf(targetCharacter) then
		return true
	end

	local hitDistance = (lowHit.Position - lowOrigin).Magnitude
	if hitDistance > 4 then
		return true
	end

	local obstacleTop = lowHit.Position.Y
	if lowHit.Instance:IsA("BasePart") then
		obstacleTop = lowHit.Instance.Position.Y + lowHit.Instance.Size.Y * 0.5
	end

	local rise = obstacleTop - self.Root.Position.Y
	if rise > self.Config.MaxJumpRise then
		self.LastPathError = ("Obstacle too tall (%.1f)"):format(rise)
		return false
	end

	local highOrigin = self.Root.Position + Vector3.new(0, self.Config.MaxJumpRise + 2, 0)
	local highHit = Workspace:Raycast(highOrigin, directionUnit * probeDistance, params)
	if highHit and highHit.Instance == lowHit.Instance then
		self.LastPathError = "Obstacle blocks jump lane"
		return false
	end

	if rise > 1 then
		self:_triggerJump(0.5)
	end

	return true
end

function NpcController:_followNavigation(targetCharacter)
	if self.CurrentWaypoints then
		local waypoint = self:_advanceWaypoint()
		if not waypoint then
			return
		end

		if not self:_maybeJumpForWaypoint(waypoint) then
			return
		end

		local riseToWaypoint = waypoint.Position.Y - self.Root.Position.Y
		if riseToWaypoint > 1.25 and not self:_probeForwardJump(waypoint.Position, targetCharacter) then
			self:_clearNavigation()
			return
		end

		local distance = (waypoint.Position - self.Root.Position).Magnitude
		if distance < self.LastWaypointDistance - 0.25 then
			self.LastProgressClock = os.clock()
		end
		self.LastWaypointDistance = distance

		if os.clock() - self.LastProgressClock > self.Config.StuckReplanSeconds then
			self.LastPathError = "Navigation stalled"
			self:_clearNavigation()
			return
		end

		self.Humanoid:MoveTo(waypoint.Position)
		return
	end

	if self.DirectMoveTarget then
		if not self:_probeForwardJump(self.DirectMoveTarget, targetCharacter) then
			self.DirectMoveTarget = nil
			return
		end

		local distance = (self.DirectMoveTarget - self.Root.Position).Magnitude
		if distance < self.LastWaypointDistance - 0.25 then
			self.LastProgressClock = os.clock()
		end
		self.LastWaypointDistance = distance

		if os.clock() - self.LastProgressClock > self.Config.StuckReplanSeconds then
			self.LastPathError = "Direct movement stalled"
			self.DirectMoveTarget = nil
			return
		end

		if distance <= self.Config.WaypointReachedDistance then
			self.DirectMoveTarget = nil
			return
		end

		self.Humanoid:MoveTo(self.DirectMoveTarget)
	end
end

function NpcController:_runPatrol()
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
	local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	local routePlan = self:_resolveRoutePlan(targetCharacter, targetRoot)
	local destination = self:_clampToLeash(routePlan.Destination)

	if self:_needsReplan(destination, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(destination, targetCharacter)
	end

	self:_followNavigation(targetCharacter)

	self:_tryAttackTarget(targetCharacter, targetRoot)
end

function NpcController:_runRetreat()
	if not self.CurrentTarget or not self.CurrentTarget.Character then
		return
	end

	local targetRoot = self.CurrentTarget.Character:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return
	end

	self.RouteMode = "Retreat"

	local delta = self.Root.Position - targetRoot.Position
	local awayDirection = if delta.Magnitude > 0.01 then delta.Unit else Vector3.new(0, 0, -1)
	local retreatPoint = self:_clampToLeash(self.Root.Position + awayDirection * self.Config.RetreatDistance)

	if self:_needsReplan(retreatPoint, self.Config.PathDestinationChangeThreshold) and os.clock() - self.LastPlanClock >= self.Config.PathReplanInterval then
		self.LastPlanClock = os.clock()
		self:_replan(retreatPoint, self.CurrentTarget.Character)
	end

	self:_followNavigation(self.CurrentTarget.Character)
end

function NpcController:_runReturn()
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

	self:_publishState()

	if self.AnimationController then
		local humanoidState = self.Humanoid:GetState()
		local movementState = if os.clock() <= self.JumpStateUntil
			or humanoidState == Enum.HumanoidStateType.Jumping
			or humanoidState == Enum.HumanoidStateType.Freefall
		then
			"Jump"
		else
			"Grounded"
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
	self.Humanoid:MoveTo(self.Root.Position)

	local damage = math.max(1, math.floor(humanoid.MaxHealth * self.Config.AttackHealthFraction + 0.5))
	humanoid:TakeDamage(damage)
	self.ThreatService:AddDamageThreat(self.Model, self.CurrentTarget, damage)
	return true
end

function NpcController:Destroy()
	self:_clearNavigation()

	if self.AnimationController then
		self.AnimationController:Destroy()
		self.AnimationController = nil
	end
end

return NpcController
