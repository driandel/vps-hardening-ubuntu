# ===========================================================================
#  TRAER LAS COPIAS DEL VPS
#
#  Se ejecuta en el PC y TIRA del servidor. Nunca al reves: si el servidor
#  empujara, esta maquina tendria que aceptar conexiones entrantes y
#  habria que abrir el router. Asi el servidor no tiene ninguna credencial
#  de aqui, y quien lo comprometa no alcanza estas copias ni las borra.
#
#  La clave que usa (copias_dexclub) NO tiene frase de paso, porque una
#  tarea programada no puede escribirla. Eso solo es aceptable porque en
#  el servidor esa clave esta atada a un comando forzado: haga lo que haga
#  quien la use, el servidor responde con el tar de la carpeta de copias y
#  nada mas. Ni shell, ni otros archivos, ni reenvio de puertos.
#  Ver authorized_keys en el servidor.
# ===========================================================================

$ErrorActionPreference = 'Stop'

$destino = 'C:\Servidor\Copias'
$alias   = 'copias-dexclub'     # definido en ~/.ssh/config
$dias    = 60                   # el servidor guarda 14; aqui, mas

# ---------------------------------------------------------------------------
#  Comprueba que un .gz esta completo y no corrompido.
#
#  Lo hace .NET, sin depender de que haya un gzip.exe instalado: al leer el
#  flujo hasta el final se valida la suma de control del cierre, que es lo
#  mismo que comprueba 'gzip -t'. Mirar solo los dos primeros bytes diria
#  que PARECE un .gz; esto dice que se puede restaurar.
# ---------------------------------------------------------------------------
function Test-Gzip([string]$ruta) {
    $e = $null; $g = $null
    try {
        $e = [System.IO.File]::OpenRead($ruta)
        $g = New-Object System.IO.Compression.GZipStream(
                 $e, [System.IO.Compression.CompressionMode]::Decompress)
        $buf = New-Object byte[] 65536
        while ($g.Read($buf, 0, $buf.Length) -gt 0) { }
        return $true
    } catch {
        return $false
    } finally {
        if ($g) { $g.Dispose() }
        if ($e) { $e.Dispose() }
    }
}

New-Item -ItemType Directory -Force -Path $destino | Out-Null
$tmp = Join-Path $env:TEMP 'copias-dexclub.tar.gz'

# El volcado viene por la salida estandar y son BYTES. La redireccion de
# PowerShell pasa por su tuberia de texto y los estropea, asi que la hace
# cmd, que escribe crudo.
cmd /c "ssh $alias > `"$tmp`"" 2>$null
if ($LASTEXITCODE -ne 0) { throw "No se pudo conectar con el servidor (codigo $LASTEXITCODE)." }
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100) {
    throw "El servidor no devolvio nada aprovechable."
}

# tar viene de serie en Windows 10 y 11. Conserva las fechas originales,
# que es lo que hace que la rotacion de abajo cuente bien.
tar -xzf $tmp -C $destino
if ($LASTEXITCODE -ne 0) { throw "El archivo llego corrupto: tar no pudo abrirlo." }
Remove-Item $tmp

$todas = Get-ChildItem $destino -Filter 'dexclub_*.sql.gz'
if ($todas.Count -eq 0) { throw "No hay ninguna copia en $destino." }

$malas = @($todas | Where-Object { -not (Test-Gzip $_.FullName) } | ForEach-Object { $_.Name })
if ($malas.Count -gt 0) { throw "No pasan la verificacion: $($malas -join ', ')" }

# Rotacion local. Las que el servidor ya borro siguen aqui: para eso esta
# fuera.
$todas | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$dias) } | Remove-Item

$todas  = Get-ChildItem $destino -Filter 'dexclub_*.sql.gz'
$ultima = $todas | Sort-Object LastWriteTime -Descending | Select-Object -First 1

"$(Get-Date -Format 'yyyy-MM-dd HH:mm')  verificadas: $($todas.Count)  ultima: $($ultima.Name)" |
    Add-Content (Join-Path $destino 'registro.txt')

# El fallo que de verdad importa no es que esto reviente: es que deje de
# funcionar en silencio y no se note hasta que haga falta la copia. Si la
# mas reciente tiene mas de dos dias, la tarea programada queda en rojo.
if ($ultima.LastWriteTime -lt (Get-Date).AddDays(-2)) {
    throw "La copia mas reciente es del $($ultima.LastWriteTime). Revisa el servidor."
}

Write-Host "OK - $($todas.Count) copias verificadas, la ultima $($ultima.Name)"
