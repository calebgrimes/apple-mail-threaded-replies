-- mail-draft.applescript: create an Apple Mail DRAFT (never transmits).
--
-- Usage:
--   osascript applescript/mail-draft.applescript SUBJECT SENDER TO_CSV CC_CSV BODY_FILE ATTACHMENT_OR_EMPTY [--pre-html]
--
--   SUBJECT             plain text subject line
--   SENDER              an account address configured in Mail (e.g. you@example.com)
--   TO_CSV              comma-separated recipient addresses
--   CC_CSV              comma-separated cc addresses ("" for none)
--   BODY_FILE           path to a UTF-8 file holding the body. Plain text / light
--                       markdown by default; pass --pre-html if it already holds HTML.
--   ATTACHMENT_OR_EMPTY one absolute path, several joined by "|", or "" for none
--
-- Prints "saved draft: SUBJECT (N chars)" on success. Errors loudly if the body
-- did not land, because Mail will save an empty compose window without complaint.
--
-- WHY THIS DOES NOT USE THE `content` PROPERTY
-- --------------------------------------------
-- Apple Mail 16 (macOS 15.4) wraps ANY body supplied through the AppleScript
-- `content` property in <blockquote type="cite"> inside an
-- Apple-Mail-URLShareWrapperClass div, and emits a ">"-prefixed text/plain
-- alternative. Gmail and iOS Mail treat blockquote type="cite" as quoted history
-- and collapse it behind "show trimmed content" / "show history", so the recipient
-- opens what looks like an empty message; clients that render the quote indent the
-- whole body. Verified 2026-07-29 on new messages and on replies, on both
-- construction paths (creation properties and `set content`), with the plain-text
-- composing preference on and off, and in mail already delivered to clients.
--
-- The escape is to paste real HTML into the compose window body, which is what
-- Mail itself does when you type. See lib/text-to-mail-html.py.
-- Attachments go through the File > Attach Files… menu for the same reason: the
-- AppleScript attachment verb writes through `content` and re-wraps the body.
--
-- SAFETY: this script only ever `save`s to Drafts. There is intentionally no
-- transmit verb anywhere in it. You review and send every draft by hand.

property maxAttempts : 3

on run argv
	set theSubject to item 1 of argv
	set theSender to item 2 of argv
	set toCSV to item 3 of argv
	set ccCSV to item 4 of argv
	set bodyFile to item 5 of argv
	set attachPath to item 6 of argv

	set preHTML to ""
	if (count of argv) > 6 then
		if item 7 of argv is "--pre-html" then set preHTML to " --pre-html"
	end if

	-- Body -> Mail-native HTML -> hex, for the «data HTML...» clipboard flavor.
	set libDir to my scriptDir()
	set hexData to do shell script "/usr/bin/python3 " & quoted form of (libDir & "text-to-mail-html.py") & " " & quoted form of bodyFile & preHTML
	if hexData is "" then error "mail-draft: body conversion produced nothing for " & bodyFile

	-- Longest plain line of the body, used as the proof-of-paste needle. Skips
	-- markup-only and list-marker lines so the needle is real prose from the body.
	-- One distinctive phrase from the body, handed to the verifier as proof the
	-- paste actually landed. See lib/body-needle.py.
	set bodyNeedle to ""
	try
		set bodyNeedle to do shell script "/usr/bin/python3 " & quoted form of (libDir & "body-needle.py") & " " & quoted form of bodyFile
	end try

	-- Preserve whatever the user had on the clipboard, across all flavors.
	set savedClip to missing value
	try
		set savedClip to the clipboard as record
	end try

	set bodyLen to 0
	set lastErr to ""
	repeat with attempt from 1 to maxAttempts
		try
			my discardDraft(theSubject, toCSV)
			my composeAndPaste(theSubject, theSender, toCSV, ccCSV, hexData)

			if attachPath is not "" then
				set AppleScript's text item delimiters to "|"
				set attachParts to text items of attachPath
				set AppleScript's text item delimiters to ""
				repeat with ap in attachParts
					set apt to my trimText(ap as text)
					if apt is not "" then my attachViaMenu(theSubject, apt)
				end repeat
			end if

			tell application "Mail"
				set theMsg to first outgoing message whose subject is theSubject
				delay 1
				save theMsg
				delay 1
				try
					close theMsg saving no
				end try
			end tell
			delay 1

			-- The only honest witness: the .emlx Mail just wrote. A clean return from
			-- `save` proves nothing, and `content of msg` reads back empty for a body
			-- that arrived by paste.
			set bodyLen to my verifyDraftBody(theSubject, bodyNeedle)
			if bodyLen < 20 then
				set lastErr to "body did not land (" & bodyLen & " chars)"
			else
				-- The body verifier only reads the text/html part, so a run that attached
				-- nothing would still look clean here. Check the payload landed as well.
				set attachErr to my verifyDraftAttachments(theSubject, attachPath)
				if attachErr is "" then exit repeat
				set bodyLen to 0
				set lastErr to "attachment did not land: " & attachErr
			end if
		on error errMsg
			set lastErr to errMsg
		end try
		delay 1
	end repeat

	my restoreClip(savedClip)

	if bodyLen < 20 then
		-- Leave the last attempt in place rather than discarding it, matching
		-- mail-reply. A false negative here is not hypothetical:
		-- a needle bug once failed every verification while the paste was
		-- landing perfectly, and this line deleted three correct drafts,
		-- three times per run, leaving nothing to inspect and no way to see
		-- that the body had been fine all along. Nothing transmits either way, so
		-- the cost of keeping a bad draft is one manual delete; the cost of
		-- discarding a good one is the work plus the diagnosis.
		error "mail-draft: could not stage \"" & theSubject & "\" after " & maxAttempts & " attempts (" & lastErr & "). Nothing was transmitted. The last attempt was LEFT IN DRAFTS so you can see what actually landed; delete it if it is junk."
	end if

	return "saved draft: " & theSubject & " (" & bodyLen & " chars)"
