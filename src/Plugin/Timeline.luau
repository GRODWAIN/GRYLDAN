--!nonstrict
-- Timeline strip: ruler, camera lane with keyframes, one lane per actor with draggable clips.
local UI = require(script.Parent.UI)
local Shared = script.Parent.Parent.Shared
local SceneData = require(Shared.SceneData)
local PoseTrack = require(Shared.PoseTrack)
local Motion = require(Shared.Motion)
local BodyParts = require(script.Parent.BodyParts)

local C = UI.C
local LABEL_W = 92
local RULER_H = 18
local ROW_H = 22
local RIGHT_PAD = 10
local MAX_VISIBLE_ROWS = 8

local Timeline = {}
Timeline.__index = Timeline

function Timeline.new(app, parent: Instance)
	local self = setmetatable({}, Timeline)
	self.app = app
	self.viewLen = 10
	self.height = RULER_H + ROW_H * 2 + 8

	self.frame = UI.new("Frame", {
		Name = "Timeline",
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, self.height),
		Parent = parent,
	})
	UI.corner(self.frame, 6)

	self.ruler = UI.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.panel2,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(LABEL_W, 0),
		Size = UDim2.new(1, -LABEL_W - RIGHT_PAD, 0, RULER_H),
		Parent = self.frame,
	})
	self.ruler.MouseButton1Down:Connect(function()
		self:beginScrub()
	end)
	self.ruler:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:drawTicks()
	end)

	self.rows = UI.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, RULER_H + 4),
		Size = UDim2.new(1, 0, 1, -RULER_H - 4),
		ScrollBarThickness = 4,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = self.frame,
	})
	UI.list(self.rows, false, 2)

	local overlay = UI.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(LABEL_W, 0),
		Size = UDim2.new(1, -LABEL_W - RIGHT_PAD, 1, 0),
		Interactable = false,
		ZIndex = 20,
		Parent = self.frame,
	})
	self.playhead = UI.new("Frame", {
		BackgroundColor3 = C.record,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.new(0, 2, 1, 0),
		ZIndex = 20,
		Parent = overlay,
	})
	return self
end

function Timeline:timeAtX(x: number, viewLen: number?): number
	local abs = self.ruler.AbsolutePosition.X
	local width = math.max(1, self.ruler.AbsoluteSize.X)
	return math.max(0, (x - abs) / width * (viewLen or self.viewLen))
end

function Timeline:beginScrub()
	local app = self.app
	app:pausePlayback()
	local viewLen = self.viewLen
	app:beginDrag(function(mouse: Vector2)
		app:seek(math.min(self:timeAtX(mouse.X, viewLen), app.playback:length()))
	end, function()
		-- pose fields show values at the cursor, refresh them once the scrub ends
		if app.tab == "anim" then
			app:render()
		end
	end)
end

function Timeline:beginClipDrag(actor: Instance)
	local app = self.app
	local viewLen = self.viewLen
	local startOffset = actor:GetAttribute("Offset") or 0
	local startX = app.widget:GetRelativeMousePosition().X
	local moved = false
	app:selectActor(actor, true)
	app:beginDrag(function(mouse: Vector2)
		local dx = mouse.X - startX
		if math.abs(dx) < 3 and not moved then
			return
		end
		moved = true
		local width = math.max(1, self.ruler.AbsoluteSize.X)
		local offset = math.max(0, startOffset + dx / width * viewLen)
		offset = math.floor(offset * 20 + 0.5) / 20
		actor:SetAttribute("Offset", offset)
		app.playback:evaluate(app.playback.time)
	end, function()
		if not moved then
			app:render()
			return
		end
		-- re-apply the final value inside an undo recording
		local final = actor:GetAttribute("Offset")
		actor:SetAttribute("Offset", startOffset)
		app:mutate("сдвиг клипа", function()
			actor:SetAttribute("Offset", final)
		end)
	end)
end

