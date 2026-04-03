local Players = game:GetService("Players")

local ThreatService = {}
ThreatService.__index = ThreatService

function ThreatService.new()
	local self = setmetatable({}, ThreatService)
	self._entries = {}
	return self
end

function ThreatService:_getNpcState(npcModel)
	local state = self._entries[npcModel]
	if state then
		return state
	end

	state = {}
	self._entries[npcModel] = state
	return state
end

function ThreatService:AddDamageThreat(npcModel, player, amount)
	local npcState = self:_getNpcState(npcModel)
	local current = npcState[player] or 0
	npcState[player] = current + amount * 2
end

function ThreatService:AddProximityThreat(npcModel, player, amount)
	local npcState = self:_getNpcState(npcModel)
	local current = npcState[player] or 0
	npcState[player] = current + amount
end

function ThreatService:Decay(deltaTime)
	local decayFactor = math.max(0, 1 - deltaTime * 0.5)

	for _, npcState in pairs(self._entries) do
		for player, value in pairs(npcState) do
			local nextValue = value * decayFactor
			if nextValue < 0.5 or not player.Parent then
				npcState[player] = nil
			else
				npcState[player] = nextValue
			end
		end
	end
end

function ThreatService:GetBestTarget(npcModel, originPosition, maxDistance)
	local npcState = self._entries[npcModel]
	if not npcState then
		return nil, 0
	end

	local bestPlayer = nil
	local bestScore = 0

	for player, baseThreat in pairs(npcState) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if root and humanoid and humanoid.Health > 0 then
			local distance = (root.Position - originPosition).Magnitude
			if distance <= maxDistance then
				local normalizedProximity = 1 - math.clamp(distance / math.max(maxDistance, 1), 0, 1)
				local score = baseThreat + normalizedProximity * 18
				if score > bestScore then
					bestScore = score
					bestPlayer = player
				end
			end
		end
	end

	return bestPlayer, bestScore
end

function ThreatService:SeedFromNearbyPlayers(npcModel, originPosition, radius)
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			local distance = (root.Position - originPosition).Magnitude
			if distance <= radius then
				local normalizedProximity = 1 - math.clamp(distance / math.max(radius, 1), 0, 1)
				self:AddProximityThreat(npcModel, player, 4 + normalizedProximity * 8)
			end
		end
	end
end

function ThreatService:RemoveNpc(npcModel)
	self._entries[npcModel] = nil
end

return ThreatService
