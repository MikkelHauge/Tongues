-- Tongues - the icon, the options window and the blocked words window
-- (Core.lua at the top explains how the file header and the shared "ns"
-- table work; this file adds the visible bits on top of it.)
local addonName, ns = ...

-- Amber accent for the section headings in the windows, the same as Ammonia.
local ACCENT = { 1.0, 0.72, 0.25 }

-- The raid markers as inline textures, for the tooltips on the two marker
-- rows: the point of the hover is to show what gets filtered. Width and
-- height are both given - the client does not size an inline texture from
-- one number alone.
local RAID_MARKER_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local function RaidMarkerIcon(index)
	return "|T"..RAID_MARKER_TEXTURE..index..":18:18|t"
end

-- The Curse of Tongues icon - an old friend for a language filter.
local ICON_PATH = "Interface\\Icons\\Spell_Shadow_CurseOfTounges"

-- File-wide handles, so the helper functions and the slash commands can
-- reach the pieces that are created further down.
local optionsFrame
local wordListFrame
local expansionFrame
local iconButton
local iconTexture
local iconRing
local scrollHost      -- the options window's viewport; clips whatever scrolls
local scrollContent   -- the tall frame inside it that actually moves
local scrollBar       -- the little bar on the right
local wordEditBox     -- the "Add a word" box, re-synced on every open
local expansionKeyBox   -- the "short form" box in the options window
local expansionValueBox -- the "what to send instead" box
local refreshers = {}
local counterLines = {} -- one "blocked so far" line per script, plus the word list

-- Reads the version straight from Tongues.toc for the window title.
local function GetAddonVersion()
	local getMetadata = GetAddOnMetadata
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		getMetadata = C_AddOns.GetAddOnMetadata
	end
	if getMetadata then
		local ok, version = pcall(getMetadata, addonName, "Version")
		if ok and version then
			return version
		end
	end
	return "?"
end

-- True only on the modern (Retail) client, where Communities exist. The C_Club
-- API is what the Communities feature itself is built on and is absent from
-- Forever and the Classic clients; the WOW_PROJECT check is a second guard
-- for clients that ship a stub. nil == nil must not read as "Retail", hence
-- the explicit type checks.
local function IsRetailClient()
	if not C_Club then
		return false
	end
	if type(WOW_PROJECT_ID) == "number" and type(WOW_PROJECT_MAINLINE) == "number" then
		return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
	end
	return true
end

-- How often one short form has fired, and the sum across the whole list.
-- Counts are keyed by the lowered short form, like the block list's tallies.
local function ExpansionUsage(rule)
	if not rule or not ns.db or not ns.db.expansionCounts then
		return 0
	end
	return ns.db.expansionCounts[string.lower(rule.key)] or 0
end

local function ExpansionUsageTotal()
	local total = 0
	local counts = (ns.db and ns.db.expansionCounts) or {}
	local rules = (ns.db and ns.db.expansions and ns.db.expansions.rules) or {}
	for index = 1, #rules do
		total = total + (counts[string.lower(rules[index].key)] or 0)
	end
	return total
end

-- The total sits beside the "Text expansions" heading in the options window.
local expansionUsageNote

local function UpdateExpansionUsageTotal()
	if not expansionUsageNote then
		return
	end
	local total = ExpansionUsageTotal()
	if total == 1 then
		expansionUsageNote:SetText("1 use")
	else
		expansionUsageNote:SetText(ns.FormatCount(total).." uses")
	end
end

-- Every setting control registers a small "read the saved value and show
-- it" function here; this is what re-syncs the whole window in one go.
local function RefreshAll()
	for index = 1, #refreshers do
		refreshers[index]()
	end
end
ns.RefreshOptions = RefreshAll

-- "You have blocked 12 messages in Russian." - singular on exactly one.
local function BlockedLine(count, whereText)
	local plural = "s"
	if count == 1 then
		plural = ""
	end
	return "You have blocked "..ns.FormatCount(count).." message"..plural.." "..whereText.."."
end

-- Re-fills every counter line - and the grand total beside the Reset
-- button - from the saved counters. Core.lua calls this right after it
-- counts a blocked message, so the window stays live while messages are
-- being hidden.
--
-- A hidden window is skipped on purpose: its text cannot be seen, and
-- rebuilding ten font strings for every blocked line of a spam wave is
-- wasted work. Showing the window refreshes it anyway (see the OnShow
-- handler in CreateOptionsFrame).
function ns.RefreshCounters()
	if not optionsFrame or not optionsFrame:IsShown() then
		return
	end
	for index = 1, #ns.LANGUAGES do
		local language = ns.LANGUAGES[index]
		local line = counterLines[language.key]
		if line then
			line:SetText(BlockedLine(ns.db.counters[language.key] or 0, "in "..language.counter))
		end
	end
	if counterLines.words then
		counterLines.words:SetText(BlockedLine(ns.db.counters.words or 0, "from your word list"))
	end
	if counterLines.markers then
		counterLines.markers:SetText(BlockedLine(ns.db.counters.markers or 0, "with raid markers"))
	end
	if counterLines.unreadable then
		counterLines.unreadable:SetText(BlockedLine(ns.db.counters.unreadable or 0, "that the font could not draw"))
	end
	if counterLines.total then
		counterLines.total:SetText("Total: "..ns.FormatCount(ns.GetTotalBlocked()))
	end
end
table.insert(refreshers, ns.RefreshCounters)

-------------------------------------------------------------------------------
-- Icon (rides the minimap edge, toggled with a right click)
-------------------------------------------------------------------------------

-- The icon rides the minimap's outer edge, the way most minimap buttons do.
-- Only the angle around the circle is saved - one number, with nothing about
-- the screen or the minimap's position in it - so it comes back exactly
-- where it was left after a reload. The leeway keeps the icon clear of the
-- minimap's own border art instead of half-buried under it.
local ICON_LEEWAY = 10

-- How far from the middle of the minimap the icon's middle belongs. Worked
-- out whenever it is used, so a resized or scaled minimap still gets a ring
-- that hugs its edge. 140 is only the fallback for a client that has not
-- laid the minimap out yet.
local function IconRingRadius()
	local width = Minimap:GetWidth()
	if not width or width <= 0 then
		width = 140
	end
	return width / 2 + ICON_LEEWAY
end

-- Puts the icon where the saved angle says it belongs.
local function ApplyIconPosition()
	if not iconButton then
		return
	end
	local angle = math.rad(ns.db.icon.angle or 140)
	local radius = IconRingRadius()
	iconButton:ClearAllPoints()
	iconButton:SetParent(Minimap)
	iconButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end
-- Shared, so Core.lua can put the icon back once the minimap has its real
-- size (the first apply can run before the layout settles).
ns.ApplyIconPosition = ApplyIconPosition

-- Back to the default spot around the minimap (the window's reset button
-- and /tongues reset both call this).
function ns.ResetIconPosition()
	ns.db.icon.angle = 120
	ApplyIconPosition()
end

-- Shows or hides the icon. While filtering is off the ring drains from
-- gold to silver, so the state shows at a glance - the grey icon alone
-- cannot show it.
function ns.UpdateIconState()
	if not iconButton then
		return
	end
	iconButton:SetShown(ns.db.icon.shown and true or false)
	if iconTexture then
		iconTexture:SetDesaturated(not ns.db.enabled)
	end
	if iconRing then
		iconRing:SetDesaturated(not ns.db.enabled)
	end
end

-- Opens the options window, or closes it when it is already open.
function ns.ToggleOptions()
	if not optionsFrame then
		return
	end
	if optionsFrame:IsShown() then
		optionsFrame:Hide()
	else
		ns.PlayUISound("IG_MAINMENU_OPEN")
		RefreshAll()
		optionsFrame:Show()
	end
end

