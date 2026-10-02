--!nonstrict
-- Easing shared by camera keys and pose keys. The ease of a key shapes the segment that starts at it.
local Ease = {}

Ease.LIST = { "linear", "smooth", "in", "out", "cut" }
Ease.LABELS = {
	linear = "Ровно",
	smooth = "Плавно",
	["in"] = "Разгон",
	out = "Торможение",
	cut = "Стоп-кадр",
}

local FN = {
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
	-- hold the value until the next key, then jump
	cut = function(_a)
		return 0
	end,
}

function Ease.valid(name: any): boolean
	return type(name) == "string" and FN[name] ~= nil
end

function Ease.apply(name: string?, a: number): number
	return (FN[name or "linear"] or FN.linear)(a)
end

return Ease
