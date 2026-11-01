-- Tongues - text expansions: the saved rules and the rewrite just before
-- a line is sent.
local addonName, ns = ...

--------------------------------------------------------------------------------
-- Text expansions
--------------------------------------------------------------------------------
-- Phone-keyboard style: type a short form, send the long one. The swap
-- happens in the chat edit box at the moment the player presses Enter,
-- through the client's own "final edits before sending" callback. That is
-- what keeps the line in the channel it was written for: by the time the
-- callback runs the client has already turned "/p brb" into party chat with
-- "brb" in the box, and only the text is ever replaced - the chat type,
-- whisper target and channel belong to the edit box and are never touched.
--
-- The rules are a list of { key, value } pairs in the saved table. The
-- lowered keys live in ns.expansionCache, so a chat line costs one lookup
-- per word instead of a walk over the whole list.

ns.expansionCache = {}

-- Trims a box's text and keeps it inside a sane length. Keys stay short
-- enough to read, values fit well inside the 255-byte chat limit. The cut
-- never lands inside a multi-byte character, so a Cyrillic value is not
-- broken in half by a byte limit.
local function TruncateUtf8(text, limit)
	if #text <= limit then
		return text
	end
	local cut = 1
	local index = 1
	while index <= limit do
		local codepoint, nextIndex = ns.NextCodepoint(text, index)
		if not codepoint or not nextIndex or nextIndex - 1 > limit then
			break
		end
		cut = nextIndex
		index = nextIndex
	end
	return string.sub(text, 1, cut - 1)
end

local function ClampExpansionText(text, limit)
	text = ns.Trim(text or "")
	if #text > limit then
		text = TruncateUtf8(text, limit)
	end
	return text
end

-- A short form has to be a single word: it is matched against whole words in
-- the chat line, so a space or punctuation could never be found. ASCII
-- letters, digits, underscore and the bytes of a multi-byte character are
-- allowed, so a Cyrillic or Greek short form works too.
local function IsValidExpansionKey(key)
	return key ~= "" and string.find(key, "^[%w_\128-\255]+$") ~= nil
end

-- Rebuilds the lowered lookup table; called whenever the list changes and
-- after login. Anything in the saved list that is not a { key, value } pair
-- of strings is dropped on the way (a hand-edited WTF file can contain
-- anything, and one bad entry must not break every message).
function ns.RefreshExpansionCache()
	local cache = {}
	local rules = (ns.db and ns.db.expansions and ns.db.expansions.rules) or {}
	local clean, seen = {}, {}
	for index = 1, #rules do
		local rule = rules[index]
		if type(rule) == "table" and type(rule.key) == "string" and type(rule.value) == "string" then
			local key = ClampExpansionText(rule.key, 40)
			local value = ClampExpansionText(rule.value, 200)
			if key ~= "" and value ~= "" and IsValidExpansionKey(key)
				and string.sub(value, 1, 1) ~= "/" then
				local lowered = string.lower(key)
				if not seen[lowered] then
					seen[lowered] = true
					rule.key, rule.value = key, value
					clean[#clean + 1] = rule
				end
			end
		end
	end
	-- Replace the saved list with the clean copy, in place, so the window and
	-- the saved table keep pointing at the same table.
	local oldCount = #rules
	for index = 1, #clean do
		rules[index] = clean[index]
	end
	for index = oldCount, #clean + 1, -1 do
		rules[index] = nil
	end
	for index = 1, #clean do
		cache[string.lower(clean[index].key)] = clean[index].value
	end
	ns.expansionCache = cache
end

-- A value is message text, not a command. One starting with a slash would be
-- re-read as a slash command by the chat box's own text-changed handler (which
-- the client runs even for text an addon sets), changing the chat type or the
-- whisper target out from under the player - so it is refused.
local function IsValidExpansionValue(value)
	return string.sub(value, 1, 1) ~= "/"
end

-- The usage tally belongs to the short form, so it follows a rename and is
-- dropped with the rule.
local function MoveExpansionCount(oldKey, newKey)
	local counts = ns.db.expansionCounts
	if not counts then
		return
	end
	local oldLower = string.lower(oldKey or "")
	local newLower = string.lower(newKey or "")
	if oldLower == "" or oldLower == newLower then
		return
	end
	local used = counts[oldLower]
	if used then
		counts[newLower] = (counts[newLower] or 0) + used
		counts[oldLower] = nil
	end
