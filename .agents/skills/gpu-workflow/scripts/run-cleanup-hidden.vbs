Option Explicit

If WScript.Arguments.Count < 2 Then
    WScript.Quit 2
End If

Dim cleanupScript, searchRoot, quote, command, exitCode
cleanupScript = WScript.Arguments(0)
searchRoot = WScript.Arguments(1)
quote = Chr(34)
command = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & _
    quote & cleanupScript & quote & " -SearchRoot " & quote & searchRoot & quote
exitCode = CreateObject("WScript.Shell").Run(command, 0, True)
WScript.Quit exitCode
