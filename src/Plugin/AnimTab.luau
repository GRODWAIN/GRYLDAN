--!nonstrict
-- "Анимация" tab: base motion mode, skin animation sets, timed action clips and pose keyframes.
local Shared = script.Parent.Parent.Shared
local SceneData = require(Shared.SceneData)
local PoseTrack = require(Shared.PoseTrack)
local Anims = require(Shared.Anims)
local ClipLibrary = require(Shared.ClipLibrary)
local Motion = require(Shared.Motion)
local Ease = require(Shared.Ease)
local Rig = require(Shared.Rig)
local Log = require(Shared.Log)

local UI = require(script.Parent.UI)
local BodyParts = require(script.Parent.BodyParts)
local Appearance = require(script.Parent.Appearance)

local C = UI.C
local ROT_STEP = 5
local POS_STEP = 0.1

local AnimTab = {}

local MODE_OPTIONS = {
	{ value = "auto", label = "Режим: авто" },
	{ value = "record", label = "Режим: записанные движения" },
	{ value = "skin", label = "Режим: анимации скина" },
	{ value = "none", label = "Режим: только позы" },
}
local MODE_TEXT = {
	record = "сейчас играют записанные движения суставов",
	skin = "сейчас играют анимации скина (стоит / шаг / бег / прыжок…) по траектории записи",
	none = "базового движения нет, только ваши позы",
}

local function rel(app, actor: Instance): number
	return app.playback.time - (tonumber(actor:GetAttribute("Offset")) or 0)
end
AnimTab.rel = rel

local function statusMark(id: string?): (string, Color3)
	local st = ClipLibrary.getStatus(id)
	if st == "ok" then
		return "✓", C.good
	elseif st == "loading" then
		return "…", C.warn
	elseif st == "error" then
		return "×", C.danger
	end
	return "·", C.dim
end

-- Skin shown in the editors: the user's pick, else the skin at the cursor, else the default.
function AnimTab.currentSkin(app, actor: Instance): Model?
	local name = app.animSkin and app.animSkin[actor]
	local skin = name and SceneData.getSkin(actor, name)
	if skin then
		return skin
	end
	local at = SceneData.skinAt(actor, rel(app, actor))
	skin = at and SceneData.getSkin(actor, at)
	if skin then
		return skin
	end
	return SceneData.listSkins(actor)[1]
end

-- Pose ---------------------------------------------------------------------------

function AnimTab.currentOffset(app, actor: Instance, name: string): CFrame
	local live = app.playback.live[actor.Name]
	if live and live[name] then
		return live[name]
	end
	local keys = PoseTrack.get(actor)[name]
	return if keys then PoseTrack.sample(keys, rel(app, actor)) else CFrame.identity
end

function AnimTab.setKey(app, actor: Instance, name: string, cf: CFrame, ease: string?)
	local tracks = PoseTrack.copy(PoseTrack.get(actor))
	local t = math.max(0, rel(app, actor))
	local keys = tracks[name] or {}
	local i = PoseTrack.keyAt(keys, t)
	if i then
		keys[i].cf = cf
		keys[i].e = ease or keys[i].e
	else
		table.insert(keys, { t = t, cf = cf, e = ease or "smooth" })
	end
	tracks[name] = keys
	app:mutate("ключ позы", function()
		PoseTrack.set(actor, tracks)
	end)
end

function AnimTab.editTracks(app, actor: Instance, label: string, fn: (any) -> ())
	local tracks = PoseTrack.copy(PoseTrack.get(actor))
	fn(tracks)
	app:mutate(label, function()
		PoseTrack.set(actor, tracks)
	end)
end

local function decompose(cf: CFrame): { number }
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	local p = cf.Position
	return { p.X, p.Y, p.Z, math.deg(rx), math.deg(ry), math.deg(rz) }
end

