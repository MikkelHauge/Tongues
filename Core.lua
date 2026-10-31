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
--     first, so the shared machinery lives here; UI.lua adds the icon, the
--     options window and the two list windows on top of it.
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
--   * Functions named like ns.Something are shared with UI.lua too; plain
--     local functions stay private to this file.
--
-- Files:
--   * Core.lua (this file): defaults, the script table, the UTF-8 walker,
--     the chat filter and its counters, the word list, the text expansions,
--     events, commands.
--   * UI.lua: the icon, the options window, the blocked words window and the
--     text expansions window.
--------------------------------------------------------------------------------
local addonName, ns = ...

-- Lowered copies of the blocked words, kept here so every incoming message
-- does not have to lowercase the whole list again.
ns.loweredWords = {}

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
-- Reading scripts out of a message
--------------------------------------------------------------------------------
-- Chat messages arrive as UTF-8, where a letter outside plain ASCII is a
-- small sequence of bytes. To tell Cyrillic from Chinese (and to give each
-- its own counter) the message is walked character by character: every
-- character is turned back into its Unicode number and looked up in the
-- tables below.

-- Reads one UTF-8 character starting at byte index i and returns its
-- codepoint and the index of the next character. A damaged sequence is
-- treated as its first byte, so the walk never errors or loops forever.
--
-- UTF-8 packs a character into 1-4 bytes. The first byte says how many
-- follow and carries the top bits of the codepoint; every following byte
-- starts with the bits 10 and carries six more bits:
--   0xxxxxxx                               -> 1 byte,   7 bits (ASCII)
--   110xxxxx 10xxxxxx                      -> 2 bytes, 11 bits
--   1110xxxx 10xxxxxx 10xxxxxx             -> 3 bytes, 16 bits
--   11110xxx 10xxxxxx 10xxxxxx 10xxxxxx    -> 4 bytes, 21 bits
-- The formulas below rebuild the number exactly from that layout: each
-- byte's leftover low bits are shifted into place with * and +.
local function NextCodepoint(text, i)
	local first = string.byte(text, i)
	if not first then
		return nil
	end
	if first < 0x80 then
		-- Plain ASCII: every Latin letter, digit and punctuation mark a
		-- chat line normally contains.
		return first, i + 1
	end
	local second = string.byte(text, i + 1)
	if first >= 0xF0 then
		-- Four bytes. The low three bits of the first byte (what - 0xF0
		-- leaves over) are the top of a 21-bit number. Used by emoji and
		-- the rarer CJK extensions.
		local third = string.byte(text, i + 2)
		local fourth = string.byte(text, i + 3)
		if not (second and third and fourth) then
			return first, i + 1
		end
		return (first - 0xF0) * 0x40000 + (second - 0x80) * 0x1000 + (third - 0x80) * 0x40 + (fourth - 0x80), i + 4
	elseif first >= 0xE0 then
		-- Three bytes: everything from Cyrillic and Greek up to Chinese,
		-- Japanese and Korean.
		local third = string.byte(text, i + 2)
		if not (second and third) then
			return first, i + 1
		end
		return (first - 0xE0) * 0x1000 + (second - 0x80) * 0x40 + (third - 0x80), i + 3
	elseif first >= 0xC0 then
		-- Two bytes: most Latin accents (e, u, o with accents), Cyrillic
		-- letters and the like.
		if not second then
			return first, i + 1
		end
		return (first - 0xC0) * 0x40 + (second - 0x80), i + 2
	end
	-- A stray continuation byte on its own: skip it.
	return first, i + 1
end

-- Kana - hiragana and katakana - are the characters Japanese does not share
-- with Chinese, so they are what tells a Japanese line from a Chinese one
-- that happens to use the same kanji.
local function IsKana(cp)
	return (cp >= 0x3040 and cp <= 0x30FF)   -- hiragana and katakana
		or (cp >= 0x31F0 and cp <= 0x31FF)  -- katakana phonetic extensions
		or (cp >= 0xFF66 and cp <= 0xFF9D)  -- halfwidth katakana
end

