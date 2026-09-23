#requires -Version 7.2
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# NeMo-Speech.cpp - Windows / CUDA + Video UI avanzata
# Unico launcher:
#   - installa/aggiorna NeMo-Speech.cpp
#   - Nemotron 3.5 ASR + Sortformer diarization
#   - MagpieTTS Multilingual + NanoCodec per doppiaggio
#   - UI drag&drop audio/video
#   - speaker colorati
#   - SRT / VTT / ASS colorato
#   - MKV con sottotitoli ASS selezionabili
#   - burn-in opzionale con NVENC
#   - traccia doppiaggio AI separata nel video
# ============================================================

$Base      = "D:\Modelli\NeMo-Speech"
$Runtime   = Join-Path $Base "Runtime"
$Models    = Join-Path $Base "Models"
$Temp      = Join-Path $Base "Temp"
$Downloads = Join-Path $Base "Downloads"
$Logs      = Join-Path $Base "Logs"
$Output    = Join-Path $Base "Output"
$Installer = Join-Path $Downloads "install-nemo-speech.ps1"

$InstallerUrl = "https://raw.githubusercontent.com/NVIDIA/NeMo-Speech.cpp/main/scripts/install.ps1"
$MaxUploadBytes = 20GB
$script:JobControl = $null
$script:NeMoProcess = $null
$script:TcpListener = $null
$script:CompletedJob = $false

# Voci MagpieTTS ufficiali.
$DefaultVoices = @{
    1 = "John"
    2 = "Sofia"
    3 = "Jason"
    4 = "Aria"
}

# Colori coerenti UI + sottotitoli ASS.
$SpeakerColors = @{
    1 = "#58A6FF"
    2 = "#FF7B72"
    3 = "#D2A8FF"
    4 = "#3FB950"
}


$VideoExtensions = @(".mp4", ".mkv", ".mov", ".avi", ".webm", ".m4v", ".ts", ".m2ts")

# ------------------------------------------------------------
# NVIDIA Riva Translate 4B Instruct v2
#
# NVIDIA non pubblica attualmente il GGUF pronto nel model index di
# NeMo-Speech.cpp. Per mantenere il launcher "un click", quando serve
# la traduzione scarichiamo una quantizzazione Q4_K_M verificata,
# derivata dal modello ufficiale NVIDIA Riva-Translate-4B-Instruct-v2.
# Il modello viene caricato solo alla prima traduzione richiesta.
# ------------------------------------------------------------
$RivaModelDir = Join-Path $Models "Riva-Translate-4B-Instruct-v2"
$RivaModelPath = Join-Path $RivaModelDir "Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf"
$RivaModelUrl = "https://huggingface.co/liodon-ai/Riva-Translate-4B-Instruct-v2-imatrix-GGUF/resolve/main/Riva-Translate-4B-Instruct-v2-Q4_K_M.gguf?download=true"
$RivaModelSha256 = "90c2f48ff5549b770d9aaecb7eea603548bcca035a970a800d9c17781991804d"

$SupportedTranslationLanguages = @(
    "en","cs","da","de","el","es-ES","es-US","fi","fr","hu","it","lt","lv",
    "nl","no","pl","pt-PT","pt-BR","ro","ru","sk","sv","zh-CN","zh-TW","ja",
    "hi","ko","et","sl","bg","uk","hr","ar","vi","tr","id","th"
)

# Magpie v2602 + build server standard: teniamo nel menu solo le lingue
# utilizzabili senza ricompilare il runtime con frontend TTS extra.
$SupportedDubLanguages = @("en","es-ES","de","fr","it","vi","hi")

$script:NmtProcess = $null
$script:NmtPort = $null
$script:NmtUrl = $null

# Download prodotti durante questa sessione.
$DownloadFiles = @{}

# UTF-8
[Console]::InputEncoding  = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# ------------------------------------------------------------
# Cartelle / ambiente
# ------------------------------------------------------------
New-Item -ItemType Directory -Force -Path `
    $Base, $Runtime, $Models, $Temp, $Downloads, $Logs, $Output | Out-Null

# Evita di aggiornare il binario e cancellare Temp di una sessione in corso.
$ExistingNeMoExe = Join-Path $Runtime "bin\nemo-speech.exe"
if (Test-Path -LiteralPath $ExistingNeMoExe) {
    $ExistingServers = @(Get-CimInstance Win32_Process -Filter "Name='nemo-speech.exe'" |
        Where-Object { $_.ExecutablePath -eq $ExistingNeMoExe -and $_.CommandLine -match '(^|\s)serve(\s|$)' })
    if ($ExistingServers.Count -gt 0) {
        throw "NeMo è già avviato (PID $($ExistingServers[0].ProcessId)). Chiudi la sessione precedente prima di riaprire Studio."
    }
}

# Pulisce solo i file temporanei riconoscibili di sessioni precedenti.
Get-ChildItem -LiteralPath $Temp -Force -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '^(input-|audio-|tts-|fit-|silence-|concat-|filter-|job-)'
    } |
    Remove-Item -Force -Recurse -ErrorAction SilentlyContinue

$env:TEMP = $Temp
$env:TMP  = $Temp

$env:NEMO_SPEECH_MODEL_DIR = $Models
[Environment]::SetEnvironmentVariable(
    "NEMO_SPEECH_MODEL_DIR",
    $Models,
    "User"
)

$env:NEMO_SPEECH_RELEASE_BASE_URL = "https://github.com/NVIDIA/NeMo-Speech.cpp/releases"

# ------------------------------------------------------------
# Fallback SHA-256 per installer NVIDIA
# ------------------------------------------------------------
if (-not (Get-Command Get-FileHash -ErrorAction SilentlyContinue)) {
    function Get-FileHash {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true, Position = 0)]
            [string]$Path,
            [ValidateSet("SHA256")]
            [string]$Algorithm = "SHA256"
        )

        $ResolvedPath = (Resolve-Path -LiteralPath $Path).Path
        $Stream = [System.IO.File]::OpenRead($ResolvedPath)

        try {
            $Sha = [System.Security.Cryptography.SHA256]::Create()
            try {
                $Bytes = $Sha.ComputeHash($Stream)
                $Hash = ([System.BitConverter]::ToString($Bytes)).Replace("-", "")
            }
            finally { $Sha.Dispose() }
        }
        finally { $Stream.Dispose() }

        [PSCustomObject]@{
            Algorithm = "SHA256"
            Hash      = $Hash
            Path      = $ResolvedPath
        }
    }
}

# ------------------------------------------------------------
# Helpers generici
# ------------------------------------------------------------
function Test-LocalPortFree {
    param([Parameter(Mandatory)][int]$Port)

    $Listener = $null

    try {
        $Listener = [System.Net.Sockets.TcpListener]::new(
            [System.Net.IPAddress]::Loopback,
            $Port
        )
        $Listener.Server.ExclusiveAddressUse = $true
        $Listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $Listener) {
            try { $Listener.Stop() } catch {}
        }
    }
}

function Get-FreeLocalPort {
    param(
        [int]$StartPort,
        [int]$EndPort
    )

    foreach ($Port in $StartPort..$EndPort) {
        if (Test-LocalPortFree -Port $Port) {
            return $Port
        }
    }

    throw "Nessuna porta libera trovata tra $StartPort e $EndPort."
}

function Get-StartupMemoryReport {
    $Lines = [System.Collections.Generic.List[string]]::new()
    try {
        $Os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $Lines.Add(("RAM libera: {0:N1} GB" -f ([double]$Os.FreePhysicalMemory / 1MB)))
        $Lines.Add(("Memoria virtuale libera (stima Windows): {0:N1} GB" -f
            ([double]$Os.FreeVirtualMemory / 1MB)))
    }
    catch {
        $Lines.Add("Dati di memoria Windows non disponibili: $($_.Exception.Message)")
    }
    try {
        $Mem = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        if ($Mem -and [double]$Mem.CommitLimit -gt 0) {
            $Used = [double]$Mem.CommittedBytes / 1GB
            $Limit = [double]$Mem.CommitLimit / 1GB
            $Lines.Add(("Memoria impegnata: {0:N1} / {1:N1} GB (margine {2:N1} GB)" -f
                $Used, $Limit, ($Limit - $Used)))
        }
    }
    catch {}
    try {
        $PageFiles = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop)
        if ($PageFiles.Count) {
            $Pages = ($PageFiles | ForEach-Object {
                "$($_.Name): $($_.AllocatedBaseSize) MB assegnati"
            }) -join "; "
            $Lines.Add("File di paging: $Pages")
        }
        else { $Lines.Add("File di paging: nessuno rilevato") }
    }
    catch {}
    try {
        $Top = @(Get-Process -ErrorAction Stop |
            Sort-Object -Property PrivateMemorySize64 -Descending |
            Select-Object -First 6)
        $Heavy = ($Top | ForEach-Object {
            "$($_.ProcessName) PID $($_.Id) $([Math]::Round($_.PrivateMemorySize64 / 1GB, 1)) GB"
        }) -join "; "
        if ($Heavy) { $Lines.Add("Processi più pesanti (memoria privata): $Heavy") }
    }
    catch {}
    return ($Lines -join "`n")
}

# Canale di controllo indipendente: il listener UI principale è occupato
# durante inferenza e mux. Solo la pagina locale può inviare Stop.
if (-not ("NeMoJobControl" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Text.Json;

public sealed class NeMoJobControl : IDisposable {
    private readonly TcpListener listener;
    private readonly Thread thread;
    private readonly string origin;
    private readonly string secret;
    private readonly object gate = new object();
    private CancellationTokenSource source = new CancellationTokenSource();
    private string job = "";
    private string phase = "In attesa";
    private int percent = 0;
    private bool running = false;
    private volatile bool closing = false;

    public NeMoJobControl(int port, string allowedOrigin, string token) {
        origin = allowedOrigin.TrimEnd('/');
        secret = token;
        listener = new TcpListener(IPAddress.Loopback, port);
        listener.Server.ExclusiveAddressUse = true;
        listener.Start();
        thread = new Thread(Listen) { IsBackground = true, Name = "NeMo Studio Control" };
        thread.Start();
    }
    public CancellationToken Token { get { lock(gate) return source.Token; } }
    public void Begin(string id) {
        lock(gate) {
            if (job != id) throw new InvalidOperationException("Job non registrato.");
            running = true;
            if (!source.IsCancellationRequested) { phase = "Preparazione audio"; percent = 8; }
        }
    }
    public void Update(string id, string step, int progress) {
        lock(gate) {
            if (job != id || source.IsCancellationRequested) return;
            phase = step; percent = Math.Max(0, Math.Min(99, progress));
        }
    }
    public void Finish(string id, bool success) {
        lock(gate) {
            if (job != id) return;
            running = false;
            if (source.IsCancellationRequested) { phase = "Annullato"; percent = 0; }
            else { phase = success ? "Completato" : "Errore"; percent = success ? 100 : 0; }
        }
    }
    private void Listen() {
        while (!closing) {
            try {
                using (var client = listener.AcceptTcpClient()) {
                    client.ReceiveTimeout = 3000; client.SendTimeout = 3000;
                    var stream = client.GetStream();
                    var bytes = new List<byte>();
                    int v;
                    while (bytes.Count < 16384 && (v = stream.ReadByte()) >= 0) {
                        bytes.Add((byte)v);
                        int n = bytes.Count;
                        if (n >= 4 && bytes[n-4] == 13 && bytes[n-3] == 10 &&
                            bytes[n-2] == 13 && bytes[n-1] == 10) break;
                    }
                    var lines = Encoding.ASCII.GetString(bytes.ToArray()).Split(new[] {"\r\n"}, StringSplitOptions.None);
                    var first = lines[0].Split(' ');
                    var headers = new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var line in lines) {
                        int colon = line.IndexOf(':');
                        if (colon > 0) headers[line.Substring(0,colon).Trim()] = line.Substring(colon+1).Trim();
                    }
                    string requestOrigin = headers.ContainsKey("Origin") ? headers["Origin"] : "";
                    bool permittedOrigin = requestOrigin == origin;
                    if (first.Length < 2 || !permittedOrigin) { Reply(stream, 403, "{}", false); continue; }
                    if (first[0] == "OPTIONS") { Reply(stream, 204, "", true); continue; }
                    if (!headers.ContainsKey("X-NeMo-Token") || headers["X-NeMo-Token"] != secret) {
                        Reply(stream, 403, "{}", true); continue;
                    }
                    var uri = new Uri("http://127.0.0.1" + first[1]);
                    var parts = uri.Query.TrimStart('?').Split('=');
                    string id = parts.Length == 2 ? Uri.UnescapeDataString(parts[1]) : "";
                    if (id.Length != 32 || !System.Text.RegularExpressions.Regex.IsMatch(id,"^[0-9a-f]{32}$")) {
                        Reply(stream, 400, "{}", true); continue;
                    }
                    string json;
                    int code = 200;
                    lock (gate) {
                        if (first[0] == "POST" && uri.AbsolutePath == "/arm") {
                            if (running) { code = 409; json = "{\"error\":\"Job in corso\"}"; }
                            else {
                                source.Dispose(); source = new CancellationTokenSource();
                                job = id; phase = "In attesa del file"; percent = 0;
                                json = "{\"ok\":true}";
                            }
                        } else if (job != id) { code = 404; json = "{}"; }
                        else if (first[0] == "POST" && uri.AbsolutePath == "/cancel") {
                            source.Cancel(); phase = "Annullamento in corso";
                            json = "{\"ok\":true}";
                        } else if (first[0] == "GET" && uri.AbsolutePath == "/status") {
                            json = JsonSerializer.Serialize(new { phase, percent, cancelled = source.IsCancellationRequested });
                        } else { code = 404; json = "{}"; }
                    }
                    Reply(stream, code, json, true);
                }
            } catch (SocketException) { if (closing) break; }
              catch (ObjectDisposedException) { if (closing) break; }
              catch { /* un client malformato non ferma il listener */ }
        }
    }
    private void Reply(NetworkStream stream, int code, string json, bool cors) {
        byte[] body = Encoding.UTF8.GetBytes(json);
        string head = "HTTP/1.1 " + code + " " + (code == 200 ? "OK" : code == 204 ? "No Content" : "Error") + "\r\n" +
            "Content-Type: application/json; charset=utf-8\r\nContent-Length: " + body.Length + "\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n" +
            (cors ? "Access-Control-Allow-Origin: " + origin + "\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: X-NeMo-Token, Content-Type\r\nVary: Origin\r\n" : "") + "\r\n";
        byte[] prefix = Encoding.ASCII.GetBytes(head);
        stream.Write(prefix, 0, prefix.Length);
        if (body.Length > 0) stream.Write(body, 0, body.Length);
    }
    public void Dispose() {
        closing = true;
        listener.Stop();
        if (thread.IsAlive) thread.Join(1500);
        lock(gate) { source.Cancel(); source.Dispose(); }
    }
}
'@
}

function Assert-JobActive {
    if ($script:CurrentJobId -and $null -ne $script:JobControl) {
        $script:JobControl.Token.ThrowIfCancellationRequested()
    }
}

function Get-OperationToken {
    if ($script:CurrentJobId -and $null -ne $script:JobControl) {
        return $script:JobControl.Token
    }
    return [System.Threading.CancellationToken]::None
}

function Set-JobPhase {
    param([string]$Name, [int]$Percent)
    if ($null -ne $script:JobControl -and $script:CurrentJobId) {
        Assert-JobActive
        $script:JobControl.Update($script:CurrentJobId, $Name, $Percent)
    }
}

