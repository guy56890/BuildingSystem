-- Discord: guy56890 | Roblox: guy56890
--[[
	BuildingController (LocalScript)

	Manages the full client side of the hammer building tool.
	Covers ghost preview rendering, smooth CFrame interpolation, surface-aligned
	placement, delete mode with hover highlighting, rotation input, and server
	communication on confirmed actions.

	Key systems in this version:

	TweenService - color transitions on the preview animate between valid and
	invalid states instead of snapping instantly, giving clear visual feedback.

	SelectionBox - a Roblox adornment instance that draws a wire outline around
	the preview model so the player can clearly see its bounding volume.

	Highlight - a modern Roblox instance that renders a colored overlay on any
	model without touching its parts directly, used to mark the delete target.

	ContextActionService - binds the rotation keys with explicit input priority
	so other systems can override or sink the same keys cleanly if needed.

	SoundService - plays audio cues when placement validity changes and when a
	build is successfully placed, giving audio feedback alongside visual.

	CFrame:Lerp - each frame the preview glides toward its target CFrame rather
	than jumping to it instantly, making the ghost feel responsive but smooth.
]]

-- services

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

-- player refs

-- LocalPlayer is always present on the client, never nil
local Player = Players.LocalPlayer

-- wait for the character in case this script runs before spawn completes
local Character = Player.Character or Player.CharacterAdded:Wait()

-- Mouse provides the cursor ray direction we cast through the world each frame
local Mouse = Player:GetMouse()

-- remotes

-- BuildRemotes holds all server remotes for the building system
local Remotes = ReplicatedStorage:WaitForChild("BuildRemotes")

-- TryPlace is an InvokeServer so we can read success or failure back
local TryPlace = Remotes:WaitForChild("TryPlace")

-- DeletePlayerBuild is fire-and-forget, the server validates ownership itself
local DeleteBuild = Remotes:WaitForChild("DeletePlayerBuild")

-- sounds

-- these are expected to exist as Sound instances parented under SoundService
-- playing through SoundService.RollOffMaxDistance = 0 so they are always heard
local SoundPlaced = SoundService:WaitForChild("BuildPlaced")
local SoundInvalid = SoundService:WaitForChild("BuildInvalid")

-- constants

-- furthest distance from the head where placements are accepted
local MAX_RANGE = 30

-- world space grid cell size used when snapping mode is active
local SNAP_DISTANCE = 0.5

-- radians per second the yaw changes while a rotation key is held
local ROT_SPEED = math.rad(45)

-- CollectionService tag that identifies a tool instance as a hammer
local HAMMER_TAG = "HAMMER"

-- CollectionService tag applied by the server to every placed build model
-- used in delete mode to identify which models in the world are player builds
local BUILD_TAG = "PlayerBuild"

-- lerp alpha multiplier for smooth preview movement, higher means snappier
-- multiplied by delta time so the catch-up speed is frame rate independent
local PREVIEW_LERP = 18

-- TweenInfo shared by all color transition tweens on the preview parts
-- short duration and Sine easing keeps the flash snappy but not jarring
local COLOR_TWEEN_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

-- color constants used for the invalid state flash and the delete highlight
local COLOR_INVALID = Color3.new(1, 0.2, 0.2)
local COLOR_SELECTION_BOX = Color3.fromRGB(80, 200, 255)

-- head is resolved once here because validatePlacement runs every frame
-- and calling WaitForChild inside a hot path would yield unexpectedly
local Head = Character:WaitForChild("Head")

-- raycast setup

-- new RaycastParams for all preview raycasts
local CastParams = RaycastParams.new()

-- Exclude mode means listed instances are skipped by the raycast
CastParams.FilterType = Enum.RaycastFilterType.Exclude

-- exclude the character so the cursor ray never registers hits on our own body
CastParams.FilterDescendantsInstances = { Character }

-- state

