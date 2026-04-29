-- building controller
-- author: guy56890

-- Services expose Roblox engine systems as singleton objects.
-- GetService is the canonical way to access them; indexing game directly
-- (e.g. game.Players) works but is less reliable across environments.
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

-- LocalPlayer is only valid inside a LocalScript running on the client.
-- It is the root of all per-player data: character, backpack, GUI, etc.
local Player    = Players.LocalPlayer

-- Player.Character may already exist if this script runs after the first spawn.
-- CharacterAdded:Wait() yields the coroutine until the event fires if not.
-- The `or` short-circuits to the yield only when Character is nil/false.
local Character = Player.Character or Player.CharacterAdded:Wait()

-- GetMouse returns a Mouse object that exposes UnitRay (a Ray from the camera
-- through the cursor) and Hit (the last raycast CFrame). UnitRay is preferred
-- for manual raycasts because it pairs cleanly with workspace:Raycast.
local Mouse = Player:GetMouse()

-- RemoteEvents and RemoteFunctions live in ReplicatedStorage so both the
-- server and every client can reference the same instances.
-- WaitForChild yields until replication completes, preventing nil errors on join.
local Remotes     = ReplicatedStorage:WaitForChild("BuildRemotes")

-- RemoteFunction (InvokeServer): client calls, server responds, result returned.
-- Used for placement because the server must validate and confirm authority-side.
local TryPlace    = Remotes:WaitForChild("TryPlace")

-- RemoteEvent (FireServer): one-way message from client to server, no return.
-- Deletion only needs to signal intent; the server handles the actual removal.
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- MAX_RANGE caps how far from the player's head a placement can be confirmed.
-- Prevents abuse such as placing through walls from a distance.
local MAX_RANGE     = 30

-- SNAP_DISTANCE is the world-space grid size in studs for positional snapping.
-- A value of 0.5 means builds snap to half-stud intervals on each axis.
local SNAP_DISTANCE = 0.5

-- SNAP_ROTATION is the angular grid step in radians (15 degrees).
-- math.rad(d) = d * (math.pi / 180), converting degrees to the radians
-- that all Roblox trig and CFrame functions expect.
local SNAP_ROTATION = math.rad(15)

-- ROT_SPEED is the continuous yaw rate when Q or E is held, in radians/second.
-- At 45 deg/s the player makes a full 360 rotation in 8 seconds.
local ROT_SPEED     = math.rad(45)

-- HAMMER_TAG is the CollectionService tag applied to tool instances that
-- activate build mode. Using tags decouples detection from naming conventions,
-- so any tool tagged "HAMMER" works regardless of its AssetId or Name.
local HAMMER_TAG = "HAMMER"

-- State centralises all mutable runtime data in one table.
-- This avoids scattered module-level variables, makes state easy to inspect,
-- and lets reset/cleanup functions address everything in one place.
local State = {
	Tool        = nil,            -- the currently equipped tool Instance, or nil
	Preview     = nil,            -- the ghost Model shown before confirming placement
	DeleteTarget = nil,           -- the build Model currently hovered in delete mode
	Yaw         = 0,              -- accumulated rotation around world Y, in radians
	Snapping    = false,          -- true when the player has grid-snap toggled on
	Deleting    = false,          -- true when the player is in delete mode
	CanPlace    = false,          -- validity flag, updated every frame
	Keys        = {Q=false, E=false}, -- held-key state for continuous rotation
	Connections = {}              -- stores RBXScriptConnections for grouped cleanup
}

-- RaycastParams controls which parts the ray can hit.
-- Exclude mode means the list is a blocklist; every part NOT in the list
-- is eligible for intersection. We exclude the character so the preview
-- ray never registers hits on the player's own limbs.
local CastParams = RaycastParams.new()
CastParams.FilterType = Enum.RaycastFilterType.Exclude
CastParams.FilterDescendantsInstances = {Character}

-- DisconnectAll severs every stored RBXScriptConnection at once, then
-- empties the table. table.clear resets length to 0 without reallocating,
-- which is more efficient than assigning a new table.
-- This must be called on unequip to stop per-frame callbacks and prevent
-- memory leaks from listeners holding references after the tool is gone.
local function DisconnectAll()
	for _, c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

-- Snap quantises a Vector3 to the nearest multiple of `grid` on each axis.
-- math.round returns the nearest integer n such that n = round(v/grid),
-- then multiplying back by grid restores the scale.
-- Example: Snap(Vector3.new(1.3, 0, 2.7), 0.5) → (1.5, 0, 2.5)
local function Snap(v: Vector3, grid: number): Vector3
	return Vector3.new(
		math.round(v.X / grid) * grid,
		math.round(v.Y / grid) * grid,
		math.round(v.Z / grid) * grid
	)
end

-- SnapYaw rounds the accumulated yaw to the nearest SNAP_ROTATION step.
-- Works by the same quantise pattern as Snap: divide, round, multiply back.
-- This produces discrete 15-degree yaw increments when snap mode is active
-- and no rotation key is held.
local function SnapYaw(yaw: number): number
	return math.round(yaw / SNAP_ROTATION) * SNAP_ROTATION