end run

-- Create the compose window and paste the body into it.
on composeAndPaste(subj, theSender, toCSV, ccCSV, hexData)
	-- The «data HTML...» clipboard flavor is a literal token, so the hex has to be
	-- compiled in rather than concatenated.
	run script "set the clipboard to «data HTML" & hexData & "»"

	tell application "Mail"
		activate
		-- No `content` here on purpose. The body arrives by paste, below.
		set theMsg to make new outgoing message with properties {subject:subj, sender:theSender, visible:true}
		tell theMsg
			repeat with addr in my splitTrim(toCSV)
				if addr is not "" then make new to recipient at end of to recipients with properties {address:addr}
			end repeat
			repeat with addr in my splitTrim(ccCSV)
				if addr is not "" then make new cc recipient at end of cc recipients with properties {address:addr}
			end repeat
		end tell
	end tell

	delay 1.5

	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			delay 0.4
			set win to my composeWindow(subj)
			perform action "AXRaise" of win
			delay 0.6

			-- A fresh compose window focuses the To: field, so a naive cmd-V lands in
			-- the address bar and silently does nothing. Move focus to the body, which
			-- is the AXScrollArea nested two AXGroups deep.
			set bodyArea to missing value
			repeat with g in (UI elements of win whose role is "AXGroup")
				try
					repeat with g2 in (UI elements of g)
						try
							set bodyArea to (first UI element of g2 whose role is "AXScrollArea")
							exit repeat
						end try
					end repeat
				end try
				if bodyArea is not missing value then exit repeat
			end repeat
			if bodyArea is missing value then error "could not locate the compose body area"

			set focused of bodyArea to true
			delay 0.5
			keystroke "v" using {command down}
			delay 1.5
		end tell
	end tell
end composeAndPaste