end

-- Adds a rule, or updates the text of one whose short form is already there.
-- Returns true plus "added" or "updated", or false plus the reason.
function ns.SetExpansion(key, value)
	key = ClampExpansionText(key, 40)
	value = ClampExpansionText(value, 200)
	if key == "" or value == "" then
		return false, "empty"
	end
	if not IsValidExpansionKey(key) then
		return false, "invalid"
	end
	if not IsValidExpansionValue(value) then
		return false, "command"
	end
	local loweredKey = string.lower(key)
	local rules = ns.db.expansions.rules
	for index = 1, #rules do
		local rule = rules[index]
		if string.lower(rule.key) == loweredKey then
			local oldKey = rule.key
			rule.key, rule.value = key, value
			MoveExpansionCount(oldKey, key)
			ns.RefreshExpansionCache()
			return true, "updated"
		end
	end
	table.insert(rules, { key = key, value = value })
	ns.RefreshExpansionCache()
	return true, "added"
end

-- Saves the two boxes of one row in the expansions window. A rename onto a
-- short form another row already uses is refused rather than merged, so
-- nothing disappears without the player being told.
function ns.UpdateExpansion(rule, key, value)
	if not rule then
		return false, "missing"
	end
	key = ClampExpansionText(key, 40)
	value = ClampExpansionText(value, 200)
	if key == "" or value == "" then
		return false, "empty"
	end
	if not IsValidExpansionKey(key) then
		return false, "invalid"
	end
	if not IsValidExpansionValue(value) then
		return false, "command"
	end
	local loweredKey = string.lower(key)
	local rules = ns.db.expansions.rules
	for index = 1, #rules do
		local other = rules[index]
		if other ~= rule and string.lower(other.key) == loweredKey then
			return false, "duplicate"
		end
	end
	local oldKey = rule.key
	rule.key, rule.value = key, value
	MoveExpansionCount(oldKey, key)
	ns.RefreshExpansionCache()
	return true
end

-- Removes one rule by its table, so a row always deletes what it shows. Its
-- usage tally goes with it.
function ns.RemoveExpansion(rule)
	local rules = ns.db.expansions.rules
	for index = 1, #rules do
		if rules[index] == rule then
			table.remove(rules, index)
			if ns.db.expansionCounts then
				ns.db.expansionCounts[string.lower(rule.key)] = nil
			end
			ns.RefreshExpansionCache()
			if ns.RefreshExpansionCounts then
				ns.RefreshExpansionCounts()
			end
			return true
		end
	end
	return false
end

-- Empties the whole list, tallies included.
function ns.ClearExpansions()
	wipe(ns.db.expansions.rules)
	if ns.db.expansionCounts then
		wipe(ns.db.expansionCounts)
	end
	ns.RefreshExpansionCache()
	if ns.RefreshExpansionCounts then
		ns.RefreshExpansionCounts()
	end
end

-- Matches the replacement's capitals to how the short form was typed, so
-- "brb" stays calm, "Brb" starts a sentence and "BRB" shouts. Words without
-- case of their own (Cyrillic, digits) come back untouched instead of being
-- shouted at by accident.
local function MatchCase(typed, replacement)
	if string.lower(typed) == typed then
		return replacement
	end
	if string.upper(typed) == typed then
		return string.upper(replacement)
	end
	local first = string.sub(typed, 1, 1)
	if first == string.upper(first) then
		return string.upper(string.sub(replacement, 1, 1))..string.sub(replacement, 2)
	end
	return replacement
end

-- A chat line can carry at most 255 bytes; expanding a long one can push it
-- over, and the client would cut it somewhere arbitrary.
local EXPANSION_LINE_LIMIT = 255

-- The character at `index`: its first byte, its codepoint, and the index just
-- past it. nil at the end of the text (or on a byte that is not valid UTF-8).
local function CharacterAt(text, index)
	local byte = string.byte(text, index)
	if not byte then
		return nil
	end
	if byte < 0x80 then
		return byte, byte, index + 1
	end
	local codepoint, nextIndex = ns.NextCodepoint(text, index)
	if not codepoint then
		return nil
	end
	return byte, codepoint, nextIndex
