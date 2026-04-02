local UtilityScorer = {}

function UtilityScorer.Score(context)
	local scores = {}

	local targetDistance = context.TargetDistance or math.huge
	local leashDistance = context.LeashDistance or 0
	local healthRatio = context.HealthRatio or 1
	local hasTarget = context.TargetPlayer ~= nil

	scores.Patrol = if not hasTarget then 42 else 2
	scores.Chase = if hasTarget then 72 + math.max(0, 36 - targetDistance) else 0
	scores.Retreat = if healthRatio < 0.18 and hasTarget and targetDistance < 12 then 88 else 0
	scores.Return = if leashDistance > context.MaxLeashDistance then 140 else 0

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
