-- Orbit: create_note - creates a note in Apple Notes (only after the user confirmed it).
--
-- Arguments (argv), all text - never part of the script source:
--   1  the note's body as HTML (Orbit builds it from the title and the text and escapes
--      both; Notes takes the first line as the note's name)
--   2  folder name: the first folder with this name (the default account's folders
--      first, nested folders included). Empty: the default account's default folder.
--   3  names of folders a note is never created in, one per line (the localized
--      "Recently Deleted" folder)
--
-- Output (JSON):
--   {"id": text, "name": text, "folder": text}
--   {"error": "folderNotFound", "folders": [names of all folders a note may go to]}
--
-- Apple Events go only to Notes. Handlers that do not talk to Notes (folderIndex,
-- allowedNames, nonEmptyLines, toJSON) are tested on their own by Orbit's unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 3 then error "notes-create expects 3 arguments" number 1000
	set noteHTML to item 1 of argv
	set folderName to item 2 of argv
	set excludedNames to my nonEmptyLines(item 3 of argv)
	if folderName is "" then
		tell application "Notes" to set targetFolder to default folder of default account
	else
		set {folderRefs, folderNames} to my allFolders()
		set matchIndex to my folderIndex(folderNames, folderName, excludedNames)
		if matchIndex = 0 then
			return my toJSON(current application's NSDictionary's dictionaryWithObjects:{"folderNotFound", my allowedNames(folderNames, excludedNames)} forKeys:{"error", "folders"})
		end if
		set targetFolder to item matchIndex of folderRefs
	end if
	tell application "Notes"
		set newNote to make new note at targetFolder with properties {body:noteHTML}
		set newID to id of newNote
		set newName to name of newNote
		set targetName to name of targetFolder
	end tell
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{newID, newName, targetName} forKeys:{"id", "name", "folder"})
end run

-- Every folder of every account, the default account first, subfolders included,
-- each once: {references, names}.
on allFolders()
	tell application "Notes"
		set theAccounts to every account
		set defaultID to id of default account
	end tell
	set orderedAccounts to {}
	repeat with i from 1 to count of theAccounts
		set theAccount to item i of theAccounts
		tell application "Notes" to set accountID to id of theAccount
		if accountID = defaultID then
			set orderedAccounts to {theAccount} & orderedAccounts
		else
			set end of orderedAccounts to theAccount
		end if
	end repeat
	set folderRefs to {}
	set folderNames to {}
	set seenIDs to current application's NSMutableSet's |set|()
	repeat with i from 1 to count of orderedAccounts
		set {accountRefs, accountNames} to my foldersIn(item i of orderedAccounts, seenIDs)
		set folderRefs to folderRefs & accountRefs
		set folderNames to folderNames & accountNames
	end repeat
	return {folderRefs, folderNames}
end allFolders

on foldersIn(theContainer, seenIDs)
	set folderRefs to {}
	set folderNames to {}
	tell application "Notes" to set theFolders to every folder of theContainer
	repeat with i from 1 to count of theFolders
		set theFolder to item i of theFolders
		tell application "Notes"
			set folderID to id of theFolder
			set folderName to name of theFolder
		end tell
		if not ((seenIDs's containsObject:folderID) as boolean) then
			(seenIDs's addObject:folderID)
			set end of folderRefs to theFolder
			set end of folderNames to folderName
			set {childRefs, childNames} to my foldersIn(theFolder, seenIDs)
			set folderRefs to folderRefs & childRefs
			set folderNames to folderNames & childNames
		end if
	end repeat
	return {folderRefs, folderNames}
end foldersIn

-- The position of the first folder named folderName (compared like AppleScript compares
-- text: case-insensitive) that is not excluded; 0 when there is none.
on folderIndex(folderNames, folderName, excludedNames)
	repeat with i from 1 to count of folderNames
		set candidate to item i of folderNames
		if candidate = folderName and excludedNames does not contain candidate then return i
	end repeat
	return 0
end folderIndex

-- The folder names without the excluded ones, each once.
on allowedNames(folderNames, excludedNames)
	set found to {}
	repeat with i from 1 to count of folderNames
		set candidate to item i of folderNames
		if excludedNames does not contain candidate and found does not contain candidate then set end of found to candidate
	end repeat
	return found
end allowedNames

-- The lines of theText that are not empty.
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
