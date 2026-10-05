-- Orbit: create_mail_draft with reply_to_id - opens Mail's own reply window for a message.
-- Mail fills in the recipients, the "Re:" subject, the quoted original and the user's
-- signature. Nothing is written into the window (Mail ignores scripted changes to the text of
-- its replies): Orbit puts the text for it on the clipboard. The user reviews the reply and
-- decides in Mail; this script has no way to deliver it.
--
-- Arguments (argv), all text - never part of the script source:
--   1  Mail's number of the message to answer (its "id")
--   2  the id of its account; empty for "On My Mac" or when unknown
--   3  the names of its mailbox's path, one per line ("Archiv", "Rechnungen")
--   4  "true" to answer everyone who got the message, anything else for the sender only
--
-- Output (JSON):
--   {"id": the reply window's id, "subject": text, "to": [{"name": text, "address": text}],
--    "cc": [...] - the reply as Mail filled it in (null or empty where Mail does not tell),
--    "sender": text, "replyTo": text, "originalSubject": text,
--    "dateReceived": seconds since 1970 - of the answered message}
--   {"error": "notFound"}
--
-- The message is looked for like in mail-read: in its mailbox first; if that mailbox cannot be
-- found by its path, in every mailbox with the same name; "@inbox" ("@sent" ...) means in that
-- Mail-wide mailbox. Apple Events go only to Mail. Handlers that do not talk to Mail
-- (addressDictionaries, isFatal, mailWideKind, pathText, dateSeconds, nonEmptyLines, toJSON) are
-- tested on their own by Orbit's unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 4 then error "mail-reply expects 4 arguments" number 1000
	set theNumber to (item 1 of argv) as integer
	set accountID to item 2 of argv
	set boxPath to my nonEmptyLines(item 3 of argv)
	set toAll to (item 4 of argv) is "true"
	set found to my findMessage(theNumber, accountID, boxPath)
	if found is missing value then return my toJSON(current application's NSDictionary's dictionaryWithObject:"notFound" forKey:"error")
	set theMessage to item 1 of found
	tell application "Mail"
		set theSender to sender of theMessage
		set theSubject to subject of theMessage
		set replyAddress to reply to of theMessage
		set receivedDate to date received of theMessage
	end tell
	tell application "Mail"
		if toAll then
			set theReply to reply theMessage with opening window and reply to all
		else
			set theReply to reply theMessage with opening window
		end if
	end tell
	-- The window is open now: what follows only reads, briefly, and never ends the run
	-- unless Orbit may not control Mail anymore.
	set replyID to missing value
	try
		with timeout of 5 seconds
			tell application "Mail" to set replyID to id of theReply
		end timeout
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
	end try
	set replySubject to missing value
	try
		with timeout of 5 seconds
			tell application "Mail" to set replySubject to subject of theReply
		end timeout
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
	end try
	set toList to my recipientList(theReply, "to")
	set ccList to my recipientList(theReply, "cc")
	tell application "Mail" to activate
	set theKeys to {"id", "subject", "to", "cc", "sender", "replyTo", "originalSubject", "dateReceived"}
	set theValues to {replyID, replySubject, toList, ccList, theSender, replyAddress, theSubject, my dateSeconds(receivedDate)}
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:theValues forKeys:theKeys)
end run

-- The To or Cc recipients Mail put into the reply, as name/address dictionaries (empty when
-- Mail does not tell).
on recipientList(theReply, whichField)
	try
		with timeout of 5 seconds
			tell application "Mail"
				if whichField is "to" then
					set theNames to name of every to recipient of theReply
					set theAddresses to address of every to recipient of theReply
				else
					set theNames to name of every cc recipient of theReply
					set theAddresses to address of every cc recipient of theReply
				end if
			end tell
		end timeout
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
		return {}
	end try
	return my addressDictionaries(theNames, theAddresses)
end recipientList

