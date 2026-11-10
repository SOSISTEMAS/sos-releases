#requires -Version 5.1
# Acerta sequences atrasadas em TODAS as tabelas do banco do SOS (sintoma: "chave duplicada"
# ao cadastrar produto/codigo de barras/categoria depois de migracao ou import de produtos).
# So AUMENTA a sequence quando ela esta atras do max(id) da tabela; nunca diminui.
# Idempotente, pode rodar com o SOS aberto; rodar 1x no servidor (ou em qualquer PC da loja).
# Agent FULL: node scripts\_enq_any.js <este.ps1> <SERIAL> <pcId> <cliId> "acertar sequences" 300
# Shell: powershell -ExecutionPolicy Bypass -File acertar_sequences.ps1 [-SoVer]
param([switch]$SoVer)
$ErrorActionPreference = 'Continue'
function Out([string]$m) { [Console]::Out.WriteLine($m) }

$iniPath = @('C:/SOS/Win64/CONF/DATABASE.INI', 'C:/SOS/CONF/DATABASE.INI') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iniPath) {
  $iniPath = Get-ChildItem 'C:/SOS*' -Recurse -Depth 3 -Filter 'DATABASE.INI' -EA SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $iniPath) { throw 'nao achei o DATABASE.INI do SOS (procurei em C:/SOS*)' }
$ini = @{}
foreach ($l in Get-Content $iniPath) {
  if ($l -match '^\s*([A-Za-z]+)\s*=\s*(.*)$') { $ini[$matches[1].ToUpper()] = $matches[2].Trim() }
}
$srv = if ($ini.SERVER) { $ini.SERVER } else { '127.0.0.1' }
$port = if ($ini.PORT) { $ini.PORT } else { '5432' }
$db = if ($ini.DATABASE) { $ini.DATABASE } else { 'softmobile' }
$usr = if ($ini.USERNAME) { $ini.USERNAME } else { 'postgres' }
$env:PGPASSWORD = if ($ini.PASSWORD) { $ini.PASSWORD } else { '123' }
Out "INI: $iniPath | Banco: ${srv}:${port}/$db | $(if ($SoVer) { 'SO VER' } else { 'CORRIGIR' })"

$psql = Get-ChildItem 'C:/Program Files/PostgreSQL/*/bin/psql.exe' -EA SilentlyContinue |
  Sort-Object { [int]($_.Directory.Parent.Name -replace '[^0-9].*$', '') } -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $psql) { throw 'psql.exe nao encontrado' }

$acao = if ($SoVer) { 'NULL' } else { 'setval(s, mx + 1, false)' }
$sql = @'
CREATE TEMP TABLE _acerto (tabela text, coluna text, antes bigint, depois bigint);
DO $$ DECLARE r record; s text; mx bigint; lv bigint; ic boolean; nx bigint; BEGIN
FOR r IN SELECT table_name t, column_name c, column_default d FROM information_schema.columns
  WHERE table_schema = 'public' AND column_default LIKE 'nextval(%' LOOP
  s := substring(r.d from 'nextval\(''([^'']+)''');
  IF s IS NULL THEN CONTINUE; END IF;
  BEGIN
    EXECUTE format('SELECT max(%I)::bigint FROM public.%I', r.c, r.t) INTO mx;
    EXECUTE format('SELECT last_value, is_called FROM %s', s) INTO lv, ic;
  EXCEPTION WHEN others THEN CONTINUE;
  END;
  nx := CASE WHEN ic THEN lv + 1 ELSE lv END;
  IF mx IS NOT NULL AND mx >= nx THEN
    PERFORM ACAO;
    INSERT INTO _acerto VALUES (r.t, r.c, nx, mx + 1);
  END IF;
END LOOP; END $$;
SELECT '  ' || tabela || '.' || coluna || ': proximo ' || antes || ' -> ' || depois FROM _acerto ORDER BY 1;
SELECT 'TOTAL=' || count(*) FROM _acerto;
'@
$sf = "$env:TEMP/acertar_sequences.sql"
Set-Content -Path $sf -Encoding ASCII -Value $sql.Replace('ACAO', $acao)
$o = & $psql -X -q -A -t -h $srv -p $port -U $usr -d $db -v ON_ERROR_STOP=1 -f $sf 2>&1
$rc = $LASTEXITCODE
$o | Where-Object { "$_".Trim() } | ForEach-Object { Out "$_" }
if ($rc -ne 0) { throw "psql falhou (exit $rc)" }
Out $(if ($SoVer) { 'SO VER: nada alterado. Rode sem -SoVer para corrigir.' } else { 'OK: sequences acertadas (TOTAL = quantas estavam atrasadas)' })
