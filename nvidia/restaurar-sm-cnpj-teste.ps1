#requires -Version 5.1
# Restore dump SM Mercadinho na NVIDIA e troca CNPJ ANTES de abrir o SOS.
# Piloto: serial 7E437B04 / PC #86. Nao emite NFC-e. Nao liga Monitor.
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$CnpjNvidia = '29366969000162'
$CnpjSm = '48853845000156'
$BackupLeo = 'C:\Users\sebas\Downloads\BKP_18_08_SMERCADINHO\BKP_18_08_2026_21_01.backup'
$LogDir = 'C:\SOS\Win64\Logs'
$LogFile = Join-Path $LogDir ('analise-vendas-sm-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$NaoAbrirSos = $true

function Out-Log([string]$msg) {
  $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $msg
  [Console]::Out.WriteLine($line)
  if ($script:LogFile) {
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
  }
}

function Find-PgExe([string]$name) {
  $cands = @(
    "C:\Program Files\PostgreSQL\17\bin\$name",
    "C:\Program Files\PostgreSQL\16\bin\$name",
    "C:\Program Files\PostgreSQL\15\bin\$name",
    "C:\Program Files\PostgreSQL\13\bin\$name"
  )
  foreach ($c in $cands) { if (Test-Path $c) { return $c } }
  return $name
}

function Find-Backup {
  $cands = @(
    $BackupLeo,
    'C:\Users\sebas\Downloads\BKP_18_08_SMERCADINHO\BKP_18_08_2026_21_01.backup',
    'C:\Users\sebas\Downloads\BKP_18_08_2026_21_01.backup'
  )
  foreach ($c in $cands) { if (Test-Path $c) { return (Get-Item $c).FullName } }
  $dir = 'C:\Users\sebas\Downloads'
  if (Test-Path $dir) {
    $hit = Get-ChildItem $dir -Recurse -Filter 'BKP_18_08_2026_21_01.backup' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return $null
}

function Read-DatabaseIni {
  $inis = @(
    'C:\SOS\Win64\CONF\DATABASE.INI',
    'C:\SOS\Win64\DATABASE.INI',
    'C:\SOS\CONF\DATABASE.INI'
  )
  $ini = $inis | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $ini) { throw 'DATABASE.INI nao encontrado' }
  $cfg = @{
    Ini = $ini
    PgHost = '127.0.0.1'
    Port = '5434'
    Db = 'softmobile'
    User = 'postgres'
    Pass = '123'
  }
  Get-Content $ini | ForEach-Object {
    if ($_ -match '(?i)^\s*Server\s*=\s*(.+)$') { $cfg.PgHost = $Matches[1].Trim() }
    if ($_ -match '(?i)^\s*Port\s*=\s*(.+)$') { $cfg.Port = $Matches[1].Trim() }
    if ($_ -match '(?i)^\s*Database\s*=\s*(.+)$') { $cfg.Db = $Matches[1].Trim() }
    if ($_ -match '(?i)^\s*User[_ ]?Name\s*=\s*(.+)$') { $cfg.User = $Matches[1].Trim() }
    if ($_ -match '(?i)^\s*Password\s*=\s*(.+)$') { $cfg.Pass = $Matches[1].Trim() }
  }
  return $cfg
}

function Invoke-Psql([hashtable]$cfg, [string]$database, [string]$sql) {
  $env:PGPASSWORD = $cfg.Pass
  $out = & $script:Psql -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d $database -v ON_ERROR_STOP=1 -tAc $sql 2>&1
  return @{ code = $LASTEXITCODE; out = @($out) -join "`n" }
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Out-Log '=== RESTORE SM -> NVIDIA (CNPJ teste) ==='
Out-Log ('whoami=' + [Environment]::UserName + ' host=' + $env:COMPUTERNAME)

$bkp = Find-Backup
if (-not $bkp) { throw 'ERRO: backup SM nao achado. Esperado: ' + $BackupLeo }
$bkpItem = Get-Item $bkp
Out-Log ('BACKUP=' + $bkp + ' bytes=' + $bkpItem.Length + ' mtime=' + $bkpItem.LastWriteTime.ToString('s'))
if ($bkpItem.Length -lt 1000000) { throw 'ERRO: backup pequeno demais' }

$cfg = Read-DatabaseIni
Out-Log ('INI=' + $cfg.Ini + ' db=' + $cfg.Db + ' port=' + $cfg.Port + ' server=' + $cfg.PgHost)

$script:Psql = Find-PgExe 'psql.exe'
$pgRestore = Find-PgExe 'pg_restore.exe'
$pgDump = Find-PgExe 'pg_dump.exe'
Out-Log ('PSQL=' + $script:Psql)
Out-Log ('RESTORE=' + $pgRestore)

Out-Log 'Fechando SOS.exe (nao reabre ate CNPJ NVIDIA gravado)'
cmd /c 'taskkill /F /IM SOS.exe /IM SosPdv.exe /IM SosFood.exe /IM ControleSOS.exe >NUL 2>&1'
Start-Sleep -Seconds 2

$bakDir = 'C:\SOS\Win64\Backup'
New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
$nvidiaBak = Join-Path $bakDir ('nvidia-antes-sm-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.backup')
Out-Log ('Dump NVIDIA atual -> ' + $nvidiaBak)
$env:PGPASSWORD = $cfg.Pass
& $pgDump -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d $cfg.Db -Fc -f $nvidiaBak
if (-not (Test-Path $nvidiaBak) -or (Get-Item $nvidiaBak).Length -lt 10000) {
  Out-Log 'AVISO: dump NVIDIA ficou pequeno; sigo com restore SM mesmo assim'
} else {
  Out-Log ('NVIDIA_BKP_OK bytes=' + (Get-Item $nvidiaBak).Length)
}

$tmpSql = Join-Path $env:TEMP 'sos_recreate_db.sql'
$dbLit = $cfg.Db.Replace("'", "''")
@"
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '$dbLit' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "$dbLit";
CREATE DATABASE "$dbLit";
"@ | Set-Content -Path $tmpSql -Encoding ASCII
Out-Log 'DROP/CREATE banco do DATABASE.INI'
$env:PGPASSWORD = $cfg.Pass
& $script:Psql -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d postgres -v ON_ERROR_STOP=1 -f $tmpSql
if ($LASTEXITCODE -ne 0) { throw 'ERRO: DROP/CREATE falhou exit=' + $LASTEXITCODE }

Out-Log 'pg_restore SM (pode ter warnings; vale count depois)'
& $pgRestore -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d $cfg.Db --no-owner --no-acl $bkp
$restoreExit = $LASTEXITCODE
Out-Log ('pg_restore exit=' + $restoreExit)

$cnt = Invoke-Psql $cfg $cfg.Db "SELECT (SELECT count(*) FROM materiais) || '|' || (SELECT count(*) FROM venda) || '|' || (SELECT count(*) FROM empresas)"
Out-Log ('COUNTS materiais|venda|empresas=' + $cnt.out)
$parts = ($cnt.out -split '\|')
$nMat = 0; $nVen = 0
[void][int]::TryParse(($parts[0] + '').Trim(), [ref]$nMat)
[void][int]::TryParse(($parts[1] + '').Trim(), [ref]$nVen)
if ($nMat -lt 100) {
  Out-Log 'ERRO: restore parece vazio. Tentando devolver dump NVIDIA'
  if (Test-Path $nvidiaBak) {
    & $script:Psql -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d postgres -v ON_ERROR_STOP=1 -f $tmpSql
    & $pgRestore -h $cfg.PgHost -p $cfg.Port -U $cfg.User -d $cfg.Db --no-owner --no-acl $nvidiaBak
  }
  throw 'ERRO: restore SM nao carregou materiais'
}

Out-Log 'Gravando CNPJ NVIDIA ANTES de qualquer abertura do SOS'
$upd = Invoke-Psql $cfg $cfg.Db @"
UPDATE empresas
SET emp_004 = '$CnpjNvidia'
WHERE regexp_replace(coalesce(emp_004,''), '[^0-9]', '', 'g') IN ('$CnpjSm', '')
   OR emp_001 = 1
   OR regexp_replace(coalesce(emp_004,''), '[^0-9]', '', 'g') <> '$CnpjNvidia';
SELECT string_agg(emp_001 || ':' || coalesce(emp_002,'') || ':' || regexp_replace(coalesce(emp_004,''), '[^0-9]', '', 'g'), ' || ')
FROM empresas;
"@
Out-Log ('EMPRESAS=' + $upd.out)
if ($upd.out -notmatch $CnpjNvidia) { throw 'ERRO: CNPJ NVIDIA nao gravou. SOS NAO SERA ABERTO.' }
if ($upd.out -match $CnpjSm) { throw 'ERRO: CNPJ SM ainda presente. SOS NAO SERA ABERTO.' }
Out-Log 'CNPJ_OK=29366969000162'

$xmlPaths = @(
  'C:\SOS\Win64\CONF\CONFIGURACAO.XML',
  'C:\SOS\CONF\CONFIGURACAO.XML'
)
foreach ($xml in $xmlPaths) {
  if (-not (Test-Path $xml)) { continue }
  $raw = [IO.File]::ReadAllText($xml)
  Copy-Item $xml ($xml + '.bak-antes-sm-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
  $new = [regex]::Replace($raw, 'NOME="CKMONITORATIVO"(\s+)LOGICO="true"', 'NOME="CKMONITORATIVO"$1LOGICO="false"', 'IgnoreCase')
  if ($new -ne $raw) {
    [IO.File]::WriteAllText($xml, $new)
    Out-Log ('MONITOR_OFF=' + $xml)
  } else {
    $m = [regex]::Match($raw, 'NOME="CKMONITORATIVO"\s+LOGICO="([^"]*)"')
    Out-Log ('MONITOR_XML=' + $xml + ' valor=' + $(if ($m.Success) { $m.Groups[1].Value } else { 'ausente' }))
  }
}

Out-Log '=== ANALISE VENDAS 18/08 ==='
Out-Log ('LOG=' + $LogFile)

$colVenda = (Invoke-Psql $cfg $cfg.Db "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='venda'").out
Out-Log ('COLS_VENDA=' + $colVenda)
$colItem = (Invoke-Psql $cfg $cfg.Db "SELECT string_agg(table_name || '.' || column_name, ',' ORDER BY table_name, ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND (table_name ILIKE '%venda%item%' OR table_name IN ('venda_item','itens_venda','venda_itens'))").out
Out-Log ('COLS_ITEM=' + $colItem)
$colMat = (Invoke-Psql $cfg $cfg.Db "SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns WHERE table_schema='public' AND table_name='materiais'").out
Out-Log ('COLS_MAT=' + $colMat)

$qAlvo = @"
SELECT 'VENDA_ALVO' AS tag, v.ven_001,
       COALESCE(v.ven_029,0) AS cupom,
       COALESCE(v.ven_009,0) AS total,
       COALESCE(v.sit_001,0) AS sit,
       COALESCE(v.ven_024,'') AS tipo,
       v.ven_004
FROM venda v
WHERE v.ven_001 IN (217286)
   OR COALESCE(v.ven_029,0) IN (204435, 22304, 22304)
ORDER BY v.ven_001
LIMIT 20;
"@
Out-Log (Invoke-Psql $cfg $cfg.Db $qAlvo).out

$qDia = @"
SELECT 'DIA_18' AS tag,
       count(*) AS vendas,
       count(*) FILTER (WHERE COALESCE(sit_001,0)=1) AS fechadas,
       round(sum(COALESCE(ven_009,0)) FILTER (WHERE COALESCE(sit_001,0)=1),2) AS total_fechadas
FROM venda
WHERE ven_004::date = DATE '2026-08-18';
"@
Out-Log (Invoke-Psql $cfg $cfg.Db $qDia).out

$hasItem = (Invoke-Psql $cfg $cfg.Db "SELECT to_regclass('public.venda_item')").out
Out-Log ('TAB_VENDA_ITEM=' + $hasItem.Trim())
if ($hasItem -match 'venda_item') {
  $qItens = @"
SELECT 'ITENS_ALVO' AS tag, i.ven_001, i.mat_001,
       COALESCE(i.ite_002,0) AS qtd,
       COALESCE(i.ite_003,0) AS unit,
       COALESCE(i.ite_005,0) AS tot,
       left(COALESCE(m.mat_003,''),40) AS nome
FROM venda_item i
LEFT JOIN materiais m ON m.mat_001 = i.mat_001 AND m.emp_001 = i.emp_001
WHERE i.ven_001 IN (217286)
   OR i.ven_001 IN (SELECT ven_001 FROM venda WHERE COALESCE(ven_029,0) IN (204435,22304))
ORDER BY i.ven_001, i.ite_001
LIMIT 80;
"@
  Out-Log (Invoke-Psql $cfg $cfg.Db $qItens).out

  $qCod = @"
SELECT 'MAT_COD' AS tag, m.mat_001, left(COALESCE(m.mat_003,''),50) AS nome,
       COALESCE(m.mat_008,0) AS preco
FROM materiais m
WHERE m.mat_001 IN (7603,7610,9394,9492)
   OR m.mat_003 ILIKE '%CEBOLA PERA%'
   OR m.mat_003 ILIKE '%MACA GALA%'
   OR m.mat_003 ILIKE '%BATON%'
ORDER BY m.mat_001
LIMIT 40;
"@
  Out-Log (Invoke-Psql $cfg $cfg.Db $qCod).out

  $qPreco = @"
SELECT 'PRECO_18_COD' AS tag, i.mat_001, left(COALESCE(m.mat_003,''),40) AS nome,
       count(*) AS n,
       min(i.ite_003) AS min_u, max(i.ite_003) AS max_u,
       min(i.ite_002) AS min_q, max(i.ite_002) AS max_q
FROM venda_item i
JOIN venda v ON v.ven_001 = i.ven_001 AND v.emp_001 = i.emp_001
LEFT JOIN materiais m ON m.mat_001 = i.mat_001 AND m.emp_001 = i.emp_001
WHERE v.ven_004::date = DATE '2026-08-18'
  AND COALESCE(v.sit_001,0)=1
  AND (
    i.mat_001 IN (7603,7610,9394,9492)
    OR m.mat_003 ILIKE '%CEBOLA%'
    OR m.mat_003 ILIKE '%MACA GALA%'
    OR m.mat_003 ILIKE '%BATON%'
    OR m.mat_003 ILIKE '%ALA %'
  )
GROUP BY i.mat_001, m.mat_003
ORDER BY i.mat_001
LIMIT 80;
"@
  Out-Log (Invoke-Psql $cfg $cfg.Db $qPreco).out
}

$lic = $null
try {
  $lic = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri 'https://sosistemas.com/api/license/7E437B04').Content
} catch { $lic = 'ERRO_LICENSE ' + $_.Exception.Message }
Out-Log ('LICENSE=' + $lic)
if ($lic -notmatch '29366969000162') {
  Out-Log 'AVISO: portal nao devolveu CNPJ NVIDIA; mesmo assim banco ja esta com esse CNPJ'
}

Out-Log 'SOS_NAO_ABERTO=1 (CNPJ NVIDIA gravado; abra C:\SOS\Win64\SOS.exe so depois desta linha)'
Out-Log 'ISOLAMENTO=Monitor off + emp_004=29366969000162; venda teste nao soma no SM real'
Out-Log '=== FIM OK ==='
exit 0
