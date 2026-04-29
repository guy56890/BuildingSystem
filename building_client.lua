-- building controller
-- author: guy56890

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Player    = Players.LocalPlayer
-- Character might already exist by the time this script runs, so we fall
-- back to waiting on CharacterAdded if it doesn't
local Character = Player.Character or Player.CharacterAdded:Wait()
-- UnitRay gives us a direction from the camera through the cursor, which
-- is what we use for the placement raycast each frame
local Mouse = Player:GetMouse()

-- WaitForChild because these remotes replicate from the server and might
-- not exist yet the moment this script runs on the client
local Remotes     = ReplicatedStorage:WaitForChild("BuildRemotes")
-- InvokeServer because placement needs a round trip, the server validates
-- the request and tells us whether it worked
local TryPlace    = Remotes:WaitForChild("TryPlace")
-- FireServer is fine for deletion since we don't need a response back
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- how far from the player's head a placement can be confirmed
local MAX_RANGE     = 30
-- world grid size in studs for positional snapping
local SNAP_DISTANCE = 0.5
-- rotation snap increment, 15 degree steps
local SNAP_ROTATION = math.rad(15)
-- yaw speed in radians per second when Q or E is held
local ROT_SPEED     = math.rad(45)
-- the CollectionService tag we look for to activate build mode
-- doing it this way means any tool with this tag works, not just ones with a specific name
local HAMMER_TAG = "HAMMER"

-- all mutable runtime state lives here so nothing bleeds into the module scope
-- and cleanup stays straightforward
local State = {
	Tool         = nil,
	Preview      = nil,
	DeleteTarget = nil,
	Yaw          = 0,
	Snapping     = false,
	Deleting     = false,
	CanPlace     = false,
	Keys         = {Q = false, E = false},
	Connections  = {}
}

-- exclude the local character so the placement ray never hits our own body
local CastParams = RaycastParams.new()
CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.FilterDescendantsInstances = {Character}

-- severs every stored connection at once and clears the table
-- called on unequip so we're not running a per-frame callback with no tool equipped
local function DisconnectAll()
	for _, c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

-- rounds each axis of a Vector3 to the nearest multiple of `grid`
-- so builds align to a consistent world grid
local function Snap(v: Vector3, grid: number): Vector3
	return Vector3.new(
		math.round(v.X / grid) * grid,
		math.round(v.Y / grid) * grid,
		math.round(v.Z / grid) * grid
	)
end

-- same idea as Snap but for the yaw angle, locks it to 15 degree increments
local function SnapYaw(yaw: number): number
	return math.round(yaw / SNAP_ROTATION) * SNAP_ROTATION
end

-- tints the entire preview red when placement is invalid and restores original
-- colours when it becomes valid again
-- we cache each part's original colour as an instance attribute rather than a
-- separate lookup table because attributes travel with the instance, no bookkeeping needed
local function SetInvalid(toggle: boolean)
	if not State.Preview then return end

	for _, p in State.Preview:GetDescendants() do
		if not p:IsA("BasePart") then continue end

		local stored = p:GetAttribute("OriginalColor")

		if toggle then
			-- only cache and tint if we haven't already, otherwise we'd overwrite
			-- the cached original with red on a repeated call
			if not stored then
				p:SetAttribute("OriginalColor", p.Color)
				p.Color = Color3.new(1, 0, 0)
			end
		else
			if stored then
				p.Color = stored
				p:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

-- checks two things: distance from the player's head and surface slope
-- if either fails, placement is blocked and the preview turns red
--
-- the slope check uses the dot product between the surface normal and world up
-- the dot product of two unit vectors equals the cosine of the angle between them
-- so math.acos gets us the actual angle in radians
-- we clamp the dot value before passing it to math.acos because floating point
-- drift can push it just outside the valid range and cause it to return NaN
local function ValidatePlacement(surfaceNormal: Vector3)
	local head = Character:WaitForChild("Head")

	local distance =
		(State.Preview.PrimaryPart.Position - head.Position).Magnitude

	local allowed = true

	if distance > MAX_RANGE then
		allowed = false
	end

	local dot   = surfaceNormal:Dot(Vector3.yAxis)
	local angle = math.acos(math.clamp(dot, -1, 1))

	-- anything steeper than 45 degrees counts as a wall or ceiling
	if angle > math.rad(45) then
		allowed = false
	end

	State.CanPlace = allowed
	SetInvalid(not allowed)
