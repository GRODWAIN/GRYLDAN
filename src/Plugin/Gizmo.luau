--!nonstrict
-- Viewport arrows for posing: ArcHandles rotate and Handles move the selected body part.
-- Drags preview through Playback.live and become a pose key on release.
local CoreGui = game:GetService("CoreGui")

local Shared = script.Parent.Parent.Shared
local PoseTrack = require(Shared.PoseTrack)
local UI = require(script.Parent.UI)
local AnimTab = require(script.Parent.AnimTab)

local Gizmo = {}
Gizmo.__index = Gizmo

-- Converts a direction in the part's space into the joint frame the pose offset lives in.
local function toJointSpace(node, v: Vector3): Vector3
	if node and node.c1 and not node.invert then
		return node.c1:Inverse():VectorToWorldSpace(v)
	end
	return v
end

function Gizmo.new(app)
	local self = setmetatable({ app = app, dragging = nil }, Gizmo)
	local folder = Instance.new("Folder")
	folder.Name = "BBS_Gizmo"
	folder.Archivable = false
	pcall(function()
		folder.Parent = CoreGui
	end)
	self.folder = folder

	local arc = Instance.new("ArcHandles")
	arc.Name = "Rotate"
	arc.Visible = false
	arc.Parent = folder
	self.arc = arc

	local move = Instance.new("Handles")
	move.Name = "Move"
	move.Style = Enum.HandlesStyle.Movement
	move.Color3 = UI.C.warn
	move.Visible = false
	move.Parent = folder
	self.move = move

	arc.MouseButton1Down:Connect(function()
		self:begin()
	end)
	move.MouseButton1Down:Connect(function()
		self:begin()
	end)
	arc.MouseDrag:Connect(function(axis, angle)
		local d = self.dragging
		if not d then
			return
		end
		if app.gizmoSnap then
			angle = math.rad(math.floor(math.deg(angle) / 15 + 0.5) * 15)
		end
		local axisVector = toJointSpace(d.node, Vector3.FromAxis(axis))
		self:preview(CFrame.fromAxisAngle(axisVector, angle))
	end)
	move.MouseDrag:Connect(function(face, distance)
		local d = self.dragging
		if not d then
			return
		end
		local dir = toJointSpace(d.node, Vector3.FromNormalId(face))
		self:preview(CFrame.new(dir * distance))
	end)
	arc.MouseButton1Up:Connect(function()
		self:finish()
	end)
	move.MouseButton1Up:Connect(function()
		self:finish()
	end)
	return self
end

function Gizmo:target()
	local app = self.app
	if app.tab ~= "anim" or app.gizmoMode == "off" then
		return nil
	end
	local actor = app.selected
	if not actor or not actor.Parent then
		return nil
	end
	local name = app.selectedPart or PoseTrack.ROOT
	local part, node = app.playback:getPuppetPart(actor, name)
	if not part then
		return nil
	end
	return actor, name, part, node
end

function Gizmo:update()
	if self.dragging then
		return
	end
	local _, _, part = self:target()
	local mode = self.app.gizmoMode
	self.arc.Adornee = if part and mode == "rotate" then part else nil
	self.arc.Visible = part ~= nil and mode == "rotate"
	self.move.Adornee = if part and mode == "move" then part else nil
	self.move.Visible = part ~= nil and mode == "move"
end

function Gizmo:begin()
	local actor, name, _, node = self:target()
	if not actor then
		return
	end
	self.app:pausePlayback()
	self.dragging = {
		actor = actor,
		name = name,
		node = node,
		start = AnimTab.currentOffset(self.app, actor, name),
	}
end

function Gizmo:preview(delta: CFrame)
	local d = self.dragging
	local playback = self.app.playback
	playback.live[d.actor.Name] = { [d.name] = d.start * delta }
	playback:evaluate(playback.time)
end

function Gizmo:finish()
	local d = self.dragging
	self.dragging = nil
	if not d then
		return
	end
	local playback = self.app.playback
	local live = playback.live[d.actor.Name]
	local value = live and live[d.name]
	playback.live[d.actor.Name] = nil
	if value then
		AnimTab.setKey(self.app, d.actor, d.name, value)
	else
		self:update()
	end
end

function Gizmo:destroy()
	self.folder:Destroy()
end

return Gizmo
