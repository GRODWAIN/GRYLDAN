--!nonstrict
-- Scene storage in ReplicatedStorage.BBS_Data, so it is saved with the place and visible to clients:
--   BBS_Data (attrs: Length, PlayerKey, Autoplay, HidePlayer, Letterbox, Loop)
--     Camera: StringValue (JSON keyframes)
--     Actors/<id>: Folder (attrs: DisplayName, Offset, Enabled, DefaultSkin, Color, Order, RecVersion)
--       Recording: Folder of StringValue chunks
--       Skins: Folder of Models
--       SkinKeys: StringValue (JSON [{t, skin}], t relative to the actor's start)
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Codec = require(script.Parent.Codec)
local CameraTrack = require(script.Parent.CameraTrack)

local SceneData = {}

SceneData.ROOT_NAME = "BBS_Data"
SceneData.HIDDEN_SKIN = "-"

local PALETTE = {
	Color3.fromRGB(88, 140, 255),
	Color3.fromRGB(255, 140, 70),
	Color3.fromRGB(90, 200, 120),
	Color3.fromRGB(220, 90, 200),
	Color3.fromRGB(240, 200, 70),
	Color3.fromRGB(80, 200, 220),
	Color3.fromRGB(230, 90, 90),
}

local recCache = setmetatable({}, { __mode = "k" })
local cameraCache = setmetatable({}, { __mode = "k" })
local keysCache = setmetatable({}, { __mode = "k" })

function SceneData.getRoot(create: boolean?): Folder?
	local root = ReplicatedStorage:FindFirstChild(SceneData.ROOT_NAME)
	if not root and create then
		root = Instance.new("Folder")
		root.Name = SceneData.ROOT_NAME
		root:SetAttribute("Length", 0)
		root:SetAttribute("PlayerKey", "P")
		root:SetAttribute("Autoplay", false)
		root:SetAttribute("HidePlayer", true)
		root:SetAttribute("Letterbox", true)
		root:SetAttribute("Loop", false)
		local actors = Instance.new("Folder")
		actors.Name = "Actors"
		actors.Parent = root
		local cam = Instance.new("StringValue")
		cam.Name = "Camera"
		cam.Value = CameraTrack.encode(CameraTrack.new())
		cam.Parent = root
		root.Parent = ReplicatedStorage
	end
	return root
end

function SceneData.getActorsFolder(root: Instance): Folder
	local f = root:FindFirstChild("Actors")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Actors"
		f.Parent = root
	end
	return f
end

function SceneData.listActors(root: Instance): { Folder }
	local f = root:FindFirstChild("Actors")
	local list = {}
	if not f then
		return list
	end
	for _, child in f:GetChildren() do
		if child:IsA("Folder") then
			table.insert(list, child)
		end
	end
	table.sort(list, function(a, b)
		local oa, ob = a:GetAttribute("Order") or 0, b:GetAttribute("Order") or 0
		if oa == ob then
			return a.Name < b.Name
		end
		return oa < ob
	end)
	return list
end

function SceneData.findActor(root: Instance, id: string): Folder?
	local f = root:FindFirstChild("Actors")
	local actor = f and f:FindFirstChild(id)
	return if actor and actor:IsA("Folder") then actor else nil
end

function SceneData.getName(actor: Instance): string
	local name = actor:GetAttribute("DisplayName")
	return if type(name) == "string" then name else actor.Name
end

-- Recording ----------------------------------------------------------------

function SceneData.getRecording(actor: Instance)
	local folder = actor:FindFirstChild("Recording")
	if not folder then
		return nil
	end
	local version = actor:GetAttribute("RecVersion") or 0
	local cached = recCache[actor]
	if cached and cached.version == version then
		return cached.rec
	end
	local rec = Codec.decodeRecording(Codec.readChunks(folder))
	recCache[actor] = { version = version, rec = rec }
	return rec
end

function SceneData.setRecording(actor: Instance, rec)
	local folder = actor:FindFirstChild("Recording")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Recording"
		folder.Parent = actor
	end
	Codec.writeChunks(folder, Codec.encodeRecording(rec))
	local version = (tonumber(actor:GetAttribute("RecVersion")) or 0) + 1
	actor:SetAttribute("RecVersion", version)
	actor:SetAttribute("RecordingId", rec.id)
	recCache[actor] = { version = version, rec = rec }
end

function SceneData.actorLength(actor: Instance): number
	local rec = SceneData.getRecording(actor)
	return if rec then rec.length else 0
end

-- Skins --------------------------------------------------------------------

function SceneData.getSkinsFolder(actor: Instance): Folder
	local f = actor:FindFirstChild("Skins")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Skins"
		f.Parent = actor
	end
	return f
end

function SceneData.listSkins(actor: Instance): { Model }
	local list = {}
	local f = actor:FindFirstChild("Skins")
	if f then
		for _, child in f:GetChildren() do
			if child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

function SceneData.getSkin(actor: Instance, name: string): Model?
	local f = actor:FindFirstChild("Skins")
	local m = f and f:FindFirstChild(name)
	return if m and m:IsA("Model") then m else nil
end

-- Adds a model as a skin under a unique name and returns that name.
function SceneData.addSkin(actor: Instance, model: Model, name: string?): string
	local folder = SceneData.getSkinsFolder(actor)
	local base = name or model.Name
	if base == "" or base == SceneData.HIDDEN_SKIN then
		base = "Скин"
	end
	local unique = base
	local n = 1
	while folder:FindFirstChild(unique) do
		n += 1
		unique = base .. " " .. n
	end
	model.Name = unique
	model.Parent = folder
	local default = actor:GetAttribute("DefaultSkin")
	if not default or not SceneData.getSkin(actor, default) then
		actor:SetAttribute("DefaultSkin", unique)
	end
	return unique
end

function SceneData.getSkinKeys(actor: Instance): { { t: number, skin: string } }
	local sv = actor:FindFirstChild("SkinKeys")
	if not sv or not sv:IsA("StringValue") then
		return {}
	end
	local cached = keysCache[actor]
	if cached and cached.value == sv.Value then
		return cached.keys
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(sv.Value)
	end)
	local keys = {}
	if ok and type(data) == "table" then
		for _, k in data do
			if type(k) == "table" and type(k.skin) == "string" then
				table.insert(keys, { t = tonumber(k.t) or 0, skin = k.skin })
			end
		end
	end
	table.sort(keys, function(a, b)
		return a.t < b.t
	end)
	keysCache[actor] = { value = sv.Value, keys = keys }
	return keys
