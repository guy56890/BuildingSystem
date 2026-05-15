-- Discord: guy56890 | Roblox: guy56890
--[[
	BuildingController (LocalScript)

	Handles client-side preview rendering, placement validation, and input
	routing for the hammer tool. The server is only contacted on confirmed
	placement or deletion, keeping interaction feel responsive.

	Architecture:
	  - A single State table owns all mutable runtime data so nothing leaks
	    into the module scope.
	  - Connections are accumulated into State.Connections and batch-cleared on
	    Unequip, preventing listener accumulation across tool re-equips.
	  - All heavy math (CFrame basis construction, raycast, validation) runs
	    inside RenderStepped rather than Heartbeat so it stays in sync with
	    the camera and avoids a frame of visual lag.
]]

-- services

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- player refs

local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Mouse = Player:GetMouse()

-- remotes

local Remotes = ReplicatedStorage:WaitForChild("BuildRemotes")
local TryPlace = Remotes:WaitForChild("TryPlace")
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- constants

local MAX_RANGE = 30
local SNAP_DISTANCE = 0.5
local ROT_SPEED = math.rad(45)
local HAMMER_TAG = "HAMMER"

-- head is cached here so validatePlacement can read it every frame without
-- calling WaitForChild in a hot path

local Head = Character:WaitForChild("Head")

-- the character is excluded so preview raycasts don't self-occlude against the
-- local player's own body parts

local CastParams = RaycastParams.new()
CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.FilterDescendantsInstances = { Character }

-- state

local State = {
	Tool = nil,
	Preview = nil,
	DeleteTarget = nil,
	Yaw = 0,
	Snapping = false,
	Deleting = false,
	CanPlace = false,
	Keys = { Q = false, E = false },
	Connections = {},
}

-- utilities

local function disconnectAll()
	for _, c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

-- rounds each world-space axis to the nearest grid increment so preview parts
-- snap cleanly to a fixed grid without drifting between cells

local function snap(v: Vector3, grid: number): Vector3
	return Vector3.new(
		math.round(v.X / grid) * grid,
		math.round(v.Y / grid) * grid,
		math.round(v.Z / grid) * grid
	)
end

-- preview colouring

-- stores the original colour as a part attribute before overwriting it so we
-- can restore it exactly without holding a separate lookup table

local function setInvalid(toggle: boolean)
	if not State.Preview then return end

	for _, part in State.Preview:GetDescendants() do
		if not part:IsA("BasePart") then continue end

		local stored = part:GetAttribute("OriginalColor")

		if toggle then
			if not stored then
				part:SetAttribute("OriginalColor", part.Color)
				part.Color = Color3.new(1, 0, 0)
			end
		else
			if stored then
				part.Color = stored
				part:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

-- placement validation

-- dot product against the world up axis converts the surface normal into an
-- angle from vertical; surfaces steeper than 45° would let objects slide, so
-- we reject them. math.clamp guards acos against NaN at exactly ±1

local function validatePlacement(surfaceNormal: Vector3)
	local distance = (State.Preview.PrimaryPart.Position - Head.Position).Magnitude
	local dot = surfaceNormal:Dot(Vector3.yAxis)
	local angle = math.acos(math.clamp(dot, -1, 1))

	State.CanPlace = distance <= MAX_RANGE and angle <= math.rad(45)
	setInvalid(not State.CanPlace)
end

-- preview creation

-- clones the source model and makes every BasePart non-interactive so the
-- ghost doesn't collide with the world or interfere with subsequent raycasts

local function createPreview(model: Model)
	if State.Preview then
		State.Preview:Destroy()
	end

	local clone = model:Clone()

	for _, part in clone:GetDescendants() do
		if not part:IsA("BasePart") then continue end
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Transparency = math.clamp(part.Transparency + 0.7, 0, 1)
	end

	clone.Parent = workspace
	State.Preview = clone
	State.Yaw = 0
end

-- orientation math

--[[
	Builds an orthonormal CFrame aligned to a surface rather than the world axes.

	Step 1 - Rotate the world forward vector by the accumulated yaw so the
	         player can spin the object with Q/E.
	Step 2 - Project that forward vector onto the surface plane by subtracting
	         its component along the normal. This keeps the object flush with
	         slopes instead of clipping into them.
	Step 3 - Cross-product the projected forward with the normal to get a right
	         vector that is perpendicular to both, completing the basis.
	Step 4 - CFrame.fromMatrix assembles the final orientation from the three
	         orthogonal axes.
]]
local function computePlacementCF(position: Vector3, normal: Vector3): CFrame
	local forward = CFrame.Angles(0, State.Yaw, 0) * Vector3.zAxis
	local projectedForward = (forward - normal * forward:Dot(normal)).Unit
	local right = projectedForward:Cross(normal).Unit
	return CFrame.fromMatrix(position, right, normal)
end

-- preview update

-- runs every RenderStepped; accumulates yaw from held keys and repositions the
-- ghost model on the surface under the cursor each frame

local function updatePreview(dt: number)
	local preview = State.Preview
	if not preview then return end

	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000,
		CastParams
	)

	if not result then return end

	local pos = result.Position
	local normal = result.Normal

	if State.Snapping then
		pos = snap(pos, SNAP_DISTANCE)
	end

	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	-- computePlacementCF encodes the full yaw into the basis vectors already,
	-- so no additional rotation is applied after the fact

	preview:PivotTo(computePlacementCF(pos, normal))
	validatePlacement(normal)
end

-- actions

local function place()
	if not State.Preview or not State.CanPlace then return end

	local result = TryPlace:InvokeServer(
		State.Preview.Name,
		State.Preview:GetPivot()
	)

	-- only clear the preview on an acknowledged success; failed placements
	-- leave the ghost in place so the player can adjust and retry

	if result == "SUCCESS" then
		State.Preview:Destroy()
		State.Preview = nil
	end
end

local function deleteSelected()
	if State.DeleteTarget then
		DeleteBuild:FireServer(State.DeleteTarget)
	end
end

-- input

local function inputBegan(input: InputObject, gpe: boolean)
	if gpe then return end

	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = true
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = true
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		if State.Deleting then
			deleteSelected()
		else
			place()
		end
	end
end

local function inputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = false
	end
end

-- tool lifecycle

-- connections are registered into State.Connections so they can all be
-- cleaned up atomically in unequipped without tracking each handle separately

local function equipped(tool: Tool)
	State.Tool = tool

	table.insert(State.Connections, RunService.RenderStepped:Connect(updatePreview))
	table.insert(State.Connections, UserInputService.InputBegan:Connect(inputBegan))
	table.insert(State.Connections, UserInputService.InputEnded:Connect(inputEnded))
end

local function unequipped()
	disconnectAll()

	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	State.Tool = nil
end

-- tool detection

-- ChildAdded fires for every instance parented to the character; the tag check
-- narrows it to hammer tools so other equipment is silently ignored

Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		equipped(child)
	end
end)

-- compare by reference rather than tag in case multiple hammers exist at once

Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		unequipped()
	end
end)
