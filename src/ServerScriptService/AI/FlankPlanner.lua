local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local FlankPlanner = {}

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function safeUnit(vector, fallback)
	if vector.Magnitude > 0.05 then
		return vector.Unit
	end

	return fallback
end

local function quantize(value, step)
	return math.floor((value / step) + 0.5) * step
end

local function buildPositionKey(position)
	return table.concat({
		tostring(quantize(position.X, 1.25)),
		tostring(quantize(position.Y, 1.25)),
		tostring(quantize(position.Z, 1.25)),
	}, ":")
end

local function clampDot(value)
	return math.clamp(value, -1, 1)
end

local function angleBetween(left, right)
	local leftUnit = horizontal(left)
	local rightUnit = horizontal(right)
	if leftUnit.Magnitude <= 0.05 or rightUnit.Magnitude <= 0.05 then
		return 0
	end

	return math.deg(math.acos(clampDot(leftUnit.Unit:Dot(rightUnit.Unit))))
end

local function buildRaycastParams(npcModel, targetCharacter)
	local ignored = {}
	for _, taggedNpc in ipairs(CollectionService:GetTagged("CombatNpc")) do
		table.insert(ignored, taggedNpc)
	end

	if npcModel then
		table.insert(ignored, npcModel)
	end

	if targetCharacter then
		table.insert(ignored, targetCharacter)
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignored
	return params
end

local function projectToGround(samplePosition, params)
	local origin = samplePosition + Vector3.new(0, 24, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -72, 0), params)
	if not result or result.Normal.Y < 0.6 then
		return nil
	end

	local instance = result.Instance
	if not instance or not instance:IsA("BasePart") then
		return nil
	end

	local halfX = instance.Size.X * 0.5
	local halfZ = instance.Size.Z * 0.5
	local localHit = instance.CFrame:PointToObjectSpace(result.Position)
	local inset = math.max(0.12, math.min(0.5, math.min(halfX, halfZ) * 0.18))
	if halfX <= inset or halfZ <= inset then
		return nil
	end

	local safeLocal = Vector3.new(
		math.clamp(localHit.X, -halfX + inset, halfX - inset),
		instance.Size.Y * 0.5 + 0.1,
		math.clamp(localHit.Z, -halfZ + inset, halfZ - inset)
	)

	return instance.CFrame:PointToWorldSpace(safeLocal)
end

local function estimateOpenness(position, params)
	local directions = {
		Vector3.new(1, 0, 0),
		Vector3.new(-1, 0, 0),
		Vector3.new(0, 0, 1),
		Vector3.new(0, 0, -1),
		Vector3.new(1, 0, 1).Unit,
		Vector3.new(1, 0, -1).Unit,
		Vector3.new(-1, 0, 1).Unit,
		Vector3.new(-1, 0, -1).Unit,
	}

	local origin = position + Vector3.new(0, 2.25, 0)
	local maxDistance = 18
	local totalFraction = 0

	for _, direction in ipairs(directions) do
		local hit = Workspace:Raycast(origin, direction * maxDistance, params)
		local distance = hit and (hit.Position - origin).Magnitude or maxDistance
		totalFraction = totalFraction + math.clamp(distance / maxDistance, 0, 1)
	end

	return totalFraction / #directions
end

local function getTargetMotionDirection(npcPosition, targetRoot, context)
	local contextDirection = context and context.TargetMotionDirection
	if contextDirection and contextDirection.Magnitude > 0.1 then
		return contextDirection.Unit
	end

	local velocity = horizontal(targetRoot.AssemblyLinearVelocity)
	if velocity.Magnitude > 1.2 then
		return velocity.Unit
	end

	local look = horizontal(targetRoot.CFrame.LookVector)
	if look.Magnitude > 0.2 then
		return look.Unit
	end

	local remembered = context and context.LastSeenDirection
	if remembered and remembered.Magnitude > 0.1 then
		return remembered.Unit
	end

	return safeUnit(horizontal(targetRoot.Position - npcPosition), Vector3.new(0, 0, -1))
end

local function buildRawProbeSamples(anchorPosition, forward, right, preferredSide, config)
	local samples = {}
	local lateralOffsets = config.FlankProbeLateralOffsets or { 0, 8, -8, 14, -14 }
	local forwardDistances = config.FlankProbeDistances or { 10, 18, 28, 38 }
	local sideMultiplier = preferredSide == "Left" and -1 or 1

	for _, forwardDistance in ipairs(forwardDistances) do
		for _, lateralOffset in ipairs(lateralOffsets) do
			local sideBiasedOffset = lateralOffset == 0 and 0 or lateralOffset * sideMultiplier
			table.insert(samples, anchorPosition + forward * forwardDistance + right * sideBiasedOffset)
		end
	end

	return samples