-- Digits and punctuation that share a Unicode block with a script's letters.
-- They are not evidence of that script: a line made of Arabic-Indic digits or
-- a bare Arabic question mark must not be hidden by the Arabic checkbox.
-- Only the marks that actually sit in the middle of a block are listed, so a
-- letter can never be caught here by accident.
local function IsScriptSeparator(cp)
	-- Arabic: sign characters, punctuation, and both sets of digits.
	if (cp >= 0x0600 and cp <= 0x0605) or (cp >= 0x060C and cp <= 0x060D)
		or (cp >= 0x061B and cp <= 0x061F) or (cp >= 0x0660 and cp <= 0x066D)
		or (cp >= 0x06D4 and cp <= 0x06D4) or (cp >= 0x06DD and cp <= 0x06DD)
		or (cp >= 0x06F0 and cp <= 0x06F9) then
		return true
	end
	-- Thai: digits and the two punctuation marks beside them.
	if (cp >= 0x0E4F and cp <= 0x0E4F) or (cp >= 0x0E50 and cp <= 0x0E5B) then
		return true
	end
	-- Hebrew: punctuation, cantillation and the Yiddish quotes.
	if (cp >= 0x05BE and cp <= 0x05C7) or (cp >= 0x05F3 and cp <= 0x05F4) then
		return true
	end
	-- Greek: the question mark that looks like a semicolon, and friends.
	if (cp >= 0x0374 and cp <= 0x0375) or (cp >= 0x037E and cp <= 0x037E)
		or (cp >= 0x0384 and cp <= 0x0385) or (cp >= 0x0387 and cp <= 0x0387) then
		return true
	end
	-- Armenian: its own question mark and abbreviation marks.
	if (cp >= 0x055A and cp <= 0x055F) or (cp >= 0x0589 and cp <= 0x058A) then
		return true
	end
	return false
end

-- Which script a character belongs to, or nil for everything that should
-- stay visible: Latin letters (accents included), digits, punctuation,
-- symbols, emoji and the like. Only letter blocks are listed on purpose -
-- catching a normal en dash or a smiley would only hide friendly chat.
local function ClassifyCodepoint(cp)
	-- Punctuation and digits that borrow a letter block are not letters.
	if IsScriptSeparator(cp) then
		return nil
	end
	-- Russian: Cyrillic and its less common extensions.
	if (cp >= 0x0400 and cp <= 0x052F)
		or (cp >= 0x1C80 and cp <= 0x1C8F)
		or (cp >= 0x2DE0 and cp <= 0x2DFF)
		or (cp >= 0xA640 and cp <= 0xA69F) then
		return "russian"
	end
	-- Japanese: hiragana, katakana and their extensions.
	if IsKana(cp) then
		return "japanese"
	end
	-- Chinese: the shared CJK ideographs. Japanese writes them as kanji, so
	-- the filter re-reads them as Japanese when the line also carries kana
	-- (see GetFilterReason) - on their own they are indistinguishable from
	-- Chinese.
	if (cp >= 0x3400 and cp <= 0x4DBF)
		or (cp >= 0x4E00 and cp <= 0x9FFF)
		or (cp >= 0xF900 and cp <= 0xFAFF)
		or (cp >= 0x20000 and cp <= 0x323FF) then
		return "chinese"
	end
	-- Korean: hangul syllables, jamo and halfwidth hangul.
	if (cp >= 0xAC00 and cp <= 0xD7AF)
		or (cp >= 0x1100 and cp <= 0x11FF)
		or (cp >= 0x3130 and cp <= 0x318F)
		or (cp >= 0xFFA0 and cp <= 0xFFDC) then
		return "korean"
	end
	-- Greek, including the polytonic (accented) block used by older texts.
	if (cp >= 0x0370 and cp <= 0x03FF)
		or (cp >= 0x1F00 and cp <= 0x1FFF) then
		return "greek"
	end
	-- Hebrew.
	if (cp >= 0x0590 and cp <= 0x05FF)
		or (cp >= 0xFB1D and cp <= 0xFB4F) then
		return "hebrew"
	end
	-- Arabic and its supplements and presentation forms.
	if (cp >= 0x0600 and cp <= 0x06FF)
		or (cp >= 0x0750 and cp <= 0x077F)
		or (cp >= 0x08A0 and cp <= 0x08FF)
		or (cp >= 0xFB50 and cp <= 0xFDFF)
		or (cp >= 0xFE70 and cp <= 0xFEFF) then
		return "arabic"
	end
	-- Thai.
	if cp >= 0x0E00 and cp <= 0x0E7F then
		return "thai"
	end
	-- Styled Latin: the "fancy font" letters pasted instead of plain A-Z.
	-- Gold spammers use these to dodge word filters, and nothing else in
	-- normal chat looks like them: mathematical bold/italic/script letters,
	-- the modifier letters used as small capitals, and enclosed or squared
	-- Latin letters. Flag emoji (U+1F1E6 and up) sit just past the last of
	-- those and are deliberately not caught.
	if (cp >= 0x1D00 and cp <= 0x1D7F)      -- phonetic and modifier letters
		or (cp >= 0x1D400 and cp <= 0x1D7FF) -- mathematical alphanumerics
		or (cp >= 0x1F100 and cp <= 0x1F1AD) -- enclosed and squared letters
		then
		return "styled"
	end
	-- Symbols and emoji are deliberately not a script of their own: the chat
	-- font cannot draw most of them, so the "hide anything the font cannot
	-- draw" catch-all is what catches them (see IsDrawableCodepoint).
	-- Everything else that is a real letter script but rarer in chat;
	-- this is what the "Other scripts" checkbox catches.
	if (cp >= 0x0530 and cp <= 0x058F)     -- Armenian
		or (cp >= 0x0700 and cp <= 0x074F) -- Syriac
		or (cp >= 0x0780 and cp <= 0x07FF) -- Thaana and N'Ko
		or (cp >= 0x0900 and cp <= 0x0DFF) -- Indic (Devanagari to Sinhala)
		or (cp >= 0x0E80 and cp <= 0x0EFF) -- Lao
		or (cp >= 0x0F00 and cp <= 0x0FFF) -- Tibetan
		or (cp >= 0x1000 and cp <= 0x109F) -- Myanmar
		or (cp >= 0x10A0 and cp <= 0x10FF) -- Georgian
		or (cp >= 0x1200 and cp <= 0x139F) -- Ethiopic
		or (cp >= 0x13A0 and cp <= 0x13FF) -- Cherokee
		or (cp >= 0x1780 and cp <= 0x17FF) -- Khmer
		or (cp >= 0x1800 and cp <= 0x18AF) -- Mongolian
		or (cp >= 0x1C90 and cp <= 0x1CBF) -- Georgian extended
		or (cp >= 0x2D00 and cp <= 0x2D2F) -- Georgian supplement
		or (cp >= 0xFF21 and cp <= 0xFF3A) -- fullwidth Latin capitals
		or (cp >= 0xFF41 and cp <= 0xFF5A) -- fullwidth Latin small letters
		then
		return "other"
	end
	return nil
