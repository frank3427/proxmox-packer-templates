$ErrorActionPreference = "Stop"

# Disable IPv6 because it leads to problems with proxmox terraform
Get-NetAdapter | foreach { Disable-NetAdapterBinding -InterfaceAlias $_.Name -ComponentID ms_tcpip6 }

# Reset auto logon count
# https://docs.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon-logoncount#logoncount-known-issue
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name AutoLogonCount -Value 0

# Run a custom installer script if there is one
$customInstaller = Join-Path $PSScriptRoot "custom\custom.ps1"
if (Test-Path $customInstaller) {
    & $customInstaller
}

Enable-PSRemoting -SkipNetworkProfileCheck -Force

# WinRM only answers on the HTTPS listener; recreated with a fresh self-signed
# cert here because sysprep can strip listeners from clones.
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation 'Cert:\LocalMachine\My'
Get-ChildItem -Path WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null

if (Get-NetFirewallRule -Name 'WINRM-HTTPS-In-TCP' -ErrorAction SilentlyContinue) {
    Set-NetFirewallRule -Name 'WINRM-HTTPS-In-TCP' -Enabled True -RemoteAddress Any
} else {
    New-NetFirewallRule -Name 'WINRM-HTTPS-In-TCP' -DisplayName 'Windows Remote Management (HTTPS-In)' `
        -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null
}

# Basic auth for the build/test tooling; with AllowUnencrypted off it is only
# accepted on the HTTPS listener.
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'

# On clones (running from the copy that sysprep.ps1 persisted to disk) turn UAC
# back on. It must stay off while this script runs so that FirstLogonCommands
# are elevated; the change takes effect on the clone's next reboot. Remote
# admin keeps working through LocalAccountTokenFilterPolicy, set at build time
# by ConfigureRemotingForAnsible.ps1.
if ($PSScriptRoot -like "$env:SystemRoot*") {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -Value 1
}
