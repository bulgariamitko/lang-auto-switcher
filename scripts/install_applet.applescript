-- Bulgarian installer applet for LangAutoSwitcher.
-- Contents/Resources/LangAutoSwitcher.app holds the input method to install.
-- On run we ask the user, then cp -R it into ~/Library/Input Methods/.
-- No admin password required.

on run
	set installerPosix to POSIX path of (path to me)
	set sourceApp to installerPosix & "Contents/Resources/LangAutoSwitcher.app"
	set installDir to (POSIX path of (path to home folder as text)) & "Library/Input Methods/"
	set targetApp to installDir & "LangAutoSwitcher.app"

	-- Use the embedded Аб icon for every dialog, regardless of macOS's
	-- default applet-icon resolution.
	set iconAlias to (path to resource "applet.icns") as alias

	try
		set confirm to display dialog ¬
			"LangAutoSwitcher ще бъде инсталиран в твоята папка с методи за въвеждане. Не се изисква администраторска парола." & return & return & ¬
			"След инсталацията трябва да излезеш от профила си и да влезеш отново веднъж. След това го добави от Системни настройки → Клавиатура → Източници на въвеждане." ¬
			buttons {"Отказ", "Инсталирай"} ¬
			default button "Инсталирай" ¬
			with title "Инсталиране на LangAutoSwitcher" ¬
			with icon iconAlias
	on error
		return
	end try
	if button returned of confirm is not "Инсталирай" then return

	try
		do shell script "mkdir -p " & quoted form of installDir
		do shell script "/usr/bin/killall LangAutoSwitcher 2>/dev/null || true"
		do shell script "/bin/rm -rf " & quoted form of targetApp
		do shell script "/bin/cp -R " & quoted form of sourceApp & " " & quoted form of installDir
	on error errMsg
		display dialog "Инсталацията се провали:" & return & return & errMsg ¬
			buttons {"OK"} default button "OK" ¬
			with title "LangAutoSwitcher" ¬
			with icon iconAlias
		return
	end try

	display dialog ¬
		"LangAutoSwitcher е инсталиран." & return & return & ¬
		"Последни стъпки:" & return & ¬
		"   1. Излез от профила си и влез отново" & return & ¬
		"   2. Системни настройки → Клавиатура → Източници на въвеждане" & return & ¬
		"   3. Натисни Edit… → + → потърси „LangAutoSwitcher" & "“ → Add" & return & ¬
		"   4. Натисни 🌐 в горната лента и избери LangAutoSwitcher" & return & return & ¬
		"Всички бъдещи обновления ще се инсталират автоматично." ¬
		buttons {"Готово"} default button "Готово" ¬
		with title "Инсталацията е завършена" ¬
		with icon iconAlias
end run
