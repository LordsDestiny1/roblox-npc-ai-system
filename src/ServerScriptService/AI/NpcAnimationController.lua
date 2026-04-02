local NpcAnimationController = {}
NpcAnimationController.__index = NpcAnimationController

local DEFAULT_ANIMATION_IDS = {
	Idle = {
		"rbxassetid://507766666",
		"rbxassetid://507766951",
	},
	Walk = {
		"rbxassetid://507777826",
	},
	Jump = {
		"rbxassetid://507765000",
	},
}

local function cloneList(values)
	local result = {}
	for index, value in ipairs(values or {}) do
		result[index] = value
	end
	return result
end

local function ensureAnimator(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		return animator
	end

	animator = Instance.new("Animator")
	animator.Parent = humanoid
	return animator
end

local function createAnimation(animationId, name)
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = animationId
	return animation
end

local function collectAnimationIdsFromAnimate(model, stateName)
	local animate = model:FindFirstChild("Animate")
	if not animate then
		return nil
	end

	local folder = animate:FindFirstChild(string.lower(stateName))
	if not folder then
		folder = animate:FindFirstChild(stateName)
	end
	if not folder then
		return nil
	end

	local ids = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Animation") and child.AnimationId ~= "" then
			table.insert(ids, child.AnimationId)
		end
	end

	if #ids == 0 then
		return nil
	end

	return ids
end

local function loadTrack(animator, animationId, stateName, index)
	local animation = createAnimation(animationId, stateName .. tostring(index))
	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if not ok then
		return nil, tostring(trackOrError)
	end

	local track = trackOrError
	if stateName == "Jump" then
		track.Priority = Enum.AnimationPriority.Action
	else
		track.Priority = Enum.AnimationPriority.Movement
	end
	track.Looped = stateName ~= "Jump"
	return track, nil
end

local function appendSource(sourcesToTry, sourceName, ids)
	if ids and #ids > 0 then
		table.insert(sourcesToTry, {
			Source = sourceName,
			Ids = ids,
		})
	end
end

local function loadTracksForState(model, animator, stateName)
	local sourcesToTry = {}
	local attributeName = stateName .. "AnimationId"
	local attributeValue = model:GetAttribute(attributeName)
	if type(attributeValue) == "string" and attributeValue ~= "" then
		appendSource(sourcesToTry, "Attribute", { attributeValue })
	end

	appendSource(sourcesToTry, "Animate", collectAnimationIdsFromAnimate(model, stateName))
	appendSource(sourcesToTry, "Default", cloneList(DEFAULT_ANIMATION_IDS[stateName]))

	local lastError = nil

	for _, candidate in ipairs(sourcesToTry) do
		local tracks = {}
		for index, animationId in ipairs(candidate.Ids or {}) do
			local track, errorMessage = loadTrack(animator, animationId, stateName, index)
			if track then
				table.insert(tracks, track)
			else
				lastError = errorMessage
			end
		end

		if #tracks > 0 then
			return tracks, candidate.Source, lastError
		end
	end

	return {}, "Failed", lastError
end

function NpcAnimationController.new(model, humanoid)
	local animator = ensureAnimator(humanoid)

	local self = setmetatable({}, NpcAnimationController)
	self.Model = model
	self.Humanoid = humanoid
	self.Animator = animator
	self.Tracks = {}
	self.CurrentState = nil
	self.CurrentIndex = 1
	self.CurrentTrack = nil
	self.SourceByState = {}
	self.LoadErrors = {}

	for _, stateName in ipairs({ "Idle", "Walk", "Jump" }) do
		local tracks, source, loadError = loadTracksForState(model, animator, stateName)
		self.SourceByState[stateName] = source
		self.Tracks[stateName] = tracks
		if loadError then
			self.LoadErrors[stateName] = loadError
		end
	end

	model:SetAttribute("AnimationSource", ("Idle:%s Walk:%s Jump:%s"):format(
		self.SourceByState.Idle or "None",
		self.SourceByState.Walk or "None",
		self.SourceByState.Jump or "None"
	))

	local loadErrorSummary = table.concat({
		self.LoadErrors.Idle or "",
		self.LoadErrors.Walk or "",
		self.LoadErrors.Jump or "",
	}, " | ")
	model:SetAttribute("AnimationLoadError", loadErrorSummary)

	return self
end

function NpcAnimationController:_stopAll(fadeTime)
	for _, trackList in pairs(self.Tracks) do
		for _, track in ipairs(trackList) do
			if track.IsPlaying then
				track:Stop(fadeTime or 0.15)
			end
		end
	end
end

function NpcAnimationController:_getTrack(stateName)
	local trackList = self.Tracks[stateName]
	if not trackList or #trackList == 0 then
		return nil
	end

	if stateName == "Idle" and #trackList > 1 then
		self.CurrentIndex = self.CurrentIndex + 1
		if self.CurrentIndex > #trackList then
			self.CurrentIndex = 1
		end
		return trackList[self.CurrentIndex]
	end

	return trackList[1]
end

function NpcAnimationController:Update(aiState, moveSpeed, movementState)
	local desiredState = "Idle"
	if moveSpeed > 1 then
		desiredState = "Walk"
	end

	if movementState == "Jump" then
		desiredState = "Jump"
	elseif aiState == "Retreat" or aiState == "Chase" or aiState == "Return" or aiState == "Patrol" then
		if moveSpeed > 1 then
			desiredState = "Walk"
		else
			desiredState = "Idle"
		end
	end

	if self.CurrentState == desiredState then
		if self.CurrentTrack and self.CurrentTrack.IsPlaying then
			if desiredState == "Walk" then
				self.CurrentTrack:AdjustSpeed(math.clamp(moveSpeed / 8, 0.75, 1.35))
			elseif desiredState == "Idle" then
				self.CurrentTrack:AdjustSpeed(1)
			end
		elseif desiredState == "Jump" and self.CurrentTrack then
			self.CurrentTrack:Play(0.05)
		end
		return
	end

	self:_stopAll(0.15)
	self.CurrentState = desiredState

	local track = self:_getTrack(desiredState)
	if not track then
		self.CurrentTrack = nil
		return
	end

	self.CurrentTrack = track
	track:Play(0.15)
	if desiredState == "Walk" then
		track:AdjustSpeed(math.clamp(moveSpeed / 8, 0.75, 1.35))
	elseif desiredState == "Idle" then
		track:AdjustSpeed(1)
	end
end

function NpcAnimationController:Destroy()
	self:_stopAll(0)
	for _, trackList in pairs(self.Tracks) do
		for _, track in ipairs(trackList) do
			track:Destroy()
		end
	end
end

return NpcAnimationController
