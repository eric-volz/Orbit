-- Orbit: open_note - shows one note in Apple Notes and brings Notes to the front.
--
-- Arguments (argv), all text - never part of the script source:
--   1  the note's id (x-coredata://...)
--
-- Output (JSON):
--   {"opened": true, "name": text}
--   {"error": "notFound"}
--
-- Apple Events go only to Notes.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 1 then error "notes-open expects 1 argument" number 1000
	set noteID to item 1 of argv
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
		show theNote
		activate
	end tell
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{true, noteName} forKeys:{"opened", "name"})
end run

on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
