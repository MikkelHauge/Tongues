--------------------------------------------------------------------------------
-- Tongues - a chat filter that hides foreign-script messages and messages
-- containing words you never want to see again
--------------------------------------------------------------------------------
-- What it does:
--   * Hides chat messages written in scripts you don't read - Russian,
--     Chinese, Japanese, Korean, Greek, Hebrew, Arabic, Thai and a catch-all
--     "Other" bucket. Each one has its own checkbox and is on by default.
--     A catch-all can hide any character the chat font cannot draw at all -
--     which is also what covers symbols and emoji, since they are boxes here.
--   * Hides messages carrying a raid marker ({rt1} ... {Skull}) on its own
--     switch, and keeps that switch out of party, raid and instance chat
--     unless a second box is ticked.
--   * Hides messages that contain any word on your own block list. Matching
--     ignores case and, by default, only whole words count: "lf" hides a
--     message that says "lf" but not one that says "halfway". A checkbox in
--     the window relaxes that to catch the word inside longer words too.
--   * Counts every hidden message per script and for the word list, and
--     keeps a little tally per blocked word too; the options window shows
--     the big numbers, the blocked words window the per-word ones.
--   * Says hello on login with the master switch and the grand total of
--     blocked messages so far (a checkbox in the window turns it off).
--   * Only the kinds of chat you tick are filtered. Say, yell and public
--     channels start ticked; raid, instance, party, guild and whisper chat
--     are left alone until you tick them.
--   * Rewrites your own messages before they are sent, phone-keyboard style:
--     with "brb" on the expansion list, typing "brb" in chat sends
--     "be right back". Whole words only, capitals are matched to how you
--     typed the short form, and the line keeps the channel, whisper target
--     and language it was written for. Links and slash commands are never
--     touched.
--   * A small icon rides the minimap's outer edge: left-click opens the
--     options, right-click turns filtering on or off. Only its angle is
--     saved, so it comes back to the same spot after a reload.
--
-- How an addon like this is put together, for anyone who wants to tinker:
--   * The game loads the files named in Tongues.toc from top to bottom.
--   * The first line of each file is:
--         local addonName, ns = ...
--     The game hands every file the addon's name and one shared table
--     (called a namespace; "ns" here). Files can put functions and settings
--     on that table and see what the other files put there. Core.lua loads
--     first, so the shared machinery lives there; the other files add their
--     own piece on top, and UI.lua adds the icon, the options window and the
--     two list windows last.
--   * Addons hear about the world through events. The game calls our event
--     handler (see the Events section below) with names like ADDON_LOADED
--     ("our files are loaded and our saved settings are here"). We register
--     for the events we care about and act when they fire.
--   * Chat filtering itself works through the chat system's message-event
--     filters: we hand the game a little function per chat event, the game
--     calls it for every incoming message, and returning true hides it.
--   * Outgoing text is changed through the chat system's own callback for
--     "this line is about to be sent" (ChatFrame.OnEditBoxPreSendText). The
--     game calls it after it has worked out the chat type and target and
--     before it reads the text, so replacing the text there sends the new
--     line exactly where the old one was headed.
--   * TonguesDB is a saved-variables table: the game stores it in the WTF
--     folder and hands it back on every login, so settings and counters
--     survive between sessions.
--   * Functions named like ns.Something are shared with the other files and
--     with UI.lua; plain local functions stay private to their file.
--
-- Files:
--   * Core.lua (this file): helpers, the script and channel tables, defaults
--     and the master switch.
--   * Core/Scripts.lua: the UTF-8 walker, script classification and the
--     characters the chat font cannot draw.
--   * Core/Words.lua: whole-word matching, chat-code stripping and the saved
--     block list.
--   * Core/Filter.lua: the chat filter itself, the counters and the
--     try-it-out report.
--   * Core/Expansions.lua: the text expansion rules and the rewrite just
--     before a line is sent.
--   * Core/Events.lua: events, the login hello, help and slash commands.
--   * UI.lua: the icon, the options window, the blocked words window and the
--     text expansions window.
--------------------------------------------------------------------------------
local addonName, ns = ...

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

