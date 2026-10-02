--!nonstrict
-- Moves recordings from the playtest client back to the edit session.
-- Channel 1: PluginConnectionService messages (split into parts).
-- Channel 2: plugin settings, which outlive the playtest; the edit side polls and imports them.
local HttpService = game:GetService("HttpService")

local Log = require(script.Parent.Parent.Shared.Log)

local Bridge = {}
Bridge.__index = Bridge

local INDEX_KEY = "BBS_PendingIndex2"
local REC_PREFIX = "BBS_Rec2_"
local MSG_PART = "BBS_PART\n"
local MSG_CFG = "BBS_CFG\n"
local MSG_HELLO = "BBS_HELLO\n"
local PART_SIZE = 60000
local MAX_PENDING = 30

local function getService()
	local ok, service = pcall(function()
		return game:GetService("PluginConnectionService")
	end)
	return if ok then service else nil
end

local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

-- Identifies the place so backups recorded in one place are not auto-imported into another.
function Bridge.placeKey(): string
	if game.PlaceId ~= 0 then
		return "id:" .. tostring(game.PlaceId)
	end
	return "local"
end

function Bridge.new(plugin: Plugin)
	local self = setmetatable({}, Bridge)
	self.plugin = plugin
	self.tests = {}
	self.partial = {}
	self.editConnection = nil
	self.available = getService() ~= nil
	return self
end

-- Backup storage -------------------------------------------------------------

function Bridge:getPendingIndex()
	local ok, index = pcall(function()
		return self.plugin:GetSetting(INDEX_KEY)
	end)
	if not ok or type(index) ~= "table" then
		return {}
	end
	return index
end

function Bridge:savePending(rec, str: string): (boolean, string?)
	local ok, err = pcall(function()
		self.plugin:SetSetting(REC_PREFIX .. rec.id, str)
		local index = self:getPendingIndex()
		table.insert(index, {
			id = rec.id,
			name = HttpService:UrlEncode(rec.name),
			length = rec.length,
			time = os.time(),
			place = Bridge.placeKey(),
		})
		while #index > MAX_PENDING do
			local old = table.remove(index, 1)
			self.plugin:SetSetting(REC_PREFIX .. old.id, nil)
		end
		self.plugin:SetSetting(INDEX_KEY, index)
	end)
	return ok, if ok then nil else tostring(err)
end

function Bridge:loadPending(id: string): string?
	local ok, str = pcall(function()
		return self.plugin:GetSetting(REC_PREFIX .. id)
	end)
	return if ok and type(str) == "string" then str else nil
end

function Bridge:removePending(id: string)
	pcall(function()
		self.plugin:SetSetting(REC_PREFIX .. id, nil)
		local index = self:getPendingIndex()
		for i = #index, 1, -1 do
			if index[i].id == id then
				table.remove(index, i)
			end
		end
		self.plugin:SetSetting(INDEX_KEY, index)
	end)
end

function Bridge.entryName(entry): string
	local ok, name = pcall(function()
		return HttpService:UrlDecode(entry.name)
	end)
	return if ok and type(name) == "string" then name else tostring(entry.name)
end

-- Edit side ------------------------------------------------------------------

function Bridge:onMessage(msg, onRecording: (string) -> ())
	if type(msg) ~= "string" then
		return
	end
	if startsWith(msg, MSG_HELLO) then
		Log.info("связь с тестом установлена")
		return
	end
	if not startsWith(msg, MSG_PART) then
		return
	end
	-- BBS_PART\n<id>\n<index>\n<count>\n<data>
	local id, index, count, data = string.match(msg, "^BBS_PART\n([^\n]+)\n(%d+)\n(%d+)\n(.*)$")
	if not id then
		return
	end
	local i, n = tonumber(index), tonumber(count)
	local entry = self.partial[id]
	if not entry then
		entry = { parts = {}, received = 0, count = n }
		self.partial[id] = entry
	end
	if not entry.parts[i] then
		entry.parts[i] = data
		entry.received += 1
	end
	if entry.received >= entry.count then
		self.partial[id] = nil
		onRecording(table.concat(entry.parts, "", 1, entry.count))
	end
end

function Bridge:listenFromTests(onRecording: (string) -> (), onChanged: () -> ())
	local service = getService()
	if not service then
		Log.warn("PluginConnectionService недоступен — записи будут передаваться через резервное сохранение")
		return
	end
	local testType
	local ok, err = pcall(function()
		testType = Enum.PluginConnectionTargetType.Test
		if not service:CanHaveConnectionType(testType) then
			error("CanHaveConnectionType(Test) = false")
		end
	end)
	if not ok then
		Log.warn("связь с тестами недоступна (" .. tostring(err) .. ") — используется резервное сохранение")
		return
	end
	local function bind(conn)
		if self.tests[conn] or not conn.Connected then
			return
		end
		local binding = conn:BindToMessage(function(msg)
			self:onMessage(msg, onRecording)
		end)
		self.tests[conn] = binding
		conn:GetPropertyChangedSignal("Connected"):Connect(function()
			if not conn.Connected and self.tests[conn] then
				self.tests[conn]:Disconnect()
				self.tests[conn] = nil
				onChanged()
			end
		end)
		onChanged()
	end
	for _, conn in service:GetPluginConnectionsOfType(testType) do
		bind(conn)
	end
	service.Connected:Connect(function(conn)
		if conn.Type == testType then
			bind(conn)
		end
	end)
end

function Bridge:hasActiveTests(): boolean
	return next(self.tests) ~= nil
end

function Bridge:broadcastConfig(config)
	local msg = MSG_CFG .. HttpService:JSONEncode(config)
	for conn in self.tests do
		pcall(function()
			if conn.Connected then
				conn:SendMessage(msg)
			end
		end)
	end
end

-- Playtest side --------------------------------------------------------------

function Bridge:connectToEdit(onConfig: (any) -> (), onConnected: () -> ())
	local service = getService()
	if not service then
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			local editType = Enum.PluginConnectionTargetType.Edit
			if not service:CanHaveConnectionType(editType) then
				return
			end
			local conn = service:GetPluginConnectionsOfType(editType)[1]
			while not conn do
				local candidate = service.Connected:Wait()
				if candidate.Type == editType then
					conn = candidate
				end
			end
			self.editConnection = conn
			conn:BindToMessage(function(msg)
				if type(msg) == "string" and startsWith(msg, MSG_CFG) then
					local okDecode, config = pcall(function()
						return HttpService:JSONDecode(string.sub(msg, #MSG_CFG + 1))
					end)
					if okDecode and type(config) == "table" then
						onConfig(config)
					end
				end
			end)
			conn:SendMessage(MSG_HELLO)
			onConnected()
		end)
		if not ok then
			Log.warn("нет связи с редактором: " .. tostring(err))
		end
	end)
end

function Bridge:isConnectedToEdit(): boolean
	local conn = self.editConnection
	return conn ~= nil and conn.Connected
end

function Bridge:sendToEdit(id: string, str: string): (boolean, string?)
	local conn = self.editConnection
	if not conn then
		return false, "нет соединения"
	end
	local ok, err = pcall(function()
		assert(conn.Connected, "соединение закрыто")
		local count = math.max(1, math.ceil(#str / PART_SIZE))
		for i = 1, count do
			local data = string.sub(str, (i - 1) * PART_SIZE + 1, i * PART_SIZE)
			conn:SendMessage(MSG_PART .. id .. "\n" .. i .. "\n" .. count .. "\n" .. data)
		end
	end)
	return ok, if ok then nil else tostring(err)
end

return Bridge
