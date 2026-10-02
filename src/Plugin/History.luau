--!nonstrict
-- Wraps scene edits in ChangeHistoryService recordings so Ctrl+Z works.
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local History = {}

function History.record(name: string, fn: () -> ()): boolean
	local id = nil
	pcall(function()
		id = ChangeHistoryService:TryBeginRecording(name, name)
	end)
	local ok, err = pcall(fn)
	if id then
		ChangeHistoryService:FinishRecording(
			id,
			if ok then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[BBS Studio] " .. name .. ": " .. tostring(err))
	end
	return ok
end

return History
