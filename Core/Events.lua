-- Tongues - events, the login hello, the help text and slash commands.
local addonName, ns = ...

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- The hello when the world is ready: the master switch and the grand total
-- of everything blocked so far, printed once per session. The checkbox in
-- the window ("Say hello on login") turns it off without touching anything
-- else. One line, in the addon's red, the way the icon looks.
local WELCOME_RED = { 1.00, 0.32, 0.32 }

local function PrintWelcome()
	if ns.db.greeting == false then
		return
	end
	if not DEFAULT_CHAT_FRAME then
		return
	end
	local state = ns.db.enabled and "Enabled" or "Disabled"
	local total = ns.FormatCount(ns.GetTotalBlocked())
	DEFAULT_CHAT_FRAME:AddMessage("[Tongues] "..state..". Blocked messages: "..total,
		WELCOME_RED[1], WELCOME_RED[2], WELCOME_RED[3])
end

-- One frame listens for everything. ADDON_LOADED arrives first and is where
-- the saved settings are read and the UI is built; PLAYER_LOGIN and
-- PLAYER_ENTERING_WORLD get a second chance to hook the chat filters, for
-- clients where the chat machinery is not ready quite as early.
--
-- The two client warnings below are said once per session each.
local warnedNoFilterAPI = false
local warnedNoExpansionHook = false
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
local function HandleTonguesEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon ~= addonName then
			return
		end
		self:UnregisterEvent("ADDON_LOADED")
		if type(TonguesDB) ~= "table" then
			TonguesDB = {}
		end
		ns.db = TonguesDB
		ns.ApplyDefaults(ns.db, ns.DEFAULTS)
		-- One-time touch-up for settings saved by the first build: it
		-- shipped with raid and instance chat ticked, which turned out to
		-- be too eager. Existing tables get those two switched off once;
		-- after that the checkboxes belong entirely to the player.
		--
		-- settingsRevision is deliberately absent from DEFAULTS: defaults
		-- are applied just above, and listing it there would set it to 1
		-- before this check, so the touch-up would never fire again.
		if (ns.db.settingsRevision or 0) < 1 then
			ns.db.settingsRevision = 1
			if ns.db.channels then
				ns.db.channels.raid = false
				ns.db.channels.instance = false
			end
		end
		-- Revision 2 split the old single "channels" box into General, Trade
		-- and everything else. Saves from before that get the old box's value
		-- copied into both new boxes once, so unticking channels still keeps
		-- all channels quiet.
		if (ns.db.settingsRevision or 0) < 2 then
			ns.db.settingsRevision = 2
			if ns.db.channels then
				local on = ns.db.channels.channels and true or false
				ns.db.channels.general = on
				ns.db.channels.trade = on
			end
		end
		-- One-time placement on the minimap edge: 11 o'clock for Tongues,
		-- with Ammonia at 9 and Tally at 7. Not in DEFAULTS, so ApplyDefaults
		-- above cannot set the flag before this check.
		if (ns.db.icon.ringRevision or 0) < 2 then
			ns.db.icon.ringRevision = 2
			ns.db.icon.angle = 120
		end
		ns.RefreshWordFilterCache()
		ns.RefreshExpansionCache()
		if ns.BuildUI then
			ns.BuildUI()
		end
		ns.TryRegisterChatFilters()
		ns.InstallExpansionHook()
		return
	end
	if not ns.db then
		return
	end
	if event == "PLAYER_LOGIN" then
		ns.TryRegisterChatFilters()
		ns.InstallExpansionHook()
		-- The minimap has its real size by now: put the icon back on its
		-- ring at the saved angle (the first apply can run before layout).
		if ns.ApplyIconPosition then
			ns.ApplyIconPosition()
		end
		PrintWelcome()
	elseif event == "PLAYER_ENTERING_WORLD" then
		local filtersReady = ns.TryRegisterChatFilters()
		if not filtersReady and not warnedNoFilterAPI then
			warnedNoFilterAPI = true
			ns.Print("Warning: this client has no chat filtering API, so nothing can be hidden.")
		end
		-- The expansion hook does not depend on the chat filters; it is
		-- retried here for clients whose callback registry was not ready
		-- at ADDON_LOADED.
		if not ns.InstallExpansionHook() and not warnedNoExpansionHook and ns.db.expansions.on then
			warnedNoExpansionHook = true
			ns.Print("Warning: this client cannot edit chat before sending, so text expansions do nothing.")
		end
		-- Both in place: this event has nothing left to say, so stop
		-- listening and save every loading screen the check.
		if filtersReady and ns.expansionHookInstalled then
			self:UnregisterEvent("PLAYER_ENTERING_WORLD")
		end
	end
end

local eventFailureReported = false
eventFrame:SetScript("OnEvent", function(self, event, ...)
	local ok = pcall(HandleTonguesEvent, self, event, ...)
	if not ok and not eventFailureReported then
		eventFailureReported = true
		ns.Print("An internal event check failed; Tongues skipped that event without interrupting the game.")
	end
end)

--------------------------------------------------------------------------------
-- Help
--------------------------------------------------------------------------------

