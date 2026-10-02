--!nonstrict
-- BBS Studio: machinima toolkit inspired by the BBS / Blockbuster mod for Minecraft.
-- Studio runs a copy of every plugin in the edit DataModel and in each playtest DataModel.
local RunService = game:GetService("RunService")

local PluginFolder = script:WaitForChild("Plugin")

if RunService:IsRunning() then
	if RunService:IsClient() then
		require(PluginFolder.PlayApp).start(plugin)
	end
else
	require(PluginFolder.App).start(plugin)
end
