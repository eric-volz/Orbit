-- Test fixture (targets no app): fails with the error number in argument 1 and the
-- message in argument 2; with "none" as the number, without a number.
on run argv
	set errorNumber to item 1 of argv
	set errorMessage to item 2 of argv
	if errorNumber is "none" then error errorMessage
	error errorMessage number (errorNumber as integer)
end run
