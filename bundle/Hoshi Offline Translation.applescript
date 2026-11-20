-- Hoshi Offline Translation: the app install.sh makes from this file with
-- osacompile, in /Applications (or ~/Applications). It holds no logic of its
-- own: it runs "Start Translation.command" from the folder the install put it
-- in, shows a progress window while that waits, and shows what it says at the
-- end. Its Resources folder holds two lines the installer wrote: that folder
-- (install-folder.txt) and the bundle's support line (support.txt).
--
-- An app made by osacompile, not a script set as an app's executable: macOS
-- gives this one a Dock icon and a progress window with a Stop button. A plain
-- script shows nothing at all while it waits, which can be minutes.

property appName : "Hoshi Offline Translation"

on run
	set resourcesFolder to POSIX path of (path to me) & "Contents/Resources/"
	set installFolder to readLine(resourcesFolder & "install-folder.txt")
	set support to readLine(resourcesFolder & "support.txt")
	set starter to installFolder & "/Start Translation.command"
	if installFolder is "" or not fileExists(starter) then
		set message to appName & " isn't installed on this Mac, or its folder has been moved or deleted"
		if installFolder is not "" then set message to message & ":" & return & installFolder
		set message to message & return & return & "To install it, double-click Install.command in the Hoshi bundle folder (on the USB stick it came on)."
		tellUser(message, support)
		return
	end if

	set statusFile to do shell script "/usr/bin/mktemp -t hoshi-start"
	set logFile to installFolder & "/start-translation.log"
	set pid to do shell script "/bin/bash " & quoted form of starter & " --app " & quoted form of statusFile & " > " & quoted form of logFile & " 2>&1 < /dev/null & echo $!"
	set progress total steps to -1
	set progress completed steps to 0
	set progress description to "Starting " & appName
	set progress additional description to "Getting ready"
	try
		repeat
			set state to paragraphs of (do shell script "if kill -0 " & pid & " 2>/dev/null; then echo running; else echo finished; fi; /usr/bin/sed -n 's/^progress: //p' " & quoted form of statusFile & " | /usr/bin/tail -n 1")
			if (count of state) > 1 then set progress additional description to item 2 of state
			if item 1 of state is "finished" then exit repeat
			delay 1
		end repeat
	on error number -128 -- Stop, in the progress window
		do shell script "kill " & pid & " 2>/dev/null; rm -f " & quoted form of statusFile & "; true"
		return
	end try

	set finished to do shell script "/usr/bin/sed -n 's/^done: //p' " & quoted form of statusFile
	set message to do shell script "/usr/bin/sed -n 's/^dialog: //p' " & quoted form of statusFile
	do shell script "rm -f " & quoted form of statusFile
	if finished is "" then
		set message to appName & " stopped before it could say what happened." & return & return & "A record of what it did is in:" & return & logFile & return & return & "Try opening it again."
		tellUser(message, support)
	else if message is not "" then
		-- the starter has given the support line already, where it has one
		tellUser(message, "")
	end if
	-- All well: the starter has opened the translation page, and there is nothing to say.
end run

on tellUser(message, support)
	if support is not "" then set message to message & return & return & "For help: " & support
	activate
	display dialog message buttons {"OK"} default button 1 with title appName with icon caution
end tellUser

on readLine(path)
	try
		return do shell script "/usr/bin/head -n 1 " & quoted form of path
	on error
		return ""
	end try
end readLine

on fileExists(path)
	try
		do shell script "test -f " & quoted form of path
		return true
	on error
		return false
	end try
end fileExists
