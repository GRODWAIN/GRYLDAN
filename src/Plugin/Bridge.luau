--!nonstrict
-- Moves recordings from the playtest client back to the edit session.
-- Primary path: PluginConnectionService. Backup: plugin settings, which survive the playtest.
local HttpService = game:GetService("HttpService")

local Bridge = {}
Bridge.__index = Bridge

local INDEX_KEY = "BBS_PendingIndex"
local REC_PREFIX = "BBS_Rec_"
local MSG_REC = "BBS_REC\n"
local MSG_CFG = "BBS_CFG\n"

local function getService()
	local ok, service = pcall(function()
		return game:GetService("PluginConnectionService")
	end)
	return if ok then service else nil
end

local function startsWith(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

function Bridge.new(plugin: Plugin)
	local self = setmetatable({}, Bridge)
	self.plugin = plugin
	self.tests = {}
	self.editConnection = nil
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

function Bridge:savePending(rec, str: string): boolean
	return (pcall(function()
		self.plugin:SetSetting(REC_PREFIX .. rec.id, str)
		local index = self:getPendingIndex()
		table.insert(index, { id = rec.id, name = rec.name, length = rec.length, time = os.time() })
		self.plugin:SetSetting(INDEX_KEY, index)
	end))
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

-- Edit side ------------------------------------------------------------------

function Bridge:listenFromTests(onRecording: (string) -> (), onChanged: () -> ())
	local service = getService()
	if not service then
		return
	end
	local testType
	local ok = pcall(function()
		testType = Enum.PluginConnectionTargetType.Test
		if not service:CanHaveConnectionType(testType) then
			error("no test connections")
		end
	end)
	if not ok then
		return
	end
	local function bind(conn)
		if self.tests[conn] or not conn.Connected then
			return
		end
		local binding = conn:BindToMessage(function(msg)
			if type(msg) == "string" and startsWith(msg, MSG_REC) then
				onRecording(string.sub(msg, #MSG_REC + 1))
			end
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

function Bridge:connectToEdit(onConfig: (any) -> ())
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
		end)
		if not ok then
			warn("[BBS Studio] нет связи с редактором: " .. tostring(err))
		end
	end)
end

function Bridge:sendToEdit(str: string): boolean
	local conn = self.editConnection
	if not conn then
		return false
	end
	local ok = pcall(function()
		assert(conn.Connected, "disconnected")
		conn:SendMessage(MSG_REC .. str)
	end)
	return ok
end

return Bridge
