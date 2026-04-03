local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local ParkourPlanner = {}

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

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

local function quantize(value, step)
	return math.floor((value / step) + 0.5) * step
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

local function getSidePreferenceSign(npcModel)
	local preferredSide = npcModel and npcModel:GetAttribute("PreferredSide")
	if preferredSide == "Left" then
		return -1
	end
	if preferredSide == "Right" then
		return 1
	end
	return 0
end

local function buildNodeKey(instance, position)
	return table.concat({
		tostring(instance),
		tostring(quantize(position.X, 0.35)),
		tostring(quantize(position.Y, 0.35)),
		tostring(quantize(position.Z, 0.35)),
	}, ":")
end

local function buildPositionKey(position)
	return table.concat({
		tostring(quantize(position.X, 0.6)),
		tostring(quantize(position.Y, 0.6)),
		tostring(quantize(position.Z, 0.6)),
	}, ":")
end

local function getSafeLandingPoint(hit, config)
	local instance = hit.Instance
	if not instance or not instance:IsA("BasePart") then
		return nil, 0
	end

	local size = instance.Size
	local halfX = size.X * 0.5
	local halfZ = size.Z * 0.5
	local minHalf = math.min(halfX, halfZ)
	local inset = math.min(
		config.ParkourSurfaceInset,
		math.max(0.08, minHalf * 0.22),
		math.max(0.06, halfX - 0.04),
		math.max(0.06, halfZ - 0.04)
	)

	if halfX <= inset or halfZ <= inset then
		inset = math.max(0.03, minHalf * 0.1)
		if halfX <= inset or halfZ <= inset then
			return nil, 0
		end
	end

	local localHit = instance.CFrame:PointToObjectSpace(hit.Position)
	local safeLocal = Vector3.new(
		math.clamp(localHit.X, -halfX + inset, halfX - inset),
		size.Y * 0.5 + config.ParkourLandingYOffset,
		math.clamp(localHit.Z, -halfZ + inset, halfZ - inset)
	)

	local footprint = math.min(size.X, size.Z)
	return instance.CFrame:PointToWorldSpace(safeLocal), footprint
end

local function shouldKeepNode(landingPoint, originPosition, targetPosition, config)
	local minY = math.min(originPosition.Y, targetPosition.Y) - config.ParkourMaxDrop - 2
	local maxY = math.max(originPosition.Y, targetPosition.Y) + config.ParkourSearchMaxRise + 2
	return landingPoint.Y >= minY and landingPoint.Y <= maxY
end

local function computeSideBias(originPosition, targetPosition, landingPoint, sidePreferenceSign)
	if sidePreferenceSign == 0 then
		return 0
	end

	local toTarget = horizontal(targetPosition - originPosition)
	if toTarget.Magnitude < 0.5 then
		return 0
	end

	local right = Vector3.new(-toTarget.Unit.Z, 0, toTarget.Unit.X)
	local sideDistance = right:Dot(horizontal(landingPoint - originPosition))
	return sideDistance * sidePreferenceSign
end

local function scoreSearchEntryCandidate(candidate, originPosition, targetPosition, config)
	local rise = candidate.Position.Y - originPosition.Y
	local distanceFromOrigin = horizontal(candidate.Position - originPosition).Magnitude
	local directDistance = horizontal(targetPosition - originPosition).Magnitude
	local remainingDistance = horizontal(targetPosition - candidate.Position).Magnitude
	local progress = directDistance - remainingDistance
	local preferredRise = config.ParkourSearchEntryMaxRise or math.min(config.MaxJumpRise, 5.5)
	local risePenalty = math.max(0, rise - preferredRise) * 3.4
	local lowRisePenalty = rise < 0.45 and (0.45 - rise) * 2.2 or 0
	local footprintBonus = math.min(candidate.Footprint or 0, 6) * 0.85
	return progress * 2.15
		+ footprintBonus
		- distanceFromOrigin * 0.28
		- risePenalty
		- lowRisePenalty
end

local function insertNode(nodes, nodesByKey, originPosition, targetPosition, hit, config, sampleBias, sidePreferenceSign)
	if not hit or hit.Normal.Y < config.ParkourSurfaceNormalMin then
		return nil
	end

	local landingPoint, footprint = getSafeLandingPoint(hit, config)
	if not landingPoint or footprint < (config.ParkourMinFootprint or 0.45) then
		return nil
	end

	if not shouldKeepNode(landingPoint, originPosition, targetPosition, config) then
		return nil
	end

	local key = buildNodeKey(hit.Instance, landingPoint)
	if nodesByKey[key] then
		return nil
	end

	local remainingDistance = horizontal(targetPosition - landingPoint).Magnitude
	local directDistance = horizontal(targetPosition - originPosition).Magnitude
	local progress = directDistance - remainingDistance
	local heightDelta = math.abs(targetPosition.Y - landingPoint.Y)
	local riseFromOrigin = math.max(0, landingPoint.Y - originPosition.Y)
	local sideBias = computeSideBias(originPosition, targetPosition, landingPoint, sidePreferenceSign)
	local score = progress * 2.35
		- heightDelta * 0.65
		+ riseFromOrigin * 0.9
		+ math.min(footprint, 8) * 0.8
		+ sideBias * (config.ParkourSideBiasScale or 0.08)
		+ (sampleBias or 0)

	local node = {
		Key = key,
		Instance = hit.Instance,
		Position = landingPoint,
		Footprint = footprint,
		RemainingDistance = remainingDistance,
		HeightDelta = heightDelta,
		SearchScore = score,
	}

	nodesByKey[key] = node
	table.insert(nodes, node)
	return node
