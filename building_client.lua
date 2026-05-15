-- Discord: guy56890 | Roblox: guy56890
--[[
	BuildingController (LocalScript)

	Manages the client side of the hammer building tool.
	Handles ghost preview rendering, placement validation, rotation input,
	and talking to the server only when a placement or deletion is confirmed.

	The server is never contacted for visual updates, only for final actions.
	This keeps the preview feeling instant and avoids remote lag on every frame.

	All runtime state lives in one State table so nothing leaks into the
	module scope and everything is easy to reset on unequip.

	Connections are stored in a list and disconnected together on unequip
	so listeners do not pile up if the player equips the tool multiple times.
]]

-- services

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- player refs

-- LocalPlayer is always available on the client, this never returns nil
local Player = Players.LocalPlayer

-- wait for the character in case this script runs before it loads in
local Character = Player.Character or Player.CharacterAdded:Wait()

-- Mouse is used to read the cursor ray direction each frame for raycasting
local Mouse = Player:GetMouse()

-- remotes

-- BuildRemotes is the folder that holds all remotes for the building system
local Remotes = ReplicatedStorage:WaitForChild("BuildRemotes")

-- TryPlace is an invoke so we can get a success or failure back from the server
local TryPlace = Remotes:WaitForChild("TryPlace")

-- DeletePlayerBuild just needs a fire, no response needed for deletion
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- constants

-- furthest distance from the head that a placement is allowed
local MAX_RANGE = 30

-- world space grid size used when snapping is active
local SNAP_DISTANCE = 0.5

-- how many radians per second the yaw changes while Q or E is held
local ROT_SPEED = math.rad(45)

-- the CollectionService tag that marks a tool as a hammer
local HAMMER_TAG = "HAMMER"

-- head is fetched once here rather than inside validatePlacement because
-- validatePlacement runs every frame and WaitForChild would yield each time
local Head = Character:WaitForChild("Head")

-- raycast filter setup

-- a new RaycastParams object to hold the filter settings for preview raycasts
local CastParams = RaycastParams.new()

-- Exclude mode means the listed instances are ignored by raycasts
CastParams.FilterType = Enum.RaycastFilterType.Exclude

-- the character is excluded so raycasts do not hit the player's own body parts
CastParams.FilterDescendantsInstances = { Character }

-- state

-- single table that holds everything that changes at runtime
-- keeping it here means unequipped can wipe relevant fields in one place
local State = {
	Tool = nil,           -- the tool instance currently equipped, or nil
	Preview = nil,        -- the ghost model sitting in the world, or nil
	DeleteTarget = nil,   -- the build part the player is hovering over to delete
	Yaw = 0,              -- accumulated rotation in radians from Q and E input
	Snapping = false,     -- whether grid snapping is currently on
	Deleting = false,     -- whether the player is in delete mode
	CanPlace = false,     -- whether the current preview position passes validation
	Keys = {              -- tracks which rotation keys are currently held down
		Q = false,
		E = false,
	},
	Connections = {},     -- list of all active RBXScriptConnection objects
}

-- utilities

-- disconnects every stored connection and empties the list
-- called on unequip so listeners from the previous equip do not keep running
local function disconnectAll()
	for _, c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

-- rounds a Vector3 to the nearest multiple of grid on each axis
-- this makes the preview snap to a fixed grid instead of sliding freely
local function snap(v: Vector3, grid: number): Vector3
	return Vector3.new(
		math.round(v.X / grid) * grid,
		math.round(v.Y / grid) * grid,
		math.round(v.Z / grid) * grid
	)
end

-- preview colouring

-- toggles the preview between its normal colour and solid red
-- red signals that the current position is not a valid placement
-- the original colour is stored as a part attribute so it can be restored
-- exactly without needing a separate lookup table anywhere
local function setInvalid(toggle: boolean)
	-- nothing to colour if there is no preview in the world
	if not State.Preview then return end

	for _, part in State.Preview:GetDescendants() do
		-- skip non-visual instances like scripts or attachments
		if not part:IsA("BasePart") then continue end

		-- read back whatever colour we stored before we changed it
		local stored = part:GetAttribute("OriginalColor")

		if toggle then
			-- only overwrite if we have not already done so this cycle
			if not stored then
				-- save the current colour before changing it
				part:SetAttribute("OriginalColor", part.Color)
				-- set to red to indicate the placement is invalid
				part.Color = Color3.new(1, 0, 0)
			end
		else
			-- only restore if we actually saved a colour previously
			if stored then
				-- put the original colour back
				part.Color = stored
				-- clear the saved value so the next invalid toggle starts fresh
				part:SetAttribute("OriginalColor", nil)
			end
		end
	end
