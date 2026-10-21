-- mail-reply.applescript: stage a THREADED reply as an Apple Mail draft (never transmits).
--
-- Usage:
--   osascript applescript/mail-reply.applescript SRC_SUBJECT SENDER_MATCH BODY_FILE TO_OVERRIDE_OR_EMPTY [--all] [--pre-html]
--
--   SRC_SUBJECT   exact subject of the message being replied to
--   SENDER_MATCH  substring that identifies the sender of that message
--   BODY_FILE     UTF-8 file holding the reply body (plain text / light markdown,
--                 or HTML with --pre-html)
--   TO_OVERRIDE   single address to replace the recipients with, or "" to keep
--   --all         reply to all rather than the sender alone (use this on purpose:
--                 old threads carry CC'd people who may have left)
--
-- Prints "STAGED | <subject> | to=... | <N> chars" on success, errors otherwise.
--
-- WHY THIS DOES NOT USE THE `content` PROPERTY
-- --------------------------------------------
-- `set content of <reply>` in Apple Mail 16 (macOS 15.4) wraps the body in
-- <blockquote type="cite">, which Gmail and iOS Mail read as quoted history and
-- collapse behind "show trimmed content" / "show history", so the recipient opens
-- what looks like an empty reply. It also silently fails to commit at times, and
-- intermittently duplicates the first line. All three failure modes come from the
-- same write path, and all three go away when the body is pasted into the compose
-- window instead. Verified 2026-07-29.
--
-- Pasting also preserves the real quoted history that `reply` puts in the window,
-- which `set content` used to overwrite.
--
-- SAFETY: saves to Drafts only. There is intentionally no transmit verb here.

property maxAttempts : 3

on run argv
	set srcSubject to item 1 of argv
	set senderMatch to item 2 of argv
	set bodyFile to item 3 of argv
	set toOverride to item 4 of argv

	set replyAll to false
	set preHTML to ""
	repeat with i from 5 to (count of argv)
		if item i of argv is "--all" then set replyAll to true
		if item i of argv is "--pre-html" then set preHTML to " --pre-html"
	end repeat

	set libDir to my scriptDir()
	set hexData to do shell script "/usr/bin/python3 " & quoted form of (libDir & "text-to-mail-html.py") & " " & quoted form of bodyFile & preHTML
	if hexData is "" then error "mail-reply: body conversion produced nothing for " & bodyFile

	-- A phrase from our own text, used to prove the paste landed. The quoted history
	-- alone would otherwise be long enough to pass a length check.
	--
	-- An early version took the first 40 characters of the body verbatim. That is
	-- only a valid needle when the body opens with plain prose. A body that opens
	-- with a bullet gives "- Reviewing the numbers", and the renderer turns the marker
	-- into <li>, so the phrase is nowhere in the draft and every attempt fails.
	-- Parentheses and bare URLs caused the same bug. Now this script shares
	-- body-needle.py with mail-draft, which strips list markers and emphasis and
	-- skips any line with a link. A missing needle is survivable (the length check still
	-- runs), so failure here must not abort the staging run.
	set needle to ""
	try
		set needle to do shell script "/usr/bin/python3 " & quoted form of (libDir & "body-needle.py") & " " & quoted form of bodyFile
	end try

	set savedClip to missing value
	try
		set savedClip to the clipboard as record
	end try

	set replySubject to ""
	set rcp to ""
	set bodyLen to 0
	set lastErr to ""

	repeat with attempt from 1 to maxAttempts
		try
			set found to my findSource(srcSubject, senderMatch)
			if found is missing value then error "no message found with subject \"" & srcSubject & "\" from a sender containing \"" & senderMatch & "\""

			run script "set the clipboard to «data HTML" & hexData & "»"

			tell application "Mail"
				activate
				set r to reply found opening window true reply to all replyAll
				-- A reply window has to render the whole quoted history before the body
				-- will accept a paste. Pasting into a half-built window is what makes
				-- this path flaky, so wait longer here than a new message needs.
				delay 3.5
				set replySubject to subject of r
			end tell

			-- Mail puts the insertion point above the quoted history in a reply window,
			-- which is exactly where the body belongs, so paste without moving it.
			my pasteIntoReply(replySubject)

			tell application "Mail"
				set r to first outgoing message whose subject is replySubject
				-- Recipients are rewritten AFTER the paste. Editing them beforehand
				-- resets the compose window's editing state and the paste lands nowhere.
				if toOverride is not "" then
					tell r
						delete every to recipient
						make new to recipient at end of to recipients with properties {address:toOverride}
					end tell
					delay 0.8
				end if
				set rcp to ""
				repeat with x in to recipients of r
					set rcp to rcp & (address of x) & ";"
				end repeat
				delay 1
			end tell
			-- Save with a real Cmd+S keystroke, never `close r saving yes`. On the
			-- Exchange account the AppleScript verb returns success and silently
			-- discards the reply, no draft on disk, no error. That caused a
			-- week of missing replies. Cmd+S on the focused window saves for real; verified
			-- once against Mail's own message store on two threads, including
			-- one where `close saving yes` had just eaten the identical reply.
			my saveAndCloseWindow(replySubject)
			delay 2

			set bodyLen to my verifyDraftBody(replySubject, needle)
			if bodyLen ≥ 20 then exit repeat
			set lastErr to "body did not land (" & bodyLen & " chars)"
			-- Discard only to clear the way for another attempt. On the last one,
			-- leave the draft standing: a false negative here once deleted three
			-- good replies in a row, and an unverified draft you can
			-- read is always worth more than a tidy empty Drafts folder.
			if attempt < maxAttempts then my discardDraft(replySubject)
		on error errMsg
			set lastErr to errMsg
			try
				my discardDraft(replySubject)
			end try
		end try
		delay 1
	end repeat

	my restoreClip(savedClip)

	if bodyLen < 20 then
		error "mail-reply: could not stage a reply to \"" & srcSubject & "\" after " & maxAttempts & " attempts (" & lastErr & "). Nothing was transmitted."
	end if

	return "STAGED | " & replySubject & " | to=" & rcp & " | " & bodyLen & " chars"
end run

-- Look in the mailboxes a reply target actually lives in, newest match wins.
-- Iterating every mailbox of every account walks the whole Exchange store and takes
-- longer than osascript will wait, so the search is scoped and ordered instead.
on findSource(srcSubject, senderMatch)
	tell application "Mail"
		set boxes to {}
		try
			set end of boxes to inbox
		end try
		repeat with acct in accounts
			repeat with boxName in {"Archive", "Inbox", "Sent Items", "Later", "Starred"}
				try
					set end of boxes to (mailbox (boxName as text) of acct)
				end try
			end repeat
			-- Gmail accounts archive to the nested [Gmail]/All Mail, invisible to the flat names above
			try
				set end of boxes to (mailbox "All Mail" of mailbox "[Gmail]" of acct)
			end try
		end repeat

		set found to missing value
		set foundDate to date "Friday, January 1, 2010 at 12:00:00 AM"
		repeat with mb in boxes
			try
				repeat with m in (every message of mb whose subject is srcSubject)
					if (sender of m) contains senderMatch then
						if (date sent of m) > foundDate then
							set found to m
							set foundDate to date sent of m
						end if
					end if
				end repeat
			end try
			if found is not missing value then exit repeat
		end repeat
		return found
	end tell
end findSource

on pasteIntoReply(subj)
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			delay 0.4
			set win to missing value
			repeat with attempt from 1 to 25
				try
					set win to (first window whose name contains subj)
					exit repeat
				on error
					delay 0.3
				end try
			end repeat
			if win is missing value then error "reply window for \"" & subj & "\" never appeared"
			perform action "AXRaise" of win
			delay 0.6

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
			if bodyArea is missing value then error "could not locate the reply body area"

			-- Mail parks the insertion point above the quoted history, which is where
			-- the reply belongs, so focus the body and paste without moving the caret.
			set focused of bodyArea to true
			delay 1.2
			set focused of bodyArea to true
			delay 0.8
			keystroke "v" using {command down}
			delay 2
		end tell
	end tell
end pasteIntoReply

-- Save via keystroke, then close. The exact sequence verified by hand:
-- Cmd+S, wait for the Exchange round-trip, Cmd+W. After a save the close is
-- silent (no sheet). Do not "improve" this into `close saving yes`, that verb
-- discards Exchange reply drafts while reporting success.
on saveAndCloseWindow(subj)
	tell application "System Events"
		tell process "Mail"
			set frontmost to true
			set win to missing value
			repeat with attempt from 1 to 10
				try
					set win to (first window whose name contains subj)
					exit repeat
				on error
					delay 0.3
				end try
			end repeat
			if win is missing value then error "compose window for \"" & subj & "\" disappeared before save"
			perform action "AXRaise" of win
			delay 0.4
			keystroke "s" using {command down}
			delay 2
			keystroke "w" using {command down}
			delay 1
		end tell
	end tell
end saveAndCloseWindow

on discardDraft(subj)
	if subj is "" then return
	tell application "Mail"
		repeat with om in (every outgoing message)
			try
				if subject of om is subj then close om saving no
			end try
		end repeat
		repeat with a in every account
			try
				delete (every message of mailbox "Drafts" of a whose subject is subj)
			end try
		end repeat
	end tell
	delay 0.5
end discardDraft

-- Poll rather than sample once: Mail writes the .emlx a beat after `save` returns,
-- and on an Exchange account that lag is long enough that a single immediate check
-- reports a perfectly good draft as empty, and the retry then deletes it.
on verifyDraftBody(subj, needle)
	set libDir to my scriptDir()
	-- An empty needle means body-needle.py found no line safe to match on (every line
	-- carried a link, say). Pass no --needle at all rather than an empty one: length
	-- alone is a weaker check, but it is a real one, and it beats failing every run.
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
