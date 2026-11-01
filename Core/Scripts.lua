-- Tongues - reading scripts out of a message: the UTF-8 walker, the script
-- tables and the characters the chat font cannot draw.
local addonName, ns = ...

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
	-- (see GetFilterReason in Core/Filter.lua) - on their own they are
	-- indistinguishable from Chinese.
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

--------------------------------------------------------------------------------
-- Shared with the word matcher, the filter and the expansions.
--------------------------------------------------------------------------------
ns.NextCodepoint = NextCodepoint
ns.IsWordByte = IsWordByte
ns.IsWordSeparator = IsWordSeparator
ns.ClassifyCodepoint = ClassifyCodepoint
ns.ContainsKana = ContainsKana
ns.ContainsUndrawable = ContainsUndrawable
