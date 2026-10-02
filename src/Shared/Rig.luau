--!nonstrict
-- Puppets: every part is anchored, joints are disabled and part CFrames are computed here
-- (forward kinematics over the joint tree). Motor6D.Transform is only applied by the physics
-- step, which never runs in edit mode, so poses must not rely on the engine solving joints.
local Workspace = game:GetService("Workspace")

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

-- Animated joints: classic Motor6D, and AnimationConstraint which replaces it in R15 avatars
-- since the Avatar Joint Upgrade. Both expose Transform with the same meaning.
function Rig.isMotor(j: Instance): boolean
	return j:IsA("Motor6D") or j:IsA("AnimationConstraint")
end

-- Part0, Part1, C0, C1 of an animated joint.
function Rig.motorInfo(j: Instance): (BasePart?, BasePart?, CFrame?, CFrame?)
	if j:IsA("Motor6D") then
		return j.Part0, j.Part1, j.C0, j.C1
	elseif j:IsA("AnimationConstraint") then
		local a0, a1 = j.Attachment0, j.Attachment1
		local p0 = a0 and a0.Parent
		local p1 = a1 and a1.Parent
		if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
			return p0, p1, a0.CFrame, a1.CFrame
		end
	end
	return nil, nil, nil, nil
end

-- Body joints used for recording, keyed by Part1 name.
function Rig.getJoints(model: Instance): { [string]: Instance }
	local map = {}
	for _, d in model:GetDescendants() do
		if Rig.isMotor(d) and not insideAccessory(d, model) then
			local _, p1 = Rig.motorInfo(d)
			local existing = p1 and map[p1.Name]
			-- an AnimationConstraint is the live joint when both kinds are present
			if p1 and not (existing and existing:IsA("AnimationConstraint")) then
				map[p1.Name] = d
			end
		end
	end
	return map
end

function Rig.findRoot(model: Model): BasePart?
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

function Rig.getRootCFrame(model: Model): CFrame
	local root = Rig.findRoot(model)
	return if root then root.CFrame else model:GetPivot()
end

-- Removes scripts so stored skins and puppets never run code (and stay replicable in Team Create).
function Rig.sanitize(model: Instance)
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
end

local function jointParts(j: Instance): (BasePart?, BasePart?)
	local p0, p1
	if j:IsA("AnimationConstraint") then
		p0, p1 = Rig.motorInfo(j)
	elseif j:IsA("JointInstance") or j:IsA("WeldConstraint") then
		p0, p1 = (j :: any).Part0, (j :: any).Part1
	elseif j:IsA("RigidConstraint") then
		local a0, a1 = j.Attachment0, j.Attachment1
		p0 = a0 and a0.Parent
		p1 = a1 and a1.Parent
	end
	if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart") then
		return p0, p1
	end
	return nil, nil
end

-- Offset of `child` relative to `parent` for a rigid joint, from the joint's own data when possible.
local function rigidOffset(j: Instance, parent: BasePart, child: BasePart): CFrame
	if j:IsA("JointInstance") then
		local c0, c1 = (j :: any).C0, (j :: any).C1
		if (j :: any).Part0 == parent then
			return c0 * c1:Inverse()
		end
		return c1 * c0:Inverse()
	elseif j:IsA("RigidConstraint") then
		local a0, a1 = j.Attachment0, j.Attachment1
		if a0.Parent == parent then
			return a0.CFrame * a1.CFrame:Inverse()
		end
		return a1.CFrame * a0.CFrame:Inverse()
	end
	return parent.CFrame:ToObjectSpace(child.CFrame)
end

-- Turns a cloned skin into a puppet and returns its kinematic description.
function Rig.prepare(model: Model)
	Rig.sanitize(model)
	for _, d in model:GetDescendants() do
		if d:IsA("Animator") then
			d:Destroy()
		end
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		pcall(function()
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			humanoid.BreakJointsOnDeath = false
			humanoid.RequiresNeck = false
			humanoid.EvaluateStateMachine = false
		end)
	end
	local root = Rig.findRoot(model)
	if not root then
		return nil
	end
	model.PrimaryPart = root

	local parts = {}
	local inModel = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			inModel[d] = true
		end
	end

	local edges = {}
	local joints = {}
	local disable = {}
	for _, d in model:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("WeldConstraint") then
			table.insert(disable, d)
		end
		local p0, p1 = jointParts(d)
		if p0 and inModel[p0] and inModel[p1] then
			table.insert(joints, d)
			edges[p0] = edges[p0] or {}
			edges[p1] = edges[p1] or {}
			-- animated joints first, so a part reachable both ways is driven by its animation
			local motor = Rig.isMotor(d)
			table.insert(edges[p0], if motor then 1 else #edges[p0] + 1, { other = p1, joint = d })
			table.insert(edges[p1], if motor then 1 else #edges[p1] + 1, { other = p0, joint = d })
		end
	end

	-- breadth-first from the root so every parent is solved before its children
	local nodes = {}
	local visited = { [root] = true }
	local queue = { root }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		for _, edge in edges[current] or {} do
			local other, j = edge.other, edge.joint
			if not visited[other] then
				visited[other] = true
				table.insert(queue, other)
				local node = { part = other, parent = current }
				if Rig.isMotor(j) and not insideAccessory(j, model) then
					local p0, p1, c0, c1 = Rig.motorInfo(j)
					node.motor = true
					node.name = (p1 :: BasePart).Name
					node.invert = p0 ~= current
					node.c0 = c0
					node.c1 = c1
				else
					node.offset = rigidOffset(j, current, other)
				end
				table.insert(nodes, node)
			end
		end
	end
	for _, part in parts do
		if not visited[part] then
			table.insert(nodes, { part = part, parent = root, offset = root.CFrame:ToObjectSpace(part.CFrame) })
		end
	end

	for _, j in disable do
		pcall(function()
			(j :: any).Enabled = false
		end)
	end
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
	end

	local partList = { root }
	local byName = {}
	for i, node in nodes do
		partList[i + 1] = node.part
		if node.motor and not byName[node.name] then
			byName[node.name] = node
		end
	end
	return {
		root = root,
		humanoid = humanoid,
		nodes = nodes,
		byName = byName,
		partList = partList,
		cframes = table.create(#partList),
		solved = {},
	}
end

-- pose: joint transform per Part1 name; joints without an entry keep their rest pose.
function Rig.applyPose(info, rootCf: CFrame, pose: { [string]: CFrame }?)
	local solved = info.solved
	local cframes = info.cframes
	solved[info.root] = rootCf
	cframes[1] = rootCf
	for i, node in info.nodes do
		local parentCf = solved[node.parent] or rootCf
		local cf
		if node.motor then
			local t = (pose and pose[node.name]) or CFrame.identity
			if node.invert then
				cf = parentCf * node.c1 * t:Inverse() * node.c0:Inverse()
			else
				cf = parentCf * node.c0 * t * node.c1:Inverse()
			end
		else
			cf = parentCf * node.offset
		end
		solved[node.part] = cf
		cframes[i + 1] = cf
	end
	Workspace:BulkMoveTo(info.partList, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return Rig
