-- AnimationConstraint rigs, baked clips, skin locomotion, pose keys and the motion composer.
local H = require("./harness")
local CFrame, Vector3, Instance = H.CFrame, H.Vector3, H.Instance
local check, near, load = H.check, H.near, H.load
local Enum = H.roblox.Enum

local Rig = load("Rig")
local Codec = load("Codec")
local Clip = load("Clip")
local ClipLibrary = load("ClipLibrary")
local SceneData = load("SceneData")
local Anims = load("Anims")
local PoseTrack = load("PoseTrack")
local Motion = load("Motion")
local Locomotion = load("Locomotion")

local function part(name, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Parent = parent
	return p
end

-- R15-like rig with Avatar Joint Upgrade joints (AnimationConstraint + BallSocketConstraint)
local function attachment(parentPart, cf)
	local a = Instance.new("Attachment")
	a.CFrame = cf
	a.Parent = parentPart
	return a
end
local function animJoint(p0, p1, c0, c1)
	local a0, a1 = attachment(p0, c0), attachment(p1, c1)
	local j = Instance.new("AnimationConstraint")
	j.Attachment0 = a0
	j.Attachment1 = a1
	j.Parent = p1
	local ball = Instance.new("BallSocketConstraint")
	ball.Attachment0 = a0
	ball.Attachment1 = a1
	ball.Parent = p1
	return j
end

local rig = Instance.new("Model")
local hrp = part("HumanoidRootPart", rig)
local lower = part("LowerTorso", rig)
local upper = part("UpperTorso", rig)
local head = part("Head", rig)
Instance.new("Humanoid").Parent = rig
animJoint(hrp, lower, CFrame.new(0, -0.2, 0), CFrame.new())
local waist = animJoint(lower, upper, CFrame.new(0, 0.5, 0), CFrame.new(0, -0.5, 0))
animJoint(upper, head, CFrame.new(0, 0.8, 0), CFrame.new(0, -0.5, 0))

local joints = Rig.getJoints(rig)
check(joints.UpperTorso == waist and joints.Head ~= nil and joints.LowerTorso ~= nil, "recorder finds AnimationConstraint joints")

local info = Rig.prepare(rig:Clone())
check(info.byName.Head ~= nil and info.byName.Head.motor, "puppet solves AnimationConstraint as an animated joint")
local tilt = CFrame.Angles(0, 0, math.rad(40))
Rig.applyPose(info, CFrame.new(0, 3, 0), { Head = tilt })
local headNode = info.byName.Head
local upperNode = info.byName.UpperTorso
local expected = upperNode.part.CFrame * CFrame.new(0, 0.8, 0) * tilt * CFrame.new(0, -0.5, 0):Inverse()
check(near(headNode.part.CFrame.Position, expected.Position), "head follows its pose transform")

-- Clip baking from a KeyframeSequence (mocked: lune lacks GetKeyframes/GetPoses)
local function pose(name, cf, weight, style, dir, subs)
	return {
		Name = name,
		CFrame = cf,
		Weight = weight,
		EasingStyle = Enum.PoseEasingStyle[style or "Linear"],
		EasingDirection = Enum.PoseEasingDirection[dir or "Out"],
		IsA = function(_, c)
			return c == "Pose"
		end,
		GetSubPoses = function()
			return subs or {}
		end,
	}
end
local function keyframe(time, poses)
	return {
		Time = time,
		IsA = function(_, c)
			return c == "Keyframe"
		end,
		GetPoses = function()
			return poses
		end,
	}
end
local kfs = {
	Loop = true,
	GetKeyframes = function()
		return {
			keyframe(1, { pose("HumanoidRootPart", CFrame.identity, 0, nil, nil, { pose("Head", CFrame.Angles(0, math.rad(90), 0), 1) }) }),
			keyframe(0, {
				pose("HumanoidRootPart", CFrame.identity, 0, nil, nil, {
					pose("Head", CFrame.identity, 1, "Linear"),
					pose("UpperTorso", CFrame.new(0, 1, 0), 1, "Constant"),
				}),
			}),
		}
	end,
}
local baked = Clip.fromKeyframeSequence(kfs)
check(baked.length == 1 and baked.loop == true, "clip length and loop")
check(baked.tracks.HumanoidRootPart == nil, "weight-0 poses are not animated")
local clip = Clip.decode(Clip.encode(baked))
local out = {}
Clip.sample(clip, 0.5, out)
local _, ry = out.Head:ToEulerAnglesYXZ()
check(near(math.deg(ry), 45, 0.5), "linear pose interpolates halfway")
check(near(out.UpperTorso.Position.Y, 1), "single key holds its value")
Clip.sample(clip, 1.5, out)
_, ry = out.Head:ToEulerAnglesYXZ()
check(near(math.deg(ry), 45, 0.5), "looping clip wraps time")

-- Clip library stores baked clips in BBS_Data and loads through the plugin loader
local root = SceneData.getRoot(true)
local loads = 0
ClipLibrary.setLoader(function(id)
	loads += 1
	if id == "999" then
		error("нет доступа")
	end
	return Clip.encode(baked)
end)
check(ClipLibrary.normalize("rbxassetid://507766666") == "507766666", "normalize rbxassetid")
check(ClipLibrary.normalize("http://www.roblox.com/asset/?id=180435571") == "180435571", "normalize asset url")
check(ClipLibrary.get("123") ~= nil and loads == 1, "missing clip is loaded and stored")
check(root:FindFirstChild("Clips"):FindFirstChild("123") ~= nil, "clip saved under BBS_Data.Clips")
check(ClipLibrary.get("123") ~= nil and loads == 1, "stored clip is reused")
check(ClipLibrary.get("999") == nil and ClipLibrary.getStatus("999") == "error", "failed load reports error")
ClipLibrary.get("999")
check(loads == 2, "failed clip is not retried every frame")

-- Skin animation sets: extracted from Animate, defaults otherwise
local skin = rig:Clone()
skin.Name = "Скин"
local animate = Instance.new("LocalScript")
animate.Name = "Animate"
animate.Parent = skin
local walk = Instance.new("StringValue")
walk.Name = "walk"
walk.Parent = animate
local anim = Instance.new("Animation")
anim.AnimationId = "rbxassetid://555"
anim.Parent = walk
local actor = SceneData.createActor(root, { name = "A", skin = skin })
check(skin:FindFirstChild("Animate") == nil, "skin scripts stripped")
check(Anims.read(skin).walk == "555", "Animate walk animation kept on the skin")
check(Anims.resolve(skin, "walk") == "555", "custom walk resolves")
check(Anims.resolve(skin, "idle") == Anims.DEFAULTS.R15.idle, "missing state falls back to Roblox default")

-- Locomotion: idle, then walking, states from recorded Humanoid codes
local frames = {}
for i = 0, 59 do
	local t = i / 30
	local x = if t < 1 then 0 else (t - 1) * 8
	table.insert(frames, { root = CFrame.new(x, 3, 0), joints = {}, s = 1 })
end
local rec = { id = "r", name = "A", fps = 30, rig = "R15", userId = 0, parts = {}, frames = frames }
Codec.computeLength(rec)
local loco = Locomotion.analyze(rec)
check(#loco.segs == 2 and loco.segs[1].state == "idle" and loco.segs[2].state == "walk", "idle then walk segments")
-- mark clips as available for idle and walk
local function store(id, c)
	local sv = Instance.new("StringValue")
	sv.Name = id
	sv.Value = Clip.encode(c)
	sv.Parent = root:FindFirstChild("Clips")
end
store(Anims.DEFAULTS.R15.idle, { length = 1, loop = true, tracks = { Head = { t = { 0 }, p = { { 0, 0, 0, 0.1, 0, 0 } }, e = { "L:I" } } } })
store("555", { length = 1, loop = true, tracks = { Head = { t = { 0, 1 }, p = { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 1, 0, 0 } }, e = { "L:I", "L:I" } } } })
local p1 = {}
Locomotion.sample(rec, 0.5, skin, p1)
check(p1.Head and near(p1.Head:ToEulerAnglesXYZ(), 0.1, 1e-3), "idle animation plays while standing")
local p2 = {}
Locomotion.sample(rec, 1.6, skin, p2)
-- 0.6 s of walking at 8 studs/s = 4.8 studs; walk cycle advances distance/8 = 0.6 → rx 0.6
check(p2.Head and near(p2.Head:ToEulerAnglesXYZ(), 0.6, 0.03), "walk cycle advances with travelled distance")

-- Motion composer: skin mode + pose keys + live gizmo override
SceneData.setRecording(actor, rec)
check(Motion.effectiveMode(actor, rec) == "skin", "recording without joints defaults to skin animations")
local tracks = { Head = { { t = 0, cf = CFrame.new(0, 0.5, 0), e = "linear" }, { t = 2, cf = CFrame.new(0, 1.5, 0), e = "linear" } } }
PoseTrack.set(actor, tracks)
actor:SetAttribute("Motion", "none")
local rootCf, final = Motion.evaluate(actor, rec, skin, 1)
check(rootCf and near(final.Head.Position.Y, 1, 1e-3), "pose key offset interpolates on top (head raised)")
local _, liveFinal = Motion.evaluate(actor, rec, skin, 1, { Head = CFrame.new(0, 3, 0) })
check(near(liveFinal.Head.Position.Y, 3, 1e-3), "live gizmo offset overrides the key")
actor:SetAttribute("Motion", nil)
local _, layered = Motion.evaluate(actor, rec, skin, 0.5)
local idleHead = CFrame.Angles(0.1, 0, 0)
check(near(layered.Head.Position, (idleHead * PoseTrack.sample(tracks.Head, 0.5)).Position), "pose offset is layered on the skin animation")
PoseTrack.set(actor, { __root = { { t = 0, cf = CFrame.new(0, 2, 0), e = "linear" } } })
local lifted = Motion.evaluate(actor, rec, skin, 0.5)
check(near(lifted.Position.Y, 5), "whole-body key lifts the root")

-- Actions replace base motion while active
PoseTrack.set(actor, {})
Motion.setActions(actor, { { t = 0.2, id = "123", name = "x", speed = 1, loop = false, fade = 0 } })
local _, withAction = Motion.evaluate(actor, rec, skin, 0.7)
_, ry = withAction.Head:ToEulerAnglesYXZ()
check(near(math.deg(ry), 45, 0.5), "action clip overrides the head during its span")
local _, after = Motion.evaluate(actor, rec, skin, 1.5)
local _, ryAfter = after.Head:ToEulerAnglesYXZ()
check(near(ryAfter, 0, 1e-3), "base motion resumes after the action")

-- Codec keeps state codes
local str = Codec.encodeRecording(rec)
check(Codec.decodeRecording(str).frames[10].s == 1, "humanoid state codes survive encoding")
print("ALL OK")