-- [{"name": ..., "address": ...}] for parallel lists (empty when they do not line up).
on addressDictionaries(theNames, theAddresses)
	set found to current application's NSMutableArray's array()
	if (count of theNames) is not (count of theAddresses) then return found
	repeat with i from 1 to count of theAddresses
		(found's addObject:(current application's NSDictionary's dictionaryWithObjects:{item i of theNames, item i of theAddresses} forKeys:{"name", "address"}))
	end repeat
	return found
end addressDictionaries

-- The message with Mail's number theNumber in the mailbox at boxPath of the account with id
-- accountID ("" for "On My Mac" or unknown): {message, account id, mailbox path}, or missing
-- value. The path "@inbox" ("@sent", "@drafts", "@junk", "@trash") stands for a message found
-- in that Mail-wide mailbox whose own mailbox Mail could not name: it is looked for there
-- first. When the mailbox cannot be found by its path, every mailbox with the same name is
-- tried (in that account, or in all when the account is unknown).
on findMessage(theNumber, accountID, boxPath)
	set wideKind to my mailWideKind(boxPath)
	if wideKind is not "" then
		set theMessage to missing value
		try
			set theMessage to my messageIn(my specialMailbox(wideKind), theNumber)
		on error errorMessage number errorNumber
			if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
		end try
		if theMessage is not missing value then return {theMessage, accountID, boxPath}
	end if
	set theAccount to missing value
	if accountID is not "" then
		try
			tell application "Mail" to set theAccount to first account whose id is accountID
		on error errorMessage number errorNumber
			if my isFatal(errorNumber) then error errorMessage number errorNumber
		end try
	end if
	if theAccount is not missing value or accountID is "" then
		set theBox to my mailboxAt(theAccount, boxPath)
		if theBox is not missing value then
			set theMessage to my messageIn(theBox, theNumber)
			if theMessage is not missing value then return {theMessage, accountID, boxPath}
		end if
	end if
	if (count of boxPath) = 0 then return missing value
	set wantedName to item -1 of boxPath
	set {boxRefs, boxPaths, boxAccounts} to my allMailboxes()
	repeat with i from 1 to count of boxRefs
		set candidatePath to item i of boxPaths
		if (item -1 of candidatePath) = wantedName and (theAccount is missing value or (item i of boxAccounts) = accountID) then
			set theMessage to my messageIn(item i of boxRefs, theNumber)
			if theMessage is not missing value then return {theMessage, item i of boxAccounts, candidatePath}
		end if
	end repeat
	return missing value
end findMessage

-- "inbox" for the path {"@inbox"} (also sent, drafts, junk and trash; case counts), else "".
on mailWideKind(boxPath)
	if (count of boxPath) is not 1 then return ""
	considering case
		repeat with theKind in {"inbox", "sent", "drafts", "junk", "trash"}
			if (item 1 of boxPath) is ("@" & theKind) then return contents of theKind
		end repeat
	end considering
	return ""
end mailWideKind

-- Mail's mailbox of one kind for all accounts.
on specialMailbox(whichKind)
	tell application "Mail"
		if whichKind is "inbox" then return inbox
		if whichKind is "sent" then return sent mailbox
		if whichKind is "drafts" then return drafts mailbox
		if whichKind is "junk" then return junk mailbox
		return trash mailbox
	end tell
end specialMailbox

-- The mailbox at boxPath in theAccount (missing value: "On My Mac"), or missing value. Mail
-- names a nested mailbox both by its parent and by its whole path ("Archiv/Rechnungen").
on mailboxAt(theAccount, boxPath)
	if (count of boxPath) = 0 then return missing value
	try
		tell application "Mail"
			if theAccount is missing value then
				set theBox to mailbox (item 1 of boxPath)
			else
				set theBox to mailbox (item 1 of boxPath) of theAccount
			end if
			repeat with i from 2 to count of boxPath
				set theBox to mailbox (item i of boxPath) of theBox
			end repeat
			get name of theBox
		end tell
		return theBox
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
	end try
	if (count of boxPath) = 1 then return missing value
	try
		set wholePath to my pathText(boxPath)
		tell application "Mail"
			if theAccount is missing value then
				set theBox to mailbox wholePath
			else
				set theBox to mailbox wholePath of theAccount
			end if
			get name of theBox
		end tell
		return theBox
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
	end try
	return missing value
end mailboxAt

-- The message with Mail's number theNumber in theBox, or missing value. It is written with
-- the raw code of Mail's class "message" because in Mail's terms "message id" is the
-- Message-ID header; this element-by-id form is the one Mail itself uses for messages.
on messageIn(theBox, theNumber)
	try
		tell application "Mail"
			set theMessage to «class mssg» id theNumber of theBox
			get id of theMessage
		end tell
		return theMessage
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
	end try
	return missing value
end messageIn

-- Every mailbox of every account and "On My Mac", subfolders included, each once:
-- {references, paths (lists of names), account ids ("" for "On My Mac")}.
on allMailboxes()
	set boxRefs to {}
	set boxPaths to {}
	set boxAccounts to {}
	set seenPaths to {}
	tell application "Mail" to set theAccounts to every account
	repeat with i from 1 to count of theAccounts
		set theAccount to item i of theAccounts
		tell application "Mail"
			set accountID to id of theAccount
			set topBoxes to every mailbox of theAccount
		end tell
		my collectMailboxes(topBoxes, {}, accountID, boxRefs, boxPaths, boxAccounts, seenPaths)
	end repeat
	tell application "Mail" to set localBoxes to every mailbox
	my collectMailboxes(localBoxes, {}, "", boxRefs, boxPaths, boxAccounts, seenPaths)
	return {boxRefs, boxPaths, boxAccounts}
end allMailboxes

on collectMailboxes(theBoxes, parentPath, accountID, boxRefs, boxPaths, boxAccounts, seenKeys)
	repeat with i from 1 to count of theBoxes
		set theBox to item i of theBoxes
		tell application "Mail"
			set boxName to name of theBox
			set children to every mailbox of theBox
		end tell
		set boxPath to parentPath & {boxName}
		set boxKey to accountID & ":" & my pathText(boxPath)
		if seenKeys does not contain boxKey and (count of boxPath) <= 20 then
			set end of seenKeys to boxKey
			set end of boxRefs to theBox
			set end of boxPaths to boxPath
			set end of boxAccounts to accountID
			if (count of children) > 0 then my collectMailboxes(children, boxPath, accountID, boxRefs, boxPaths, boxAccounts, seenKeys)
		end if
	end repeat
end collectMailboxes

-- Errors that end the run: a denied permission, a missing app or a cancellation.
on isFatal(errorNumber)
	return errorNumber is in {-1743, -1744, -600, -609, -128}
end isFatal

on pathText(boxPath)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "/"
	set joined to boxPath as text
	set AppleScript's text item delimiters to savedDelimiters
	return joined
end pathText

-- Seconds since 1970 for a date, or missing value.
on dateSeconds(theDate)
	if class of theDate is not date then return missing value
	return ((current application's NSDate's dateWithTimeInterval:0 sinceDate:theDate)'s timeIntervalSince1970()) as real
end dateSeconds

on nonEmptyLines(theText)
	set found to {}
	repeat with i from 1 to count of paragraphs of theText
		set lineText to paragraph i of theText
		if lineText is not "" then set end of found to lineText
	end repeat
	return found
end nonEmptyLines

on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
