--!nonstrict
-- Playtest-client window: records the local character while the scene plays around it.
-- Each take also becomes a local actor right away, so it can be previewed without leaving Play.
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent.Shared
local Codec = require(Shared.Codec)
local SceneData = require(Shared.SceneData)
local Playback = require(Shared.Playback)
local Log = require(Shared.Log)

local UI = require(script.Parent.UI)
local Bridge = require(script.Parent.Bridge)
local Recorder = require(script.Parent.Recorder)
local Version = require(script.Parent.Version)

local C = UI.C
local SETTING_FPS = "BBS_RecordFPS"
local SETTING_COUNTDOWN = "BBS_RecordCountdown"
local SETTING_AUTO_OPEN = "BBS_AutoOpenRecorder"
local SETTING_HUD = "BBS_ShowHud"

local PlayApp = {}

local function getSetting(plugin: Plugin, key: string, default: any): any
	local ok, v = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and v ~= nil then
		return v
	end
	return default
end

local function setSetting(plugin: Plugin, key: string, value: any)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

local function cloneCharacter(character: Model): Model?
	local was = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(function()
		return character:Clone()
	end)
	character.Archivable = was
	if not ok or not copy then
		return nil
	end
	for _, d in copy:GetDescendants() do
		if d:IsA("ForceField") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	return copy
end

local function buildHud()
	local gui = Instance.new("ScreenGui")
	gui.Name = "BBS_RecordHud"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bar = UI.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 8),
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.bg,
		BackgroundTransparency = 0.15,
		Parent = gui,
	})
	UI.corner(bar, 8)
	UI.pad(bar, 6, 6, 6, 6)
	UI.list(bar, true, 6)
	local label = UI.label("BBS", {
		Font = UI.FONT_BOLD,
		TextSize = 16,
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = bar,
	})
	local recordButton = UI.button("● Записать", nil, { Parent = bar, BackgroundColor3 = C.record, Font = UI.FONT_BOLD })
	local previewButton = UI.button("▶ Просмотр", nil, { Parent = bar })

	local countdown = UI.label("", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(200, 120),
		TextSize = 96,
		Font = UI.FONT_BOLD,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = gui,
	})

	local ok = pcall(function()
		gui.Parent = CoreGui
	end)
	if not ok then
		local player = Players.LocalPlayer
		gui.Parent = player and player:FindFirstChildOfClass("PlayerGui")
	end
	return { gui = gui, label = label, record = recordButton, preview = previewButton, countdown = countdown }
end

