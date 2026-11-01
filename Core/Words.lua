-- Tongues - matching words in a message, and the saved block list itself.
local addonName, ns = ...

-- Lowered copies of the blocked words, kept here so every incoming message
-- does not have to lowercase the whole list again.
ns.loweredWords = {}

-- Reads the character that ends just before byte `position`, so a boundary
-- check can tell an em dash (a break) from a letter (not a break). Returns
-- the codepoint, or nil at the start of the text.
local function CodepointBefore(text, position)
	local index = position - 1
	if index < 1 then
		return nil
	end
	local byte = string.byte(text, index)
	if byte < 0x80 then
		return byte
	end
	-- Step back over the trailing bytes (10xxxxxx) to the first byte of the
	-- character; three steps is the most a four-byte character can need.
	local steps = 0
	while index > 1 and byte and byte >= 0x80 and byte < 0xC0 and steps < 3 do
		index = index - 1
		steps = steps + 1
		byte = string.byte(text, index)
	end
	return (ns.NextCodepoint(text, index))
end

-- True when the message starts, or a separating character, sits just before
-- the match. A stray continuation byte keeps the old "part of a word" answer.
local function BoundaryBefore(text, position)
	if position <= 1 then
		return true
	end
	local codepoint = CodepointBefore(text, position)
	if codepoint and ns.IsWordSeparator(codepoint) then
		return true
	end
	return not ns.IsWordByte(string.byte(text, position - 1))
end

-- The same check on the far side: end of message, separator, or a non-word
-- byte such as a space, brackets or punctuation.
local function BoundaryAfter(text, position)
	local byte = string.byte(text, position)
	if not byte then
		return true
	end
	if byte >= 0x80 then
		local codepoint = ns.NextCodepoint(text, position)
		if codepoint and ns.IsWordSeparator(codepoint) then
			return true
		end
		return false
	end
	return not ns.IsWordByte(byte)
end

-- Finds `word` in the lowered message only where it stands on its own: the
-- characters on either side must not be word characters. This is what keeps
-- "lf" from hiding "halfway".
--
-- Lua's patterns cannot express a word boundary, so this is a plain find in a
-- circle:
--   * search for the next occurrence (true = plain text, no pattern),
--   * look at the character just before and just after it (the ends of the
--     message count as boundaries),
--   * accept when neither side is a word character, otherwise step one byte
--     forward and search again.
local function ContainsWholeWord(lowered, word)
	if word == "" then
		return false
	end
	local start = 1
	while true do
		local matchStart, matchEnd = string.find(lowered, word, start, true)
		if not matchStart then
			return false
		end
		if BoundaryBefore(lowered, matchStart) and BoundaryAfter(lowered, matchEnd + 1) then
			return true
		end
		start = matchStart + 1
	end
end

-- Chat text arrives with formatting codes baked into the raw string:
--   |cAARRGGBB  colour start        |r  colour reset
--   |Hitem:123|h[Name]|h  item link |Ttexture|t  embedded texture
-- plus rarer ones this deliberately leaves alone (|n, |K, ...).
-- They matter to the word list because a word glued straight to a code
-- ("|cffffd200WTS GOLD|r") would fail the whole-word boundary check, so
-- the codes are taken out for matching. The script walk keeps reading the
-- raw text, so coloured Cyrillic is still caught exactly as before.
local function StripChatCodes(text)
	if not string.find(text, "|", 1, true) then
		return text
	end
	text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
	text = string.gsub(text, "|H.-|h", "")
	text = string.gsub(text, "|T.-|t", "")
	text = string.gsub(text, "|r", "")
	text = string.gsub(text, "|h", "")
	return text
end

-- Blanks out the inside of every link (|Hitem:123|h -> |h) while leaving the
-- visible link text and the colour codes alone. The word list checks this
-- view too: a link's payload is digits and colons, so without this a block
-- list entry that happens to be a number would hide every message carrying an
-- item with that number in its ID.
local function MaskLinkTargets(text)
	return (string.gsub(text, "|H.-|h", "|h"))
end
--------------------------------------------------------------------------------
-- Word list management
--------------------------------------------------------------------------------

-- Rebuilds the pre-lowered copy of the word list; called whenever the list
-- changes and after login. string.lower only knows A-Z, so matching is
-- case-insensitive for the Latin alphabet only; a word written in another
-- script must match its case exactly - which hardly matters, since whole
-- messages in that script can be hidden with the script checkbox instead.
function ns.RefreshWordFilterCache()
	local clean = {}
	local cache = {}
	local words = ns.db and ns.db.wordFilter and ns.db.wordFilter.words or {}
	local seen = {}
	for index = 1, #words do
		local word = words[index]
		if type(word) == "string" then
			word = ns.Trim(StripChatCodes(word))
			if word ~= "" then
				local lowered = string.lower(word)
				if not seen[lowered] then
					seen[lowered] = true
					clean[#clean + 1] = word
					cache[#cache + 1] = lowered
				end
			end
		end
	end
	-- Replace the saved list with the clean copy, in place: the UI and the
	-- saved table keep pointing at the same table.
	if ns.db and ns.db.wordFilter and type(ns.db.wordFilter.words) == "table" then
		local oldCount = #ns.db.wordFilter.words
		for index = 1, #clean do
			ns.db.wordFilter.words[index] = clean[index]
		end
		for index = oldCount, #clean + 1, -1 do
			ns.db.wordFilter.words[index] = nil
		end
	end
	ns.loweredWords = cache
end

-- Adds a word; false plus a reason when it is empty or already there. A
-- word pasted straight out of chat can still carry colour codes, so those
-- are taken out first - otherwise it could never match anything.
function ns.AddWordFilter(word)
	if type(word) ~= "string" then
		return false, "empty"
	end
	word = ns.Trim(StripChatCodes(word))
	if word == "" then
		return false, "empty"
	end
	local loweredWord = string.lower(word)
	local words = ns.db.wordFilter.words
	for index = 1, #words do
		local existing = words[index]
		if type(existing) == "string" and string.lower(existing) == loweredWord then
			return false, "duplicate"
		end
	end
	table.insert(words, word)
	ns.RefreshWordFilterCache()
	return true
end

-- Removes one exact word from the list, along with its tally.
function ns.RemoveWordFilter(word)
	if type(word) ~= "string" then
		return false
	end
	local words = ns.db.wordFilter.words
	for index = 1, #words do
		if type(words[index]) == "string" and words[index] == word then
			table.remove(words, index)
			if ns.db.wordCounts then
				ns.db.wordCounts[string.lower(word)] = nil
			end
			ns.RefreshWordFilterCache()
			return true
		end
	end
	return false
end

-- Empties the whole list, tallies included.
function ns.ClearWordFilter()
	wipe(ns.db.wordFilter.words)
	if ns.db.wordCounts then
		wipe(ns.db.wordCounts)
	end
	ns.RefreshWordFilterCache()
end

--------------------------------------------------------------------------------
-- Shared with the chat filter.
--------------------------------------------------------------------------------
ns.ContainsWholeWord = ContainsWholeWord
ns.StripChatCodes = StripChatCodes
ns.MaskLinkTargets = MaskLinkTargets
