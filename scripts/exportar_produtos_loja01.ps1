#requires -Version 5.1
# Agent FULL - LOJA 01 (servidor). Exporta SO produtos + cadastros auxiliares (pg_dump -Fc).
# NAO leva clientes, vendas, caixa, financeiro. Somente leitura no banco.
# Enfileirar: node scripts\_enq_any.js <este.ps1> <SERIAL> <pcId> <cliId> "export produtos loja01" 600
# Continue: no PS 5.1 stderr de exe nativo vira erro fatal com Stop; checamos $LASTEXITCODE
$ErrorActionPreference = 'Continue'
function Out([string]$m) { [Console]::Out.WriteLine($m) }

$iniPath = @('C:/SOS/Win64/CONF/DATABASE.INI', 'C:/SOS/CONF/DATABASE.INI') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iniPath) {
  $iniPath = Get-ChildItem 'C:/SOS*' -Recurse -Depth 3 -Filter 'DATABASE.INI' -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $iniPath) { throw 'nao achei o DATABASE.INI do SOS (procurei em C:/SOS*)' }
Out "INI: $iniPath"
$ini = @{}
foreach ($l in Get-Content $iniPath) {
  if ($l -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $ini[$matches[1].ToUpper()] = $matches[2].Trim() }
}
$srv = if ($ini.SERVER) { $ini.SERVER } else { '127.0.0.1' }
$port = if ($ini.PORT) { $ini.PORT } else { '5432' }
$db = if ($ini.DATABASE) { $ini.DATABASE } else { 'softmobile' }
$usr = if ($ini.USERNAME) { $ini.USERNAME } else { 'postgres' }
$env:PGPASSWORD = if ($ini.PASSWORD) { $ini.PASSWORD } else { '123' }
Out "Banco: ${srv}:${port}/$db"

$bin = Get-ChildItem 'C:/Program Files/PostgreSQL/*/bin/pg_dump.exe' -EA SilentlyContinue |
  Sort-Object { [int]($_.Directory.Parent.Name -replace '[^0-9].*$', '') } -Descending | Select-Object -First 1
if (-not $bin) { throw 'pg_dump.exe nao encontrado' }
$pgDir = $bin.DirectoryName
Out "pg_dump: $($bin.FullName)"
$psql = Join-Path $pgDir 'psql.exe'

$tabs = 'unidades','categoria','subcategoria','setor_estoque','desc_tamanho_material','fornecedor',
  'materiais','materiais_codigos','materiais_kit','materiais_composicao','materiais_variacao',
  'materiais_variacao_cor','setor_estoque_material'
$lista = ($tabs | ForEach-Object { "'$_'" }) -join ','
$exist = & $psql -X -A -t -h $srv -p $port -U $usr -d $db -c "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name IN ($lista) ORDER BY 1"
if ($LASTEXITCODE -ne 0) { throw "psql falhou: $exist" }
$exist = @($exist | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
Out ("Tabelas: " + ($exist -join ', '))
if ($exist -notcontains 'materiais') { throw 'tabela materiais nao existe' }

$n = & $psql -X -A -t -h $srv -p $port -U $usr -d $db -c 'SELECT emp_001, count(*) FROM materiais GROUP BY 1 ORDER BY 1'
Out ("Produtos por empresa (emp|qtd): " + (($n | Where-Object { $_ }) -join ' ; '))
$e = & $psql -X -A -t -h $srv -p $port -U $usr -d $db -c 'SELECT emp_004, emp_002, emp_003 FROM empresas WHERE emp_001=1'
Out ("EMPRESA=" + (($e | Where-Object { $_ }) -join ' '))

$dir = 'C:/PRODUTOS_LOJA01'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$arq = "$dir/produtos_loja01_$(Get-Date -Format 'yyyyMMdd_HHmmss').dump"
$pa = @('-h', $srv, '-p', $port, '-U', $usr, '-d', $db, '-Fc', '-Z', '9', '--no-owner', '--no-privileges', '-f', $arq)
foreach ($t in $exist) { $pa += @('-t', "public.$t") }
$o = & $bin.FullName @pa 2>&1
if ($LASTEXITCODE -ne 0) { throw "pg_dump falhou: $o" }

$f = Get-Item $arq
if ($f.Length -lt 1024) { throw "dump pequeno demais: $($f.Length) bytes" }
Out ("ARQUIVO=" + $f.FullName)
Out ("BYTES=" + $f.Length)
Out ("SHA256=" + (Get-FileHash $arq -Algorithm SHA256).Hash)
# copia na area de trabalho publica pra facilitar levar pela AnyDesk
Copy-Item $arq 'C:/Users/Public/Desktop/' -Force -EA SilentlyContinue
if (Test-Path "C:/Users/Public/Desktop/$($f.Name)") { Out "COPIA=C:/Users/Public/Desktop/$($f.Name)" }
if ([Environment]::UserInteractive -and $env:USERNAME -ne 'SYSTEM') { explorer.exe "/select,$($f.FullName -replace '/', '\')" }
