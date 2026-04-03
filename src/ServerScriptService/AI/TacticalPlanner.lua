local TacticalPlanner = {}

local function horizontal(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function safeUnit(vector, fallback)
	if vector.Magnitude > 0.01 then
		return vector.Unit
	end

	return fallback
end

local function hasToken(haystack, needle)
	return string.find(haystack, needle, 1, true) ~= nil
end

local function getSideToken(mode)
	if hasToken(mode, "Left") then
		return "Left"
	end

	if hasToken(mode, "Right") then
		return "Right"
	end

	return "Neutral"
end

local function choose(condition, whenTrue, whenFalse)
	if condition then
		return whenTrue
	end

	return whenFalse
end

local function repeatPenalty(mode, previousMode)
	if not previousMode or previousMode == "" then
		return 1
	end

	if mode == previousMode then
		return 0.96
	end

	local modeIsLeft = hasToken(mode, "Left")
	local previousIsLeft = hasToken(previousMode, "Left")
	if modeIsLeft and previousIsLeft then
		return 0.98
	end

	local modeIsRight = hasToken(mode, "Right")
	local previousIsRight = hasToken(previousMode, "Right")
	if modeIsRight and previousIsRight then
		return 0.98
	end

	return 1
end

local function weightedPick(options)
	local totalWeight = 0
	for _, option in ipairs(options) do
		totalWeight = totalWeight + option.Weight
	end

	local roll = math.random() * totalWeight
	local cumulative = 0

	for _, option in ipairs(options) do
		cumulative = cumulative + option.Weight
		if roll <= cumulative then
			return option
		end
	end

	return options[#options]
end

local function addOption(options, mode, destination, weight)
	if weight <= 0 then
		return
	end

	table.insert(options, {
		Mode = mode,
		Destination = destination,
		Weight = weight,
	})
end

function TacticalPlanner.BuildRoute(npcPosition, targetRoot, config, context)
	context = context or {}

	local targetPosition = targetRoot.Position
	local targetVelocity = horizontal(targetRoot.AssemblyLinearVelocity)
	local offsetToTarget = horizontal(targetPosition - npcPosition)
	local distance = offsetToTarget.Magnitude
	local approachDirection = safeUnit(offsetToTarget, Vector3.new(0, 0, -1))
	local motionDirection = safeUnit(targetVelocity, approachDirection)
	local right = Vector3.new(-motionDirection.Z, 0, motionDirection.X)
	local backward = -motionDirection
	local targetSpeed = targetVelocity.Magnitude
	local verticalDelta = targetPosition.Y - npcPosition.Y
	local hasLineOfSight = context.HasLineOfSight ~= false
	local preferredSide = context.PreferredSide or "Either"
	local previousSide = getSideToken(context.PreviousMode or "")
	local flankCommitBroken = context.LastPathError == "Path blocked"
		or context.LastPathError == "Navigation stalled"
		or context.LastPathError == "Direct movement stalled"

	local flankOffset = math.clamp(distance * 0.4, config.MinFlankOffset, config.MaxFlankOffset)
	local wideOffset = math.clamp(distance * 0.7, config.MinWideOffset, config.MaxWideOffset)
	local cutoffDepth = math.clamp(distance * 0.3, config.MinCutoffDepth, config.MaxCutoffDepth)
	local backdoorDepth = math.clamp(distance * 0.55, config.MinBackdoorDepth, config.MaxBackdoorDepth)
	local pinchDepth = math.clamp(distance * 0.22, config.MinPincerDepth, config.MaxPincerDepth)
	local leadSeconds = math.clamp(distance / config.InterceptDistanceDivisor, config.MinInterceptSeconds, config.MaxInterceptSeconds)
	local jitterScale = math.max(0, math.floor(config.RouteJitterMax * 100 + 0.5))
	local routeJitter = math.random(-jitterScale, jitterScale) / 100
	local pressureCommitDistance = math.max(config.DirectEngageDistance + 4, config.FlankMinimumDistance * 0.72)

	if distance <= config.DirectEngageDistance
		and hasLineOfSight
		and math.abs(verticalDelta) <= config.ParkourGoalHeightTolerance
	then
		return {
			Mode = "DirectPressure",
			Destination = targetPosition,
			ExpiresAt = os.clock() + 0.6,
			TargetSnapshot = targetPosition,
		}
	end

	local options = {}

	addOption(options, "DirectPressure", targetPosition, choose(hasLineOfSight, 18, 8))
	addOption(options, "InterceptLead", targetPosition + targetVelocity * leadSeconds, choose(targetSpeed > 3, 26, 10))
	addOption(options, "FlankLeft", targetPosition - right * flankOffset + motionDirection * 6, 18)
	addOption(options, "FlankRight", targetPosition + right * flankOffset + motionDirection * 6, 18)
	addOption(options, "WideLeft", targetPosition - right * wideOffset - motionDirection * cutoffDepth, choose(distance > 15, 17, 6))
	addOption(options, "WideRight", targetPosition + right * wideOffset - motionDirection * cutoffDepth, choose(distance > 15, 17, 6))
	addOption(options, "BackdoorLeft", targetPosition - right * (wideOffset * 0.85) + backward * backdoorDepth, choose(distance > 11, 14, 6))
	addOption(options, "BackdoorRight", targetPosition + right * (wideOffset * 0.85) + backward * backdoorDepth, choose(distance > 11, 14, 6))
	addOption(options, "PinchLeft", targetPosition + motionDirection * pinchDepth - right * (flankOffset * 0.65), choose(distance < 24, 13, 5))
	addOption(options, "PinchRight", targetPosition + motionDirection * pinchDepth + right * (flankOffset * 0.65), choose(distance < 24, 13, 5))
	addOption(options, "Cutoff", targetPosition + motionDirection * cutoffDepth, choose(distance > 12 or targetSpeed > 2, 18, 7))

	for _, option in ipairs(options) do
		option.Weight = option.Weight * repeatPenalty(option.Mode, context.PreviousMode)

		if preferredSide == "Left" and hasToken(option.Mode, "Left") then
			option.Weight = option.Weight * 1.15
		elseif preferredSide == "Right" and hasToken(option.Mode, "Right") then
			option.Weight = option.Weight * 1.15
		end

		if previousSide ~= "Neutral" and not flankCommitBroken then
			local optionSide = getSideToken(option.Mode)
			if optionSide == previousSide then
				option.Weight = option.Weight * 1.6
			elseif optionSide ~= "Neutral" then
				option.Weight = option.Weight * 0.24
			end
		end

		if not hasLineOfSight then
			if option.Mode == "DirectPressure" then
				option.Weight = option.Weight * 0.22
			elseif option.Mode == "InterceptLead" then
				option.Weight = option.Weight * 0.7
			elseif hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor") then
				option.Weight = option.Weight * 1.7
			elseif hasToken(option.Mode, "Flank") or hasToken(option.Mode, "Pinch") then
				option.Weight = option.Weight * 1.35
			elseif option.Mode == "Cutoff" then
				option.Weight = option.Weight * 1.2
			end
		end

		if targetSpeed < 1.5 then
			if option.Mode == "InterceptLead" then
				option.Weight = option.Weight * 0.4
			elseif option.Mode == "Cutoff" then
				option.Weight = option.Weight * 0.7
			end
		elseif targetSpeed > 7 then
			if option.Mode == "InterceptLead" or option.Mode == "Cutoff" then
				option.Weight = option.Weight * 1.25
			end
		end

		if distance < pressureCommitDistance then
			if option.Mode == "DirectPressure" then
				option.Weight = option.Weight * 2.7
			elseif option.Mode == "InterceptLead" then
				option.Weight = option.Weight * 1.3
			elseif option.Mode == "Cutoff" then
				option.Weight = option.Weight * 0.95
			elseif hasToken(option.Mode, "Flank")
				or hasToken(option.Mode, "Wide")
				or hasToken(option.Mode, "Backdoor")
				or hasToken(option.Mode, "Pinch")
			then
				option.Weight = option.Weight * 0.12
			end
		end

		if distance < config.FlankMinimumDistance then
			if option.Mode == "DirectPressure" then
				option.Weight = option.Weight * 2.2
			elseif option.Mode == "InterceptLead" then
				option.Weight = option.Weight * 1.25
			elseif option.Mode == "Cutoff" then
				option.Weight = option.Weight * 0.85
			elseif hasToken(option.Mode, "Flank")
				or hasToken(option.Mode, "Wide")
				or hasToken(option.Mode, "Backdoor")
				or hasToken(option.Mode, "Pinch")
			then
				option.Weight = option.Weight * 0.08
			end
		elseif distance < 10 then
			if hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor") then
				option.Weight = option.Weight * 1.25
			elseif option.Mode == "DirectPressure" then
				option.Weight = option.Weight * 0.8
			end
		elseif distance > 30 then
			if option.Mode == "DirectPressure" or option.Mode == "InterceptLead" then
				option.Weight = option.Weight * 1.15
			elseif hasToken(option.Mode, "Pinch") then
				option.Weight = option.Weight * 0.55
			end
		end

		if context.LastPathError == "Path blocked" and (hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor")) then
			option.Weight = option.Weight * 1.35
		end

		if verticalDelta > 3 then
			if option.Mode == "DirectPressure" or option.Mode == "InterceptLead" or option.Mode == "Cutoff" then
				option.Weight = option.Weight * 1.3
			elseif hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor") then
				option.Weight = option.Weight * 0.6
			end
		end

		if verticalDelta > config.AssistJumpRiseThreshold and not hasLineOfSight then
			if option.Mode == "DirectPressure" then
				option.Weight = option.Weight * 0.12
			elseif option.Mode == "InterceptLead" or option.Mode == "Cutoff" then
				option.Weight = option.Weight * 0.45
			elseif hasToken(option.Mode, "Flank") then
				option.Weight = option.Weight * 1.5
			elseif hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor") then
				option.Weight = option.Weight * 1.85
			end
		end

		if hasLineOfSight and math.abs(verticalDelta) <= config.ParkourGoalHeightTolerance then
			if distance <= 26 then
				if option.Mode == "DirectPressure" then
					option.Weight = option.Weight * 3.1
				elseif option.Mode == "InterceptLead" then
					option.Weight = option.Weight * 1.2
				elseif option.Mode == "Cutoff" then
					option.Weight = option.Weight * 0.5
				elseif hasToken(option.Mode, "Flank") then
					option.Weight = option.Weight * 0.16
				elseif hasToken(option.Mode, "Wide") or hasToken(option.Mode, "Backdoor") or hasToken(option.Mode, "Pinch") then
					option.Weight = option.Weight * 0.05
				end
			end
		end
	end

	local chosen = weightedPick(options)
	local jitterVector = right * routeJitter
	local lifetimeScale = 1
	if hasToken(chosen.Mode, "Flank")
		or hasToken(chosen.Mode, "Wide")
		or hasToken(chosen.Mode, "Backdoor")
		or hasToken(chosen.Mode, "Pinch")
	then
		lifetimeScale = 1.35
	elseif chosen.Mode == "DirectPressure" then
		lifetimeScale = 0.8
	end

	local baseLifetime = math.random(
		math.floor(config.RouteLifetimeMin * 100 + 0.5),
		math.floor(config.RouteLifetimeMax * 100 + 0.5)
	) / 100
	return {
		Mode = chosen.Mode,
		Destination = chosen.Destination + jitterVector,
		ExpiresAt = os.clock() + baseLifetime * lifetimeScale,
		TargetSnapshot = targetPosition,
	}
end

return TacticalPlanner
