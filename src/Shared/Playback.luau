--!nonstrict
-- Drives puppets (and optionally the camera) from scene data. Used by the plugin in edit mode,
-- by the plugin inside a playtest while recording, and by the in-game player.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Codec = require(script.Parent.Codec)
local CameraTrack = require(script.Parent.CameraTrack)
local Rig = require(script.Parent.Rig)
local SceneData = require(script.Parent.SceneData)

local Playback = {}
Playback.__index = Playback

function Playback.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Playback)
	self.folderName = opts.folderName or "BBS_Puppets"
	self.puppets = {}
	self.exclude = {}
	self.time = 0
	self.playing = false
	self.loop = false
	self.useCamera = false
	self.onTime = nil
	self.onStopped = nil
	return self
end

function Playback:getPuppetFolder(): Folder
	local f = self.puppetFolder
	if f and f.Parent then
		return f
	end
	f = Workspace:FindFirstChild(self.folderName)
	if not f then
		f = Instance.new("Folder")
		f.Name = self.folderName
		-- puppets are regenerated from data: never saved with the place or copied into playtests
		f.Archivable = false
		f.Parent = Workspace
	end
	self.puppetFolder = f
	return f
end

function Playback:clearPuppet(state)
	if state.model then
		state.model:Destroy()
	end
	state.model = nil
	state.rig = nil
	state.skin = nil
end

function Playback:refresh()
	local root = SceneData.getRoot(false)
	local alive = {}
	if root then
		for _, actor in SceneData.listActors(root) do
			alive[actor] = true
			if not self.puppets[actor] then
				self.puppets[actor] = {}
			end
		end
	end
	for actor, state in self.puppets do
		if not alive[actor] then
			self:clearPuppet(state)
			self.puppets[actor] = nil
		end
	end
	local folder = Workspace:FindFirstChild(self.folderName)
	if folder then
		local tracked = {}
		for _, state in self.puppets do
			if state.model then
				tracked[state.model] = true
			end
		end
		for _, child in folder:GetChildren() do
			if not tracked[child] then
				child:Destroy()
			end
		end
	end
end

function Playback:invalidate(actor: Instance?)
	if actor then
		local state = self.puppets[actor]
		if state then
			self:clearPuppet(state)
		end
	else
		for _, state in self.puppets do
			self:clearPuppet(state)
		end
	end
end

function Playback:getPuppet(actor: Instance): Model?
	local state = self.puppets[actor]
	return state and state.model
end

function Playback:ensureSkin(actor: Instance, state, skinName: string?): Model?
	if state.skin == skinName and state.model and state.model.Parent then
		return state.model
	end
	self:clearPuppet(state)
	state.skin = skinName
	if not skinName or skinName == SceneData.HIDDEN_SKIN then
		return nil
	end
	local source = SceneData.getSkin(actor, skinName)
	if not source then
		return nil
	end
	local wasArchivable = source.Archivable
	source.Archivable = true
	local model = source:Clone()
	source.Archivable = wasArchivable
	model.Name = SceneData.getName(actor)
	model:SetAttribute("BBS_ActorId", actor.Name)
	state.rig = Rig.prepare(model)
	model.Parent = self:getPuppetFolder()
	state.model = model
	return model
end

function Playback:evaluateActor(actor: Instance, state, t: number)
	local enabled = actor:GetAttribute("Enabled") ~= false and not self.exclude[actor.Name]
	local rel = t - (tonumber(actor:GetAttribute("Offset")) or 0)
	local skin = if enabled then SceneData.skinAt(actor, rel) else nil
	local model = self:ensureSkin(actor, state, skin)
	if not model then
		return
	end
	local rec = SceneData.getRecording(actor)
	if not rec then
		return
	end
	local rootCf, joints = Codec.sample(rec, rel)
	if rootCf then
		Rig.apply(state.rig, model, rec.parts, rootCf, joints)
	end
end

function Playback:evaluate(t: number)
	self.time = t
	local root = SceneData.getRoot(false)
	if root then
		for actor, state in self.puppets do
			if actor.Parent then
				local ok, err = pcall(self.evaluateActor, self, actor, state, t)
				if not ok then
					warn("[BBS Studio] " .. SceneData.getName(actor) .. ": " .. tostring(err))
				end
			end
		end
		if self.useCamera then
			local cf, fov = CameraTrack.evaluate(SceneData.getCamera(root), t)
			local cam = Workspace.CurrentCamera
			if cf and cam then
				cam.CFrame = cf
				cam.Focus = cf * CFrame.new(0, 0, -10)
				cam.FieldOfView = fov
			end
		end
	end
	if self.onTime then
		self.onTime(t)
	end
end

function Playback:length(): number
	local root = SceneData.getRoot(false)
	return if root then SceneData.sceneLength(root) else 0
end

function Playback:play(from: number?)
	if from then
		self.time = from
	end
	if self.time >= self:length() - 1e-3 then
		self.time = 0
	end
	self:pause()
	self.playing = true
	local signal = if RunService:IsRunning() and RunService:IsClient()
		then RunService.RenderStepped
		else RunService.Heartbeat
	self.conn = signal:Connect(function(dt)
		local t = self.time + dt
		local len = self:length()
		if t >= len then
			if self.loop then
				t = 0
			else
				self:evaluate(len)
				self:pause()
				if self.onStopped then
					self.onStopped()
				end
				return
			end
		end
		self:evaluate(t)
	end)
end

function Playback:pause()
	self.playing = false
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
end

function Playback:destroy()
	self:pause()
	for _, state in self.puppets do
		self:clearPuppet(state)
	end
	self.puppets = {}
	if self.puppetFolder and #self.puppetFolder:GetChildren() == 0 then
		self.puppetFolder:Destroy()
	end
	self.puppetFolder = nil
end

return Playback