local function compose(v: { number }): CFrame
	return CFrame.new(v[1], v[2], v[3])
		* CFrame.fromEulerAnglesXYZ(math.rad(v[4]), math.rad(v[5]), math.rad(v[6]))
end

function AnimTab.partNames(app, actor: Instance): { [string]: boolean }
	local set = { [BodyParts.ROOT] = true }
	local skin = AnimTab.currentSkin(app, actor)
	if skin then
		for name in Rig.getJoints(skin) do
			set[name] = true
		end
	end
	local rec = SceneData.getRecording(actor)
	if rec then
		for _, name in rec.parts do
			set[name] = true
		end
	end
	for name in PoseTrack.get(actor) do
		set[name] = true
	end
	return set
end

local function renderPose(app, actor: Instance)
	local sec = UI.section("Позы — ключевые кадры частей тела", app.content)
	UI.paragraph(
		"Выберите часть тела, поставьте курсор на таймлайне и поверните её (стрелки в окне просмотра или поля ниже). Ключ ставится сам. Между ключами поза меняется плавно, а поверх идёт движение актёра.",
		{ Parent = sec }
	)
	local tracks = PoseTrack.get(actor)
	local names = AnimTab.partNames(app, actor)
	if not names[app.selectedPart] then
		app.selectedPart = if names.Head then "Head" else BodyParts.ROOT
	end
	for _, row in BodyParts.rows(names) do
		local r = UI.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			Parent = sec,
		})
		UI.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalFlex = Enum.UIFlexAlignment.Fill,
			Padding = UDim.new(0, 4),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = r,
		})
		for _, name in row do
			local keyed = tracks[name] ~= nil
			local label = BodyParts.label(name) .. (if keyed then "  ◆" else "")
			UI.button(label, function()
				app.selectedPart = name
				app:render()
			end, {
				Parent = r,
				AutomaticSize = Enum.AutomaticSize.None,
				Size = UDim2.new(0, 60, 0, 24),
				BackgroundColor3 = if name == app.selectedPart then C.accent else C.panel2,
				TextColor3 = if keyed and name ~= app.selectedPart then C.warn else C.text,
			})
		end
	end

	local name = app.selectedPart
	local keys = tracks[name] or {}
	local t = rel(app, actor)
	local keyIndex = PoseTrack.keyAt(keys, t)
	local values = decompose(AnimTab.currentOffset(app, actor, name))

	local edit = UI.section(nil, app.content)
	UI.label(BodyParts.label(name) .. "  ·  " .. UI.formatTime(math.max(0, t)) .. " от начала актёра", {
		Parent = edit,
		Font = UI.FONT_BOLD,
	})
	UI.row({
		UI.cycle({
			{ value = "rotate", label = "Стрелки: поворот" },
			{ value = "move", label = "Стрелки: сдвиг" },
			{ value = "off", label = "Стрелки: выкл" },
		}, app.gizmoMode, function(v)
			app.gizmoMode = v
			app.gizmo:update()
		end),
		UI.toggle("Шаг 15°", app.gizmoSnap, function(v)
			app.gizmoSnap = v
		end),
	}, { Parent = edit })

	local fields = {
		{ 4, "Поворот X", ROT_STEP },
		{ 5, "Поворот Y", ROT_STEP },
		{ 6, "Поворот Z", ROT_STEP },
		{ 1, "Сдвиг X", POS_STEP },
		{ 2, "Сдвиг Y", POS_STEP },
		{ 3, "Сдвиг Z", POS_STEP },
	}
	for _, f in fields do
		local index, label, step = f[1], f[2], f[3]
		local function setValue(v: number)
			local copy = table.clone(values)
			copy[index] = v
			AnimTab.setKey(app, actor, name, compose(copy))
		end
		local row = UI.row({}, { Parent = edit })
		UI.label(label, { Parent = row, Size = UDim2.fromOffset(78, 24), TextColor3 = C.dim })
		UI.button("−", function()
			setValue(values[index] - step)
		end, { Parent = row, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(26, 24) })
		UI.textbox(UI.formatNumber(values[index]), function(text, box)
			local v = UI.parseNumber(text)
			if v then
				setValue(v)
			else
				box.Text = UI.formatNumber(values[index])
			end
		end, { Parent = row, Size = UDim2.fromOffset(64, 24) })
		UI.button("+", function()
			setValue(values[index] + step)
		end, { Parent = row, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(26, 24) })
		UI.label(if index >= 4 then "°" else "студ.", { Parent = row, Size = UDim2.fromOffset(30, 24), TextColor3 = C.dim })
	end

	local keyRow = UI.row({}, { Parent = edit })
	UI.button("◀", function()
		local target
		for _, k in keys do
			if k.t < t - 0.02 then
				target = k.t
			end
		end
		if target then
			app:pausePlayback()
			app:seek(target + (tonumber(actor:GetAttribute("Offset")) or 0))
			app:render()
		end
	end, { Parent = keyRow })
	UI.button("◆ Ключ", function()
		AnimTab.setKey(app, actor, name, AnimTab.currentOffset(app, actor, name))
	end, { Parent = keyRow, BackgroundColor3 = C.accent })
	UI.button("▶", function()
		for _, k in keys do
			if k.t > t + 0.02 then
				app:pausePlayback()
				app:seek(k.t + (tonumber(actor:GetAttribute("Offset")) or 0))
				app:render()
				return
			end
		end
	end, { Parent = keyRow })
	UI.button("Обнулить", function()
		AnimTab.setKey(app, actor, name, CFrame.identity)
	end, { Parent = keyRow })
	if keyIndex then
		local easeOptions = {}
		for _, e in Ease.LIST do
			table.insert(easeOptions, { value = e, label = "Переход: " .. Ease.LABELS[e] })
		end
		local keyRow2 = UI.row({}, { Parent = edit })
		UI.label("Ключ на курсоре", { Parent = keyRow2, Size = UDim2.fromOffset(96, 24), TextColor3 = C.warn })
		UI.cycle(easeOptions, keys[keyIndex].e, function(v)
			AnimTab.editTracks(app, actor, "переход ключа", function(tr)
				tr[name][keyIndex].e = v
			end)
		end, { Parent = keyRow2 })
		UI.button("Удалить ключ", function()
			AnimTab.editTracks(app, actor, "удаление ключа позы", function(tr)
				table.remove(tr[name], keyIndex)
				if #tr[name] == 0 then
					tr[name] = nil
				end
			end)
		end, { Parent = keyRow2, BackgroundColor3 = C.danger })
	end
	UI.label(string.format("Ключей у части: %d", #keys), { Parent = edit, TextSize = 12, TextColor3 = C.dim })

	local poseRow = UI.row({}, { Parent = edit })
	UI.button("Копировать позу", function()
		local clip = {}
		for part in AnimTab.partNames(app, actor) do
			if tracks[part] then
				clip[part] = AnimTab.currentOffset(app, actor, part)
			end
		end
		app.poseClipboard = clip
		app:toast("Поза скопирована", C.good)
	end, { Parent = poseRow })
	UI.button("Вставить", function()
		local clip = app.poseClipboard
		if not clip then
			app:toast("Сначала скопируйте позу", C.warn)
			return
		end
		local at = math.max(0, rel(app, actor))
		AnimTab.editTracks(app, actor, "вставка позы", function(tr)
			for part, cf in clip do
				local list = tr[part] or {}
				local i = PoseTrack.keyAt(list, at)
				if i then
					list[i].cf = cf
				else
					table.insert(list, { t = at, cf = cf, e = "smooth" })
				end
				tr[part] = list
			end
		end)
	end, { Parent = poseRow })
	UI.button("Очистить часть", function()
		AnimTab.editTracks(app, actor, "очистка части", function(tr)
			tr[name] = nil
		end)
	end, { Parent = poseRow, BackgroundColor3 = C.danger })
	UI.button("Очистить все позы", function()
		AnimTab.editTracks(app, actor, "очистка поз", function(tr)
			table.clear(tr)
		end)
	end, { Parent = poseRow, BackgroundColor3 = C.danger })
end

-- Motion and skin animations -------------------------------------------------------

local function writeSkinAnims(app, skin: Model, set)
	app.playback:invalidate()
	app:mutate("анимации скина", function()
		Anims.write(skin, set)
	end)
end

local function renderMotion(app, actor: Instance)
	local rec = SceneData.getRecording(actor)
	local sec = UI.section("Движение актёра", app.content)
	UI.cycle(MODE_OPTIONS, Motion.getMode(actor), function(v)
		app:mutate("режим движения", function()
			actor:SetAttribute("Motion", if v == "auto" then nil else v)
		end)
	end, { Parent = sec })
	local effective = Motion.effectiveMode(actor, rec)
	UI.paragraph("→ " .. (MODE_TEXT[effective] or effective), { Parent = sec, TextColor3 = C.text })
	if effective == "record" and rec and #rec.parts == 0 then
		UI.paragraph("В этой записи нет суставов — выберите «анимации скина».", { Parent = sec, TextColor3 = C.warn })
	end

	local skins = SceneData.listSkins(actor)
	local skin = AnimTab.currentSkin(app, actor)
	local anims = UI.section("Анимации скина", app.content)
	if not skin then
		UI.paragraph("У актёра нет скина. Добавьте его во вкладке «Актёры».", { Parent = anims, TextColor3 = C.warn })
		return
	end
	if #skins > 1 then
		local options = {}
		for _, s in skins do
			table.insert(options, { value = s.Name, label = "Скин: " .. s.Name })
		end
		UI.cycle(options, skin.Name, function(v)
			app.animSkin = app.animSkin or setmetatable({}, { __mode = "k" })
			app.animSkin[actor] = v
			app:render()
		end, { Parent = anims })
	else
		UI.label("Скин: " .. skin.Name, { Parent = anims, TextColor3 = C.dim })
	end
	local rig = Anims.rigType(skin)
	if not skin:FindFirstChildOfClass("Humanoid") or not rig then
		UI.paragraph("Это не персонаж (нет Humanoid/R15/R6) — анимации скина к нему не применяются.", {
			Parent = anims,
			TextColor3 = C.warn,
		})
		return
	end
	local custom = Anims.read(skin)
	local defaults = Anims.DEFAULTS[rig]
	for _, state in Anims.STATES do
		if defaults[state] or custom[state] then
			local id = Anims.resolve(skin, state)
			local mark, color = statusMark(id)
			local row = UI.row({}, { Parent = anims })
			UI.label(Anims.LABELS[state], { Parent = row, Size = UDim2.fromOffset(70, 24), TextColor3 = C.dim })
			UI.flex(UI.textbox(custom[state] or "", function(text)
				local value = ClipLibrary.normalize(text)
				if (value or "") == (custom[state] or "") then
					return
				end
				local set = table.clone(custom)
				set[state] = value
				writeSkinAnims(app, skin, set)
				if value then
					ClipLibrary.request(value, true)
				end
			end, {
				Parent = row,
				Size = UDim2.fromOffset(80, 24),
				PlaceholderText = "стандарт: " .. tostring(defaults[state] or "—"),
			}))
			UI.label(mark, { Parent = row, Size = UDim2.fromOffset(16, 24), TextColor3 = color })
			if ClipLibrary.getStatus(id) == "error" then
				UI.button("↻", function()
					ClipLibrary.request(id, true)
					app:render()
				end, { Parent = row })
			end
		end
	end
	UI.row({
		UI.button("Стандартные Roblox", function()
			writeSkinAnims(app, skin, nil)
		end),
	}, { Parent = anims })
	local userRow = UI.row({}, { Parent = anims })
	local userBox = UI.textbox("", nil, {
		Parent = userRow,
		PlaceholderText = "ник или UserId",
		Size = UDim2.fromOffset(100, 24),
	})
	UI.flex(userBox)
	UI.button("Взять анимации аватара", function()
		AnimTab.animsFromUser(app, skin, userBox.Text)
	end, { Parent = userRow })
	UI.paragraph(
		"Пустое поле — стандартная анимация. Вставьте ID анимации (rbxassetid://…), чтобы заменить. Анимации скачиваются один раз и сохраняются в плейсе, чтобы работать и в игре.",
		{ Parent = anims }
	)
end

function AnimTab.animsFromUser(app, skin: Model, text: string)
	app:toast("Загрузка анимаций аватара…")
	task.spawn(function()
		local userId, name = Appearance.resolveUser(text)
		if not userId then
			app:toast("Игрок не найден: " .. text, C.warn)
			return
		end
		local ok, model = pcall(Appearance.rigFromUserId, userId, Anims.rigType(skin) or "R15")
		local set = ok and model and Anims.extractFromAnimate(model)
		if model and typeof(model) == "Instance" then
			model:Destroy()
		end
		if not set then
			app:toast("Не удалось получить анимации аватара", C.warn)
			return
		end
		writeSkinAnims(app, skin, set)
		Log.info("анимации аватара " .. tostring(name) .. " назначены скину «" .. skin.Name .. "»")
	end)
end

-- Actions -------------------------------------------------------------------------

function AnimTab.editActions(app, actor: Instance, label: string, fn: (any) -> ())
	local list = Motion.copyActions(actor)
	fn(list)
	app:mutate(label, function()
		Motion.setActions(actor, list)
	end)
end

local function addAction(app, actor: Instance, id: string?, name: string)
	id = ClipLibrary.normalize(id)
	if not id then
		app:toast("Неверный ID анимации", C.warn)
		return
	end
	ClipLibrary.request(id, true)
	local at = math.max(0, rel(app, actor))
	AnimTab.editActions(app, actor, "действие", function(list)
		table.insert(list, { t = at, id = id, name = name, speed = 1, loop = false, fade = 0.2 })
	end)
end

local function renderActions(app, actor: Instance)
	local sec = UI.section("Действия — анимации в нужный момент", app.content)
	UI.paragraph(
		"Поставьте курсор и добавьте анимацию: на время её действия она заменит движение (плавно входит и выходит). Позы применяются поверх.",
		{ Parent = sec }
	)
	local skin = AnimTab.currentSkin(app, actor)
	local rig = Anims.rigType(skin) or "R15"
	local presetRow = UI.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = sec,
	})
	UI.new("UIGridLayout", {
		CellSize = UDim2.new(0.25, -4, 0, 24),
		CellPadding = UDim2.fromOffset(4, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = presetRow,
	})
	for _, preset in Anims.EMOTES[rig] do
		UI.button(preset.label, function()
			addAction(app, actor, preset.id, preset.label)
		end, { Parent = presetRow, AutomaticSize = Enum.AutomaticSize.None })
	end
	local customRow = UI.row({}, { Parent = sec })
	local idBox = UI.textbox("", nil, {
		Parent = customRow,
		PlaceholderText = "ID своей анимации",
		Size = UDim2.fromOffset(100, 24),
	})
	UI.flex(idBox)
	UI.button("+ на курсоре", function()
		addAction(app, actor, idBox.Text, "ID " .. idBox.Text)
	end, { Parent = customRow, BackgroundColor3 = C.accent })

	local offset = tonumber(actor:GetAttribute("Offset")) or 0
	for i, a in Motion.getActions(actor) do
		local mark, color = statusMark(a.id)
		local row = UI.row({}, { Parent = sec })
		UI.label(mark, { Parent = row, Size = UDim2.fromOffset(14, 24), TextColor3 = color })
		UI.flex(UI.label(a.name, { Parent = row, Size = UDim2.fromOffset(60, 24) }))
		UI.textbox(UI.formatNumber(offset + a.t), function(text, box)
			local v = UI.parseNumber(text)
			if not v then
				box.Text = UI.formatNumber(offset + a.t)
				return
			end
			AnimTab.editActions(app, actor, "время действия", function(list)
				list[i].t = math.max(0, v - offset)
			end)
		end, { Parent = row, Size = UDim2.fromOffset(44, 24) })
		UI.textbox("×" .. UI.formatNumber(a.speed), function(text, box)
			local v = UI.parseNumber((string.gsub(text, "[x×]", "")))
			if not v then
				box.Text = "×" .. UI.formatNumber(a.speed)
				return
			end
			AnimTab.editActions(app, actor, "скорость действия", function(list)
				list[i].speed = math.clamp(v, 0.05, 10)
			end)
		end, { Parent = row, Size = UDim2.fromOffset(40, 24) })
		UI.toggle("Петля", a.loop, function(v)
			AnimTab.editActions(app, actor, "петля действия", function(list)
				list[i].loop = v
				if v and not list[i].dur then
					list[i].dur = 3
				end
			end)
		end, { Parent = row })
		if a.loop then
			UI.textbox(UI.formatNumber(a.dur or 3), function(text, box)
				local v = UI.parseNumber(text)
				if not v then
					box.Text = UI.formatNumber(a.dur or 3)
					return
				end
				AnimTab.editActions(app, actor, "длительность действия", function(list)
					list[i].dur = math.max(0.1, v)
				end)
			end, { Parent = row, Size = UDim2.fromOffset(36, 24) })
		end
		UI.button("×", function()
			AnimTab.editActions(app, actor, "удаление действия", function(list)
				table.remove(list, i)
			end)
		end, { Parent = row, BackgroundColor3 = C.danger })
	end
end

-- Entry -----------------------------------------------------------------------------

function AnimTab.render(app)
	local root = SceneData.getRoot(false)
	local actors = if root then SceneData.listActors(root) else {}
	local actor = app.selected
	if not actor or not actor.Parent then
		local sec = UI.section("Анимация", app.content)
		if #actors == 0 then
			UI.paragraph("Сначала запишите актёра или добавьте его во вкладке «Актёры».", { Parent = sec })
			return
		end
		UI.paragraph("Выберите актёра:", { Parent = sec })
		for _, a in actors do
			UI.button(SceneData.getName(a), function()
				app.selected = a
				app:render()
			end, { Parent = sec })
		end
		return
	end
	local head = UI.section(nil, app.content)
	local options = {}
	for _, a in actors do
		table.insert(options, { value = a, label = "Актёр: " .. SceneData.getName(a) })
	end
	UI.row({
		UI.cycle(options, actor, function(v)
			app.selected = v
			app:render()
		end),
		UI.button("◎", function()
			app:focusActor(actor)
		end),
	}, { Parent = head })
	renderMotion(app, actor)
	renderPose(app, actor)
	renderActions(app, actor)
end

-- Requests every clip the scene can use, so the in-game player has them baked.
function AnimTab.prefetch(): number
	local root = SceneData.getRoot(false)
	if not root then
		return 0
	end
	local ids = {}
	for _, actor in SceneData.listActors(root) do
		local rec = SceneData.getRecording(actor)
		if Motion.effectiveMode(actor, rec) == "skin" then
			for _, skin in SceneData.listSkins(actor) do
				if Anims.rigType(skin) then
					for _, state in Anims.STATES do
						local id = Anims.resolve(skin, state)
						if id then
							ids[id] = true
						end
					end
				end
			end
		end
		for _, a in Motion.getActions(actor) do
			ids[a.id] = true
		end
	end
	local count = 0
	for id in ids do
		count += 1
		ClipLibrary.request(id, false)
	end
	return count
end

return AnimTab
