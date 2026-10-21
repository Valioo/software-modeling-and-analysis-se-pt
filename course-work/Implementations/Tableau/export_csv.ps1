# =====================================================================
# export_csv.ps1 – изнася изгледите за Tableau в CSV файлове
# ---------------------------------------------------------------------
# Пускане (от PowerShell в тази папка):
#   powershell -ExecutionPolicy Bypass -File .\export_csv.ps1
#   powershell -ExecutionPolicy Bypass -File .\export_csv.ps1 -Server "localhost\SQLEXPRESS"
#
# -Server   – името на сървъра, както е в прозореца за вход на SSMS
# -Database – по подразбиране RiskManagementPlatform
# -OutDir   – по подразбиране папка "csv" до скрипта
#
# Вход с Windows акаунта (Integrated Security), както в SSMS.
# Числата се записват с точка (1287.37), датите – като 2026-10-20 22:46:29,
# независимо от регионалните настройки на Windows. Кодиране: UTF-8.
# =====================================================================
param(
    [string]$Server   = "localhost",
    [string]$Database = "RiskManagementPlatform",
    [string]$OutDir   = (Join-Path $PSScriptRoot "csv")
)

$ErrorActionPreference = "Stop"
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$views = @(
    "vw_Tableau_Transactions",
    "vw_Tableau_Rule_Executions",
    "vw_Tableau_Alert_Queues"
)

function Quote([string]$s) {
    return '"' + $s.Replace('"', '""') + '"'
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$connStr = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
$conn.Open()

try {
    foreach ($view in $views) {
        $name = $view -replace '^vw_Tableau_', ''
        $path = Join-Path $OutDir "$name.csv"

        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT * FROM dbo.[$view]"
        $reader = $cmd.ExecuteReader()

        $writer = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $header = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt $reader.FieldCount; $i++) { $header.Add((Quote ($reader.GetName($i)))) }
            $writer.WriteLine(($header -join ","))

            $rows = 0
            while ($reader.Read()) {
                $values = New-Object System.Collections.Generic.List[string]
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    if ($reader.IsDBNull($i)) {
                        $cell = ""
                    }
                    else {
                        $v = $reader.GetValue($i)
                        if     ($v -is [datetime])      { $cell = $v.ToString("yyyy-MM-dd HH:mm:ss", $inv) }
                        elseif ($v -is [bool])          { $cell = $(if ($v) { "1" } else { "0" }) }
                        elseif ($v -is [string])        { $cell = Quote $v }
                        elseif ($v -is [IFormattable])  { $cell = $v.ToString($null, $inv) }
                        else                            { $cell = Quote ([string]$v) }
                    }
                    $values.Add($cell)
                }
                $writer.WriteLine(($values -join ","))
                $rows++
            }
        }
        finally {
            $writer.Close()
            $reader.Close()
        }

        Write-Host ("{0,-22} {1,6} rows  ->  {2}" -f "$name.csv", $rows, $path)
    }
}
finally {
    $conn.Close()
}