-- Builds the little button that floats near the minimap.
local function CreateIconButton()
	-- Parented to the minimap like a normal minimap button.
	local button = CreateFrame("Button", "TonguesIcon", Minimap)
	iconButton = button
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetMovable(true)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	-- The minimap-button look: decorative border, dark disc, icon on top.
	-- The border ring is kept as a handle: gold while filtering is on,
	-- silver while it is off.
	-- The classic minimap-button geometry, the same numbers LibDBIcon uses:
	-- the tracking border's ring sits in the upper-left of its 53 pixel
	-- texture, so the disc and the icon are offset down-right to line up with
	-- it. Centring them on the button instead left the icon off-centre in
	-- the ring and its square corners showing outside the circle.
	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetSize(53, 53)
	overlay:SetPoint("TOPLEFT", 0, 0)
	iconRing = overlay

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	iconTexture = button:CreateTexture(nil, "ARTWORK")
	iconTexture:SetTexture(ICON_PATH)
	iconTexture:SetSize(17, 17)
	iconTexture:SetPoint("TOPLEFT", 7, -6)
	iconTexture:SetTexCoord(0.05, 0.95, 0.05, 0.95)

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- Dragging: the icon slides around the minimap's edge (unless locked).
	-- The cursor's direction from the middle of the minimap is the angle; the
	-- distance is always the ring, so the icon cannot wander off the minimap
	-- or off the screen, and one saved number brings it back after a reload.
	--
	-- Every press notes where it began and clears the "actually moved"
	-- flag: clients also deliver OnClick when a drag is released, and
	-- without the flag every move would end by opening the options window.
	-- The flag is only set once the cursor has travelled a few pixels, so
	-- a slightly shaky click still counts as a click.
	button:SetScript("OnMouseDown", function(self)
		local x, y = GetCursorPosition()
		self.pressX, self.pressY = x, y
		self.dragMoved = nil
	end)
	button:SetScript("OnDragStart", function(self)
		if ns.db.icon.locked then
			return
		end
		self:SetScript("OnUpdate", function()
			local x, y = GetCursorPosition()
			if not x then
				return
			end
			if self.pressX and math.abs(x - self.pressX) + math.abs(y - self.pressY) > 8 then
				self.dragMoved = true
			end
			-- Both the cursor and the minimap's middle are read in the
			-- minimap's own units, which is what its anchors use too.
			local scale = Minimap:GetEffectiveScale() or 1
			x, y = x / scale, y / scale
			local centerX, centerY = Minimap:GetCenter()
			if not centerX then
				return
			end
			local angle = math.deg(math.atan2(y - centerY, x - centerX))
			ns.db.icon.angle = angle
			local radius = IconRingRadius()
			self:ClearAllPoints()
			self:SetPoint("CENTER", Minimap, "CENTER",
				math.cos(math.rad(angle)) * radius, math.sin(math.rad(angle)) * radius)
		end)
	end)
	-- Dropping it: stop following the cursor; the saved angle stays put.
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
	-- Right-click flips filtering on or off; left-click opens the window.
	-- A release that ended a real drag is swallowed (see above).
	button:SetScript("OnClick", function(self, mouseButton)
		if self.dragMoved then
			return
		end
		if mouseButton == "RightButton" then
			ns.SetEnabled(not ns.db.enabled)
		else
			ns.ToggleOptions()
		end
	end)
	-- Tooltip: quick state readout plus the two click hints.
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Tongues")
		if ns.db.enabled then
			GameTooltip:AddLine("Filtering is on.", 1, 1, 1)
		else
			GameTooltip:AddLine("Filtering is off.", 1, 1, 1)
		end
		GameTooltip:AddLine("Left-click: open the options.", 1, 1, 1)
		GameTooltip:AddLine("Right-click: "..(ns.db.enabled and "turn filtering off." or "turn filtering on."), 1, 1, 1)
		if ns.db.icon.locked then
			GameTooltip:AddLine("Position locked.", 1, 1, 1)
		else
			GameTooltip:AddLine("Drag it around the minimap to move it.", 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	ApplyIconPosition()
end

-------------------------------------------------------------------------------
-- Options window
-------------------------------------------------------------------------------

-- The settings list is taller than the window, so every row is drawn into
-- one tall frame (scrollContent) that lives inside a scroll frame
-- (scrollHost). The scroll frame clips the content to the window bounds, and
-- the content is then moved up and down by hand - the same way Ammonia does
-- it. Bigger values move the content further up, which is what reveals the
-- rows below.

-- Moves the content so `value` (0 = top of the list, 1000 = bottom) points
-- into the list.
local function ApplyScroll(value)
	if not scrollHost or not scrollContent then
		return
	end
	if not value or value < 0 then
		value = 0
	elseif value > 1000 then
		value = 1000
	end
	local viewHeight = scrollHost:GetHeight() or 0
	local contentHeight = scrollContent:GetHeight() or 0
	local maxOffset = contentHeight - viewHeight
	local offset = 0
	if maxOffset > 0 then
		offset = math.floor(maxOffset / 1000 * value + 0.5)
	end
	scrollContent:ClearAllPoints()
	scrollContent:SetPoint("TOPLEFT", 0, offset)
	scrollContent:SetPoint("TOPRIGHT", 0, offset)
end

-- One mouse wheel notch moves about 100 pixels; the 0-1000 bar value is
-- worked out from how much content actually overflows.
local function ScrollWheel(delta)
	if not scrollHost or not scrollContent or not scrollBar or not scrollBar:IsShown() then
		return
	end
	local maxOffset = (scrollContent:GetHeight() or 0) - (scrollHost:GetHeight() or 0)
	if maxOffset <= 0 then
		return
	end
	local value = scrollBar:GetValue() - delta * (100 / maxOffset) * 1000
	if value < 0 then
		value = 0
	elseif value > 1000 then
		value = 1000
	end
	scrollBar:SetValue(value)
end

-- Shows the scroll bar only when the rows are taller than the window can
-- show, and parks the list at the top when everything fits.
local function UpdateScrollBar()
	if not scrollHost or not scrollContent or not scrollBar then
		return
	end
	local overflow = (scrollContent:GetHeight() or 0) > (scrollHost:GetHeight() or 0) + 2
	scrollBar:SetShown(overflow)
	if not overflow then
		scrollBar:SetValue(0)
	end
end

-- Builds the whole window, once, on the first login.
local function CreateOptionsFrame()
	local frame = CreateFrame("Frame", "TonguesFrame", UIParent, "BasicFrameTemplateWithInset")
	optionsFrame = frame
	frame:SetSize(480, math.min(700, math.max(420, (UIParent:GetHeight() or 768) - 80)))
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	if frame.TitleText then
		frame.TitleText:SetText("Tongues "..GetAddonVersion())
	end
	-- The stock title band is 18 pixels tall, shorter than the 22 pixel
	-- icon, so the icon used to hang over the inset and look like it was
	-- falling out of the bar. Give the band the icon's height, and put the
	-- icon on the overlay layer so the frame's own border art cannot cover
	-- it.
	if frame.TitleBg then
		frame.TitleBg:SetHeight(24)
	end
	local titleIcon = frame:CreateTexture(nil, "OVERLAY", nil, 1)
	titleIcon:SetSize(22, 22)
	titleIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -2)
	titleIcon:SetTexture(ICON_PATH)
	table.insert(UISpecialFrames, "TonguesFrame")

	-- Opening the window: fresh values everywhere, always start back at the
	-- top of the list, and leave the "add a word" box empty.
	frame:SetScript("OnShow", function()
		RefreshAll()
		-- The bar's range is worked out from the content height, which the
		-- refreshers above may have just changed (the word count note, the
		-- expansion section). Without this the bar can show the wrong
		-- range until the next scroll.
		UpdateScrollBar()
		if scrollBar then
			scrollBar:SetValue(0)
		end
		-- Setting the position right here - not only when the bar value
		-- changes - is what keeps the very first open correct: the bar
		-- starts at 0, so a plain SetValue(0) would never fire.
		ApplyScroll(0)
		if wordEditBox and not wordEditBox:HasFocus() then
			wordEditBox:SetText("")
		end
		if expansionKeyBox then
			expansionKeyBox:SetText("")
		end
		if expansionValueBox then
			expansionValueBox:SetText("")
		end
	end)

	-- The viewport. Everything drawn below is clipped to this rectangle.
	local host = CreateFrame("ScrollFrame", "TonguesScrollHost", frame)
	host:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -36)
	host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 14)
	host:EnableMouse(true)
	host:EnableMouseWheel(true)
	host:SetScript("OnMouseWheel", function(_, delta)
		ScrollWheel(delta)
	end)
	scrollHost = host

	-- The tall frame inside the viewport; every row is a child of this. It
	-- is handed to the scroll frame as its scroll child further down, once
	-- its real height is known - the order matters (see there).
	local content = CreateFrame("Frame", "TonguesScrollContent", host)
	content:SetPoint("TOPLEFT", 0, 0)
	content:SetPoint("TOPRIGHT", 0, 0)
	content:SetHeight(1)
	scrollContent = content

	-- Blizzard's scroll bar template wants a scroll frame as its parent (its
	-- built-in handler leans on methods only scroll frames have). The look
	-- is free with it; the value handler is pointed at our own content
	-- movement instead. The handler is set last, so nothing fires through
	-- the template default while the starting values are put in place.
	local bar = CreateFrame("Slider", "TonguesScrollBar", host, "UIPanelScrollBarTemplate")
	bar:SetPoint("TOPLEFT", host, "TOPRIGHT", 6, -16)
	bar:SetPoint("BOTTOMLEFT", host, "BOTTOMRIGHT", 6, 16)
	bar:SetWidth(16)
	bar:SetMinMaxValues(0, 1000)
	bar:SetValueStep(1)
	bar:SetValue(0)
	bar:SetScript("OnValueChanged", function(_, value)
		ApplyScroll(value)
	end)
	scrollBar = bar

	-- The writing position, walked down the page as rows are added. It is
	-- always a negative number of pixels from the top of the content.
	local y = -10

	-- One line of small grey text, used when the client cannot measure a
	-- font string for us.
	local SMALL_LINE = 12

	-- How tall a wrapped piece of text turned out to be. GetStringHeight is
	-- the real answer; the width-based estimate covers clients without it.
	-- This is what keeps rows from overlapping when a note wraps to a
	-- second line.
	local function TextHeight(fontString, fallback)
		local height = fontString.GetStringHeight and fontString:GetStringHeight()
		if height and height > 0 then
			return height
		end
		local width = fontString.GetStringWidth and fontString:GetStringWidth()
		if width and width > 0 then
			return math.ceil(width / 400) * SMALL_LINE
		end
		return fallback or SMALL_LINE
	end

	-- Short grey explanation under a setting. Returns the font string so the
	-- caller can measure it before placing the next row.
	local function AddNote(parent, point, text)
		local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		note:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, point)
		note:SetWidth(400)
		note:SetJustifyH("LEFT")
		note:SetTextColor(0.58, 0.58, 0.58)
		note:SetText(text)
		return note
	end

	-- One checkbox setting: a title line, the box itself on the right and an
	-- optional explanation under the title. The next row is placed below
	-- whatever the explanation really took up, so a wrapped note pushes the
	-- following row down instead of being overlapped by it. A row can carry a
	-- tooltip (a list of lines, the first one being the heading); the hover
	-- region sits over the text only, so the box itself still takes clicks.
	local function AddCheckboxRow(parent, title, descText, getter, setter, tooltip)
		if tooltip then
			local hover = CreateFrame("Frame", nil, parent)
			hover:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y + 2)
			hover:SetPoint("RIGHT", parent, "RIGHT", -54, 0)
			hover:SetHeight(16)
			hover:EnableMouse(true)
			hover:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				for index = 1, #tooltip do
					if index == 1 then
						GameTooltip:AddLine(tooltip[index], 1, 0.82, 0.36)
					else
						GameTooltip:AddLine(tooltip[index], 1, 1, 1, true)
					end
				end
				GameTooltip:Show()
			end)
			hover:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
		end

		local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
		label:SetText(title)

		local checkbox = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
		checkbox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y + 2)

		local note
		if descText then
			note = AddNote(parent, y - 15, descText)
		end

		-- Clicking the box flips the matching saved setting and plays the
		-- little tick sound the game uses everywhere.
		checkbox:SetScript("OnClick", function(self)
			local checked = self:GetChecked() and true or false
			if checked then
				ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			else
				ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
			end
			setter(checked)
		end)
		-- Re-read the saved value whenever the window refreshes.
		table.insert(refreshers, function()
			checkbox:SetChecked(getter() and true or false)
		end)

		if note then
			y = y - 15 - TextHeight(note) - 15
		else
			y = y - 26
		end
		return checkbox
	end

	-- A section heading with a thin divider above it; returns the heading
	-- and the height it sits at, so callers can park a button on the same
	-- line. Moves the writing position down to the next row.
	local function AddDividerHeading(title)
		local divider = content:CreateTexture(nil, "ARTWORK")
		divider:SetColorTexture(1, 1, 1, 0.1)
		divider:SetHeight(1)
		divider:SetPoint("TOPLEFT", content, "TOPLEFT", 10, y)
		divider:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, y)
		y = y - 12

		local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		header:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
		header:SetText(title)
		header:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

		local headingY = y
		y = y - 24
		return header, headingY
	end

	-- A one-click reminder of how matching works, printed in chat.
	local helpButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	helpButton:SetSize(100, 22)
	helpButton:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	helpButton:SetText("Show help")
	helpButton:SetScript("OnClick", function()
		ns.ShowHelp()
	end)
	y = y - 32

	-- The page, top to bottom: the Show help button, the intro text, the
	-- master switch and the login hello, Channels, Foreign scripts, Raid
	-- markers in chat, Word filter, Text expansions, Blocked so far and
	-- finally the Icon section. y (above) walks down the page as each block
	-- is placed, which is how the content height is known.

	-- What this window is for
	local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	header:SetText("What Tongues hides")
	header:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	y = y - 20

	local info = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", content, "TOPLEFT", 18, y)
	info:SetWidth(410)
	info:SetJustifyH("LEFT")
	info:SetText("Tongues hides chat messages written in scripts you don't read, and messages that contain any word on your block list. The scripts and the kinds of chat it may touch each have their own checkbox below; everything is saved as you click. Left-click the icon to get back here, right-click it to switch filtering on or off.")
	y = y - TextHeight(info, 51) - 20

	AddCheckboxRow(content, "Enable Tongues",
		"The master switch. Right-clicking the icon does the same.",
		function() return ns.db.enabled end,
		function(value) ns.SetEnabled(value) end)

	-- The login hello, right beside the master switch because both are
	-- about the addon talking to you rather than about what it hides.
	AddCheckboxRow(content, "Say hello on login",
		"Print the on/off state and the blocked total in chat when you log in. Untick to keep chat quiet.",
		function() return ns.db.greeting ~= false end,
		function(value) ns.db.greeting = value end)

	-- Kinds of chat
	AddDividerHeading("Channels")
	local channelNote = AddNote(content, y, "Tick the kinds of chat Tongues may hide messages in. Say, yell and the public channels start ticked; everything else is off until you tick it, so friends always reach you.")
	y = y - TextHeight(channelNote) - 20

	for index = 1, #ns.CHANNEL_GROUPS do
		local group = ns.CHANNEL_GROUPS[index]
		if group.key == "channels" then
			-- One event carries every public channel, so the window splits it
			-- into the two zone channels and the rest; the filter reads which
			-- one a line came from (see Core/Filter.lua).
			AddCheckboxRow(content, "General channel", nil,
				function() return ns.db.channels.general end,
				function(value) ns.db.channels.general = value end)
			AddCheckboxRow(content, "Trade channel", nil,
				function() return ns.db.channels.trade end,
				function(value) ns.db.channels.trade = value end)
			AddCheckboxRow(content, "Other channels (all)", nil,
				function() return ns.db.channels.channels end,
				function(value) ns.db.channels.channels = value end,
				{ "Hides every other channel:", "LocalDefense, WorldDefense, LookingForGroup", "and any custom channel." })
		elseif group.key ~= "communities" or IsRetailClient() then
			-- Communities chat only exists on Retail; Classic and Forever have
			-- no such feature, so the checkbox would be dead weight there.
			AddCheckboxRow(content, group.label, nil,
				function() return ns.db.channels[group.key] end,
				function(value) ns.db.channels[group.key] = value end)
		end
	end

	-- The scripts, one checkbox each
	AddDividerHeading("Foreign scripts")
	local scriptNote = AddNote(content, y, "Messages containing a letter of a ticked script are hidden. Kana anywhere makes a line Japanese; kanji with no kana is Chinese. Accented Latin letters (e, u, o with accents) stay visible. A script your client's font cannot draw appears in chat as boxes; it is still classified and hidden by its own checkbox.")
	y = y - TextHeight(scriptNote) - 20

	-- The example line each script's tooltip shows: the heading first, then
	-- the text in that script. The catch-all bucket has several scripts, so
	-- each of its lines carries its language name first.
	local function LanguageTooltip(language)
		local lines = { "Example:" }
		if language.examples then
			for entryIndex = 1, #language.examples do
				local entry = language.examples[entryIndex]
				lines[#lines + 1] = "|cff9d9d9d"..entry[1]..":|r "..entry[2]
			end
		elseif language.example then
			lines[#lines + 1] = language.example
		end
		return lines
	end

	for index = 1, #ns.LANGUAGES do
		local language = ns.LANGUAGES[index]
		AddCheckboxRow(content, language.label, nil,
			function() return ns.db.languageFilter[language.key] end,
			function(value) ns.db.languageFilter[language.key] = value end,
			LanguageTooltip(language))
	end

	-- The catch-all: anything left over that this client would draw as an
	-- empty box. It says "boxes" rather than naming scripts, because that is
	-- what the player actually sees on screen.
	AddCheckboxRow(content, "Hide anything the chat font cannot draw",
		"The boxes this client shows instead of letters. Catches whatever the script boxes above miss - any character outside Latin, Greek and Cyrillic. Your own lines are never filtered.",
		function() return ns.db.unreadable end,
		function(value) ns.db.unreadable = value end)

	-- Raid markers: their own switch, because they are neither a language nor
	-- a word, and because a marker in group chat is usually a real order
	-- rather than spam - hence the second box.
	AddDividerHeading("Raid markers in chat")

	-- The examples are written the way a spammer uses the markers: inside the
	-- message, several at a time, next to the words.
	local skull = RaidMarkerIcon(8)
	local moon = RaidMarkerIcon(5)
	local diamond = RaidMarkerIcon(3)
	local cross = RaidMarkerIcon(7)
	local markerSpam = skull..skull.." JOHNS SERVICES "..skull..skull
		.." SELLING BOOSTS "..moon..moon.." <Dungeon> "..diamond.." <Dungeon> "..moon..moon

	AddCheckboxRow(content, "Hide messages containing raid markers",
		"Catch any message carrying a marker - {rt1} to {rt8} or {Skull}, {Star}, {X} and the rest.",
		function() return ns.db.markers.on end,
		function(value) ns.db.markers.on = value end,
		{ "Example:", markerSpam })

	AddCheckboxRow(content, "Also in party, raid and instance chat",
		"Leave this unticked to keep markers where they do a job: public chat is checked, group chat is not.",
		function() return ns.db.markers.groupChat end,
		function(value) ns.db.markers.groupChat = value end,
		{ "Example:", "Party: "..skull.." PULL LEFT, "..moon.." ON THE HEALER, "..cross.." STAY OUT" })
	y = y - 4

	-- Word filter
	AddDividerHeading("Word filter")

	AddCheckboxRow(content, "Match whole words only",
		"Tick to catch the word standing on its own - 'lf' will not hide 'halfway'. Untick to also catch the word inside longer words.",
		function() return ns.db.wordFilter.wholeWords ~= false end,
		function(value)
			ns.db.wordFilter.wholeWords = value
			ns.RefreshWordList()
		end)

	local wordLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	wordLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	wordLabel:SetText("Add a word")
	y = y - 18

	local editBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
	editBox:SetSize(210, 24)
	editBox:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	editBox:SetAutoFocus(false)
	editBox:SetMaxLetters(80)
	wordEditBox = editBox

	-- The one place a word gets added: the Add button and Enter both land
	-- here. Empty words are turned away, duplicates explained.
	local function AddFromEditBox()
		local word = ns.Trim(editBox:GetText() or "")
		if word == "" then
			ns.Print("Type a word first.")
			return
		end
		local ok, reason = ns.AddWordFilter(word)
		if ok then
			editBox:SetText("")
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			ns.Print('Now blocking "'..word..'".')
			RefreshAll()
			ns.RefreshWordList()
		elseif reason == "duplicate" then
			ns.Print("That word is already on the list.")
		end
	end

	local addButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	addButton:SetSize(58, 22)
	addButton:SetPoint("LEFT", editBox, "RIGHT", 6, 0)
	addButton:SetText("Add")
	addButton:SetScript("OnClick", AddFromEditBox)

	editBox:SetScript("OnEnterPressed", function(self)
		AddFromEditBox()
		self:ClearFocus()
	end)
	editBox:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)

	y = y - 24
	local wordNote = AddNote(content, y, "Messages containing this word are hidden. Matching ignores case; the whole-words box above decides whether it can hide longer words too.")
	y = y - TextHeight(wordNote) - 12

	local manageButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	manageButton:SetSize(150, 22)
	manageButton:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	manageButton:SetText("Manage blocked words")
	manageButton:SetScript("OnClick", function()
		ns.ToggleWordList()
	end)

	-- A live count next to the button, so a misspelled word is one glance
	-- away from being found.
	local wordCountNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	wordCountNote:SetPoint("LEFT", manageButton, "RIGHT", 10, 0)
	wordCountNote:SetTextColor(0.58, 0.58, 0.58)
	table.insert(refreshers, function()
		local count = #ns.db.wordFilter.words
		if count == 0 then
			-- Nothing to manage yet: the button greys out until the
			-- first word is added above.
			wordCountNote:SetText("The list is empty.")
			manageButton:Disable()
		elseif count == 1 then
			wordCountNote:SetText("1 word on the list.")
			manageButton:Enable()
		else
			wordCountNote:SetText(count.." words on the list.")
			manageButton:Enable()
		end
	end)
	y = y - 34

	-- Text expansions: the phone-keyboard half of the addon. Two boxes and a
	-- button, laid out like the word filter above, plus the switch that turns
	-- the whole thing off without losing the list. The total usage sits on
	-- the heading line, right-aligned.
	local expansionHeader, expansionHeadingY = AddDividerHeading("Text expansions")
	expansionUsageNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	expansionUsageNote:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, expansionHeadingY + 2)
	expansionUsageNote:SetJustifyH("RIGHT")
	expansionUsageNote:SetTextColor(0.58, 0.58, 0.58)
	table.insert(refreshers, UpdateExpansionUsageTotal)

	AddCheckboxRow(content, "Enable text expansions",
		"Rewrite your own chat just before it is sent. The channel, whisper target and language are left exactly as you picked them.",
		function() return ns.db.expansions.on ~= false end,
		function(value) ns.db.expansions.on = value end)

	local expansionLabel = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	expansionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	expansionLabel:SetText("Short form and what to send instead")
	y = y - 18

	local keyBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
	keyBox:SetSize(110, 24)
	keyBox:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	keyBox:SetAutoFocus(false)
	keyBox:SetMaxLetters(40)
	expansionKeyBox = keyBox

	local arrow = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	arrow:SetPoint("LEFT", keyBox, "RIGHT", 6, 0)
	arrow:SetText("->")
	arrow:SetTextColor(0.58, 0.58, 0.58)

	local valueBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
	valueBox:SetSize(196, 24)
	valueBox:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
	valueBox:SetAutoFocus(false)
	valueBox:SetMaxLetters(200)
	expansionValueBox = valueBox

	local addExpansionButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	addExpansionButton:SetSize(58, 22)
	addExpansionButton:SetPoint("LEFT", valueBox, "RIGHT", 6, 0)
	addExpansionButton:SetText("Add")

	-- The one place the Add button and Enter both land in. It uses the same
	-- words the slash command does, so a refused short form explains itself
	-- the same way wherever it was typed.
	local function AddExpansionFromBoxes()
		local ok, reason = ns.SetExpansion(keyBox:GetText(), valueBox:GetText())
		if ok then
			local key = ns.Trim(keyBox:GetText())
			keyBox:SetText("")
			valueBox:SetText("")
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			if reason == "updated" then
				ns.Print('Updated the expansion for "'..key..'".')
			else
				ns.Print('Now expanding "'..key..'".')
			end
			RefreshAll()
			ns.RefreshExpansionList()
		elseif reason == "invalid" then
			ns.Print("The short form must be one word: letters, digits or underscore.")
		elseif reason == "command" then
			ns.Print("The long text cannot start with a slash: that would make it a chat command.")
		else
			ns.Print("Type both the short form and the text to send.")
		end
	end

	addExpansionButton:SetScript("OnClick", AddExpansionFromBoxes)
	-- Enter walks from the short form to the long one, then adds: the order
	-- the two boxes are read in.
	keyBox:SetScript("OnEnterPressed", function()
		valueBox:SetFocus()
	end)
	valueBox:SetScript("OnEnterPressed", function(self)
		AddExpansionFromBoxes()
		self:ClearFocus()
	end)
	local function ClearExpansionBoxes(self)
		keyBox:SetText("")
		valueBox:SetText("")
		self:ClearFocus()
	end
	keyBox:SetScript("OnEscapePressed", ClearExpansionBoxes)
	valueBox:SetScript("OnEscapePressed", ClearExpansionBoxes)
	-- Tab walks the two boxes, left to right and back.
	keyBox:SetScript("OnTabPressed", function()
		valueBox:SetFocus()
	end)
	valueBox:SetScript("OnTabPressed", function()
		keyBox:SetFocus()
	end)

	y = y - 30
	local expansionNote = AddNote(content, y, "Type the short form in chat and the longer text is sent instead. Whole words only, and only in your own messages: links and slash commands are never touched. Short forms are not case sensitive.")
	y = y - TextHeight(expansionNote) - 12

	local manageExpansionsButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	manageExpansionsButton:SetSize(150, 22)
	manageExpansionsButton:SetPoint("TOPLEFT", content, "TOPLEFT", 16, y)
	manageExpansionsButton:SetText("Manage expansions")
	manageExpansionsButton:SetScript("OnClick", function()
		ns.ToggleExpansions()
	end)

	-- The live count beside the button, word filter style.
	local expansionCountNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	expansionCountNote:SetPoint("LEFT", manageExpansionsButton, "RIGHT", 10, 0)
	expansionCountNote:SetTextColor(0.58, 0.58, 0.58)
	table.insert(refreshers, function()
		local count = #ns.db.expansions.rules
		if count == 0 then
			expansionCountNote:SetText("The list is empty - open it to add one.")
		elseif count == 1 then
			expansionCountNote:SetText("1 expansion on the list.")
		else
			expansionCountNote:SetText(count.." expansions on the list.")
		end
		manageExpansionsButton:Enable()
	end)
	y = y - 34

	-- The tallies, one line per script plus the word list
	local countersHeader, countersHeadingY = AddDividerHeading("Blocked so far")

	local resetCountersButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	resetCountersButton:SetSize(130, 22)
	resetCountersButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, countersHeadingY + 2)
	resetCountersButton:SetText("Reset counters")
	resetCountersButton:SetScript("OnClick", function()
		StaticPopup_Show("TONGUES_RESET_COUNTERS")
	end)

	-- The grand total across every counter, parked on the left side of the
	-- Reset button so the whole section sums up at a glance.
	local totalNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	totalNote:SetPoint("RIGHT", resetCountersButton, "LEFT", -12, 0)
	totalNote:SetJustifyH("RIGHT")
	counterLines.total = totalNote

	local function AddCounterLine(key)
		local line = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		line:SetPoint("TOPLEFT", content, "TOPLEFT", 18, y)
		counterLines[key] = line
		y = y - 14
	end

	for index = 1, #ns.LANGUAGES do
		AddCounterLine(ns.LANGUAGES[index].key)
	end
	AddCounterLine("words")
	AddCounterLine("markers")
	AddCounterLine("unreadable")

	local countersNote = AddNote(content, y - 4, "Each hidden message is counted once, under the first reason it matched: your word list, a raid marker, a script, or the undrawable-text catch-all. Counters are saved between sessions; the Reset button clears them all.")
	y = y - 4 - TextHeight(countersNote) - 15

	-- Icon section
	local iconHeader, iconHeadingY = AddDividerHeading("Icon")

	local resetButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	resetButton:SetSize(140, 22)
	resetButton:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, iconHeadingY + 2)
	resetButton:SetText("Reset icon position")
	resetButton:SetScript("OnClick", function()
		ns.ResetIconPosition()
		ns.Print("Icon moved back to its default spot at 11 o'clock.")
	end)

	AddCheckboxRow(content, "Show icon",
		"Hide the icon completely. /tongues still opens this window.",
		function() return ns.db.icon.shown end,
		function(value)
			ns.db.icon.shown = value
			ns.UpdateIconState()
		end)

	AddCheckboxRow(content, "Lock icon", nil,
		function() return ns.db.icon.locked end,
		function(value) ns.db.icon.locked = value end)

	-- The list is finished. y is the bottom edge (negative), so the content
	-- is one small padding taller than -y, and the scroll bar appears only
	-- when the rows do not all fit the window.
	content:SetHeight(-y + 12)
	-- The content is handed over as the scroll frame's scroll child only
	-- now, with its real height in place: doing it while the frame was
	-- still 1 pixel tall left the whole list off-screen on the first open,
	-- until something scrolled it into view. A manual position is applied
	-- last, so the list is guaranteed to start at the top.
	if host.SetScrollChild then
		host:SetScrollChild(content)
	end
	if host.UpdateScrollChildRect then
		host:UpdateScrollChildRect()
	end
	UpdateScrollBar()
	ApplyScroll(0)

	RefreshAll()