-- Attach one file through File > Attach Files…, navigating with Go to Folder.
-- Menu-driven rather than the toolbar button, which does not reliably register.
on attachViaMenu(subj, filePath)
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			set win to my composeWindow(subj)
			perform action "AXRaise" of win
			delay 0.5
			click menu item "Attach Files…" of menu 1 of menu bar item "File" of menu bar 1

			-- Wait for the open panel, which Mail presents as a sheet on the window.
			set panelUp to false
			repeat with i from 1 to 40
				if (count of sheets of win) > 0 then
					set panelUp to true
					exit repeat
				end if
				delay 0.25
			end repeat
			if not panelUp then error "the Attach Files panel never opened"

			-- Paste the path, never type it. Go To Folder autocompletes as you type,
			-- and a path containing spaces ("Some Folder/My Report ....pdf") gets
			-- silently rewritten into something that resolves to a folder or to
			-- nothing, after which the panel closes having attached no file.
			-- Verified failure 2026-07-29.
			--
			-- Every wait below polls for the state it needs rather than sleeping a
			-- fixed interval. The old fixed delays worked for one attachment and
			-- dropped roughly one in three when called in a loop: the Go To Folder
			-- field had not taken focus yet, so cmd-V went to the file list as a
			-- type-select query and the subsequent return dismissed the panel having
			-- attached nothing, silently. In one run only 2 of 3 files landed.
			set the clipboard to filePath
			delay 0.3
			keystroke "g" using {command down, shift down}

			set gotoField to missing value
			repeat with i from 1 to 40
				set gotoField to my gotoFolderField(win)
				if gotoField is not missing value then exit repeat
				delay 0.25
			end repeat
			if gotoField is missing value then error "the Go To Folder field never appeared"
			delay 0.3

			keystroke "v" using {command down}

			-- Do not press return until the field actually holds the whole path.
			set pathLanded to false
			repeat with i from 1 to 25
				try
					if (value of gotoField as text) is filePath then
						set pathLanded to true
						exit repeat
					end if
				end try
				delay 0.2
			end repeat
			if not pathLanded then
				-- Setting the value is atomic, so it cannot trip the autocomplete
				-- that makes character-by-character typing unsafe here.
				try
					set value of gotoField to filePath
					delay 0.4
				end try
				try
					if (value of gotoField as text) is not filePath then ¬
						error "Go To Folder would not accept " & filePath
				end try
			end if

			keystroke return

			-- Wait for Go To Folder to close and hand focus back to the open panel
			-- with the file selected, then commit. Pressing return into a panel that
			-- has not caught up yet is the other half of the dropped-attachment bug.
			repeat with i from 1 to 40
				if my gotoFolderField(win) is missing value then exit repeat
				delay 0.25
			end repeat
			delay 0.6
			keystroke return

			-- Wait for the panel to dismiss before touching the window again.
			set panelClosed to false
			repeat with i from 1 to 40
				if (count of sheets of win) is 0 then
					set panelClosed to true
					exit repeat
				end if
				delay 0.25
			end repeat
			if not panelClosed then error "the Attach Files panel never closed for " & filePath
			delay 1
		end tell
	end tell
end attachViaMenu

-- The Go To Folder prompt, or `missing value` while it is absent. macOS renders it
-- as a sheet on the open panel (itself a sheet on the compose window) holding one
-- combo box; older builds use a plain text field, so accept either. Its presence is
-- the signal that cmd-V will land in the path field and not in the file list.
on gotoFolderField(win)
	tell application "System Events"
		try
			repeat with panel in sheets of win
				repeat with prompt in sheets of panel
					try
						return (first UI element of prompt whose role is "AXComboBox")
					end try
					try
						return (first UI element of prompt whose role is "AXTextField")
					end try
				end repeat
				-- Some builds put the prompt straight onto the panel.
				try
					return (first UI element of panel whose role is "AXComboBox")
				end try
			end repeat
		end try
		return missing value
	end tell
end gotoFolderField

on composeWindow(subj)
	tell application "System Events"
		tell process "Mail"
			repeat with attempt from 1 to 25
				try
					return (first window whose name contains subj)
				on error
					delay 0.3
				end try
			end repeat
			error "compose window for \"" & subj & "\" never appeared"
		end tell
	end tell
end composeWindow

-- Close any compose window and delete any saved draft carrying this subject, so a
-- retry cannot leave a half-written duplicate behind. Matches by subject, never by
-- window position.
-- Clear this run's own prior attempt before retrying. Matches on subject AND
-- recipient, never subject alone.
--
-- Subject alone is not an identity. A batch job that titles every message the
-- same way (for example "Call notes: MM.DD.YY") makes drafts with identical
-- subjects for different people. One run staged a finished draft for person A,
-- then began person B's, and this handler deleted A's finished draft before the
-- first attempt. The recipient is what actually distinguishes them.
on discardDraft(subj, toCSV)
	set wanted to ""
	try
		set addrList to my splitTrim(toCSV)
		if (count of addrList) > 0 then set wanted to my trimText(item 1 of addrList)
	end try

	tell application "Mail"
		repeat with om in (every outgoing message)
			try
				if subject of om is subj and my recipientMatches(om, wanted) then ¬
					close om saving no
			end try
		end repeat
		repeat with a in every account
			try
				-- Collect first, delete second. Deleting out of the collection being
				-- iterated makes the loop skip elements, and the enclosing `try` hides
				-- it: three test drafts piled up because
				-- each retry's cleanup silently did nothing.
				set doomed to {}
				repeat with m in (every message of mailbox "Drafts" of a whose subject is subj)
					try
						if my recipientMatches(m, wanted) then set end of doomed to m
					end try
				end repeat
				repeat with m in doomed
					try
						delete m
					end try
				end repeat
			end try
		end repeat
	end tell
	delay 0.5
