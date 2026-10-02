--!nonstrict
-- Camera keyframes: { t, cf, fov, ease }. The ease of a key controls the segment that starts at it.
local HttpService = game:GetService("HttpService")
local Codec = require(script.Parent.Codec)

local CameraTrack = {}

CameraTrack.EASES = { "linear", "smooth", "in", "out", "cut" }
CameraTrack.EASE_LABELS = {
	linear = "Ровно",
	smooth = "Плавно",
	["in"] = "Разгон",
	out = "Торможение",
	cut = "Склейка",
}

local EASE = {
	linear = function(a)
		return a
	end,
	smooth = function(a)
		return a * a * (3 - 2 * a)
	end,
	["in"] = function(a)
		return a * a
	end,
	out = function(a)
		return 1 - (1 - a) * (1 - a)
	end,
	-- hold this shot until the next key, then jump: a hard cut between shots
	cut = function(_a)
		return 0
	end,
}

function CameraTrack.new()
	return { interp = "catmull", keys = {} }
end

function CameraTrack.sort(track)
	table.sort(track.keys, function(a, b)
		return a.t < b.t
	end)
end

function CameraTrack.decode(str: string?)
	local track = CameraTrack.new()
	if type(str) ~= "string" or str == "" then
		return track
	end
	local ok, data = pcall(function()
		return HttpService:JSONDecode(str)
	end)
	if not ok or type(data) ~= "table" then
		return track
	end
	track.interp = data.interp or "catmull"
	for _, k in data.keys or {} do
		table.insert(track.keys, {
			t = tonumber(k.t) or 0,
			cf = Codec.arrayToCFrame(k.p or {}, 1),
			fov = tonumber(k.fov) or 70,
			ease = if EASE[k.ease] then k.ease else "linear",
		})
	end
	CameraTrack.sort(track)
	return track
end

function CameraTrack.encode(track): string
	local keys = {}
	for i, k in track.keys do
		local p = Codec.cframeToArray(k.cf)
		for j, v in p do
			p[j] = math.floor(v * 10000 + 0.5) / 10000
		end
		keys[i] = { t = k.t, p = p, fov = k.fov, ease = k.ease }
	end
	return HttpService:JSONEncode({ interp = track.interp, keys = keys })
end

local function catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, a: number): Vector3
	local a2 = a * a
	local a3 = a2 * a
	return 0.5
		* ((2 * p1) + (p2 - p0) * a + (2 * p0 - 5 * p1 + 4 * p2 - p3) * a2 + (3 * p1 - p0 - 3 * p2 + p3) * a3)
end

function CameraTrack.evaluate(track, t: number): (CFrame?, number?)
	local keys = track.keys
	local n = #keys
	if n == 0 then
		return nil, nil
	end
	if n == 1 or t <= keys[1].t then
		return keys[1].cf, keys[1].fov
	end
	if t >= keys[n].t then
		return keys[n].cf, keys[n].fov
	end
	local i = 1
	while i < n - 1 and keys[i + 1].t <= t do
		i += 1
	end
	local k1, k2 = keys[i], keys[i + 1]
	local span = k2.t - k1.t
	local a = if span > 0 then math.clamp((t - k1.t) / span, 0, 1) else 1
	a = (EASE[k1.ease] or EASE.linear)(a)

	local pos
	if track.interp == "catmull" then
		local prev = keys[i - 1]
		local nextKey = keys[i + 2]
		-- a cut breaks the spline, so neighbours across it are ignored
		local p0 = if prev and prev.ease ~= "cut" then prev.cf.Position else k1.cf.Position
		local p3 = if nextKey and k2.ease ~= "cut" then nextKey.cf.Position else k2.cf.Position
		pos = catmull(p0, k1.cf.Position, k2.cf.Position, p3, a)
	else
		pos = k1.cf.Position:Lerp(k2.cf.Position, a)
	end
	local rot = k1.cf.Rotation:Lerp(k2.cf.Rotation, a)
	return CFrame.new(pos) * rot, k1.fov + (k2.fov - k1.fov) * a
end

return CameraTrack