end

-- clones the model and strips all collision and query flags from its parts
-- so it acts purely as a visual ghost with no effect on gameplay raycasts
-- transparency is nudged up and clamped in case the source model already has
-- partially transparent parts that would exceed 1 otherwise
local function CreatePreview(model: Model)
	if State.Preview then
		State.Preview:Destroy()
	end

	local clone = model:Clone()

	for _, p in clone:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored     = true
			p.CanCollide   = false
			p.CanQuery     = false
			p.CanTouch     = false
			p.Transparency = math.clamp(p.Transparency + 0.7, 0, 1)
		end
	end

	clone.Parent  = workspace
	State.Preview = clone
	State.Yaw     = 0
end

-- builds a CFrame that aligns to the hit surface so objects sit flush on any
-- angle rather than always defaulting to world-up orientation
--
-- we start by rotating the forward vector by the current yaw, then project it
-- onto the surface plane by removing any component that points along the normal
-- v - n*(v dot n) strips the normal-aligned part and leaves only the in-plane part
-- from there a cross product of the projected forward and the normal gives us
-- the right axis, and CFrame.fromMatrix assembles the full orientation from those
-- two orthogonal basis vectors
local function ComputePlacementCF(position: Vector3, normal: Vector3): CFrame
	local forward =
		(CFrame.Angles(0, State.Yaw, 0) * Vector3.zAxis)

	local projectedForward =
		(forward - normal * forward:Dot(normal)).Unit

	local right =
		projectedForward:Cross(normal).Unit

	return CFrame.fromMatrix(position, right, normal)
end

-- runs every RenderStepped frame and moves the preview to wherever the cursor
-- is pointing, applying snapping and rotation along the way
-- dt is delta time in seconds so rotation speed stays consistent regardless of framerate
local function UpdatePreview(dt: number)
	local preview = State.Preview
	if not preview then return end

	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000,
		CastParams
	)

	if not result then return end

	local pos    = result.Position
	local normal = result.Normal

	if State.Snapping then
		pos = Snap(pos, SNAP_DISTANCE)
	end

	-- scale rotation by dt so holding E at 120fps doesn't rotate twice as fast as at 60fps
	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	-- when snapping is on and neither key is held, lock yaw to the nearest 15 degree
	-- step so the rotation feels intentional rather than stopping at a random angle
	if State.Snapping and not State.Keys.E and not State.Keys.Q then
		State.Yaw = SnapYaw(State.Yaw)
	end

	-- yaw is already baked into ComputePlacementCF via the rotated forward vector
	-- so we just call PivotTo once with the finished surface-aligned CFrame
	local cf = ComputePlacementCF(pos, normal)
	preview:PivotTo(cf)

	ValidatePlacement(normal)
end

-- sends the placement request to the server with the model name and its current
-- world CFrame, then destroys the local preview if the server confirms success
-- the server is authoritative so the real instance is always spawned server-side
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

-- gpe being true means the engine already consumed the input, usually because
-- the chat or a UI element was focused, so we bail early to avoid interfering
local function InputBegan(input: InputObject, gpe: boolean)
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

-- just resets the held key flags so rotation stops when the key comes up
local function InputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = false
	end
end

-- registers the three connections needed while a hammer is active
-- storing them in State.Connections means DisconnectAll handles everything
-- in one call rather than us having to track each handle separately
local function Equipped(tool: Tool)
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

-- tears everything down when the tool leaves the character, whether that's
-- from unequipping, switching tools, dying, or being kicked
local function Unequipped()
	DisconnectAll()

	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	State.Tool = nil
end

-- using a CollectionService tag instead of checking the tool name means
-- any tool tagged HAMMER activates build mode without caring what it's called
Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		Equipped(child)
	end
end)

-- comparing by identity against State.Tool rather than re-checking the tag
-- because we only want to call Unequipped if it's actually the hammer we were tracking
Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		Unequipped()
	end
end)