end discardDraft

-- True when the message is addressed to `wanted`. An empty `wanted` means the
-- caller gave no recipient to disambiguate by, so fall back to subject-only
-- behaviour rather than refusing to clean up. A draft carrying no recipients at
-- all is a failed attempt of ours and is always fair game.
on recipientMatches(msg, wanted)
	if wanted is "" then return true
	tell application "Mail"
		try
			set addrs to (address of every to recipient of msg)
			if (count of addrs) is 0 then return true
			repeat with a in addrs
				if (a as text) is wanted then return true
			end repeat
			return false
		on error
			return true
		end try
	end tell
end recipientMatches

-- Read the saved draft's HTML part off disk and return its length. Returns 0 if the
-- body is missing, empty, or carries the quote-wrapping fingerprint.
-- Poll rather than sample once: Mail writes the .emlx a beat after `save` returns,
-- and on an Exchange account that lag can outrun a single immediate check, which
-- would report a perfectly good draft as empty and get it deleted on retry.
-- "" when the attachments are on the draft (or none were asked for), else why not.
on verifyDraftAttachments(subj, attachPath)
	if attachPath is "" then return ""
	set libDir to my scriptDir()
	set AppleScript's text item delimiters to "|"
	set parts to text items of attachPath
	set AppleScript's text item delimiters to ""
	set argStr to ""
	repeat with ap in parts
		set apt to my trimText(ap as text)
		if apt is not "" then set argStr to argStr & " " & quoted form of apt
	end repeat
	if argStr is "" then return ""
	try
		do shell script "/usr/bin/python3 " & quoted form of (libDir & "verify-draft-attachments.py") & " " & quoted form of subj & argStr
		return ""
	on error errMsg
		return errMsg
	end try
end verifyDraftAttachments

-- The needle is a distinctive phrase from the body we meant to send. Length alone
-- is not proof the right text landed: once the user copied a spreadsheet cell
-- mid-run, the clipboard beat the paste, and a draft containing a stray cell value
-- verified clean at 250 chars and was reported as success. Any paste that loses the race now
-- fails loudly instead.
on verifyDraftBody(subj, needle)
	set libDir to my scriptDir()
	set cmd to "/usr/bin/python3 " & quoted form of (libDir & "verify-draft-body.py") & " " & quoted form of subj
	if needle is not "" then set cmd to cmd & " --needle " & quoted form of needle
	repeat with i from 1 to 24
		try
			set n to (do shell script cmd) as integer
			if n ≥ 20 then return n
		end try
		delay 0.5
	end repeat
	return 0
end verifyDraftBody

on restoreClip(savedClip)
	if savedClip is not missing value then
		try
			set the clipboard to savedClip
		end try
	end if
end restoreClip

-- Helpers live in <repo>/lib/, one level up from this script's folder.
on scriptDir()
	tell application "System Events"
		set p to POSIX path of (container of (container of (path to me)))
	end tell
	if p does not end with "/" then set p to p & "/"
	return p & "lib/"
end scriptDir

on splitTrim(csv)
	set AppleScript's text item delimiters to ","
	set rawParts to text items of csv
	set AppleScript's text item delimiters to ""
	set outList to {}
	repeat with p in rawParts
		set end of outList to my trimText(p as text)
	end repeat
	return outList
end splitTrim

on trimText(s)
	set wc to {" ", tab, return, linefeed}
	repeat while (length of s) > 0 and (character 1 of s) is in wc
		set s to text 2 thru -1 of s
	end repeat
	repeat while (length of s) > 0 and (character -1 of s) is in wc
		set s to text 1 thru -2 of s
	end repeat
	return s
end trimText
