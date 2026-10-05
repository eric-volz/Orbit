-- Orbit: create_mail_draft - opens a new message window in Apple Mail with recipients,
-- subject and text. The user reviews the draft and decides in Mail; this script has no way
-- to deliver it.
--
-- Arguments (argv), all text - never part of the script source:
--   1  the subject
--   2  the text (plain text)
--   3  the To recipients, one per line: the address, then a tab and the name (may be empty)
--   4  the Cc recipients, in the same form
--
-- Output (JSON):
--   {"id": the window's id, "failed": [addresses Mail did not accept]}
--
-- The text is set when the message is made; Mail writes from the account it chooses. Orbit
-- answers a message in Mail's own window for answers instead (a script of its own). Apple
-- Events go only to Mail. Handlers that do not talk to Mail (recipientParts, isFatal,
-- nonEmptyLines, toJSON) are tested on their own by Orbit's unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 4 then error "mail-draft expects 4 arguments" number 1000
	set theSubject to item 1 of argv
	set theContent to item 2 of argv
	set toLines to my nonEmptyLines(item 3 of argv)
	set ccLines to my nonEmptyLines(item 4 of argv)
	tell application "Mail"
		set theDraft to make new outgoing message with properties {subject:theSubject, content:theContent, visible:true}
	end tell
	set failed to {}
	repeat with i from 1 to count of toLines
		set {theAddress, theName} to my recipientParts(item i of toLines)
		if not my addRecipient(theDraft, "to", theAddress, theName) then set end of failed to theAddress
	end repeat
	repeat with i from 1 to count of ccLines
		set {theAddress, theName} to my recipientParts(item i of ccLines)
		if not my addRecipient(theDraft, "cc", theAddress, theName) then set end of failed to theAddress
	end repeat
	tell application "Mail"
		set draftID to id of theDraft
		activate
	end tell
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{draftID, failed} forKeys:{"id", "failed"})
end run

-- Adds a recipient to the draft's To (whichField "to") or Cc field; false when Mail refuses it.
on addRecipient(theDraft, whichField, theAddress, theName)
	try
		tell application "Mail"
			tell theDraft
				if whichField is "to" then
					if theName is "" then
						make new to recipient at end of to recipients with properties {address:theAddress}
					else
						make new to recipient at end of to recipients with properties {address:theAddress, name:theName}
					end if
				else
					if theName is "" then
						make new cc recipient at end of cc recipients with properties {address:theAddress}
					else
						make new cc recipient at end of cc recipients with properties {address:theAddress, name:theName}
					end if
				end if
			end tell
		end tell
		return true
	on error errorMessage number errorNumber
		if my isFatal(errorNumber) then error errorMessage number errorNumber
		return false
	end try
end addRecipient

-- {address, name} from "address<tab>name".
on recipientParts(theLine)
	set savedDelimiters to AppleScript's text item delimiters
	set AppleScript's text item delimiters to tab
	set fields to text items of theLine
	set AppleScript's text item delimiters to savedDelimiters
	set theName to ""
	if (count of fields) > 1 then set theName to item 2 of fields
	return {item 1 of fields, theName}
end recipientParts

-- Errors that end the run: a denied permission, a missing app, a timeout or a cancellation.
on isFatal(errorNumber)
	return errorNumber is in {-1743, -1744, -600, -609, -1712, -128}
end isFatal

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
