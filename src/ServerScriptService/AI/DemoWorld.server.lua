local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

if #CollectionService:GetTagged("CombatNpc") > 0 then
	return
end

local function ensureFolder(name)
	local existing = Workspace:FindFirstChild(name)
	if existing then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = Workspace
	return folder
end

local function createPart(parent, name, size, position, color, anchored)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end

	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = anchored ~= false
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function createNpc(parent, name, position)
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end

	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Position = position + Vector3.new(0, 3, 0)
	root.Anchored = false
	root.CanCollide = false
	root.Transparency = 1
	root.Parent = model

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Position = position + Vector3.new(0, 3, 0)
	torso.Anchored = false
	torso.Color = Color3.fromRGB(140, 62, 62)
	torso.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Position = position + Vector3.new(0, 4.5, 0)
	head.Anchored = false
	head.Color = Color3.fromRGB(234, 190, 145)
	head.Parent = model

	local rootJoint = Instance.new("WeldConstraint")
	rootJoint.Part0 = root
	rootJoint.Part1 = torso
	rootJoint.Parent = root

	local neck = Instance.new("WeldConstraint")
	neck.Part0 = torso
	neck.Part1 = head
	neck.Parent = torso

	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = 10
	humanoid.MaxHealth = 120
	humanoid.Health = 120
	humanoid.Parent = model

	local animate = Instance.new("Folder")
	animate.Name = "Animate"
	animate.Parent = model

	local idleFolder = Instance.new("Folder")
	idleFolder.Name = "idle"
	idleFolder.Parent = animate

	local idle1 = Instance.new("Animation")
	idle1.Name = "Animation1"
	idle1.AnimationId = "rbxassetid://507766666"
	idle1.Parent = idleFolder

	local idle2 = Instance.new("Animation")
	idle2.Name = "Animation2"
	idle2.AnimationId = "rbxassetid://507766951"
	idle2.Parent = idleFolder

	local walkFolder = Instance.new("Folder")
	walkFolder.Name = "walk"
	walkFolder.Parent = animate

	local walk = Instance.new("Animation")
	walk.Name = "WalkAnim"
	walk.AnimationId = "rbxassetid://507777826"
	walk.Parent = walkFolder

	local jumpFolder = Instance.new("Folder")
	jumpFolder.Name = "jump"
	jumpFolder.Parent = animate

	local jump = Instance.new("Animation")
	jump.Name = "JumpAnim"
	jump.AnimationId = "rbxassetid://507765000"
	jump.Parent = jumpFolder

	model.PrimaryPart = root
	CollectionService:AddTag(model, "CombatNpc")

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "StateBillboard"
	billboard.Size = UDim2.fromOffset(120, 36)
	billboard.StudsOffset = Vector3.new(0, 4.5, 0)
	billboard.Adornee = head
	billboard.AlwaysOnTop = true
	billboard.Parent = model

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(255, 245, 220)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 14
	label.Text = name
	label.Parent = billboard

	return model
end

local world = ensureFolder("NpcAiDemoWorld")
createPart(world, "ArenaFloor", Vector3.new(180, 1, 180), Vector3.new(0, 0, 0), Color3.fromRGB(78, 109, 74), true)
createPart(world, "CentralRock", Vector3.new(10, 12, 10), Vector3.new(0, 6, 14), Color3.fromRGB(102, 102, 102), true)
createPart(world, "WestCover", Vector3.new(12, 8, 2), Vector3.new(-28, 4, -12), Color3.fromRGB(121, 85, 58), true)
createPart(world, "EastCover", Vector3.new(12, 8, 2), Vector3.new(30, 4, 8), Color3.fromRGB(121, 85, 58), true)
createPart(world, "NorthWallLeft", Vector3.new(38, 12, 3), Vector3.new(-24, 6, 28), Color3.fromRGB(93, 93, 93), true)
createPart(world, "NorthWallRight", Vector3.new(38, 12, 3), Vector3.new(24, 6, 28), Color3.fromRGB(93, 93, 93), true)
createPart(world, "SouthWallLeft", Vector3.new(32, 10, 3), Vector3.new(-30, 5, -18), Color3.fromRGB(93, 93, 93), true)
createPart(world, "SouthWallRight", Vector3.new(32, 10, 3), Vector3.new(30, 5, -4), Color3.fromRGB(93, 93, 93), true)
createPart(world, "JumpCrateA", Vector3.new(4, 3, 4), Vector3.new(-8, 1.5, 4), Color3.fromRGB(145, 102, 71), true)
createPart(world, "JumpCrateB", Vector3.new(4, 3, 4), Vector3.new(-2, 1.5, 4), Color3.fromRGB(145, 102, 71), true)
createPart(world, "JumpCrateC", Vector3.new(4, 3, 4), Vector3.new(4, 1.5, 4), Color3.fromRGB(145, 102, 71), true)
createPart(world, "RaisedLedge", Vector3.new(16, 4, 16), Vector3.new(28, 2, 28), Color3.fromRGB(88, 104, 124), true)

local spawnPad = world:FindFirstChild("SpawnPad")
if not spawnPad then
	spawnPad = Instance.new("SpawnLocation")
	spawnPad.Name = "SpawnPad"
	spawnPad.Size = Vector3.new(10, 1, 10)
	spawnPad.Position = Vector3.new(0, 1.5, -26)
	spawnPad.Anchored = true
	spawnPad.Neutral = true
	spawnPad.Color = Color3.fromRGB(52, 152, 219)
	spawnPad.Parent = world
end

createNpc(world, "BanditNpcA", Vector3.new(26, 1, -10))
createNpc(world, "BanditNpcB", Vector3.new(-24, 1, 20))
