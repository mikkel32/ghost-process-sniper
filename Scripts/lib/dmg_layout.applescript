-- Arranges the mounted installer volume: icon view, background artwork, and icon positions.
-- Positions are icon centers in a 660 x 420 content area and must match
-- Packaging/render-artwork.swift (appIconCenter / applicationsIconCenter).
on run argv
	set volumeName to item 1 of argv
	set appName to item 2 of argv
	tell application "Finder"
		tell disk volumeName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set pathbar visible of container window to false
			set sidebar width of container window to 0
			-- 420 pt of content plus the title bar.
			set the bounds of container window to {200, 140, 860, 588}
			set viewOptions to the icon view options of container window
			set arrangement of viewOptions to not arranged
			set icon size of viewOptions to 128
			set text size of viewOptions to 13
			set shows item info of viewOptions to false
			set shows icon preview of viewOptions to true
			set background picture of viewOptions to file ".background:background.tiff"
			-- With hidden files shown (Command-Shift-Period), Finder would auto-place these in the
			-- visible grid and push the real icons out of place. Park them outside the window.
			repeat with hiddenName in {".background", ".fseventsd", ".Trashes", ".DS_Store"}
				try
					set position of item (hiddenName as text) of container window to {900, 900}
				end try
			end repeat
			set position of item (appName & ".app") of container window to {170, 205}
			set position of item "Applications" of container window to {490, 205}
			close
			open
			update without registering applications
			delay 2
			close
		end tell
	end tell
end run
