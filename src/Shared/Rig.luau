--!nonstrict
-- Applying recorded poses to arbitrary models ("skins"). Joints are matched by Part1 name,
-- so any rig with the same part names as the recorded character can play the recording.
local Rig = {}

local function insideAccessory(inst: Instance, model: Instance): boolean
	local p = inst.Parent
	while p and p ~= model do
		if p:IsA("Accoutrement") or p:IsA("Tool") then
			return true
		end
		p = p.Parent
	end
	return false
end

function Rig.getJoints(model: Instance): { [string]: Motor6D }
	local map = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Part1 and not insideAccessory(d, model) then
			map[d.Part1.Name] = d
		end
	end
	return map
end

function Rig.inspect(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local hrp = model:FindFirstChild("HumanoidRootPart")
	local root = if hrp and hrp:IsA("BasePart") then hrp else model.PrimaryPart
	return {
		root = root,
		humanoid = humanoid,
		-- humanoid rigs move by their root part; props are moved by pivot
		useRootPart = humanoid ~= nil and root ~= nil,
		joints = Rig.getJoints(model),
	}
end

function Rig.getRootCFrame(model: Model): CFrame
	local info = Rig.inspect(model)
	if info.useRootPart then
		return info.root.CFrame
	end
	return model:GetPivot()
end

-- Turns a cloned skin into a script-free puppet driven only by the playback.
function Rig.prepare(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("Animator") then
			d:Destroy()
		end
	end
	local info = Rig.inspect(model)
	if info.humanoid then
		pcall(function()
			info.humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			info.humanoid.BreakJointsOnDeath = false
			info.humanoid.RequiresNeck = false
		end)
	end
	if info.root then
		model.PrimaryPart = info.root
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.Anchored = if info.useRootPart then d == info.root else true
		end
	end
	return info
end

function Rig.apply(info, model: Model, parts: { string }, rootCf: CFrame, joints: { CFrame }?)
	if info.useRootPart then
		info.root.CFrame = rootCf
	else
		model:PivotTo(rootCf)
	end
	if joints then
		local map = info.joints
		for i, name in parts do
			local motor = map[name]
			local cf = joints[i]
			if motor and cf then
				motor.Transform = cf
			end
		end
	end
end

return Rig
