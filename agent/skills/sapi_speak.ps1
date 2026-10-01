# Synthèse vocale LOCALE via les voix Windows (System.Speech / SAPI 5) — V3 LOT 11.
# Paramètres lus dans un fichier JSON (UTF-8) passé en argument : le texte n'apparaît JAMAIS
# dans une ligne de commande (aucune injection possible). Sortie : nom de la voix utilisée.
#   {"text": "...", "voice": "Hortense" | "", "rate": -10..10, "output": "C:\\...\\a.wav" | ""}
# Codes : 0 succès · 3 voix introuvable · 4 paramètres illisibles.
param([Parameter(Mandatory = $true)][string]$ParamsFile)
$ErrorActionPreference = 'Stop'
try {
    $p = Get-Content -Raw -Encoding UTF8 -LiteralPath $ParamsFile | ConvertFrom-Json
} catch {
    [Console]::Error.WriteLine("paramètres illisibles : $($_.Exception.Message)")
    exit 4
}
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $voices = @($s.GetInstalledVoices() | Where-Object { $_.Enabled })
    $chosen = $null
    if ($p.voice) {
        $needle = ([string]$p.voice).ToLowerInvariant()
        $chosen = $voices | Where-Object { $_.VoiceInfo.Name.ToLowerInvariant().Contains($needle) } | Select-Object -First 1
        if (-not $chosen) {
            [Console]::Error.WriteLine("voix introuvable : $($p.voice)")
            exit 3
        }
    } else {
        $chosen = $voices | Where-Object { $_.VoiceInfo.Culture.Name -like 'fr*' } | Select-Object -First 1
    }
    if ($chosen) { $s.SelectVoice($chosen.VoiceInfo.Name) }
    $s.Rate = [Math]::Max(-10, [Math]::Min(10, [int]$p.rate))
    if ($p.output) { $s.SetOutputToWaveFile([string]$p.output) } else { $s.SetOutputToDefaultAudioDevice() }
    $s.Speak([string]$p.text)
    [Console]::Out.WriteLine($s.Voice.Name)
} finally {
    $s.Dispose()
}
exit 0