end

-- True when a byte is part of a word, for the whole-word matching below:
-- ASCII letters, digits and the underscore, plus anything non-ASCII, so a
-- word never splits in the middle of a Cyrillic or Chinese character.
-- The broad "anything non-ASCII" rule is deliberate: telling an accented
-- letter from an em dash or an emoji would mean decoding the neighbouring
-- character as well, and the misses it can cause (a symbol glued straight
-- onto the word with no space between) are rare in real chat.
local function IsWordByte(byte)
	if not byte then
		return false
	end
	if byte >= 128 then
		return true
	end
	if (byte >= 48 and byte <= 57)     -- 0-9
		or (byte >= 65 and byte <= 90)  -- A-Z
		or (byte >= 97 and byte <= 122) -- a-z
		or byte == 95 then              -- _
		return true
	end
	return false
end

-- Punctuation and symbols that should count as a break between words even
-- though they are not ASCII spaces. They matter because IsWordByte treats
-- every non-ASCII byte as part of a word, which would otherwise make a word
-- glued to an em dash, a curly quote or an emoji unmatchable:
--   WTS gold—cheap      wtf😂      “gold”
-- Combining marks are deliberately absent - they belong to the letter they
-- sit on, and treating them as a break would split accented words.
local function IsWordSeparator(cp)
	return (cp >= 0x2000 and cp <= 0x2064)   -- spaces, dashes, quotes, ellipsis
		or (cp >= 0x2190 and cp <= 0x2BFF)   -- arrows, maths, dingbats, symbols
		or (cp >= 0x3000 and cp <= 0x303F)   -- CJK punctuation
		or (cp >= 0xFE00 and cp <= 0xFE0F)   -- variation selectors
		or (cp >= 0x1F000 and cp <= 0x1FAFF) -- emoji and pictographs
		or (cp >= 0xFF01 and cp <= 0xFF20)   -- fullwidth punctuation
		or (cp >= 0xFF3B and cp <= 0xFF40)
		or (cp >= 0xFF5B and cp <= 0xFF65)
		or cp == 0x00A0 or cp == 0x00AB or cp == 0x00BB or cp == 0x00B7
		or cp == 0x037E or cp == 0x0387
		or cp == 0xFEFF
end

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
	return (NextCodepoint(text, index))
end

-- True when the message starts, or a separating character, sits just before
-- the match. A stray continuation byte keeps the old "part of a word" answer.
local function BoundaryBefore(text, position)
	if position <= 1 then
		return true
	end
	local codepoint = CodepointBefore(text, position)
	if codepoint and IsWordSeparator(codepoint) then
		return true
	end
	return not IsWordByte(string.byte(text, position - 1))
