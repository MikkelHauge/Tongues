-- Tongues - the chat filter: raid markers, foreign scripts, the block list,
-- the counters and the /tongues test report.
local addonName, ns = ...

-- Group chat, where a marker is usually a real order ("skull first") rather
-- than spam. The raid-marker filter leaves these alone unless the player
-- ticks "Also in party, raid and instance chat".
local MARKER_QUIET_GROUPS = {
	party = true,
	raid = true,
	instance = true,
}

-- Every way a raid marker can be written in chat: {rt1}..{rt8} plus the
-- names ({Skull}, {X}, ...). ICON_TAG_LIST is the client's own lowered table
-- of them, so a localised client brings its own names; the English list is
-- added on top as the reliable fallback.
local FALLBACK_MARKER_TAGS = {
	"rt1", "rt2", "rt3", "rt4", "rt5", "rt6", "rt7", "rt8",
	"star", "circle", "coin", "diamond", "triangle", "moon",
	"square", "cross", "x", "skull",
}

local markerTokens

local function GetMarkerTokens()
	if markerTokens then
		return markerTokens
	end
	local tokens = {}
	local seen = {}
	local function add(tag)
		if type(tag) ~= "string" or tag == "" then
			return
		end
		local token = tag
		if string.sub(token, 1, 1) ~= "{" then
			token = "{"..token.."}"
		end
		token = string.lower(token)
		if not seen[token] then
			seen[token] = true
			tokens[#tokens + 1] = token
		end
	end
	if type(ICON_TAG_LIST) == "table" then
		for tag in pairs(ICON_TAG_LIST) do
			add(tag)
		end
	end
	for index = 1, #FALLBACK_MARKER_TAGS do
		add(FALLBACK_MARKER_TAGS[index])
	end
	markerTokens = tokens
	return tokens
end
-- True when the message carries a raid marker. The message is expected
-- lowered already. A client that has turned the tag into its picture leaves
-- the texture path behind instead, so that is checked too.
local function ContainsRaidMarker(lowered)
	local tokens = GetMarkerTokens()
	for index = 1, #tokens do
		if string.find(lowered, tokens[index], 1, true) then
			return true
		end
	end
	return string.find(lowered, "ui-raidtargetingicon_", 1, true) ~= nil
end

-- Walks a message and returns the reason it should be hidden: "words" for a
-- hit on the block list (together with the word that matched, kept lowered
-- because that is how the list and the per-word tallies are keyed),
-- "markers" for a raid marker, otherwise the key of the first script found
-- whose checkbox is ticked, or nil when the message should stay visible.
--
-- `group` is the kind of chat the message arrived on ("say", "party", ...);
-- it is optional so /tongues test can run the same checks, and it is what
-- lets the raid-marker filter stay out of party and raid chat.
--
-- The word list is checked before the rest, then the raid markers, then the
-- scripts: a message caught by more than one is credited to the most
-- deliberate reason first, and the rest get their turn on what is left.
local function GetFilterReason(message, group)
	-- The word list first: case-insensitive, and by default only whole
	-- words count, so "lf" does not hide "halfway". ns.loweredWords is the
	-- pre-lowered copy of the list, kept ready for every message.
	--
	-- Two views of the message are checked and a hit in either one counts:
	-- the lowered raw text with link payloads blanked out, and - only when a
	-- "|" is present - the same text with the chat codes stripped. Each view
	-- catches what the other can miss: "WTS|rGOLD" keeps its word boundaries
	-- only in the raw text, while "|cff00ff00WTS" only has them once the code
	-- is gone. Plain messages contain no "|", so neither copy costs anything.
	local words = ns.loweredWords
	if #words > 0 then
		local plain = string.lower(message)
		local stripped = plain
		if string.find(plain, "|", 1, true) then
			plain = string.lower(ns.MaskLinkTargets(message))
			stripped = string.lower(ns.StripChatCodes(message))
		end
		local wholeWords = ns.db.wordFilter.wholeWords ~= false
		for index = 1, #words do
			local word = words[index]
			local hit
			if wholeWords then
				hit = ns.ContainsWholeWord(plain, word)
					or (stripped ~= plain and ns.ContainsWholeWord(stripped, word))
			else
				hit = string.find(plain, word, 1, true) ~= nil
					or (stripped ~= plain and string.find(stripped, word, 1, true) ~= nil)
			end
			if hit then
				return "words", word
			end
		end
	end

	-- Raid markers next. Their own switch, because they are neither a
	-- language nor a word, and their own channel rule: a marker in party,
	-- raid or instance chat is usually someone calling the pull, so those
	-- are skipped unless the second box is ticked. The ordinary channel
	-- checkboxes still decide whether the message is looked at at all.
	local markerSettings = ns.db.markers
	if markerSettings and markerSettings.on then
		local quietGroup = group and MARKER_QUIET_GROUPS[group]
		if not (quietGroup and not markerSettings.groupChat) then
			if ContainsRaidMarker(string.lower(message)) then
				return "markers"
			end
		end
	end

	-- Then the scripts, character by character. The first ticked script the
	-- message contains is the one that hides it (and takes the credit).
	--
	-- Chinese and Japanese share every one of their characters, so the two
	-- boxes are split by what the whole line is written in instead of by
	-- which character happens to come first: kana anywhere makes the line
	-- Japanese (and its ideographs are then kanji), while ideographs with
	-- no kana at all are Chinese. A line therefore falls in exactly one of
	-- the two boxes, and the counter always names the right one. The kana
	-- check only runs once, when the first ideograph is met.
	local languages = ns.db.languageFilter
	local hasKana
	local position = 1
	while true do
		local codepoint
		codepoint, position = ns.NextCodepoint(message, position)
		if not codepoint then
			break
		end
		local script = ns.ClassifyCodepoint(codepoint)
		if script == "chinese" then
			if hasKana == nil then
				hasKana = ns.ContainsKana(message, 1)
			end
			if hasKana then
				script = "japanese"
			end
		end
		if script and languages[script] then
			return script
		end
	end

	-- The catch-all, last: nothing above claimed the line, so if it still
	-- holds a character the font cannot draw, this is what hides it. It is
	-- what makes an unticked script box (or a script no box names) unable
	-- to leak its boxes into chat.
	if ns.db.unreadable and ns.ContainsUndrawable(message) then
		return "unreadable"
	end
	return nil
end

-- Event name -> group key, for the filter below.
local EVENT_GROUP = {}
for index = 1, #ns.CHANNEL_GROUPS do
	local group = ns.CHANNEL_GROUPS[index]
	for eventIndex = 1, #group.events do
		EVENT_GROUP[group.events[eventIndex]] = group.key
	end
end
--------------------------------------------------------------------------------
-- The chat filter
--------------------------------------------------------------------------------

-- The chat system runs filters once per chat frame that would show the
-- message, so a second chat window means a second call for the same line.
-- The counters must still count it once: the last counted message is
-- remembered (reason + event + sender + text) and an identical call right
-- after it - within a blink - is treated as the same message, not a new
-- one. The flip side: two truly identical lines from the same sender
-- inside that quarter second count as one, which is a fair trade for
-- never counting a single line twice.
local lastCountedKey
local lastCountedAt
local filterFailureReported = false

local function CountBlocked(reason, event, message, sender, detail)
	-- GetTime is always there in practice. If a client ever lacked it the
	-- dedupe switches itself off rather than freezing on the first message:
	-- a double count is recoverable, a counter that stops is not.
	local at = GetTime and GetTime()
	local key = reason.."\1"..(event or "?").."\1"..(sender or "?").."\1"..message
	if at and lastCountedAt and key == lastCountedKey and (at - lastCountedAt) < 0.25 then
		return
	end
	lastCountedKey, lastCountedAt = key, at
	local counters = ns.db.counters
	counters[reason] = (counters[reason] or 0) + 1
	if detail then
		-- A word-list hit: tally it for that word as well, so the blocked
		-- words window can show how often each word matched.
		local wordCounts = ns.db.wordCounts
		if wordCounts then
			wordCounts[detail] = (wordCounts[detail] or 0) + 1
		end
	end
	if ns.RefreshCounters then
		ns.RefreshCounters()
	end
	if detail and ns.RefreshWordCounts then
		ns.RefreshWordCounts()
	end
end

-- The little function the chat system calls for every incoming message.
-- It answers true to hide the message and false to let it through - that
-- is the whole contract of a message event filter.

-- The player's own name, read once (it cannot change without a reload).
local ownName

-- True when a message came from the player themselves. Chat lines the player
-- sends come back through these same events - the client does not echo them
-- locally - so without this check a blocked word would eat the line the
-- player just typed and everything would look broken.
local function IsFromPlayer(sender)
	if type(sender) ~= "string" or sender == "" then
		return false
	end
	if not ownName then
		ownName = UnitName("player")
	end
	if not ownName then
		return false
	end
	-- Cross-realm senders arrive as "Name-Realm"; player names never contain
	-- a dash, so the part before it is the character name.
	return (string.match(sender, "^([^%-]+)") or sender) == ownName
end

local function MessageFilter(chatFrame, event, message, sender, ...)
	if not ns.db or not ns.db.enabled then
		-- The master switch silences everything, quietly.
		return false
	end
	if type(message) ~= "string" then
		return false
	end
	if IsFromPlayer(sender) then
		return false
	end
	local group = EVENT_GROUP[event]
	if not group or not ns.db.channels[group] then
		-- This kind of chat is not ticked in the window.
		return false
	end
	local ok, reason, detail = pcall(GetFilterReason, message, group)
	if not ok then
		if not filterFailureReported then
			filterFailureReported = true
			ns.Print("A chat line could not be checked and was left visible.")
		end
		return false
	end
	if reason then
		local okCount = pcall(CountBlocked, reason, event, message, sender, detail)
		if not okCount and not filterFailureReported then
			filterFailureReported = true
			ns.Print("A blocked chat line could not be counted.")
		end
		return true, false -- hide the message
	end
	return false
end

-- The filters are registered once, for every event Tongues knows about;
-- which of them actually hide anything is decided per message from the
-- saved settings, so the checkboxes take effect the moment they are
-- clicked. Newer clients keep the filter registry in ChatFrameUtil; the
-- old global is the fallback, and both take the same tiny function.
local filtersRegistered = false
local registeredFilterEvents = {}

local function TryRegisterChatFilters()
	if filtersRegistered then
		return true
	end
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if not addFilter then
		return false
	end
	local allRegistered = true
	local registeredCount = 0
	for event in pairs(EVENT_GROUP) do
		if not registeredFilterEvents[event] then
			local ok = pcall(addFilter, event, MessageFilter)
			if ok then
				registeredFilterEvents[event] = true
			end
		end
		if registeredFilterEvents[event] then
			registeredCount = registeredCount + 1
		else
			allRegistered = false
		end
	end
	filtersRegistered = allRegistered
	return registeredCount > 0
end

--------------------------------------------------------------------------------
-- Counters
--------------------------------------------------------------------------------

-- Back to zero, everywhere: the options window's Reset counters button and
-- /tongues resetcounters both land here.
function ns.ResetCounters()
	for index = 1, #ns.LANGUAGES do
		ns.db.counters[ns.LANGUAGES[index].key] = 0
	end
	ns.db.counters.words = 0
	ns.db.counters.markers = 0
	ns.db.counters.unreadable = 0
	if ns.db.wordCounts then
		wipe(ns.db.wordCounts)
	end
	if ns.RefreshCounters then
		ns.RefreshCounters()
	end
	if ns.RefreshWordCounts then
		ns.RefreshWordCounts()
	end
	ns.Print("Counters cleared.")
end

-- /tongues counters: the same tallies, in chat.
function ns.ReportCounters()
	ns.Print("Blocked so far:")
	for index = 1, #ns.LANGUAGES do
		local entry = ns.LANGUAGES[index]
		ns.Print("   "..entry.counter..": "..ns.FormatCount(ns.db.counters[entry.key] or 0))
	end
	ns.Print("   word list: "..ns.FormatCount(ns.db.counters.words or 0))
	ns.Print("   raid markers: "..ns.FormatCount(ns.db.counters.markers or 0))
	ns.Print("   undrawable text: "..ns.FormatCount(ns.db.counters.unreadable or 0))
	ns.Print("   total: "..ns.FormatCount(ns.GetTotalBlocked()))
end

-- The grand total across every counter, for the welcome message.
function ns.GetTotalBlocked()
	local total = 0
	local counters = ns.db.counters
	for index = 1, #ns.LANGUAGES do
		total = total + (counters[ns.LANGUAGES[index].key] or 0)
	end
	return total + (counters.words or 0) + (counters.markers or 0) + (counters.unreadable or 0)
end

-- Runs a piece of text through the filter without hiding anything, for
-- checking a word or a script with /tongues test.
function ns.TestMessage(text)
	if not ns.db then
		return nil
	end
	return GetFilterReason(text)
end

-- Turns a filter reason into something readable for the chat report.
function ns.GetReasonLabel(reason)
	if reason == "words" then
		return "your word list"
	elseif reason == "markers" then
		return "a raid marker"
	elseif reason == "unreadable" then
		return "text the font cannot draw"
	end
	for index = 1, #ns.LANGUAGES do
		if ns.LANGUAGES[index].key == reason then
			return ns.LANGUAGES[index].counter
		end
	end
	return tostring(reason)
end

--------------------------------------------------------------------------------
-- Entry point the event file calls.
--------------------------------------------------------------------------------
ns.TryRegisterChatFilters = TryRegisterChatFilters
