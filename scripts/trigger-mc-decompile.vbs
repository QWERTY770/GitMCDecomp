' ===========================================================================
'  Hidden launcher for trigger-mc-decompile.ps1
'
'  Why this file exists:
'    "powershell.exe -WindowStyle Hidden" does NOT prevent the flash. Windows
'    creates a visible console for powershell.exe first and PowerShell hides it
'    a moment later, so every scheduled run blinks a black window.
'    wscript.exe is a GUI subsystem program and never owns a console, and
'    WScript.Shell.Run(cmd, 0, ...) starts the child with SW_HIDE, so the
'    console is hidden from its very first frame. No flash at all.
'
'  Usage (normally called by Task Scheduler):
'    wscript.exe "D:\...\scripts\trigger-mc-decompile.vbs"
'    wscript.exe "D:\...\scripts\trigger-mc-decompile.vbs" -DryRun    (debugging)
'
'  Extra arguments are forwarded to the .ps1 unchanged. Keep them free of
'  quotes and spaces (the ones this project uses: -DryRun, -Force, -Wait).
'
'  The launcher waits for PowerShell and exits with its exit code, so the task's
'  "Last Run Result" tells you whether the trigger actually succeeded.
' ===========================================================================
Option Explicit

Dim fso, sh, baseDir, ps1, extra, i, cmd, rc

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1     = fso.BuildPath(baseDir, "trigger-mc-decompile.ps1")

If Not fso.FileExists(ps1) Then
    ' Nothing to run: fail loudly instead of pretending success.
    WScript.Quit 2
End If

extra = ""
For i = 0 To WScript.Arguments.Count - 1
    extra = extra & " """ & WScript.Arguments(i) & """"
Next

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive" & _
      " -File """ & ps1 & """" & extra

' 0 = SW_HIDE (hidden window), True = wait for the child and get its exit code
rc = sh.Run(cmd, 0, True)

WScript.Quit rc
