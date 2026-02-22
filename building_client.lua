-- building controller
-- author: guy56890

-- services

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

-- player refs

local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Mouse = Player:GetMouse()

-- remotes

local Remotes = ReplicatedStorage:WaitForChild("BuildRemotes")
local TryPlace = Remotes:WaitForChild("TryPlace")
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- config

local MAX_RANGE = 30
local SNAP_DISTANCE = 0.5
local SNAP_ROTATION = math.rad(15)
local ROT_SPEED = math.rad(45)
local HAMMER_TAG = "HAMMER"

-- state

local State = {
	Tool = nil,
	Preview = nil,
	DeleteTarget = nil,
	Yaw = 0,
	Snapping = false,
	Deleting = false,
	CanPlace = false,
	Keys = {Q=false,E=false},
	Connections = {}
}

-- raycast setup

CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.FilterDescendantsInstances = {Character}

-- utilities

local function DisconnectAll()
	for _,c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

local function Snap(v: Vector3, grid: number)
	return Vector3.new(
		math.round(v.X/grid)*grid,
		math.round(v.Y/grid)*grid,
		math.round(v.Z/grid)*grid
	)
end

-- preview colouring

local function SetInvalid(toggle)
	if not State.Preview then return end

	for _,p in State.Preview:GetDescendants() do
		if not p:IsA("BasePart") then continue end

		local stored = p:GetAttribute("OriginalColor")

		if toggle then
			if not stored then
				p:SetAttribute("OriginalColor", p.Color)
				p.Color = Color3.new(1,0,0)
			end
		else
			if stored then
				p.Color = stored
				p:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

-- placement validation

local function ValidatePlacement(surfaceNormal: Vector3)

	local head = Character:WaitForChild("Head")

	local distance =
		(State.Preview.PrimaryPart.Position - head.Position).Magnitude

	local allowed = true

	if distance > MAX_RANGE then
		allowed = false
	end

	-- dot product measures alignment between vectors
	-- dot = 1 means perfectly upward surface
	-- dot = 0 means vertical wall
	-- we reject steep angles

	local dot = surfaceNormal:Dot(Vector3.yAxis)
	local angle = math.acos(dot)

	if angle > math.rad(45) then
		allowed = false
	end

	State.CanPlace = allowed
	SetInvalid(not allowed)
end

-- preview creation

local function CreatePreview(model: Model)

	if State.Preview then
		State.Preview:Destroy()
	end

	local clone = model:Clone()

	for _,p in clone:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Transparency = math.clamp(p.Transparency+0.7,0,1)
		end
	end

	clone.Parent = workspace
	State.Preview = clone
	State.Yaw = 0
end

-- orientation math

local function ComputePlacementCF(position: Vector3, normal: Vector3)

	-- we build a coordinate system aligned to the surface

	-- step 1:
	-- create forward vector rotated by user yaw
	local forward =
		(CFrame.Angles(0,State.Yaw,0) * Vector3.zAxis)

	-- step 2:
	-- remove vertical component from forward
	-- this projects forward onto the surface plane
	local projectedForward =
		(forward - normal * forward:Dot(normal)).Unit

	-- step 3:
	-- cross product builds perpendicular axis
	local right =
		projectedForward:Cross(normal).Unit

	-- step 4:
	-- construct matrix from orthogonal basis
	return CFrame.fromMatrix(position, right, normal)
end

-- preview update

local function UpdatePreview(dt)

	local preview = State.Preview
	if not preview then return end

	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction*1000,
		CastParams
	)

	if not result then return end

	local pos = result.Position
	local normal = result.Normal

	if State.Snapping then
		pos = Snap(pos,SNAP_DISTANCE)
	end

	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	local cf = ComputePlacementCF(pos,normal)

	preview:PivotTo(cf * CFrame.Angles(0,State.Yaw,0))

	ValidatePlacement(normal)
end

-- actions

local function Place()
	if not State.Preview or not State.CanPlace then return end

	local result = TryPlace:InvokeServer(
		State.Preview.Name,
		State.Preview:GetPivot()
	)

	if result == "SUCCESS" then
		State.Preview:Destroy()
		State.Preview = nil
	end
end

local function DeleteSelected()
	if State.DeleteTarget then
		DeleteBuild:FireServer(State.DeleteTarget)
	end
end

-- input

local function InputBegan(input,gpe)
	if gpe then return end

	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = true

	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = true

	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if State.Deleting then
			DeleteSelected()
		else
			Place()
		end
	end
end

local function InputEnded(input)
	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = false
	end
end

-- tool lifecycle

local function Equipped(tool)

	State.Tool = tool

	table.insert(
		State.Connections,
		RunService.RenderStepped:Connect(UpdatePreview)
	)

	table.insert(
		State.Connections,
		UserInputService.InputBegan:Connect(InputBegan)
	)

	table.insert(
		State.Connections,
		UserInputService.InputEnded:Connect(InputEnded)
	)
end

local function Unequipped()

	DisconnectAll()

	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	State.Tool = nil
end

-- tool detection

Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child,HAMMER_TAG) then
		Equipped(child)
	end
end)

Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		Unequipped()
	end
end)
