local UtilityScorer = {}

function UtilityScorer.Score(context)
	local scores = {}

	local targetDistance = context.TargetDistance or math.huge
	local leashDistance = context.LeashDistance or 0
	local healthRatio = context.HealthRatio or 1
	local hasTarget = context.TargetPlayer ~= nil

	if not hasTarget then
		scores.Patrol = 42
	else
		scores.Patrol = 2
	end

	if hasTarget then
		scores.Chase = 72 + math.max(0, 36 - targetDistance)
	else
		scores.Chase = 0
	end

	if healthRatio < 0.18 and hasTarget and targetDistance < 12 then
		scores.Retreat = 88
	else
		scores.Retreat = 0
	end

	if leashDistance > context.MaxLeashDistance then
		scores.Return = 140
	else
		scores.Return = 0
	end

	return scores
end

function UtilityScorer.Pick(scores)
	local bestState = "Patrol"
	local bestScore = -math.huge

	for stateName, score in pairs(scores) do
		if score > bestScore then
			bestState = stateName
			bestScore = score
		end
	end

	return bestState, bestScore
end

return UtilityScorer