end

-- SetInvalid tints every BasePart in the preview red when `toggle` is true,
-- and restores original colours when false.
--
-- Instance Attributes are key-value pairs stored directly on an instance,
-- surviving parenting changes and replication. They accept most Roblox value
-- types including Color3, making them suitable for per-part colour caches
-- without needing an external lookup table.
local function SetInvalid(toggle: boolean)
	if not State.Preview then return end

	for _, p in State.Preview:GetDescendants() do
		if not p:IsA("BasePart") then continue end

		-- GetAttribute returns nil if the attribute does not exist.
		local stored = p:GetAttribute("OriginalColor")

		if toggle then
			-- Only cache and tint if not already tinted, preventing repeated
			-- writes that would overwrite the cached original with red.
			if not stored then
				p:SetAttribute("OriginalColor", p.Color)
				p.Color = Color3.new(1, 0, 0)
			end
		else
			-- Restore only if a cached colour exists, then delete the attribute
			-- to signal the part is back to its original state.
			if stored then
				p.Color = stored
				p:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

-- ValidatePlacement checks two independent conditions each frame:
--
-- 1. Distance: the preview's PrimaryPart must be within MAX_RANGE of the
--    player's head. PrimaryPart is set in Studio and acts as the model's
--    pivot reference; its Position gives the model's effective world origin.
--
-- 2. Slope: the surface normal must be within 45 degrees of world-up.
--    The dot product of two unit vectors equals cos(θ) where θ is the angle
--    between them. math.acos recovers θ from that cosine. We clamp the dot
--    product to [-1, 1] first because floating-point errors can push it
--    slightly outside that range, which would cause math.acos to return NaN.
--    A result > 45 degrees means the surface is too steep (wall or ceiling).
--
-- State.CanPlace and the preview tint are both updated here to keep all
-- validity logic in one place.
local function ValidatePlacement(surfaceNormal: Vector3)
	local head = Character:WaitForChild("Head")

	local distance =
		(State.Preview.PrimaryPart.Position - head.Position).Magnitude

	local allowed = true

	if distance > MAX_RANGE then
		allowed = false
	end

	-- Vector3.yAxis is the constant unit vector (0, 1, 0).
	local dot   = surfaceNormal:Dot(Vector3.yAxis)
	local angle = math.acos(math.clamp(dot, -1, 1))

	if angle > math.rad(45) then
		allowed = false
	end

	State.CanPlace = allowed
	SetInvalid(not allowed)
end

-- CreatePreview clones the source model to produce a non-colliding ghost
-- that follows the cursor. Every BasePart is configured so it:
--   • Anchored = true   — not simulated by the physics solver
--   • CanCollide = false — no physical collision response
--   • CanQuery = false   — excluded from workspace:Raycast results
--   • CanTouch = false   — does not fire Touched events
-- Transparency is raised by 0.7 and clamped so models that are already
-- partially transparent do not exceed 1.0 (fully invisible).
-- State.Yaw resets to 0 so each new preview starts unrotated.
local function CreatePreview(model: Model)
	if State.Preview then
		State.Preview:Destroy()
	end

	local clone = model:Clone()

	for _, p in clone:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored      = true
			p.CanCollide    = false
			p.CanQuery      = false
			p.CanTouch      = false
			p.Transparency  = math.clamp(p.Transparency + 0.7, 0, 1)
		end
	end

	clone.Parent   = workspace
	State.Preview  = clone
	State.Yaw      = 0
end

-- ComputePlacementCF builds a CFrame whose up axis (Y column) aligns to the
-- hit surface normal, so placed objects sit flush on any angled surface.
--
-- Step 1 — Yawed forward vector:
--   CFrame.Angles(0, yaw, 0) is a rotation-only CFrame (no translation).
--   Multiplying a Vector3 by a CFrame applies the rotation to the vector.
--   This rotates world-forward (0,0,1) by the current yaw around world Y.
--
-- Step 2 — Project onto the surface plane:
--   A vector projected onto a plane with unit normal n is:
--     v_proj = v - n * (v · n)
--   Subtracting the component parallel to n leaves only the in-plane part.
--   .Unit normalises to length 1, required for CFrame.fromMatrix.
--
-- Step 3 — Right axis via cross product:
--   The cross product of two non-parallel vectors produces a third vector
--   perpendicular to both, following the right-hand rule.
--   projectedForward × normal gives a vector lying in the surface plane,
--   perpendicular to the forward direction — this is our right axis.
--
-- Step 4 — CFrame.fromMatrix(pos, rightVec, upVec):
--   Constructs a CFrame from an origin and explicit right/up column vectors.
--   The look vector (third column) is inferred as right × up, completing
--   an orthonormal basis. The result orients the model to the surface.
local function ComputePlacementCF(position: Vector3, normal: Vector3): CFrame
	local forward =
		(CFrame.Angles(0, State.Yaw, 0) * Vector3.zAxis)

	local projectedForward =
		(forward - normal * forward:Dot(normal)).Unit

	local right =
		projectedForward:Cross(normal).Unit

	return CFrame.fromMatrix(position, right, normal)
