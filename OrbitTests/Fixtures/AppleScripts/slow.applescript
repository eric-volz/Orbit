-- Test fixture (targets no app): waits the seconds in argument 1, then prints "done".
on run argv
	delay ((item 1 of argv) as real)
	return "done"
end run
