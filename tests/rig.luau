local H = require("./harness")
local CFrame, Vector3, Instance = H.CFrame, H.Vector3, H.Instance
local check, load = H.check, H.load
local function near(a, b, eps) return (a - b).Magnitude <= (eps or 1e-3) end

local Rig, Codec = load("Rig"), load("Codec")

local function part(name, parent, cf)
	local p = Instance.new("Part"); p.Name = name; p.CFrame = cf or CFrame.new(); p.Parent = parent; return p
end
local function motor(name, p0, p1, c0, c1)
	local m = Instance.new("Motor6D"); m.Name = name; m.Part0 = p0; m.Part1 = p1; m.C0 = c0; m.C1 = c1 or CFrame.new(); m.Parent = p1; return m
end
local model = Instance.new("Model"); model.Name = "Rig"
local hrp = part("HumanoidRootPart", model)
local lower = part("LowerTorso", model)
local upper = part("UpperTorso", model)
local head = part("Head", model)
Instance.new("Humanoid").Parent = model
motor("Root", hrp, lower, CFrame.new(0, -0.2, 0))
motor("Waist", lower, upper, CFrame.new(0, 0.5, 0), CFrame.new(0, -0.5, 0))
-- deliberately inverted joint (Part0 = child side) to test the inverse path
local neck = motor("Neck", head, upper, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.8, 0))
local acc = Instance.new("Accessory"); acc.Parent = model
local handle = part("Handle", acc, CFrame.new(100, 100, 100)) -- stale position must not matter
local w = Instance.new("Weld"); w.Part0 = head; w.Part1 = handle; w.C0 = CFrame.new(0, 1, 0); w.C1 = CFrame.new(); w.Parent = handle
local script_ = Instance.new("Script"); script_.Parent = model

local info = Rig.prepare(model)
check(info ~= nil and info.root == hrp, "prepare finds HumanoidRootPart")
check(#model:GetDescendants() > 0 and model:FindFirstChildOfClass("Script") == nil, "scripts stripped")
check(hrp.Anchored and head.Anchored and handle.Anchored, "all parts anchored")
check(neck.Enabled == false and w.Enabled == false, "joints disabled")

local parts = { "LowerTorso", "UpperTorso" } -- recorded joint order (Part1 names)
local rootCf = CFrame.new(10, 3, 5) * CFrame.Angles(0, math.rad(90), 0)
local waistT = CFrame.Angles(math.rad(30), 0, 0)
Rig.applyPose(info, rootCf, { LowerTorso = CFrame.identity, UpperTorso = waistT })
check(H.stats.bulkMoves == 1, "BulkMoveTo used once per apply")
check(near(hrp.CFrame.Position, rootCf.Position), "root placed")
local expLower = rootCf * CFrame.new(0, -0.2, 0)
check(near(lower.CFrame.Position, expLower.Position), "lower torso via Root motor")
local expUpper = expLower * CFrame.new(0, 0.5, 0) * waistT * CFrame.new(0, -0.5, 0):Inverse()
check(near(upper.CFrame.Position, expUpper.Position), "upper torso uses recorded Waist transform")
local expHead = expUpper * CFrame.new(0, 0.8, 0) * waistT:Inverse() * CFrame.new(0, -0.5, 0):Inverse()
check(near(head.CFrame.Position, expHead.Position), "inverted Neck solved")
check(near(handle.CFrame.Position, (expHead * CFrame.new(0, 1, 0)).Position), "accessory follows head via weld C0/C1")

-- codec: Cyrillic name survives as pure ASCII
local rec = { id = "x", name = "Актёр 100% тест", fps = 30, rig = "R15", userId = 0, parts = parts,
	frames = { { root = rootCf, joints = { CFrame.identity, waistT } }, { root = rootCf, joints = { CFrame.identity, waistT } } } }
Codec.computeLength(rec)
local str = Codec.encodeRecording(rec)
check(not string.find(str, "[\128-\255]"), "encoded recording is pure ASCII")
check(Codec.decodeRecording(str).name == "Актёр 100% тест", "name round-trips through escaping")

-- bridge: multi-part reassembly, out of order
local Bridge = load("Bridge")
local b = Bridge.new({ GetSetting = function() return nil end, SetSetting = function() end })
local big = string.rep("abcdefghij", 15000) -- 150 KB → 3 parts
local sent = {}
b.editConnection = { Connected = true, SendMessage = function(_, m) table.insert(sent, m) end }
local ok = b:sendToEdit("rid", big)
check(ok and #sent == 3, "sendToEdit splits into 3 parts")
local got
for _, i in { 3, 1, 2 } do b:onMessage(sent[i], function(s) got = s end) end
check(got == big, "edit side reassembles out-of-order parts")
print("ALL OK")
