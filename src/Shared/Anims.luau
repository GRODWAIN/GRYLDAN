--!nonstrict
-- Animation sets of skins. Each skin may carry Configuration "BBS_Anims" (StringValue per state,
-- value = animation asset id). It is filled from the skin's Animate script when the skin is added
-- and can be edited in the plugin. Missing states fall back to Roblox's default animations.
local Anims = {}

Anims.FOLDER = "BBS_Anims"
Anims.STATES = { "idle", "walk", "run", "jump", "fall", "climb", "sit", "swim", "swimidle" }
Anims.LABELS = {
	idle = "Стоит",
	walk = "Шаг",
	run = "Бег",
	jump = "Прыжок",
	fall = "Падение",
	climb = "Лазание",
	sit = "Сидит",
	swim = "Плывёт",
	swimidle = "На воде",
}

-- From Roblox's default Animate scripts.
Anims.DEFAULTS = {
	R15 = {
		idle = "507766666",
		walk = "507777826",
		run = "507767714",
		jump = "507765000",
		fall = "507767968",
		climb = "507765644",
		sit = "507768133",
		swim = "507784897",
		swimidle = "507785072",
	},
	R6 = {
		idle = "180435571",
		walk = "180426354",
		run = "180426354",
		jump = "125750702",
		fall = "180436148",
		climb = "180436334",
		sit = "178130996",
	},
}

Anims.EMOTES = {
	R15 = {
		{ label = "Помахать", id = "507770239" },
		{ label = "Указать", id = "507770453" },
		{ label = "Танец 1", id = "507771019" },
		{ label = "Танец 2", id = "507776043" },
		{ label = "Танец 3", id = "507777268" },
		{ label = "Смех", id = "507770818" },
		{ label = "Радость", id = "507770677" },
	},
	R6 = {
		{ label = "Помахать", id = "128777973" },
		{ label = "Указать", id = "128853357" },
		{ label = "Танец 1", id = "182435998" },
		{ label = "Танец 2", id = "182436842" },
		{ label = "Танец 3", id = "182436935" },
		{ label = "Смех", id = "129423131" },
		{ label = "Радость", id = "129423030" },
	},
}

local FALLBACK = { run = "walk", swim = "walk", swimidle = "idle", climb = "walk", sit = "idle", fall = "jump" }

function Anims.rigType(model: Instance?): string?
	if not model then
		return nil
	end
	if model:FindFirstChild("UpperTorso") then
		return "R15"
	end
	if model:FindFirstChild("Torso") then
		return "R6"
	end
	return nil
end

local function digits(id: any): string?
	if type(id) ~= "string" then
		return nil
	end
	local d = string.match(id, "(%d+)%s*$") or string.match(id, "id=(%d+)")
	return if d and d ~= "0" then d else nil
end

-- Reads the state animations from a Roblox Animate script (StringValue per state with Animations).
function Anims.extractFromAnimate(model: Instance): { [string]: string }?
	local animate = model:FindFirstChild("Animate")
	if not animate then
		return nil
	end
	local set = {}
	local found = false
	for _, state in Anims.STATES do
		local holder = animate:FindFirstChild(state)
		if holder then
			local best, bestWeight = nil, -1
			for _, anim in holder:GetChildren() do
				if anim:IsA("Animation") then
					local w = anim:FindFirstChild("Weight")
					local weight = if w and w:IsA("NumberValue") then w.Value else 1
					local id = digits(anim.AnimationId)
					if id and weight > bestWeight then
						best, bestWeight = id, weight
					end
				end
			end
			if best then
				set[state] = best
				found = true
			end
		end
	end
	return if found then set else nil
end

function Anims.read(skin: Instance?): { [string]: string }
	local set = {}
	local folder = skin and skin:FindFirstChild(Anims.FOLDER)
	if folder then
		for _, sv in folder:GetChildren() do
			if sv:IsA("StringValue") then
				local id = digits(sv.Value)
				if id then
					set[sv.Name] = id
				end
			end
		end
	end
	return set
end

-- Replaces the custom set (nil or empty clears it, falling back to defaults).
function Anims.write(skin: Instance, set: { [string]: string }?)
	local folder = skin:FindFirstChild(Anims.FOLDER)
	if folder then
		folder:Destroy()
	end
	if not set or next(set) == nil then
		return
	end
	folder = Instance.new("Configuration")
	folder.Name = Anims.FOLDER
	for state, id in set do
		local sv = Instance.new("StringValue")
		sv.Name = state
		sv.Value = id
		sv.Parent = folder
	end
	folder.Parent = skin
end

function Anims.resolve(skin: Instance?, state: string): string?
	local custom = Anims.read(skin)
	local defaults = Anims.DEFAULTS[Anims.rigType(skin) or "R15"]
	local s = state
	for _ = 1, 4 do
		local id = custom[s] or defaults[s]
		if id then
			return id
		end
		s = FALLBACK[s]
		if not s then
			break
		end
	end
	return defaults.idle
end

return Anims
