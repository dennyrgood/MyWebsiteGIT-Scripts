param (
    [Parameter(Mandatory = $true, Position = 0)]
    [int]$Id
)

Stop-Process -Id $Id -Force