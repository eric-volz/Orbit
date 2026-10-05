-- Orbit: the items selected in Finder, as POSIX paths - the context of a
-- request (the context chips when Orbit opens, get_frontmost_context).
--
-- Arguments (argv), all text - never part of the script source:
--   1  the most paths to return (a whole number, at least 1)
--
-- Output - no JSON: the script uses no AppleScriptObjC, so a run takes a few
-- hundredths of a second instead of a few tenths (it runs while the panel
-- opens). Fields separated by NUL characters (character id 0), which no path
-- can contain:
--   <number of selected items> NUL <POSIX path 1> NUL <POSIX path 2> ...
-- Only the first items become paths; an item that is no file or folder (e.g. a
-- server in the sidebar) is counted but has no path.
--
-- Apple Events go only to Finder. The script only reads the selection: it
-- opens, moves and changes nothing.

on run argv
	if (count of argv) < 1 then error "finder-selection expects 1 argument" number 1000
	set maxItems to my itemLimit(item 1 of argv)
	tell application "Finder"
		set theSelection to (get selection)
		if class of theSelection is not list then set theSelection to {theSelection}
		set total to count of theSelection
		set theAliases to {}
		repeat with i from 1 to my smaller(total, maxItems)
			try
				set end of theAliases to (item i of theSelection) as alias
			end try
		end repeat
	end tell
	return my selectionOutput(total, my posixPaths(theAliases))
end run

-- The limit from the argument: a whole number, at least 1.
on itemLimit(argument)
	try
		set limit to argument as integer
	on error
		set limit to 1
	end try
	if limit < 1 then set limit to 1
	return limit
end itemLimit

on smaller(a, b)
	if a < b then return a
	return b
end smaller

on posixPaths(theAliases)
	set thePaths to {}
	repeat with anAlias in theAliases
		set end of thePaths to POSIX path of (contents of anAlias)
	end repeat
	return thePaths
end posixPaths

on selectionOutput(total, thePaths)
	set separator to character id 0
	set output to (total as text)
	repeat with aPath in thePaths
		set output to output & separator & (contents of aPath)
	end repeat
	return output
end selectionOutput