-- all runtime mutable data lives in one table so equip/unequip can reset it
-- cleanly without tracking individual variables scattered across the module
local State = {
	Tool = nil,            -- the currently equipped tool instance, or nil
	Preview = nil,         -- the ghost model in the world, or nil
	SelectionBox = nil,    -- SelectionBox adornment outlining the preview
	DeleteHighlight = nil, -- Highlight instance placed on the hovered build
	DeleteTarget = nil,    -- the PlayerBuild model the cursor is currently over
	TargetCF = CFrame.new(),  -- where the preview should ideally be this frame
	CurrentCF = CFrame.new(), -- the lerped CFrame the preview is actually at
	Yaw = 0,               -- accumulated rotation in radians from Q/E input
	Snapping = false,      -- whether grid snapping is currently enabled
	Deleting = false,      -- whether the player is in delete mode
	CanPlace = false,      -- whether the last validation pass allowed placement
	ColorTweens = {},      -- active TweenService tweens for the color flash
	Keys = {               -- held state for rotation keys, set by ContextActionService
		E = false,
		Q = false,
	},
	Connections = {},      -- all active RBXScriptConnection objects for batch cleanup
}

-- utilities

-- disconnects every tracked connection and empties the list
-- called on unequip so listeners from one equip do not carry into the next
local function disconnectAll()
	for _, c in State.Connections do
		c:Disconnect()
	end
	table.clear(State.Connections)
end

-- rounds every axis of a Vector3 to the nearest multiple of grid
-- snaps the hit position to a fixed world grid so builds align cleanly
local function snap(v: Vector3, grid: number): Vector3
	return Vector3.new(
		math.round(v.X / grid) * grid,
		math.round(v.Y / grid) * grid,
		math.round(v.Z / grid) * grid
	)
end

-- selection box

-- creates a SelectionBox that draws a wire outline around the given model
-- SelectionBox is a Roblox adornment that renders on top without modifying parts
-- SurfaceTransparency 1 hides the face fill so only the edges are visible
local function createSelectionBox(adornee: Model): SelectionBox
	local box = Instance.new("SelectionBox")
	box.Color3 = COLOR_SELECTION_BOX
	box.LineThickness = 0.04
	box.SurfaceTransparency = 1
	box.Adornee = adornee
	-- parent to workspace so it renders in the 3D world
	box.Parent = workspace
	return box
end

-- delete highlight

-- creates a Highlight that renders a colored overlay on whatever its Adornee is
-- Highlight is a modern API that avoids having to iterate and recolor all parts
-- setting Adornee to nil hides it without destroying and recreating it each frame
local function createDeleteHighlight(): Highlight
	local h = Instance.new("Highlight")
	h.FillColor = COLOR_INVALID
	h.OutlineColor = Color3.new(1, 0, 0)
	h.FillTransparency = 0.5
	h.OutlineTransparency = 0
	-- initially no adornee so the highlight is invisible until the cursor lands on a build
	h.Adornee = nil
	h.Parent = workspace
	return h
end

-- color tweens

-- cancels all in-progress color tweens before starting new ones
-- prevents old tweens from fighting a newly triggered transition
local function cancelColorTweens()
	for _, t in State.ColorTweens do
		t:Cancel()
	end
	table.clear(State.ColorTweens)
end

-- tweens all BaseParts in the preview to targetColor using TweenService
-- the original colour is saved as a part attribute on the first call so we
-- can restore it later without a separate lookup table
local function tweenPreviewToColor(targetColor: Color3)
	if not State.Preview then return end
	cancelColorTweens()

	for _, part in State.Preview:GetDescendants() do
		if not part:IsA("BasePart") then continue end

		-- save the original colour before we overwrite it for the first time
		if not part:GetAttribute("OriginalColor") then
			part:SetAttribute("OriginalColor", part.Color)
		end

		-- TweenService:Create returns a Tween that animates the Color property
		local tween = TweenService:Create(part, COLOR_TWEEN_INFO, { Color = targetColor })
		tween:Play()

		-- track it so cancelColorTweens can stop it if the state flips again mid-tween
		table.insert(State.ColorTweens, tween)
	end
