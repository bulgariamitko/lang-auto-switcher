-- Installer applet for LangAutoSwitcher.
-- Inside this .app bundle, Contents/Resources/LangAutoSwitcher.app holds the
-- input method to install. On run we ask the user, then cp -R it into
-- ~/Library/Input Methods/. No admin password required.

on run
	set installerPosix to POSIX path of (path to me)
	set sourceApp to installerPosix & "Contents/Resources/LangAutoSwitcher.app"
	set installDir to (POSIX path of (path to home folder as text)) & "Library/Input Methods/"
	set targetApp to installDir & "LangAutoSwitcher.app"

	try
		set confirm to display dialog ¬
			"This will install LangAutoSwitcher into your Input Methods folder. No admin password required." & return & return & ¬
			"After install you'll need to log out and back in once, then add it from System Settings → Keyboard → Input Sources." ¬
			buttons {"Cancel", "Install"} ¬
			default button "Install" ¬
			with title "Install LangAutoSwitcher" ¬
			with icon note
	on error
		return
	end try
	if button returned of confirm is not "Install" then return

	try
		do shell script "mkdir -p " & quoted form of installDir
		do shell script "/usr/bin/killall LangAutoSwitcher 2>/dev/null || true"
		do shell script "/bin/rm -rf " & quoted form of targetApp
		do shell script "/bin/cp -R " & quoted form of sourceApp & " " & quoted form of installDir
	on error errMsg
		display dialog "Install failed:" & return & return & errMsg ¬
			buttons {"OK"} default button "OK" with icon stop ¬
			with title "LangAutoSwitcher"
		return
	end try

	display dialog ¬
		"LangAutoSwitcher is installed." & return & return & ¬
		"Final steps:" & return & ¬
		"   1. Log out and log back in" & return & ¬
		"   2. System Settings → Keyboard → Input Sources" & return & ¬
		"   3. Click Edit… → + → search 'LangAutoSwitcher' → Add" & return & ¬
		"   4. Click 🌐 in the menu bar and pick LangAutoSwitcher" & return & return & ¬
		"All future updates will install automatically." ¬
		buttons {"Done"} default button "Done" ¬
		with title "Install complete" with icon note
end run