# ProcessStartInfo.ArgumentList conserva correttamente percorsi con spazi,
# virgolette e apostrofi; il polling consente di arrestare FFmpeg subito.
function Invoke-MediaCommand {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Assert-JobActive
    $Info = [System.Diagnostics.ProcessStartInfo]::new()
    $Info.FileName = $Executable
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    $Info.RedirectStandardOutput = $true
    $Info.RedirectStandardError = $true
    foreach ($Arg in $Arguments) { [void]$Info.ArgumentList.Add($Arg) }
    $Proc = [System.Diagnostics.Process]::new()
    $Proc.StartInfo = $Info
    try {
        [void]$Proc.Start()
        $StdoutTask = $Proc.StandardOutput.ReadToEndAsync()
        $StderrTask = $Proc.StandardError.ReadToEndAsync()
        while (-not $Proc.WaitForExit(200)) {
            if ($null -ne $script:JobControl -and $script:JobControl.Token.IsCancellationRequested) {
                $Proc.Kill($true)
                [void]$Proc.WaitForExit(5000)
                throw [System.OperationCanceledException]::new("Elaborazione annullata.")
            }
        }
        $OutText = $StdoutTask.GetAwaiter().GetResult()
        $ErrText = $StderrTask.GetAwaiter().GetResult()
        Assert-JobActive
        if ($Proc.ExitCode -ne 0) {
            throw "$([IO.Path]::GetFileName($Executable)) (codice $($Proc.ExitCode)): $ErrText $OutText"
        }
        return $OutText
    }
    finally {
        try { if (-not $Proc.HasExited) { $Proc.Kill($true) } } catch {}
        $Proc.Dispose()
    }
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)

    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $BaseName = $BaseName.Replace([string]$c, "_")
    }

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        $BaseName = "media"
    }

    if ($BaseName.Length -gt 100) {
        $BaseName = $BaseName.Substring(0, 100)
    }

    return $BaseName
}

function Get-MediaDuration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$FfprobePath
    )

    $Raw = & $FfprobePath `
        -v error `
        -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 `
        $Path 2>$null

    if ($LASTEXITCODE -ne 0 -or -not $Raw) {
        throw "FFprobe non riesce a leggere la durata di: $Path"
    }
    $Text = ($Raw | Select-Object -First 1).ToString().Trim()

    [double]$Value = 0
    if (-not [double]::TryParse(
        $Text,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$Value
    )) {
        throw "Impossibile leggere la durata di: $Path"
    }

    return $Value
}

function Get-AtempoFilter {
    param([Parameter(Mandatory)][double]$Factor)

    if ($Factor -le 0) {
        return "atempo=1.0"
    }

    $Parts = [System.Collections.Generic.List[string]]::new()
    $Remaining = $Factor

    while ($Remaining -gt 2.0) {
        $Parts.Add("atempo=2.0")
        $Remaining /= 2.0
    }

    while ($Remaining -lt 0.5) {
        $Parts.Add("atempo=0.5")
        $Remaining /= 0.5
    }

    $Parts.Add(
        "atempo=" +
        $Remaining.ToString("0.000000", [System.Globalization.CultureInfo]::InvariantCulture)
    )

    return ($Parts -join ",")
}

function Convert-ToTtsLanguage {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return "it"
    }

    $x = $Language.ToLowerInvariant()

    if ($x.StartsWith("it")) { return "it" }
    if ($x.StartsWith("en")) { return "en" }
    if ($x.StartsWith("es")) { return "es" }
    if ($x.StartsWith("de")) { return "de" }
    if ($x.StartsWith("fr")) { return "fr" }
    if ($x.StartsWith("vi")) { return "vi" }
    if ($x.StartsWith("hi")) { return "hi" }

    throw "La build MagpieTTS corrente non supporta il doppiaggio in '$Language'."
}

function Format-SrtTime {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }

    $Ts = [TimeSpan]::FromSeconds($Seconds)

    return "{0:00}:{1:00}:{2:00},{3:000}" -f `
        [Math]::Floor($Ts.TotalHours),
        $Ts.Minutes,
        $Ts.Seconds,
        $Ts.Milliseconds
}

function Format-VttTime {
    param([double]$Seconds)

    return (Format-SrtTime $Seconds).Replace(",", ".")
}

function Format-AssTime {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }

    $Ts = [TimeSpan]::FromSeconds($Seconds)
    $Cs = [Math]::Floor($Ts.Milliseconds / 10)

    return "{0}:{1:00}:{2:00}.{3:00}" -f `
        [Math]::Floor($Ts.TotalHours),
        $Ts.Minutes,
        $Ts.Seconds,
        $Cs
}

function Convert-HexToAssColor {
    param([Parameter(Mandatory)][string]$Hex)

    $x = $Hex.TrimStart("#")

    if ($x.Length -ne 6) {
        return "&H00FFFFFF"
    }

    $R = $x.Substring(0,2)
    $G = $x.Substring(2,2)
    $B = $x.Substring(4,2)

    return "&H00$B$G$R"
}

function Join-TranscriptWord {
    param(
        [string]$Current,
        [string]$Word
    )

    $w = $Word.Trim()
    if (-not $w) { return $Current }

    if (-not $Current) {
        return $w
    }

    if ($w -match '^[,.;:!?…\)\]\}]') {
        return $Current + $w
    }

    return $Current + " " + $w
}

# ------------------------------------------------------------
# Raggruppamento parole -> battute / cue
# ------------------------------------------------------------
function Convert-WordsToSegments {
    param(
        [Parameter(Mandatory)]$Words,
        [double]$MaxDuration = 6.0,
        [int]$MaxChars = 82,
        [double]$GapThreshold = 0.75
    )

    $Segments = [System.Collections.Generic.List[object]]::new()
    $Current = $null

    foreach ($WordObj in $Words) {
        $Word = [string]$WordObj.word
        if ([string]::IsNullOrWhiteSpace($Word)) { continue }

        $Start = [double]$WordObj.start
        $End   = [double]$WordObj.end

        $Speaker = 1
        if ($null -ne $WordObj.speaker) {
            try { $Speaker = [int]$WordObj.speaker } catch {}
        }

        if ($Speaker -lt 1 -or $Speaker -gt 4) {
            $Speaker = 1
        }

        $NeedNew = $false

        if ($null -eq $Current) {
            $NeedNew = $true
        }
        else {
            $Gap = $Start - [double]$Current.end
            $ProjectedDuration = $End - [double]$Current.start
            $ProjectedText = Join-TranscriptWord -Current $Current.text -Word $Word

            if ($Speaker -ne [int]$Current.speaker) { $NeedNew = $true }
            elseif ($Gap -gt $GapThreshold) { $NeedNew = $true }
            elseif ($ProjectedDuration -gt $MaxDuration) { $NeedNew = $true }
            elseif ($ProjectedText.Length -gt $MaxChars) { $NeedNew = $true }
        }

        if ($NeedNew) {
            if ($null -ne $Current) {
                $Segments.Add([PSCustomObject]$Current)
            }

            $Current = @{
                speaker = $Speaker
                start   = $Start
                end     = $End
                text    = $Word.Trim()
            }
        }
        else {
            $Current.text = Join-TranscriptWord -Current $Current.text -Word $Word
            $Current.end  = $End
        }

        # Chiude preferibilmente su fine frase.
        if (
            $null -ne $Current -and
            $Word -match '[.!?…]$' -and
            (([double]$Current.end - [double]$Current.start) -ge 1.0)
        ) {
            $Segments.Add([PSCustomObject]$Current)
            $Current = $null
        }
    }

    if ($null -ne $Current) {
        $Segments.Add([PSCustomObject]$Current)
    }

    return @($Segments)
}

# ------------------------------------------------------------
# Subtitle files
# ------------------------------------------------------------
function Write-SubtitleFiles {
    param(
        [Parameter(Mandatory)]$Segments,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseName
    )

    $SrtPath = Join-Path $Directory "$BaseName.srt"
    $VttPath = Join-Path $Directory "$BaseName.vtt"
    $AssPath = Join-Path $Directory "$BaseName.ass"

    $Srt = [System.Text.StringBuilder]::new()
    $Vtt = [System.Text.StringBuilder]::new()
    $Ass = [System.Text.StringBuilder]::new()

    [void]$Vtt.AppendLine("WEBVTT")
    [void]$Vtt.AppendLine("")

    [void]$Ass.AppendLine("[Script Info]")
    [void]$Ass.AppendLine("ScriptType: v4.00+")
    [void]$Ass.AppendLine("WrapStyle: 0")
    [void]$Ass.AppendLine("ScaledBorderAndShadow: yes")
    [void]$Ass.AppendLine("PlayResX: 1920")
    [void]$Ass.AppendLine("PlayResY: 1080")
    [void]$Ass.AppendLine("")
    [void]$Ass.AppendLine("[V4+ Styles]")
    [void]$Ass.AppendLine("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")

    foreach ($sp in 1..4) {
        $AssColor = Convert-HexToAssColor $SpeakerColors[$sp]

        [void]$Ass.AppendLine(
            "Style: Speaker$sp,Segoe UI,54,$AssColor,$AssColor,&H00101010,&H90000000,-1,0,0,0,100,100,0,0,1,3,1,2,80,80,60,1"
        )
    }

    [void]$Ass.AppendLine("")
    [void]$Ass.AppendLine("[Events]")
    [void]$Ass.AppendLine("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")

    $i = 1

    foreach ($Seg in $Segments) {
        $Speaker = [int]$Seg.speaker
        $Text = [string]$Seg.text

        # SRT
        [void]$Srt.AppendLine([string]$i)
        [void]$Srt.AppendLine(
            "$(Format-SrtTime ([double]$Seg.start)) --> $(Format-SrtTime ([double]$Seg.end))"
        )
        [void]$Srt.AppendLine("Speaker ${Speaker}: $Text")
        [void]$Srt.AppendLine("")

        # VTT
        [void]$Vtt.AppendLine(
            "$(Format-VttTime ([double]$Seg.start)) --> $(Format-VttTime ([double]$Seg.end))"
        )
        [void]$Vtt.AppendLine("Speaker ${Speaker}: $Text")
        [void]$Vtt.AppendLine("")

        # ASS colorato
        $AssText = $Text.Replace("\", "\\").Replace("{", "\{").Replace("}", "\}")
        $AssText = "SPEAKER $Speaker  •  " + $AssText

        [void]$Ass.AppendLine(
            "Dialogue: 0,$(Format-AssTime ([double]$Seg.start)),$(Format-AssTime ([double]$Seg.end)),Speaker$Speaker,Speaker $Speaker,0,0,0,,$AssText"
        )

        $i++
    }

    [System.IO.File]::WriteAllText($SrtPath, $Srt.ToString(), [System.Text.UTF8Encoding]::new($true))
    [System.IO.File]::WriteAllText($VttPath, $Vtt.ToString(), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($AssPath, $Ass.ToString(), [System.Text.UTF8Encoding]::new($true))

    return [PSCustomObject]@{
        Srt = $SrtPath
        Vtt = $VttPath
        Ass = $AssPath
    }
}

# ------------------------------------------------------------
# HTTP mini-server locale
# ------------------------------------------------------------
function Read-HttpHeaderBlock {
    param([Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream)

    $Bytes = [System.Collections.Generic.List[byte]]::new()
    $State = 0
    $Limit = 65536

    while ($Bytes.Count -lt $Limit) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }

        $Bytes.Add([byte]$b)

        switch ($State) {
            0 { if ($b -eq 13) { $State = 1 } }
            1 { if ($b -eq 10) { $State = 2 } elseif ($b -ne 13) { $State = 0 } }
            2 { if ($b -eq 13) { $State = 3 } else { $State = 0 } }
            3 {
                if ($b -eq 10) {
                    return [System.Text.Encoding]::ASCII.GetString($Bytes.ToArray())
                }
                $State = 0
            }
        }
    }

    throw "Header HTTP non valido o troppo grande."
}

function Parse-HttpRequestHeaders {
    param([Parameter(Mandatory)][string]$HeaderText)

    $Lines = $HeaderText -split "`r`n"
    $RequestLine = $Lines[0].Split(" ")

    if ($RequestLine.Count -lt 2) {
        throw "Request HTTP non valida."
    }

    $Headers = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($Line in $Lines[1..($Lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }

        $i = $Line.IndexOf(":")
        if ($i -gt 0) {
            $Name  = $Line.Substring(0, $i).Trim()
            $Value = $Line.Substring($i + 1).Trim()
            $Headers[$Name] = $Value
        }
    }

    [PSCustomObject]@{
        Method  = $RequestLine[0]
        Target  = $RequestLine[1]
        Headers = $Headers
    }
}

function Write-HttpResponse {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode = 200,
        [string]$StatusText = "OK",
        [string]$ContentType = "text/plain; charset=utf-8",
        [byte[]]$Body = @(),
        [hashtable]$ExtraHeaders = @{}
    )

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add("HTTP/1.1 $StatusCode $StatusText")
    $Lines.Add("Content-Type: $ContentType")
    $Lines.Add("Content-Length: $($Body.Length)")
    $Lines.Add("Cache-Control: no-store")
    $Lines.Add("Connection: close")

    foreach ($k in $ExtraHeaders.Keys) {
        $Lines.Add("$k`: $($ExtraHeaders[$k])")
    }

    $Lines.Add("")
    $Lines.Add("")

    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes(($Lines -join "`r`n"))
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)

    if ($Body.Length -gt 0) {
        $Stream.Write($Body, 0, $Body.Length)
    }

    $Stream.Flush()
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$StatusText,
        [Parameter(Mandatory)]$Object
    )

    $Json = $Object | ConvertTo-Json -Depth 30 -Compress
    $Body = [System.Text.Encoding]::UTF8.GetBytes($Json)

    Write-HttpResponse `
        -Stream $Stream `
        -StatusCode $StatusCode `
        -StatusText $StatusText `
        -ContentType "application/json; charset=utf-8" `
        -Body $Body
}

function Write-FileHttpResponse {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-HttpResponse `
            -Stream $Stream `
            -StatusCode 404 `
            -StatusText "Not Found" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes("File non trovato"))
        return
    }

    $Info = Get-Item -LiteralPath $Path
    $Name = $Info.Name.Replace('"', "_")

    $ContentType = switch ($Info.Extension.ToLowerInvariant()) {
        ".srt"  { "application/x-subrip; charset=utf-8" }
        ".vtt"  { "text/vtt; charset=utf-8" }
        ".ass"  { "text/plain; charset=utf-8" }
        ".json" { "application/json; charset=utf-8" }
        ".txt"  { "text/plain; charset=utf-8" }
        ".wav"  { "audio/wav" }
        ".mkv"  { "video/x-matroska" }
        ".mp4"  { "video/mp4" }
        default { "application/octet-stream" }
    }

    $Header = @(
        "HTTP/1.1 200 OK"
        "Content-Type: $ContentType"
        "Content-Length: $($Info.Length)"
        "Content-Disposition: attachment; filename=`"$Name`""
        "Cache-Control: no-store"
        "Connection: close"
        ""
        ""
    ) -join "`r`n"

    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Header)
    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)

    $File = [System.IO.File]::OpenRead($Info.FullName)

    try {
        $Buffer = New-Object byte[] 1048576

        while (($Read = $File.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
            $Stream.Write($Buffer, 0, $Read)
        }

        $Stream.Flush()
    }
    finally {
        $File.Dispose()
    }
}

function Save-RawRequestBody {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][long]$ContentLength,
        [Parameter(Mandatory)][string]$Destination
    )

    if ($ContentLength -lt 1) {
        throw "File vuoto."
    }

    if ($ContentLength -gt $MaxUploadBytes) {
        throw "File troppo grande. Limite: 20 GB."
    }

    $File = [System.IO.File]::Create($Destination)

    try {
        $Buffer = New-Object byte[] 1048576
        [long]$Remaining = $ContentLength

        while ($Remaining -gt 0) {
            Assert-JobActive
            $ToRead = [int][Math]::Min($Buffer.Length, $Remaining)
            $Read = $Stream.Read($Buffer, 0, $ToRead)

            if ($Read -le 0) {
                throw "Upload interrotto prima del completamento."
            }

            $File.Write($Buffer, 0, $Read)
            $Remaining -= $Read
        }
    }
    finally {
        $File.Dispose()
    }
}

function Read-RawRequestBodyText {
    param(
        [Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream,
        [Parameter(Mandatory)][long]$ContentLength,
        [long]$MaxBytes = 1048576
    )

    if ($ContentLength -lt 1) {
        return ""
    }

    if ($ContentLength -gt $MaxBytes) {
        throw "Request troppo grande."
    }

    $Buffer = New-Object byte[] ([int]$ContentLength)
    [int]$Offset = 0

    while ($Offset -lt $ContentLength) {
        $Read = $Stream.Read($Buffer, $Offset, [int]($ContentLength - $Offset))
        if ($Read -le 0) {
            throw "Request interrotta."
        }
        $Offset += $Read
    }

    return [System.Text.Encoding]::UTF8.GetString($Buffer)
}

function Get-HeaderBool {
    param(
        [Parameter(Mandatory)]$Headers,
        [Parameter(Mandatory)][string]$Name,
        [bool]$Default = $false
    )

    if (-not $Headers.ContainsKey($Name)) {
        return $Default
    }

    return $Headers[$Name].Trim().ToLowerInvariant() -eq "true"
}

# ------------------------------------------------------------
# API NeMo
# ------------------------------------------------------------
function Invoke-NeMoTranscription {
    param(
        [Parameter(Mandatory)][string]$WavPath,
        [Parameter(Mandatory)][int]$Port,
        [string]$Language = "it-IT",
        [bool]$Diarization = $true
    )

    $Handler = [System.Net.Http.HttpClientHandler]::new()
    $Client  = [System.Net.Http.HttpClient]::new($Handler)
    $Client.Timeout = [TimeSpan]::FromHours(12)

    $Form = [System.Net.Http.MultipartFormDataContent]::new()
    $FileStream = $null

    try {
        $FileStream = [System.IO.File]::OpenRead($WavPath)
        $FileContent = [System.Net.Http.StreamContent]::new($FileStream)
        $FileContent.Headers.ContentType =
            [System.Net.Http.Headers.MediaTypeHeaderValue]::new("audio/wav")

        $Form.Add($FileContent, "file", "audio.wav")
        $Form.Add([System.Net.Http.StringContent]::new("verbose_json"), "response_format")
        $Form.Add(
            [System.Net.Http.StringContent]::new(
                $(if ($Diarization) { "true" } else { "false" })
            ),
            "diarization"
        )

        if ($Language -and $Language -ne "auto") {
            $Form.Add([System.Net.Http.StringContent]::new($Language), "language")
        }

        $Uri = "http://127.0.0.1:$Port/v1/audio/transcriptions"
        Assert-JobActive
        $Response = $Client.PostAsync($Uri, $Form, (Get-OperationToken)).GetAwaiter().GetResult()
        $Content  = $Response.Content.ReadAsStringAsync((Get-OperationToken)).GetAwaiter().GetResult()

        if (-not $Response.IsSuccessStatusCode) {
            throw "NeMo HTTP $([int]$Response.StatusCode): $Content"
        }

        return ($Content | ConvertFrom-Json -Depth 30)
    }
    finally {
        if ($null -ne $FileStream) { $FileStream.Dispose() }
        $Form.Dispose()
        $Client.Dispose()
        $Handler.Dispose()
    }
}

function Invoke-NeMoTts {
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Voice,
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$OutputPath
    )

    $Handler = [System.Net.Http.HttpClientHandler]::new()
    $Client  = [System.Net.Http.HttpClient]::new($Handler)
    $Client.Timeout = [TimeSpan]::FromHours(2)

    try {
        $Payload = @{
            model           = "magpie"
            input           = $Text
            voice           = $Voice
            language        = $Language
            response_format = "wav"
        } | ConvertTo-Json -Compress

        $Content = [System.Net.Http.StringContent]::new(
            $Payload,
            [System.Text.Encoding]::UTF8,
            "application/json"
        )

        Assert-JobActive
        $Response = $Client.PostAsync(
            "http://127.0.0.1:$Port/v1/audio/speech",
            $Content,
            (Get-OperationToken)
        ).GetAwaiter().GetResult()

        if (-not $Response.IsSuccessStatusCode) {
            $Err = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            throw "TTS HTTP $([int]$Response.StatusCode): $Err"
        }

        $Bytes = $Response.Content.ReadAsByteArrayAsync((Get-OperationToken)).GetAwaiter().GetResult()
        [System.IO.File]::WriteAllBytes($OutputPath, $Bytes)
    }
    finally {
        $Client.Dispose()
        $Handler.Dispose()
    }
}

# ------------------------------------------------------------
# Traduzione NVIDIA Riva Translate 4B Instruct v2
# ------------------------------------------------------------
function Convert-ToRivaLanguage {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return "en"
    }

    $x = $Language.Trim()

    # Codici già supportati esattamente.
    if ($SupportedTranslationLanguages -contains $x) {
        return $x
    }

    $l = $x.ToLowerInvariant()

    if ($l.StartsWith("en")) { return "en" }
    if ($l.StartsWith("it")) { return "it" }
    if ($l.StartsWith("de")) { return "de" }
    if ($l.StartsWith("fr")) { return "fr" }
    if ($l.StartsWith("vi")) { return "vi" }
    if ($l.StartsWith("hi")) { return "hi" }
    if ($l.StartsWith("ru")) { return "ru" }
    if ($l.StartsWith("ja")) { return "ja" }
    if ($l.StartsWith("ko")) { return "ko" }
    if ($l.StartsWith("ar")) { return "ar" }
    if ($l.StartsWith("zh-tw") -or $l.StartsWith("zh-hant")) { return "zh-TW" }
    if ($l.StartsWith("zh")) { return "zh-CN" }
    if ($l.StartsWith("pt-br")) { return "pt-BR" }
    if ($l.StartsWith("pt")) { return "pt-PT" }
    if ($l.StartsWith("es-us") -or $l.StartsWith("es-mx") -or $l.StartsWith("es-419")) { return "es-US" }
    if ($l.StartsWith("es")) { return "es-ES" }

    foreach ($code in $SupportedTranslationLanguages) {
        $prefix = $code.Split("-")[0].ToLowerInvariant()
        if ($l.StartsWith($prefix)) {
            return $code
        }
    }

    throw "Lingua sorgente non supportata da Riva Translate: $Language"
}

function Get-LanguageLabel {
    param([string]$Code)

    $Labels = @{
        "original" = "Originale"
        "en" = "Inglese"
        "it" = "Italiano"
        "fr" = "Francese"
        "de" = "Tedesco"
        "es-ES" = "Spagnolo (Europa)"
        "es-US" = "Spagnolo (LATAM)"
        "pt-PT" = "Portoghese"
        "pt-BR" = "Portoghese (Brasile)"
        "vi" = "Vietnamita"
        "hi" = "Hindi"
        "ja" = "Giapponese"
        "ko" = "Coreano"
        "zh-CN" = "Cinese semplificato"
        "zh-TW" = "Cinese tradizionale"
        "ar" = "Arabo"
        "ru" = "Russo"
        "nl" = "Olandese"
        "pl" = "Polacco"
        "uk" = "Ucraino"
        "tr" = "Turco"
    }

    if ($Labels.ContainsKey($Code)) {
        return $Labels[$Code]
    }

    return $Code
}

function Ensure-RivaModel {
    if (Test-Path -LiteralPath $RivaModelPath -PathType Leaf) {
        $Info = Get-Item -LiteralPath $RivaModelPath
        if ($Info.Length -gt 2GB -and
            (Get-FileHash -Path $RivaModelPath -Algorithm SHA256).Hash.ToLowerInvariant() -eq $RivaModelSha256) {
            return
        }
        Write-Warning "Modello Riva esistente non integro: verrà riscaricato."
        Remove-Item -Force -LiteralPath $RivaModelPath -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force -Path $RivaModelDir | Out-Null

    $Curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $Curl) {
        throw "curl.exe non trovato: necessario per scaricare Riva Translate."
    }

    $Part = "$RivaModelPath.part"

    Write-Host ""
    Write-Host "[RIVA] Primo utilizzo della traduzione." -ForegroundColor Yellow
    Write-Host "[RIVA] Scarico Riva Translate 4B Instruct v2 Q4_K_M (~2.76 GB)..." -ForegroundColor Yellow
    Write-Host "[RIVA] Destinazione: $RivaModelPath" -ForegroundColor DarkGray

    [void](Invoke-MediaCommand -Executable $Curl.Source -Arguments @(
        "--location", "--fail", "--retry", "3", "--retry-delay", "2",
        "--continue-at", "-", "--output", $Part, $RivaModelUrl
    ))
    if (-not (Test-Path -LiteralPath $Part)) {
        throw "Download di Riva Translate fallito."
    }

    Write-Host "[RIVA] Verifica SHA-256..." -ForegroundColor DarkGray
    $Hash = (Get-FileHash -Path $Part -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($Hash -ne $RivaModelSha256.ToLowerInvariant()) {
        Remove-Item -Force -LiteralPath $Part -ErrorAction SilentlyContinue
        throw "SHA-256 Riva Translate non valido. Download eliminato."
    }

    Move-Item -Force -LiteralPath $Part -Destination $RivaModelPath
    Write-Host "[RIVA] Modello pronto." -ForegroundColor Green
}

function Start-NmtServerAttempt {
    param(
        [Parameter(Mandatory)][int]$GpuIndex,
        [Parameter(Mandatory)][int]$Port
    )

    $OutLog = Join-Path $Logs "riva-translate-server.log"
    $ErrLog = Join-Path $Logs "riva-translate-server-error.log"

    Remove-Item -Force -ErrorAction SilentlyContinue $OutLog, $ErrLog

    $NmtArgs = @(
        "serve",
        "--host", "127.0.0.1",
        "--port", "$Port",
        "--nmt.model.path", $RivaModelPath,
        "--nmt.backend.gpu", "$GpuIndex",
        "--nmt.model.n_ctx", "1024",
        "--nmt.generation.max_new_tokens", "256",
        "--nmt.pool.contexts", "1",
        "--no-ui",
        "--read-timeout", "3600",
        "--write-timeout", "3600"
    )

    $Proc = Start-Process `
        -FilePath $NeMo `
        -ArgumentList $NmtArgs `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog `
        -RedirectStandardError $ErrLog

    $Url = "http://127.0.0.1:$Port"

    for ($i = 0; $i -lt 300; $i++) {
        if ($script:JobControl.Token.IsCancellationRequested) {
            try { $Proc.Kill() } catch {}
            Assert-JobActive
        }
        if ($Proc.HasExited) {
            $Err = ""
            if (Test-Path $ErrLog) {
                $Err = (Get-Content $ErrLog -Tail 30 -ErrorAction SilentlyContinue) -join "`n"
            }

            return [PSCustomObject]@{
                Ready = $false
                Process = $Proc
                Url = $Url
                Error = $Err
            }
        }

        try {
            $Ready = Invoke-RestMethod -Uri "$Url/ready" -TimeoutSec 2

            if ($Ready.ready -eq $true) {
                return [PSCustomObject]@{
                    Ready = $true
                    Process = $Proc
                    Url = $Url
                    Error = ""
                }
            }
        }
        catch {}

        Start-Sleep -Milliseconds 500
    }

    try { Stop-Process -Id $Proc.Id -Force -ErrorAction SilentlyContinue } catch {}

    return [PSCustomObject]@{
        Ready = $false
        Process = $Proc
        Url = $Url
        Error = "Timeout durante l'avvio del server Riva Translate."
    }
}

