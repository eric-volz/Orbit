-- Test fixture (targets no app): prints as many "x" as argument 1 says.
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	set wanted to (item 1 of argv) as integer
	return ((current application's NSString's |string|()'s stringByPaddingToLength:wanted withString:"x" startingAtIndex:0) as text)
end run
