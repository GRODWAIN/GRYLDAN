--!nonstrict
-- Plays a skin's state animations (idle/walk/run/jump/...) along a recorded path, like Roblox's
-- Animate script would: the state comes from the recorded Humanoid state or from root motion,
-- and walk/run cycles advance with travelled distance so feet match the speed.
local Clip = require(script.Parent.Clip)
local ClipLibrary = require(script.Parent.ClipLibrary)
local Anims = require(script.Parent.Anims)

local Locomotion = {}

local FADE = 0.2
local MIN_SEGMENT = 0.15
local STATE_FROM_CODE = { [2] = "jump", [3] = "fall", [4] = "climb", [5] = "sit", [6] = "swim" }
local LOOPING = { idle = true, walk = true, run = true, climb = true, swim = true, swimidle = true, sit = true }

local cache = setmetatable({}, { __mode = "k" })

local function groundState(speed: number): string
	if speed < 0.75 then
		return "idle"
	elseif speed < 12 then
		return "walk"
	end
	return "run"
end

function Locomotion.analyze(rec)
	local cached = cache[rec]
	if cached and cached.frames == #rec.frames then
		return cached
	end
	local frames = rec.frames
	local n = #frames
	local fps = rec.fps
	local cum = table.create(n, 0)
	for i = 2, n do
		local d = frames[i].root.Position - frames[i - 1].root.Position
		cum[i] = cum[i - 1] + Vector3.new(d.X, 0, d.Z).Magnitude
	end
	local states = table.create(n)
	for i = 1, n do
		local a, b = math.max(1, i - 3), math.min(n, i + 3)
		local dt = math.max(b - a, 1) / fps
		local speed = (cum[b] - cum[a]) / dt
		local vy = (frames[b].root.Position.Y - frames[a].root.Position.Y) / dt
		local code = frames[i].s
		local st
		if code and code > 0 then
			st = STATE_FROM_CODE[code]
			if st == "swim" and speed < 1 then
				st = "swimidle"
			end
			st = st or groundState(speed)
		elseif vy > 6 then
			st = "jump"
		elseif vy < -6 then
			st = "fall"
		else
			st = groundState(speed)
		end
		states[i] = st
	end
	local raw = {}
	for i = 1, n do
		local last = raw[#raw]
		if last and last.state == states[i] then
			last.i1 = i
		else
			table.insert(raw, { state = states[i], i0 = i, i1 = i })
		end
	end
	-- absorb flickers shorter than MIN_SEGMENT (jumps are short but real)
	local segs = {}
	for _, s in raw do
		local last = segs[#segs]
		local short = (s.i1 - s.i0 + 1) / fps < MIN_SEGMENT and s.state ~= "jump"
		if last and (short or last.state == s.state) then
			last.i1 = s.i1
		else
			table.insert(segs, s)
		end
	end
	for _, s in segs do
		s.t0 = (s.i0 - 1) / fps
	end
	local result = { frames = n, cum = cum, segs = segs }
	cache[rec] = result
	return result
end

local function cumAt(info, fps: number, t: number): number
	local cum = info.cum
	local f = math.max(0, t) * fps
	local i = math.floor(f) + 1
	local n = #cum
	if i >= n then
		return cum[n] or 0
	end
	return cum[i] + (cum[i + 1] - cum[i]) * (f - (i - 1))
end

local function sampleSegment(rec, info, seg, skin: Instance?, rig: string, t: number, out)
	local clip = ClipLibrary.get(Anims.resolve(skin, seg.state))
	if not clip then
		return false
	end
	local animTime
	if seg.state == "walk" or seg.state == "run" or seg.state == "swim" then
		local divisor = if rig == "R6" then 14.5 elseif seg.state == "walk" then 8 else 16
		animTime = (cumAt(info, rec.fps, t) - cumAt(info, rec.fps, seg.t0)) / divisor
	else
		animTime = t - seg.t0
	end
	Clip.sample(clip, animTime, out, if LOOPING[seg.state] then true else nil)
	return true
end

function Locomotion.sample(rec, rel: number, skin: Instance?, out: { [string]: CFrame })
	if #rec.frames == 0 then
		return
	end
	local info = Locomotion.analyze(rec)
	local segs = info.segs
	local t = math.clamp(rel, 0, rec.length)
	local lo, hi = 1, #segs
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if segs[mid].t0 <= t then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local seg = segs[lo]
	local rig = Anims.rigType(skin) or "R15"
	sampleSegment(rec, info, seg, skin, rig, t, out)
	local into = t - seg.t0
	if lo > 1 and into < FADE then
		local prev = {}
		if sampleSegment(rec, info, segs[lo - 1], skin, rig, t, prev) then
			local w = into / FADE
			for name, cf in prev do
				out[name] = cf:Lerp(out[name] or CFrame.identity, w)
			end
		end
	end
end

return Locomotion