function Ensure-NmtServer {
    if (
        $null -ne $script:NmtProcess -and
        -not $script:NmtProcess.HasExited -and
        $script:NmtUrl
    ) {
        return $script:NmtUrl
    }

    Set-JobPhase -Name 'Verifica modello traduzione' -Percent 46
    Ensure-RivaModel

    $script:NmtPort = Get-FreeLocalPort -StartPort 8200 -EndPort 8299

    Write-Host ""
    Set-JobPhase -Name 'Avvio modello traduzione' -Percent 47
    Write-Host "[RIVA] Avvio traduzione su GPU..." -ForegroundColor Yellow

    $Attempt = Start-NmtServerAttempt -GpuIndex 0 -Port $script:NmtPort

    if (-not $Attempt.Ready) {
        Write-Warning "Riva Translate su GPU non è partito. Provo CPU."
        try {
            if ($Attempt.Process -and -not $Attempt.Process.HasExited) {
                Stop-Process -Id $Attempt.Process.Id -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}

        Start-Sleep -Milliseconds 500
        $script:NmtPort = Get-FreeLocalPort -StartPort 8200 -EndPort 8299
        $Attempt = Start-NmtServerAttempt -GpuIndex -1 -Port $script:NmtPort
    }

    if (-not $Attempt.Ready) {
        throw "Impossibile avviare Riva Translate.`n$($Attempt.Error)"
    }

    $script:NmtProcess = $Attempt.Process
    $script:NmtUrl = $Attempt.Url

    Write-Host "[RIVA] Pronto: $($script:NmtUrl)" -ForegroundColor Green

    return $script:NmtUrl
}

function Invoke-RivaTranslationBatch {
    param(
        [Parameter(Mandatory)][string[]]$Texts,
        [Parameter(Mandatory)][string]$SourceLanguage,
        [Parameter(Mandatory)][string]$TargetLanguage
    )

    if ($Texts.Count -eq 0) {
        return @()
    }

    if ($SourceLanguage -eq $TargetLanguage) {
        return @($Texts)
    }

    $Url = Ensure-NmtServer

    $Handler = [System.Net.Http.HttpClientHandler]::new()
    $Client = [System.Net.Http.HttpClient]::new($Handler)
    $Client.Timeout = [TimeSpan]::FromHours(2)

    try {
        $Payload = @{
            input = @($Texts)
            source_language = $SourceLanguage
            target_language = $TargetLanguage
        } | ConvertTo-Json -Depth 5 -Compress

        $Content = [System.Net.Http.StringContent]::new(
            $Payload,
            [System.Text.Encoding]::UTF8,
            "application/json"
        )

        Assert-JobActive
        $Response = $Client.PostAsync(
            "$Url/v1/translations",
            $Content,
            (Get-OperationToken)
        ).GetAwaiter().GetResult()

        $Raw = $Response.Content.ReadAsStringAsync((Get-OperationToken)).GetAwaiter().GetResult()

        if (-not $Response.IsSuccessStatusCode) {
            throw "Riva Translate HTTP $([int]$Response.StatusCode): $Raw"
        }

        $Obj = $Raw | ConvertFrom-Json -Depth 10
        $Results = @($Obj.translations | ForEach-Object { [string]$_.text })

        if ($Results.Count -ne $Texts.Count) {
            throw "Riva Translate ha restituito $($Results.Count) traduzioni per $($Texts.Count) input."
        }

        return $Results
    }
    finally {
        $Client.Dispose()
        $Handler.Dispose()
    }
}

function Invoke-RivaTranslation {
    param(
        [Parameter(Mandatory)][string[]]$Texts,
        [Parameter(Mandatory)][string]$SourceLanguage,
        [Parameter(Mandatory)][string]$TargetLanguage
    )

    $Source = Convert-ToRivaLanguage $SourceLanguage
    $Target = Convert-ToRivaLanguage $TargetLanguage

    if ($Source -eq $Target) {
        return @($Texts)
    }

    # Riva Translate espone coppie con inglese su uno dei due lati.
    # Per coppie non-inglesi facciamo automaticamente X -> EN -> Y.
    if ($Source -ne "en" -and $Target -ne "en") {
        $English = Invoke-RivaTranslation -Texts $Texts -SourceLanguage $Source -TargetLanguage "en"
        return Invoke-RivaTranslation -Texts $English -SourceLanguage "en" -TargetLanguage $Target
    }

    $All = [System.Collections.Generic.List[string]]::new()
    $ChunkSize = 16

    for ($i = 0; $i -lt $Texts.Count; $i += $ChunkSize) {
        Assert-JobActive
        $End = [Math]::Min($i + $ChunkSize - 1, $Texts.Count - 1)
        $Chunk = @($Texts[$i..$End])

        $Translated = Invoke-RivaTranslationBatch `
            -Texts $Chunk `
            -SourceLanguage $Source `
            -TargetLanguage $Target

        foreach ($t in $Translated) {
            $All.Add($t)
        }
    }

    return @($All)
}

function Translate-Segments {
    param(
        [Parameter(Mandatory)]$Segments,
        [Parameter(Mandatory)][string]$SourceLanguage,
        [Parameter(Mandatory)][string]$TargetLanguage
    )

    $Texts = @($Segments | ForEach-Object { [string]$_.text })
    $Translated = Invoke-RivaTranslation `
        -Texts $Texts `
        -SourceLanguage $SourceLanguage `
        -TargetLanguage $TargetLanguage

    $Out = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Segments.Count; $i++) {
        $Out.Add([PSCustomObject]@{
            speaker = [int]$Segments[$i].speaker
            start   = [double]$Segments[$i].start
            end     = [double]$Segments[$i].end
            text    = [string]$Translated[$i]
        })
    }

    return @($Out)
}

# ------------------------------------------------------------
# Doppiaggio MagpieTTS
# ------------------------------------------------------------
function New-DubMixBatch {
    param(
        [Parameter(Mandatory)][object[]]$AudioInputs,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [double]$TotalDuration = 0
    )
    $MixArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($Arg in @('-hide_banner','-loglevel','error','-nostdin','-y')) { $MixArgs.Add($Arg) }
    $Filters = [System.Collections.Generic.List[string]]::new()
    $Labels = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $AudioInputs.Count; $i++) {
        $MixArgs.Add('-i'); $MixArgs.Add([string]$AudioInputs[$i].Path)
        $Delay = [Math]::Max(0, [int][Math]::Round([double]$AudioInputs[$i].DelayMs))
        $Filters.Add("[$($i):a]adelay=$Delay`:all=1[a$i]")
        $Labels.Add("[a$i]")
    }
    if ($AudioInputs.Count -eq 1) {
        $Filters.Add('[a0]anull[mix]')
    } else {
        $Filters.Add(($Labels -join '') + "amix=inputs=$($AudioInputs.Count):duration=longest:normalize=0[mix]")
    }
    if ($TotalDuration -gt 0) {
        $Length = $TotalDuration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        $Filters.Add("[mix]alimiter=limit=0.95,apad,atrim=duration=$Length[out]")
        $OutputLabel = '[out]'
    } else {
        $OutputLabel = '[mix]'
    }
    $MixArgs.Add('-filter_complex'); $MixArgs.Add(($Filters -join ';'))
    $MixArgs.Add('-map'); $MixArgs.Add($OutputLabel)
    foreach ($Arg in @('-ar','22050','-ac','1','-c:a',$(if ($TotalDuration -gt 0) { 'pcm_s16le' } else { 'pcm_f32le' }))) {
        $MixArgs.Add($Arg)
    }
    $MixArgs.Add($OutputPath)
    [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments $MixArgs.ToArray())
}

