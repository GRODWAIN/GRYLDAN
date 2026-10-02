--!nonstrict
-- In-game scene player. Installed by the plugin into ReplicatedStorage.BBS_Runtime and started
-- by StarterPlayerScripts.BBS_Player. Settings live as attributes on ReplicatedStorage.BBS_Data.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Playback = require(script.Parent.Playback)
local SceneData = require(script.Parent.SceneData)

local RuntimePlayer = {}

local function setting(name: string, default: any): any
	local root = SceneData.getRoot(false)
	local v = root and root:GetAttribute(name)
	if v == nil then
		return default
	end
	return v
end

local function makeLetterbox(player: Player): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "BBS_Letterbox"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	gui.Enabled = false
	for _, top in { true, false } do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.Size = UDim2.fromScale(1, 0.11)
		bar.AnchorPoint = Vector2.new(0, if top then 0 else 1)
		bar.Position = UDim2.fromScale(0, if top then 0 else 1)
		bar.Parent = gui
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

local function setCharacterHidden(player: Player, hidden: boolean)
	local character = player.Character
	if not character then
		return
	end
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			d.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

function RuntimePlayer.start()
	local player = Players.LocalPlayer
	ReplicatedStorage:WaitForChild(SceneData.ROOT_NAME, 10)
	local playback = Playback.new({ folderName = "BBS_LocalPuppets" })
	local letterbox = makeLetterbox(player)
	local active = false
	local savedFov = 70

	local function stop()
		if not active then
			return
		end
		active = false
		playback:destroy()
		RunService:UnbindFromRenderStep("BBS_HidePlayer")
		letterbox.Enabled = false
		setCharacterHidden(player, false)
		local camera = Workspace.CurrentCamera
		camera.CameraType = Enum.CameraType.Custom
		camera.FieldOfView = savedFov
	end

	local function start()
		local root = SceneData.getRoot(false)
		if active or not root then
			return
		end
		active = true
		local camera = Workspace.CurrentCamera
		savedFov = camera.FieldOfView
		local hasCamera = #SceneData.getCamera(root).keys > 0
		playback.useCamera = hasCamera
		if hasCamera then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		playback.loop = setting("Loop", false) == true
		letterbox.Enabled = setting("Letterbox", true) == true
		if setting("HidePlayer", true) == true then
			-- camera scripts reset LocalTransparencyModifier every frame, so re-apply after them
			RunService:BindToRenderStep("BBS_HidePlayer", Enum.RenderPriority.Camera.Value + 1, function()
				setCharacterHidden(player, true)
			end)
		end
		playback:refresh()
		playback:play(0)
	end

	playback.onStopped = stop

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local ok, key = pcall(function()
			return Enum.KeyCode[setting("PlayerKey", "P")]
		end)
		if ok and key and input.KeyCode == key then
			if active then
				stop()
			else
				start()
			end
		end
	end)

	if setting("Autoplay", false) == true then
		task.delay(setting("AutoplayDelay", 2), start)
	end

	return { start = start, stop = stop, playback = playback }
end

return RuntimePlayer
