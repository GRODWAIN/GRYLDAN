-- Loads plugin modules outside Studio with lune: stubs the few services they touch.
-- Run tests from the repository root: lune run tests/<name>.luau
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local H = {}
H.roblox = roblox
H.CFrame, H.Vector3, H.Instance = roblox.CFrame, roblox.Vector3, roblox.Instance
H.stats = { bulkMoves = 0 }

local guid = 0
H.services = {
	HttpService = {
		JSONEncode = function(_, v)
			return serde.encode("json", v)
		end,
		JSONDecode = function(_, s)
			return serde.decode("json", s)
		end,
		GenerateGUID = function()
			guid += 1
			return string.format("%08x-aaaa-bbbb-cccc-dddddddddddd", guid)
		end,
		UrlEncode = function(_, s)
			return s
		end,
		UrlDecode = function(_, s)
			return s
		end,
	},
	TweenService = {
		GetValue = function(_, a)
			return a * a * (3 - 2 * a)
		end,
	},
	Workspace = {
		BulkMoveTo = function(_, parts, cfs)
			for i, p in parts do
				p.CFrame = cfs[i]
			end
			H.stats.bulkMoves += 1
		end,
	},
	ReplicatedStorage = roblox.Instance.new("Folder"),
}
H.game = {
	PlaceId = 0,
	GetService = function(_, n)
		return H.services[n] or error("no service " .. n)
	end,
}

local function proxy(name)
	return setmetatable({ __module = name }, {
		__index = function(_, k)
			return proxy(k)
		end,
	})
end

local cache = {}
-- task.spawn runs inline so asynchronous loads finish within the test
local syncTask = setmetatable({
	spawn = function(fn, ...)
		fn(...)
	end,
	defer = function(fn, ...)
		fn(...)
	end,
}, { __index = task })

function H.load(name: string)
	if cache[name] then
		return cache[name]
	end
	local path = "src/Shared/" .. name .. ".luau"
	if not fs.isFile(path) then
		path = "src/Plugin/" .. name .. ".luau"
	end
	local env = setmetatable({
		game = H.game,
		script = proxy(name),
		CFrame = roblox.CFrame,
		Vector3 = roblox.Vector3,
		Instance = roblox.Instance,
		Color3 = roblox.Color3,
		Enum = roblox.Enum,
		task = syncTask,
		print = function() end,
		warn = function() end,
		require = function(m)
			return H.load(m.__module)
		end,
	}, { __index = _G })
	cache[name] = luau.load(luau.compile(fs.readFile(path)), { debugName = name, environment = env })()
	return cache[name]
end

function H.near(a, b, eps: number?): boolean
	if type(a) == "number" then
		return math.abs(a - b) <= (eps or 1e-3)
	end
	return (a - b).Magnitude <= (eps or 1e-3)
end

function H.check(cond: any, msg: string)
	if not cond then
		error("FAIL: " .. msg, 2)
	end
	print("ok  " .. msg)
end

return H