function New-DubTrack {
    param(
        [Parameter(Mandatory)]$Segments,
        [Parameter(Mandatory)][int]$NeMoPort,
        [Parameter(Mandatory)][string]$TtsLanguage,
        [Parameter(Mandatory)][hashtable]$Voices,
        [Parameter(Mandatory)][double]$TotalDuration,
        [Parameter(Mandatory)][string]$JobTemp,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$FfmpegPath,
        [Parameter(Mandatory)][string]$FfprobePath
    )
    New-Item -ItemType Directory -Force -Path $JobTemp | Out-Null
    $Entries = [System.Collections.Generic.List[object]]::new()
    $Index = 0

    foreach ($Seg in $Segments) {
        Assert-JobActive
        $Index++
        $Speaker = [int]$Seg.speaker
        if (-not $Voices.ContainsKey($Speaker)) { $Voices[$Speaker] = 'John' }
        $Voice = [string]$Voices[$Speaker]
        $Start = [Math]::Max(0.0, [double]$Seg.start)
        $TargetDuration = [Math]::Max(0.35, [double]$Seg.end - [double]$Seg.start)
        $TtsPath = Join-Path $JobTemp ('tts-{0:D5}.wav' -f $Index)
        $FitPath = Join-Path $JobTemp ('fit-{0:D5}.wav' -f $Index)
        Set-JobPhase -Name ("Doppiaggio: battuta $Index/$($Segments.Count)") -Percent (58 + [int](28 * $Index / $Segments.Count))

        try {
            Invoke-NeMoTts -Port $NeMoPort -Text ([string]$Seg.text) -Voice $Voice -Language $TtsLanguage -OutputPath $TtsPath
        } catch {
            Assert-JobActive
            Invoke-NeMoTts -Port $NeMoPort -Text ([string]$Seg.text) -Voice 'default' -Language $TtsLanguage -OutputPath $TtsPath
        }
        $ActualDuration = Get-MediaDuration -Path $TtsPath -FfprobePath $FfprobePath
        if ($ActualDuration -le 0.02) { throw 'MagpieTTS ha prodotto una battuta vuota.' }
        $Filter = Get-AtempoFilter -Factor ($ActualDuration / $TargetDuration)
        $Length = $TargetDuration.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments @(
            '-hide_banner','-loglevel','error','-nostdin','-y','-i',$TtsPath,
            '-af',"$Filter,apad=pad_dur=$Length,atrim=duration=$Length",
            '-ar','22050','-ac','1','-c:a','pcm_s16le',$FitPath
        ))
        $Entries.Add([PSCustomObject]@{ Path=$FitPath; DelayMs=[int][Math]::Round($Start * 1000) })
        Remove-Item -Force -LiteralPath $TtsPath -ErrorAction SilentlyContinue
    }
    if ($Entries.Count -eq 0) { throw 'Nessuna battuta disponibile per il doppiaggio.' }

    # Mix gerarchico in blocchi per non superare i limiti della riga di comando.
    # Ogni voce conserva il timestamp assoluto; le sovrapposizioni si sommano.
    $Layer = @($Entries.ToArray())
    $Depth = 0
    while ($Layer.Count -gt 24) {
        $Next = [System.Collections.Generic.List[object]]::new()
        for ($Offset = 0; $Offset -lt $Layer.Count; $Offset += 24) {
            Assert-JobActive
            $End = [Math]::Min($Offset + 23, $Layer.Count - 1)
            $BatchFile = Join-Path $JobTemp ("mix-$Depth-$Offset.wav")
            New-DubMixBatch -AudioInputs @($Layer[$Offset..$End]) -OutputPath $BatchFile -FfmpegPath $FfmpegPath
            $Next.Add([PSCustomObject]@{ Path=$BatchFile; DelayMs=0 })
            foreach ($Item in @($Layer[$Offset..$End])) {
                Remove-Item -LiteralPath $Item.Path -Force -ErrorAction SilentlyContinue
            }
        }
        $Layer = @($Next.ToArray())
        $Depth++
    }
    Set-JobPhase -Name 'Mix delle voci e sincronizzazione' -Percent 89
    New-DubMixBatch -AudioInputs $Layer -OutputPath $OutputPath -FfmpegPath $FfmpegPath -TotalDuration $TotalDuration
}

# ------------------------------------------------------------
# Output video
# ------------------------------------------------------------
function New-SoftSubtitleMkv {
    param(
        [string]$InputPath,
        [string]$AssPath,
        [string]$OutputPath,
        [string]$FfmpegPath,
        [string]$LanguageTag = "und",
        [string]$SubtitleTitle = "Speaker colorati AI"
    )

    [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments @(
        '-hide_banner','-loglevel','error','-nostdin','-y',
        '-i',$InputPath,'-i',$AssPath,
        '-map','0:v?','-map','0:a?','-map','1:0','-map','0:s?','-map','0:t?',
        '-map_metadata','0','-map_chapters','0','-c','copy',
        '-metadata:s:s:0',"language=$LanguageTag",
        '-metadata:s:s:0',"title=$SubtitleTitle",$OutputPath
    ))
}

