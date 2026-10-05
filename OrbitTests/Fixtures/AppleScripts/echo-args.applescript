-- Test fixture (targets no app): prints its arguments as JSON {"count": n, "args": [...]}.
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
	set found to current application's NSMutableArray's array()
	repeat with i from 1 to count of argv
		(found's addObject:(item i of argv))
	end repeat
	set payload to current application's NSDictionary's dictionaryWithObjects:{(count of argv), found} forKeys:{"count", "args"}
	set {jsonData, jsonError} to current application's NSJSONSerialization's dataWithJSONObject:payload options:0 |error|:(reference)
	return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as text
end run