end

-- The same check on the far side: end of message, separator, or a non-word
-- byte such as a space, brackets or punctuation.
local function BoundaryAfter(text, position)
	local byte = string.byte(text, position)
	if not byte then
		return true
	end
	if byte >= 0x80 then
		local codepoint = NextCodepoint(text, position)
		if codepoint and IsWordSeparator(codepoint) then
			return true
		end
		return false
	end
	return not IsWordByte(byte)
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

-- True when any character from `position` onwards is kana. A line that
-- carries kana is Japanese chat, so its ideographs are kanji, not Chinese:
-- this is what keeps the two filters from overlapping.
local function ContainsKana(text, position)
	while true do
		local codepoint
		codepoint, position = NextCodepoint(text, position)
		if not codepoint then
			return false
		end
		if IsKana(codepoint) then
			return true
		end
	end
end

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

-- The characters the game's chat font can actually draw. The fonts that
-- ship with the client cover Latin (accents included), Greek and Cyrillic
-- plus ordinary punctuation and currency; they have no glyphs for CJK,
-- kana, Korean, Hebrew, Arabic, Thai or emoji, which is why those are drawn
-- as empty boxes. The font cannot be asked what it supports, so this is the
-- list; anything outside it is treated as unreadable.
local function IsDrawableCodepoint(cp)
	return cp < 0x0250                       -- ASCII, Latin-1 and Latin Extended
		or (cp >= 0x0300 and cp <= 0x036F)   -- combining marks on those letters
		or (cp >= 0x0370 and cp <= 0x03FF)   -- Greek
		or (cp >= 0x0400 and cp <= 0x052F)   -- Cyrillic
		or (cp >= 0x1F00 and cp <= 0x1FFF)   -- Greek extended
		or (cp >= 0x2000 and cp <= 0x206F)   -- dashes, quotes, ellipsis, bullet
		or (cp >= 0x20A0 and cp <= 0x20BF)   -- currency signs
		or (cp >= 0x2100 and cp <= 0x214F)   -- letterlike signs (tm, no., ...)
end

-- True when the message holds a character that would be drawn as a box.
local function ContainsUndrawable(text)
	local position = 1
	while true do
		local codepoint
		codepoint, position = NextCodepoint(text, position)
		if not codepoint then
			return false
		end
		if not IsDrawableCodepoint(codepoint) then
			return true
		end
	end
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
	return string.find(lowered, "ui-raittargetingicon_", 1, true) ~= nil
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
			plain = string.lower(MaskLinkTargets(message))
			stripped = string.lower(StripChatCodes(message))
		end
		local wholeWords = ns.db.wordFilter.wholeWords ~= false
		for index = 1, #words do
			local word = words[index]
			local hit
			if wholeWords then
				hit = ContainsWholeWord(plain, word)
					or (stripped ~= plain and ContainsWholeWord(stripped, word))
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
		codepoint, position = NextCodepoint(message, position)
		if not codepoint then
			break
		end
		local script = ClassifyCodepoint(codepoint)
		if script == "chinese" then
			if hasKana == nil then
				hasKana = ContainsKana(message, 1)
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
	if ns.db.unreadable and ContainsUndrawable(message) then
		return "unreadable"
	end
	return nil
end

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

-- Event name -> group key, for the filter below.
local EVENT_GROUP = {}
for index = 1, #CHANNEL_GROUPS do
	local group = CHANNEL_GROUPS[index]
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
local warnedNoFilterAPI = false
local warnedNoExpansionHook = false
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
-- Word list management
--------------------------------------------------------------------------------

-- Rebuilds the pre-lowered copy of the word list; called whenever the list
-- changes and after login. string.lower only knows A-Z, so matching is
-- case-insensitive for the Latin alphabet only; a word written in another
-- script must match its case exactly - which hardly matters, since whole
-- messages in that script can be hidden with the script checkbox instead.
function ns.RefreshWordFilterCache()
	local cache = {}
	local words = ns.db and ns.db.wordFilter.words or {}
	for index = 1, #words do
		cache[index] = string.lower(words[index])
	end
	ns.loweredWords = cache
end

-- Adds a word; false plus a reason when it is empty or already there. A
-- word pasted straight out of chat can still carry colour codes, so those
-- are taken out first - otherwise it could never match anything.
function ns.AddWordFilter(word)
	word = ns.Trim(StripChatCodes(word or ""))
	if word == "" then
		return false, "empty"
	end
	local loweredWord = string.lower(word)
	local words = ns.db.wordFilter.words
	for index = 1, #words do
		if string.lower(words[index]) == loweredWord then
			return false, "duplicate"
		end
	end
	table.insert(words, word)
	ns.RefreshWordFilterCache()
	return true