end

-- placement validation

-- checks whether the current preview position is actually allowed
-- two conditions must both pass: range from the head, and surface angle
-- the dot product of the surface normal against world up gives the cosine
-- of the angle between them, acos converts that to the angle in radians
-- math.clamp guards acos against returning NaN when the dot is exactly 1 or -1
-- which can happen on perfectly flat or perfectly inverted surfaces
local function validatePlacement(surfaceNormal: Vector3)
	-- straight line distance from the player's head to the preview pivot
	local distance = (State.Preview.PrimaryPart.Position - Head.Position).Magnitude

	-- how closely the surface normal points straight up
	-- a value of 1 means flat ground, a value of 0 means a vertical wall
	local dot = surfaceNormal:Dot(Vector3.yAxis)

	-- convert the dot product to an angle, clamped to avoid NaN at the poles
	local angle = math.acos(math.clamp(dot, -1, 1))

	-- placement is only valid if both the range and the slope are within limits
	State.CanPlace = distance <= MAX_RANGE and angle <= math.rad(45)

	-- show red when invalid, restore normal colour when valid
	setInvalid(not State.CanPlace)
end

-- preview creation

-- clones the source model to create a ghost that follows the cursor
-- every BasePart on the clone is made non-physical so it cannot interfere
-- with the world, other players, or subsequent raycasts
local function createPreview(model: Model)
	-- destroy any previous preview before creating a new one to avoid duplicates
	if State.Preview then
		State.Preview:Destroy()
	end

	-- clone the full model so we get all its parts and descendants
	local clone = model:Clone()

	for _, part in clone:GetDescendants() do
		-- only configure physical parts, skip scripts and decorators
		if not part:IsA("BasePart") then continue end

		-- anchored so physics do not move it while the player is aiming
		part.Anchored = true

		-- CanCollide off so players and objects can pass through the ghost
		part.CanCollide = false

		-- CanQuery off so raycasts do not hit the ghost itself
		part.CanQuery = false

		-- CanTouch off so Touched events do not fire on the ghost
		part.CanTouch = false

		-- raise transparency to make the ghost look translucent
		-- clamped so parts that are already semi-transparent stay valid
		part.Transparency = math.clamp(part.Transparency + 0.7, 0, 1)
	end

	-- put the clone into the world so it becomes visible
	clone.Parent = workspace

	-- store the reference so other functions can read and move it
	State.Preview = clone

	-- reset yaw so each new preview starts with no accumulated rotation
	State.Yaw = 0
end

-- orientation math

--[[
	Builds a CFrame that positions and orients an object on a surface.

	The object needs to sit flush with the surface even on slopes, and the
	player needs to be able to spin it around the surface normal with Q/E.

	Step 1 - Rotate the world forward vector by the current yaw so we know
	         which direction the front of the object is pointing.

	Step 2 - Project that forward vector onto the surface plane by subtracting
	         the component of it that runs along the normal. This removes any
	         tilt that would cause the object to clip into or float off the
	         surface, keeping it flush even on angled terrain.

	Step 3 - Cross the projected forward with the normal to get a right vector
	         that is perpendicular to both. This completes the coordinate basis.

	Step 4 - CFrame.fromMatrix assembles the position and three axis vectors
	         into a full orientation CFrame ready to pass to PivotTo.
]]
local function computePlacementCF(position: Vector3, normal: Vector3): CFrame
	-- rotate world forward by yaw to get the current facing direction
	local forward = CFrame.Angles(0, State.Yaw, 0) * Vector3.zAxis

	-- subtract the component of forward that is parallel to the normal
	-- this projects forward onto the plane defined by the surface
	local projectedForward = (forward - normal * forward:Dot(normal)).Unit

	-- cross product gives a vector perpendicular to both projected forward and normal
	local right = projectedForward:Cross(normal).Unit

	-- fromMatrix takes position, then the right and up axis vectors
	-- we use the surface normal as up so the object sits on the surface
	return CFrame.fromMatrix(position, right, normal)
