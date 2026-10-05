-- Orbit: read_note - the content of one note in Apple Notes.
--
-- Arguments (argv), all text - never part of the script source:
--   1  the note's id (x-coredata://...)
--   2  maximum number of characters of the HTML body to return
--
-- Output (JSON):
--   {"id": text, "name": text, "folder": text, "created": seconds since 1970,
--    "modified": seconds since 1970, "locked": boolean, "body": HTML text,
--    "bodyLength": characters of the whole body}
--   {"error": "notFound"}
--
-- Notes puts images (and other embedded files) into the body as data: URLs, which are
-- often far longer than the whole text. Their data is removed before the body is measured
-- and cut (src="data:..." becomes src=""), so the text after an image is kept; Orbit shows
-- an image as [image] anyway. A locked note has an empty body. Apple Events go only to
-- Notes. Handlers that do not talk to Notes (noteDictionary, withoutEmbeddedData, prefix,
-- toJSON) are tested on their own by Orbit's unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 2 then error "notes-read expects 2 arguments" number 1000
	set noteID to item 1 of argv
	set maxBody to (item 2 of argv) as integer
	try
		tell application "Notes"
			set theNote to note id noteID
			set noteName to name of theNote
		end tell
	on error errorMessage number errorNumber
		if errorNumber is -1728 or errorNumber is -1719 then return my toJSON(current application's NSDictionary's dictionaryWithObject:"notFound" forKey:"error")
		error errorMessage number errorNumber
	end try
	tell application "Notes"
		set isLocked to password protected of theNote
		set createdDate to creation date of theNote
		set modifiedDate to modification date of theNote
	end tell
	set folderName to ""
	try
		tell application "Notes" to set folderName to name of container of theNote
	end try
	set noteBody to ""
	if not isLocked then
		tell application "Notes" to set noteBody to body of theNote
	end if
	return my toJSON(my noteDictionary(noteID, noteName, folderName, createdDate, modifiedDate, isLocked, noteBody, maxBody))
end run

on noteDictionary(noteID, noteName, folderName, createdDate, modifiedDate, isLocked, noteBody, maxBody)
	set createdSeconds to ((current application's NSDate's dateWithTimeInterval:0 sinceDate:createdDate)'s timeIntervalSince1970()) as real
	set modifiedSeconds to ((current application's NSDate's dateWithTimeInterval:0 sinceDate:modifiedDate)'s timeIntervalSince1970()) as real
	set cleanBody to my withoutEmbeddedData(noteBody)
	set bodyLength to length of cleanBody
	set bodyPart to my prefix(cleanBody, maxBody)
	return current application's NSDictionary's dictionaryWithObjects:{noteID, noteName, folderName, createdSeconds, modifiedSeconds, isLocked, bodyPart, bodyLength} forKeys:{"id", "name", "folder", "created", "modified", "locked", "body", "bodyLength"}
end noteDictionary

-- theBody without the data of data: URLs in src, srcset, data and href attributes (quoted
-- with " or ', or unquoted; any case): src="data:image/png;base64,..." becomes src="". One
-- regular expression over the whole text, so even a body of many megabytes takes
-- milliseconds.
on withoutEmbeddedData(theBody)
	if theBody does not contain "data:" then return theBody
	set theString to current application's NSString's stringWithString:theBody
	set cleaned to theString's stringByReplacingOccurrencesOfString:"(?i)\\b(src|srcset|data|href)\\s*=\\s*(\"data:[^\"]*\"|'data:[^']*'|data:[^\\s\"'>]*)" withString:"$1=\"\"" options:(current application's NSRegularExpressionSearch) range:{0, theString's |length|()}
	return cleaned as text
end withoutEmbeddedData

-- At most maxLength characters of theText (AppleScript counts whole characters,
-- so an emoji is never split).
on prefix(theText, maxLength)
	if maxLength < 1 then return ""
	if (length of theText) <= maxLength then return theText
	return text 1 thru maxLength of theText
end prefix

on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
