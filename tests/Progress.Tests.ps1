$modulePath = Join-Path $PSScriptRoot '../src/Progress.ps1'
if (Test-Path -LiteralPath $modulePath) { . $modulePath }

Describe 'live progress reporting' {
    BeforeEach {
        # Keep the real machine state out of the test run.
        $script:progressDir = Join-Path $TestDrive 'progress'
        [IO.Directory]::CreateDirectory($script:progressDir) | Out-Null
        $env:LanProgressDirectory = $script:progressDir
    }
    AfterEach { $env:LanProgressDirectory = $null }

    It 'records the operation header and each step in order' {
        Start-LanProgress -Message 'เริ่ม'
        Write-LanProgress -Message 'ขั้นที่หนึ่ง'
        Write-LanProgress -Message 'ขั้นที่สอง' -Current 3 -Total 9

        $lines = @(Get-LanProgressLog)
        $lines.Count | Should Be 3
        ([string]$lines[0]) | Should Match 'เริ่มทำงาน'
        ([string]$lines[1]) | Should Match 'ขั้นที่หนึ่ง'
        ([string]$lines[2]) | Should Match 'ขั้นที่สอง'
        # Start-LanProgress truncates so a new run never shows the previous run's steps.
        Start-LanProgress -Message 'เริ่มใหม่'
        @(Get-LanProgressLog).Count | Should Be 1
    }
    It 'exposes the current step with its counter for the window to show' {
        Start-LanProgress -Message 'เริ่ม'
        Set-LanProgress -Message 'กำลังตั้งสิทธิ์' -Current 4 -Total 10
        $status = Get-LanProgressStatus
        $status | Should Not BeNullOrEmpty
        $status.Message | Should Be 'กำลังตั้งสิทธิ์'
        $status.Current | Should Be 4
        $status.Total | Should Be 10
        ([string]$status.Time) | Should Match '4/10'
    }
    It 'reports staleness instead of showing a step from an earlier run' {
        Start-LanProgress -Message 'เริ่ม'
        Set-LanProgress -Message 'ค้างอยู่'
        # Make the age deliberate; two Get-Date calls can have the same clock
        # tick, which made a zero-second threshold intermittently still fresh.
        $path=Get-LanProgressStatusPath
        $status=[IO.File]::ReadAllText($path)|ConvertFrom-Json
        $status.Updated=(Get-Date).AddMinutes(-2).ToString('o')
        [IO.File]::WriteAllText($path,($status|ConvertTo-Json -Compress),[Text.Encoding]::UTF8)
        (Get-LanProgressStatus -StaleSeconds 60) | Should BeNullOrEmpty
        (Get-LanProgressStatus -StaleSeconds 3600) | Should Not BeNullOrEmpty
    }
    It 'returns the newest lines when the log is longer than the tail' {
        Start-LanProgress -Message 'เริ่ม'
        foreach ($i in 1..30) { Add-LanProgressLog -Message "บรรทัดที่ $i" }
        $tail = @(Get-LanProgressLog -TailLines 5)
        $tail.Count | Should Be 5
        ([string]$tail[-1]) | Should Match 'บรรทัดที่ 30'
    }
    It 'reports nothing when no operation has run' {
        Clear-LanProgress
        (Get-LanProgressStatus) | Should BeNullOrEmpty
        @(Get-LanProgressLog).Count | Should Be 0
    }
    It 'throttles a long walk so it does not write a line per item' {
        $throttle = New-LanProgressThrottle
        $fired = 0
        for ($i=1; $i -le 500; $i++) { if (Test-LanProgressDue -Throttle $throttle -Interval 25 -Seconds 2) { $fired++ } }
        $fired | Should BeLessThan 40
        $fired | Should BeGreaterThan 0
    }
    It 'never fails the caller when the progress location is unusable' {
        $env:LanProgressDirectory = 'Z:\definitely-not-here\progress'
        { Start-LanProgress -Message 'เริ่ม' } | Should Not Throw
        { Write-LanProgress -Message 'ขั้น' } | Should Not Throw
        { Set-LanProgress -Message 'ขั้น' } | Should Not Throw
        { Add-LanProgressLog -Message 'ขั้น' } | Should Not Throw
        { Clear-LanProgress } | Should Not Throw
        (Get-LanProgressStatus) | Should BeNullOrEmpty
        @(Get-LanProgressLog).Count | Should Be 0
    }
    It 'keeps progress out of the restricted state folder' {
        # The state folder holds state.json with the credentials of a Protected Password share, so
        # it is restricted to SYSTEM and Administrators. Writing progress there made every read by
        # the signed-in user's window fail silently, and the log pane stayed empty until that folder
        # was opened with administrator rights. Progress lives in its own readable subfolder.
        $env:LanProgressDirectory = $null
        $stateRoot = Join-Path $env:ProgramData 'LanFileSharing'
        $directory = Get-LanProgressDirectory
        $directory | Should Not Be $stateRoot
        $directory.StartsWith($stateRoot,[StringComparison]::OrdinalIgnoreCase) | Should Be $true
        (Split-Path -Leaf $directory) | Should Be 'progress'
        (Get-LanProgressLogPath).StartsWith($directory,[StringComparison]::OrdinalIgnoreCase) | Should Be $true
    }
    It 'grants the signed-in user read access when it creates the progress folder' {
        $target = Join-Path $TestDrive 'acl-progress'
        (Initialize-LanProgressDirectory -Directory $target) | Should Be $true
        ([IO.Directory]::Exists($target)) | Should Be $true
        $acl = Get-Acl -LiteralPath $target
        $keys = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value })
        # Users and Authenticated Users: then a normal account, not only an administrator, can read.
        ($keys -contains 'S-1-5-32-545') | Should Be $true
        ($keys -contains 'S-1-5-11') | Should Be $true
        # Inheritance must reach the files, because the window opens the files themselves.
        $rule = @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' })[0]
        ($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit) | Should Not Be 0
    }
}
