--[[
by guy56890, october 29th through october 30th, 2025
client-side building controller
everything below is explained line-by-line
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage") -- shared assets + remotes
local UserInputService = game:GetService("UserInputService") -- keyboard / mouse input
local Players = game:GetService("Players") -- player service
local RunService = game:GetService("RunService") -- frame updates
local CollectionService = game:GetService("CollectionService") -- tagging system
local TweenService = game:GetService("TweenService") -- tween animations
local DebrisService = game:GetService("Debris") -- auto cleanup instances

local Player = Players.LocalPlayer -- this client
local Char = Player.Character or Player.CharacterAdded:Wait() -- ensure character exists
local Mouse = Player:GetMouse() -- mouse ray provider

local PlayerUI = Player:WaitForChild("PlayerGui") -- UI container
local BuildUI = PlayerUI:WaitForChild("BuildingUI") -- main build interface

-- remote references used to communicate with server
local BuildRemotes = ReplicatedStorage:WaitForChild("BuildRemotes")
local TryPlace = BuildRemotes.TryPlace -- server validates and places object
local DeleteBuild = BuildRemotes.DeletePlayerBuild -- deletes placed object
local GetMaterialRequirements = BuildRemotes.GetMaterialRequirements -- returns material costs
local UnlockedBuildings = BuildRemotes.UnlockedBuildings -- returns unlocked builds

local HAMMER_TAG = "HAMMER" -- tag identifying the build tool
local MAX_RANGE = 30 -- maximum build distance
local Tool = nil -- current equipped hammer

-- snapping + rotation configuration
local SNAP_DISTANCE = 1 -- grid size when snapping enabled
local SNAP_ROTATION = math.rad(15) -- rotation step when snapping
local YawAngle = 0 -- accumulated rotation
local YawSpeed = math.rad(60) -- degrees/sec converted to radians

local OriginForward = Vector3.new(0,0,1) -- original forward vector of model

-- state flags controlling modes
local Snapping = false
local Deleting = false
local Debugging = false
local Continuous = false

local CanPlacing = true -- whether placement currently valid
local FolderName = nil -- folder random selection tracking
local SearchText = ""
local ErrorReason = ""

-- fetch build costs once
local MaterialRequirements = GetMaterialRequirements:InvokeServer()

-- gradients used for button feedback
local RedColor = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255,0,4)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255,255,255))
})

local GreenColor = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(59,118,63)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255,255,255))
})

local Assets = ReplicatedStorage:WaitForChild("BuildAssets")
local BuildObjects = Assets:WaitForChild("BuildObjects")

local SelectedObject = nil -- preview model
local SelectedObjectForDeletion = nil -- hovered build during delete
local PreviewOutOfRange = false
local BuildRangeVisualizer = script:WaitForChild("BuildRangeVisualizer")

-- raycast ignores player and NPC actors
local CastParams = RaycastParams.new()
CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.FilterDescendantsInstances = {Char, workspace.Actors}

local BuildButtonTemplate = script.Template
local TempConnections = {} -- temporary runtime connections
local DebugConnections = {}

-- tracks held rotation keys
local KeysDown = {Q=false,E=false}

local Motor6D = nil -- replaces default grip weld
local HoldAnimation = nil

---------------------------------------------------------------------
-- PREVIEW COLOR LOGIC
---------------------------------------------------------------------

local function SwapPreviewColor(valid)
	assert(SelectedObject)

	-- iterate through every visual descendant
	for _, Part in SelectedObject:GetDescendants() do

		-- ignore objects that cannot visually change color
		if not (Part:IsA("BasePart") or Part:IsA("Decal") or Part:IsA("Light") or Part:IsA("SurfaceAppearance")) then
			continue
		end

		local OriginalColor = Part:GetAttribute("OriginalColor")

		-- invalid placement -> tint red
		if not valid then
			if not OriginalColor then
				if Part:IsA("Decal") then
					Part:SetAttribute("OriginalColor", Part.Color3)
					Part.Color3 = Color3.fromRGB(255,0,0)
				else
					Part:SetAttribute("OriginalColor", Part.Color)
					Part.Color = Color3.fromRGB(255,0,0)
				end
			end
		else
			-- restore original color if valid again
			if OriginalColor then
				if Part:IsA("Decal") then
					Part.Color3 = OriginalColor
				else
					Part.Color = OriginalColor
				end
				Part:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

---------------------------------------------------------------------
-- SPACE CHECK
---------------------------------------------------------------------