-- Drag a pose key diamond to retime it; a click selects the part and jumps to the key.
function Timeline:beginKeyDrag(actor: Instance, partName: string, index: number, diamond: GuiObject)
	local app = self.app
	local viewLen = self.viewLen
	local offset = tonumber(actor:GetAttribute("Offset")) or 0
	local keys = PoseTrack.get(actor)[partName]
	local key = keys and keys[index]
	if not key then
		return
	end
	local startT = key.t
	local startX = app.widget:GetRelativeMousePosition().X
	local moved = false
	local newT = startT
	app:pausePlayback()
	app:beginDrag(function(mouse: Vector2)
		local dx = mouse.X - startX
		if math.abs(dx) < 3 and not moved then
			return
		end
		moved = true
		local width = math.max(1, self.ruler.AbsoluteSize.X)
		newT = math.max(0, startT + dx / width * viewLen)
		newT = math.floor(newT * 30 + 0.5) / 30
		diamond.Position = UDim2.new((offset + newT) / viewLen, 0, 0.5, 0)
	end, function()
		app.selectedPart = partName
		app.selected = actor
		app.tab = "anim"
		if not moved then
			app:seek(offset + startT)
			app:render()
			return
		end
		local tracks = PoseTrack.copy(PoseTrack.get(actor))
		local list = tracks[partName]
		if list and list[index] then
			list[index].t = newT
		end
		app:mutate("перенос ключа позы", function()
			PoseTrack.set(actor, tracks)
		end)
		app:seek(offset + newT)
	end)
end

-- Extra lanes under the selected actor: timed actions and one lane per posed body part.
function Timeline:addActorSubrows(actor: Instance): number
	local app = self.app
	local viewLen = self.viewLen
	local offset = tonumber(actor:GetAttribute("Offset")) or 0
	local rows = 0
	local actions = Motion.getActions(actor)
	if #actions > 0 then
		rows += 1
		local lane = self:makeRow("  ↳ Действия", C.dim, function()
			app:setTab("anim")
		end)
		for _, a in actions do
			local bar = UI.new("Frame", {
				BackgroundColor3 = C.good,
				BackgroundTransparency = 0.3,
				BorderSizePixel = 0,
				Position = UDim2.new((offset + a.t) / viewLen, 0, 0, 4),
				Size = UDim2.new(Motion.actionLength(a) / viewLen, 0, 1, -8),
				ZIndex = 2,
				Parent = lane,
			})
			UI.corner(bar, 3)
			UI.new("UISizeConstraint", { MinSize = Vector2.new(4, 0), Parent = bar })
		end
	end
	local tracks = PoseTrack.get(actor)
	local names = {}
	for name in tracks do
		table.insert(names, name)
	end
	table.sort(names, BodyParts.compare)
	for _, name in names do
		rows += 1
		local isSel = app.tab == "anim" and app.selectedPart == name
		local lane = self:makeRow("  ↳ " .. BodyParts.label(name), if isSel then C.warn else C.dim, function()
			app.selectedPart = name
			app.selected = actor
			app:setTab("anim")
		end)
		for i, key in tracks[name] do
			local diamond = UI.new("TextButton", {
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = if isSel then Color3.new(1, 1, 1) else C.accent,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new((offset + key.t) / viewLen, 0, 0.5, 0),
				Size = UDim2.fromOffset(9, 9),
				Rotation = 45,
				ZIndex = 3,
				Parent = lane,
			})
			diamond.MouseButton1Down:Connect(function()
				self:beginKeyDrag(actor, name, i, diamond)
			end)
		end
	end
	return rows
end

function Timeline:drawTicks()
	for _, child in self.ruler:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local width = self.ruler.AbsoluteSize.X
	if width <= 0 then
		return
	end
	local step = 60
	for _, s in { 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60 } do
		if s / self.viewLen * width >= 48 then
			step = s
			break
		end
	end
	local t = 0
	while t <= self.viewLen do
		local x = t / self.viewLen
		UI.new("Frame", {
			BackgroundColor3 = C.dim,
			BorderSizePixel = 0,
			Position = UDim2.new(x, 0, 1, -5),
			Size = UDim2.new(0, 1, 0, 5),
			Parent = self.ruler,
		})
		UI.new("TextLabel", {
			BackgroundTransparency = 1,
			Text = UI.formatNumber(t) .. "с",
			TextColor3 = C.dim,
			TextSize = 11,
			Font = UI.FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.new(x, 3, 0, 0),
			Size = UDim2.new(0, 40, 1, -4),
			Parent = self.ruler,
		})
		t += step
	end
end