-- Prints a line in chat with the addon's name in front, used by the slash
-- commands and the window's little notices.
function ns.Print(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffb347[Tongues]|r "..tostring(message))
	end
end

-- Removes leading and trailing spaces from a piece of text.
function ns.Trim(text)
	return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

-- Plays one of the game's interface sounds by its SOUNDKIT name, quietly
-- doing nothing when the client does not know that name.
function ns.PlayUISound(name)
	local kit = SOUNDKIT and SOUNDKIT[name]
	if kit then
		pcall(PlaySound, kit)
	end
end

-- Formats a number with thousands separators where the client can do that
-- ("1,250"), and as a plain number where it cannot.
function ns.FormatCount(count)
	if BreakUpLargeNumbers then
		local ok, formatted = pcall(BreakUpLargeNumbers, count)
		if ok and formatted then
			return tostring(formatted)
		end
	end
	return tostring(count)
end

--------------------------------------------------------------------------------
-- The filterable scripts
--------------------------------------------------------------------------------

-- "label" is what the checkbox in the window says, "counter" is what the
-- "blocked so far" line says ("You have blocked 12 messages in Russian.").
-- The saved settings and counters are keyed by "key".
local LANGUAGES = {
	{ key = "russian",  label = "Russian (Cyrillic)",              counter = "Russian" },
	{ key = "chinese",  label = "Chinese (kanji, no kana)",        counter = "Chinese" },
	{ key = "japanese", label = "Japanese (kana)",                 counter = "Japanese" },
	{ key = "korean",   label = "Korean (hangul)",                 counter = "Korean" },
	{ key = "greek",    label = "Greek",                           counter = "Greek" },
	{ key = "hebrew",   label = "Hebrew",                          counter = "Hebrew" },
	{ key = "arabic",   label = "Arabic",                          counter = "Arabic" },
	{ key = "thai",     label = "Thai",                            counter = "Thai" },
	{ key = "other",    label = "Other scripts (Armenian, Georgian, Indic ...)", counter = "other scripts" },
	{ key = "styled",   label = "Styled Latin (spam fonts)",        counter = "styled Latin" },
}
ns.LANGUAGES = LANGUAGES

--------------------------------------------------------------------------------
-- The kinds of chat
--------------------------------------------------------------------------------
-- Every group carries one or more chat events; the checkboxes in the window
-- pick which groups may hide messages. Say, yell and public channels start
-- ticked - raid, instance, party, guild and whisper chat are off by default.

local CHANNEL_GROUPS = {
	{ key = "say",      label = "Say",                                      events = { "CHAT_MSG_SAY" } },
	{ key = "yell",     label = "Yell",                                     events = { "CHAT_MSG_YELL" } },
	{ key = "channels", label = "Channels (general, trade and custom)",     events = { "CHAT_MSG_CHANNEL" } },
	{ key = "communities", label = "Communities chat",                      events = { "CHAT_MSG_COMMUNITIES_CHANNEL" } },
	{ key = "raid",     label = "Raid",                                     events = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER" } },
	{ key = "instance", label = "Instance chat (dungeons, battlegrounds)",  events = { "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_BATTLEGROUND", "CHAT_MSG_BATTLEGROUND_LEADER" } },
	{ key = "party",    label = "Party",                                    events = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" } },
	{ key = "guild",    label = "Guild and officer",                        events = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER" } },
	{ key = "whisper",  label = "Whispers (normal and Battle.net)",         events = { "CHAT_MSG_WHISPER", "CHAT_MSG_BN_WHISPER" } },
}
ns.CHANNEL_GROUPS = CHANNEL_GROUPS

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

-- Every setting, with the value a fresh install starts from. ApplyDefaults
-- below copies missing keys from here into the saved table, so new settings
-- can simply be added to this list. Note the defaults for channels: say,
-- yell and public channels are ticked; everything more personal stays off
-- until the player asks for it.
local DEFAULTS = {
	enabled = true,
	-- The hello printed in chat at login. On by default, off for anyone who
	-- would rather not see it every session.
	greeting = true,
	channels = {
		say = true,
		yell = true,
		channels = true,
		communities = false,
		raid = false,
		instance = false,
		party = false,
		guild = false,
		whisper = false,
	},
	languageFilter = {
		russian = true,
		chinese = true,
		japanese = true,
		korean = true,
		greek = true,
		hebrew = true,
		arabic = true,
		thai = true,
		other = true,
		styled = true,
	},
	-- Raid markers written into chat ({rt1} ... {Skull}). Off by default,
	-- and kept out of party, raid and instance chat unless groupChat is on.
	markers = {
		on = false,
		groupChat = false,
	},
	-- Catch-all: hide anything the chat font would draw as a box, whatever
	-- script it is. Off by default; the per-script boxes already cover the
	-- common cases.
	unreadable = false,
	wordFilter = {
		words = {},
		wholeWords = true,
	},
	counters = {
		russian = 0,
		chinese = 0,
		japanese = 0,
		korean = 0,
		greek = 0,
		hebrew = 0,
		arabic = 0,
		thai = 0,
		other = 0,
		styled = 0,
		words = 0,
		markers = 0,
		unreadable = 0,
	},
	-- Per-word tallies for the blocked words window, keyed by the lowered
	-- word (so "WTS Gold" and "wts gold" share one tally).
	wordCounts = {},
	icon = {
		shown = true,
		locked = false,
		-- Degrees around the minimap's outer edge; 120 is 11 o'clock. The
		-- three addons use 120, 180 and 240 (11, 9 and 7 o'clock) so they
		-- line up down the left side and never sit on the clock.
		-- The old free-position keys (freePos/freeX/freeY) are gone on
		-- purpose: one angle is all it takes to put the icon back, and an
		-- old save simply keeps its unused keys without harm.
		angle = 120,
	},
	-- Phone-keyboard style replacements for the player's own messages.
	-- "rules" is a list of { key = "brb", value = "be right back" } pairs,
	-- kept in the order they were added so the window reads predictably.
	expansions = {
		on = true,
		rules = {},
	},
}

-- Walks the defaults and fills in anything the saved table does not have
-- yet (tables go one level deeper). A value that is there but of the wrong
-- type - a hand-edited WTF file, a setting that changed shape between
-- versions - is replaced rather than trusted, so no later code has to guard
-- against a table where it expects a number.
local function ApplyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			ApplyDefaults(target[key], value)
		elseif target[key] == nil or type(target[key]) ~= type(value) then
			target[key] = value
		end
	end
end

-- The master switch, used by the checkbox, the icon's right-click and the
-- slash commands. Refreshes the icon and the window so everything agrees.
function ns.SetEnabled(enabled)
	ns.db.enabled = enabled and true or false
	if ns.UpdateIconState then
		ns.UpdateIconState()
	end
	if ns.RefreshOptions then
		ns.RefreshOptions()
	end
	if ns.db.enabled then
		ns.Print("Filtering enabled.")
	else
		ns.Print("Filtering disabled.")
	end
end

ns.DEFAULTS = DEFAULTS
ns.ApplyDefaults = ApplyDefaults