end

-- restores all preview parts back to their stored original colours via tween
local function restorePreviewColor()
	if not State.Preview then return end
	cancelColorTweens()

	for _, part in State.Preview:GetDescendants() do
		if not part:IsA("BasePart") then continue end

		local stored = part:GetAttribute("OriginalColor")
		if not stored then continue end

		local tween = TweenService:Create(part, COLOR_TWEEN_INFO, { Color = stored })
		tween:Play()
		table.insert(State.ColorTweens, tween)
	end
end

-- placement validation

-- checks distance from the head and the surface slope against allowed limits
-- the dot product gives the cosine of the angle between the normal and world up
-- acos converts that to an angle, clamped to avoid NaN at the poles of the range
-- only reacts when validity changes so tweens and sounds do not fire every frame
local function validatePlacement(surfaceNormal: Vector3)
	local distance = (State.Preview.PrimaryPart.Position - Head.Position).Magnitude
	local dot = surfaceNormal:Dot(Vector3.yAxis)
	local angle = math.acos(math.clamp(dot, -1, 1))

	local allowed = distance <= MAX_RANGE and angle <= math.rad(45)

	-- guard: skip all the tween and sound work if validity has not changed
	if allowed == State.CanPlace then return end

	State.CanPlace = allowed

	if not allowed then
		-- tween to red and play the invalid cue when the spot becomes disallowed
		tweenPreviewToColor(COLOR_INVALID)
		SoundInvalid:Play()
	else
		-- tween back to original colours when the spot becomes valid again
		restorePreviewColor()
	end
end

-- preview creation

-- clones the source model into a ghost with non-physical parts and attaches
-- a SelectionBox adornment to it so the player can see the bounding volume
local function createPreview(model: Model)
	-- tear down any previous preview and its adornment before making a new one
	if State.Preview then
		State.Preview:Destroy()
	end
	if State.SelectionBox then
		State.SelectionBox:Destroy()
	end

	local clone = model:Clone()

	for _, part in clone:GetDescendants() do
		if not part:IsA("BasePart") then continue end

		-- anchored so the physics engine does not move the ghost
		part.Anchored = true

		-- the ghost must not physically interact with the world or other players
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false

		-- make the ghost translucent so the player can see through it
		part.Transparency = math.clamp(part.Transparency + 0.7, 0, 1)

		-- no shadow so the ghost does not cast a misleading shadow on the ground
		part.CastShadow = false
	end

	clone.Parent = workspace
	State.Preview = clone
	State.Yaw = 0

	-- seed both CFrame trackers to the model's current pivot so the lerp does
	-- not launch the preview from the world origin on the very first frame
	local initialCF = clone:GetPivot()
	State.TargetCF = initialCF
	State.CurrentCF = initialCF

	-- attach the selection box outline now that the clone is in the world
	State.SelectionBox = createSelectionBox(clone)
end

-- orientation math

--[[
	Builds a CFrame that positions and orients an object flush with a surface.

	Step 1 - Rotate world forward by current yaw to get the facing direction.
	Step 2 - Project that forward onto the surface plane so the object does not
	         tilt into or float off sloped terrain.
	Step 3 - Cross the projected forward with the normal to get the right vector,
	         completing an orthonormal coordinate basis.
	Step 4 - CFrame.fromMatrix assembles position and the three axis vectors
	         into the final orientation ready to pass to PivotTo.
]]
local function computePlacementCF(position: Vector3, normal: Vector3): CFrame
	-- rotate world forward by yaw to get the current facing direction
	local forward = CFrame.Angles(0, State.Yaw, 0) * Vector3.zAxis

	-- subtract the component of forward that runs along the normal
	-- this projects forward onto the surface plane so the object sits flush
	local projectedForward = (forward - normal * forward:Dot(normal)).Unit

	-- cross product of projected forward and normal gives the right axis
	local right = projectedForward:Cross(normal).Unit

	-- fromMatrix takes (position, rightVector, upVector)
	-- using normal as up so the object aligns to the surface it sits on
	return CFrame.fromMatrix(position, right, normal)
