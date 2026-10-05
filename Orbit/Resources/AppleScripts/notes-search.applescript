-- Orbit: search_notes - finds notes in Apple Notes, newest first.
--
-- Arguments (argv), all text - never part of the script source:
--   1  search terms, one per line; every term must occur in the note's name or text
--      (compared the way Notes compares text: case-insensitive). No terms: every note.
--   2  folder name: only the notes directly in folders with this name (in any account,
--      nested folders included). Empty: all folders.
--   3  maximum number of notes to return
--   4  maximum number of characters of each note's text to return ("start")
--   5  names of top-level folders whose notes are left out, one per line (the
--      localized "Recently Deleted" folder)
--   6  seconds (from the start) the searches of the notes' text may take, so the run ends
--      before its time limit: a term whose text search would end later (judged by the longest
--      text search so far) is looked for in the names only, and so is every term after it.
--      Optional (35).
--
-- Output (JSON):
--   {"notes": [{"id": text, "name": text, "folder": text, "modified": seconds since 1970,
--               "locked": boolean, "start": text}], "total": number of matching notes,
--    "textSearched": boolean, "titleOnlyTerms": [terms], "folders": [names of all folders]}
--   "folders" only when nothing matched in all folders (no folder name given) and time is left:
--   people name a note by its folder ("my recipe note" for a note in "Recipes"), so the agent
--   can then look in a folder.
--   {"error": "folderNotFound", "folders": [names of all folders]}
--
-- The ids and modification dates of the notes to search (all, or those of the folders with
-- that name) are read at once without looking at their text; then each term is searched once,
-- in the same notes, for ids only; the lists are joined here. "start" stays empty for locked
-- notes. If Notes cannot search the notes' text (an error other than a denied permission, a
-- missing app or a timeout), only the names are searched and "textSearched" is false;
-- "titleOnlyTerms" are the terms looked for in the names only because time ran short. Apple
-- Events go only to Notes. Handlers that do not talk to Notes (rankedMatches, textSearchFits,
-- rowDictionary, isFatal, nonEmptyLines, prefix, toJSON) are tested on their own by Orbit's
-- unit tests.