end

-------------------------------------------------------------------------------
-- Blocked words window
-------------------------------------------------------------------------------

-- One word per row, with a Remove button, and a Clear All button in the
-- corner - so a misspelled word can be taken back off the list.
local WORD_ROW_HEIGHT = 22

-- Redraws the whole list from the saved words. Called on open and after
-- every add or remove, so the window always shows the truth.
--
-- Every row reads left to right as:
--     "word text .................."   [count]   [X]
-- with a hairline underneath it and a hover tooltip on the row itself.
-- Rows are created once and reused afterwards (frame.rows keeps them), so
-- the scripts below are re-pointed at the current word on every refresh
-- instead of the rows being thrown away and built anew.
local function RefreshWordList()
	if not wordListFrame then
		return
	end
	local frame = wordListFrame
	local words = ns.db.wordFilter.words
	local count = #words

	local rowWidth = frame.scroll:GetWidth()
	if rowWidth < 50 then
		rowWidth = 280
	end
	rowWidth = rowWidth - 10
	frame.content:SetWidth(rowWidth)

	for index = 1, count do
		local row = frame.rows[index]
		if not row then
			row = CreateFrame("Frame", nil, frame.content)
			row:SetHeight(WORD_ROW_HEIGHT)
			row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
			row.text:SetPoint("LEFT", 4, 0)
			row.text:SetJustifyH("LEFT")
			row.text:SetWordWrap(false)
			-- The tally for this word, parked just left of the X.
			row.count = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.count:SetPoint("RIGHT", row, "RIGHT", -28, 0)
			row.count:SetWidth(40)
			row.count:SetJustifyH("RIGHT")
			row.count:SetTextColor(0.58, 0.58, 0.58)
			-- A red X to take the word back off the list, drawn with the
			-- game's own "pass" button textures.
			row.remove = CreateFrame("Button", nil, row)
			row.remove:SetSize(20, 20)
			row.remove:SetPoint("RIGHT", -2, 0)
			row.remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			row.remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
			row.remove:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
			row.remove:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine("Remove this word from the list.", 1, 1, 1, true)
				GameTooltip:Show()
			end)
			row.remove:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			-- A hairline between rows so the list reads as a list.
			row.divider = row:CreateTexture(nil, "ARTWORK")
			row.divider:SetColorTexture(1, 1, 1, 0.08)
			row.divider:SetHeight(1)
			row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
			row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 0)
			-- Hovering a row shows the whole word and its tally, so a word
			-- cut off with "..." can still be read.
			row:EnableMouse(true)
			row:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine('"'..self.tooltipWord..'"', 1, 1, 1, true)
				GameTooltip:AddLine(self.tooltipHits, 0.8, 0.8, 0.8, true)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			frame.rows[index] = row
		end

		local word = words[index]
		local wordHits = 0
		if ns.db.wordCounts then
			wordHits = ns.db.wordCounts[string.lower(word)] or 0
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -(index - 1) * WORD_ROW_HEIGHT)
		row:SetWidth(rowWidth)
		row.text:SetWidth(rowWidth - 76)
		row.text:SetText('"'..word..'"')
		row.count:SetText(ns.FormatCount(wordHits))
		row.divider:SetShown(index < count)
		row.tooltipWord = word
		if wordHits == 1 then
			row.tooltipHits = "Blocked once."
		else
			row.tooltipHits = "Blocked "..ns.FormatCount(wordHits).." times."
		end
		row.remove:SetScript("OnClick", function()
			ns.RemoveWordFilter(word)
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
			RefreshWordList()
			RefreshAll()
		end)
		row:Show()
	end

	for index = count + 1, #frame.rows do
		frame.rows[index]:Hide()
	end

	frame.content:SetHeight(math.max(count * WORD_ROW_HEIGHT, 1))
	frame.emptyText:SetShown(count == 0)
	if frame.clearButton then
		-- Nothing to clear while the list is empty.
		if count == 0 then
			frame.clearButton:Disable()
		else
			frame.clearButton:Enable()
		end
	end
	if frame.modeNote then
		if ns.db.wordFilter.wholeWords ~= false then
			frame.modeNote:SetText('Matching ignores case; only whole words count, so "lf" does not catch "halfway".')
		else
			frame.modeNote:SetText("Matching ignores case; words are caught inside longer words too.")
		end
	end
	local listBar = frame.scroll and frame.scroll.ScrollBar
	if listBar then
		pcall(listBar.SetValue, listBar, 0)
	end