end

local function sampleCorridor(nodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	local horizontalDelta = horizontal(targetPosition - originPosition)
	if horizontalDelta.Magnitude < 1 then
		return
	end

	local forward = horizontalDelta.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local searchDistance = math.min(
		config.ParkourSearchDistance,
		horizontalDelta.Magnitude + config.ParkourSearchForwardOvershoot
	)
	local lanes = math.max(
		config.ParkourLateralProbeCount,
		math.floor((config.ParkourSearchWidth / math.max(config.ParkourLateralSpacing, 0.5)) + 0.5)
	)

	local distance = 0
	while distance <= searchDistance do
		for lateralIndex = -lanes, lanes do
			local lateralOffset = lateralIndex * config.ParkourLateralSpacing
			local sampleOrigin = originPosition
				+ Vector3.new(0, config.ParkourSearchHeight, 0)
				+ forward * distance
				+ right * lateralOffset
			local hit = Workspace:Raycast(sampleOrigin, Vector3.new(0, -config.ParkourLandingProbeDepth, 0), params)
			insertNode(nodes, nodesByKey, originPosition, targetPosition, hit, config, 0, sidePreferenceSign)
		end

		distance = distance + config.ParkourSampleStep
	end
end

local function sampleRings(nodes, nodesByKey, sampleCenter, sampleBias, originPosition, targetPosition, params, config, maxRings, sidePreferenceSign)
	local ringRadius = 0
	for ringIndex = 0, maxRings do
		local sampleCount = ringIndex == 0 and 1 or 8
		for sampleIndex = 1, sampleCount do
			local angle = sampleCount == 1 and 0 or ((sampleIndex - 1) / sampleCount) * math.pi * 2
			local offset = Vector3.new(math.cos(angle) * ringRadius, 0, math.sin(angle) * ringRadius)
			local sampleOrigin = sampleCenter + offset + Vector3.new(0, config.ParkourSearchHeight, 0)
			local hit = Workspace:Raycast(sampleOrigin, Vector3.new(0, -config.ParkourLandingProbeDepth, 0), params)
			insertNode(nodes, nodesByKey, originPosition, targetPosition, hit, config, sampleBias, sidePreferenceSign)
		end

		ringRadius = ringRadius + config.ParkourTargetSampleRadius
	end
end

local function projectedHalfExtent(part, direction)
	return math.abs(part.CFrame.RightVector:Dot(direction)) * part.Size.X * 0.5
		+ math.abs(part.CFrame.LookVector:Dot(direction)) * part.Size.Z * 0.5
end

local function sampleWallBypass(nodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	local horizontalDelta = horizontal(targetPosition - originPosition)
	if horizontalDelta.Magnitude < 4 then
		return
	end

	local chestOrigin = originPosition + Vector3.new(0, 3, 0)
	local hit = Workspace:Raycast(chestOrigin, horizontalDelta.Unit * math.min(horizontalDelta.Magnitude, config.ParkourSearchDistance), params)
	if not hit or not hit.Instance or not hit.Instance:IsA("BasePart") then
		return
	end

	local wallNormal = horizontal(hit.Normal)
	if wallNormal.Magnitude < 0.25 then
		return
	end

	wallNormal = wallNormal.Unit
	local tangent = Vector3.new(-wallNormal.Z, 0, wallNormal.X)
	local tangentExtent = projectedHalfExtent(hit.Instance, tangent)
	local normalExtent = projectedHalfExtent(hit.Instance, wallNormal)
	local orderedSides = sidePreferenceSign == 0 and { -1, 1 } or { sidePreferenceSign, -sidePreferenceSign }

	for _, sideSign in ipairs(orderedSides) do
		for _, bypassOffset in ipairs({ 2.5, 5, 8, 11 }) do
			local sampleCenter = hit.Instance.Position
				+ tangent * sideSign * (tangentExtent + bypassOffset)
				+ wallNormal * (normalExtent + 2.25)
			local sampleOrigin = sampleCenter + Vector3.new(0, config.ParkourSearchHeight, 0)
			local groundHit = Workspace:Raycast(sampleOrigin, Vector3.new(0, -config.ParkourLandingProbeDepth, 0), params)
			local bias = sideSign == sidePreferenceSign and 6.5 or 5
			insertNode(nodes, nodesByKey, originPosition, targetPosition, groundHit, config, bias, sidePreferenceSign)
		end
	end
end

local function sampleWallApproach(nodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	local horizontalDelta = horizontal(targetPosition - originPosition)
	if horizontalDelta.Magnitude < 4 then
		return
	end

	local chestOrigin = originPosition + Vector3.new(0, 3, 0)
	local hit = Workspace:Raycast(chestOrigin, horizontalDelta.Unit * math.min(horizontalDelta.Magnitude, config.ParkourSearchDistance), params)
	if not hit then
		return
	end

	local wallNormal = horizontal(hit.Normal)
	if wallNormal.Magnitude < 0.25 then
		return
	end

	wallNormal = wallNormal.Unit
	local tangent = Vector3.new(-wallNormal.Z, 0, wallNormal.X)
	local orderedSides = sidePreferenceSign == 0 and { -1, 1 } or { sidePreferenceSign, -sidePreferenceSign }
	local normalOffsets = { 0.8, 1.2, 1.7, 2.15 }
	local lateralOffsets = { 0, 2.5, 5, 7.5, 10.5 }

	for _, sideSign in ipairs(orderedSides) do
		for _, lateralOffset in ipairs(lateralOffsets) do
			for _, normalOffset in ipairs(normalOffsets) do
				local sampleCenter = hit.Position + tangent * lateralOffset * sideSign + wallNormal * normalOffset
				local bias = sideSign == sidePreferenceSign and 3.5 or 2
				sampleRings(nodes, nodesByKey, sampleCenter, bias, originPosition, targetPosition, params, config, 1, sidePreferenceSign)
			end
		end
	end
end

local function sampleWallClimbLine(
	nodes,
	nodesByKey,
	samplePosition,
	originPosition,
	targetPosition,
	params,
	config,
	sidePreferenceSign,
	sampleBias
)
	local horizontalDelta = horizontal(targetPosition - samplePosition)
	if horizontalDelta.Magnitude < 2 then
		return
	end

	local chestOrigin = samplePosition + Vector3.new(0, 3, 0)
	local hit = Workspace:Raycast(
		chestOrigin,
		horizontalDelta.Unit * math.min(horizontalDelta.Magnitude, config.ParkourSearchDistance),
		params
	)
	if not hit or not hit.Instance or not hit.Instance:IsA("BasePart") then
		return
	end

	local wallNormal = horizontal(hit.Normal)
	if wallNormal.Magnitude < 0.25 then
		return
	end

	wallNormal = wallNormal.Unit
	local tangent = Vector3.new(-wallNormal.Z, 0, wallNormal.X)
	local verticalStep = config.ParkourWallClimbVerticalStep or 2.5
	local minY = math.min(samplePosition.Y, targetPosition.Y) - 0.5
	local maxY = math.max(samplePosition.Y, targetPosition.Y) + 1.5
	local orderedSides = sidePreferenceSign == 0 and { -1, 1 } or { sidePreferenceSign, -sidePreferenceSign }
	local bandCount = math.max(2, math.min(8, math.ceil((maxY - minY) / verticalStep)))

	for bandIndex = 0, bandCount do
		local bandY = minY + bandIndex * verticalStep
		for _, sideSign in ipairs(orderedSides) do
			for _, lateralOffset in ipairs({ 0, 1.8, 3.6, 5.4 }) do
				local sampleCenter = Vector3.new(hit.Position.X, bandY, hit.Position.Z)
					+ wallNormal * 1.35
					+ tangent * lateralOffset * sideSign
				local bias = (sampleBias or 0) + bandIndex * 0.45 - lateralOffset * 0.06
				sampleRings(nodes, nodesByKey, sampleCenter, bias, originPosition, targetPosition, params, config, 1, sidePreferenceSign)
			end
		end
	end
end

local function getGroundedOrigin(originPosition, params, config)
	local localHit = Workspace:Raycast(
		originPosition + Vector3.new(0, 2.75, 0),
		Vector3.new(0, -10, 0),
		params
	)
	if localHit and localHit.Normal.Y >= config.ParkourSurfaceNormalMin then
		local landingPoint = getSafeLandingPoint(localHit, config)
		if landingPoint then
			return landingPoint
		end
	end

	local hit = Workspace:Raycast(
		originPosition + Vector3.new(0, config.ParkourSearchHeight, 0),
		Vector3.new(0, -config.ParkourLandingProbeDepth, 0),
		params
	)

	if hit then
		local landingPoint = getSafeLandingPoint(hit, config)
		if landingPoint then
			return landingPoint
		end
	end

	return originPosition
end

local function trimNodes(nodes, config)
	local limit = math.max(6, config.ParkourNodeLimit)
	if #nodes <= limit then
		return nodes
	end

	local maxRemainingDistance = 0
	for _, node in ipairs(nodes) do
		maxRemainingDistance = math.max(maxRemainingDistance, node.RemainingDistance or 0)
	end

	local byScore = cloneTable(nodes)
	table.sort(byScore, function(a, b)
		return a.SearchScore > b.SearchScore
	end)

	local byHeight = cloneTable(nodes)
	table.sort(byHeight, function(a, b)
		return a.Position.Y > b.Position.Y
	end)

	local byOriginHeight = cloneTable(nodes)
	table.sort(byOriginHeight, function(a, b)
		return a.Position.Y < b.Position.Y
	end)

	local progressBuckets = { {}, {}, {}, {} }
	local bucketCount = #progressBuckets
	for _, node in ipairs(nodes) do
		local normalized = maxRemainingDistance > 0 and ((node.RemainingDistance or 0) / maxRemainingDistance) or 0
		local bucketIndex = math.clamp(math.floor(normalized * bucketCount) + 1, 1, bucketCount)
		table.insert(progressBuckets[bucketIndex], node)
	end

	for _, bucket in ipairs(progressBuckets) do
		table.sort(bucket, function(a, b)
			if a.SearchScore == b.SearchScore then
				return a.Position.Y < b.Position.Y
			end

			return a.SearchScore > b.SearchScore
		end)
	end

	local trimmed = {}
	local seen = {}
	local function appendNode(node)
		if node and not seen[node.Key] and #trimmed < limit then
			seen[node.Key] = true
			table.insert(trimmed, node)
		end
	end

	local scoreLimit = math.max(4, math.floor(limit * 0.38))
	for index = 1, math.min(#byScore, scoreLimit) do
		appendNode(byScore[index])
	end

	local perBucket = math.max(2, math.floor(limit * 0.12))
	for bucketIndex = bucketCount, 1, -1 do
		local bucket = progressBuckets[bucketIndex]
		for index = 1, math.min(#bucket, perBucket) do
			appendNode(bucket[index])
		end
	end

	local originLiftCount = math.max(3, math.floor(limit * 0.16))
	for index = 1, math.min(#byOriginHeight, originLiftCount) do
		appendNode(byOriginHeight[index])
	end

	for index = 1, #byHeight do
		appendNode(byHeight[index])
		if #trimmed >= limit then
			break
		end
	end

	return trimmed
end

local function frontierPriority(node, originPosition, targetPosition)
	local remainingDistance = node.RemainingDistance or horizontal(targetPosition - node.Position).Magnitude
	local climbGain = math.max(0, node.Position.Y - originPosition.Y)
	local searchScore = node.SearchScore or 0
	return remainingDistance - climbGain * 1.35 - searchScore * 0.08
end

local function sampleLocalExpansion(nodes, nodesByKey, frontierNode, originPosition, targetPosition, params, config, sidePreferenceSign, depth)
	local toTarget = horizontal(targetPosition - frontierNode.Position)
	if toTarget.Magnitude < 0.35 then
		return
	end

	local forward = toTarget.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local baseBias = math.max(0.6, 3.6 - depth * 0.55)
	local maxForwardSteps = config.ParkourExpansionMaxForwardSteps or 3
	local lateralSteps = config.ParkourExpansionLateralSteps or 2
	local forwardStep = config.ParkourExpansionForwardStep or 3.4
	local lateralSpacing = config.ParkourExpansionLateralSpacing or 2.25

	sampleRings(nodes, nodesByKey, frontierNode.Position, baseBias + 1.1, originPosition, targetPosition, params, config, 1, sidePreferenceSign)
	sampleWallClimbLine(
		nodes,
		nodesByKey,
		frontierNode.Position,
		originPosition,
		targetPosition,
		params,
		config,
		sidePreferenceSign,
		baseBias + 2
	)

	for forwardIndex = 1, maxForwardSteps do
		local forwardCenter = frontierNode.Position + forward * (forwardIndex * forwardStep)
		sampleRings(
			nodes,
			nodesByKey,
			forwardCenter,
			baseBias - forwardIndex * 0.2,
			originPosition,
			targetPosition,
			params,
			config,
			1,
			sidePreferenceSign
		)

		for lateralIndex = 1, lateralSteps do
			local lateralOffset = lateralIndex * lateralSpacing
			local lateralBias = baseBias - forwardIndex * 0.18 - lateralIndex * 0.12
			sampleRings(
				nodes,
				nodesByKey,
				forwardCenter + right * lateralOffset,
				lateralBias,
				originPosition,
				targetPosition,
				params,
				config,
				1,
				sidePreferenceSign
			)
			sampleRings(
				nodes,
				nodesByKey,
				forwardCenter - right * lateralOffset,
				lateralBias,
				originPosition,
				targetPosition,
				params,
				config,
				1,
				sidePreferenceSign
			)
		end
	end
end

local function expandFrontier(sampledNodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	local originNode = {
		Key = "FrontierOrigin",
		Instance = nil,
		Position = getGroundedOrigin(originPosition, params, config),
		Footprint = 6,
		RemainingDistance = horizontal(targetPosition - originPosition).Magnitude,
		SearchScore = 0,
	}
	local frontier = { originNode }
	local expandedKeys = {}

	for depth = 1, (config.ParkourExpansionDepth or 2) do
		table.sort(frontier, function(a, b)
			return frontierPriority(a, originPosition, targetPosition) < frontierPriority(b, originPosition, targetPosition)
		end)

		local nextFrontier = {}
		local frontierLimit = math.min(#frontier, config.ParkourExpansionFrontierLimit or 6)

		for frontierIndex = 1, frontierLimit do
			local frontierNode = frontier[frontierIndex]
			local frontierKey = buildPositionKey(frontierNode.Position)
			if not expandedKeys[frontierKey] then
				expandedKeys[frontierKey] = true
				local beforeCount = #sampledNodes
				sampleLocalExpansion(
					sampledNodes,
					nodesByKey,
					frontierNode,
					originPosition,
					targetPosition,
					params,
					config,
					sidePreferenceSign,
					depth
				)

				for nodeIndex = beforeCount + 1, #sampledNodes do
					table.insert(nextFrontier, sampledNodes[nodeIndex])
				end
			end
		end

		if #nextFrontier == 0 then
			break
		end

		frontier = nextFrontier
	end
end

local function isGoalNode(node, targetPosition, config)
	local horizontalDistance = horizontal(targetPosition - node.Position).Magnitude
	local heightDelta = math.abs(targetPosition.Y - node.Position.Y)

	if horizontalDistance <= config.ParkourGoalDistance and heightDelta <= config.ParkourGoalHeightTolerance then
		return true
	end

	if node.Position.Y >= targetPosition.Y - config.ParkourGoalHeightTolerance
		and horizontalDistance <= config.ParkourGoalDistance * 1.4
	then
		return true
	end

	return false
end

local function segmentHitsObstacle(startPoint, endPoint, params, fromInstance, toInstance)
	local direction = endPoint - startPoint
	if direction.Magnitude <= 0.05 then
		return false
	end

	local hit = Workspace:Raycast(startPoint, direction, params)
	if not hit then
		return false
	end

	if hit.Instance == fromInstance and (hit.Position - startPoint).Magnitude <= 0.8 then
		return false
	end

	if hit.Instance == toInstance and (hit.Position - endPoint).Magnitude <= 1.2 then
		return false
	end

	return true
end

local function getSampleGroundSupport(samplePoint, params, config)
	local hit = Workspace:Raycast(
		samplePoint + Vector3.new(0, config.ParkourSearchHeight * 0.45, 0),
		Vector3.new(0, -(config.ParkourSearchHeight * 0.45 + config.ParkourLandingProbeDepth), 0),
		params
	)
	if not hit or hit.Normal.Y < config.ParkourSurfaceNormalMin then
		return nil
	end

	local landingPoint = getSafeLandingPoint(hit, config)
	if not landingPoint then
		return nil
	end

	return {
		Position = landingPoint,
		Instance = hit.Instance,
	}
end

local function hasContinuousGroundSupport(fromNode, toNode, params, config)
	if fromNode.Instance == toNode.Instance then
		return true
	end

	local delta = toNode.Position - fromNode.Position
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance <= 1.75 and math.abs(delta.Y) <= (config.ParkourWalkSupportTolerance or 1.1) then
		return true
	end

	local supportTolerance = config.ParkourWalkSupportTolerance or 1.1
	for sampleIndex = 1, 4 do
		local alpha = sampleIndex / 5
		local samplePoint = fromNode.Position:Lerp(toNode.Position, alpha)
		local support = getSampleGroundSupport(samplePoint, params, config)
		if not support then
			return false
		end

		local expectedY = fromNode.Position.Y + delta.Y * alpha
		if math.abs(support.Position.Y - expectedY) > supportTolerance then
			return false
		end
	end

	return true
end

local function hasClearWalkLane(fromNode, toNode, params)
	local startBase = fromNode.Position + Vector3.new(0, 2.2, 0)
	local endBase = toNode.Position + Vector3.new(0, 2.2, 0)
	local startHead = fromNode.Position + Vector3.new(0, 5.5, 0)
	local endHead = toNode.Position + Vector3.new(0, 5.5, 0)

	return not segmentHitsObstacle(startBase, endBase, params, fromNode.Instance, toNode.Instance)
		and not segmentHitsObstacle(startHead, endHead, params, fromNode.Instance, toNode.Instance)
end

local function quadraticBezier(a, b, c, t)
	local ab = a:Lerp(b, t)
	local bc = b:Lerp(c, t)
	return ab:Lerp(bc, t)
end

local function hasClearJumpArc(fromNode, toNode, params, config)
	local delta = toNode.Position - fromNode.Position
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance <= 0.5 then
		return false
	end

	local landingAllowance = math.clamp(toNode.Footprint * 0.4, 1.1, 2.2)
	local apexBoost = math.max(3.2, delta.Y + 2.3, horizontalDistance * 0.18)
	local apex = (fromNode.Position + toNode.Position) * 0.5 + Vector3.new(0, apexBoost, 0)
	local previousPoint = fromNode.Position + Vector3.new(0, 2.8, 0)
	local sampleCount = math.max(4, config.ParkourArcSamples)

	for sampleIndex = 1, sampleCount do
		local alpha = sampleIndex / sampleCount
		local curvePoint = quadraticBezier(
			fromNode.Position + Vector3.new(0, 2.8, 0),
			apex,
			toNode.Position + Vector3.new(0, 2.4, 0),
			alpha
		)

		local blocked = segmentHitsObstacle(previousPoint, curvePoint, params, fromNode.Instance, toNode.Instance)
		if blocked then
			local distanceToEnd = (curvePoint - (toNode.Position + Vector3.new(0, 2.4, 0))).Magnitude
			if distanceToEnd > landingAllowance then
				return false
			end
		end

		previousPoint = curvePoint
	end

	return true
end

local function computeHopProfile(fromPosition, toPosition, config)
	local delta = toPosition - fromPosition
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance <= 0.1 then
		return nil
	end

	local gravity = Workspace.Gravity
	local nominalSpeed = math.clamp(
		config.ParkourNominalHorizontalSpeed or ((config.ParkourHorizontalSpeedMin + config.ParkourHorizontalSpeedMax) * 0.5),
		config.ParkourHorizontalSpeedMin,
		config.ParkourHorizontalSpeedMax
	)
	local minFlightTime = config.ParkourFlightTimeMin or 0.42
	local maxFlightTime = config.ParkourFlightTimeMax or 0.9
	local bestProfile = nil
	local bestScore = math.huge

	for stepIndex = 0, 12 do
		local alpha = stepIndex / 12
		local flightTime = minFlightTime + (maxFlightTime - minFlightTime) * alpha
		local horizontalSpeed = horizontalDistance / flightTime
		local verticalSpeed = (delta.Y + 0.5 * gravity * flightTime * flightTime) / flightTime

		if horizontalSpeed >= config.ParkourHorizontalSpeedMin
			and horizontalSpeed <= config.ParkourHorizontalSpeedMax
			and verticalSpeed >= config.ParkourVerticalSpeedMin
			and verticalSpeed <= config.ParkourVerticalSpeedMax
		then
			local score = math.abs(horizontalSpeed - nominalSpeed) + math.abs(verticalSpeed - config.ParkourVerticalSpeedMin) * 0.02
			if score < bestScore then
				bestScore = score
				bestProfile = {
					FlightTime = flightTime,
					HorizontalSpeed = horizontalSpeed,
					VerticalSpeed = verticalSpeed,
				}
			end
		end
	end

	return bestProfile
end

local function classifyEdge(fromNode, toNode, params, config)
	local delta = toNode.Position - fromNode.Position
	local horizontalDistance = horizontal(delta).Magnitude
	local rise = delta.Y
	local walkStepRise = config.ParkourWalkStepRise or 0.95

	if horizontalDistance <= 0.35 then
		return nil
	end

	if horizontalDistance <= config.ParkourWalkLinkDistance
		and rise <= config.ParkourWalkRise
		and rise >= -config.ParkourWalkDrop
		and (fromNode.Instance == toNode.Instance or math.abs(rise) <= walkStepRise)
		and hasClearWalkLane(fromNode, toNode, params)
		and hasContinuousGroundSupport(fromNode, toNode, params, config)
	then
		return {
			Action = "Walk",
			Cost = horizontalDistance + math.max(0, rise) * 0.75 + math.max(0, -rise) * 0.15,
		}
	end

	local hopDistance = config.ParkourHopLinkDistance or config.AssistJumpDistance
	local hopProfile = computeHopProfile(fromNode.Position, toNode.Position, config)
	local footprintBonus = math.max(0, math.min((toNode.Footprint or 0) - (config.ParkourMinFootprint or 0.45), 8))
	local maxPrecisionRise = math.min(config.MaxJumpRise, (config.ParkourPrecisionHopMaxRise or 4.4) + footprintBonus * 0.4)
	local maxPrecisionDistance = math.min(hopDistance, (config.ParkourPrecisionHopDistance or 8.25) + footprintBonus * 0.35)
	if horizontalDistance <= hopDistance
		and rise >= -(config.ParkourHopDrop or config.ParkourWalkDrop or 4)
		and rise <= maxPrecisionRise
		and horizontalDistance <= maxPrecisionDistance
		and hopProfile ~= nil
		and hasClearJumpArc(fromNode, toNode, params, config)
	then
		local precisionPenalty = math.max(0, 3 - math.min(toNode.Footprint, 3))
		local distancePenalty = math.max(0, horizontalDistance - 4.25) * 0.9
		local risePenalty = math.max(0, rise - 3.25) * 2.35
		return {
			Action = "Hop",
			Cost = horizontalDistance * 1.15
				+ rise * 2.4
				+ config.ParkourHopPenalty
				+ precisionPenalty
				+ distancePenalty
				+ risePenalty
				+ hopProfile.FlightTime * 0.9,
		}
	end

	return nil
end

local function shouldConsiderTransition(fromNode, toNode, targetPosition, config)
	local delta = toNode.Position - fromNode.Position
	local horizontalDistance = horizontal(delta).Magnitude
	if horizontalDistance <= 0.35 then
		return false
	end

	if horizontalDistance > math.max(config.ParkourWalkLinkDistance, config.ParkourHopLinkDistance or config.AssistJumpDistance) + 0.75 then
		return false
	end

	if delta.Y > config.MaxJumpRise + 0.5 then
		return false
	end

	if delta.Y < -math.max(config.ParkourHopDrop or 0, config.ParkourWalkDrop or 0) - 0.5 then
		return false
	end

	local fromRemaining = fromNode.RemainingDistance or horizontal(targetPosition - fromNode.Position).Magnitude
	local toRemaining = toNode.RemainingDistance or horizontal(targetPosition - toNode.Position).Magnitude
	if toRemaining > fromRemaining + (config.ParkourBacktrackAllowance or 4) then
		return false
	end

	return true
end

local function buildAdjacency(nodes, params, config, targetPosition)
	local adjacency = {}
	for index = 1, #nodes do
		adjacency[index] = {}
	end

	for fromIndex = 1, #nodes do
		for toIndex = 1, #nodes do
			if fromIndex ~= toIndex then
				local fromNode = nodes[fromIndex]
				local toNode = nodes[toIndex]
				local edge = nil
				if shouldConsiderTransition(fromNode, toNode, targetPosition, config) then
					edge = classifyEdge(fromNode, toNode, params, config)
				end
				if edge then
					table.insert(adjacency[fromIndex], {
						ToIndex = toIndex,
						Action = edge.Action,
						Cost = edge.Cost,
					})
				end
			end
		end
	end

	return adjacency
end

local function heuristic(node, targetPosition)
	local horizontalDistance = horizontal(targetPosition - node.Position).Magnitude
	local verticalGap = math.max(0, targetPosition.Y - node.Position.Y)
	local heightDelta = math.abs(targetPosition.Y - node.Position.Y)
	return horizontalDistance + verticalGap * 2.1 + heightDelta * 0.35
end

local function reconstructPlan(nodes, cameFrom, bestIndex, targetPosition, config, reachedGoal)
	local sequence = { bestIndex }
	local cursor = bestIndex

	while cameFrom[cursor] do
		cursor = cameFrom[cursor].FromIndex
		table.insert(sequence, 1, cursor)
	end

	if #sequence <= 1 then
		return nil
	end

	local steps = {}
	for index = 2, #sequence do
		local fromNode = nodes[sequence[index - 1]]
		local toNode = nodes[sequence[index]]
		local edge = cameFrom[sequence[index]]
		local precisionRadius = edge.Action == "Hop"
			and math.clamp(toNode.Footprint * 0.35, 1.15, 2.05)
			or math.max(1.6, math.min(3.2, toNode.Footprint * 0.55))

		table.insert(steps, {
			Action = edge.Action,
			LaunchPosition = fromNode.Position,
			LaunchInstance = fromNode.Instance,
			LaunchSurfaceY = fromNode.Position.Y - config.ParkourLandingYOffset,
			Destination = toNode.Position,
			DestinationInstance = toNode.Instance,
			DestinationSurfaceY = toNode.Position.Y - config.ParkourLandingYOffset,
			PrecisionRadius = precisionRadius,
		})
	end

	local mode = "ParkourWalk"
	local entryPosition = nil
	local searchEntryPosition = nil
	local searchEntryMinDistance = math.max(1.6, (config.ParkourSearchArrivalDistance or 2.8) * 0.8)
	for _, step in ipairs(steps) do
		if not entryPosition then
			entryPosition = step.Action == "Hop" and step.LaunchPosition or step.Destination
		elseif step.Action == "Walk" then
			entryPosition = step.Destination
		end

		if not searchEntryPosition then
			local launchDistance = horizontal(step.LaunchPosition - nodes[1].Position).Magnitude
			local destinationDistance = horizontal(step.Destination - nodes[1].Position).Magnitude
			if step.Action == "Walk" then
				if destinationDistance >= searchEntryMinDistance then
					searchEntryPosition = step.Destination
				end
			else
				if launchDistance >= searchEntryMinDistance then
					searchEntryPosition = step.LaunchPosition
				elseif destinationDistance >= searchEntryMinDistance then
					searchEntryPosition = step.Destination
				end
			end
		end

		if step.Action == "Hop" then
			mode = "ParkourHop"
			break
		end
	end

	if not searchEntryPosition then
		searchEntryPosition = entryPosition
	end

	return {
		Mode = mode,
		Steps = steps,
		EntryPosition = entryPosition,
		SearchEntryPosition = searchEntryPosition,
		GoalPosition = nodes[bestIndex].Position,
		GoalDistance = horizontal(targetPosition - nodes[bestIndex].Position).Magnitude,
		GoalHeightDelta = math.abs(targetPosition.Y - nodes[bestIndex].Position.Y),
		ReachedGoal = reachedGoal == true,
	}
end

local function findBestRoute(nodes, adjacency, targetPosition, config)
	local open = { [1] = true }
	local gScore = { [1] = 0 }
	local fScore = { [1] = heuristic(nodes[1], targetPosition) }
	local cameFrom = {}
	local bestIndex = 1
	local bestHeuristic = heuristic(nodes[1], targetPosition)
	local reachedGoal = false

	while next(open) do
		local currentIndex = nil
		local currentScore = math.huge
		for index in pairs(open) do
			local score = fScore[index] or math.huge
			if score < currentScore then
				currentScore = score
				currentIndex = index
			end
		end

		if not currentIndex then
			break
		end

		open[currentIndex] = nil
		local currentNode = nodes[currentIndex]
		local currentHeuristic = heuristic(currentNode, targetPosition)
		if currentHeuristic < bestHeuristic then
			bestHeuristic = currentHeuristic
			bestIndex = currentIndex
		end

		if isGoalNode(currentNode, targetPosition, config) then
			bestIndex = currentIndex
			reachedGoal = true
			break
		end

		for _, edge in ipairs(adjacency[currentIndex]) do
			local tentativeG = (gScore[currentIndex] or math.huge) + edge.Cost
			if tentativeG < (gScore[edge.ToIndex] or math.huge) then
				cameFrom[edge.ToIndex] = {
					FromIndex = currentIndex,
					Action = edge.Action,
				}
				gScore[edge.ToIndex] = tentativeG
				fScore[edge.ToIndex] = tentativeG + heuristic(nodes[edge.ToIndex], targetPosition)
				open[edge.ToIndex] = true
			end
		end
	end

	return reconstructPlan(nodes, cameFrom, bestIndex, targetPosition, config, reachedGoal)
end

function ParkourPlanner.FindRoute(originPosition, targetPosition, targetCharacter, npcModel, config)
	local params = buildRaycastParams(npcModel, targetCharacter)
	local sidePreferenceSign = getSidePreferenceSign(npcModel)
	local nodesByKey = {}
	local sampledNodes = {}

	sampleWallBypass(sampledNodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	sampleCorridor(sampledNodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	sampleRings(sampledNodes, nodesByKey, originPosition, 5, originPosition, targetPosition, params, config, 2, sidePreferenceSign)
	sampleRings(
		sampledNodes,
		nodesByKey,
		(originPosition + targetPosition) * 0.5,
		4,
		originPosition,
		targetPosition,
		params,
		config,
		2,
		sidePreferenceSign
	)
	sampleRings(sampledNodes, nodesByKey, targetPosition, 5, originPosition, targetPosition, params, config, config.ParkourTargetSampleRings, sidePreferenceSign)
	sampleWallApproach(sampledNodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	expandFrontier(sampledNodes, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)

	sampledNodes = trimNodes(sampledNodes, config)

	local originNode = {
		Key = "Origin",
		Instance = nil,
		Position = getGroundedOrigin(originPosition, params, config),
		Footprint = 6,
	}

	local nodes = { originNode }
	for _, node in ipairs(sampledNodes) do
		table.insert(nodes, cloneTable(node))
	end

	if #nodes <= 1 then
		return nil
	end

	local adjacency = buildAdjacency(nodes, params, config, targetPosition)
	local plan = findBestRoute(nodes, adjacency, targetPosition, config)
	if not plan or not plan.Steps or #plan.Steps == 0 then
		return nil
	end

	plan.OriginSnapshot = originPosition
	plan.TargetSnapshot = targetPosition
	return plan
end

function ParkourPlanner.FindSearchAnchor(originPosition, targetPosition, targetCharacter, npcModel, config)
	local params = buildRaycastParams(npcModel, targetCharacter)
	local sidePreferenceSign = getSidePreferenceSign(npcModel)
	local nodesByKey = {}
	local candidates = {}

	sampleWallBypass(candidates, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	sampleWallApproach(candidates, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	sampleCorridor(candidates, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)
	sampleRings(candidates, nodesByKey, originPosition, 2, originPosition, targetPosition, params, config, 1, sidePreferenceSign)
	sampleRings(candidates, nodesByKey, targetPosition, 3, originPosition, targetPosition, params, config, 2, sidePreferenceSign)
	expandFrontier(candidates, nodesByKey, originPosition, targetPosition, params, config, sidePreferenceSign)

	if #candidates == 0 then
		return nil
	end

	candidates = trimNodes(candidates, config)
	local originNode = {
		Key = "Origin",
		Instance = nil,
		Position = getGroundedOrigin(originPosition, params, config),
		Footprint = 6,
	}

	local nodes = { originNode }
	for _, node in ipairs(candidates) do
		table.insert(nodes, cloneTable(node))
	end

	local adjacency = buildAdjacency(nodes, params, config, targetPosition)
	local route = findBestRoute(nodes, adjacency, targetPosition, config)
	local maxSearchRise = config.ParkourSearchEntryMaxRise or math.min(config.MaxJumpRise, 5.5)
	if route then
		local entryDistance = route.SearchEntryPosition and horizontal(route.SearchEntryPosition - originPosition).Magnitude or math.huge
		local entryRise = route.SearchEntryPosition and (route.SearchEntryPosition.Y - originPosition.Y) or math.huge
		if route.SearchEntryPosition
			and entryDistance > math.max(1.15, (config.ParkourSearchArrivalDistance or 2.8) * 0.55)
			and entryRise <= maxSearchRise + 0.6
		then
			return route.SearchEntryPosition
		end
		if route.GoalPosition then
			local goalDistance = horizontal(route.GoalPosition - originPosition).Magnitude
			local goalRise = route.GoalPosition.Y - originPosition.Y
			if goalDistance > math.max(1.3, (config.ParkourSearchArrivalDistance or 2.8) * 0.6)
				and goalRise <= maxSearchRise + 0.6
			then
				return route.GoalPosition
			end
		end
	end

	table.sort(candidates, function(a, b)
		return scoreSearchEntryCandidate(a, originPosition, targetPosition, config) > scoreSearchEntryCandidate(b, originPosition, targetPosition, config)
	end)

	for _, candidate in ipairs(candidates) do
		local rise = candidate.Position.Y - originPosition.Y
		if rise >= 0.45 and rise <= maxSearchRise + 0.6 then
			return candidate.Position
		end
	end

	return candidates[1].Position
end

return ParkourPlanner