local function IsSpaceFree()
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {SelectedObject}

	-- checks if preview boundary overlaps anything
	local overlapping = workspace:GetPartsInPart(SelectedObject.Boundary, params)

	return #overlapping == 0
end

---------------------------------------------------------------------
-- PLACEMENT VALIDATION
---------------------------------------------------------------------

local function CanPlace(UpVector)

	local preventPlacing = false

	-- distance check
	local Difference = SelectedObject.PrimaryPart.Position - Char.Head.Position
	if Difference.Magnitude > MAX_RANGE then
		preventPlacing = true
		ErrorReason = "OUT OF RANGE"
	end

	-- surface angle validation
	local maxAngle = math.rad(45)

	-- dot product measures alignment between surface normal and world up
	local angleFromUp = math.acos(UpVector:Dot(Vector3.new(0,1,0)))

	if angleFromUp > maxAngle then
		if not SelectedObject:GetAttribute("AllSurfaces") then
			preventPlacing = true
			ErrorReason = "INVALID SURFACE"
		end
	end

	-- collision check
	if not IsSpaceFree() then
		preventPlacing = true
		ErrorReason = "SPACE OCCUPIED"
	end

	if Debugging then
		preventPlacing = false
		ErrorReason = ""
	end

	CanPlacing = not preventPlacing
	SwapPreviewColor(CanPlacing)
end

---------------------------------------------------------------------
-- PREVIEW UPDATE (RUNS EVERY FRAME)
---------------------------------------------------------------------

local function UpdatePreview(deltaTime)

	if not SelectedObject then return end

	-- raycast downward to position range visualizer
	local groundRay =
		workspace:Raycast(Char.HumanoidRootPart.Position, Vector3.new(0,-100,0), CastParams)

	if groundRay then
		BuildRangeVisualizer.Main.Position = groundRay.Position
	end

	-- mouse raycast determines placement location
	local RayResult =
		workspace:Raycast(Mouse.UnitRay.Origin, Mouse.UnitRay.Direction * 1000, CastParams)

	if not RayResult then return end

	local Position = RayResult.Position
	local UpVector = RayResult.Normal

	-- continuous rotation when holding keys
	if KeysDown.E and not Snapping then
		YawAngle += YawSpeed * deltaTime
	end

	if KeysDown.Q and not Snapping then
		YawAngle -= YawSpeed * deltaTime
	end

	-- snap to grid
	if Snapping then
		Position = Vector3.new(
			math.round(Position.X/SNAP_DISTANCE)*SNAP_DISTANCE,
			Position.Y,
			math.round(Position.Z/SNAP_DISTANCE)*SNAP_DISTANCE
		)
	end

	-- rotate object's forward direction
	local RotatedForward =
		(CFrame.Angles(0,YawAngle,0) * OriginForward)

	-- project forward vector onto surface plane
	local ForwardVector =
		(RotatedForward - UpVector * RotatedForward:Dot(UpVector)).Unit

	-- compute perpendicular axis
	local RightVector =
		ForwardVector:Cross(UpVector).Unit

	-- construct orientation matrix
	local MatrixCFrame =
		CFrame.fromMatrix(Position, RightVector, UpVector)

	if not SelectedObject:GetAttribute("IgnoresRotation") then
		SelectedObject:PivotTo(MatrixCFrame * CFrame.Angles(0,YawAngle,0))
		CanPlace(UpVector)
	else
		local cf =
			CFrame.new(Position) *
			CFrame.Angles(0,YawAngle,0)

		SelectedObject:PivotTo(cf)
		CanPlace(Vector3.new(0,1,0))
	end
end

---------------------------------------------------------------------
-- PREVIEW CREATION
---------------------------------------------------------------------

