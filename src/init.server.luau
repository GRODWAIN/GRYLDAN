--!nonstrict
-- BBS Studio: machinima toolkit inspired by the BBS / Blockbuster mod for Minecraft.
-- Studio runs a copy of every plugin in the edit DataModel and in each playtest DataModel.
local RunService = game:GetService("RunService")

local PluginFolder = script:WaitForChild("Plugin")

local mode = if not RunService:IsRunning() then "edit" elseif RunService:IsClient() then "play" else nil

if mode then
	local ok, err = xpcall(function()
		if mode == "edit" then
			require(PluginFolder.App).start(plugin)
		else
			require(PluginFolder.PlayApp).start(plugin)
		end
	end, debug.traceback)
	if ok then
		if mode == "edit" then
			print("[BBS Studio] плагин загружен — кнопка «BBS Studio» на вкладке Plugins")
		end
	else
		warn("[BBS Studio] ошибка запуска плагина:\n" .. tostring(err))
	end
end