end

-- UpdatePreview runs every RenderStepped (before the frame is rendered).
-- dt is the elapsed seconds since the last frame, used to scale rotation so
-- it is frame-rate independent regardless of the client's FPS.
--
-- Execution order each frame:
--   1. Early-exit if no preview exists.
--   2. Raycast from cursor into the world.
--   3. Optionally snap the hit position to the grid.
--   4. Accumulate or snap yaw based on key state and snap mode.
--   5. Compute a surface-aligned CFrame and pivot the preview to it.
--   6. Run placement validation to update CanPlace and tint.
local function UpdatePreview(dt: number)
	local preview = State.Preview
	if not preview then return end

	-- workspace:Raycast(origin, direction, params) returns a RaycastResult
	-- containing Position, Normal, Instance, and Material, or nil on miss.
	-- A direction length of 1000 studs covers any reasonable view distance.
	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000,
		CastParams
	)

	if not result then return end

	local pos    = result.Position
	local normal = result.Normal

	-- Quantise world position to SNAP_DISTANCE grid when snapping is active.
	if State.Snapping then
		pos = Snap(pos, SNAP_DISTANCE)
	end

	-- Continuous rotation: accumulate yaw scaled by dt so speed is consistent
	-- at any frame rate. += is Luau syntactic sugar for State.Yaw = State.Yaw + …
	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	-- Discrete rotation snap: when snapping is on and no rotation key is held,
	-- lock yaw to the nearest 15-degree step. This uses the SNAP_ROTATION
	-- constant to give precise angular alignment without continuous drift.
	if State.Snapping and not State.Keys.E and not State.Keys.Q then
		State.Yaw = SnapYaw(State.Yaw)
	end

	-- PivotTo repositions the entire model relative to its PivotOffset,
	-- maintaining all parts' relative positions within the model.
	-- Yaw is already baked into the basis vectors inside ComputePlacementCF,
	-- so no additional CFrame.Angles rotation is applied here.
	local cf = ComputePlacementCF(pos, normal)
	preview:PivotTo(cf)

	ValidatePlacement(normal)
end

-- Place invokes the server-side TryPlace handler with the model name and its
-- current world CFrame from GetPivot. GetPivot returns the CFrame of the model's
-- pivot point, which is what was set by PivotTo.
-- The server is authoritative: it validates, spawns the real instance, and
-- returns "SUCCESS". On success the preview ghost is destroyed on the client.
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

-- DeleteSelected fires the delete remote with the currently targeted build.
-- FireServer is asynchronous and returns immediately; the server handles removal.
local function DeleteSelected()
	if State.DeleteTarget then
		DeleteBuild:FireServer(State.DeleteTarget)
	end
end

-- InputBegan fires for every input event the engine receives.
-- gpe (GameProcessedEvent) is true when the engine has already consumed the
-- input — for example, a click inside a ScreenGui or a keypress in the chat.
-- Returning early prevents accidental placements or deletions during UI use.
local function InputBegan(input: InputObject, gpe: boolean)
	if gpe then return end

	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = true

	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = true

	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- Branch on mode: delete mode fires the delete remote,
		-- otherwise attempt placement confirmation.
		if State.Deleting then
			DeleteSelected()
		else
			Place()
		end
	end
end

-- InputEnded resets the held-key flags so rotation stops when Q or E is
-- released. Not resetting these would cause perpetual rotation after release.
local function InputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = false
	end
end

-- Equipped is called when a tagged hammer enters the character.
-- It registers the three connections needed during active build mode.
-- table.insert appends each RBXScriptConnection to State.Connections so
-- DisconnectAll can clean them up as a batch on unequip.
--
-- RenderStepped fires every frame before rendering; it receives dt and is
-- the correct signal for per-frame visual updates like preview positioning.
-- InputBegan/Ended are sourced from UserInputService rather than the tool's
-- own events so Q/E still register even when the cursor is over a part.
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

-- Unequipped tears down all connections, destroys the ghost preview, and
-- clears the Tool reference. Called whenever the hammer leaves the character:
-- manual unequip, switching tools, death, or server kick.
local function Unequipped()
	DisconnectAll()

	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	State.Tool = nil
end

-- Character.ChildAdded fires when any Instance is parented to the character.
-- CollectionService:HasTag checks for the "HAMMER" tag at equip time,
-- so any tool with that tag activates build mode without name-matching.
Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		Equipped(child)
	end
end)

-- Character.ChildRemoved fires when a child leaves the character hierarchy.
-- We compare the removed child against State.Tool by identity (==), which is
-- an exact reference comparison, to confirm it is the active hammer rather
-- than any other tool or accessory that might be removed at the same time.
Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		Unequipped()
	end
end)
