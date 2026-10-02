--!nonstrict
-- Animation clips baked from KeyframeSequences into plain data, so they can be sampled anywhere
-- (edit mode, playtest, live game) without the Animator.
-- Track per joint (Part1 name): times, Motor6D/AnimationConstraint transforms and easing per key.
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local Codec = require(script.Parent.Codec)

local Clip = {}

local STYLE_CODE = {
	Linear = "L",
	Constant = "C",
	Cubic = "Cu",
	CubicV2 = "Cu",
	Elastic = "El",
	Bounce = "Bo",
}
-- PoseEasingDirection In/Out are reversed relative to TweenService (documented legacy quirk)
local DIR_CODE = { In = "O", Out = "I", InOut = "IO" }

local TWEEN_STYLE = {
	Cu = Enum.EasingStyle.Cubic,
	El = Enum.EasingStyle.Elastic,
	Bo = Enum.EasingStyle.Bounce,
}
local TWEEN_DIR = {
	I = Enum.EasingDirection.In,
	O = Enum.EasingDirection.Out,
	IO = Enum.EasingDirection.InOut,
}

local function round(v: number): number
	return math.floor(v * 10000 + 0.5) / 10000
end

function Clip.fromKeyframeSequence(kfs: KeyframeSequence)
	local tracks = {}
	local length = 0
	local keyframes = {}
	for _, kf in kfs:GetKeyframes() do
		if kf:IsA("Keyframe") then
			table.insert(keyframes, kf)
		end
	end
	table.sort(keyframes, function(a, b)
		return a.Time < b.Time
	end)

	local function addPose(pose: Pose, time: number)
		-- weight 0 poses only keep the hierarchy and do not animate their part
		if pose.Weight > 0 then
			local track = tracks[pose.Name]
			if not track then
				track = { t = {}, p = {}, e = {} }
				tracks[pose.Name] = track
			end
			local arr = Codec.cframeToArray(pose.CFrame)
			for i, v in arr do
				arr[i] = round(v)
			end
			table.insert(track.t, round(time))
			table.insert(track.p, arr)
			local style = STYLE_CODE[pose.EasingStyle.Name] or "L"
			local dir = DIR_CODE[pose.EasingDirection.Name] or "I"
			table.insert(track.e, style .. ":" .. dir)
		end
		for _, sub in pose:GetSubPoses() do
			if sub:IsA("Pose") then
				addPose(sub, time)
			end
		end
	end

	for _, kf in keyframes do
		length = math.max(length, kf.Time)
		for _, pose in kf:GetPoses() do
			if pose:IsA("Pose") then
				addPose(pose, kf.Time)
			end
		end
	end
	return { length = length, loop = kfs.Loop, tracks = tracks }
end

function Clip.encode(clip): string
	return HttpService:JSONEncode({ v = 1, length = clip.length, loop = clip.loop, tracks = clip.tracks })
end

function Clip.decode(str: string)
	local data = HttpService:JSONDecode(str)
	if type(data) ~= "table" or type(data.tracks) ~= "table" then
		return nil
	end
	local tracks = {}
	for name, tr in data.tracks do
		local cfs = table.create(#tr.p)
		for i, arr in tr.p do
			cfs[i] = Codec.arrayToCFrame(arr, 1)
		end
		local eases = table.create(#tr.e)
		for i, code in tr.e do
			local style, dir = string.match(code, "^(%a+):(%a+)$")
			eases[i] = { style = style or "L", dir = TWEEN_DIR[dir or "I"] or Enum.EasingDirection.In }
		end
		if #cfs > 0 then
			tracks[name] = { t = tr.t, cf = cfs, e = eases }
		end
	end
	return { length = tonumber(data.length) or 0, loop = data.loop == true, tracks = tracks }
end

local function ease(e, a: number): number
	local style = e and e.style or "L"
	if style == "L" then
		return a
	elseif style == "C" then
		return 0
	end
	local tweenStyle = TWEEN_STYLE[style]
	if not tweenStyle then
		return a
	end
	return TweenService:GetValue(a, tweenStyle, e.dir)
end

-- Writes joint transforms at time t into out[name]. loop overrides the clip's own Loop flag.
function Clip.sample(clip, t: number, out: { [string]: CFrame }, loop: boolean?)
	local len = clip.length
	local doLoop = if loop == nil then clip.loop else loop
	if len > 0 then
		if doLoop then
			t %= len
		else
			t = math.clamp(t, 0, len)
		end
	else
		t = 0
	end
	for name, tr in clip.tracks do
		local times, cfs = tr.t, tr.cf
		local n = #times
		if n == 1 or t <= times[1] then
			out[name] = cfs[1]
		elseif t >= times[n] then
			out[name] = cfs[n]
		else
			local lo, hi = 1, n
			while hi - lo > 1 do
				local mid = (lo + hi) // 2
				if times[mid] <= t then
					lo = mid
				else
					hi = mid
				end
			end
			local span = times[hi] - times[lo]
			local a = if span > 0 then (t - times[lo]) / span else 1
			out[name] = cfs[lo]:Lerp(cfs[hi], ease(tr.e[lo], a))
		end
	end
end

return Clip
