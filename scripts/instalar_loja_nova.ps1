#requires -Version 5.1
# SOS Gestor - instalacao de loja nova (PostgreSQL 17 ja instalado, porta 5432).
# Rodar no PowerShell COMO ADMINISTRADOR no PC da loja:
#   [Net.ServicePointManager]::SecurityProtocol='Tls12'; $f="$env:TEMP\instalar_loja_nova.ps1"; iwr -UseBasicParsing <URL> -OutFile $f; powershell -ExecutionPolicy Bypass -File $f
# 1) baixa o latest-instalador e roda instalar.ps1 (ele pergunta CNPJ / razao social)
# 2) troca o SOS.exe pelo latest-exe e roda as migrations  3) atalho na area de trabalho publica
param(
  [int]$Porta = 5432,
  [string]$SenhaPg = '123'
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir = 'C:\SOS_INST'
$rel = 'https://github.com/SOSISTEMAS/sos-releases/releases/download'
function Ok($m) { Write-Host $m -ForegroundColor Green }
function Passo($m) { Write-Host ''; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Erro($m) { Write-Host ''; Write-Host "ERRO: $m" -ForegroundColor Red; Read-Host 'Enter pra sair'; exit 1 }
function Baixar($url, $dest) {
  $curl = "$env:SystemRoot\System32\curl.exe"
  if (Test-Path $curl) { & $curl -L --fail -o $dest $url } else { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest }
  if (-not (Test-Path $dest) -or (Get-Item $dest).Length -lt 1MB) { Erro "download falhou: $url" }
  Ok ("  {0:N0} bytes" -f (Get-Item $dest).Length)
}
function Extrair($zip, $dest) {
  Remove-Item $dest -Recurse -Force -EA SilentlyContinue
  # Expand-Archive (nao tar.exe): os zips sao do Compress-Archive do PS 5.1, com '\' nos nomes
  Expand-Archive -Path $zip -DestinationPath $dest -Force
}

$adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $adm) { Erro 'abra o PowerShell como ADMINISTRADOR (botao direito > Executar como administrador)' }
New-Item -ItemType Directory -Force -Path $dir | Out-Null

Passo 'POSTGRESQL 17'
$psql = 'C:\Program Files\PostgreSQL\17\bin\psql.exe'
if (-not (Test-Path $psql)) { Erro "nao achei $psql - instale o PostgreSQL 17" }
$svc = Get-Service postgresql-x64-17 -EA SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') { Start-Service postgresql-x64-17; Start-Sleep 5 }
$env:PGPASSWORD = $SenhaPg
$r = & $psql -X -h 127.0.0.1 -p $Porta -U postgres -d postgres -tAc "SELECT version()" 2>&1
if ($LASTEXITCODE -ne 0) { Erro "PostgreSQL nao conectou na porta $Porta com a senha '$SenhaPg': $r" }
if ("$r" -notmatch 'PostgreSQL 17\.') { Erro "a porta $Porta nao e PostgreSQL 17: $r" }
Ok "  PG17 OK na porta $Porta"
if (Test-Path 'C:\SOS\Win64\SOS.exe') {
  if ((Read-Host 'Ja existe C:\SOS\Win64\SOS.exe. Continuar mesmo assim? (S/N)') -notmatch '^[sS]') { exit 1 }
}

Passo 'BAIXANDO INSTALADOR (~290 MB)'
$zip = "$dir\Instalador_SOS_PDV.zip"
Baixar "$rel/latest-instalador/Instalador_SOS_PDV.zip" $zip
$pkg = "$dir\pacote"
Extrair $zip $pkg
if (-not (Test-Path "$pkg\instalar.ps1")) { Erro "instalar.ps1 nao veio no zip ($pkg)" }

Passo 'INSTALANDO (10-15 min - nao feche)'
$env:SOS_INSTALADOR_SEM_PAUSE = '1'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$pkg\instalar.ps1"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path 'C:\SOS\Win64\SOS.exe')) { Erro "instalar.ps1 falhou - veja $pkg\Logs" }
$ini = Get-Content 'C:\SOS\Win64\CONF\DATABASE.INI' -EA SilentlyContinue
if (-not ($ini -match "^PORT=$Porta$")) { Write-Host "  ATENCAO: DATABASE.INI nao esta na porta $Porta" -ForegroundColor Yellow; $ini | Write-Host }

Passo 'ATUALIZANDO PARA A ULTIMA VERSAO'
$ez = "$dir\SOS-Win64.zip"
Baixar "$rel/latest-exe/SOS-Win64.zip" $ez
$ex = "$dir\exe"
Extrair $ez $ex
Get-Process SOS -EA SilentlyContinue | Stop-Process -Force
Copy-Item "$ex\SOS.exe", "$ex\libsodium.dll" 'C:\SOS\Win64\' -Force
Get-Content "$ex\NOVIDADES.txt" -EA SilentlyContinue | Select-Object -First 1 | ForEach-Object { Ok "  $_" }
$mg = "$ex\migrations\rodar_migrations.ps1"
if (Test-Path $mg) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $mg -Ini 'C:\SOS\Win64\CONF\DATABASE.INI' -MigrationsDir "$ex\migrations"
  if ($LASTEXITCODE -ne 0) { Write-Host '  ATENCAO: alguma migration falhou (ver acima)' -ForegroundColor Yellow }
}

$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut('C:\Users\Public\Desktop\SOS Gestor.lnk')
$lnk.TargetPath = 'C:\SOS\Win64\SOS.exe'
$lnk.WorkingDirectory = 'C:\SOS\Win64'
$lnk.Save()

Write-Host ''
Ok '==================================================='
Ok '  INSTALACAO CONCLUIDA'
Ok ("  SOS.exe: " + (Get-Item 'C:\SOS\Win64\SOS.exe').LastWriteTime)
Ok '  Login: ADM / 123456   (atalho "SOS Gestor" na area de trabalho)'
Ok '  Cadastre/libere o serial do HD no portal /computadores'
Ok '==================================================='
Read-Host 'Enter pra sair'