end

function SceneData.setSkinKeys(actor: Instance, keys)
	local sv = actor:FindFirstChild("SkinKeys")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "SkinKeys"
		sv.Parent = actor
	end
	local sorted = table.clone(keys)
	table.sort(sorted, function(a, b)
		return a.t < b.t
	end)
	sv.Value = HttpService:JSONEncode(sorted)
end

function SceneData.skinAt(actor: Instance, rel: number): string?
	local skin = actor:GetAttribute("DefaultSkin")
	for _, k in SceneData.getSkinKeys(actor) do
		if k.t <= rel + 1e-6 then
			skin = k.skin
		else
			break
		end
	end
	return skin
end

-- Actors -------------------------------------------------------------------

function SceneData.createActor(root: Instance, opts)
	local actorsFolder = SceneData.getActorsFolder(root)
	local existing = SceneData.listActors(root)
	local maxOrder = 0
	for _, a in existing do
		maxOrder = math.max(maxOrder, a:GetAttribute("Order") or 0)
	end
	local actor = Instance.new("Folder")
	actor.Name = Codec.newId()
	actor:SetAttribute("DisplayName", opts.name or ("Актёр " .. (#existing + 1)))
	actor:SetAttribute("Offset", opts.offset or 0)
	actor:SetAttribute("Enabled", true)
	actor:SetAttribute("Order", maxOrder + 1)
	actor:SetAttribute("Color", PALETTE[(#existing % #PALETTE) + 1])
	SceneData.getSkinsFolder(actor)
	SceneData.setSkinKeys(actor, {})
	if opts.skin then
		SceneData.addSkin(actor, opts.skin)
	end
	if opts.rec then
		SceneData.setRecording(actor, opts.rec)
	end
	actor.Parent = actorsFolder
	return actor
end

-- Camera -------------------------------------------------------------------

function SceneData.getCamera(root: Instance)
	local sv = root:FindFirstChild("Camera")
	local value = if sv and sv:IsA("StringValue") then sv.Value else ""
	local cached = cameraCache[root]
	if cached and cached.value == value then
		return cached.track
	end
	local track = CameraTrack.decode(value)
	cameraCache[root] = { value = value, track = track }
	return track
end

function SceneData.setCamera(root: Instance, track)
	local sv = root:FindFirstChild("Camera")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "Camera"
		sv.Parent = root
	end
	CameraTrack.sort(track)
	sv.Value = CameraTrack.encode(track)
end

-- Returns an editable deep copy of the camera track.
function SceneData.copyCamera(root: Instance)
	local src = SceneData.getCamera(root)
	local copy = { interp = src.interp, keys = {} }
	for i, k in src.keys do
		copy.keys[i] = table.clone(k)
	end
	return copy
end

-- Length -------------------------------------------------------------------

function SceneData.autoLength(root: Instance): number
	local len = 1
	for _, actor in SceneData.listActors(root) do
		len = math.max(len, (actor:GetAttribute("Offset") or 0) + SceneData.actorLength(actor))
	end
	local keys = SceneData.getCamera(root).keys
	if #keys > 0 then
		len = math.max(len, keys[#keys].t)
	end
	return len
end

function SceneData.sceneLength(root: Instance): number
	local fixed = root:GetAttribute("Length")
	if type(fixed) == "number" and fixed > 0 then
		return fixed
	end
	return SceneData.autoLength(root)
end

return SceneData
