--!nonstrict
-- Tiny widget toolkit for the plugin windows.
local UI = {}

local C = {
	bg = Color3.fromRGB(30, 31, 36),
	panel = Color3.fromRGB(40, 42, 48),
	panel2 = Color3.fromRGB(54, 56, 64),
	input = Color3.fromRGB(22, 23, 27),
	text = Color3.fromRGB(232, 234, 240),
	dim = Color3.fromRGB(150, 154, 166),
	accent = Color3.fromRGB(70, 120, 235),
	good = Color3.fromRGB(60, 160, 100),
	danger = Color3.fromRGB(190, 65, 65),
	record = Color3.fromRGB(235, 60, 60),
	warn = Color3.fromRGB(240, 185, 60),
}
UI.C = C
UI.FONT = Enum.Font.BuilderSans
UI.FONT_BOLD = Enum.Font.BuilderSansBold

local layoutOrder = 0
local toggles = setmetatable({}, { __mode = "k" })

function UI.new(className: string, props: { [string]: any }?, children: { Instance }?)
	local inst = Instance.new(className)
	local parent = nil
	if inst:IsA("GuiObject") then
		layoutOrder += 1
		inst.LayoutOrder = layoutOrder
	end
	for k, v in (props or {}) :: { [string]: any } do
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	for _, child in (children or {}) :: { Instance } do
		child.Parent = inst
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function merge(base, extra)
	for k, v in extra or {} do
		base[k] = v
	end
	return base
end

function UI.corner(inst: Instance, radius: number?)
	UI.new("UICorner", { CornerRadius = UDim.new(0, radius or 4), Parent = inst })
	return inst
end

function UI.pad(inst: Instance, l: number, r: number, t: number, b: number)
	UI.new("UIPadding", {
		PaddingLeft = UDim.new(0, l),
		PaddingRight = UDim.new(0, r),
		PaddingTop = UDim.new(0, t),
		PaddingBottom = UDim.new(0, b),
		Parent = inst,
	})
	return inst
end

function UI.list(inst: Instance, horizontal: boolean?, spacing: number?)
	UI.new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, spacing or 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		Parent = inst,
	})
	return inst
end

function UI.flex(inst: Instance)
	UI.new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill, Parent = inst })
	return inst
end

function UI.label(text: string, props: { [string]: any }?): TextLabel
	return UI.new(
		"TextLabel",
		merge({
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = C.text,
			Font = UI.FONT,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(1, 0, 0, 20),
		}, props)
	)
end

function UI.paragraph(text: string, props: { [string]: any }?): TextLabel
	return UI.label(
		text,
		merge({
			TextWrapped = true,
			TextTruncate = Enum.TextTruncate.None,
			TextColor3 = C.dim,
			TextSize = 13,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
		}, props)
	)
end

function UI.recolor(button: GuiObject, color: Color3)
	button:SetAttribute("BaseColor", color)
	button.BackgroundColor3 = color
end

function UI.button(text: string, onClick: ((TextButton) -> ())?, props: { [string]: any }?): TextButton
	local b = UI.new(
		"TextButton",
		merge({
			Text = text,
			AutoButtonColor = false,
			BackgroundColor3 = C.panel2,
			TextColor3 = C.text,
			Font = UI.FONT,
			TextSize = 13,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 0, 0, 24),
			AutomaticSize = Enum.AutomaticSize.X,
		}, props)
	)
	UI.corner(b, 4)
	UI.pad(b, 8, 8, 0, 0)
	b:SetAttribute("BaseColor", b.BackgroundColor3)
	b.MouseEnter:Connect(function()
		local base = b:GetAttribute("BaseColor") or C.panel2
		b.BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.12)
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = b:GetAttribute("BaseColor") or C.panel2
	end)
	if onClick then
		b.Activated:Connect(function()
			onClick(b)
		end)
	end
	return b
end

function UI.textbox(text: any, onCommit: ((string, TextBox) -> ())?, props: { [string]: any }?): TextBox
	local tb = UI.new(
		"TextBox",
		merge({
			Text = tostring(text),
			ClearTextOnFocus = false,
			BackgroundColor3 = C.input,
			TextColor3 = C.text,
			PlaceholderColor3 = C.dim,
			Font = UI.FONT,
			TextSize = 13,
			BorderSizePixel = 0,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Size = UDim2.new(0, 60, 0, 24),
		}, props)
	)
	UI.corner(tb, 4)
	UI.pad(tb, 6, 6, 0, 0)
	if onCommit then
		tb.FocusLost:Connect(function()
			onCommit(tb.Text, tb)
		end)
	end
	return tb
end

local function paintToggle(b: TextButton)
	local info = toggles[b]
	b.Text = (if info.value then "✓ " else "") .. info.text
	UI.recolor(b, if info.value then C.accent else C.panel2)
end

function UI.toggle(text: string, value: boolean, onChange: (boolean) -> (), props: { [string]: any }?): TextButton
	local b = UI.button(text, nil, props)
	toggles[b] = { value = value, text = text }
	paintToggle(b)
	b.Activated:Connect(function()
		local info = toggles[b]
		info.value = not info.value
		paintToggle(b)
		onChange(info.value)
	end)
	return b
end

function UI.setToggle(b: TextButton, value: boolean)
	local info = toggles[b]
	if info and info.value ~= value then
		info.value = value
		paintToggle(b)
	end
end

-- options = { { value = any, label = string } }; click cycles to the next option.
function UI.cycle(options, current: any, onChange: (any) -> (), props: { [string]: any }?): TextButton
	local index = 1
	for i, opt in options do
		if opt.value == current then
			index = i
		end
	end
	local b
	b = UI.button(options[index].label, function()
		index = index % #options + 1
		b.Text = options[index].label
		onChange(options[index].value)
	end, props)
	return b
end

function UI.row(children: { Instance }, props: { [string]: any }?): Frame
	local row = UI.new(
		"Frame",
		merge({
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 26),
		}, props)
	)
	UI.list(row, true, 4)
	for _, child in children do
		child.Parent = row
	end
	return row
end

function UI.section(title: string?, parent: Instance): Frame
	local f = UI.new("Frame", {
		BackgroundColor3 = C.panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = parent,
	})
	UI.corner(f, 6)
	UI.pad(f, 8, 8, 8, 8)
	UI.list(f, false, 6)
	if title then
		UI.label(title, { Font = UI.FONT_BOLD, TextSize = 15, Parent = f })
	end
	return f
end

function UI.clear(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function UI.formatTime(t: number): string
	t = math.max(0, t)
	local m = math.floor(t / 60)
	return string.format("%d:%05.2f", m, t - m * 60)
end

function UI.formatNumber(n: number): string
	local s = string.format("%.2f", n)
	s = (string.gsub(s, "0+$", ""))
	s = (string.gsub(s, "%.$", ""))
	return s
end

function UI.parseNumber(text: string): number?
	local cleaned = string.gsub(text, ",", ".")
	return tonumber(cleaned)
end

function UI.createWidget(plugin: Plugin, id: string, info: DockWidgetPluginGuiInfo): DockWidgetPluginGui
	local ok, widget = pcall(function()
		return plugin:CreateDockWidgetPluginGuiAsync(id, info)
	end)
	if ok and widget then
		return widget
	end
	return plugin:CreateDockWidgetPluginGui(id, info)
end

return UI