function Timeline:makeRow(labelText: string, color: Color3?, onLabel: (() -> ())?)
	local row = UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, ROW_H),
		Parent = self.rows,
	})
	UI.new("TextButton", {
		Text = "  " .. labelText,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		TextColor3 = color or C.text,
		TextSize = 12,
		Font = UI.FONT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(0, LABEL_W - 4, 1, 0),
		Parent = row,
	}).Activated:Connect(function()
		if onLabel then
			onLabel()
		end
	end)
	local lane = UI.new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.input,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(LABEL_W, 0),
		Size = UDim2.new(1, -LABEL_W - RIGHT_PAD, 1, 0),
		Parent = row,
	})
	lane.MouseButton1Down:Connect(function()
		self:beginScrub()
	end)
	return lane
end

function Timeline:rebuild()
	for _, child in self.rows:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local app = self.app
	local root = SceneData.getRoot(false)
	local length = app.playback:length()
	self.viewLen = math.max(length, 5) * 1.05
	local viewLen = self.viewLen

	-- camera lane
	local camLane = self:makeRow("Камера", C.warn, function()
		app:setTab("camera")
	end)
	if root then
		for i, key in SceneData.getCamera(root).keys do
			local selected = app.tab == "camera" and app.selectedKey == i
			local diamond = UI.new("TextButton", {
				Text = "",
				AutoButtonColor = false,
				BackgroundColor3 = if key.ease == "cut" then C.record elseif selected then Color3.new(1, 1, 1) else C.warn,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.new(key.t / viewLen, 0, 0.5, 0),
				Size = UDim2.fromOffset(9, 9),
				Rotation = 45,
				ZIndex = 3,
				Parent = camLane,
			})
			diamond.Activated:Connect(function()
				app.selectedKey = i
				app:setTab("camera")
				app:seek(key.t)
			end)
		end
	end

	local actors = if root then SceneData.listActors(root) else {}
	local subrows = 0
	for _, actor in actors do
		local color = actor:GetAttribute("Color") or C.accent
		local enabled = actor:GetAttribute("Enabled") ~= false
		local lane = self:makeRow(SceneData.getName(actor), if enabled then C.text else C.dim, function()
			app:selectActor(actor)
		end)
		local offset = actor:GetAttribute("Offset") or 0
		local len = math.max(SceneData.actorLength(actor), 0.05)
		local clip = UI.new("TextButton", {
			Text = " " .. SceneData.getName(actor),
			AutoButtonColor = false,
			BackgroundColor3 = color,
			BackgroundTransparency = if enabled then 0.15 else 0.65,
			BorderSizePixel = 0,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 11,
			Font = UI.FONT_BOLD,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.new(offset / viewLen, 0, 0, 2),
			Size = UDim2.new(len / viewLen, 0, 1, -4),
			ClipsDescendants = true,
			ZIndex = 2,
			Parent = lane,
		})
		UI.corner(clip, 3)
		UI.new("UISizeConstraint", { MinSize = Vector2.new(4, 0), Parent = clip })
		if actor == app.selected then
			UI.new("UIStroke", {
				Color = Color3.new(1, 1, 1),
				Thickness = 1.5,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Parent = clip,
			})
		end
		for _, key in SceneData.getSkinKeys(actor) do
			if key.t >= 0 and key.t <= len then
				UI.new("Frame", {
					BackgroundColor3 = if key.skin == SceneData.HIDDEN_SKIN then C.record else Color3.new(1, 1, 1),
					BorderSizePixel = 0,
					Position = UDim2.new(key.t / len, 0, 0, 0),
					Size = UDim2.new(0, 2, 1, 0),
					ZIndex = 3,
					Parent = clip,
				})
			end
		end
		clip.MouseButton1Down:Connect(function()
			self:beginClipDrag(actor)
		end)
		if actor == app.selected then
			subrows += self:addActorSubrows(actor)
		end
	end

	local rowCount = 1 + #actors + subrows
	local height = RULER_H + 4 + math.min(rowCount, MAX_VISIBLE_ROWS) * (ROW_H + 2) + 4
	if height ~= self.height then
		self.height = height
		self.frame.Size = UDim2.new(self.frame.Size.X.Scale, self.frame.Size.X.Offset, 0, height)
		if self.onHeightChanged then
			self.onHeightChanged()
		end
	end
	self:drawTicks()
	self:updatePlayhead(app.playback.time)
end

function Timeline:updatePlayhead(t: number)
	self.playhead.Position = UDim2.new(math.clamp(t / self.viewLen, 0, 1), 0, 0, 0)
end

return Timeline
