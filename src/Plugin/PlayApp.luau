--!nonstrict
-- Playtest-client window: records the local character while the scene plays around it.
local CoreGui = game:GetService("CoreGui")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = script.Parent.Parent.Shared
local Codec = require(Shared.Codec)
local SceneData = require(Shared.SceneData)
local Playback = require(Shared.Playback)

local UI = require(script.Parent.UI)
local Bridge = require(script.Parent.Bridge)
local Recorder = require(script.Parent.Recorder)

local C = UI.C
local SETTING_FPS = "BBS_RecordFPS"
local SETTING_COUNTDOWN = "BBS_RecordCountdown"
local SETTING_AUTO_OPEN = "BBS_AutoOpenRecorder"

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

local function makeOverlay(): (ScreenGui, TextLabel)
	local gui = Instance.new("ScreenGui")
	gui.Name = "BBS_RecordOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 1000
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 40)
	label.Size = UDim2.fromOffset(400, 60)
	label.Font = UI.FONT_BOLD
	label.TextSize = 36
	label.TextColor3 = C.record
	label.TextStrokeTransparency = 0.4
	label.Text = ""
	label.Parent = gui
	local ok = pcall(function()
		gui.Parent = CoreGui
	end)
	if not ok then
		local player = Players.LocalPlayer
		gui.Parent = player and player:FindFirstChildOfClass("PlayerGui")
	end
	return gui, label
end

