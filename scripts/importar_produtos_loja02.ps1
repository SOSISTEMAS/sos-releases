#requires -Version 5.1
# LOJA 02 recem-instalada: importa SO produtos da Loja 01 (ver LEIA-ME.md).
# $Dump vazio = produtos_loja01*.dump mais novo em BACKUP/Desktop/Downloads. $Sha opcional.
param([string]$Dump = '', [string]$Sha = '', [int]$EmpOrigem = 1)
$ErrorActionPreference = 'Continue'
function Out([string]$m) { [Console]::Out.WriteLine($m) }

if (-not $Dump) {
  # 1o: pasta C:/SOS/Win64/BKP (backup completo do SOS da Loja 01 ou o dump de produtos)
  $c = Get-ChildItem 'C:/SOS/Win64/BKP/*' -Include '*.zip', '*.backup', '*.dump' -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $c) {
    $c = Get-ChildItem 'C:/PRODUTOS_LOJA01', 'C:/SOS/Win64/BACKUP', 'C:/Users/*/Desktop', 'C:/Users/*/Downloads' -Filter 'produtos_loja01*.dump' -EA SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if ($c) { $Dump = $c.FullName }
}
if (-not $Dump -or -not (Test-Path $Dump)) { throw "backup da Loja 01 nao encontrado ($Dump) - coloque em C:/SOS/Win64/BKP" }
if ($Dump -like '*.zip') {
  # backup automatico do SOS: BKP_dd_mm_aaaa_hh_mm.zip com o .backup (formato tar) dentro
  $ux = "$env:TEMP/bkp_loja01"
  Remove-Item $ux -Recurse -Force -EA SilentlyContinue
  Expand-Archive -Path $Dump -DestinationPath $ux -Force
  $b = Get-ChildItem $ux -Recurse -Include '*.backup', '*.dump' | Sort-Object Length -Descending | Select-Object -First 1
  if (-not $b) { throw "zip sem .backup dentro: $Dump" }
  Out "Zip: $Dump -> $($b.Name)"
  $Dump = $b.FullName
}
$h = (Get-FileHash $Dump -Algorithm SHA256).Hash
Out "Dump: $Dump ($((Get-Item $Dump).Length) bytes) SHA256=$h"
if ($Sha -and $h -ne $Sha.ToUpper()) { throw "SHA256 nao confere com a Loja 01 ($Sha)" }
if (Get-Process -Name SOS -EA SilentlyContinue) { throw 'SOS.exe aberto na Loja 02 - fechar antes' }

$iniPath = 'C:/SOS/Win64/CONF/DATABASE.INI'
if (-not (Test-Path $iniPath)) { throw "SOS nao instalado (sem $iniPath)" }
$ini = @{}
foreach ($l in Get-Content $iniPath) {
  if ($l -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $ini[$matches[1].ToUpper()] = $matches[2].Trim() }
}
$srv = if ($ini.SERVER) { $ini.SERVER } else { '127.0.0.1' }
$port = if ($ini.PORT) { $ini.PORT } else { '5432' }
$db = if ($ini.DATABASE) { $ini.DATABASE } else { 'softmobile' }
$usr = if ($ini.USERNAME) { $ini.USERNAME } else { 'postgres' }
$pwd0 = if ($ini.PASSWORD) { $ini.PASSWORD } else { '123' }
$env:PGPASSWORD = $pwd0
Out "Destino: ${srv}:${port}/$db"

$bin = Get-ChildItem 'C:/Program Files/PostgreSQL/*/bin/pg_restore.exe' -EA SilentlyContinue |
  Sort-Object { [int]($_.Directory.Parent.Name -replace '[^0-9].*$', '') } -Descending | Select-Object -First 1
if (-not $bin) { throw 'pg_restore.exe nao encontrado' }
$pgDir = $bin.DirectoryName
$psql = Join-Path $pgDir 'psql.exe'
function Q($d, $sql) {
  $r = & $psql -X -A -t -h $srv -p $port -U $usr -d $d -c $sql 2>&1
  if ($LASTEXITCODE -ne 0) { throw "psql ($d): $sql => $r" }
  return (($r | Select-Object -First 1) -as [string]).Trim()
}

$antes = Q $db 'SELECT count(*) FROM materiais'
Out "Produtos destino antes: $antes"
if ([int]$antes -gt 50) { throw "destino ja tem $antes produtos - script e so pra loja recem-instalada" }

New-Item -ItemType Directory -Force -Path 'C:/SOS/Win64/BACKUP' | Out-Null
$bk = "C:/SOS/Win64/BACKUP/antes_produtos_${db}_$(Get-Date -Format 'yyyyMMdd_HHmmss').backup"
$e = & (Join-Path $pgDir 'pg_dump.exe') -h $srv -p $port -U $usr -d $db -Fc -f $bk 2>&1
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bk)) { throw "backup do destino falhou - nada foi alterado: $e" }
Out "Backup destino: $bk ($((Get-Item $bk).Length) bytes)"

