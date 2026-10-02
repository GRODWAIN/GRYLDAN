--!nonstrict
-- Samples the local character (root CFrame + every Motor6D.Transform) at a fixed rate.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = script.Parent.Parent.Shared
local Codec = require(Shared.Codec)
local Rig = require(Shared.Rig)
local Appearance = require(script.Parent.Appearance)

local Recorder = {}
Recorder.__index = Recorder

function Recorder.new()
	return setmetatable({ recording = false, elapsed = 0 }, Recorder)
end

function Recorder:start(opts): (boolean, string?)
	local player = Players.LocalPlayer
	local character = player and player.Character
	if not character then
		return false, "Нет персонажа — нужен режим Play (F5)"
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then
		return false, "У персонажа нет HumanoidRootPart"
	end

	local jointMap = Rig.getJoints(character)
	local parts = {}
	for name in jointMap do
		table.insert(parts, name)
	end
	table.sort(parts)
	local motors = table.create(#parts)
	for i, name in parts do
		motors[i] = jointMap[name]
	end

	local desc = nil
	if humanoid then
		pcall(function()
			desc = Appearance.serialize(humanoid:GetAppliedDescription())
		end)
	end

	local fps = math.clamp(math.floor(opts.fps or 30), 5, 60)
	self.rec = {
		id = Codec.newId(),
		name = opts.name or player.DisplayName,
		fps = fps,
		rig = if humanoid then humanoid.RigType.Name else "R15",
		userId = player.UserId,
		desc = desc,
		parts = parts,
		frames = {},
	}
	self.recording = true
	self.elapsed = 0

	local interval = 1 / fps
	local nextSample = 0
	local frames = self.rec.frames
	local lastJoints = table.create(#motors, CFrame.identity)
	local lastRoot = root.CFrame
	local function sample()
		-- after death or respawn the old parts are gone: hold the last pose
		if root.Parent then
			lastRoot = root.CFrame
			local joints = table.create(#motors)
			for i, motor in motors do
				joints[i] = if motor.Parent then motor.Transform else lastJoints[i]
			end
			lastJoints = joints
		end
		table.insert(frames, { root = lastRoot, joints = lastJoints })
	end
	sample()
	nextSample = interval
	self.conn = RunService.Heartbeat:Connect(function(dt)
		self.elapsed += dt
		-- repeat the current pose on slow frames so frame index always equals time * fps
		while nextSample <= self.elapsed do
			sample()
			nextSample += interval
		end
	end)
	return true, nil
end

function Recorder:stop()
	if not self.recording then
		return nil
	end
	self.recording = false
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	local rec = self.rec
	self.rec = nil
	Codec.computeLength(rec)
	return rec
end

return Recorder
