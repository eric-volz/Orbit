-- Test fixture (targets no app): prints a value of the kind in argument 1.
on run argv
	set wanted to item 1 of argv
	if wanted is "list" then return {"a", "b", 3}
	if wanted is "number" then return 42
	if wanted is "empty" then return ""
	if wanted is "nothing" then return
	if wanted is "lines" then return "eins" & linefeed & "zwei"
	return "text"
end run