end
-- Shared, so the options window can refresh the list when a word is added
-- while the window happens to be open.
ns.RefreshWordList = RefreshWordList

-- Light touch for live hits: only the little tallies are re-read, so an
-- open window keeps up with new messages without rebuilding the rows. A
-- closed window is skipped: its rows cannot be seen, and the list is
-- refreshed from scratch when it is next shown.
local function UpdateWordCounts()
	if not wordListFrame or not wordListFrame:IsShown() then
		return
	end
	local words = ns.db.wordFilter.words
	for index = 1, #words do
		local row = wordListFrame.rows[index]
		if row and row.count then
			local hits = ns.db.wordCounts and ns.db.wordCounts[string.lower(words[index])] or 0
			row.count:SetText(ns.FormatCount(hits))
		end
	end
end
ns.RefreshWordCounts = UpdateWordCounts

-- Builds the small window, once, on the first login.
local function CreateWordListFrame()
	local frame = CreateFrame("Frame", "TonguesWordListFrame", UIParent, "BasicFrameTemplateWithInset")
	wordListFrame = frame
	frame:SetSize(380, 440)
	frame:SetPoint("CENTER", UIParent, "CENTER", 160, 0)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	frame.TitleText:SetText("Tongues - blocked words")
	table.insert(UISpecialFrames, "TonguesWordListFrame")
	frame.rows = {}

	local scroll = CreateFrame("ScrollFrame", "TonguesWordListScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -38)
	scroll:SetPoint("BOTTOMRIGHT", -30, 70)
	frame.scroll = scroll

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(10, 10)
	local attached = pcall(scroll.SetScrollChild, scroll, content)
	if not attached then
		-- Show the list at least at the top if this client refuses the attach.
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
	end
	frame.content = content

	frame.emptyText = frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
	frame.emptyText:SetPoint("TOP", scroll, "TOP", -10, -30)
	frame.emptyText:SetWidth(320)
	frame.emptyText:SetJustifyH("CENTER")
	frame.emptyText:SetText("No blocked words yet.\nAdd them in the options window (/tongues).")

	-- The bottom note explains the matching rule; RefreshWordList keeps it
	-- in step with the "whole words" checkbox in the options. It is centred
	-- on the same axis as the "No blocked words yet" line, and lives in the
	-- band above the Clear All button so the two never overlap.
	local note = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	note:SetPoint("BOTTOM", scroll, "BOTTOM", -10, -24)
	note:SetWidth(320)
	note:SetJustifyH("CENTER")
	frame.modeNote = note

	-- Kept on the frame so RefreshWordList can grey the button out while
	-- the list is empty.
	local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	clearButton:SetSize(100, 22)
	clearButton:SetPoint("BOTTOMLEFT", 14, 14)
	clearButton:SetText("Clear All")
	frame.clearButton = clearButton
	clearButton:SetScript("OnClick", function()
		if #ns.db.wordFilter.words == 0 then
			return
		end
		StaticPopup_Show("TONGUES_CLEAR_WORDS", tostring(#ns.db.wordFilter.words))
	end)

	frame:SetScript("OnShow", function()
		RefreshWordList()
	end)
end

-- Opens or closes the blocked words window, with the same little sound the
-- options window gets.
function ns.ToggleWordList()
	if not wordListFrame then
		return
	end
	if wordListFrame:IsShown() then
		wordListFrame:Hide()
	else
		ns.PlayUISound("IG_MAINMENU_OPEN")
		wordListFrame:Show()
	end
end

-------------------------------------------------------------------------------
-- Text expansions window
-------------------------------------------------------------------------------

-- One rule per row, and the row is the editor: the short form on the left, the
-- text to send instead on the right, both live edit boxes. An edit is held in
-- a small pending table, keyed by the rule it belongs to, until Save (or Enter)
-- writes it - so sorting the list, or another row changing, never loses a
-- half-typed row. The red X takes the rule off the list; the Save button
-- appears only while a row differs from what is saved, and closing the window
-- with pending rows asks whether to keep them.
local EXPANSION_ROW_HEIGHT = 26

-- The window's four orders, cycled by the Sort button. "newest" is the saved
-- list read backwards, since new rules are appended as they are added.
local EXPANSION_SORTS = {
	{ key = "newest", label = "Newest first" },
	{ key = "oldest", label = "Oldest first" },
	{ key = "az",     label = "A to Z" },
	{ key = "za",     label = "Z to A" },
}

local function CurrentExpansionSort()
	local mode = ns.db and ns.db.expansions and ns.db.expansions.sort
	for index = 1, #EXPANSION_SORTS do
		if EXPANSION_SORTS[index].key == mode then
			return index
		end
	end
	return 1
end

local function UpdateExpansionSortButton()
	if expansionFrame and expansionFrame.sortButton then
		expansionFrame.sortButton:SetText("Sort: "..EXPANSION_SORTS[CurrentExpansionSort()].label)
	end
end

-- The rules in display order. The saved list itself is never reordered. The
-- blank row from the Add button always sits first, so it stays under the eye
-- while it is being filled in, whatever the chosen order.
local function SortedExpansions()
	local rules = ns.db.expansions.rules
	local order = {}
	for index = 1, #rules do
		order[index] = rules[index]
	end
	local mode = EXPANSION_SORTS[CurrentExpansionSort()].key
	if mode == "newest" then
		local reversed = {}
		for index = #order, 1, -1 do
			reversed[#reversed + 1] = order[index]
		end
		order = reversed
	elseif mode == "az" then
		table.sort(order, function(a, b) return string.lower(a.key) < string.lower(b.key) end)
	elseif mode == "za" then
		table.sort(order, function(a, b) return string.lower(a.key) > string.lower(b.key) end)
	end
	if expansionFrame and expansionFrame.draft then
		table.insert(order, 1, expansionFrame.draft)
	end
	return order
end

-- The Add button is one button that lives in the middle of an empty window
-- and in the bottom row as soon as there is a row to show.
local function UpdateExpansionAddButton()
	local frame = expansionFrame
	if not frame or not frame.addButton then
		return
	end
	local empty = #ns.db.expansions.rules == 0 and not frame.draft
	frame.addButton:ClearAllPoints()
	if empty then
		frame.addButton:SetSize(170, 26)
		frame.addButton:SetPoint("CENTER", frame.scroll, "CENTER", -10, 0)
	else
		frame.addButton:SetSize(100, 22)
		frame.addButton:SetPoint("BOTTOMLEFT", 120, 14)
	end
end

-- The pending edit for one rule, or nil when the row matches what is saved.
local function PendingExpansion(rule)
	if not expansionFrame or not rule or expansionFrame.draft == rule then
		return nil
	end
	return expansionFrame.pending[rule]
end

-- The Add button opens one blank row. It is not a saved rule yet: its two
-- boxes live on the draft table itself, and the row is only written into the
-- list when Save is pressed.
local function DraftHasText(draft)
	return draft ~= nil and (draft.key ~= "" or draft.value ~= "")
end

local function UpdateExpansionSaveButton(row)
	if not row or not row.save then
		return
	end
	if row.isDraft then
		row.save:SetShown(DraftHasText(row.rule))
	else
		row.save:SetShown(PendingExpansion(row.rule) ~= nil)
	end
end

-- One line for every reason an expansion edit can be refused.
local function PrintExpansionReason(reason)
	if reason == "duplicate" then
		ns.Print("Another expansion already uses that short form.")
	elseif reason == "invalid" then
		ns.Print("The short form must be one word: letters, digits or underscore.")
	elseif reason == "empty" then
		ns.Print("Type both the short form and the text to send.")
	elseif reason == "command" then
		ns.Print("The long text cannot start with a slash: that would make it a chat command.")
	end
end

-- Writes the blank row from the Add button into the saved list. A short form
-- another rule already uses is refused rather than merged.
local function SaveDraftExpansion(draft)
	local key = ns.Trim(draft.key or "")
	local value = ns.Trim(draft.value or "")
	if key == "" or value == "" then
		return false, "empty"
	end
	local lowered = string.lower(key)
	for index = 1, #ns.db.expansions.rules do
		if string.lower(ns.db.expansions.rules[index].key) == lowered then
			return false, "duplicate"
		end
	end
	return ns.SetExpansion(key, value)
end

-- Puts a row's boxes back to what is saved and forgets its pending edit. A
-- draft row has nothing saved to go back to, so it is simply emptied.
local function ResetExpansionRow(row)
	if not row or not row.rule then
		return
	end
	if row.isDraft then
		row.rule.key, row.rule.value = "", ""
	elseif expansionFrame then
		expansionFrame.pending[row.rule] = nil
	end
	row.updating = true
	row.keyBox:SetText(row.rule.key)
	row.valueBox:SetText(row.rule.value)
	row.updating = false
	UpdateExpansionSaveButton(row)
end

-- Saves one row. Everything that can go wrong is reported in chat and the
-- boxes are put back, so the window never shows something that is not saved.
-- (RefreshExpansionList is forward declared: the row handlers below need it.)
local RefreshExpansionList

local function CommitExpansionRow(row)
	local rule = row.rule
	if not rule then
		return
	end
	if row.isDraft then
		rule.key, rule.value = row.keyBox:GetText(), row.valueBox:GetText()
		local ok, reason = SaveDraftExpansion(rule)
		if ok then
			expansionFrame.draft = nil
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
			ns.Print('Now expanding "'..ns.Trim(rule.key)..'" to "'..ns.Trim(rule.value)..'".')
		else
			-- Keep the row and its text so it can be corrected.
			PrintExpansionReason(reason)
		end
		RefreshExpansionList()
		RefreshAll()
		return
	end
	local key = row.keyBox:GetText()
	local value = row.valueBox:GetText()
	if key == rule.key and value == rule.value then
		expansionFrame.pending[rule] = nil
		UpdateExpansionSaveButton(row)
		return
	end
	local ok, reason = ns.UpdateExpansion(rule, key, value)
	if ok then
		expansionFrame.pending[rule] = nil
		ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
		ns.Print('Now expanding "'..rule.key..'" to "'..rule.value..'".')
	else
		ResetExpansionRow(row)
		PrintExpansionReason(reason)
	end
	RefreshExpansionList()
	RefreshAll()
end

-- Watches a row's two boxes so the Save button follows what is typed. A
-- draft keeps its text on the draft table; a saved row keeps it pending.
local function WatchExpansionRow(row)
	local function NoteEdit()
		if row.updating or not row.rule then
			return
		end
		local key = row.keyBox:GetText()
		local value = row.valueBox:GetText()
		if row.isDraft then
			row.rule.key, row.rule.value = key, value
		elseif key == row.rule.key and value == row.rule.value then
			expansionFrame.pending[row.rule] = nil
		else
			expansionFrame.pending[row.rule] = { key = key, value = value }
		end
		UpdateExpansionSaveButton(row)
	end
	row.keyBox:SetScript("OnTextChanged", NoteEdit)
	row.valueBox:SetScript("OnTextChanged", NoteEdit)
end

local function HasPendingExpansions()
	if not expansionFrame then
		return false
	end
	if next(expansionFrame.pending) then
		return true
	end
	return DraftHasText(expansionFrame.draft)
end

-- Writes every pending edit in one go, for the close prompt's Yes. Rows that
-- fail validation are left at their saved text and reported in chat.
local function SavePendingExpansions()
	if not expansionFrame then
		return
	end
	local saved = 0
	for rule, pending in pairs(expansionFrame.pending) do
		local ok, reason = ns.UpdateExpansion(rule, pending.key, pending.value)
		if ok then
			saved = saved + 1
		else
			PrintExpansionReason(reason)
		end
	end
	local draft = expansionFrame.draft
	if DraftHasText(draft) then
		local ok, reason = SaveDraftExpansion(draft)
		if ok then
			saved = saved + 1
		else
			PrintExpansionReason(reason)
		end
	end
	expansionFrame.draft = nil
	wipe(expansionFrame.pending)
	RefreshExpansionList()
	RefreshAll()
	if saved > 0 then
		ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
		ns.Print("Expansion changes saved.")
	end
end

local function DiscardPendingExpansions()
	if expansionFrame then
		wipe(expansionFrame.pending)
		expansionFrame.draft = nil
	end
end

-- The real close, past the unsaved-changes guard in CreateExpansionFrame.
local function CloseExpansionFrameNow()
	if not expansionFrame then
		return
	end
	expansionFrame.savePromptShown = false
	expansionFrame.forceHide = true
	expansionFrame:Hide()
	expansionFrame.forceHide = false
end

-- Redraws the whole list from the saved rules. Rows are created once and
-- reused; each one captures the rule table it shows, so a row keeps pointing
-- at its own rule even after rows above it are removed or the list is sorted.
function RefreshExpansionList()
	if not expansionFrame then
		return
	end
	local frame = expansionFrame
	local order = SortedExpansions()
	local count = #order

	local rowWidth = frame.scroll:GetWidth()
	if rowWidth < 50 then
		rowWidth = 380
	end
	rowWidth = rowWidth - 10
	frame.content:SetWidth(rowWidth)

	for index = 1, count do
		local rule = order[index]
		local row = frame.rows[index]
		if not row then
			row = CreateFrame("Frame", nil, frame.content)
			row:SetHeight(EXPANSION_ROW_HEIGHT)

			row.keyBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
			row.keyBox:SetSize(110, 22)
			row.keyBox:SetPoint("LEFT", row, "LEFT", 2, 0)
			row.keyBox:SetAutoFocus(false)
			row.keyBox:SetMaxLetters(40)
			row.keyBox:SetTextInsets(8, 4, 0, 0)

			row.arrow = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.arrow:SetPoint("LEFT", row.keyBox, "RIGHT", 4, 0)
			row.arrow:SetText("->")
			row.arrow:SetTextColor(0.58, 0.58, 0.58)

			row.valueBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
			row.valueBox:SetHeight(22)
			row.valueBox:SetPoint("LEFT", row.arrow, "RIGHT", 4, 0)
			row.valueBox:SetPoint("RIGHT", row, "RIGHT", -130, 0)
			row.valueBox:SetAutoFocus(false)
			row.valueBox:SetMaxLetters(200)
			row.valueBox:SetTextInsets(8, 4, 0, 0)

			row.usage = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
			row.usage:SetPoint("RIGHT", row, "RIGHT", -80, 0)
			row.usage:SetWidth(46)
			row.usage:SetJustifyH("RIGHT")

			row.keyBox:SetScript("OnEnterPressed", function()
				row.valueBox:SetFocus()
			end)
			row.keyBox:SetScript("OnEscapePressed", function(self)
				ResetExpansionRow(row)
				self:ClearFocus()
			end)
			row.valueBox:SetScript("OnEnterPressed", function(self)
				CommitExpansionRow(row)
				self:ClearFocus()
			end)
			row.valueBox:SetScript("OnEscapePressed", function(self)
				ResetExpansionRow(row)
				self:ClearFocus()
			end)
			-- Tab walks the boxes left to right, row by row, and wraps around.
			row.keyBox:SetScript("OnTabPressed", function()
				row.valueBox:SetFocus()
			end)
			row.valueBox:SetScript("OnTabPressed", function()
				local nextRow = frame.rows[(row.index or 1) + 1]
				if not nextRow or not nextRow:IsShown() then
					nextRow = frame.rows[1]
				end
				if nextRow and nextRow.keyBox then
					nextRow.keyBox:SetFocus()
				end
			end)
			WatchExpansionRow(row)

			-- Shown only while the row differs from what is saved.
			row.save = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
			row.save:SetSize(46, 20)
			row.save:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			row.save:SetText("Save")
			row.save:Hide()
			row.save:SetScript("OnClick", function()
				CommitExpansionRow(row)
			end)

			row.remove = CreateFrame("Button", nil, row)
			row.remove:SetSize(20, 20)
			row.remove:SetPoint("RIGHT", -52, 0)
			row.remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
			row.remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
			row.remove:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
			row.remove:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine("Remove this expansion.", 1, 1, 1, true)
				GameTooltip:Show()
			end)
			row.remove:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)

			row.divider = row:CreateTexture(nil, "ARTWORK")
			row.divider:SetColorTexture(1, 1, 1, 0.08)
			row.divider:SetHeight(1)
			row.divider:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 2, 0)
			row.divider:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -2, 0)

			frame.rows[index] = row
		end

		local isDraft = (frame.draft ~= nil and rule == frame.draft)
		row.rule = rule
		row.isDraft = isDraft
		row.index = index
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 0, -(index - 1) * EXPANSION_ROW_HEIGHT)
		row:SetWidth(rowWidth)
		local pending = (not isDraft) and frame.pending[rule] or nil
		row.updating = true
		row.keyBox:SetText(pending and pending.key or rule.key)
		row.valueBox:SetText(pending and pending.value or rule.value)
		row.updating = false
		row.divider:SetShown(index < count)
		row.remove:SetShown(not isDraft)
		if not isDraft then
			row.remove:SetScript("OnClick", function()
				local shown = row.rule
				if shown then
					frame.pending[shown] = nil
					if ns.RemoveExpansion(shown) then
						ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
						ns.Print('No longer expanding "'..shown.key..'".')
					end
				end
				RefreshExpansionList()
				RefreshAll()
			end)
			row.usage:SetText(ns.FormatCount(ExpansionUsage(rule)))
		else
			row.usage:SetText("")
		end
		UpdateExpansionSaveButton(row)
		row:Show()
	end

	for index = count + 1, #frame.rows do
		frame.rows[index]:Hide()
	end

	frame.content:SetHeight(math.max(count * EXPANSION_ROW_HEIGHT, 1))
	local savedCount = #ns.db.expansions.rules
	if frame.clearButton then
		if savedCount == 0 then
			frame.clearButton:Disable()
		else
			frame.clearButton:Enable()
		end
	end
	UpdateExpansionSortButton()
	UpdateExpansionAddButton()
	local listBar = frame.scroll and frame.scroll.ScrollBar
	if listBar then
		pcall(listBar.SetValue, listBar, 0)
	end