$tmp = 'loja01_produtos_tmp'
Q 'postgres' "DROP DATABASE IF EXISTS $tmp" | Out-Null
Q 'postgres' "CREATE DATABASE $tmp" | Out-Null
& $bin.FullName -h $srv -p $port -U $usr -d $tmp --no-owner --no-privileges $Dump 2>&1 | Out-Null
if ((Q $tmp "SELECT count(*) FROM pg_tables WHERE tablename='materiais'") -ne '1') {
  # sequence/tipo fora do dump: schema do destino + so dados
  Out 'restore direto falhou; usando schema do destino + dados'
  Q 'postgres' "DROP DATABASE $tmp" | Out-Null; Q 'postgres' "CREATE DATABASE $tmp" | Out-Null
  $sf = "$env:TEMP/schema_destino.sql"
  & (Join-Path $pgDir 'pg_dump.exe') -h $srv -p $port -U $usr -d $db -s -f $sf 2>&1 | Out-Null
  & $psql -X -q -h $srv -p $port -U $usr -d $tmp -f $sf 2>&1 | Out-Null
  & $bin.FullName -h $srv -p $port -U $usr -d $tmp --data-only --disable-triggers $Dump 2>&1 | Out-Null
}
$nTmp = Q $tmp "SELECT count(*) FROM materiais WHERE emp_001=$EmpOrigem"
Out "Produtos no dump (emp $EmpOrigem): $nTmp"
if ([int]$nTmp -le 0) { throw 'dump restaurado sem produtos' }
$kit = 'C:/SOS/Win64/Tools/MigradorRP'
$mig = "$kit/migrar_somente_produtos.ps1"
if (-not (Test-Path $mig)) {
  New-Item -ItemType Directory -Force -Path $kit | Out-Null
  $zip = "$env:TEMP/SOS_MigradorRP.zip"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -OutFile $zip `
    -Uri 'https://github.com/SOSISTEMAS/sos-releases/releases/download/latest-migrador-rp/SOS_MigradorRP.zip'
  Expand-Archive -Path $zip -DestinationPath $kit -Force
}
if (-not (Test-Path $mig)) { throw "nao achei $mig" }
# o banco do SOS pode ter as funcoes dblink criadas fora de extensao; so cria se faltar
if ((Q $db "SELECT count(*) FROM pg_proc WHERE proname='dblink'") -eq '0') { Q $db 'CREATE EXTENSION IF NOT EXISTS dblink' | Out-Null }
# seeds do banco zerado (categoria DIVERSOS id 1) fariam o ON CONFLICT descartar o id 1 da Loja 01
foreach ($t in 'materiais_codigos','materiais_kit','materiais_composicao','materiais_variacao_cor',
  'materiais_variacao','setor_estoque_material','materiais','subcategoria','categoria','unidades',
  'desc_tamanho_material','setor_estoque','fornecedor') {
  & $psql -X -q -h $srv -p $port -U $usr -d $db -c "DELETE FROM public.$t" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { Out "  aviso: $t nao limpou ($(Q $db "SELECT count(*) FROM public.$t") linhas ficam)" }
}

$out = & powershell -NoProfile -ExecutionPolicy Bypass -File $mig -OrigemDb $tmp -DestinoDb $db `
  -HostName $srv -Port $port -User $usr -Password $pwd0 -PgBin $pgDir `
  -EmpresaOrigem $EmpOrigem -EmpresaDestino 1 -Substituir 2>&1
$rc = $LASTEXITCODE
$out | Select-Object -Last 15 | ForEach-Object { Out "  $_" }
if ($rc -ne 0) { throw "migrar_somente_produtos falhou (exit $rc) - banco temporario $tmp mantido; backup em $bk" }
# o migrador copia os ids da Loja 01 mas so acerta a sequence de materiais; sem isto o 1o codigo
# de barras/categoria novo cadastrado na Loja 02 da chave duplicada
$sf2 = "$env:TEMP/acertar_sequences.sql"
Set-Content -Path $sf2 -Encoding ASCII -Value @'
DO $$ DECLARE r record; s text; BEGIN
FOR r IN SELECT table_name t, column_name c, column_default d FROM information_schema.columns
  WHERE table_schema='public' AND column_default LIKE 'nextval(%' AND table_name IN ('unidades','categoria','subcategoria','setor_estoque','desc_tamanho_material','fornecedor','materiais','materiais_codigos','materiais_kit','materiais_composicao','materiais_variacao','materiais_variacao_cor','setor_estoque_material') LOOP
  s := substring(r.d from 'nextval\(''([^'']+)''');
  EXECUTE format('SELECT setval(%L, COALESCE((SELECT max(%I) FROM %I), 0) + 1, false)', s, r.c, r.t);
END LOOP; END $$;
'@
$e = & $psql -X -q -h $srv -p $port -U $usr -d $db -v ON_ERROR_STOP=1 -f $sf2 2>&1
if ($LASTEXITCODE -ne 0) { Out "  aviso: acerto das sequences falhou: $e" } else { Out 'Sequences acertadas' }

$depois = Q $db 'SELECT count(*) FROM materiais WHERE emp_001=1'
Out "CONFERENCIA: origem=$nTmp destino=$depois (antes=$antes)"
Q 'postgres' "DROP DATABASE IF EXISTS $tmp" | Out-Null
if ($depois -ne $nTmp) { Out 'ATENCAO: contagem diferente - ver log em C:/SOS/Win64/Tools/MigradorRP/Logs' } else { Out 'OK: contagem confere' }
