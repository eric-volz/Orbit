-- Orbit: read_mail - one message in Apple Mail with its recipients and text.
--
-- Arguments (argv), all text - never part of the script source:
--   1  Mail's number of the message (its "id")
--   2  the id of its account; empty for "On My Mac" or when unknown
--   3  the names of its mailbox's path, one per line ("Archiv", "Rechnungen")
--   4  maximum number of characters of the text to return
--
-- Output (JSON):
--   {"number": number, "account": text, "accountName": text, "accountAddresses": [text],
--    "mailbox": [names], "messageID": text, "subject": text, "sender": text, "replyTo": text,
--    "to": [{"name": text, "address": text}], "cc": [...], "dateReceived": seconds since 1970,
--    "dateSent": seconds since 1970, "read": boolean, "flagged": boolean,
--    "attachments": [{"name": text, "size": number}], "body": text, "bodyLength": number}
--   {"error": "notFound"}
--
-- A message is looked for in its mailbox first; if that mailbox cannot be found by its path,
-- in every mailbox with the same name. The path "@inbox" (also "@sent", "@drafts", "@junk",
-- "@trash") means: in that Mail-wide mailbox (search could not name the message's own one).
-- Reading changes nothing (the message stays unread). Apple Events go only to Mail. Handlers
-- that do not talk to Mail (addressDictionaries, attachmentDictionaries, isFatal, mailWideKind,
-- pathText, prefix, dateSeconds, nonEmptyLines, toJSON) are tested on their own by Orbit's
-- unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 4 then error "mail-read expects 4 arguments" number 1000
	set theNumber to (item 1 of argv) as integer
	set accountID to item 2 of argv
	set boxPath to my nonEmptyLines(item 3 of argv)
	set maxBody to (item 4 of argv) as integer
	set found to my findMessage(theNumber, accountID, boxPath)
	if found is missing value then return my toJSON(current application's NSDictionary's dictionaryWithObject:"notFound" forKey:"error")
	set {theMessage, foundAccount, foundPath} to found
	tell application "Mail"
		set theSubject to subject of theMessage
		set theSender to sender of theMessage
		set receivedDate to date received of theMessage
		set sentDate to date sent of theMessage
		set isRead to read status of theMessage
		set isFlagged to flagged status of theMessage
		set headerID to message id of theMessage
		set replyAddress to reply to of theMessage
	end tell
	set toList to my recipientList(theMessage, "to")
	set ccList to my recipientList(theMessage, "cc")
	set {accountName, accountAddresses} to my accountOf(theMessage)
	set attachmentList to my attachmentsOf(theMessage)
	set theBody to ""
	try
		tell application "Mail" to set theBody to content of theMessage
		set theBody to theBody as text
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
		set theBody to ""
	end try
	set theKeys to {"number", "account", "accountName", "accountAddresses", "mailbox", "messageID", "subject", "sender", "replyTo", "to", "cc", "dateReceived", "dateSent", "read", "flagged", "attachments", "body", "bodyLength"}
	set theValues to {theNumber, foundAccount, accountName, accountAddresses, foundPath, headerID, theSubject, theSender, replyAddress, toList, ccList, my dateSeconds(receivedDate), my dateSeconds(sentDate), isRead, isFlagged, attachmentList, my prefix(theBody, maxBody), length of theBody}
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:theValues forKeys:theKeys)
end run

-- The To or Cc recipients of theMessage as name/address dictionaries.
on recipientList(theMessage, whichField)
	try
		tell application "Mail"
			if whichField is "to" then
				set theNames to name of every to recipient of theMessage
				set theAddresses to address of every to recipient of theMessage
			else
				set theNames to name of every cc recipient of theMessage
				set theAddresses to address of every cc recipient of theMessage
			end if
		end tell
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
		return {}
	end try
	return my addressDictionaries(theNames, theAddresses)
end recipientList

-- The name and the addresses of the account the message belongs to.
on accountOf(theMessage)
	try
		tell application "Mail"
			set theAccount to account of mailbox of theMessage
			set accountName to name of theAccount
			set accountAddresses to email addresses of theAccount
		end tell
		return {accountName, accountAddresses}
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
	end try
	return {missing value, {}}
end accountOf

-- The names and sizes of the message's attachments.
on attachmentsOf(theMessage)
	try
		tell application "Mail"
			set theNames to name of every mail attachment of theMessage
			set theSizes to file size of every mail attachment of theMessage
		end tell
		return my attachmentDictionaries(theNames, theSizes)
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
	end try
	return {}
end attachmentsOf

-- [{"name": ..., "address": ...}] for parallel lists (empty when they do not line up).
on addressDictionaries(theNames, theAddresses)
	set found to current application's NSMutableArray's array()
	if (count of theNames) is not (count of theAddresses) then return found
	repeat with i from 1 to count of theAddresses
		(found's addObject:(current application's NSDictionary's dictionaryWithObjects:{item i of theNames, item i of theAddresses} forKeys:{"name", "address"}))
	end repeat
	return found
end addressDictionaries

-- [{"name": ..., "size": ...}] for parallel lists (sizes may be missing).
on attachmentDictionaries(theNames, theSizes)
	set found to current application's NSMutableArray's array()
	repeat with i from 1 to count of theNames
		set theSize to missing value
		if (count of theSizes) is (count of theNames) then set theSize to item i of theSizes
		(found's addObject:(current application's NSDictionary's dictionaryWithObjects:{item i of theNames, theSize} forKeys:{"name", "size"}))
	end repeat
	return found
end attachmentDictionaries

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