end
-- Shared, so the options window and the slash commands can refresh the list
-- while the window happens to be open.
ns.RefreshExpansionList = RefreshExpansionList

-- The live half of the usage counters: called whenever an expansion fires, and
-- after a rule is removed or the list is cleared. It only re-reads the texts,
-- so an open window keeps up without rebuilding or stealing focus.
function ns.RefreshExpansionCounts()
	if expansionFrame and expansionFrame:IsShown() then
		for index = 1, #expansionFrame.rows do
			local row = expansionFrame.rows[index]
			if row:IsShown() then
				if row.isDraft then
					row.usage:SetText("")
				elseif row.rule then
					row.usage:SetText(ns.FormatCount(ExpansionUsage(row.rule)))
				end
			end
		end
	end
	UpdateExpansionUsageTotal()
end

-- Builds the window once, on the first login.
local function CreateExpansionFrame()
	local frame = CreateFrame("Frame", "TonguesExpansionFrame", UIParent, "BasicFrameTemplateWithInset")
	expansionFrame = frame
	frame:SetSize(540, 440)
	-- Left of centre, so it sits beside the blocked words window (which is at
	-- +160) instead of on top of it: the two lists are often open together.
	frame:SetPoint("CENTER", UIParent, "CENTER", -260, 0)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	frame.TitleText:SetText("Tongues - text expansions")
	table.insert(UISpecialFrames, "TonguesExpansionFrame")
	frame.rows = {}
	-- Rule -> { key, value } for every row that has been edited but not saved.
	frame.pending = {}

	local scroll = CreateFrame("ScrollFrame", "TonguesExpansionScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -56)
	scroll:SetPoint("BOTTOMRIGHT", -30, 86)
	frame.scroll = scroll

	-- Column headings, fixed above the list so the two boxes read as a short
	-- form and the message it sends.
	local header = CreateFrame("Frame", nil, frame)
	header:SetPoint("TOPLEFT", 24, -42)
	header:SetPoint("TOPRIGHT", -38, -42)
	header:SetHeight(14)

	local shortHeading = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	shortHeading:SetPoint("LEFT", header, "LEFT", 0, 0)
	shortHeading:SetText("Short form")

	local messageHeading = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	messageHeading:SetPoint("LEFT", header, "LEFT", 132, 0)
	messageHeading:SetText("Message")

	local usageHeading = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	usageHeading:SetPoint("RIGHT", scroll, "RIGHT", -90, 0)
	usageHeading:SetWidth(46)
	usageHeading:SetJustifyH("RIGHT")
	usageHeading:SetText("Usage")

	local headerLine = header:CreateTexture(nil, "ARTWORK")
	headerLine:SetColorTexture(1, 1, 1, 0.08)
	headerLine:SetHeight(1)
	headerLine:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", -10, -4)
	headerLine:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 10, -4)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(10, 10)
	local attached = pcall(scroll.SetScrollChild, scroll, content)
	if not attached then
		content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
	end
	frame.content = content

	local note = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	note:SetPoint("BOTTOM", scroll, "BOTTOM", -10, -40)
	note:SetWidth(380)
	note:SetJustifyH("CENTER")
	note:SetText("Whole words only, in your own messages; links and slash commands stay.\nShort forms are not case sensitive. Enter or Save keeps an edit.\nClosing with unsaved rows asks whether to save them.")

	local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	clearButton:SetSize(100, 22)
	clearButton:SetPoint("BOTTOMLEFT", 14, 14)
	clearButton:SetText("Clear All")
	frame.clearButton = clearButton
	clearButton:SetScript("OnClick", function()
		local count = #ns.db.expansions.rules
		if count == 0 then
			return
		end
		StaticPopup_Show("TONGUES_CLEAR_EXPANSIONS", tostring(count))
	end)

	-- Adds a blank row at the top of the list. Once there is something to
	-- show, the same button moves to the bottom row of the window.
	local addButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	addButton:SetSize(100, 22)
	addButton:SetText("Add")
	addButton:SetScript("OnClick", function()
		if not expansionFrame.draft then
			expansionFrame.draft = { key = "", value = "" }
			RefreshExpansionList()
		end
		local row = expansionFrame.rows[1]
		if row and row.keyBox then
			row.keyBox:SetFocus()
		end
	end)
	frame.addButton = addButton

	-- The order the list is shown in; cycled by the button and remembered
	-- between sessions.
	local sortButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sortButton:SetSize(150, 22)
	sortButton:SetPoint("BOTTOMRIGHT", -14, 14)
	sortButton:SetScript("OnClick", function()
		local nextIndex = CurrentExpansionSort() + 1
		if nextIndex > #EXPANSION_SORTS then
			nextIndex = 1
		end
		ns.db.expansions.sort = EXPANSION_SORTS[nextIndex].key
		UpdateExpansionSortButton()
		RefreshExpansionList()
	end)
	frame.sortButton = sortButton
	UpdateExpansionSortButton()
	UpdateExpansionAddButton()

	-- Closing with unsaved rows asks first. ESC closes this window through
	-- UISpecialFrames, which calls Hide directly, so Hide itself is wrapped:
	-- with pending edits the close is parked and the popup decides, and the
	-- real Hide only runs once the player has answered.
	local realHide = frame.Hide
	frame.Hide = function(self)
		if not self.forceHide and self:IsShown() and HasPendingExpansions() then
			if not self.savePromptShown then
				self.savePromptShown = true
				StaticPopup_Show("TONGUES_SAVE_EXPANSIONS")
			end
			return
		end
		-- An empty Add row is not a change worth keeping across a close.
		if self.draft and not DraftHasText(self.draft) then
			self.draft = nil
		end
		return realHide(self)
	end

	frame:SetScript("OnShow", function()
		frame.savePromptShown = false
		RefreshExpansionList()
	end)