function PlayApp.start(plugin: Plugin)
	local player = Players.LocalPlayer
	local bridge = Bridge.new(plugin)
	local recorder = Recorder.new()
	local playback = Playback.new({ folderName = "BBS_LocalPuppets" })
	local _, overlayLabel = makeOverlay()

	local state: string = "idle" -- idle | countdown | recording | preview
	-- read through a function: the state is changed by other threads while the countdown waits
	local function currentState(): string
		return state
	end
	local config = { start = 0 }
	local take = 1
	local nameText = player and player.DisplayName or "Актёр"
	local targetId = nil
	local playScene = true
	local sceneCamera = false
	local session = {}
	local timerConn = nil
	local savedCameraType = nil

	local toolbar = plugin:CreateToolbar("BBS Studio")
	local button = toolbar:CreateButton("BBSStudioRecord", "Окно записи BBS Studio", "", "BBS запись")
	button.ClickableWhenViewportHidden = true
	local autoOpen = getSetting(plugin, SETTING_AUTO_OPEN, true)
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, autoOpen, autoOpen, 340, 520, 300, 300)
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

	local function setStatus(text: string, color: Color3?)
		if statusLabel then
			statusLabel.Text = text
			statusLabel.TextColor3 = color or C.text
		end
	end

	local function restoreCamera()
		if savedCameraType then
			Workspace.CurrentCamera.CameraType = savedCameraType
			savedCameraType = nil
		end
	end

	local function startScene(from: number, useCamera: boolean)
		if not SceneData.getRoot(false) then
			return
		end
		playback.exclude = if targetId then { [targetId] = true } else {}
		playback.useCamera = useCamera
		if useCamera then
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

	local function stopRecording()
		if state == "countdown" then
			state = "idle"
			overlayLabel.Text = ""
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
		overlayLabel.Text = ""
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
		local saved = bridge:savePending(rec, str)
		local sent = bridge:sendToEdit(str)
		table.insert(session, { name = rec.name, length = rec.length, sent = sent, saved = saved })
		setStatus(
			if sent then "✓ Отправлено в редактор" elseif saved then "Сохранено — импортируйте во вкладке «Запись»" else "Не удалось сохранить запись",
			if sent or saved then C.good else C.danger
		)
		if not targetId then
			take += 1
			nameText = (player and player.DisplayName or "Актёр") .. " " .. take
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
				setStatus(tostring(i) .. "…", C.warn)
				overlayLabel.Text = tostring(i)
				task.wait(1)
			end
			if currentState() ~= "countdown" then
				return
			end
			local ok, err = recorder:start({
				fps = tonumber(getSetting(plugin, SETTING_FPS, 30)) or 30,
				name = nameText,
			})
			if not ok then
				state = "idle"
				overlayLabel.Text = ""
				setStatus(err or "Ошибка", C.danger)
				render()
				return
			end
			state = "recording"
			if playScene then
				startScene(config.start or 0, sceneCamera)
			end
			timerConn = RunService.Heartbeat:Connect(function()
				local text = "● REC " .. UI.formatTime(recorder.elapsed)
				overlayLabel.Text = text
				setStatus(text, C.record)
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
			state = "preview"
			startScene(config.start or 0, true)
		end
		render()
	end

	playback.onStopped = function()
		if state == "preview" then
			stopScene()
			state = "idle"
			render()
		end
	end

	render = function()
		UI.clear(root)
		local sec = UI.section("Запись актёра", root)
		statusLabel = UI.label("", { Parent = sec, Font = UI.FONT_BOLD, TextSize = 18, Size = UDim2.new(1, 0, 0, 26) })
		if state == "idle" then
			setStatus(if player and player.Character then "Готово к записи" else "Ждём персонажа…", C.text)
		elseif state == "preview" then
			setStatus("▶ Просмотр сцены", C.accent)
		end
		local busy = state == "countdown" or state == "recording"

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
			end
			render()
		end, { Parent = targetRow, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromOffset(100, 24) }))

		local startRow = UI.row({}, { Parent = sec })
		UI.label("Старт сцены", { Parent = startRow, Size = UDim2.fromOffset(80, 24), TextColor3 = C.dim })
		startBox = UI.textbox(UI.formatNumber(config.start or 0), function(text, box)
			local v = UI.parseNumber(text)
			config.start = math.max(0, v or config.start or 0)
			box.Text = UI.formatNumber(config.start)
		end, { Parent = startRow, Size = UDim2.fromOffset(50, 24) })
		UI.label("с", { Parent = startRow, Size = UDim2.fromOffset(12, 24), TextColor3 = C.dim })

		UI.toggle("Проигрывать сцену во время записи", playScene, function(v)
			playScene = v
		end, { Parent = sec })
		UI.toggle("Камера сцены во время записи", sceneCamera, function(v)
			sceneCamera = v
		end, { Parent = sec })

		UI.button(if busy then "■  Стоп" else "●  Записать", function()
			toggleRecording()
		end, {
			Parent = sec,
			AutomaticSize = Enum.AutomaticSize.None,
			Size = UDim2.new(1, 0, 0, 36),
			TextSize = 18,
			Font = UI.FONT_BOLD,
			BackgroundColor3 = if busy then C.panel2 else C.record,
		})
		if not busy then
			UI.button(if state == "preview" then "■ Остановить просмотр" else "▶ Просмотр сцены", togglePreview, {
				Parent = sec,
			})
		end
		UI.paragraph(
			"Записи уходят в редактор и появляются как актёры после остановки теста. Горячая клавиша: File → Customize Shortcuts → «BBS: запись / стоп».",
			{ Parent = sec }
		)

		if #session > 0 then
			local list = UI.section("Записано в этом тесте", root)
			for _, entry in session do
				UI.label(
					string.format(
						"%s %s · %.1f с",
						if entry.sent then "✓" elseif entry.saved then "•" else "×",
						entry.name,
						entry.length
					),
					{ Parent = list, TextSize = 13 }
				)
			end
		end
		local autoRow = UI.section(nil, root)
		UI.toggle("Открывать это окно при запуске теста", getSetting(plugin, SETTING_AUTO_OPEN, true), function(v)
			pcall(function()
				plugin:SetSetting(SETTING_AUTO_OPEN, v)
			end)
		end, { Parent = autoRow })
	end

	bridge:connectToEdit(function(cfg)
		if type(cfg.start) == "number" then
			config.start = cfg.start
			if startBox and state == "idle" then
				startBox.Text = UI.formatNumber(config.start)
			end
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
	end)

	if player then
		player.CharacterAdded:Connect(function()
			if state == "idle" then
				render()
			end
		end)
	end

	plugin.Unloading:Connect(function()
		recorder:stop()
		stopScene()
	end)

	render()
end

return PlayApp
