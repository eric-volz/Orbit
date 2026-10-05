-- Orbit: "In Mail zeigen" on a draft card - brings a draft window Orbit opened to the front.
--
-- Arguments (argv), all text - never part of the script source:
--   1  the draft window's id (as mail-draft returned it)
--
-- Output (JSON):
--   {"shown": true}
--   {"shown": false} when the window is no longer open (Mail comes to the front anyway)
--
-- Apple Events go only to Mail; the draft is not changed.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 1 then error "mail-show-draft expects 1 argument" number 1000
	set draftID to (item 1 of argv) as integer
	tell application "Mail"
		set openDrafts to every outgoing message whose id is draftID
		if (count of openDrafts) > 0 then set visible of (item 1 of openDrafts) to true
		activate
	end tell
	return my toJSON(current application's NSDictionary's dictionaryWithObject:((count of openDrafts) > 0) forKey:"shown")
end run

on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
