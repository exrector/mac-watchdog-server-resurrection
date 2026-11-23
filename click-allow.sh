#!/bin/zsh
# click-allow.sh: if macOS shows a "Tailscale Would Like to Add VPN Configurations"
# dialog, click Allow via System Events. Prints the result or "no VPN dialog found".
osascript << 'APPLESCRIPT_EOF' 2>&1
tell application "System Events"
  set foundDialog to false
  repeat with proc in (every process whose background only is false)
    try
      repeat with w in (every window of proc)
        try
          set wname to name of w as text
          if wname contains "VPN" or wname contains "Tailscale" then
            set foundDialog to true
            set btns to every button of w whose name is "Allow"
            if (count of btns) > 0 then
              click (item 1 of btns)
              return "clicked Allow in " & wname
            end if
          end if
        end try
      end repeat
    end try
  end repeat
  if foundDialog then
    return "VPN dialog found but no Allow button"
  else
    return "no VPN dialog found"
  end if
end tell
APPLESCRIPT_EOF