end

-- Opens or closes the text expansions window.
function ns.ToggleExpansions()
	if not expansionFrame then
		return
	end
	if expansionFrame:IsShown() then
		expansionFrame:Hide()
	else
		ns.PlayUISound("IG_MAINMENU_OPEN")
		expansionFrame:Show()
	end
end

-- Confirmation before wiping the whole list.
StaticPopupDialogs["TONGUES_CLEAR_WORDS"] = {
	text = "Remove all %s blocked words?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.ClearWordFilter()
		RefreshWordList()
		RefreshAll()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The same confirmation for the expansion list.
StaticPopupDialogs["TONGUES_CLEAR_EXPANSIONS"] = {
	text = "Remove all %s text expansions?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		DiscardPendingExpansions()
		ns.ClearExpansions()
		RefreshExpansionList()
		RefreshAll()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Asked when the expansions window closes with rows that have not been saved.
StaticPopupDialogs["TONGUES_SAVE_EXPANSIONS"] = {
	text = "Do you want to save your changes to the text expansions?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		SavePendingExpansions()
		CloseExpansionFrameNow()
	end,
	OnCancel = function()
		DiscardPendingExpansions()
		CloseExpansionFrameNow()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = false,
	preferredIndex = 3,
}

-- Reset counters used to wipe the tallies the moment the button was pressed.
StaticPopupDialogs["TONGUES_RESET_COUNTERS"] = {
	text = "Reset all counters to zero?",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.ResetCounters()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Entry point: called once from Core.lua after the saved settings are in.
function ns.BuildUI()
	CreateIconButton()
	CreateOptionsFrame()
	CreateWordListFrame()
	CreateExpansionFrame()
	ns.UpdateIconState()
end
