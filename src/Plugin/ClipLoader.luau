--!nonstrict
-- Downloads an animation asset and bakes it into Clip data (plugin-only API).
local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Clip = require(script.Parent.Parent.Shared.Clip)

return function(id: string): string
	local kfs = (KeyframeSequenceProvider :: any):GetKeyframeSequenceAsync("rbxassetid://" .. id)
	if not kfs or not kfs:IsA("KeyframeSequence") then
		error("формат не поддерживается (" .. (if kfs then kfs.ClassName else "nil") .. ")", 0)
	end
	local clip = Clip.fromKeyframeSequence(kfs)
	kfs:Destroy()
	if next(clip.tracks) == nil then
		error("в анимации нет поз", 0)
	end
	return Clip.encode(clip)
end
