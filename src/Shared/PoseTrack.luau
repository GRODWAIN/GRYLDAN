--!nonstrict
-- User pose keyframes per body part, stored in actor StringValue "Pose".
-- Each key is an offset applied on top of the base motion: joint transform = base * offset.
-- Track "__root" offsets the whole body.
local HttpService = game:GetService("HttpService")

local Codec = require(script.Parent.Codec)
local Ease = require(script.Parent.Ease)

local PoseTrack = {}

PoseTrack.ROOT = "__root"

local cache = setmetatable({}, { __mode = "k" })

function PoseTrack.get(actor: Instance): { [string]: { { t: number, cf: CFrame, e: string } } }
	local sv = actor:FindFirstChild("Pose")
	if not sv or not sv:IsA("StringValue") then
		return {}
	end
	local cached = cache[actor]
	if cached and cached.value == sv.Value then
		return cached.tracks
	end
	local tracks = {}
	local ok, data = pcall(function()
		return HttpService:JSONDecode(sv.Value)
	end)
	if ok and type(data) == "table" then
		for name, keys in data do
			local list = {}
			for _, k in keys do
				table.insert(list, {
					t = tonumber(k.t) or 0,
					cf = Codec.arrayToCFrame(k.p or {}, 1),
					e = if Ease.valid(k.e) then k.e else "smooth",
				})
			end
			table.sort(list, function(a, b)
				return a.t < b.t
			end)
			if #list > 0 then
				tracks[name] = list
			end
		end
	end
	cache[actor] = { value = sv.Value, tracks = tracks }
	return tracks
end

function PoseTrack.copy(tracks)
	local out = {}
	for name, keys in tracks do
		local list = table.create(#keys)
		for i, k in keys do
			list[i] = table.clone(k)
		end
		out[name] = list
	end
	return out
end

function PoseTrack.set(actor: Instance, tracks)
	local data = {}
	for name, keys in tracks do
		if #keys > 0 then
			table.sort(keys, function(a, b)
				return a.t < b.t
			end)
			local list = table.create(#keys)
			for i, k in keys do
				local p = Codec.cframeToArray(k.cf)
				for j, v in p do
					p[j] = math.floor(v * 10000 + 0.5) / 10000
				end
				list[i] = { t = math.floor(k.t * 1000 + 0.5) / 1000, p = p, e = k.e }
			end
			data[name] = list
		end
	end
	local sv = actor:FindFirstChild("Pose")
	if not sv then
		sv = Instance.new("StringValue")
		sv.Name = "Pose"
		sv.Parent = actor
	end
	sv.Value = HttpService:JSONEncode(data)
end

function PoseTrack.sample(keys, t: number): CFrame
	local n = #keys
	if n == 0 then
		return CFrame.identity
	end
	if n == 1 or t <= keys[1].t then
		return keys[1].cf
	end
	if t >= keys[n].t then
		return keys[n].cf
	end
	local i = 1
	while i < n - 1 and keys[i + 1].t <= t do
		i += 1
	end
	local k1, k2 = keys[i], keys[i + 1]
	local span = k2.t - k1.t
	local a = if span > 0 then (t - k1.t) / span else 1
	return k1.cf:Lerp(k2.cf, Ease.apply(k1.e, a))
end

-- Index of the key within eps of t, if any.
function PoseTrack.keyAt(keys, t: number, eps: number?): number?
	for i, k in keys or {} do
		if math.abs(k.t - t) <= (eps or 0.02) then
			return i
		end
	end
	return nil
end

return PoseTrack
