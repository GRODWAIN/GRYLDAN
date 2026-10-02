--!nonstrict
-- Compact text format for recordings: JSON header, "\n", then frames.
-- Frame = root CFrame + Motor6D.Transform per part, 6 numbers each (pos + XYZ euler).
local HttpService = game:GetService("HttpService")

local Codec = {}

Codec.VERSION = 2
Codec.CHUNK_SIZE = 100000

-- Headers are made pure ASCII ("~" marker + %XX escapes) so plugin settings and messages
-- never have to carry non-ASCII text such as Cyrillic names.
local function asciiEscape(s: string): string
	return (string.gsub(s, "[%%\128-\255]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function asciiUnescape(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

local function fmt(n: number, pattern: string): string
	if n ~= n then
		return "0"
	end
	local s = string.format(pattern, n)
	if string.find(s, ".", 1, true) then
		s = (string.gsub(s, "0+$", ""))
		s = (string.gsub(s, "%.$", ""))
	end
	if s == "-0" or s == "" then
		return "0"
	end
	return s
end

local function pushCFrame(out: { string }, cf: CFrame)
	local p = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	table.insert(out, fmt(p.X, "%.3f"))
	table.insert(out, fmt(p.Y, "%.3f"))
	table.insert(out, fmt(p.Z, "%.3f"))
	table.insert(out, fmt(rx, "%.4f"))
	table.insert(out, fmt(ry, "%.4f"))
	table.insert(out, fmt(rz, "%.4f"))
end

function Codec.cframeToArray(cf: CFrame): { number }
	local p = cf.Position
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	return { p.X, p.Y, p.Z, rx, ry, rz }
end

function Codec.arrayToCFrame(a: { number }, i: number?): CFrame
	local b = i or 1
	return CFrame.new(a[b] or 0, a[b + 1] or 0, a[b + 2] or 0)
		* CFrame.fromEulerAnglesXYZ(a[b + 3] or 0, a[b + 4] or 0, a[b + 5] or 0)
end

function Codec.newId(): string
	local guid = string.gsub(HttpService:GenerateGUID(false), "-", "")
	return string.lower(string.sub(guid, 1, 12))
end

function Codec.computeLength(rec)
	rec.length = math.max(0, (#rec.frames - 1) / rec.fps)
	return rec.length
end

function Codec.encodeRecording(rec): string
	local header = {
		v = Codec.VERSION,
		id = rec.id,
		name = rec.name,
		fps = rec.fps,
		rig = rec.rig,
		userId = rec.userId,
		desc = rec.desc,
		parts = rec.parts,
		offset = rec.offset,
		target = rec.target,
	}
	local out = table.create(#rec.frames)
	local nums = {}
	for i, frame in rec.frames do
		table.clear(nums)
		pushCFrame(nums, frame.root)
		for j = 1, #rec.parts do
			pushCFrame(nums, frame.joints[j] or CFrame.identity)
		end
		if frame.s then
			table.insert(nums, tostring(frame.s))
		end
		out[i] = table.concat(nums, ",")
	end
	return "~" .. asciiEscape(HttpService:JSONEncode(header)) .. "\n" .. table.concat(out, ";")
end

function Codec.decodeRecording(str: string)
	if type(str) ~= "string" or str == "" then
		return nil
	end
	local nl = string.find(str, "\n", 1, true)
	local headerStr = if nl then string.sub(str, 1, nl - 1) else str
	local body = if nl then string.sub(str, nl + 1) else ""
	if string.sub(headerStr, 1, 1) == "~" then
		headerStr = asciiUnescape(string.sub(headerStr, 2))
	end
	local ok, header = pcall(function()
		return HttpService:JSONDecode(headerStr)
	end)
	if not ok or type(header) ~= "table" then
		return nil
	end
	local parts = if type(header.parts) == "table" then header.parts else {}
	local frames = {}
	local nums = {}
	for frameStr in string.gmatch(body, "[^;]+") do
		table.clear(nums)
		local k = 0
		for numStr in string.gmatch(frameStr, "[^,]+") do
			k += 1
			nums[k] = tonumber(numStr) or 0
		end
		if k >= 6 then
			local joints = table.create(#parts)
			for j = 1, #parts do
				local base = 6 * j + 1
				joints[j] = if base + 5 <= k then Codec.arrayToCFrame(nums, base) else CFrame.identity
			end
			-- optional trailing number: recorded Humanoid state code (see Recorder)
			local s = if k == 6 + 6 * #parts + 1 then nums[k] else nil
			table.insert(frames, { root = Codec.arrayToCFrame(nums, 1), joints = joints, s = s })
		end
	end
	local rec = {
		id = header.id or Codec.newId(),
		name = header.name or "Запись",
		fps = math.max(1, tonumber(header.fps) or 30),
		rig = header.rig or "R15",
		userId = tonumber(header.userId) or 0,
		desc = header.desc,
		parts = parts,
		offset = tonumber(header.offset) or 0,
		target = header.target,
		frames = frames,
	}
	Codec.computeLength(rec)
	return rec
end

-- Returns interpolated root CFrame and joint transforms at time t (seconds from clip start).
function Codec.sample(rec, t: number): (CFrame?, { CFrame }?)
	local frames = rec.frames
	local n = #frames
	if n == 0 then
		return nil, nil
	end
	if n == 1 then
		return frames[1].root, frames[1].joints
	end
	local f = math.clamp(t, 0, rec.length) * rec.fps
	local i = math.floor(f)
	local a = f - i
	local f1 = frames[math.min(i + 1, n)]
	local f2 = frames[math.min(i + 2, n)]
	if a < 1e-4 or f1 == f2 then
		return f1.root, f1.joints
	end
	local joints = table.create(#f1.joints)
	for j, cf in f1.joints do
		joints[j] = cf:Lerp(f2.joints[j] or cf, a)
	end
	return f1.root:Lerp(f2.root, a), joints
end

-- Copy of rec keeping only frames between t0 and t1 (seconds).
function Codec.trim(rec, t0: number, t1: number)
	local n = #rec.frames
	local first = math.clamp(math.floor(t0 * rec.fps + 0.5) + 1, 1, n)
	local last = math.clamp(math.floor(t1 * rec.fps + 0.5) + 1, first, n)
	local copy = table.clone(rec)
	copy.frames = table.move(rec.frames, first, last, 1, {})
	Codec.computeLength(copy)
	return copy
end

function Codec.writeChunks(folder: Instance, str: string)
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			child:Destroy()
		end
	end
	local size = Codec.CHUNK_SIZE
	local index = 0
	local pos = 1
	local len = #str
	repeat
		local stop = math.min(pos + size - 1, len)
		-- never split a multi-byte UTF-8 character between chunks
		while stop < len and stop > pos do
			local nextByte = string.byte(str, stop + 1)
			if nextByte >= 0x80 and nextByte < 0xC0 then
				stop -= 1
			else
				break
			end
		end
		index += 1
		local value = Instance.new("StringValue")
		value.Name = tostring(index)
		value.Value = string.sub(str, pos, stop)
		value.Parent = folder
		pos = stop + 1
	until pos > len
end

function Codec.readChunks(folder: Instance): string
	local list = {}
	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			table.insert(list, child)
		end
	end
	table.sort(list, function(a, b)
		return (tonumber(a.Name) or 0) < (tonumber(b.Name) or 0)
	end)
	local pieces = table.create(#list)
	for i, child in list do
		pieces[i] = child.Value
	end
	return table.concat(pieces)
end

return Codec
