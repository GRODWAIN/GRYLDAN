--!nonstrict
-- Human-readable names and layout of body parts (joint Part1 names) for R15 and R6.
local BodyParts = {}

BodyParts.ROOT = "__root"

local LABELS = {
	__root = "Всё тело",
	Head = "Голова",
	UpperTorso = "Грудь",
	LowerTorso = "Таз",
	Torso = "Торс",
	LeftUpperArm = "Л. плечо",
	RightUpperArm = "П. плечо",
	LeftLowerArm = "Л. предплечье",
	RightLowerArm = "П. предплечье",
	LeftHand = "Л. кисть",
	RightHand = "П. кисть",
	LeftUpperLeg = "Л. бедро",
	RightUpperLeg = "П. бедро",
	LeftLowerLeg = "Л. голень",
	RightLowerLeg = "П. голень",
	LeftFoot = "Л. стопа",
	RightFoot = "П. стопа",
	["Left Arm"] = "Л. рука",
	["Right Arm"] = "П. рука",
	["Left Leg"] = "Л. нога",
	["Right Leg"] = "П. нога",
}

local ROWS = {
	{ "__root" },
	{ "Head" },
	{ "UpperTorso" },
	{ "Torso" },
	{ "LowerTorso" },
	{ "LeftUpperArm", "RightUpperArm" },
	{ "LeftLowerArm", "RightLowerArm" },
	{ "LeftHand", "RightHand" },
	{ "Left Arm", "Right Arm" },
	{ "LeftUpperLeg", "RightUpperLeg" },
	{ "LeftLowerLeg", "RightLowerLeg" },
	{ "LeftFoot", "RightFoot" },
	{ "Left Leg", "Right Leg" },
}

local ORDER = {}
for i, row in ROWS do
	for j, name in row do
		ORDER[name] = i * 10 + j
	end
end

function BodyParts.label(name: string): string
	return LABELS[name] or name
end

function BodyParts.compare(a: string, b: string): boolean
	local oa, ob = ORDER[a] or 1000, ORDER[b] or 1000
	if oa == ob then
		return a < b
	end
	return oa < ob
end

-- Rows of part names present in `available` (set), known parts first, then any others.
function BodyParts.rows(available: { [string]: boolean }): { { string } }
	local out = {}
	local used = {}
	for _, row in ROWS do
		local present = {}
		for _, name in row do
			if available[name] then
				table.insert(present, name)
				used[name] = true
			end
		end
		if #present > 0 then
			table.insert(out, present)
		end
	end
	local extra = {}
	for name in available do
		if not used[name] then
			table.insert(extra, name)
		end
	end
	table.sort(extra)
	for i = 1, #extra, 2 do
		table.insert(out, { extra[i], extra[i + 1] })
	end
	return out
end

return BodyParts
