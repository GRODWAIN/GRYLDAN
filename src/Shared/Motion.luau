--!nonstrict
-- Final pose of an actor at a moment: base motion (recorded joints / skin animations / none),
-- then timed action clips, then the user's pose keyframes on top.
local HttpService = game:GetService("HttpService")

local Codec = require(script.Parent.Codec)
local Clip = require(script.Parent.Clip)
local ClipLibrary = require(script.Parent.ClipLibrary)
local Locomotion = require(script.Parent.Locomotion)
local PoseTrack = require(script.Parent.PoseTrack)

local Motion = {}

Motion.MODES = { "auto", "record", "skin", "none" }

local actionsCache = setmetatable({}, { __mode = "k" })

function Motion.getMode(actor: Instance): string
	local mode = actor:GetAttribute("Motion")
	return if type(mode) == "string" and table.find(Motion.MODES, mode) then mode else "auto"
end

function Motion.effectiveMode(actor: Instance, rec): string
	local mode = Motion.getMode(actor)
	if mode == "auto" then
		return if rec and #rec.parts > 0 then "record" else "skin"
	end
	return mode
end

-- Actions: [{ t, id, name, speed, loop, dur, fade }], t relative to the actor's start.
function Motion.getActions(actor: Instance)
	local sv = actor:FindFirstChild("Actions")
	if not sv or not sv:IsA("StringValue") then
		return {}
	end
	local cached = actionsCache[actor]
	if cached and cached.value == sv.Value then
		return cached.list
	end
	local list = {}
	local ok, data = pcall(function()
		return HttpService:JSONDecode(sv.Value)
	end)
	if ok and type(data) == "table" then
		for _, a in data do
			if type(a) == "table" and ClipLibrary.normalize(a.id) then
				table.insert(list, {
					t = tonumber(a.t) or 0,
					id = ClipLibrary.normalize(a.id),
					name = if type(a.name) == "string" then a.name else ("ID " .. tostring(a.id)),
					speed = math.clamp(tonumber(a.speed) or 1, 0.05, 10),
					loop = a.loop == true,
					dur = tonumber(a.dur),
					fade = math.clamp(tonumber(a.fade) or 0.2, 0, 2),
				})
			end
		end
	end
	table.sort(list, function(a, b)
		return a.t < b.t
	end)
	actionsCache[actor] = { value = sv.Value, list = list }
	return list
end

function Motion.setActions(actor: Instance, list)
	local sv = actor:FindFirstChild("Actions")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "Actions"
		sv.Parent = actor
	end
	sv.Value = HttpService:JSONEncode(list)
end

function Motion.copyActions(actor: Instance)
	local out = {}
	for i, a in Motion.getActions(actor) do
		out[i] = table.clone(a)
	end
	return out
end

-- Duration of an action in seconds (falls back to 1 s until its clip is loaded).
function Motion.actionLength(a): number
	if a.loop and a.dur and a.dur > 0 then
		return a.dur
	end
	local clip = ClipLibrary.get(a.id)
	if clip and clip.length > 0 then
		return clip.length / a.speed
	end
	return a.dur or 1
end

local function applyActions(actor: Instance, rel: number, pose: { [string]: CFrame })
	for _, a in Motion.getActions(actor) do
		if rel >= a.t then
			local len = Motion.actionLength(a)
			local into = rel - a.t
			if into <= len then
				local clip = ClipLibrary.get(a.id)
				if clip then
					local w = 1
					if a.fade > 0 then
						w = math.clamp(math.min(into, len - into) / a.fade, 0, 1)
					end
					local tmp = {}
					Clip.sample(clip, into * a.speed, tmp, a.loop)
					for name, cf in tmp do
						pose[name] = (pose[name] or CFrame.identity):Lerp(cf, w)
					end
				end
			end
		end
	end
end

-- Returns the root CFrame and joint transforms (by Part1 name) of an actor at rel seconds.
function Motion.evaluate(actor: Instance, rec, skin: Instance?, rel: number, live: { [string]: CFrame }?)
	local rootCf, joints = Codec.sample(rec, rel)
	if not rootCf then
		return nil, nil
	end
	local pose = {}
	local mode = Motion.effectiveMode(actor, rec)
	if mode == "record" and joints then
		for i, name in rec.parts do
			pose[name] = joints[i]
		end
	elseif mode == "skin" and skin and skin:FindFirstChildOfClass("Humanoid") then
		Locomotion.sample(rec, rel, skin, pose)
	end
	applyActions(actor, rel, pose)
	local tracks = PoseTrack.get(actor)
	for name, keys in tracks do
		local offset = (live and live[name]) or PoseTrack.sample(keys, rel)
		if name == PoseTrack.ROOT then
			rootCf *= offset
		else
			pose[name] = (pose[name] or CFrame.identity) * offset
		end
	end
	if live then
		for name, offset in live do
			if not tracks[name] then
				if name == PoseTrack.ROOT then
					rootCf *= offset
				else
					pose[name] = (pose[name] or CFrame.identity) * offset
				end
			end
		end
	end
	return rootCf, pose
end

return Motion
