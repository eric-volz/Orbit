-- Orbit: shows one photo or video in Apple Photos and brings Photos to the front
-- (a click on a tile of a photo card).
--
-- Arguments (argv), all text - never part of the script source:
--   1  the media item's id: PhotoKit's localIdentifier ("UUID/L0/001"), which is
--      what Photos' dictionary gives as a media item's id
--
-- Output (JSON):
--   {"shown": true}
--   {"error": "notFound"}
--
-- Apple Events go only to Photos. The script only looks up the item and shows
-- it: it changes nothing in the library.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 1 then error "photos-show expects 1 argument" number 1000
	set itemID to item 1 of argv
	try
		tell application "Photos"
			set theItem to media item id itemID
			-- Resolves the reference: an id Photos does not know fails here, not later.
			set foundID to id of theItem
		end tell
	on error errorMessage number errorNumber
		if errorNumber is -1728 or errorNumber is -1719 then return my toJSON(current application's NSDictionary's dictionaryWithObject:"notFound" forKey:"error")
		error errorMessage number errorNumber
	end try
	tell application "Photos"
		activate
		spotlight theItem
	end tell
	return my toJSON(current application's NSDictionary's dictionaryWithObject:true forKey:"shown")
end run

on toJSON(value)
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:value options:0 |error|:(reference)
	if jsonData is missing value then error "Orbit could not encode the result as JSON." number 1001
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end toJSON
