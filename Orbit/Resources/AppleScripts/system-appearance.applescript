-- Orbit: switches macOS between the light and the dark appearance
-- (set_appearance, after the user confirmed it on its card).
--
-- Arguments (argv), all text - never part of the script source:
--   1  "dark" or "light"
--
-- Output (JSON, two booleans, written by the script itself - no
-- AppleScriptObjC needed):
--   {"dark": true, "changed": true}
-- "dark": the appearance afterwards; "changed": whether it was different before.
--
-- Apple Events go only to System Events. The script changes the appearance and
-- nothing else.

on run argv
	if (count of argv) < 1 then error "system-appearance expects 1 argument" number 1000
	set wantsDark to my wantsDarkMode(item 1 of argv)
	tell application "System Events"
		tell appearance preferences
			set wasDark to dark mode
			if wasDark is not wantsDark then set dark mode to wantsDark
			set isDark to dark mode
		end tell
	end tell
	return my answer(isDark, wasDark is not wantsDark)
end run

-- true for "dark", false for "light"; anything else is an error.
on wantsDarkMode(argument)
	if argument is "dark" then return true
	if argument is "light" then return false
	error "system-appearance expects dark or light" number 1001
end wantsDarkMode

on answer(isDark, changed)
	return "{\"dark\":" & (isDark as text) & ",\"changed\":" & (changed as text) & "}"
end answer
