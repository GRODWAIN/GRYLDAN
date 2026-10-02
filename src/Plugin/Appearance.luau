--!nonstrict
-- Avatar appearance: serialising the recorded player's HumanoidDescription and building skins.
local Players = game:GetService("Players")

local Appearance = {}

local NUMBER_PROPS = {
	"Face",
	"Head",
	"LeftArm",
	"LeftLeg",
	"RightArm",
	"RightLeg",
	"Torso",
	"Shirt",
	"Pants",
	"GraphicTShirt",
	"BodyTypeScale",
	"DepthScale",
	"HeadScale",
	"HeightScale",
	"ProportionScale",
	"WidthScale",
}
local STRING_PROPS = {
	"HatAccessory",
	"HairAccessory",
	"FaceAccessory",
	"NeckAccessory",
	"ShouldersAccessory",
	"FrontAccessory",
	"BackAccessory",
	"WaistAccessory",
}
local COLOR_PROPS = {
	"HeadColor",
	"LeftArmColor",
	"LeftLegColor",
	"RightArmColor",
	"RightLegColor",
	"TorsoColor",
}

function Appearance.serialize(desc: HumanoidDescription)
	local data = {}
	local d = desc :: any
	for _, prop in NUMBER_PROPS do
		pcall(function()
			data[prop] = d[prop]
		end)
	end
	for _, prop in STRING_PROPS do
		pcall(function()
			data[prop] = d[prop]
		end)
	end
	for _, prop in COLOR_PROPS do
		pcall(function()
			data[prop] = d[prop]:ToHex()
		end)
	end
	pcall(function()
		local list = {}
		for _, acc in desc:GetAccessories(true) do
			table.insert(list, {
				AssetId = acc.AssetId,
				AccessoryType = acc.AccessoryType.Name,
				IsLayered = acc.IsLayered,
				Order = acc.Order,
				Puffiness = acc.Puffiness,
			})
		end
		data._accessories = list
	end)
	return data
end

function Appearance.deserialize(data): HumanoidDescription
	local desc = Instance.new("HumanoidDescription")
	local d = desc :: any
	if type(data) ~= "table" then
		return desc
	end
	for _, prop in NUMBER_PROPS do
		if type(data[prop]) == "number" then
			pcall(function()
				d[prop] = data[prop]
			end)
		end
	end
	for _, prop in STRING_PROPS do
		if type(data[prop]) == "string" then
			pcall(function()
				d[prop] = data[prop]
			end)
		end
	end
	for _, prop in COLOR_PROPS do
		if type(data[prop]) == "string" then
			pcall(function()
				d[prop] = Color3.fromHex(data[prop])
			end)
		end
	end
	if type(data._accessories) == "table" then
		pcall(function()
			local list = {}
			for _, acc in data._accessories do
				local entry = table.clone(acc)
				entry.AccessoryType = Enum.AccessoryType[acc.AccessoryType]
				table.insert(list, entry)
			end
			desc:SetAccessories(list, true)
		end)
	end
	return desc
end

-- Calls the *Async API where it exists and falls back to the legacy name.
local function callPlayers(asyncName: string, legacyName: string, ...)
	local args = table.pack(...)
	local p = Players :: any
	local ok, result = pcall(function()
		return p[asyncName](p, table.unpack(args, 1, args.n))
	end)
	if ok then
		return result
	end
	local ok2, result2 = pcall(function()
		return p[legacyName](p, table.unpack(args, 1, args.n))
	end)
	if ok2 then
		return result2
	end
	error(result2 or result, 0)
end

local function rigType(rigName: string?): Enum.HumanoidRigType
	return if rigName == "R6" then Enum.HumanoidRigType.R6 else Enum.HumanoidRigType.R15
end

function Appearance.rigFromDescription(desc: HumanoidDescription, rigName: string?): Model
	return callPlayers("CreateHumanoidModelFromDescriptionAsync", "CreateHumanoidModelFromDescription", desc, rigType(rigName))
end

function Appearance.rigFromUserId(userId: number, rigName: string?): Model
	local desc = callPlayers("GetHumanoidDescriptionFromUserIdAsync", "GetHumanoidDescriptionFromUserId", userId)
	return Appearance.rigFromDescription(desc, rigName)
end

function Appearance.resolveUser(text: string): (number?, string?)
	text = string.match(text, "^%s*(.-)%s*$") or ""
	if text == "" then
		return nil, nil
	end
	local id = tonumber(text)
	if not id then
		local ok, result = pcall(function()
			return Players:GetUserIdFromNameAsync(text)
		end)
		id = if ok then result else nil
	end
	if not id then
		return nil, nil
	end
	local okName, name = pcall(function()
		return Players:GetNameFromUserIdAsync(id)
	end)
	return id, if okName then name else tostring(id)
end

-- Best-effort rig matching the recorded character: its description, then its user, then a default.
function Appearance.rigForRecording(rec): Model
	if rec.desc then
		local ok, model = pcall(function()
			return Appearance.rigFromDescription(Appearance.deserialize(rec.desc), rec.rig)
		end)
		if ok and model then
			return model
		end
	end
	if rec.userId and rec.userId > 0 then
		local ok, model = pcall(Appearance.rigFromUserId, rec.userId, rec.rig)
		if ok and model then
			return model
		end
	end
	return Appearance.rigFromDescription(Instance.new("HumanoidDescription"), rec.rig)
end

return Appearance