-- The window's Show help button and /tongues help both land here: a short
-- tour of how the word list matches, plus the commands, printed in chat
-- right where the player is already looking.
function ns.ShowHelp()
	ns.Print("Blocked words ignore case. By default only whole words count:")
	ns.Print('   "lf" hides a message saying "lf" or "wts lf", but not "halfway" or "lfg".')
	ns.Print('   Untick "Match whole words only" to also catch a word inside longer words.')
	ns.Print("Foreign scripts: every ticked script hides messages written in it;")
	ns.Print("   kana anywhere counts as Japanese, kanji with no kana as Chinese; accented Latin stays visible.")
	ns.Print("Raid markers are their own switch and stay out of party and raid chat")
	ns.Print("   unless you also tick the group-chat box next to it.")
	ns.Print("'Hide anything the font cannot draw' is the catch-all for the boxes")
	ns.Print("   this client shows instead of letters, whatever the script.")
	ns.Print("Text expansions rewrite your own chat just before it is sent:")
	ns.Print('   with "brb" on the list, typing "brb" sends "be right back".')
	ns.Print("   The channel, whisper target and language are left alone.")
	ns.Print("Commands:")
	ns.Print("   /tongues - open the options; words - the blocked words window")
	ns.Print("   expansions - the expansion list; expand brb = be right back")
	ns.Print("   unexpand brb - take one back off the list")
	ns.Print("   on / off / toggle - the master switch; counters - tallies in chat")
	ns.Print("   resetcounters - back to zero; reset - put the icon back")
	ns.Print("   test <text> - check a line before it ever appears: /tongues test lf")
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Splits "brb = be right back" (or "brb be right back") into its two halves.
local function ParseExpansionCommand(text)
	local key, value = string.match(text, "^%s*([^=]-)%s*=%s*(.-)%s*$")
	if not key or key == "" then
		key, value = string.match(text, "^%s*(%S+)%s+(.+)$")
	end
	return key, value
end

-- /tongues and friends: the window, the on/off switch, the blocked words
-- window, the expansions, the counters, the help, a try-out of the filter
-- and the icon reset.
local function HandleSlash(message)
	if not ns.db then
		return
	end
	local trimmed = ns.Trim(message)
	local command = string.lower(trimmed)
	if command == "" or command == "options" or command == "config" then
		ns.ToggleOptions()
	elseif command == "on" then
		ns.SetEnabled(true)
	elseif command == "off" then
		ns.SetEnabled(false)
	elseif command == "toggle" then
		ns.SetEnabled(not ns.db.enabled)
	elseif command == "words" or command == "list" then
		ns.ToggleWordList()
	elseif command == "expansions" or command == "expansion" then
		ns.ToggleExpansions()
	elseif command == "expand" then
		ns.Print("Usage: /tongues expand brb = be right back")
	elseif string.sub(command, 1, 7) == "expand " then
		local key, value = ParseExpansionCommand(string.sub(trimmed, 8))
		if not key then
			ns.Print("Usage: /tongues expand brb = be right back")
		else
			local ok, reason = ns.SetExpansion(key, value or "")
			if ok then
				if ns.RefreshExpansionList then
					ns.RefreshExpansionList()
				end
				if ns.RefreshOptions then
					ns.RefreshOptions()
				end
				if reason == "updated" then
					ns.Print('Updated the expansion for "'..ns.Trim(key)..'".')
				else
					ns.Print('Now expanding "'..ns.Trim(key)..'".')
				end
			elseif reason == "invalid" then
				ns.Print("The short form must be one word: letters, digits or underscore.")
			elseif reason == "command" then
				ns.Print("The long text cannot start with a slash: that would make it a chat command.")
			else
				ns.Print("Usage: /tongues expand brb = be right back")
			end
		end
	elseif command == "unexpand" then
		ns.Print("Usage: /tongues unexpand brb")
	elseif string.sub(command, 1, 9) == "unexpand " then
		local key = ns.Trim(string.sub(trimmed, 10))
		local loweredKey = string.lower(key)
		local removed
		local rules = ns.db.expansions.rules
		for index = 1, #rules do
			if string.lower(rules[index].key) == loweredKey then
				removed = table.remove(rules, index)
				break
			end
		end
		if removed then
			ns.RefreshExpansionCache()
			if ns.RefreshExpansionList then
				ns.RefreshExpansionList()
			end
			if ns.RefreshOptions then
				ns.RefreshOptions()
			end
			ns.Print('No longer expanding "'..removed.key..'".')
		else
			ns.Print('"'..key..'" is not on the expansion list.')
		end
	elseif command == "counters" then
		ns.ReportCounters()
	elseif command == "resetcounters" then
		ns.ResetCounters()
	elseif command == "help" then
		ns.ShowHelp()
	elseif command == "reset" or command == "resetpos" then
		ns.ResetIconPosition()
		ns.Print("Icon position reset.")
	elseif string.sub(command, 1, 5) == "test " then
		local text = ns.Trim(string.sub(trimmed, 6))
		local reason, detail = ns.TestMessage(text)
		if reason then
			local because = ns.GetReasonLabel(reason)
			if reason == "words" and detail then
				because = 'the word "'..detail..'"'
			end
			ns.Print('"'..text..'" would be hidden ('..because..").")
		else
			ns.Print('"'..text..'" would stay visible.')
		end
	elseif command == "test" then
		ns.Print("Usage: /tongues test some text")
	else
		ns.Print("Commands: /tongues, on, off, toggle, words, expansions, expand <key> = <text>, unexpand <key>, counters, resetcounters, test <text>, reset, help")
	end
end

SLASH_TONGUES1 = "/tongues"
local slashFailureReported = false
SlashCmdList["TONGUES"] = function(message)
	local ok = pcall(HandleSlash, message)
	if not ok and not slashFailureReported then
		slashFailureReported = true
		ns.Print("An internal slash command failed; Tongues skipped it without interrupting the game.")
	end
end
