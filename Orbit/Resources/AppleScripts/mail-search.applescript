-- Orbit: search_mail, step 1 - every message received in a time range in some of Apple
-- Mail's mailboxes, with its subject and sender. Orbit matches, ranks and limits them; this
-- script only fetches them, with a few Apple Events per mailbox (properties of a filtered
-- message list read at once) and no work per message.
--
-- Arguments (argv), all text - never part of the script source:
--   1  which mailboxes: "inbox", "sent", "drafts", "junk" or "trash" (Mail's mailbox of that
--      kind for all accounts), "all" (every mailbox of every account and "On My Mac" except
--      those named in argument 6) or "named" (the mailboxes named in argument 2)
--   2  for "named": a mailbox's name or its path ("Archiv/Rechnungen"), compared like
--      AppleScript compares text (case and accents ignored); empty otherwise
--   3  earliest date received, in seconds since 1970
--   4  latest date received, in seconds since 1970
--   5  "true": only unread messages
--   6  names of mailboxes "all" leaves out, one per line (trash, junk, drafts, outbox)
--   7  seconds the search may take once Mail answered: no mailbox is started after that,
--      and every request to Mail ends 15 seconds later at the latest (it then stops)
--
-- Output (JSON):
--   {"batches": [{"account": text, "mailbox": [names], "ids": [numbers], "dates": [seconds],
--     "subjects": [text], "senders": [text]}], "accounts": [{"id": text, "name": text}],
--    "complete": boolean, "skipped": [[names]], "failed": [{"mailbox": [names], "error": number}]}
--   A batch of a Mail-wide mailbox (inbox, sent ...) has "accounts" and "mailboxNames" (one
--   per message, null when Mail cannot tell) instead of "account" and "mailbox".
--   "skipped": the mailboxes not searched because time ran out. "failed": the mailboxes Mail
--   could not search, with its error number - never left out silently (a Mail-wide mailbox,
--   the only one of its search, is read a second time first). Their names: the path, or the
--   kind of a Mail-wide mailbox ("inbox").
--   Subjects and senders longer than 500 characters are cut to that (Orbit shows far less), so
--   a few messages with huge headers cannot make the answer larger than Orbit accepts.
--   {"error": "mailboxNotFound", "mailboxes": [[names]]}
--
-- Apple Events go only to Mail. Handlers that do not talk to Mail (secondsSince1970,
-- dateFromSeconds, secondsLeft, isFatal, failureKind, isExcluded, isNamed, pathText,
-- nonEmptyLines, shortened, batchDictionary, toJSON) are tested on their own by Orbit's unit
-- tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 7 then error "mail-search expects 7 arguments" number 1000
	set selectionKind to item 1 of argv
	set wantedName to item 2 of argv
	set startDate to my dateFromSeconds(item 3 of argv)
	set endDate to my dateFromSeconds(item 4 of argv)
	set unreadOnly to (item 5 of argv) is "true"
	set excludedNames to my nonEmptyLines(item 6 of argv)
	set budget to (item 7 of argv) as integer

	-- The first Apple Event: Mail starts (and macOS asks for permission) here, before the clock runs.
	set accountRecords to my accountDictionaries()
	set startTime to current date
	set theDeadline to startTime + budget + 15

	-- What to search: {mailbox, its path (missing value for a Mail-wide mailbox), its account's id, label}.
	set containers to {}
	if selectionKind is in {"inbox", "sent", "drafts", "junk", "trash"} then
		set end of containers to {my specialMailbox(selectionKind), missing value, "", {selectionKind}}
	else
		set {boxRefs, boxPaths, boxAccounts} to my allMailboxes()
		repeat with i from 1 to count of boxRefs
			set boxPath to item i of boxPaths
			if selectionKind is "all" then
				if not my isExcluded(boxPath, excludedNames) then set end of containers to {item i of boxRefs, boxPath, item i of boxAccounts, boxPath}
			else if my isNamed(boxPath, wantedName) then
				set end of containers to {item i of boxRefs, boxPath, item i of boxAccounts, boxPath}
			end if
		end repeat
		if selectionKind is "named" and (count of containers) = 0 then return my mailboxNotFound(boxPaths)
	end if

	set batches to current application's NSMutableArray's array()
	set skipped to {}
	set failed to current application's NSMutableArray's array()
	set complete to true
	set stopped to false
	repeat with i from 1 to count of containers
		set {theContainer, boxPath, accountID, label} to item i of containers
		-- A Mail-wide mailbox is all its search has, so it gets a second try after an error.
		set attempts to 1
		if boxPath is missing value then set attempts to 2
		repeat with attempt from 1 to attempts
			if stopped or ((current date) - startTime) >= budget then
				set complete to false
				set end of skipped to label
				exit repeat
			end if
			try
				set batch to my containerBatch(theContainer, boxPath, accountID, startDate, endDate, unreadOnly, theDeadline)
				(batches's addObject:batch)
				exit repeat
			on error errorMessage number errorNumber
				set outcome to my failureKind(errorNumber, attempt, attempts)
				if outcome is "fatal" then error errorMessage number errorNumber
				if outcome is "stop" then
					-- Mail is still busy with this mailbox; further requests would wait behind it.
					set stopped to true
					set complete to false
					set end of skipped to label
					exit repeat
				else if outcome is "failed" then
					set complete to false
					(failed's addObject:(current application's NSDictionary's dictionaryWithObjects:{label, errorNumber} forKeys:{"mailbox", "error"}))
					exit repeat
				end if
				-- "retry": the next attempt reads the mailbox again.
			end try
		end repeat
	end repeat
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{batches, accountRecords, complete, skipped, failed} forKeys:{"batches", "accounts", "complete", "skipped", "failed"})
end run

-- The messages received in the range in one mailbox, with subject and sender; for a Mail-wide
-- mailbox (boxPath is missing value) also each message's own mailbox and account. Read twice
-- if a message arrived or left in between (the lists must line up). Every request may take
-- only the time left until theDeadline.
on containerBatch(theContainer, boxPath, accountID, startDate, endDate, unreadOnly, theDeadline)
	repeat with attempt from 1 to 2
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set theIDs to id of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set theIDs to id of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set theDates to date received of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set theDates to date received of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set theSubjects to subject of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set theSubjects to subject of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set theSenders to sender of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set theSenders to sender of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
		set boxNames to missing value
		set accountIDs to missing value
		if boxPath is missing value and (count of theIDs) > 0 then
			set {boxNames, accountIDs} to my mailboxesOfMessages(theContainer, startDate, endDate, unreadOnly, theDeadline)
		end if
		set expected to count of theIDs
		if (count of theDates) = expected and (count of theSubjects) = expected and (count of theSenders) = expected then
			if boxNames is missing value or ((count of boxNames) = expected and (count of accountIDs) = expected) then
				return my batchDictionary(accountID, boxPath, accountIDs, boxNames, theIDs, theDates, theSubjects, theSenders)
			end if
		end if
	end repeat
	error "The mailbox changed during the search." number 1002
end containerBatch

-- For the messages of a Mail-wide mailbox: the name of each one's mailbox and the id of its
-- account, or missing value for what Mail cannot tell (Orbit then finds the message by name).
on mailboxesOfMessages(theContainer, startDate, endDate, unreadOnly, theDeadline)
	set boxNames to missing value
	set accountIDs to missing value
	try
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set boxNames to name of mailbox of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set boxNames to name of mailbox of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
		return {missing value, missing value}
	end try
	try
		with timeout of (my secondsLeft(theDeadline)) seconds
			tell application "Mail"
				if unreadOnly then
					set accountIDs to id of account of mailbox of (every message of theContainer whose date received >= startDate and date received <= endDate and read status is false)
				else
					set accountIDs to id of account of mailbox of (every message of theContainer whose date received >= startDate and date received <= endDate)
				end if
			end tell
		end timeout
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) or errorNumber is -1712 then error errorMessage number errorNumber
		set accountIDs to {}
		repeat with i from 1 to count of boxNames
			set end of accountIDs to missing value
		end repeat
	end try
	return {boxNames, accountIDs}
end mailboxesOfMessages

-- Whole seconds left until theDeadline; a timeout (-1712) when none are left.
on secondsLeft(theDeadline)
	set remaining to theDeadline - (current date)
	if remaining < 1 then error "No time is left for Mail." number -1712
	return remaining
end secondsLeft

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

-- Every account's id and name.
on accountDictionaries()
	tell application "Mail"
		set accountIDs to id of every account
		set accountNames to name of every account
	end tell
	set found to current application's NSMutableArray's array()
	if (count of accountIDs) = (count of accountNames) then
		repeat with i from 1 to count of accountIDs
			(found's addObject:(current application's NSDictionary's dictionaryWithObjects:{item i of accountIDs, item i of accountNames} forKeys:{"id", "name"}))
		end repeat
	end if
	return found
end accountDictionaries

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

-- Adds theBoxes and their subfolders below parentPath (lists are shared, so the caller's
-- lists grow). seenKeys holds "account:path" texts already added.
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

on mailboxNotFound(boxPaths)
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{"mailboxNotFound", boxPaths} forKeys:{"error", "mailboxes"})
end mailboxNotFound

-- Errors no other mailbox can avoid: a denied permission, a missing app or a cancellation.
on isFatal(errorNumber)
	return errorNumber is in {-1743, -1744, -600, -609, -128}
end isFatal

-- What an error while reading a mailbox (attempt of attempts) means: "fatal" (the search ends
-- with it), "stop" (Mail is busy: no further mailbox is read), "retry" (read it once more) or
-- "failed" (reported as not searched, with the error number). A changed mailbox (1002) is not
-- read again here: containerBatch already read it twice.
on failureKind(errorNumber, attempt, attempts)
	if my isFatal(errorNumber) then return "fatal"
	if errorNumber is -1712 then return "stop"
	if errorNumber is not 1002 and attempt < attempts then return "retry"
	return "failed"
end failureKind

-- Whether a mailbox at boxPath is one "all" leaves out: one of its names is excluded.
on isExcluded(boxPath, excludedNames)
	ignoring case and diacriticals
		repeat with i from 1 to count of boxPath
			if excludedNames contains {item i of boxPath} then return true
		end repeat
	end ignoring
	return false
end isExcluded

-- Whether the mailbox at boxPath is the one called wantedName: its own name or its path.
on isNamed(boxPath, wantedName)
	if (count of boxPath) = 0 then return false
	ignoring case and diacriticals
		if (item -1 of boxPath) = wantedName then return true
		if my pathText(boxPath) = wantedName then return true
	end ignoring
	return false
end isNamed

-- "Archiv/Rechnungen".
on pathText(boxPath)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to "/"
	set joined to boxPath as text
	set AppleScript's text item delimiters to savedDelimiters
	return joined
end pathText

-- One batch for the JSON (accountIDs and boxNames are missing value for a single mailbox).
on batchDictionary(accountID, boxPath, accountIDs, boxNames, theIDs, theDates, theSubjects, theSenders)
	set theKeys to {"ids", "dates", "subjects", "senders"}
	set theValues to {theIDs, my secondsSince1970(theDates), my shortened(theSubjects, 500), my shortened(theSenders, 500)}
	if boxPath is not missing value then
		set theKeys to theKeys & {"account", "mailbox"}
		set theValues to theValues & {accountID, boxPath}
	else
		if accountIDs is not missing value then
			set theKeys to theKeys & {"accounts"}
			set theValues to theValues & {accountIDs}
		end if
		if boxNames is not missing value then
			set theKeys to theKeys & {"mailboxNames"}
			set theValues to theValues & {boxNames}
		end if
	end if
	return current application's NSDictionary's dictionaryWithObjects:theValues forKeys:theKeys
end batchDictionary

-- theValues (texts, or missing value where Mail has none) with every text longer than
-- maxLength characters (Unicode code points) cut to that: a few regular expressions over the
-- joined list, no loop per value. Only when a value is cut, control characters become spaces
-- and missing values empty texts (Orbit reads both alike); otherwise theValues are returned as
-- they are.
on shortened(theValues, maxLength)
	if (count of theValues) = 0 then return theValues
	set separator to character id 30
	-- A random marker joins the values (no value can contain it); it becomes the separator once
	-- the separator itself is gone from the values.
	set marker to (current application's NSUUID's UUID()'s UUIDString()) as text
	set joined to (current application's NSArray's arrayWithArray:theValues)'s componentsJoinedByString:marker
	set joined to joined's stringByReplacingOccurrencesOfString:separator withString:" "
	set joined to joined's stringByReplacingOccurrencesOfString:marker withString:separator
	set regex to current application's NSRegularExpressionSearch
	-- NSArray joins a missing value as "<null>".
	set joined to joined's stringByReplacingOccurrencesOfString:"(^|\\x{1E})<null>(?=\\x{1E}|$)" withString:"$1" options:regex range:{0, joined's |length|()}
	set tooLong to joined's rangeOfString:("(^|\\x{1E})[^\\x{1E}]{" & (maxLength + 1) & "}") options:regex
	if (|length| of tooLong) = 0 then return theValues
	set joined to joined's stringByReplacingOccurrencesOfString:"[\\x{0}-\\x{1D}\\x{1F}\\x{7F}]" withString:" " options:regex range:{0, joined's |length|()}
	set joined to joined's stringByReplacingOccurrencesOfString:("(^|\\x{1E})([^\\x{1E}]{" & maxLength & "})[^\\x{1E}]+") withString:"$1$2" options:regex range:{0, joined's |length|()}
	set parts to joined's componentsSeparatedByString:separator
	if ((parts's |count|()) as integer) is not (count of theValues) then return theValues
	return parts
end shortened

-- Seconds since 1970 for a list of dates, at once (one by one if an item is not a date).
on secondsSince1970(theDates)
	try
		return (current application's NSArray's arrayWithArray:theDates)'s valueForKey:"timeIntervalSince1970"
	on error
		set found to {}
		repeat with i from 1 to count of theDates
			set theDate to item i of theDates
			if class of theDate is date then
				set end of found to ((current application's NSDate's dateWithTimeInterval:0 sinceDate:theDate)'s timeIntervalSince1970()) as real
			else
				set end of found to missing value
			end if
		end repeat
		return found
	end try
end secondsSince1970

-- An AppleScript date for seconds since 1970 (given as text).
on dateFromSeconds(theSeconds)
	return (current application's NSDate's dateWithTimeIntervalSince1970:((theSeconds as text) as real)) as date
end dateFromSeconds

-- The lines of theText that are not empty.
on nonEmptyLines(theText)
	set found to {}
	repeat with i from 1 to count of paragraphs of theText
		set lineText to paragraph i of theText
		if lineText is not "" then set end of found to lineText
	end repeat
	return found
end nonEmptyLines

-- Slashes stay as they are ("a/b", not "a\/b"): subjects and paths are full of them.
on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:(current application's NSJSONWritingWithoutEscapingSlashes) |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