end

-- Removes one exact word from the list, along with its tally.
function ns.RemoveWordFilter(word)
	local words = ns.db.wordFilter.words
	for index = 1, #words do
		if words[index] == word then
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
local function ClampExpansionText(text, limit)
	text = ns.Trim(text or "")
	if #text > limit then
		text = string.sub(text, 1, limit)
		local last = string.byte(text, #text)
		while last and last >= 0x80 and last < 0xC0 do
			text = string.sub(text, 1, #text - 1)
			last = string.byte(text, #text)
		end
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
	for index = #rules, 1, -1 do
		local rule = rules[index]
		if type(rule) ~= "table" or type(rule.key) ~= "string" or type(rule.value) ~= "string" then
			table.remove(rules, index)
		end
	end
	for index = 1, #rules do
		local rule = rules[index]
		local key = string.lower(ns.Trim(rule.key))
		if key ~= "" then
			cache[key] = rule.value
		end
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
			rule.key, rule.value = key, value
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
	rule.key, rule.value = key, value
	ns.RefreshExpansionCache()
	return true
end

-- Removes one rule by its table, so a row always deletes what it shows.
function ns.RemoveExpansion(rule)
	local rules = ns.db.expansions.rules
	for index = 1, #rules do
		if rules[index] == rule then
			table.remove(rules, index)
			ns.RefreshExpansionCache()
			return true
		end
	end
	return false
end

-- Empties the whole list.
function ns.ClearExpansions()
	wipe(ns.db.expansions.rules)
	ns.RefreshExpansionCache()
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
	local codepoint, nextIndex = NextCodepoint(text, index)
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
		return IsWordByte(byte)
	end
	return not IsWordSeparator(codepoint)
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
			local replacement = rules[string.lower(word)]
			if replacement then
				if start > kept then
					pieces[#pieces + 1] = string.sub(text, kept, start - 1)
				end
				pieces[#pieces + 1] = MatchCase(word, replacement)
				kept = index
				changed = true
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

--------------------------------------------------------------------------------
-- Counters
--------------------------------------------------------------------------------

-- Back to zero, everywhere: the options window's Reset counters button and
-- /tongues resetcounters both land here.
function ns.ResetCounters()
	for index = 1, #LANGUAGES do
		ns.db.counters[LANGUAGES[index].key] = 0
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
	for index = 1, #LANGUAGES do
		local entry = LANGUAGES[index]
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
	for index = 1, #LANGUAGES do
		total = total + (counters[LANGUAGES[index].key] or 0)
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
	for index = 1, #LANGUAGES do
		if LANGUAGES[index].key == reason then
			return LANGUAGES[index].counter
		end
	end
	return tostring(reason)
end

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

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- The hello when the world is ready: the master switch and the grand total
-- of everything blocked so far, printed once per session. The checkbox in
-- the window ("Say hello on login") turns it off without touching anything
-- else.
local function PrintWelcome()
	if ns.db.greeting == false then
		return
	end
	if ns.db.enabled then
		ns.Print("Filtering enabled. /tongues opens the options.")
	else
		ns.Print("Filtering disabled. /tongues opens the options.")
	end
	local total = ns.GetTotalBlocked()
	if total == 0 then
		ns.Print("Nothing blocked so far.")
	elseif total == 1 then
		ns.Print("You have blocked 1 message so far.")
	else
		ns.Print("You have blocked "..ns.FormatCount(total).." messages so far.")
	end
end

-- One frame listens for everything. ADDON_LOADED arrives first and is where
-- the saved settings are read and the UI is built; PLAYER_LOGIN and
-- PLAYER_ENTERING_WORLD get a second chance to hook the chat filters, for
-- clients where the chat machinery is not ready quite as early.
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
		TonguesDB = TonguesDB or {}
		ns.db = TonguesDB
		ApplyDefaults(ns.db, DEFAULTS)
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
		TryRegisterChatFilters()
		ns.InstallExpansionHook()
		return
	end
	if not ns.db then
		return
	end
	if event == "PLAYER_LOGIN" then
		TryRegisterChatFilters()
		ns.InstallExpansionHook()
		-- The minimap has its real size by now: put the icon back on its
		-- ring at the saved angle (the first apply can run before layout).
		if ns.ApplyIconPosition then
			ns.ApplyIconPosition()
		end
		PrintWelcome()
	elseif event == "PLAYER_ENTERING_WORLD" then
		local filtersReady = TryRegisterChatFilters()
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