local function CreatePreview(object)

	assert(object)
	if Deleting then return end

	if SelectedObject then
		SelectedObject:Destroy()
	end

	-- folder = choose random variant
	if object:IsA("Folder") then
		FolderName = object.Name
		local children = object:GetChildren()
		SelectedObject = children[math.random(#children)]:Clone()
	else
		FolderName = nil
		SelectedObject = object:Clone()
	end

	-- convert into ghost preview
	for _, obj in SelectedObject:GetDescendants() do

		if obj:IsA("Weld") or obj:IsA("WeldConstraint") then
			obj:Destroy()
		end

		if obj:IsA("BasePart") then
			obj.Anchored = true
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = false
			obj.Transparency = math.clamp(obj.Transparency + 0.7,0,1)
		end

		if obj:IsA("Light") then
			obj.Enabled = false
		end
	end

	SelectedObject.Parent = workspace.Temp

	OriginForward =
		SelectedObject.PrimaryPart and SelectedObject.PrimaryPart.CFrame.LookVector
		or Vector3.new(0,0,1)

	YawAngle = 0
end

---------------------------------------------------------------------
-- PREVIEW CLEANUP
---------------------------------------------------------------------

local function EndPreview()
	if SelectedObject then
		SelectedObject:Destroy()
		SelectedObject = nil
	end

	BuildRangeVisualizer.Parent = script
end

---------------------------------------------------------------------
-- TOOL ACTIVATION (PLACEMENT)
---------------------------------------------------------------------

local function Activated()

	-- deletion mode
	if Deleting then
		if not SelectedObjectForDeletion then return end
		DeleteBuild:FireServer(SelectedObjectForDeletion, Debugging)
		return
	end

	if not SelectedObject then return end

	-- placement rejected
	if not CanPlacing then
		return
	end

	local Parent = nil

	-- allow attaching to another player build
	if Mouse.Target
	and CollectionService:HasTag(
		Mouse.Target:FindFirstAncestorOfClass("Model"),
		"PLAYER_BUILD"
	) then
		Parent = Mouse.Target:FindFirstAncestorOfClass("Model")
	end

	local result =
		TryPlace:InvokeServer(
			SelectedObject.Name,
			SelectedObject:GetPivot(),
			Parent,
			FolderName,
			Debugging
		)

	if result == "SUCCESS" then
		if not Continuous then
			EndPreview()
		else
			CreatePreview(BuildObjects:FindFirstChild(SelectedObject.Name))
		end
	end
end

---------------------------------------------------------------------
-- EQUIP / UNEQUIP
---------------------------------------------------------------------

local function Equipped()

	BuildUI.Enabled = true

	table.insert(
		TempConnections,
		Tool.Activated:Connect(Activated)
	)

	table.insert(
		TempConnections,
		RunService.RenderStepped:Connect(UpdatePreview)
	)

	-- replaces default grip with Motor6D so animations work
	if Tool:HasTag("REAL") then
		local Weld = Char.RightHand:WaitForChild("RightGrip")

		Motor6D = Instance.new("Motor6D")
		Motor6D.Parent = Char.RightHand
		Motor6D.Name = "RightGrip"
		Motor6D.Part0 = Weld.Part0
		Motor6D.Part1 = Weld.Part1
		Motor6D.C0 = Weld.C0
		Motor6D.C1 = Weld.C1

		Weld:Destroy()

		HoldAnimation =
			Char.Humanoid.Animator:LoadAnimation(script.Animations.Hold)

		HoldAnimation:Play()
	end
end

local function Unequipped()

	EndPreview()
	BuildUI.Enabled = false

	for _, c in TempConnections do
		c:Disconnect()
	end

	table.clear(TempConnections)

	if Motor6D then
		Motor6D:Destroy()
		HoldAnimation:Stop()
		HoldAnimation = nil
	end
end

---------------------------------------------------------------------
-- CHARACTER TOOL DETECTION
---------------------------------------------------------------------

local function ChildAdded(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		Tool = child
		Equipped()
	end
end

local function ChildRemoved(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		Tool = nil
		Unequipped()
	end
end

---------------------------------------------------------------------
-- INPUT HANDLING
---------------------------------------------------------------------

local function InputBegan(input, processed)
	if processed or not SelectedObject then return end

	if input.KeyCode == Enum.KeyCode.E then
		if Snapping then
			YawAngle += SNAP_ROTATION
		end
		KeysDown.E = true
	elseif input.KeyCode == Enum.KeyCode.Q then
		if Snapping then
			YawAngle -= SNAP_ROTATION
		end
		KeysDown.Q = true
	end
end

local function InputEnded(input)
	if not SelectedObject then return end

	if input.KeyCode == Enum.KeyCode.E then
		KeysDown.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		KeysDown.Q = false
	end
end

---------------------------------------------------------------------
-- CONNECTIONS
---------------------------------------------------------------------

Char.ChildAdded:Connect(ChildAdded)
Char.ChildRemoved:Connect(ChildRemoved)

UserInputService.InputBegan:Connect(InputBegan)
UserInputService.InputEnded:Connect(InputEnded)