function PlayApp.start(plugin: Plugin)
	local player = Players.LocalPlayer
	local bridge = Bridge.new(plugin)
	local recorder = Recorder.new()
	local playback = Playback.new({ folderName = "BBS_LocalPuppets" })
	playback.onError = function(text)
		Log.error(text)
	end
	local hud = buildHud()
	hud.gui.Enabled = getSetting(plugin, SETTING_HUD, true)

	local state: string = "idle" -- idle | countdown | recording | preview
	local function currentState(): string
		return state
	end
	local config = { start = 0 }
	local take = 1
	local baseName = if player then player.DisplayName else "Актёр"
	local nameText = baseName
	local targetId = nil
	local playScene = true
	local sceneCamera = false
	local session = {}
	local timerConn = nil
	local savedCameraType = nil
	local connected = false

	local toolbar = plugin:CreateToolbar("BBS Studio")
	local button = toolbar:CreateButton("BBSStudioRecord", "Окно записи BBS Studio", "", "BBS запись")
	button.ClickableWhenViewportHidden = true
	local autoOpen = getSetting(plugin, SETTING_AUTO_OPEN, true)
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, autoOpen, autoOpen, 360, 560, 300, 300)
	local widget = UI.createWidget(plugin, "BBSStudio_Play", info)
	widget.Title = "BBS Studio — запись"
	widget.Name = "BBSStudioRecorder"
	button.Click:Connect(function()
		widget.Enabled = not widget.Enabled
	end)
	widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		button:SetActive(widget.Enabled)
	end)
	button:SetActive(widget.Enabled)

	local root = UI.new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.bg,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = widget,
	})
	UI.list(root, false, 6)
	UI.pad(root, 8, 10, 8, 8)

	local render -- forward declaration
	local statusLabel, startBox
	local statusText = if player and player.Character then "Готово к записи" else "Ждём персонажа…"
	local statusColor = C.text

	local function setStatus(text: string, color: Color3?)
		statusText = text
		statusColor = color or C.text
		if statusLabel then
			statusLabel.Text = statusText
			statusLabel.TextColor3 = statusColor
		end
		hud.label.Text = statusText
		hud.label.TextColor3 = statusColor
	end

	local function updateHud()
		local busy = state == "countdown" or state == "recording"
		hud.record.Text = if busy then "■ Стоп" else "● Записать"
		UI.recolor(hud.record, if busy then C.panel2 else C.record)
		hud.preview.Visible = not busy
		hud.preview.Text = if state == "preview" then "■ Стоп просмотра" else "▶ Просмотр"
	end

	local function restoreCamera()
		if savedCameraType then
			Workspace.CurrentCamera.CameraType = savedCameraType
			savedCameraType = nil
		end
	end

	local function startScene(from: number, useCamera: boolean)
		local dataRoot = SceneData.getRoot(false)
		if not dataRoot then
			return
		end
		playback.exclude = if targetId and state == "recording" then { [targetId] = true } else {}
		local hasCamera = #SceneData.getCamera(dataRoot).keys > 0
		playback.useCamera = useCamera and hasCamera
		if playback.useCamera then
			savedCameraType = Workspace.CurrentCamera.CameraType
			Workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
		end
		playback:refresh()
		playback:play(from)
	end

	local function stopScene()
		playback:destroy()
		restoreCamera()
	end

	local function addLocalTake(rec)
		local dataRoot = SceneData.getRoot(true)
		local target = if targetId then SceneData.findActor(dataRoot, targetId) else nil
		if target then
			SceneData.setRecording(target, rec)
			target:SetAttribute("Offset", rec.offset or 0)
			return
		end
		local character = player and player.Character
		local skin = if character then cloneCharacter(character) else nil
		local actor = SceneData.createActor(dataRoot, {
			name = rec.name,
			rec = rec,
			skin = skin,
			offset = rec.offset or 0,
		})
		actor:SetAttribute("BBS_LocalTake", true)
	end

	local function stopRecording()
		if state == "countdown" then
			state = "idle"
			hud.countdown.Text = ""
			setStatus("Отменено", C.dim)
			render()
			return
		end
		if state ~= "recording" then
			return
		end
		state = "idle"
		if timerConn then
			timerConn:Disconnect()
			timerConn = nil
		end
		local rec = recorder:stop()
		stopScene()
		if not rec or #rec.frames < 2 then
			setStatus("Слишком короткая запись", C.warn)
			render()
			return
		end
		rec.name = nameText
		rec.offset = config.start or 0
		rec.target = targetId
		local str = Codec.encodeRecording(rec)
		local saved, saveErr = bridge:savePending(rec, str)
		local sent, sendErr = bridge:sendToEdit(rec.id, str)
		local okLocal, localErr = pcall(addLocalTake, rec)
		if not okLocal then
			Log.error("не удалось показать дубль в тесте: " .. tostring(localErr))
		end
		Log.info(
			string.format(
				"дубль «%s»: %.1f с, %d кадров, %d суставов, %d КБ · редактор: %s · резерв: %s",
				rec.name,
				rec.length,
				#rec.frames,
				#rec.parts,
				math.ceil(#str / 1024),
				if sent then "отправлен" else "нет (" .. tostring(sendErr) .. ")",
				if saved then "сохранён" else "ошибка (" .. tostring(saveErr) .. ")"
			)
		)
		table.insert(session, { name = rec.name, length = rec.length, sent = sent, saved = saved })
		if sent or saved then
			setStatus("✓ Дубль готов — «▶ Просмотр»", C.good)
		else
			setStatus("× Запись не сохранена — см. Output", C.danger)
		end
		if not targetId then
			take += 1
			nameText = baseName .. " " .. take
		end
		render()
	end

	local function startRecording()
		if state == "preview" then
			stopScene()
			state = "idle"
		end
		if state ~= "idle" then
			return
		end
		if not player or not player.Character then
			setStatus("Нет персонажа — запустите Play (F5)", C.warn)
			return
		end
		state = "countdown"
		render()
		local countdown = math.clamp(tonumber(getSetting(plugin, SETTING_COUNTDOWN, 3)) or 3, 0, 10)
		task.spawn(function()
			for i = countdown, 1, -1 do
				if currentState() ~= "countdown" then
					return
				end
				setStatus("Запись через " .. i .. "…", C.warn)
				hud.countdown.Text = tostring(i)
				task.wait(1)
			end
			hud.countdown.Text = ""
			if currentState() ~= "countdown" then
				return
			end
			local ok, err = recorder:start({
				fps = tonumber(getSetting(plugin, SETTING_FPS, 30)) or 30,
				name = nameText,
			})
			if not ok then
				state = "idle"
				setStatus(err or "Ошибка", C.danger)
				render()
				return
			end
			state = "recording"
			if playScene then
				startScene(config.start or 0, sceneCamera)
			end
			timerConn = RunService.Heartbeat:Connect(function()
				setStatus("● REC " .. UI.formatTime(recorder.elapsed), C.record)
			end)
			render()
		end)
	end

	local function toggleRecording()
		if state == "idle" or state == "preview" then
			startRecording()
		else
			stopRecording()
		end
	end

	local function togglePreview()
		if state == "preview" then
			stopScene()
			state = "idle"
		elseif state == "idle" then
			local dataRoot = SceneData.getRoot(false)
			if not dataRoot or #SceneData.listActors(dataRoot) == 0 then
				setStatus("Смотреть пока нечего — запишите дубль", C.warn)
				return
			end
			state = "preview"
			startScene(0, true)
			setStatus("▶ Просмотр сцены", C.accent)
		end
		render()
	end

	playback.onStopped = function()
		if state == "preview" then
			stopScene()
			state = "idle"
			setStatus("Просмотр окончен", C.dim)
			render()
		end
	end

	hud.record.Activated:Connect(toggleRecording)
	hud.preview.Activated:Connect(togglePreview)

	render = function()
		updateHud()
		UI.clear(root)
		local busy = state == "countdown" or state == "recording"
		local sec = UI.section("Запись актёра", root)
		statusLabel = UI.label("", { Parent = sec, Font = UI.FONT_BOLD, TextSize = 18, Size = UDim2.new(1, 0, 0, 26) })
		setStatus(statusText, statusColor)
		UI.label(
			if connected
				then "● Связь с редактором есть"
				else "○ Связи с редактором нет — записи сохраняются в резерв и подтянутся сами",
			{ Parent = sec, TextSize = 12, TextColor3 = if connected then C.good else C.warn, TextWrapped = true, AutomaticSize = Enum.AutomaticSize.Y }
		)

		local nameRow = UI.row({}, { Parent = sec })
		UI.label("Имя", { Parent = nameRow, Size = UDim2.fromOffset(60, 24), TextColor3 = C.dim })
		UI.flex(UI.textbox(nameText, function(text)
			if text ~= "" then
				nameText = text
			end
		end, { Parent = nameRow, Size = UDim2.fromOffset(100, 24) }))

		local options = { { value = false, label = "Новый актёр" } }
		local dataRoot = SceneData.getRoot(false)
		if dataRoot then
			for _, actor in SceneData.listActors(dataRoot) do
				table.insert(options, { value = actor.Name, label = "Перезаписать: " .. SceneData.getName(actor) })
			end
		end
		local targetRow = UI.row({}, { Parent = sec })
		UI.label("Цель", { Parent = targetRow, Size = UDim2.fromOffset(60, 24), TextColor3 = C.dim })
		UI.flex(UI.cycle(options, targetId or false, function(v)
			targetId = if v then v else nil
			if targetId and dataRoot then
				local actor = SceneData.findActor(dataRoot, targetId)
				if actor then
					nameText = SceneData.getName(actor)
				end
			else
				nameText = baseName .. (if take > 1 then " " .. take else "")
			end
			render()
		end, { Parent = targetRow, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(100, 24) }))

		local startRow = UI.row({}, { Parent = sec })
		UI.label("Старт, с", { Parent = startRow, Size = UDim2.fromOffset(60, 24), TextColor3 = C.dim })
		startBox = UI.textbox(UI.formatNumber(config.start or 0), function(text, box)
			local v = UI.parseNumber(text)
			config.start = math.max(0, v or config.start or 0)
			box.Text = UI.formatNumber(config.start)
		end, { Parent = startRow, Size = UDim2.fromOffset(50, 24) })
		UI.label("время сцены, с которого начнётся дубль", {
			Parent = startRow,
			Size = UDim2.fromOffset(200, 24),
			TextColor3 = C.dim,
			TextSize = 12,
		})

		UI.row({
			UI.toggle("Сцена во время записи", playScene, function(v)
				playScene = v
			end),
			UI.toggle("Камера сцены", sceneCamera, function(v)
				sceneCamera = v
			end),
		}, { Parent = sec })

		UI.button(if busy then "■  Стоп" else "●  Записать", toggleRecording, {
			Parent = sec,
			AutomaticSize = Enum.AutomaticSize.None,
			Size = UDim2.new(1, 0, 0, 38),
			TextSize = 18,
			Font = UI.FONT_BOLD,
			BackgroundColor3 = if busy then C.panel2 else C.record,
		})
		if not busy then
			UI.button(if state == "preview" then "■ Остановить просмотр" else "▶ Просмотр сцены (с камерой)", togglePreview, {
				Parent = sec,
				AutomaticSize = Enum.AutomaticSize.None,
				Size = UDim2.new(1, 0, 0, 28),
			})
		end

		if #session > 0 then
			local list = UI.section("Дубли в этом тесте", root)
			for _, entry in session do
				local mark = if entry.sent then "✓ в редакторе" elseif entry.saved then "• в резерве" else "× не сохранён"
				UI.label(string.format("%s · %.1f с · %s", entry.name, entry.length, mark), { Parent = list, TextSize = 13 })
			end
			UI.paragraph(
				"Дубли уже играют в этом тесте. В редакторе они станут актёрами после остановки теста (Shift+F5).",
				{ Parent = list }
			)
		end

		local settings = UI.section("Настройки", root)
		local row = UI.row({}, { Parent = settings })
		UI.label("Кадров/с", { Parent = row, Size = UDim2.fromOffset(58, 24), TextColor3 = C.dim })
		UI.textbox(tostring(getSetting(plugin, SETTING_FPS, 30)), function(text, box)
			local v = math.clamp(math.floor(UI.parseNumber(text) or 30), 5, 60)
			setSetting(plugin, SETTING_FPS, v)
			box.Text = tostring(v)
		end, { Parent = row, Size = UDim2.fromOffset(40, 24) })
		UI.label("Отсчёт, с", { Parent = row, Size = UDim2.fromOffset(62, 24), TextColor3 = C.dim })
		UI.textbox(tostring(getSetting(plugin, SETTING_COUNTDOWN, 3)), function(text, box)
			local v = math.clamp(math.floor(UI.parseNumber(text) or 3), 0, 10)
			setSetting(plugin, SETTING_COUNTDOWN, v)
			box.Text = tostring(v)
		end, { Parent = row, Size = UDim2.fromOffset(40, 24) })
		UI.toggle("Кнопки записи поверх игры", hud.gui.Enabled, function(v)
			hud.gui.Enabled = v
			setSetting(plugin, SETTING_HUD, v)
		end, { Parent = settings })
		UI.toggle("Открывать это окно при запуске теста", getSetting(plugin, SETTING_AUTO_OPEN, true), function(v)
			setSetting(plugin, SETTING_AUTO_OPEN, v)
		end, { Parent = settings })
		UI.paragraph(
			"Горячие клавиши: File → Customize Shortcuts → «BBS: запись / стоп» и «BBS: просмотр». " .. Version.LABEL,
			{ Parent = settings }
		)
	end

	bridge:connectToEdit(function(cfg)
		if type(cfg.start) == "number" then
			config.start = cfg.start
			if startBox and state == "idle" then
				startBox.Text = UI.formatNumber(config.start)
			end
		end
	end, function()
		connected = true
		if state == "idle" then
			render()
		end
	end)

	pcall(function()
		local action = plugin:CreatePluginAction(
			"BBSStudio_ToggleRecord",
			"BBS: запись / стоп",
			"Начать или остановить запись актёра BBS Studio",
			"",
			true
		)
		action.Triggered:Connect(toggleRecording)
		local previewAction = plugin:CreatePluginAction(
			"BBSStudio_TogglePreview",
			"BBS: просмотр",
			"Проиграть сцену в тесте",
			"",
			true
		)
		previewAction.Triggered:Connect(togglePreview)
	end)

	if player then
		player.CharacterAdded:Connect(function()
			if state == "idle" and #session == 0 then
				setStatus("Готово к записи", C.text)
				render()
			end
		end)
	end

	plugin.Unloading:Connect(function()
		recorder:stop()
		stopScene()
		hud.gui:Destroy()
	end)

	render()
end

return PlayApp