end

-- delete hover update

-- runs each frame while delete mode is active
-- casts a full-world ray (no exclusions) to find whatever part is under the cursor
-- walks up the hierarchy to find a Model tagged as a PlayerBuild, then points
-- the Highlight at it so the player can see exactly what will be deleted
local function updateDeleteHover()
	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000
		-- no CastParams here so the ray hits real geometry including placed builds
	)

	local newTarget = nil

	if result and result.Instance then
		-- the hit part might be a child of the build model, walk up to the root model
		local model = result.Instance:FindFirstAncestorOfClass("Model")

		-- only accept it as a delete candidate if it carries the build tag
		if model and CollectionService:HasTag(model, BUILD_TAG) then
			newTarget = model
		end
	end

	-- skip the Highlight update when the target has not changed this frame
	if newTarget == State.DeleteTarget then return end

	State.DeleteTarget = newTarget

	-- setting Adornee to nil hides the Highlight without destroying it
	-- setting it to a model moves the overlay onto that model instantly
	if State.DeleteHighlight then
		State.DeleteHighlight.Adornee = newTarget
	end
end

-- preview update

-- runs every RenderStepped, handles both normal placement preview and delete hover
-- in placement mode: repositions the ghost, accumulates yaw, and validates
-- in delete mode: delegates to updateDeleteHover and returns early
local function updatePreview(dt: number)
	if State.Deleting then
		updateDeleteHover()
		return
	end

	local preview = State.Preview
	if not preview then return end

	-- cast from the camera through the cursor to find the surface under it
	local result = workspace:Raycast(
		Mouse.UnitRay.Origin,
		Mouse.UnitRay.Direction * 1000,
		CastParams
	)

	-- leave the preview where it was if the cursor is not over any geometry
	if not result then return end

	local pos = result.Position
	local normal = result.Normal

	-- round the hit position to the nearest grid cell if snapping is active
	if State.Snapping then
		pos = snap(pos, SNAP_DISTANCE)
	end

	-- accumulate yaw from held rotation keys, scaled by dt for frame independence
	if State.Keys.E then
		State.Yaw += ROT_SPEED * dt
	elseif State.Keys.Q then
		State.Yaw -= ROT_SPEED * dt
	end

	-- store the ideal CFrame for this frame as the lerp target
	State.TargetCF = computePlacementCF(pos, normal)

	-- lerp the rendered CFrame toward the target so the ghost glides smoothly
	-- math.min clamps the alpha to 1 so high dt values do not overshoot
	State.CurrentCF = State.CurrentCF:Lerp(State.TargetCF, math.min(dt * PREVIEW_LERP, 1))

	-- move the preview to the interpolated CFrame this frame
	preview:PivotTo(State.CurrentCF)

	-- re-validate against the live surface every frame since the cursor moves
	validatePlacement(normal)
end

-- actions

-- sends the placement request to the server with the model name and pivot CFrame
-- the preview is only removed after the server confirms success, so a rejected
-- placement leaves the ghost up and lets the player pick a different spot
local function place()
	if not State.Preview or not State.CanPlace then return end

	local result = TryPlace:InvokeServer(
		State.Preview.Name,
		State.Preview:GetPivot()
	)

	if result == "SUCCESS" then
		-- play the placed sound before destroying the preview
		SoundPlaced:Play()

		-- clean up the selection box adornment first, then the model
		if State.SelectionBox then
			State.SelectionBox:Destroy()
			State.SelectionBox = nil
		end

		State.Preview:Destroy()
		State.Preview = nil
	end
end

-- fires the deletion remote with the hovered build model
-- the server is responsible for ownership validation before removing anything
local function deleteSelected()
	if State.DeleteTarget then
		DeleteBuild:FireServer(State.DeleteTarget)
		-- clear the local reference so the stale target is not sent again
		State.DeleteTarget = nil
		if State.DeleteHighlight then
			State.DeleteHighlight.Adornee = nil
		end
	end
