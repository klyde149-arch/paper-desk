' Невидимый лаунчер для trigger_tick.ps1.
' wscript.exe не является консольным приложением, поэтому окно не появляется
' независимо от того, какой терминал стоит по умолчанию (Windows Terminal ломает
' -WindowStyle Hidden у powershell). Второй аргумент Run = 0 -> скрытое окно.
CreateObject("WScript.Shell").Run _
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\klyde\trading-sim\tools\trigger_tick.ps1""", _
  0, False
