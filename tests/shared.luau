local H = require("./harness")
local CFrame, Instance = H.CFrame, H.Instance
local near, check = H.near, H.check
local load = H.load
local ReplicatedStorage = H.services.ReplicatedStorage

local Codec, CameraTrack, SceneData = load("Codec"), load("CameraTrack"), load("SceneData")

local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-3) end
local function check(cond, msg) if not cond then error("FAIL: " .. msg, 2) end print("ok  " .. msg) end

-- Codec round trip
local rec = { id = "abc", name = "Тест Актёр", fps = 30, rig = "R15", userId = 1, parts = { "Head", "LeftHand", "UpperTorso" }, frames = {} }
for i = 0, 30 do
	local t = i / 30
	table.insert(rec.frames, { root = CFrame.new(t * 10, 3, -t) * CFrame.Angles(0, t, 0),
		joints = { CFrame.Angles(t, 0, 0), CFrame.new(0, t, 0), CFrame.identity } })
end
Codec.computeLength(rec)
check(near(rec.length, 1), "length = 1s")
local str = Codec.encodeRecording(rec)
local back = Codec.decodeRecording(str)
check(back.name == "Тест Актёр" and #back.frames == 31 and #back.parts == 3, "decode header + frames")
local root, joints = Codec.sample(back, 0.5)
check(near(root.Position.X, 5, 0.01) and near(root.Position.Z, -0.5, 0.01), "sample root mid")
local rx = joints[1]:ToEulerAnglesXYZ()
check(near(rx, 0.5, 0.01), "sample joint rotation mid")
check(near(joints[2].Position.Y, 0.5, 0.01), "sample joint translation mid")
local r2 = Codec.sample(back, 99)
check(near(r2.Position.X, 10, 0.01), "sample clamps past end")
local trimmed = Codec.trim(back, 0.5, back.length)
check(#trimmed.frames == 16 and near(trimmed.length, 0.5), "trim start")
check(near(trimmed.frames[1].root.Position.X, 5, 0.01), "trim keeps world positions")

-- chunking with multibyte header
local folder = Instance.new("Folder")
Codec.CHUNK_SIZE = 7
Codec.writeChunks(folder, str)
check(#folder:GetChildren() > 10, "multiple chunks written")
check(Codec.readChunks(folder) == str, "chunks reassemble exactly")
for _, c in folder:GetChildren() do
	check(utf8.len(c.Value) ~= nil, "chunk " .. c.Name .. " valid utf8")
	break
end
local allValid = true
for _, c in folder:GetChildren() do if utf8.len(c.Value) == nil then allValid = false end end
check(allValid, "all chunks valid utf8")
Codec.CHUNK_SIZE = 100000

-- camera
local track = CameraTrack.new()
track.keys = {
	{ t = 0, cf = CFrame.new(0, 0, 0), fov = 70, ease = "linear" },
	{ t = 2, cf = CFrame.new(10, 0, 0), fov = 50, ease = "cut" },
	{ t = 4, cf = CFrame.new(100, 0, 0), fov = 30, ease = "linear" },
}
track.interp = "linear"
local cf, fov = CameraTrack.evaluate(track, 1)
check(near(cf.Position.X, 5) and near(fov, 60), "camera linear mid")
cf = CameraTrack.evaluate(track, 3.9)
check(near(cf.Position.X, 10), "cut holds shot until next key")
cf = CameraTrack.evaluate(track, 4)
check(near(cf.Position.X, 100), "cut jumps at next key")
track.interp = "catmull"
cf = CameraTrack.evaluate(track, 1)
check(near(cf.Position.X, 5, 0.6), "catmull mid ~5 (no cross-cut influence)")
local decoded = CameraTrack.decode(CameraTrack.encode(track))
check(#decoded.keys == 3 and decoded.keys[2].ease == "cut" and decoded.interp == "catmull", "camera encode/decode")

-- scene data
local sceneRoot = SceneData.getRoot(true)
check(sceneRoot ~= nil and sceneRoot.Parent == ReplicatedStorage, "root created")
local skin = Instance.new("Model"); skin.Name = "Скин"
local actor = SceneData.createActor(sceneRoot, { name = "A", rec = back, skin = skin, offset = 2 })
check(SceneData.getName(actor) == "A" and actor:GetAttribute("DefaultSkin") == "Скин", "actor created with default skin")
check(SceneData.getRecording(actor) == back, "recording cached")
local skin2 = Instance.new("Model")
check(SceneData.addSkin(actor, skin2, "Скин") == "Скин 2", "unique skin names")
SceneData.setSkinKeys(actor, { { t = 0.5, skin = "Скин 2" }, { t = 0.8, skin = "-" } })
check(SceneData.skinAt(actor, 0.2) == "Скин" and SceneData.skinAt(actor, 0.6) == "Скин 2" and SceneData.skinAt(actor, 1) == "-", "skin keys over time")
check(near(SceneData.sceneLength(sceneRoot), 3), "auto length = offset + rec")
SceneData.setCamera(sceneRoot, track)
check(near(SceneData.sceneLength(sceneRoot), 4), "auto length includes camera")
-- re-read recording from chunks (new version)
SceneData.setRecording(actor, trimmed)
check(#SceneData.getRecording(actor).frames == 16, "setRecording updates cache")
print("ALL OK")