end

-- preview update

-- runs every RenderStepped to reposition the ghost under the cursor
-- also accumulates yaw from held keys and re-validates the position each frame
local function updatePreview(dt: number)
	local preview = State.Preview

	-- nothing to update if no preview exists
	if not preview then return end

	-- cast a ray from the camera through the cursor position into the world
	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000,
		CastParams
	)

	-- if the ray hit nothing, leave the preview where it was last frame
	if not result then return end

	local pos = result.Position
	local normal = result.Normal

	-- round the hit position to the nearest grid cell if snapping is on
	if State.Snapping then
		pos = snap(pos, SNAP_DISTANCE)
	end

	-- accumulate yaw scaled by delta time for frame rate independent speed
	-- E rotates one direction, Q rotates the other
	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	-- computePlacementCF already bakes the full yaw into the basis vectors
	-- so no extra rotation is applied to the result after this call
	preview:PivotTo(computePlacementCF(pos, normal))

	-- re-check range and slope every frame since the cursor may have moved
	validatePlacement(normal)
end

-- actions

-- sends a placement request to the server with the model name and final CFrame
-- only fires if there is a preview and the last validation pass succeeded
-- the preview is only destroyed if the server sends back a success response
-- a rejected placement leaves the ghost up so the player can try a new spot
local function place()
	-- bail early if there is nothing to place or the position is invalid
	if not State.Preview or not State.CanPlace then return end

	-- send the model name and its current CFrame to the server for validation
	local result = TryPlace:InvokeServer(
		State.Preview.Name,
		State.Preview:GetPivot()
	)

	-- only remove the preview if the server confirmed the placement went through
	if result == "SUCCESS" then
		State.Preview:Destroy()
		State.Preview = nil
	end
end

-- fires the deletion remote with the target part reference
-- the server handles ownership checks before actually removing the build
local function deleteSelected()
	-- only fire if we actually have a target to delete
	if State.DeleteTarget then
		DeleteBuild:FireServer(State.DeleteTarget)
	end
end

-- input

-- handles key presses and mouse clicks while the tool is equipped
-- gpe is true when the game engine already consumed the input for a UI element
local function inputBegan(input: InputObject, gpe: boolean)
	-- ignore input that was swallowed by a text box or other UI element
	if gpe then return end

	if input.KeyCode == Enum.KeyCode.E then
		-- mark E as held so updatePreview can rotate the preview next frame
		State.Keys.E = true

	elseif input.KeyCode == Enum.KeyCode.Q then
		-- mark Q as held so updatePreview rotates the other way next frame
		State.Keys.Q = true

	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		-- left click confirms whichever mode is currently active
		if State.Deleting then
			deleteSelected()
		else
			place()
		end
	end
end

-- clears key flags when the player lifts a key
-- this stops the yaw from accumulating the moment the key is no longer held
local function inputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.E then
		State.Keys.E = false
	elseif input.KeyCode == Enum.KeyCode.Q then
		State.Keys.Q = false
	end
end

-- tool lifecycle

-- sets up all listeners when the hammer is equipped
-- each connection is pushed into State.Connections so they all die together on unequip
local function equipped(tool: Tool)
	-- store the tool reference so unequipped can match it in ChildRemoved
	State.Tool = tool

	-- reposition the preview every frame in sync with the camera
	table.insert(State.Connections, RunService.RenderStepped:Connect(updatePreview))

	-- respond to key presses and mouse clicks
	table.insert(State.Connections, UserInputService.InputBegan:Connect(inputBegan))

	-- respond to key releases so rotation stops when the key is lifted
	table.insert(State.Connections, UserInputService.InputEnded:Connect(inputEnded))
end

-- tears everything down when the hammer leaves the character
-- cuts all listeners and removes the ghost model from the world
local function unequipped()
	-- disconnect first so no callbacks fire during the cleanup below
	disconnectAll()

	-- remove the ghost if it is still sitting in the world
	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	-- clear the tool reference so the state is clean for the next equip
	State.Tool = nil
end

-- tool detection

-- ChildAdded fires for every instance added to the character, not just tools
-- the tag check narrows it to only instances flagged as hammers
Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		equipped(child)
	end
end)

-- compare by object reference so this only triggers for the exact tracked tool
-- a tag check here would break if two hammers were somehow equipped at once
Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		unequipped()
	end
end)