end

-- True when a character belongs to a word for expansion purposes: an ASCII
-- word byte, or a non-ASCII character that is not one of the separator
-- symbols. The second half matters in chat: it lets "brb😂" and "brb—now"
-- expand, instead of the emoji or dash swallowing the word.
local function IsExpansionWordChar(byte, codepoint)
	if byte < 0x80 then
		return ns.IsWordByte(byte)
	end
	return not ns.IsWordSeparator(codepoint)
end

-- Swaps every listed whole word in one left-to-right pass. A word is a run of
-- word characters, so a short form never matches inside a longer one ("brb"
-- leaves "brb2" alone) and a Cyrillic short form works as well.
--
-- One pass is deliberate: a replacement is written into the result and never
-- looked at again, so a rule can never expand inside its own output.
local function ExpandText(text)
	local rules = ns.expansionCache
	if not next(rules) then
		return text
	end
	-- Links and chat codes are left exactly as they are: rewriting inside one
	-- would break it, and a link can carry any text at all.
	if string.find(text, "|", 1, true) then
		return text
	end

	local pieces, kept, index, length = {}, 1, 1, #text
	local changed = false
	local used
	while index <= length do
		local byte, codepoint, nextIndex = CharacterAt(text, index)
		if byte and IsExpansionWordChar(byte, codepoint) then
			-- Grow the run, one character at a time.
			local start = index
			index = nextIndex
			while index <= length do
				local nextByte, nextCodepoint, afterIndex = CharacterAt(text, index)
				if not nextByte or not IsExpansionWordChar(nextByte, nextCodepoint) then
					break
				end
				index = afterIndex
			end
			local word = string.sub(text, start, index - 1)
			local loweredWord = string.lower(word)
			local replacement = rules[loweredWord]
			if replacement then
				if start > kept then
					pieces[#pieces + 1] = string.sub(text, kept, start - 1)
				end
				pieces[#pieces + 1] = MatchCase(word, replacement)
				kept = index
				changed = true
				used = used or {}
				used[loweredWord] = (used[loweredWord] or 0) + 1
			end
		else
			-- Not a word character: copy it through and carry on.
			index = nextIndex or (index + 1)
		end
	end
	if not changed then
		return text
	end
	if kept <= length then
		pieces[#pieces + 1] = string.sub(text, kept)
	end
	local expanded = table.concat(pieces)
	if #expanded > EXPANSION_LINE_LIMIT then
		-- Better to send what the player typed than to have the client cut
		-- the line in half somewhere they did not expect.
		return text
	end
	-- Tallied only now: a line that was never sent is not a use.
	if used and ns.db and ns.db.expansionCounts then
		local counts = ns.db.expansionCounts
		for key, amount in pairs(used) do
			counts[key] = (counts[key] or 0) + amount
		end
	end
	if ns.RefreshExpansionCounts then
		pcall(ns.RefreshExpansionCounts)
	end
	return expanded
end

-- The callback the client runs just before it reads the edit box and sends
-- it. Only the text is replaced; everything that decides where the line goes
-- stays as the player set it.
local function OnPreSendText(_, editBox)
	if not ns.db or not ns.db.expansions or not ns.db.expansions.on then
		return
	end
	if not editBox then
		return
	end
	local text = editBox:GetText()
	if type(text) ~= "string" or text == "" then
		return
	end
	-- The client can hand addons a hidden ("secret") value; those are left
	-- alone rather than passed through string functions.
	if issecretvalue and issecretvalue(text) then
		return
	end
	local ok, expanded = pcall(ExpandText, text)
	if not ok or type(expanded) ~= "string" or expanded == text then
		return
	end
	editBox:SetText(expanded)
end

-- Registers the callback once. Returns true when it is in place; the caller
-- retries at login for clients where the registry is not ready this early.
function ns.InstallExpansionHook()
	if ns.expansionHookInstalled then
		return true
	end
	if not (EventRegistry and EventRegistry.RegisterCallback) then
		return false
	end
	local ok = pcall(EventRegistry.RegisterCallback, EventRegistry, "ChatFrame.OnEditBoxPreSendText", OnPreSendText)
	if ok then
		ns.expansionHookInstalled = true
	end
	return ns.expansionHookInstalled
end