end

local function addMazeCandidate(candidates, seen, playerTravelDistance, waypointPosition, hypothesis, params, forward, right, metadata)
	local groundedPosition = projectToGround(waypointPosition, params)
	if not groundedPosition then
		return
	end

	local key = buildPositionKey(groundedPosition)
	if seen[key] then
		return
	end

	seen[key] = true
	local offsetFromAnchor = horizontal(groundedPosition - metadata.AnchorPosition)
	local forwardAlignment = offsetFromAnchor.Magnitude > 0.1 and safeUnit(offsetFromAnchor, forward):Dot(forward) or 0
	local lateralAlignment = offsetFromAnchor.Magnitude > 0.1 and math.abs(safeUnit(offsetFromAnchor, right):Dot(right)) or 0
	local openness = estimateOpenness(groundedPosition, params)

	table.insert(candidates, {
		Hypothesis = hypothesis,
		Position = groundedPosition,
		PlayerTravelDistance = playerTravelDistance,
		ForwardAlignment = forwardAlignment,
		LateralAlignment = lateralAlignment,
		Openness = openness,
		StructureBonus = metadata.StructureBonus or 0,
		TurnAngle = metadata.TurnAngle or 0,
	})
end

local function collectMazeCandidates(rawSample, waypoints, totalDistance, params, forward, right, config, seen, candidates, anchorPosition)
	local lookahead = math.min(#waypoints, config.FlankWaypointLookahead or 6)
	local previousPosition = anchorPosition
	local travelled = 0

	for index = 1, lookahead do
		local waypoint = waypoints[index]
		local currentPosition = waypoint.Position
		travelled = travelled + (currentPosition - previousPosition).Magnitude

		local nextPosition = index < #waypoints and waypoints[index + 1].Position or nil
		local turnAngle = nextPosition and angleBetween(currentPosition - previousPosition, nextPosition - currentPosition) or 0
		local openness = estimateOpenness(currentPosition, params)
		local isCorner = turnAngle >= (config.FlankCornerAngle or 26)
		local isIntersection = openness >= (config.FlankIntersectionOpenness or 0.52)
		local isExit = index == lookahead or math.abs(travelled - totalDistance) <= 2
		local hypothesis = "Corridor"
		local structureBonus = 0

		if isIntersection then
			hypothesis = "Intersection"
			structureBonus = 1.1
		elseif isCorner then
			hypothesis = "Corner"
			structureBonus = 0.8
		elseif isExit then
			hypothesis = "Exit"
			structureBonus = 0.6
		elseif rawSample.ForwardBias > 0 then
			hypothesis = "Lane"
			structureBonus = 0.35
		end

		if travelled >= (config.FlankMinPlayerTravel or 6)
			and travelled <= (config.FlankMaxPlayerTravel or 90)
			and (isCorner or isIntersection or isExit or rawSample.ForwardBias > 0)
		then
			addMazeCandidate(candidates, seen, travelled, currentPosition, hypothesis, params, forward, right, {
				AnchorPosition = anchorPosition,
				StructureBonus = structureBonus,
				TurnAngle = turnAngle,
			})
		end

		previousPosition = currentPosition
	end
end

local function measureTravel(pathPlanner, agentId, origin, destination, pathOptions)
	local pathLength, errorMessage, waypoints = pathPlanner:Measure(agentId, origin, destination, pathOptions)
	if pathLength then
		return pathLength, nil, waypoints
	end

	return nil, errorMessage, nil
end

local function normalizeLikelihoods(candidates)
	local total = 0
	for _, candidate in ipairs(candidates) do
		total = total + math.max(candidate.RawLikelihood or 0, 0.05)
	end

	if total <= 0 then
		total = 1
	end

	for _, candidate in ipairs(candidates) do
		candidate.LikelihoodPercent = math.floor(((math.max(candidate.RawLikelihood or 0, 0.05) / total) * 100) + 0.5)
	end
end

function FlankPlanner.FindBestRoute(npcPosition, targetRoot, targetCharacter, npcModel, config, pathPlanner, context)
	context = context or {}
	if not pathPlanner then
		return nil
	end

	local planningAnchor = context.SearchAnchorPosition or targetRoot.Position
	local params = buildRaycastParams(npcModel, targetCharacter)
	local preferredSide = context.PreferredSide or "Right"
	local forward = getTargetMotionDirection(npcPosition, targetRoot, context)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local rawSamples = buildRawProbeSamples(planningAnchor, forward, right, preferredSide, config)
	local directNpcPathLength = measureTravel(
		pathPlanner,
		("%s:flank:direct"):format(npcModel.Name),
		npcPosition,
		planningAnchor,
		config.PathOptions
	)

	if not directNpcPathLength then
		return nil
	end

	local seen = {}
	local candidates = {}

	for sampleIndex, samplePosition in ipairs(rawSamples) do
		local groundedSample = projectToGround(samplePosition, params)
		if groundedSample then
			local playerTravelDistance, _, playerWaypoints = measureTravel(
				pathPlanner,
				("%s:flank:player:%d"):format(npcModel.Name, sampleIndex),
				planningAnchor,
				groundedSample,
				config.PathOptions
			)

			if playerTravelDistance and playerWaypoints and #playerWaypoints > 0 then
				local forwardBias = math.max(0, safeUnit(horizontal(groundedSample - planningAnchor), forward):Dot(forward))
				collectMazeCandidates({
					ForwardBias = forwardBias,
				}, playerWaypoints, playerTravelDistance, params, forward, right, config, seen, candidates, planningAnchor)
			end
		end
	end

	if #candidates == 0 then
		return nil
	end

	local evaluated = {}
	for candidateIndex, candidate in ipairs(candidates) do
		local npcTravelDistance = measureTravel(
			pathPlanner,
			("%s:flank:npc:%d"):format(npcModel.Name, candidateIndex),
			npcPosition,
			candidate.Position,
			config.PathOptions
		)

		if npcTravelDistance then
			local interceptMargin = candidate.PlayerTravelDistance - npcTravelDistance
			local directPathGain = directNpcPathLength - npcTravelDistance
			local clearCatch = interceptMargin >= -(config.FlankCatchMargin or 1.5)
			local strongIntercept = interceptMargin >= (config.FlankStrongLead or 6)
			local clearPathGain = directPathGain >= (config.FlankMinPathGain or 4)
			local manageableDetour = npcTravelDistance <= directNpcPathLength + (config.FlankDirectCostAllowance or 10)

			if clearCatch and manageableDetour and (strongIntercept or clearPathGain) then
				local rawLikelihood = math.max(
					0.08,
					1
						+ math.max(0, candidate.ForwardAlignment) * 1.45
						+ candidate.LateralAlignment * 0.35
						+ candidate.Openness * 0.75
						+ candidate.StructureBonus
				)

				local priorityScore = interceptMargin * 5.4
					+ math.max(directPathGain, -4) * 2.6
					+ math.max(candidate.ForwardAlignment, -0.2) * 6.5
					+ candidate.Openness * 7.5
					+ candidate.StructureBonus * 5
					+ math.min(candidate.TurnAngle, 75) * 0.05

				table.insert(evaluated, {
					Hypothesis = candidate.Hypothesis,
					Position = candidate.Position,
					RawLikelihood = rawLikelihood,
					NpcTravelDistance = npcTravelDistance,
					TargetTravelDistance = candidate.PlayerTravelDistance,
					InterceptMargin = interceptMargin,
					PriorityScore = priorityScore,
					DirectPathGain = directPathGain,
				})
			end
		end
	end

	if #evaluated == 0 then
		return nil
	end

	normalizeLikelihoods(evaluated)
	table.sort(evaluated, function(left, rightCandidate)
		if left.PriorityScore == rightCandidate.PriorityScore then
			return left.LikelihoodPercent > rightCandidate.LikelihoodPercent
		end

		return left.PriorityScore > rightCandidate.PriorityScore
	end)

	local best = evaluated[1]
	return {
		Mode = "CutoffIntercept",
		Destination = best.Position,
		ExpiresAt = os.clock() + (config.FlankRouteLifetime or 1.8),
		TargetSnapshot = planningAnchor,
		PriorityScore = best.PriorityScore,
		LikelihoodPercent = best.LikelihoodPercent,
		Hypothesis = best.Hypothesis,
		InterceptMargin = best.InterceptMargin,
		NpcTravelDistance = best.NpcTravelDistance,
		TargetTravelDistance = best.TargetTravelDistance,
		DirectPathGain = best.DirectPathGain,
	}
end

return FlankPlanner
