-- Orbit: search_mail, step 2 - details of the few messages search_mail shows: subject,
-- sender, date, read status, Message-ID and the beginning of the text.
--
-- Arguments (argv), all text - never part of the script source:
--   1  the messages, one per line: Mail's number of the message, a tab, its account's id
--      (empty for "On My Mac" or when unknown), then the names of its mailbox's path, each
--      after a tab ("4711<tab>0A1B...<tab>Archiv<tab>Rechnungen")
--   2  maximum number of characters of each message's text to return ("preview")
--   3  seconds this may take: no message is started after that, and every request to Mail
--      ends 8 seconds later at the latest (the remaining messages are left out)
--
-- Output (JSON):
--   {"rows": [{"number": number, "found": true, "account": text, "mailbox": [names],
--     "subject": text, "sender": text, "messageID": text, "read": boolean,
--     "date": seconds since 1970, "preview": text} or {"number": number, "found": false}],
--    "complete": boolean}
--
-- A message is looked for in its mailbox first; if that mailbox cannot be found by its path,
-- in every mailbox with the same name. The path "@inbox" (also "@sent", "@drafts", "@junk",
-- "@trash") means: in that Mail-wide mailbox (mail-search could not name the message's own
-- one). Apple Events go only to Mail; nothing is changed. Handlers that do not talk to Mail
-- (parseLine, secondsLeft, isFatal, mailWideKind, pathText, prefix, dateSeconds, nonEmptyLines,
-- toJSON) are tested on their own by Orbit's unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 3 then error "mail-summaries expects 3 arguments" number 1000
	set requestLines to my nonEmptyLines(item 1 of argv)
	set previewLength to (item 2 of argv) as integer
	set budget to (item 3 of argv) as integer
	set summaryRows to current application's NSMutableArray's array()
	set complete to true
	-- Mail is running: search_mail's first step started it.
	set startTime to current date
	set theDeadline to startTime + budget + 8
	repeat with i from 1 to count of requestLines
		set {theNumber, accountID, boxPath} to my parseLine(item i of requestLines)
		if ((current date) - startTime) >= budget then
			set complete to false
			exit repeat
		end if
		try
			set summary to my summaryRow(theNumber, accountID, boxPath, previewLength, theDeadline)
		on error errorMessage number errorNumber
			if my isFatal(errorNumber) then error errorMessage number errorNumber
			if errorNumber is -1712 then
				set complete to false
				exit repeat
			end if
			set summary to current application's NSDictionary's dictionaryWithObjects:{theNumber, false} forKeys:{"number", "found"}
		end try
		(summaryRows's addObject:summary)
	end repeat
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{summaryRows, complete} forKeys:{"rows", "complete"})
end run

-- The row for one message.
on summaryRow(theNumber, accountID, boxPath, previewLength, theDeadline)
	set found to my findMessage(theNumber, accountID, boxPath)
	if found is missing value then
		return current application's NSDictionary's dictionaryWithObjects:{theNumber, false} forKeys:{"number", "found"}
	end if
	set {theMessage, foundAccount, foundPath} to found
	with timeout of (my secondsLeft(theDeadline)) seconds
		tell application "Mail"
			set theSubject to subject of theMessage
			set theSender to sender of theMessage
			set receivedDate to date received of theMessage
			set isRead to read status of theMessage
			set headerID to message id of theMessage
		end tell
	end timeout
	set thePreview to ""
	try
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail" to set theText to content of theMessage
		end timeout
		set thePreview to my prefix(theText as text, previewLength)
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
	end try
	return current application's NSDictionary's dictionaryWithObjects:{theNumber, true, foundAccount, foundPath, theSubject, theSender, headerID, isRead, my dateSeconds(receivedDate), thePreview} forKeys:{"number", "found", "account", "mailbox", "subject", "sender", "messageID", "read", "date", "preview"}
end summaryRow

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

-- {number, account id, mailbox path} from "4711<tab>account<tab>name<tab>name".
on parseLine(theLine)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to tab
	set fields to text items of theLine
	set AppleScript's text item delimiters to savedDelimiters
	set theNumber to (item 1 of fields) as integer
	set accountID to ""
	if (count of fields) > 1 then set accountID to item 2 of fields
	set boxPath to {}
	repeat with i from 3 to count of fields
		if item i of fields is not "" then set end of boxPath to item i of fields
	end repeat
	return {theNumber, accountID, boxPath}
end parseLine

-- Whole seconds left until theDeadline; a timeout (-1712) when none are left.
on secondsLeft(theDeadline)
	set remaining to theDeadline - (current date)
	if remaining < 1 then error "No time is left for Mail." number -1712
	return remaining
end secondsLeft

-- Errors that end the whole run: a denied permission, a missing app or a cancellation.
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

-- At most maxLength characters of theText (AppleScript counts whole characters).
on prefix(theText, maxLength)
	if maxLength < 1 then return ""
	if (length of theText) <= maxLength then return theText
	return text 1 thru maxLength of theText
end prefix

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