use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	if (count of argv) < 5 then error "notes-search expects 5 arguments" number 1000
	set startTime to current date
	set terms to my nonEmptyLines(item 1 of argv)
	set folderName to item 2 of argv
	set maxNotes to (item 3 of argv) as integer
	set startLength to (item 4 of argv) as integer
	set textBudget to 35
	if (count of argv) > 5 then set textBudget to (item 6 of argv) as integer
	set excludedIDs to my noteIDsInTopLevelFolders(my nonEmptyLines(item 5 of argv))

	-- Where to search: all notes (missing value), or the folders with this name.
	set scopes to {missing value}
	if folderName is not "" then
		set {folderRefs, folderNames} to my allFolders()
		set scopes to {}
		repeat with i from 1 to count of folderRefs
			if (item i of folderNames) = folderName then set end of scopes to item i of folderRefs
		end repeat
		if (count of scopes) = 0 then return my folderNotFound(folderNames)
	end if

	-- Ids and modification dates of every note there (two Apple Events per scope, no text).
	set scopeIDs to {}
	set scopeDates to {}
	repeat with i from 1 to count of scopes
		set {noteIDs, noteDates} to my notesIn(item i of scopes)
		set scopeIDs to scopeIDs & noteIDs
		set scopeDates to scopeDates & noteDates
	end repeat

	-- Each term: one search of names and texts in the same notes, for ids only. Once a term had
	-- to be looked for in the names only, so is every term after it.
	set requiredSets to {}
	set titleOnlyTerms to {}
	set textSearched to true
	set textSearchSeconds to 0
	repeat with i from 1 to count of terms
		set term to item i of terms
		set namesOnly to not my textSearchFits(i, (current date) - startTime, textSearchSeconds, textBudget, (count of titleOnlyTerms) > 0)
		if namesOnly then set end of titleOnlyTerms to term
		set searchStart to current date
		set termIDs to current application's NSMutableSet's |set|()
		repeat with j from 1 to count of scopes
			set {foundIDs, foundInText} to my idsMatching(item j of scopes, term, namesOnly)
			(termIDs's addObjectsFromArray:foundIDs)
			if not (foundInText or namesOnly) then set textSearched to false
		end repeat
		if not namesOnly then
			-- Only a search of the texts tells how long the next one may take: the longest so far.
			set searchSeconds to (current date) - searchStart
			if searchSeconds > textSearchSeconds then set textSearchSeconds to searchSeconds
		end if
		set end of requiredSets to termIDs
	end repeat

	set {ranked, datesByID} to my rankedMatches(scopeIDs, scopeDates, excludedIDs, requiredSets)
	set total to (ranked's |count|()) as integer
	set rows to current application's NSMutableArray's array()
	repeat with i from 1 to total
		if ((rows's |count|()) as integer) >= maxNotes then exit repeat
		set noteID to (ranked's objectAtIndex:(i - 1)) as text
		set row to my noteRow(noteID, (datesByID's objectForKey:noteID), startLength)
		if row is not missing value then (rows's addObject:row)
	end repeat
	set resultKeys to {"notes", "total", "textSearched", "titleOnlyTerms"}
	set resultValues to {rows, total, textSearched, titleOnlyTerms}
	if total = 0 and folderName is "" and ((current date) - startTime) < textBudget then
		try
			set {folderRefs, folderNames} to my allFolders()
			set end of resultKeys to "folders"
			set end of resultValues to folderNames
		on error errorMessage number errorNumber
			if my isFatal(errorNumber) then error errorMessage number errorNumber
		end try
	end if
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:resultValues forKeys:resultKeys)
end run

-- The ids and modification dates of every note in theFolder (missing value: all notes): two
-- requests that look at no text.
on notesIn(theFolder)
	tell application "Notes"
		if theFolder is missing value then
			set noteIDs to id of every note
			set noteDates to modification date of every note
		else
			set noteIDs to id of every note of theFolder
			set noteDates to modification date of every note of theFolder
		end if
	end tell
	if (count of noteIDs) is not (count of noteDates) then error "The notes changed during the search." number 1002
	return {noteIDs, noteDates}
end notesIn

-- The ids of the notes in theFolder (missing value: all notes) whose name or text contains
-- term, and whether the text was searched: with namesOnly, or if Notes fails to search the
-- text, only the names are searched.
on idsMatching(theFolder, term, namesOnly)
	set textSearched to not namesOnly
	tell application "Notes"
		if theFolder is missing value then
			if textSearched then
				try
					set noteIDs to id of every note whose name contains term or plaintext contains term
				on error errorMessage number errorNumber
					if my isFatal(errorNumber) then error errorMessage number errorNumber
					set textSearched to false
				end try
			end if
			if not textSearched then set noteIDs to id of every note whose name contains term
		else
			if textSearched then
				try
					set noteIDs to id of every note of theFolder whose name contains term or plaintext contains term
				on error errorMessage number errorNumber
					if my isFatal(errorNumber) then error errorMessage number errorNumber
					set textSearched to false
				end try
			end if
			if not textSearched then set noteIDs to id of every note of theFolder whose name contains term
		end if
	end tell
	return {noteIDs, textSearched}
end idsMatching

-- Whether the term at termIndex is searched in the notes' text: always the first one; a
-- further one only when no term before it was looked for in the names only (titleOnlyBefore)
-- and elapsedSeconds since the start plus the longest search of the texts so far
-- (textSearchSeconds) stays within budgetSeconds.
on textSearchFits(termIndex, elapsedSeconds, textSearchSeconds, budgetSeconds, titleOnlyBefore)
	if termIndex = 1 then return true
	if titleOnlyBefore then return false
	return elapsedSeconds + textSearchSeconds <= budgetSeconds
end textSearchFits

-- Errors no other search can avoid: a denied permission, a missing app, a timeout or
-- a cancellation.
on isFatal(errorNumber)
	return errorNumber is in {-1743, -1744, -600, -609, -1712, -128}
end isFatal

-- One result row, or missing value when the note is gone.
on noteRow(noteID, modifiedDate, startLength)
	try
		tell application "Notes"
			set theNote to note id noteID
			set noteName to name of theNote
			set isLocked to password protected of theNote
		end tell
	on error errorMessage number errorNumber
		if errorNumber is -1728 or errorNumber is -1719 then return missing value
		error errorMessage number errorNumber
	end try
	set folderName to ""
	try
		tell application "Notes" to set folderName to name of container of theNote
	end try
	set noteStart to ""
	if not isLocked then
		try
			tell application "Notes" to set noteText to plaintext of theNote
			set noteStart to my prefix(noteText, startLength)
		end try
	end if
	return my rowDictionary(noteID, noteName, folderName, modifiedDate, isLocked, noteStart)
end noteRow

-- Ids of the notes in top-level folders with one of these names.
on noteIDsInTopLevelFolders(folderNames)
	set noteIDs to current application's NSMutableSet's |set|()
	if (count of folderNames) = 0 then return noteIDs
	set wanted to current application's NSSet's setWithArray:folderNames
	tell application "Notes" to set theAccounts to every account
	repeat with i from 1 to count of theAccounts
		set theAccount to item i of theAccounts
		tell application "Notes"
			set theFolders to every folder of theAccount
			set theNames to name of every folder of theAccount
		end tell
		if (count of theFolders) = (count of theNames) then
			repeat with j from 1 to count of theFolders
				if (wanted's containsObject:(item j of theNames)) as boolean then
					tell application "Notes" to set folderNoteIDs to id of every note of (item j of theFolders)
					(noteIDs's addObjectsFromArray:folderNoteIDs)
				end if
			end repeat
		end if
	end repeat
	return noteIDs
end noteIDsInTopLevelFolders

-- Every folder of every account, subfolders included, each once: {references, names}.
on allFolders()
	set folderRefs to {}
	set folderNames to {}
	set seenIDs to current application's NSMutableSet's |set|()
	tell application "Notes" to set theAccounts to every account
	repeat with i from 1 to count of theAccounts
		set {accountRefs, accountNames} to my foldersIn(item i of theAccounts, seenIDs)
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

on folderNotFound(folderNames)
	return my toJSON(current application's NSDictionary's dictionaryWithObjects:{"folderNotFound", folderNames} forKeys:{"error", "folders"})
end folderNotFound

-- The notes of the scope (parallel lists of ids and dates) that are not in excludedIDs and are
-- in every set of requiredSets, each once, newest first: {their ids (an array), the dates by
-- id (a dictionary)}. Sets and sorting in Foundation, no loop over the notes.
on rankedMatches(scopeIDs, scopeDates, excludedIDs, requiredSets)
	set datesByID to current application's NSDictionary's dictionaryWithObjects:scopeDates forKeys:scopeIDs
	set wanted to current application's NSMutableSet's setWithArray:scopeIDs
	repeat with i from 1 to count of requiredSets
		(wanted's intersectSet:(item i of requiredSets))
	end repeat
	(wanted's minusSet:excludedIDs)
	set newestFirst to (datesByID's keysSortedByValueUsingSelector:"compare:")'s reverseObjectEnumerator()'s allObjects()
	set ranked to newestFirst's filteredArrayUsingPredicate:(current application's NSPredicate's predicateWithFormat:"SELF IN %@" argumentArray:{wanted})
	return {ranked, datesByID}
end rankedMatches

on rowDictionary(noteID, noteName, folderName, modifiedDate, isLocked, noteStart)
	set modifiedSeconds to ((current application's NSDate's dateWithTimeInterval:0 sinceDate:modifiedDate)'s timeIntervalSince1970()) as real
	return current application's NSDictionary's dictionaryWithObjects:{noteID, noteName, folderName, modifiedSeconds, isLocked, noteStart} forKeys:{"id", "name", "folder", "modified", "locked", "start"}
end rowDictionary

-- The lines of theText that are not empty.
on nonEmptyLines(theText)
	set found to {}
	repeat with i from 1 to count of paragraphs of theText
		set lineText to paragraph i of theText
		if lineText is not "" then set end of found to lineText
	end repeat
	return found
end nonEmptyLines

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
