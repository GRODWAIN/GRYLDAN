--!nonstrict
-- Baked clips live in BBS_Data/Clips/<assetId> so they are saved with the place and work in game.
-- The plugin installs a loader (KeyframeSequenceProvider); the live game only reads baked clips.
local SceneData = require(script.Parent.SceneData)
local Clip = require(script.Parent.Clip)
local Log = require(script.Parent.Log)

local ClipLibrary = {}

ClipLibrary.loader = nil :: ((string) -> string)?
ClipLibrary.writer = nil :: ((() -> ()) -> boolean)?

local status: { [string]: string } = {}
local errors: { [string]: string } = {}
local listeners = {}
local cache = setmetatable({}, { __mode = "k" })

function ClipLibrary.normalize(id: any): string?
	if type(id) == "number" then
		return if id > 0 then tostring(math.floor(id)) else nil
	end
	if type(id) ~= "string" then
		return nil
	end
	local digits = string.match(id, "(%d+)%s*$") or string.match(id, "id=(%d+)")
	if not digits or digits == "0" then
		return nil
	end
	return digits
end

function ClipLibrary.setLoader(fn)
	ClipLibrary.loader = fn
end

function ClipLibrary.setWriter(fn)
	ClipLibrary.writer = fn
end

function ClipLibrary.onChanged(fn: () -> ())
	table.insert(listeners, fn)
end

local function fire()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

local function getFolder(create: boolean): Folder?
	local root = SceneData.getRoot(create)
	if not root then
		return nil
	end
	local f = root:FindFirstChild("Clips")
	if not f and create then
		f = Instance.new("Folder")
		f.Name = "Clips"
		f.Parent = root
	end
	return f
end

local function findValue(id: string): StringValue?
	local f = getFolder(false)
	local sv = f and f:FindFirstChild(id)
	return if sv and sv:IsA("StringValue") then sv else nil
end

local function decodeStored(id: string)
	local sv = findValue(id)
	if not sv then
		return nil
	end
	local c = cache[sv]
	if c and c.value == sv.Value then
		return c.clip
	end
	local ok, clip = pcall(Clip.decode, sv.Value)
	if ok and clip then
		cache[sv] = { value = sv.Value, clip = clip }
		return clip
	end
	return nil
end

-- Returns the baked clip, or nil while it is being downloaded (the caller shows the rest pose).
function ClipLibrary.get(idText: any)
	local id = ClipLibrary.normalize(idText)
	if not id then
		return nil
	end
	local clip = decodeStored(id)
	if clip then
		return clip
	end
	ClipLibrary.request(id, false)
	return decodeStored(id)
end

function ClipLibrary.getStatus(idText: any): (string?, string?)
	local id = ClipLibrary.normalize(idText)
	if not id then
		return nil, nil
	end
	if findValue(id) then
		return "ok", nil
	end
	local st = status[id]
	if st == "ok" then
		return nil, nil
	end
	return st, errors[id]
end

function ClipLibrary.request(idText: any, force: boolean?)
	local id = ClipLibrary.normalize(idText)
	local loader = ClipLibrary.loader
	if not id or not loader then
		return
	end
	local st = status[id]
	if st == "loading" or (st == "error" and not force) then
		return
	end
	if not force and findValue(id) then
		return
	end
	status[id] = "loading"
	errors[id] = nil
	task.spawn(function()
		local ok, result = pcall(loader, id)
		if ok and type(result) == "string" then
			local function write()
				local f = getFolder(true) :: Folder
				local sv = f:FindFirstChild(id)
				if not sv then
					sv = Instance.new("StringValue")
					sv.Name = id
				end
				sv.Value = result
				sv.Parent = f
			end
			local written = if ClipLibrary.writer then ClipLibrary.writer(write) else (pcall(write))
			if written then
				status[id] = "ok"
			else
				status[id] = "error"
				errors[id] = "не удалось сохранить"
			end
		else
			status[id] = "error"
			errors[id] = tostring(result)
			Log.warn("анимация " .. id .. " не загрузилась: " .. tostring(result))
		end
		fire()
	end)
end

function ClipLibrary.counts(): (number, number)
	local loaded = 0
	local f = getFolder(false)
	if f then
		loaded = #f:GetChildren()
	end
	local failed = 0
	for _, st in status do
		if st == "error" then
			failed += 1
		end
	end
	return loaded, failed
end

return ClipLibrary