function New-BurnedSubtitleVideo {
    param(
        [string]$InputPath,
        [string]$AssPath,
        [string]$OutputPath,
        [string]$FfmpegPath
    )

    $FilterPath = $AssPath.Replace("\", "/").Replace(":", "\:")
    $FilterPath = $FilterPath.Replace("'", "\'")

    $CommonArgs = @(
        '-hide_banner','-loglevel','error','-nostdin','-y',
        '-i',$InputPath,'-vf',"ass='$FilterPath'",
        '-map','0:v:0','-map','0:a?','-map_metadata','0','-map_chapters','0'
    )
    try {
        [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments @(
            $CommonArgs + @('-c:v','h264_nvenc','-preset','p5','-cq','20','-c:a','copy',$OutputPath)
        ))
    }
    catch {
        Assert-JobActive
        Write-Warning "NVENC non riuscito: riprovo con libx264."
        [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments @(
            $CommonArgs + @('-c:v','libx264','-preset','medium','-crf','20','-c:a','copy',$OutputPath)
        ))
    }
}

function New-DubbedMkv {
    param(
        [string]$InputPath,
        [string]$DubPath,
        [string]$OutputPath,
        [string]$FfmpegPath
    )

    [void](Invoke-MediaCommand -Executable $FfmpegPath -Arguments @(
        '-hide_banner','-loglevel','error','-nostdin','-y',
        '-i',$InputPath,'-i',$DubPath,
        '-map','0:v?','-map','0:a?','-map','0:s?','-map','0:t?','-map','1:a:0',
        '-map_metadata','0','-map_chapters','0','-c','copy',$OutputPath
    ))
}

function Register-Download {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $Id = [guid]::NewGuid().ToString("N")
    $DownloadFiles[$Id] = $Path

    return [PSCustomObject]@{
        label = $Label
        url   = "/download?id=$Id"
        name  = [System.IO.Path]::GetFileName($Path)
    }
}

# ------------------------------------------------------------
# HTML UI
# ------------------------------------------------------------
$UiHtmlTemplate = @'
<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NeMo Studio</title>
<style>
:root{color-scheme:dark;--bg:#090f14;--panel:#111b20;--panel2:#0c151a;--border:#26383c;--text:#eef6f2;--muted:#9ab0ad;--accent:#8bed73;--accent2:#b3ff9c;--danger:#ff8d82;--spk1:#71bbff;--spk2:#ff958a;--spk3:#cba8ff;--spk4:#86eab1}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;min-height:100vh;background:radial-gradient(ellipse 900px 510px at 80% -10%,rgba(70,142,107,.18),transparent 73%),radial-gradient(ellipse 700px 520px at -10% 35%,rgba(30,98,94,.11),transparent 72%),var(--bg);color:var(--text);font-family:'Segoe UI Variable','Segoe UI',Inter,system-ui,sans-serif;letter-spacing:.01em}
body:before{content:'';position:fixed;inset:0;pointer-events:none;opacity:.07;background-image:linear-gradient(#80bbac 1px,transparent 1px),linear-gradient(90deg,#80bbac 1px,transparent 1px);background-size:56px 56px;mask-image:linear-gradient(to bottom,black,transparent 75%)}
button,select,textarea{font:inherit}
.wrap{position:relative;max-width:1260px;margin:0 auto;padding:42px 28px 80px}
.top,.brand,.cardheading,.sectionhead,.statecopy{display:flex;align-items:center}
.top{justify-content:space-between;gap:22px;margin-bottom:30px}.brand{gap:18px;min-width:0}
.brandmark{width:61px;height:61px;flex:none;display:flex;align-items:center;justify-content:center;gap:4px;border-radius:18px;background:linear-gradient(145deg,#173429,#0c1d1b);border:1px solid #3b7354;box-shadow:inset 0 1px 0 #59946555,0 10px 32px #040c0c90}
.brandmark span{width:4px;border-radius:3px;background:linear-gradient(var(--accent2),#41a777)}.brandmark span:nth-child(1),.brandmark span:nth-child(5){height:12px}.brandmark span:nth-child(2),.brandmark span:nth-child(4){height:24px}.brandmark span:nth-child(3){height:34px}
.eyebrow{font-size:10px;font-weight:800;letter-spacing:.18em;color:#80cf9b}.version{font-weight:650;color:#9db4ab;margin-left:10px;border-left:1px solid #527269;padding-left:12px}
h1{font-size:clamp(27px,4vw,38px);letter-spacing:-.05em;line-height:1.12;margin:5px 0}h1 em{font-style:normal;color:var(--accent)}h2{font-size:23px;letter-spacing:-.035em;margin:3px 0 4px}
.sub{color:var(--muted);font-size:13px;line-height:1.5}.health{flex:none;border:1px solid #376b4b;background:#142b20;padding:10px 14px;border-radius:99px;color:#c1f2c3;font-size:12px;font-weight:700;box-shadow:0 0 0 5px #142b2040}.healthdot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#83ec8c;box-shadow:0 0 11px #8bed73;margin-right:7px;vertical-align:1px}
.card{position:relative;background:linear-gradient(155deg,rgba(23,37,42,.98),rgba(14,25,30,.98));border:1px solid #2b4143;border-radius:23px;padding:26px;margin-bottom:20px;box-shadow:0 18px 52px rgba(0,0,0,.24),inset 0 1px 0 rgba(205,255,222,.05)}.maincard{padding:24px}
.drop{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:208px;text-align:center;cursor:pointer;background:radial-gradient(circle at 50% 0%,#233d30 0%,#132423 44%,#0e1b20 100%);border:1.5px dashed #507e63;border-radius:17px;padding:28px 16px;transition:background .2s,border-color .2s,transform .2s,box-shadow .2s}
.drop:hover,.drop:focus-visible,.drop.over{outline:none;border-color:var(--accent);background:radial-gradient(circle at 50% 0%,#2e5235 0%,#182d27 54%,#10201f 100%);box-shadow:inset 0 0 0 1px #74de7755,0 0 34px #65d26b11;transform:translateY(-1px)}
.dropicon{display:grid;place-items:center;width:47px;height:47px;border:1px solid #77bd85;border-radius:14px;background:#214334;color:#baffac;font-size:30px;line-height:1;margin-bottom:16px;box-shadow:0 10px 32px #86ff8030}
.dropheadline{font-size:17px;letter-spacing:-.015em}.dropheadline strong{font-weight:800}.dropheadline span{font-weight:450;color:var(--muted)}.dropheadline u{text-underline-offset:3px;color:var(--accent2)}.formatline{font-size:10px!important;letter-spacing:.1em;font-weight:700;margin-top:13px!important}.formatline span{color:#527267;padding:0 7px}.file{color:var(--accent2);font-size:13px;font-weight:650;margin-top:12px;max-width:90%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.muted{color:var(--muted)}
.workflow{margin-top:23px}.presetbar{display:grid;grid-template-columns:minmax(250px,370px) 1fr;gap:14px;align-items:stretch;margin-bottom:17px}
label,.field{display:flex;flex-direction:column;gap:7px;font-size:12px;color:var(--muted)}.field strong{color:var(--text);font-size:13px;font-weight:700}.field small,.togglecopy small,.sectionhead p{font-size:11px;color:var(--muted);line-height:1.5}
select,input[type=text],textarea,button{background:#17272b;color:var(--text);border:1px solid #355056;border-radius:10px;padding:11px 13px;font-size:13px}select{min-height:44px;max-width:100%;outline:none}select:focus-visible,textarea:focus-visible,button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}select:disabled{opacity:.52}
button{cursor:pointer;transition:transform .16s,background .16s,border-color .16s,box-shadow .16s;font-weight:700}button:not(:disabled):hover{transform:translateY(-1px);border-color:#729a81}button:disabled{opacity:.5;cursor:not-allowed}
button.primary{background:linear-gradient(135deg,#c2ffad,#82e46d);border-color:#c1f9ad;color:#0b2417;box-shadow:0 8px 28px #6ee86c24;font-weight:800}button.primary:hover:not(:disabled){box-shadow:0 9px 30px #8af78044}button.secondary{background:#19292c;color:#d9eae4}button.danger{border-color:#94584f;background:#3a2527;color:#ffad9f}button.danger:hover{background:#522b2b}
.hintbox{display:flex;align-items:center;padding:14px 18px;border:1px solid #305047;border-radius:12px;background:linear-gradient(90deg,#182b26,#14242a);color:#b9d4c8;font-size:12px;line-height:1.5}
.sections{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:13px}.toolsection{min-width:0;background:#0d1a1f;border:1px solid #294044;border-radius:16px;padding:17px;box-shadow:inset 0 1px 0 #a8eed409}
.sectionhead{gap:11px;align-items:flex-start;margin-bottom:17px}.sectionicon{flex:none;display:grid;place-items:center;width:35px;height:35px;border-radius:10px;background:#1d3b30;border:1px solid #3d7154;font-size:17px}.sectionhead h3{font-size:15px;letter-spacing:-.02em;margin:1px 0 3px}.sectionhead p{margin:0}
.stack{display:flex;flex-direction:column;gap:10px}.togglecard{display:grid;grid-template-columns:auto 1fr;align-items:start;gap:11px;min-height:64px;background:#152329;border:1px solid #30454b;border-radius:11px;padding:13px;cursor:pointer;transition:border-color .15s,background .15s}.togglecard:hover{border-color:#669d72}.togglecard:has(input:checked){border-color:#568963;background:#173027}.togglecard:has(input:disabled){opacity:.55;cursor:not-allowed}.togglecard input{width:17px;height:17px;margin:2px 0 0;accent-color:#9cf184}.togglecopy{display:flex;flex-direction:column;gap:3px}.togglecopy strong{color:var(--text);font-size:12px;font-weight:750}.sectiondivider{height:1px;background:var(--border);margin:5px 0}
.actionbar{display:flex;align-items:center;flex-wrap:wrap;gap:10px;margin-top:21px;padding-top:19px;border-top:1px solid #314549}.actionbar .primary{min-width:194px}.actionbar .note{margin:0 0 0 auto;max-width:290px}
.jobstate{margin-top:20px;padding:14px 16px;border:1px solid #344e4c;border-radius:11px;background:#112122}.statecopy{gap:10px;min-height:20px}.stateicon{display:grid;place-items:center;width:23px;height:23px;border-radius:50%;background:#264637;color:#aefaa0;font-weight:800}.status{font-size:12px;color:#c4d8d0;line-height:1.4}.status.err{color:var(--danger)}#progressValue{margin-left:auto;color:#aaf19c;font-size:13px;font-variant-numeric:tabular-nums}.progress{height:6px;background:#2b4243;border-radius:99px;overflow:hidden;margin-top:12px;display:none}.bar{height:100%;width:0;background:linear-gradient(90deg,#56b680,#b7fd8f);border-radius:99px;transition:width .35s;box-shadow:0 0 15px #9cf585}
.voicecard,.resultcard{padding:25px}.cardheading{gap:13px;margin-bottom:19px}.headingicon{width:37px;height:37px;display:grid;place-items:center;flex:none;border:1px solid #467b62;background:#19372d;border-radius:11px;color:#a9f4ad;font-size:21px}.voicecard textarea{width:100%;min-height:106px;resize:vertical;line-height:1.55;outline:none}.ttscontrols{display:flex;gap:10px;flex-wrap:wrap;align-items:end;margin-top:13px}.ttscontrols label{min-width:148px}.audioPlayer{width:100%;margin-top:17px;accent-color:var(--accent)}#ttsStatus{margin-top:11px}
.speaker{position:relative;padding:14px 16px;margin:10px 0;background:#13242a;border:1px solid #294044;border-left:3px solid var(--speaker);border-radius:9px}.speaker .meta{font-weight:750;color:var(--speaker);font-size:11px;letter-spacing:.03em;margin-bottom:6px}.speaker .txt{font-size:13px;line-height:1.65}.speaker .translation{margin-top:9px;padding-top:9px;border-top:1px solid #30444b;color:#c5dad1;font-size:12px;line-height:1.55}.speaker .translation b{color:var(--accent2)}.spk1{--speaker:var(--spk1)}.spk2{--speaker:var(--spk2)}.spk3{--speaker:var(--spk3)}.spk4{--speaker:var(--spk4)}
.legend,.actions,.downloads{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}.tag{border:1px solid #385257;background:#16262c;padding:6px 10px;border-radius:99px;font-size:11px}.tag.s1{color:var(--spk1)}.tag.s2{color:var(--spk2)}.tag.s3{color:var(--spk3)}.tag.s4{color:var(--spk4)}.downloads{margin:13px 0}.downloads a,#ttsDownload{display:inline-flex;align-items:center;background:#173027;border:1px solid #3c7656;color:#c7ffc0;border-radius:9px;padding:9px 12px;text-decoration:none;font-size:12px;font-weight:700}.downloads a:hover,#ttsDownload:hover{border-color:var(--accent)}pre{white-space:pre-wrap;word-break:break-word;background:#0c191e;padding:16px;border-radius:10px;border:1px solid var(--border);max-height:360px;overflow:auto;font-size:12px;line-height:1.6}a{color:var(--accent2)}details summary{cursor:pointer}details.options{margin-top:14px;border-top:1px solid var(--border);padding-top:14px}details.options summary{font-size:12px;font-weight:750}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:9px;margin-top:13px}.voicebox{background:#15252a;border:1px solid var(--border);border-radius:9px;padding:11px}.voicebox.spk1{border-left:3px solid var(--spk1)}.voicebox.spk2{border-left:3px solid var(--spk2)}.voicebox.spk3{border-left:3px solid var(--spk3)}.voicebox.spk4{border-left:3px solid var(--spk4)}.note{color:var(--muted);font-size:11px;line-height:1.5;margin-top:10px}.hidden{display:none!important}
@media(max-width:1000px){.sections{grid-template-columns:repeat(2,minmax(0,1fr))}.sections .toolsection:last-child{grid-column:1/-1}.presetbar{grid-template-columns:minmax(200px,320px) 1fr}}
@media(max-width:680px){.wrap{padding:23px 12px 50px}.top{align-items:flex-start;flex-direction:column;gap:17px}.brand{gap:12px}.brandmark{height:49px;width:49px;border-radius:13px}.health{align-self:flex-start}.card,.maincard,.voicecard,.resultcard{padding:15px;border-radius:17px}.drop{min-height:175px}.dropheadline{font-size:15px}.formatline{font-size:9px!important;line-height:1.6}.presetbar,.sections{grid-template-columns:1fr}.sections .toolsection:last-child{grid-column:auto}.actionbar button{width:100%}.actionbar .note{margin:3px 0}.grid{grid-template-columns:1fr 1fr}}
@media(prefers-reduced-motion:reduce){*,*:before,*:after{scroll-behavior:auto!important;transition:none!important;animation:none!important}}
</style>
</head>
<body>
<div class="wrap">
  <div class="top">
    <div class="brand">
      <div class="brandmark" aria-hidden="true"><span></span><span></span><span></span><span></span><span></span></div>
      <div>
        <div class="eyebrow">NVIDIA SPEECH WORKSPACE <span class="version">STUDIO 2.0</span></div>
        <h1>NeMo <em>Studio</em></h1>
        <div class="sub">Trascrizione, sottotitoli e doppiaggio. Il tuo studio audio, sul tuo PC.</div>
      </div>
    </div>
    <div class="health"><span class="healthdot"></span> Motore locale attivo</div>
  </div>

  <div class="card maincard">
    <input id="fileInput" type="file" hidden
      accept=".wav,.mp3,.m4a,.aac,.flac,.ogg,.mp4,.mkv,.mov,.avi,.webm,.m4v,.ts,.m2ts,video/*,audio/*">

    <div id="drop" class="drop" role="button" tabindex="0" aria-label="Seleziona un file audio o video">
      <div class="dropicon" aria-hidden="true">↥</div>
      <div class="dropheadline"><strong>Trascina un file qui</strong><span>oppure <u>scegli dal computer</u></span></div>
      <div class="muted formatline">VIDEO · MP4 · MKV · MOV · WEBM <span> / </span> AUDIO · WAV · MP3 · M4A · FLAC</div>
      <div id="fileName" class="file"></div>
    </div>

    <div class="workflow">
      <div class="presetbar">
        <label class="field">
          <strong>Preset rapido</strong>
          <select id="mode">
            <option value="transcribe" selected>Solo trascrizione</option>
            <option value="subtitles">Crea file sottotitoli</option>
            <option value="softsubs">Video con sottotitoli selezionabili</option>
            <option value="burnsubs">Video con sottotitoli impressi</option>
            <option value="dub">Solo doppiaggio AI</option>
            <option value="full">Tutto: sottotitoli + doppiaggio</option>
          </select>
          <small>Scegli un preset oppure modifica liberamente le opzioni qui sotto.</small>
        </label>
        <div id="modeHint" class="hintbox">Carica un audio o video: Studio adatta automaticamente le opzioni.</div>
      </div>

      <div class="sections">
        <section class="toolsection">
          <div class="sectionhead">
            <div class="sectionicon">📝</div>
            <div>
              <h3>Trascrizione</h3>
              <p>Decide come riconoscere il parlato e se distinguere le persone.</p>
            </div>
          </div>

          <div class="stack">
            <label class="field">
              <strong>Lingua parlata nel file</strong>
              <select id="lang">
                <option value="it-IT" selected>Italiano</option>
                <option value="auto">Rilevamento automatico</option>
                <option value="en">Inglese</option>
                <option value="fr">Francese</option>
                <option value="de">Tedesco</option>
                <option value="es">Spagnolo</option>
              </select>
              <small>È la lingua dell'audio originale, non quella in cui vuoi tradurre.</small>
            </label>

            <label class="togglecard">
              <input id="diar" type="checkbox" checked>
              <span class="togglecopy">
                <strong>Riconosci chi parla</strong>
                <small>Usa Sortformer per separare Speaker 1, 2, 3 e 4 con colori diversi.</small>
              </span>
            </label>
          </div>
        </section>

        <section class="toolsection">
          <div class="sectionhead">
            <div class="sectionicon">💬</div>
            <div>
              <h3>Sottotitoli</h3>
              <p>Crea i file sottotitoli e, se vuoi, li inserisce anche nel video.</p>
            </div>
          </div>

          <div class="stack">
            <label class="togglecard" id="makeSubsWrap">
              <input id="makeSubs" type="checkbox">
              <span class="togglecopy">
                <strong>Crea file sottotitoli</strong>
                <small>Genera SRT, VTT e ASS colorato. Non modifica il video.</small>
              </span>
            </label>

            <label class="field" id="subtitleLangWrap">
              <strong>Lingua dei sottotitoli</strong>
              <select id="subtitleLang">
                <option value="original" selected>Stessa lingua dell'audio</option>
                <option value="it">Italiano</option>
                <option value="en">Inglese</option>
                <option value="fr">Francese</option>
                <option value="de">Tedesco</option>
                <option value="es-ES">Spagnolo (Europa)</option>
                <option value="es-US">Spagnolo (LATAM)</option>
                <option value="pt-PT">Portoghese</option>
                <option value="pt-BR">Portoghese (Brasile)</option>
                <option value="nl">Olandese</option>
                <option value="pl">Polacco</option>
                <option value="ru">Russo</option>
                <option value="uk">Ucraino</option>
                <option value="cs">Ceco</option>
                <option value="da">Danese</option>
                <option value="el">Greco</option>
                <option value="fi">Finlandese</option>
                <option value="hu">Ungherese</option>
                <option value="lt">Lituano</option>
                <option value="lv">Lettone</option>
                <option value="no">Norvegese</option>
                <option value="ro">Rumeno</option>
                <option value="sk">Slovacco</option>
                <option value="sv">Svedese</option>
                <option value="et">Estone</option>
                <option value="sl">Sloveno</option>
                <option value="bg">Bulgaro</option>
                <option value="hr">Croato</option>
                <option value="tr">Turco</option>
                <option value="id">Indonesiano</option>
                <option value="th">Thai</option>
                <option value="vi">Vietnamita</option>
                <option value="hi">Hindi</option>
                <option value="ar">Arabo</option>
                <option value="ja">Giapponese</option>
                <option value="ko">Coreano</option>
                <option value="zh-CN">Cinese semplificato</option>
                <option value="zh-TW">Cinese tradizionale</option>
              </select>
              <small>Se scegli una lingua diversa, Riva Translate traduce solo i sottotitoli.</small>
            </label>

            <div class="sectiondivider"></div>

            <label class="togglecard video-only" id="softSubsWrap">
              <input id="softSubs" type="checkbox">
              <span class="togglecopy">
                <strong>Aggiungi i sottotitoli al video</strong>
                <small>Crea un MKV con traccia ASS selezionabile. Il video non viene ricodificato.</small>
              </span>
            </label>

            <label class="togglecard video-only" id="burnSubsWrap">
              <input id="burnSubs" type="checkbox">
              <span class="togglecopy">
                <strong>Imprimi i sottotitoli nel video</strong>
                <small>Restano sempre visibili. Richiede ricodifica video e usa la GPU NVIDIA.</small>
              </span>
            </label>
          </div>
        </section>

        <section class="toolsection">
          <div class="sectionhead">
            <div class="sectionicon">🗣️</div>
            <div>
              <h3>Doppiaggio AI</h3>
              <p>Genera una nuova traccia vocale con MagpieTTS, mantenendo l'audio originale.</p>
            </div>
          </div>

          <div class="stack">
            <label class="togglecard" id="dubWrap">
              <input id="dub" type="checkbox">
              <span class="togglecopy">
                <strong>Crea doppiaggio AI</strong>
                <small>Ogni speaker può usare una voce NVIDIA diversa.</small>
              </span>
            </label>

            <label class="field" id="dubLangWrap">
              <strong>Lingua del doppiaggio</strong>
              <select id="dubLang" disabled>
                <option value="original" selected>Stessa lingua dell'audio</option>
                <option value="it">Italiano</option>
                <option value="en">Inglese</option>
                <option value="fr">Francese</option>
                <option value="de">Tedesco</option>
                <option value="es-ES">Spagnolo</option>
                <option value="vi">Vietnamita</option>
                <option value="hi">Hindi</option>
              </select>
              <small>Può essere diversa dalla lingua scelta per i sottotitoli.</small>
            </label>

            <details class="options hidden" id="voiceOptions">
              <summary>🎙️ Scegli le voci dei singoli speaker</summary>
              <div class="grid">
                <div class="voicebox spk1">
                  <label>Speaker 1
                    <select id="voice1">
                      <option selected>John</option><option>Sofia</option><option>Jason</option><option>Aria</option><option>Leo</option>
                    </select>
                  </label>
                </div>
                <div class="voicebox spk2">
                  <label>Speaker 2
                    <select id="voice2">
                      <option>John</option><option selected>Sofia</option><option>Jason</option><option>Aria</option><option>Leo</option>
                    </select>
                  </label>
                </div>
                <div class="voicebox spk3">
                  <label>Speaker 3
                    <select id="voice3">
                      <option>John</option><option>Sofia</option><option selected>Jason</option><option>Aria</option><option>Leo</option>
                    </select>
                  </label>
                </div>
                <div class="voicebox spk4">
                  <label>Speaker 4
                    <select id="voice4">
                      <option>John</option><option>Sofia</option><option>Jason</option><option selected>Aria</option><option>Leo</option>
                    </select>
                  </label>
                </div>
              </div>
              <div class="note">MagpieTTS usa voci sintetiche NVIDIA: non clona le voci originali.</div>
            </details>
          </div>
        </section>
      </div>

      <div class="actionbar">
        <button id="go" class="primary" disabled><span>▶</span> Avvia elaborazione</button>
        <button id="cancel" class="danger hidden" type="button">■ Interrompi</button>
        <button id="nvidiaUi" class="secondary">Apri Playground NVIDIA</button>
        <span class="note">I risultati completati si trovano anche nella cartella Output.</span>
      </div>
    </div>

    <div id="jobState" class="jobstate" aria-live="polite">
      <div class="statecopy"><span class="stateicon">◌</span><span id="status" class="status">Seleziona un file per iniziare.</span><b id="progressValue"></b></div>
      <div id="progress" class="progress"><div id="bar" class="bar"></div></div>
    </div>
  </div>

  <div class="card voicecard">
    <div class="cardheading"><div class="headingicon">◉</div><div><div class="eyebrow">MODULO VOCALE</div><h2>Testo → Voce</h2><div class="sub">Dai voce alle parole con NVIDIA MagpieTTS.</div></div></div>
    <textarea id="ttsText" placeholder="Scrivi qui il testo da leggere..."></textarea>
    <div class="ttscontrols">
      <label>Lingua voce
        <select id="ttsLang">
          <option value="it" selected>Italiano</option>
          <option value="en">Inglese</option>
          <option value="fr">Francese</option>
          <option value="de">Tedesco</option>
          <option value="es">Spagnolo</option>
          <option value="vi">Vietnamita</option>
          <option value="hi">Hindi</option>
        </select>
      </label>
      <label>Voce
        <select id="ttsVoice">
          <option selected>John</option><option>Sofia</option><option>Jason</option><option>Aria</option><option>Leo</option>
        </select>
      </label>
      <button id="ttsGo" class="primary">Genera voce</button>
      <a id="ttsDownload" class="hidden" download="magpie-tts.wav">⬇ Scarica WAV</a>
    </div>
    <audio id="ttsAudio" class="audioPlayer hidden" controls></audio>
    <div id="ttsStatus" class="status"></div>
  </div>

  <div id="resultCard" class="card resultcard" style="display:none">
    <div class="cardheading"><div class="headingicon">≋</div><div><div class="eyebrow">RISULTATI</div><h2>Trascrizione pronta</h2></div></div>
    <div class="legend">
      <span class="tag s1">● Speaker 1</span>
      <span class="tag s2">● Speaker 2</span>
      <span class="tag s3">● Speaker 3</span>
      <span class="tag s4">● Speaker 4</span>
    </div>

    <div class="actions">
      <button id="copy">Copia testo</button>
      <button id="downloadTxt">Scarica TXT</button>
      <button id="downloadJson">Scarica JSON</button>
    </div>

    <div id="downloads" class="downloads"></div>
    <div id="speakers"></div>

    <details>
      <summary>Testo completo</summary>
      <pre id="plain"></pre>
    </details>
  </div>
</div>

<script>
const drop = document.getElementById('drop');
const input = document.getElementById('fileInput');
const fileName = document.getElementById('fileName');
const go = document.getElementById('go');
const statusEl = document.getElementById('status');
const progress = document.getElementById('progress');
const bar = document.getElementById('bar');
const resultCard = document.getElementById('resultCard');
const speakers = document.getElementById('speakers');
const plain = document.getElementById('plain');
const downloads = document.getElementById('downloads');
const mode = document.getElementById('mode');
const makeSubs = document.getElementById('makeSubs');
const softSubs = document.getElementById('softSubs');
const burnSubs = document.getElementById('burnSubs');
const modeHint = document.getElementById('modeHint');

let selectedFile = null;
let selectedIsVideo = false;
let lastJson = null;

const dubCheckbox = document.getElementById('dub');
const dubLang = document.getElementById('dubLang');
const subtitleLang = document.getElementById('subtitleLang');
const voiceOptions = document.getElementById('voiceOptions');
const softSubsWrap = document.getElementById('softSubsWrap');
const burnSubsWrap = document.getElementById('burnSubsWrap');

function syncFeatureControls(){
  const subtitleWork = makeSubs.checked || softSubs.checked || burnSubs.checked;
  subtitleLang.disabled = !subtitleWork;

  dubLang.disabled = !dubCheckbox.checked;
  voiceOptions.classList.toggle('hidden', !dubCheckbox.checked);

  softSubsWrap.classList.toggle('hidden', !selectedIsVideo);
  burnSubsWrap.classList.toggle('hidden', !selectedIsVideo);
}

dubCheckbox.addEventListener('change',syncFeatureControls);
makeSubs.addEventListener('change',syncFeatureControls);
softSubs.addEventListener('change',syncFeatureControls);
burnSubs.addEventListener('change',syncFeatureControls);

function applyMode(){
  const m=mode.value;

  makeSubs.checked = ['subtitles','softsubs','burnsubs','full'].includes(m);
  softSubs.checked = selectedIsVideo && ['softsubs','full'].includes(m);
  burnSubs.checked = selectedIsVideo && ['burnsubs','full'].includes(m);
  dubCheckbox.checked = ['dub','full'].includes(m);

  softSubs.disabled = !selectedIsVideo;
  burnSubs.disabled = !selectedIsVideo;

  if(!selectedIsVideo && ['softsubs','burnsubs','full'].includes(m)){
    mode.value='subtitles';
    makeSubs.checked=true;
    softSubs.checked=false;
    burnSubs.checked=false;
  }

  const hints={
    transcribe:'Trascrive il parlato e mostra testo, timestamp e speaker. Non crea nuovi file video.',
    subtitles:'Crea i file SRT, VTT e ASS. Puoi anche tradurli in un’altra lingua.',
    softsubs:'Crea i sottotitoli e un MKV con traccia selezionabile, senza ricodificare il video.',
    burnsubs:'Crea i sottotitoli e li imprime nel video usando la GPU NVIDIA.',
    dub:'Genera una nuova traccia vocale AI; l’audio originale resta disponibile.',
    full:'Crea sottotitoli, video con traccia sottotitoli e doppiaggio AI.'
  };
  modeHint.textContent=hints[mode.value]||'';
  syncFeatureControls();
}

mode.addEventListener('change',applyMode);
applyMode();

drop.onclick = () => { if(!input.disabled)input.click(); };
drop.onkeydown = e => { if((e.key==='Enter'||e.key===' ')&&!input.disabled){e.preventDefault();input.click();} };
input.onchange = () => choose(input.files[0]);

['dragenter','dragover'].forEach(ev => drop.addEventListener(ev, e => {
  e.preventDefault(); drop.classList.add('over');
}));

['dragleave','drop'].forEach(ev => drop.addEventListener(ev, e => {
  e.preventDefault(); drop.classList.remove('over');
}));

drop.addEventListener('drop', e => choose(e.dataTransfer.files[0]));

function choose(file){
  if(!file||activeJob) return;
  selectedFile = file;
  const ext=(file.name.split('.').pop()||'').toLowerCase();
  selectedIsVideo=['mp4','mkv','mov','avi','webm','m4v','ts','m2ts'].includes(ext) || file.type.startsWith('video/');

  fileName.textContent = file.name + ' • ' + formatBytes(file.size) + (selectedIsVideo ? ' • video' : ' • audio');

  // Per un audio il comportamento standard è la trascrizione semplice.
  if(!selectedIsVideo){
    mode.value='transcribe';
  }
  applyMode();
  go.disabled = false;
  setStatus(selectedIsVideo ? 'Video pronto.' : 'Audio pronto per la trascrizione.');
}

function formatBytes(n){
  const u=['B','KB','MB','GB','TB']; let i=0,v=n;
  while(v>=1024 && i<u.length-1){v/=1024;i++}
  return v.toFixed(i?1:0)+' '+u[i];
}

function setStatus(t,err=false){
  statusEl.textContent=t;
  statusEl.className='status'+(err?' err':'');
}

function esc(s){
  return String(s ?? '').replace(/[&<>"']/g,c=>({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  })[c]);
}

function ts(sec){
  sec=Number(sec||0);
  const h=Math.floor(sec/3600),m=Math.floor((sec%3600)/60),s=Math.floor(sec%60);
  return (h?String(h).padStart(2,'0')+':':'')+
         String(m).padStart(2,'0')+':'+String(s).padStart(2,'0');
}

function voiceForSpeaker(sp){
  const el=document.getElementById('voice'+sp);
  return el ? el.value : '';
}

function render(data){
  lastJson=data;
  resultCard.style.display='block';
  plain.textContent=data.text||'';
  speakers.innerHTML='';
  downloads.innerHTML='';

  if(Array.isArray(data.downloads)){
    for(const d of data.downloads){
      const a=document.createElement('a');
      a.href=d.url;
      a.textContent='⬇ '+d.label;
      a.setAttribute('download',d.name||'');
      downloads.appendChild(a);
    }
  }

  const original=Array.isArray(data.segments)?data.segments:[];
  const translated=Array.isArray(data.subtitle_segments)?data.subtitle_segments:null;
  const dubbed=Array.isArray(data.dub_segments)?data.dub_segments:null;

  if(original.length){
    speakers.innerHTML=original.map((g,i)=>{
      const sp=Math.max(1,Math.min(4,Number(g.speaker||1)));
      const voice=voiceForSpeaker(sp);
      let extra='';

      if(translated && translated[i] && data.subtitle_language &&
         data.subtitle_language!=='original' &&
         translated[i].text!==g.text){
        extra += '<div class="translation"><b>🌐 '+
          esc(data.subtitle_language_label||data.subtitle_language)+':</b> '+
          esc(translated[i].text)+'</div>';
      }

      if(dubbed && dubbed[i] && data.dub_language &&
         data.dub_language!=='original' &&
         dubbed[i].text!==g.text &&
         (!translated || !translated[i] || dubbed[i].text!==translated[i].text)){
        extra += '<div class="translation"><b>🗣️ Doppiaggio '+
          esc(data.dub_language_label||data.dub_language)+':</b> '+
          esc(dubbed[i].text)+'</div>';
      }

      return '<div class="speaker spk'+sp+'">'+
        '<div class="meta">Speaker '+sp+(voice?' · '+esc(voice):'')+
        ' · '+ts(g.start)+' → '+ts(g.end)+'</div>'+
        '<div class="txt">'+esc(g.text)+'</div>'+extra+
      '</div>';
    }).join('');
  }else{
    speakers.innerHTML='<div class="speaker spk1"><div class="txt">'+
      esc(data.text||'Nessun testo restituito.')+'</div></div>';
  }
}

const cancelButton=document.getElementById('cancel');
const progressValue=document.getElementById('progressValue');
const controlBase='__CONTROL_URL__';
const controlToken='__CONTROL_TOKEN__';
let currentXhr=null,activeJob=null,statusPoll=null,isUploading=false;

async function control(method,path){
  const response=await fetch(controlBase+path,{
    method,
    headers:{'X-NeMo-Token':controlToken},
    cache:'no-store'
  });
  if(!response.ok)throw new Error('Servizio di controllo non disponibile ('+response.status+').');
  return response.json();
}

function endJob(){
  if(statusPoll){clearInterval(statusPoll);statusPoll=null;}
  go.disabled=false;
  document.getElementById('fileInput').disabled=false;
  document.getElementById('ttsGo').disabled=false;
  cancelButton.classList.add('hidden');
  cancelButton.disabled=false;
  currentXhr=null;activeJob=null;isUploading=false;
}

async function pollJob(id){
  try{
    const data=await control('GET','/status?job='+id);
    if(activeJob!==id||isUploading||!currentXhr)return;
    if(data.cancelled){setStatus('Interruzione in corso...');return;}
    if(data.phase){setStatus(data.phase+'...');}
    if(Number.isFinite(data.percent)){
      bar.style.width=data.percent+'%';
      progressValue.textContent=data.percent+'%';
    }
  }catch{/* l'esito definitivo viene gestito dalla richiesta principale */}
}

go.onclick=async()=>{
  if(!selectedFile||activeJob)return;
  const file=selectedFile;
  const id=(crypto.randomUUID ? crypto.randomUUID().replaceAll('-','') :
    Array.from(crypto.getRandomValues(new Uint8Array(16)),x=>x.toString(16).padStart(2,'0')).join(''));
  activeJob=id;
  go.disabled=true;
  cancelButton.classList.remove('hidden');
  cancelButton.disabled=true;
  document.getElementById('fileInput').disabled=true;
  document.getElementById('ttsGo').disabled=true;
  resultCard.style.display='none';
  progress.style.display='block';
  bar.style.width='0%';
  progressValue.textContent='0%';
  setStatus('Preparazione del lavoro...');
  try{await control('POST','/arm?job='+id);}
  catch(error){endJob();setStatus(error.message,true);return;}
  if(activeJob!==id)return;
  cancelButton.disabled=false;

  const xhr=new XMLHttpRequest();
  currentXhr=xhr;
  isUploading=true;
  xhr.open('POST','/transcribe');
  xhr.setRequestHeader('X-Job-Id',id);
  xhr.setRequestHeader('X-Filename',encodeURIComponent(file.name));
  xhr.setRequestHeader('X-Language',document.getElementById('lang').value);
  xhr.setRequestHeader('X-Diarization',document.getElementById('diar').checked?'true':'false');
  xhr.setRequestHeader('X-Make-Subs',document.getElementById('makeSubs').checked?'true':'false');
  xhr.setRequestHeader('X-Soft-Subs',document.getElementById('softSubs').checked?'true':'false');
  xhr.setRequestHeader('X-Burn-Subs',document.getElementById('burnSubs').checked?'true':'false');
  xhr.setRequestHeader('X-Dub',document.getElementById('dub').checked?'true':'false');
  xhr.setRequestHeader('X-Subtitle-Language',document.getElementById('subtitleLang').value);
  xhr.setRequestHeader('X-Dub-Language',document.getElementById('dubLang').value);
  for(let i=1;i<=4;i++)xhr.setRequestHeader('X-Voice-'+i,document.getElementById('voice'+i).value);
  xhr.setRequestHeader('Content-Type','application/octet-stream');

  xhr.upload.onprogress=e=>{
    if(e.lengthComputable&&activeJob===id){
      const p=Math.round(e.loaded/e.total*100);
      bar.style.width=Math.max(1,p*0.08)+'%';
      progressValue.textContent='Upload '+p+'%';
      setStatus('Caricamento del file sul PC...');
    }
  };
  xhr.upload.onload=()=>{isUploading=false;setStatus('File ricevuto. Inizio elaborazione...');};
  xhr.onload=()=>{
    if(activeJob!==id)return;
    try{
      const data=JSON.parse(xhr.responseText);
      if(xhr.status<200||xhr.status>=300)throw new Error(data.error||'Errore HTTP '+xhr.status);
      render(data);
      bar.style.width='100%';progressValue.textContent='100%';
      setStatus('Elaborazione completata. File pronti per il download.');
      resultCard.scrollIntoView({behavior:'smooth',block:'start'});
    }catch(error){setStatus(error.message||String(error),true);}
    endJob();
  };
  xhr.onerror=()=>{if(activeJob===id){setStatus('Connessione alla UI locale interrotta.',true);endJob();}};
  xhr.onabort=()=>{if(activeJob===id){setStatus('Elaborazione annullata.');bar.style.width='0%';progressValue.textContent='';endJob();}};
  statusPoll=setInterval(()=>pollJob(id),900);
  try{xhr.send(file);}
  catch(error){setStatus(error.message||String(error),true);endJob();}
};

cancelButton.onclick=async()=>{
  if(!activeJob)return;
  cancelButton.disabled=true;
  setStatus('Interruzione in corso...');
  try{
    await control('POST','/cancel?job='+activeJob);
    if(currentXhr&&isUploading)currentXhr.abort();
    else if(!currentXhr){setStatus('Elaborazione annullata.');endJob();}
  }catch(error){
    cancelButton.disabled=false;
    setStatus('Non riesco a interrompere il lavoro: '+error.message,true);
  }
};

// Text -> Speech nella stessa Studio UI.
const ttsGo=document.getElementById('ttsGo');
const ttsText=document.getElementById('ttsText');
const ttsStatus=document.getElementById('ttsStatus');
const ttsAudio=document.getElementById('ttsAudio');
const ttsDownload=document.getElementById('ttsDownload');
let ttsBlobUrl=null;

ttsGo.onclick=async()=>{
  const text=ttsText.value.trim();
  if(!text){ttsStatus.textContent='Inserisci del testo.';return;}
  ttsGo.disabled=true;
  ttsStatus.textContent='MagpieTTS sta generando la voce...';
  try{
    const r=await fetch('/tts',{
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({
        text,
        language:document.getElementById('ttsLang').value,
        voice:document.getElementById('ttsVoice').value
      })
    });
    if(!r.ok){
      let msg='Errore TTS';
      try{const j=await r.json();msg=j.error||msg;}catch{}
      throw new Error(msg);
    }
    const blob=await r.blob();
    if(ttsBlobUrl)URL.revokeObjectURL(ttsBlobUrl);
    ttsBlobUrl=URL.createObjectURL(blob);
    ttsAudio.src=ttsBlobUrl;
    ttsAudio.classList.remove('hidden');
    ttsDownload.href=ttsBlobUrl;
    ttsDownload.classList.remove('hidden');
    ttsStatus.textContent='Voce generata.';
    ttsAudio.play().catch(()=>{});
  }catch(e){
    ttsStatus.textContent=e.message||String(e);
  }finally{ttsGo.disabled=false;}
};

document.getElementById('nvidiaUi').onclick=()=>window.open('__NEMO_URL__','_blank');

document.getElementById('copy').onclick=async()=>{
  await navigator.clipboard.writeText((lastJson&&lastJson.text)||'');
  setStatus('Testo copiato negli appunti.');
};

function downloadBlob(name,text,type){
  const b=new Blob([text],{type});
  const a=document.createElement('a');
  a.href=URL.createObjectURL(b);a.download=name;a.click();
  setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

document.getElementById('downloadTxt').onclick=()=>{
  const base=(selectedFile?selectedFile.name.replace(/\.[^.]+$/,''):'trascrizione');
  downloadBlob(base+'.txt',(lastJson&&lastJson.text)||'','text/plain;charset=utf-8');
};

document.getElementById('downloadJson').onclick=()=>{
  const base=(selectedFile?selectedFile.name.replace(/\.[^.]+$/,''):'trascrizione');
  downloadBlob(base+'.json',JSON.stringify(lastJson,null,2),'application/json;charset=utf-8');
};
</script>
</body>
</html>
'@

# ------------------------------------------------------------
# Avvio / prerequisiti
# ------------------------------------------------------------
Clear-Host

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " NeMo Studio - Windows / CUDA" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Runtime : $Runtime"
Write-Host "Models  : $Models"
Write-Host "Temp    : $Temp"
Write-Host "Output  : $Output"
Write-Host ""

$Smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $Smi) {
    throw "nvidia-smi.exe non trovato. Verifica i driver NVIDIA."
}

Write-Host "[GPU]" -ForegroundColor Yellow
& $Smi.Source --query-gpu=name,driver_version,memory.total --format=csv,noheader

if ($LASTEXITCODE -ne 0) {
    throw "Il driver NVIDIA non risponde correttamente."
}

$Nvcc = Get-Command nvcc.exe -ErrorAction SilentlyContinue
if ($Nvcc) {
    $CudaVersion = (& $Nvcc.Source --version |
        Select-String "release\s+([0-9]+\.[0-9]+)" |
        Select-Object -First 1)

    if ($CudaVersion -and $CudaVersion.Matches.Count -gt 0) {
        Write-Host "CUDA Toolkit: $($CudaVersion.Matches[0].Groups[1].Value)" -ForegroundColor DarkGray
    }
}

$Ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
$Ffprobe = Get-Command ffprobe.exe -ErrorAction SilentlyContinue

if (-not $Ffmpeg) {
    throw "ffmpeg.exe non trovato nel PATH."
}

if (-not $Ffprobe) {
    throw "ffprobe.exe non trovato nel PATH."
}

Write-Host "FFmpeg : $($Ffmpeg.Source)" -ForegroundColor DarkGray
Write-Host "FFprobe: $($Ffprobe.Source)" -ForegroundColor DarkGray
Write-Host ""

# 1. Installer aggiornato
Write-Host "[1/5] Aggiorno l'installer ufficiale NVIDIA..." -ForegroundColor Yellow

try {
    Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $Installer
}
catch {
    if (Test-Path $Installer) {
        Write-Warning "GitHub non raggiungibile: uso la copia locale dell'installer."
    }
    else {
        throw "Impossibile scaricare l'installer NVIDIA: $($_.Exception.Message)"
    }
}

# 2. Install/update
Write-Host "[2/5] Installo/aggiorno NeMo-Speech.cpp..." -ForegroundColor Yellow

& $Installer `
    -Prefix $Runtime `
    -Backend cuda `
    -Profile server `
    -BinaryOnly

if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "Installazione/aggiornamento NeMo-Speech.cpp fallito (codice $LASTEXITCODE)."
}

$NeMo = Join-Path $Runtime "bin\nemo-speech.exe"

if (-not (Test-Path $NeMo)) {
    throw "nemo-speech.exe non trovato in: $NeMo"
}

$Bin = Join-Path $Runtime "bin"

if (($env:Path -split ";") -notcontains $Bin) {
    $env:Path = "$Bin;$env:Path"
}

# 3. Doctor
Write-Host ""
Write-Host "[3/5] Verifica runtime..." -ForegroundColor Yellow

& $NeMo --version
if ($LASTEXITCODE -ne 0) {
    throw "nemo-speech --version ha restituito un errore."
}

& $NeMo doctor
if ($LASTEXITCODE -ne 0) {
    throw "nemo-speech doctor ha segnalato un errore."
}

$NeMoPort = Get-FreeLocalPort -StartPort 8080 -EndPort 8089
$UiPort   = Get-FreeLocalPort -StartPort 8090 -EndPort 8199
$ControlPort = Get-FreeLocalPort -StartPort 8300 -EndPort 8399
$ControlToken = [guid]::NewGuid().ToString("N")

$NeMoUrl = "http://127.0.0.1:$NeMoPort"
$UiUrl   = "http://127.0.0.1:$UiPort/"
$ControlUrl = "http://127.0.0.1:$ControlPort"

$UiHtml = $UiHtmlTemplate.Replace("__NEMO_URL__", $NeMoUrl).Replace("__CONTROL_URL__", $ControlUrl).Replace("__CONTROL_TOKEN__", $ControlToken)

$NeMoOut = Join-Path $Logs "nemo-server.log"
$NeMoErr = Join-Path $Logs "nemo-server-error.log"

Remove-Item -Force -ErrorAction SilentlyContinue $NeMoOut, $NeMoErr

# 4. Server NVIDIA
Write-Host ""
Write-Host "[4/5] Avvio ASR + diarizzazione + MagpieTTS..." -ForegroundColor Green
Write-Host "La prima volta MagpieTTS/NanoCodec verranno scaricati automaticamente." -ForegroundColor DarkGray

$NeMoArgs = @(
    "serve",
    "--host", "127.0.0.1",
    "--port", "$NeMoPort",
    "--asr-model", "nemotron-3.5",
    "--diar-model", "sortformer",
    "--tts-model", "magpie",
    "--codec-model", "nano-codec",
    "--tokenizer-dir", "magpie",
    "--tts.language-code", "it",
    "--tts.voice-name", "John",
    "--max-upload-mb", "2048",
    "--read-timeout", "3600",
    "--write-timeout", "3600"
)

try {
try {
    $NeMoProcess = Start-Process `
        -FilePath $NeMo `
        -ArgumentList $NeMoArgs `
        -PassThru `
        -WindowStyle Hidden `
        -RedirectStandardOutput $NeMoOut `
        -RedirectStandardError $NeMoErr
}
catch {
    $OriginalError = $_.Exception.Message
    $Native = $_.Exception
    while ($Native -and $Native -isnot [System.ComponentModel.Win32Exception]) {
        $Native = $Native.InnerException
    }
    $Code = if ($Native) { $Native.NativeErrorCode } else { "non disponibile" }
    $MemoryReport = Get-StartupMemoryReport
    $Hint = if ($Code -in @(8, 14, 1455)) {
        "Windows segnala memoria/commit insufficienti. Chiudi temporaneamente i modelli AI più grandi e verifica che il file di paging sia attivo; poi riprova."
    }
    else {
        "Controlla il codice Windows e i log in $Logs prima di cambiare le impostazioni di memoria."
    }
    throw "Impossibile avviare NeMo (errore Windows $Code). $OriginalError`n$MemoryReport`n$Hint"
}

# Attende readiness.
$Ready = $false

for ($i = 0; $i -lt 900; $i++) {
    if ($NeMoProcess.HasExited) {
        $ErrText = ""

        if (Test-Path $NeMoErr) {
            $ErrText = (Get-Content $NeMoErr -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
        }

        throw "Il server NeMo si è chiuso durante l'avvio.`n$ErrText"
    }

    try {
        $r = Invoke-RestMethod -Uri "$NeMoUrl/ready" -TimeoutSec 2

        if ($r.ready -eq $true) {
            $Ready = $true
            break
        }
    }
    catch {}

    Start-Sleep -Seconds 1
}

if (-not $Ready) {
    throw "NeMo non è diventato pronto. Controlla: $NeMoErr"
}

# 5. UI locale
Write-Host "[5/5] Avvio NeMo Studio..." -ForegroundColor Green
Write-Host ""
Write-Host "UI STUDIO   : $UiUrl" -ForegroundColor Cyan
Write-Host "Playground  : $NeMoUrl/"
Write-Host "Output      : $Output"
Write-Host ""
Write-Host "Speaker: blu / rosso / viola / verde" -ForegroundColor DarkGray
Write-Host "Voci   : John / Sofia / Jason / Aria" -ForegroundColor DarkGray
Write-Host "CTRL+C chiude UI e server NeMo." -ForegroundColor DarkGray
Write-Host ""

$TcpListener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Loopback,
    $UiPort
)

$TcpListener.Server.ExclusiveAddressUse = $true
$TcpListener.Start()
$script:JobControl = [NeMoJobControl]::new($ControlPort, $UiUrl.TrimEnd('/'), $ControlToken)

Start-Process $UiUrl

    while ($true) {
        # AcceptTcpClient() blocca il thread finché non arriva una richiesta:
        # quando la UI è inattiva PowerShell non può reagire subito a CTRL+C.
        # Torna regolarmente nel motore PowerShell per consentire l'interruzione
        # e l'esecuzione del blocco finally che arresta i server.
        if (-not $TcpListener.Pending()) {
            Start-Sleep -Milliseconds 200
            continue
        }
        $Client = $TcpListener.AcceptTcpClient()

        try {
            $Client.ReceiveTimeout = 300000
            $Client.SendTimeout    = 300000
            $Stream = $Client.GetStream()

            $HeaderText = Read-HttpHeaderBlock -Stream $Stream
            $Request = Parse-HttpRequestHeaders -HeaderText $HeaderText

            # UI
            if ($Request.Method -eq "GET" -and ($Request.Target -eq "/" -or $Request.Target.StartsWith("/?"))) {
                $Body = [System.Text.Encoding]::UTF8.GetBytes($UiHtml)

                Write-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 200 `
                    -StatusText "OK" `
                    -ContentType "text/html; charset=utf-8" `
                    -Body $Body

                continue
            }

            # Download output
            if ($Request.Method -eq "GET" -and $Request.Target.StartsWith("/download?")) {
                $Match = [regex]::Match($Request.Target, '(?:\?|&)id=([^&]+)')

                if (-not $Match.Success) {
                    Write-HttpResponse `
                        -Stream $Stream `
                        -StatusCode 400 `
                        -StatusText "Bad Request" `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes("ID mancante"))
                    continue
                }

                $Id = [uri]::UnescapeDataString($Match.Groups[1].Value)

                if (-not $DownloadFiles.ContainsKey($Id)) {
                    Write-HttpResponse `
                        -Stream $Stream `
                        -StatusCode 404 `
                        -StatusText "Not Found" `
                        -Body ([System.Text.Encoding]::UTF8.GetBytes("Download non trovato"))
                    continue
                }

                Write-FileHttpResponse -Stream $Stream -Path $DownloadFiles[$Id]
                continue
            }

            if ($Request.Method -eq "GET" -and $Request.Target -eq "/favicon.ico") {
                Write-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 204 `
                    -StatusText "No Content" `
                    -Body @()

                continue
            }

            # Testo -> voce (MagpieTTS)
            if ($Request.Method -eq "POST" -and $Request.Target.StartsWith("/tts")) {
                try {
                    if (-not $Request.Headers.ContainsKey("Content-Length")) {
                        throw "Content-Length mancante."
                    }

                    [long]$ContentLength = 0
                    if (-not [long]::TryParse($Request.Headers["Content-Length"], [ref]$ContentLength)) {
                        throw "Content-Length non valido."
                    }

                    $RawBody = Read-RawRequestBodyText `
                        -Stream $Stream `
                        -ContentLength $ContentLength

                    $Payload = $RawBody | ConvertFrom-Json
                    $TextToSpeak = [string]$Payload.text
                    $TtsLanguage = [string]$Payload.language
                    $TtsVoice = [string]$Payload.voice

                    if ([string]::IsNullOrWhiteSpace($TextToSpeak)) {
                        throw "Testo TTS vuoto."
                    }

                    if ($TtsLanguage -notin @("it","en","fr","de","es","vi","hi")) {
                        $TtsLanguage = "it"
                    }

                    if ($TtsVoice -notin @("John","Sofia","Jason","Aria","Leo")) {
                        $TtsVoice = "John"
                    }

                    $TtsTemp = Join-Path $Temp ("tts-preview-" + [guid]::NewGuid().ToString("N") + ".wav")

                    try {
                        Invoke-NeMoTts `
                            -Port $NeMoPort `
                            -Text $TextToSpeak `
                            -Voice $TtsVoice `
                            -Language $TtsLanguage `
                            -OutputPath $TtsTemp

                        $TtsBytes = [System.IO.File]::ReadAllBytes($TtsTemp)
                        Write-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -ContentType "audio/wav" `
                            -Body $TtsBytes
                    }
                    finally {
                        Remove-Item -Force -ErrorAction SilentlyContinue $TtsTemp
                    }
                }
                catch {
                    Write-JsonResponse `
                        -Stream $Stream `
                        -StatusCode 500 `
                        -StatusText "Internal Server Error" `
                        -Object @{ error = $_.Exception.Message }
                }

                continue
            }

            # Elaborazione
            if ($Request.Method -eq "POST" -and $Request.Target.StartsWith("/transcribe")) {
                $script:CurrentJobId = $null
                $JobOut = $null
                $script:CompletedJob = $false
                try {
                    if (-not $Request.Headers.ContainsKey("X-Job-Id") -or
                        $Request.Headers["X-Job-Id"] -notmatch '^[0-9a-f]{32}$') {
                        throw "Job non registrato. Ricarica la pagina e riprova."
                    }
                    $script:CurrentJobId = $Request.Headers["X-Job-Id"]
                    $script:JobControl.Begin($script:CurrentJobId)
                    Assert-JobActive
                    if (-not $Request.Headers.ContainsKey("Content-Length")) {
                        throw "Content-Length mancante."
                    }

                    [long]$ContentLength = 0

                    if (-not [long]::TryParse(
                        $Request.Headers["Content-Length"],
                        [ref]$ContentLength
                    )) {
                        throw "Content-Length non valido."
                    }

                    $OriginalName = "upload.bin"

                    if ($Request.Headers.ContainsKey("X-Filename")) {
                        $OriginalName = [uri]::UnescapeDataString(
                            $Request.Headers["X-Filename"]
                        )
                    }

                    $Language = "it-IT"

                    if ($Request.Headers.ContainsKey("X-Language")) {
                        $Candidate = $Request.Headers["X-Language"].Trim()

                        if ($Candidate -match '^(auto|[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})?)$') {
                            $Language = $Candidate
                        }
                    }

                    $Diarization = Get-HeaderBool `
                        -Headers $Request.Headers `
                        -Name "X-Diarization" `
                        -Default $true

                    $MakeSubs = Get-HeaderBool `
                        -Headers $Request.Headers `
                        -Name "X-Make-Subs" `
                        -Default $false

                    $MakeSoftSubs = Get-HeaderBool `
                        -Headers $Request.Headers `
                        -Name "X-Soft-Subs" `
                        -Default $false

                    $BurnSubs = Get-HeaderBool `
                        -Headers $Request.Headers `
                        -Name "X-Burn-Subs" `
                        -Default $false

                    $MakeDub = Get-HeaderBool `
                        -Headers $Request.Headers `
                        -Name "X-Dub" `
                        -Default $false

                    $SubtitleLanguage = "original"
                    if ($Request.Headers.ContainsKey("X-Subtitle-Language")) {
                        $CandidateSubtitleLanguage = $Request.Headers["X-Subtitle-Language"].Trim()
                        if (
                            $CandidateSubtitleLanguage -eq "original" -or
                            $SupportedTranslationLanguages -contains $CandidateSubtitleLanguage
                        ) {
                            $SubtitleLanguage = $CandidateSubtitleLanguage
                        }
                    }

                    $DubLanguage = "original"
                    if ($Request.Headers.ContainsKey("X-Dub-Language")) {
                        $CandidateDubLanguage = $Request.Headers["X-Dub-Language"].Trim()
                        if (
                            $CandidateDubLanguage -eq "original" -or
                            $SupportedDubLanguages -contains $CandidateDubLanguage
                        ) {
                            $DubLanguage = $CandidateDubLanguage
                        }
                    }

                    $Voices = @{}

                    foreach ($sp in 1..4) {
                        $HeaderName = "X-Voice-$sp"
                        $Voice = $DefaultVoices[$sp]

                        if ($Request.Headers.ContainsKey($HeaderName)) {
                            $CandidateVoice = $Request.Headers[$HeaderName].Trim()

                            if ($CandidateVoice -in @("John","Sofia","Jason","Aria","Leo")) {
                                $Voice = $CandidateVoice
                            }
                        }

                        $Voices[$sp] = $Voice
                    }

                    $Ext = [System.IO.Path]::GetExtension($OriginalName).ToLowerInvariant()

                    if ([string]::IsNullOrWhiteSpace($Ext) -or $Ext.Length -gt 12) {
                        $Ext = ".bin"
                    }

                    $IsVideo = $VideoExtensions -contains $Ext
                    $BaseName = Get-SafeFileName $OriginalName
                    $JobId = $script:CurrentJobId
                    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"

                    $InputPath = Join-Path $Temp ("input-" + $JobId + $Ext)
                    $WavPath   = Join-Path $Temp ("audio-" + $JobId + ".wav")
                    $JobTemp   = Join-Path $Temp ("job-" + $JobId)
                    $JobOut    = Join-Path $Output ("$BaseName-$Stamp-$($JobId.Substring(0,8))")

                    $script:CompletedJob = $false
                    try {
                        New-Item -ItemType Directory -Force -Path $JobTemp, $JobOut | Out-Null
                        Set-JobPhase -Name 'Ricezione del file' -Percent 2
                        Save-RawRequestBody `
                            -Stream $Stream `
                            -ContentLength $ContentLength `
                            -Destination $InputPath

                        # Audio per ASR
                        Set-JobPhase -Name 'Preparazione audio' -Percent 12
                        [void](Invoke-MediaCommand -Executable $Ffmpeg.Source -Arguments @(
                            '-hide_banner','-loglevel','error','-nostdin','-y',
                            '-i',$InputPath,'-map','0:a:0','-vn','-ac','1',
                            '-ar','16000','-c:a','pcm_s16le',$WavPath
                        ))

                        # ASR + diarization
                        Set-JobPhase -Name 'Trascrizione e riconoscimento voci' -Percent 24
                        $Result = Invoke-NeMoTranscription `
                            -WavPath $WavPath `
                            -Port $NeMoPort `
                            -Language $Language `
                            -Diarization $Diarization

                        if (-not $Result.words) {
                            throw "La trascrizione non contiene timestamp parola-per-parola."
                        }

                        $Segments = Convert-WordsToSegments -Words $Result.words
                        $Result | Add-Member -NotePropertyName "segments" -NotePropertyValue $Segments -Force

                        # Lingua sorgente effettiva.
                        $DetectedLanguage = $Language
                        if ($Result.language) {
                            $DetectedLanguage = [string]$Result.language
                        }

                        if ($DetectedLanguage -eq "auto") {
                            throw "Nemotron non ha restituito la lingua rilevata; seleziona manualmente la lingua ASR."
                        }

                        # ----------------------------------------------------
                        # Traduzione sottotitoli e/o doppiaggio
                        # ----------------------------------------------------
                        $SubtitleSegments = $Segments
                        $SubtitleOutputLanguage = "original"
                        $NeedSubtitleWork = $MakeSubs -or ($IsVideo -and ($MakeSoftSubs -or $BurnSubs))
                        $NeedsRiva = ($NeedSubtitleWork -and $SubtitleLanguage -ne "original") -or
                            ($MakeDub -and $DubLanguage -ne "original")
                        $SourceRivaLanguage = if ($NeedsRiva) {
                            Convert-ToRivaLanguage $DetectedLanguage
                        } else {
                            $DetectedLanguage
                        }

                        if ($NeedSubtitleWork -and $SubtitleLanguage -ne "original") {
                            Set-JobPhase -Name 'Traduzione sottotitoli' -Percent 44
                            $TargetSubtitleRiva = Convert-ToRivaLanguage $SubtitleLanguage

                            if ($TargetSubtitleRiva -ne $SourceRivaLanguage) {
                                Write-Host (
                                    "[RIVA] Sottotitoli: {0} -> {1}" -f
                                    $SourceRivaLanguage,
                                    $TargetSubtitleRiva
                                ) -ForegroundColor Cyan

                                $SubtitleSegments = Translate-Segments `
                                    -Segments $Segments `
                                    -SourceLanguage $SourceRivaLanguage `
                                    -TargetLanguage $TargetSubtitleRiva
                            }

                            $SubtitleOutputLanguage = $TargetSubtitleRiva
                        }

                        $DubSegments = $Segments
                        $DubOutputLanguage = "original"

                        if ($MakeDub -and $DubLanguage -ne "original") {
                            Set-JobPhase -Name 'Traduzione doppiaggio' -Percent 50
                            $TargetDubRiva = Convert-ToRivaLanguage $DubLanguage

                            if ($TargetDubRiva -ne $SourceRivaLanguage) {
                                # Riusa la traduzione sottotitoli quando coincide.
                                if (
                                    $SubtitleOutputLanguage -ne "original" -and
                                    $SubtitleOutputLanguage -eq $TargetDubRiva
                                ) {
                                    $DubSegments = $SubtitleSegments
                                }
                                else {
                                    Write-Host (
                                        "[RIVA] Doppiaggio: {0} -> {1}" -f
                                        $SourceRivaLanguage,
                                        $TargetDubRiva
                                    ) -ForegroundColor Cyan

                                    $DubSegments = Translate-Segments `
                                        -Segments $Segments `
                                        -SourceLanguage $SourceRivaLanguage `
                                        -TargetLanguage $TargetDubRiva
                                }
                            }

                            $DubOutputLanguage = $TargetDubRiva
                        }

                        # Dati per la UI.
                        $Result | Add-Member `
                            -NotePropertyName "subtitle_segments" `
                            -NotePropertyValue $SubtitleSegments `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "dub_segments" `
                            -NotePropertyValue $(if ($MakeDub) { $DubSegments } else { @() }) `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "source_language" `
                            -NotePropertyValue $SourceRivaLanguage `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "subtitle_language" `
                            -NotePropertyValue $SubtitleOutputLanguage `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "subtitle_language_label" `
                            -NotePropertyValue (Get-LanguageLabel $SubtitleOutputLanguage) `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "dub_language" `
                            -NotePropertyValue $(if ($MakeDub) { $DubOutputLanguage } else { "original" }) `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "dub_language_label" `
                            -NotePropertyValue $(if ($MakeDub) { Get-LanguageLabel $DubOutputLanguage } else { "Originale" }) `
                            -Force

                        # ----------------------------------------------------
                        # Sottotitoli: solo quando richiesti dalla modalità
                        # ----------------------------------------------------
                        $SubsForVideo = $null
                        $SubtitleFileLanguage = $SourceRivaLanguage
                        $SubtitleLabelSuffix = "originali"

                        if ($NeedSubtitleWork) {
                            $OriginalSubs = Write-SubtitleFiles `
                                -Segments $Segments `
                                -Directory $JobOut `
                                -BaseName "$BaseName-originale"

                            $DownloadItems = [System.Collections.Generic.List[object]]::new()

                            if ($MakeSubs) {
                                $DownloadItems.Add((Register-Download -Path $OriginalSubs.Srt -Label "SRT originale"))
                                $DownloadItems.Add((Register-Download -Path $OriginalSubs.Vtt -Label "VTT originale"))
                                $DownloadItems.Add((Register-Download -Path $OriginalSubs.Ass -Label "ASS originale colorato"))
                            }

                            $SubsForVideo = $OriginalSubs

                            if ($SubtitleOutputLanguage -ne "original" -and $SubtitleOutputLanguage -ne $SourceRivaLanguage) {
                                $SafeLang = $SubtitleOutputLanguage.Replace("-", "_")

                                $TranslatedSubs = Write-SubtitleFiles `
                                    -Segments $SubtitleSegments `
                                    -Directory $JobOut `
                                    -BaseName "$BaseName-$SafeLang"

                                if ($MakeSubs) {
                                    $DownloadItems.Add(
                                        (Register-Download `
                                            -Path $TranslatedSubs.Srt `
                                            -Label "SRT $(Get-LanguageLabel $SubtitleOutputLanguage)")
                                    )
                                    $DownloadItems.Add(
                                        (Register-Download `
                                            -Path $TranslatedSubs.Vtt `
                                            -Label "VTT $(Get-LanguageLabel $SubtitleOutputLanguage)")
                                    )
                                    $DownloadItems.Add(
                                        (Register-Download `
                                            -Path $TranslatedSubs.Ass `
                                            -Label "ASS colorato $(Get-LanguageLabel $SubtitleOutputLanguage)")
                                    )
                                }

                                $SubsForVideo = $TranslatedSubs
                                $SubtitleFileLanguage = $SubtitleOutputLanguage
                                $SubtitleLabelSuffix = Get-LanguageLabel $SubtitleOutputLanguage
                            }
                        }
                        else {
                            $DownloadItems = [System.Collections.Generic.List[object]]::new()
                        }

                        # ----------------------------------------------------
                        # MKV con ASS selezionabile
                        # ----------------------------------------------------
                        if ($IsVideo -and $MakeSoftSubs -and $null -ne $SubsForVideo) {
                            Set-JobPhase -Name 'Creazione video con sottotitoli' -Percent 53
                            $SoftMkv = Join-Path $JobOut "$BaseName-sottotitoli-colorati.mkv"

                            New-SoftSubtitleMkv `
                                -InputPath $InputPath `
                                -AssPath $SubsForVideo.Ass `
                                -OutputPath $SoftMkv `
                                -FfmpegPath $Ffmpeg.Source `
                                -LanguageTag $SubtitleFileLanguage `
                                -SubtitleTitle "Sottotitoli AI - $SubtitleLabelSuffix"

                            $DownloadItems.Add(
                                (Register-Download `
                                    -Path $SoftMkv `
                                    -Label "Video + sottotitoli colorati ($SubtitleLabelSuffix)")
                            )
                        }

                        # ----------------------------------------------------
                        # Burn-in opzionale
                        # ----------------------------------------------------
                        if ($IsVideo -and $BurnSubs -and $null -ne $SubsForVideo) {
                            Set-JobPhase -Name 'Impressione sottotitoli nel video' -Percent 55
                            $BurnMkv = Join-Path $JobOut "$BaseName-sottotitoli-impressi.mkv"

                            New-BurnedSubtitleVideo `
                                -InputPath $InputPath `
                                -AssPath $SubsForVideo.Ass `
                                -OutputPath $BurnMkv `
                                -FfmpegPath $Ffmpeg.Source

                            $DownloadItems.Add(
                                (Register-Download `
                                    -Path $BurnMkv `
                                    -Label "Video con sottotitoli impressi ($SubtitleLabelSuffix)")
                            )
                        }

                        # ----------------------------------------------------
                        # Doppiaggio AI opzionale
                        # ----------------------------------------------------
                        if ($MakeDub) {
                            Set-JobPhase -Name 'Preparazione doppiaggio' -Percent 57
                            $MediaDuration = Get-MediaDuration `
                                -Path $InputPath `
                                -FfprobePath $Ffprobe.Source

                            $TtsSourceLanguage = $DetectedLanguage
                            if ($DubOutputLanguage -ne "original") {
                                $TtsSourceLanguage = $DubOutputLanguage
                            }

                            $TtsLanguage = Convert-ToTtsLanguage $TtsSourceLanguage
                            $DubLangLabel = Get-LanguageLabel $(if ($DubOutputLanguage -eq "original") { $SourceRivaLanguage } else { $DubOutputLanguage })
                            $SafeDubLang = $(if ($DubOutputLanguage -eq "original") { "originale" } else { $DubOutputLanguage.Replace("-", "_") })
                            $DubWav = Join-Path $JobOut "$BaseName-doppiaggio-$SafeDubLang.wav"

                            New-DubTrack `
                                -Segments $DubSegments `
                                -NeMoPort $NeMoPort `
                                -TtsLanguage $TtsLanguage `
                                -Voices $Voices `
                                -TotalDuration $MediaDuration `
                                -JobTemp $JobTemp `
                                -OutputPath $DubWav `
                                -FfmpegPath $Ffmpeg.Source `
                                -FfprobePath $Ffprobe.Source

                            $DownloadItems.Add(
                                (Register-Download `
                                    -Path $DubWav `
                                    -Label "Traccia doppiaggio AI - $DubLangLabel")
                            )

                            if ($IsVideo) {
                                Set-JobPhase -Name 'Inserimento audio nel video' -Percent 94
                                $DubMkv = Join-Path $JobOut "$BaseName-doppiaggio-$SafeDubLang.mkv"

                                New-DubbedMkv `
                                    -InputPath $InputPath `
                                    -DubPath $DubWav `
                                    -OutputPath $DubMkv `
                                    -FfmpegPath $Ffmpeg.Source

                                $DownloadItems.Add(
                                    (Register-Download `
                                        -Path $DubMkv `
                                        -Label "Video + doppiaggio AI - $DubLangLabel")
                                )
                            }
                        }

                        $Result | Add-Member `
                            -NotePropertyName "downloads" `
                            -NotePropertyValue @($DownloadItems) `
                            -Force

                        $Result | Add-Member `
                            -NotePropertyName "output_directory" `
                            -NotePropertyValue $JobOut `
                            -Force

                        $Json = $Result | ConvertTo-Json -Depth 30 -Compress
                        $Body = [System.Text.Encoding]::UTF8.GetBytes($Json)

                        Assert-JobActive
                        Write-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -ContentType "application/json; charset=utf-8" `
                            -Body $Body
                        $script:CompletedJob = $true
                    }
                    finally {
                        # Originale caricato e WAV temporanei vengono sempre eliminati.
                        Remove-Item -Force -ErrorAction SilentlyContinue $InputPath, $WavPath
                        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue $JobTemp
                        if (-not $script:CompletedJob -and $JobOut) {
                            Remove-Item -Force -Recurse -LiteralPath $JobOut -ErrorAction SilentlyContinue
                            foreach ($DownloadId in @($DownloadFiles.Keys)) {
                                if ($DownloadFiles[$DownloadId] -like "$JobOut\*") {
                                    $DownloadFiles.Remove($DownloadId)
                                }
                            }
                        }
                    }
                }
                catch {
                    $WasCancelled = $script:CurrentJobId -and $script:JobControl.Token.IsCancellationRequested
                    try {
                        Write-JsonResponse `
                            -Stream $Stream `
                            -StatusCode $(if ($WasCancelled) { 409 } else { 500 }) `
                            -StatusText $(if ($WasCancelled) { "Conflict" } else { "Internal Server Error" }) `
                            -Object @{ error = $(if ($WasCancelled) { "Elaborazione annullata." } else { $_.Exception.Message }) }
                    }
                    catch {}
                }
                finally {
                    if ($script:CurrentJobId) {
                        $script:JobControl.Finish($script:CurrentJobId, $script:CompletedJob)
                    }
                    $script:CurrentJobId = $null
                }

                continue
            }

            Write-HttpResponse `
                -Stream $Stream `
                -StatusCode 404 `
                -StatusText "Not Found" `
                -ContentType "text/plain; charset=utf-8" `
                -Body ([System.Text.Encoding]::UTF8.GetBytes("Not found"))
        }
        catch {
            try {
                Write-JsonResponse `
                    -Stream $Stream `
                    -StatusCode 500 `
                    -StatusText "Internal Server Error" `
                    -Object @{ error = $_.Exception.Message }
            }
            catch {}
        }
        finally {
            if ($null -ne $Client) {
                try { $Client.Close() } catch {}
            }
        }
    }
}
finally {
    if ($script:CurrentJobId -and -not $script:CompletedJob -and $JobOut) {
        Remove-Item -Force -Recurse -LiteralPath $JobOut -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:JobControl) {
        try { $script:JobControl.Dispose() } catch {}
    }
    if ($null -ne $TcpListener) { try { $TcpListener.Stop() } catch {} }

    if ($null -ne $script:NmtProcess -and -not $script:NmtProcess.HasExited) {
        Write-Host ""
        Write-Host "Chiusura Riva Translate..." -ForegroundColor DarkGray
        try {
            $script:NmtProcess.Kill($true)
            [void]$script:NmtProcess.WaitForExit(5000)
        }
        catch { Write-Warning "Impossibile chiudere Riva Translate (PID $($script:NmtProcess.Id)): $($_.Exception.Message)" }
    }

    if ($null -ne $NeMoProcess -and -not $NeMoProcess.HasExited) {
        Write-Host ""
        Write-Host "Chiusura server NeMo..." -ForegroundColor DarkGray
        try {
            $NeMoProcess.Kill($true)
            [void]$NeMoProcess.WaitForExit(5000)
        }
        catch { Write-Warning "Impossibile chiudere NeMo (PID $($NeMoProcess.Id)): $($_.Exception.Message)" }
    }
}
