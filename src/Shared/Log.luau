--!nonstrict
-- Small event log shown in the plugin and mirrored to Output.
local Log = {}

local MAX = 60
Log.entries = {}
Log.listeners = {}

local function push(level: string, text: string)
	table.insert(Log.entries, { time = os.time(), level = level, text = text })
	if #Log.entries > MAX then
		table.remove(Log.entries, 1)
	end
	if level == "error" or level == "warn" then
		warn("[BBS Studio] " .. text)
	else
		print("[BBS Studio] " .. text)
	end
	for _, fn in Log.listeners do
		task.spawn(fn)
	end
end

function Log.info(text: string)
	push("info", text)
end

function Log.warn(text: string)
	push("warn", text)
end

function Log.error(text: string)
	push("error", text)
end

function Log.onChanged(fn: () -> ())
	table.insert(Log.listeners, fn)
end

return Log