end

-- input - rotation

-- ContextActionService callback for the Q and E rotation keys
-- inputState Begin means the key was pressed, End means it was released
-- returning Pass lets any other system listening to the same key still receive it
local function onRotateInput(actionName: string, inputState: Enum.UserInputState, _: InputObject)
	local holding = inputState == Enum.UserInputState.Begin

	if actionName == "BuildRotateCW" then
		State.Keys.E = holding
	elseif actionName == "BuildRotateCCW" then
		State.Keys.Q = holding
	end

	return Enum.ContextActionResult.Pass
end

-- binds the rotation keys through ContextActionService with Default priority
-- false as the second argument means no on-screen touch button is created
local function bindRotationActions()
	ContextActionService:BindActionAtPriority(
		"BuildRotateCW",
		onRotateInput,
		false,
		Enum.ContextActionPriority.Default.Value,
		Enum.KeyCode.E
	)
	ContextActionService:BindActionAtPriority(
		"BuildRotateCCW",
		onRotateInput,
		false,
		Enum.ContextActionPriority.Default.Value,
		Enum.KeyCode.Q
	)
end

-- removes both rotation bindings when the tool is unequipped
local function unbindRotationActions()
	ContextActionService:UnbindAction("BuildRotateCW")
	ContextActionService:UnbindAction("BuildRotateCCW")
end

-- input - mouse

-- handles mouse clicks while the tool is equipped
-- gpe is true when a UI element consumed the input before reaching the game world
local function inputBegan(input: InputObject, gpe: boolean)
	-- do not react to clicks that were swallowed by a text box or UI button
	if gpe then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if State.Deleting then
			deleteSelected()
		else
			place()
		end
	end
end

-- tool lifecycle

-- sets up all connections and creates the delete highlight when the hammer equips
local function equipped(tool: Tool)
	State.Tool = tool

	-- create the delete highlight once here so we can reuse it by changing Adornee
	State.DeleteHighlight = createDeleteHighlight()

	-- bind Q and E for rotation through ContextActionService
	bindRotationActions()

	-- update the preview and delete hover every render frame
	table.insert(State.Connections, RunService.RenderStepped:Connect(updatePreview))

	-- listen for mouse clicks to confirm placement or deletion
	table.insert(State.Connections, UserInputService.InputBegan:Connect(inputBegan))
end

-- tears everything down cleanly when the hammer leaves the character
local function unequipped()
	-- cut all listeners before touching any state so no callbacks fire mid-cleanup
	disconnectAll()

	-- remove ContextActionService bindings so rotation keys work normally again
	unbindRotationActions()

	-- kill any in-progress color tweens so they do not run after the preview is gone
	cancelColorTweens()

	-- remove the selection box adornment from the world
	if State.SelectionBox then
		State.SelectionBox:Destroy()
		State.SelectionBox = nil
	end

	-- remove the delete highlight from the world
	if State.DeleteHighlight then
		State.DeleteHighlight:Destroy()
		State.DeleteHighlight = nil
	end

	-- remove the ghost preview model from the world
	if State.Preview then
		State.Preview:Destroy()
		State.Preview = nil
	end

	-- clear the stored references so the state is clean for the next equip
	State.Tool = nil
	State.DeleteTarget = nil
end

-- tool detection

-- ChildAdded fires for every instance parented to the character
-- the tag check filters it down to only instances marked as hammers
Character.ChildAdded:Connect(function(child)
	if CollectionService:HasTag(child, HAMMER_TAG) then
		equipped(child)
	end
end)

-- compare by object reference so this only triggers for the exact tracked tool
-- using a tag check here would break if two hammers were equipped simultaneously
Character.ChildRemoved:Connect(function(child)
	if child == State.Tool then
		unequipped()
	end
end)
