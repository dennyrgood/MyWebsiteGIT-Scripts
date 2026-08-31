$Server = 'smtp.mail.me.com'
$Port = 587

$Username = Read-Host 'iCloud email address'
$SecurePassword = Read-Host 'App-specific password' -AsSecureString

$BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)

try {
$Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

$tcp = [System.Net.Sockets.TcpClient]::new()
$tcp.Connect($Server, $Port)

$stream = $tcp.GetStream()

$reader = [System.IO.StreamReader]::new(
    $stream,
    [System.Text.Encoding]::ASCII,
    $false,
    4096,
    $true
)

$writer = [System.IO.StreamWriter]::new(
    $stream,
    [System.Text.Encoding]::ASCII,
    4096,
    $true
)

$writer.NewLine = "`r`n"

function Read-SmtpResponse {
    do {
        $line = $reader.ReadLine()

        if ($null -eq $line) {
            throw "SMTP server closed the connection."
        }

        Write-Host "S: $line"
    }
    while ($line -match '^\d{3}-')
}

function Send-SmtpCommand([string]$Command) {
    Write-Host "C: $Command"
    $writer.WriteLine($Command)
    $writer.Flush()
    Read-SmtpResponse
}

Write-Host ""
Write-Host "=== TCP CONNECTED: $Server`:$Port ==="
Write-Host ""

Read-SmtpResponse

Send-SmtpCommand "EHLO CWH"

Send-SmtpCommand "STARTTLS"

Write-Host ""
Write-Host "=== STARTING TLS ==="
Write-Host ""

$ssl = [System.Net.Security.SslStream]::new(
    $stream,
    $false,
    {
        param($sender, $certificate, $chain, $sslPolicyErrors)
        return $true
    }
)

$ssl.AuthenticateAsClient($Server)

Write-Host "TLS protocol: $($ssl.SslProtocol)"
Write-Host "Cipher:       $($ssl.CipherAlgorithm)"
Write-Host "Strength:     $($ssl.CipherStrength)"
Write-Host ""
Write-Host "=== TLS ESTABLISHED ==="
Write-Host ""

$reader = [System.IO.StreamReader]::new(
    $ssl,
    [System.Text.Encoding]::ASCII,
    $false,
    4096,
    $true
)

$writer = [System.IO.StreamWriter]::new(
    $ssl,
    [System.Text.Encoding]::ASCII,
    4096,
    $true
)

$writer.NewLine = "`r`n"

Send-SmtpCommand "EHLO CWH"

Write-Host "C: AUTH LOGIN"
$writer.WriteLine("AUTH LOGIN")
$writer.Flush()
Read-SmtpResponse

$user64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes($Username)
)

Write-Host "C: <base64 username redacted>"
$writer.WriteLine($user64)
$writer.Flush()
Read-SmtpResponse

$pass64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::ASCII.GetBytes($Password)
)

Write-Host "C: <base64 password redacted>"
$writer.WriteLine($pass64)
$writer.Flush()
Read-SmtpResponse

Write-Host ""
Write-Host "=== AUTH PHASE COMPLETE ==="
Write-Host ""

Send-SmtpCommand "MAIL FROM:<$Username>"

$Recipient = Read-Host 'Test recipient email address'

Send-SmtpCommand "RCPT TO:<$Recipient>"

Write-Host "C: DATA"
$writer.WriteLine("DATA")
$writer.Flush()
Read-SmtpResponse

$writer.WriteLine("From: $Username")
$writer.WriteLine("To: $Recipient")
$writer.WriteLine("Subject: CWH iCloud SMTP diagnostic")
$writer.WriteLine("Date: $([DateTime]::UtcNow.ToString('R'))")
$writer.WriteLine("Message-ID: <cwh-test-$([guid]::NewGuid())@icloud.com>")
$writer.WriteLine("")
$writer.WriteLine("This is a diagnostic SMTP message from CWH.")
$writer.WriteLine("Submitted at $([DateTime]::UtcNow.ToString('o')) UTC.")
$writer.WriteLine(".")
$writer.Flush()

Read-SmtpResponse

Send-SmtpCommand "QUIT"

}
catch {
Write-Host ""
Write-Host "=== ERROR ===" -ForegroundColor Red
Write-Host $_.Exception.Message -ForegroundColor Red
}
finally {
if ($BSTR -ne [IntPtr]::Zero) {
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
}

if ($writer) { $writer.Dispose() }
if ($reader) { $reader.Dispose() }
if ($ssl)    { $ssl.Dispose() }
if ($stream) { $stream.Dispose() }
if ($tcp)    { $tcp.Dispose() }

}
