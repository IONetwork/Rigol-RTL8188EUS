:: @file fix-line-endings.bat
:: @brief Convert wifi.sh to LF line endings without a UTF-8 BOM, the only form the instrument's shell runs.
:: @note Double-click it to fix wifi.sh in the same folder, or drag another file onto it to fix that one.
:: @return 0 when the file is fixed or already fine, 1 when it is missing or saved as UTF-16.
@echo off
setlocal & rem keep the variables local to this run
set "TARGET=%~dp0wifi.sh" & rem default: wifi.sh beside this file
if not "%~1"=="" set "TARGET=%~f1" & rem a file dropped onto this one wins
set "SELF=%~f0" & rem this file, so PowerShell can read its code from it
::? cmd stops at exit /b, so the PowerShell code below the marker never reaches the batch parser.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:SELF); Invoke-Expression $s.Substring($s.LastIndexOf('#POWERSHELL#') + 12)" & rem run the code below the marker
set "RESULT=%errorlevel%" & rem PowerShell's verdict, before pause resets it
pause & rem keep the window open to show the result
::! No trailing "& rem" on the exit line: it runs after exit /b and resets the exit code to 0.
exit /b %RESULT%
#POWERSHELL#

#& Functions

<#
.SYNOPSIS
Convert the CRLF line endings of a file to LF and drop a UTF-8 BOM, leaving every other byte as saved.
.PARAMETER Path
File to fix.
.OUTPUTS
0 when the file is fixed or already fine, 1 when it is missing or saved as UTF-16.
#>
function Convert-LineEnding([string]$Path) {
    #- Read the file
    if (-not (Test-Path -LiteralPath $Path)) {  # nothing to fix
        Write-Host "not found: $Path"           # name the missing file
        return 1                                # report the failure
    }
    $bytes = [IO.File]::ReadAllBytes($Path)     # file exactly as the editor saved it

    #- Refuse UTF-16
    #? Removing bytes from UTF-16 text would corrupt it, and the instrument needs UTF-8 anyway.
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {  # UTF-16 byte order mark
        Write-Host "$Path is saved as UTF-16; save it as UTF-8 in your editor, then run this again"                                  # name the fix
        return 1                                                                                                                      # leave the file alone
    }

    #- Drop the BOM and every CR of a CRLF pair
    #? A UTF-8 BOM in front of #! stops the instrument from running the script.
    $start = 0                                                                                                     # first byte to keep
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }  # skip the UTF-8 BOM
    $kept = New-Object System.Collections.Generic.List[byte] $bytes.Length                                        # fixed content
    $converted = 0                                                                                                 # CRLF pairs turned into LF
    for ($i = $start; $i -lt $bytes.Length; $i++) {                                                                # every byte after the BOM
        if ($bytes[$i] -eq 13 -and $i + 1 -lt $bytes.Length -and $bytes[$i + 1] -eq 10) {                          # CR of a CRLF pair
            $converted++                                                                                           # count the pair
            continue                                                                                               # drop the CR, keep the LF
        }
        $kept.Add($bytes[$i])  # keep every other byte
    }

    #- Save and report
    if ($converted -eq 0 -and $start -eq 0) {                     # nothing to change
        Write-Host "$Path already has LF line endings, no change"  # report the clean file
        return 0                                                  # file is fine
    }
    [IO.File]::WriteAllBytes($Path, $kept.ToArray())                                # save the fixed content
    Write-Host "$Path : $converted CRLF line endings converted to LF"               # report the conversion
    if ($start -eq 3) { Write-Host "$Path : UTF-8 BOM removed" }                    # report the BOM removal
    return 0                                                                        # file is fixed
}

#& Entry Point
exit (Convert-LineEnding $env:TARGET)  # fix the target, exit with the result
