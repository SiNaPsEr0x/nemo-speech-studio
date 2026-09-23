# NeMo Studio

Interfaccia locale per trascrivere audio e video, riconoscere le voci, creare sottotitoli e generare un doppiaggio con [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp).

## Cosa fa

- Installa e aggiorna il runtime Windows/CUDA di NeMo-Speech.cpp tramite lo script ufficiale NVIDIA.
- Avvia una pagina locale per caricare audio e video, trascrivere, tradurre e generare sottotitoli SRT, VTT e ASS.
- Può creare una traccia doppiata e inserirla in un video MKV insieme alle tracce audio originali.
- Mostra lo stato del lavoro e permette di interrompere il job. `Ctrl+C` chiude la pagina locale e i processi avviati dal launcher.

## Requisiti

- Windows con PowerShell **7.2 o successivo** e GPU NVIDIA supportata dal runtime CUDA di NeMo-Speech.cpp.
- Driver NVIDIA funzionante (`nvidia-smi.exe`).
- `ffmpeg.exe` e `ffprobe.exe` disponibili nel `PATH`.
- Connessione Internet per la prima installazione e per scaricare i modelli. Sono richiesti spazio su disco e memoria adeguati ai modelli scelti.

## Avvio

Salva `Avvia-NeMo-Studio.ps1` sul PC. Il percorso predefinito dei dati è `D:\Modelli\NeMo-Speech`: se non hai un'unità `D:`, cambia la variabile `$Base` all'inizio dello script prima dell'avvio.

Apri PowerShell 7 nella cartella del file ed esegui:

```powershell
pwsh -NoProfile -File .\Avvia-NeMo-Studio.ps1
```

Il launcher mostra l'indirizzo della UI locale. I risultati completati vengono salvati nella cartella `Output` sotto `$Base`. Per fermare il server usa `Ctrl+C` nel terminale che lo ha avviato.

## Dati e componenti esterni

Questa repository contiene soltanto il launcher. Il runtime, i modelli, i download, i file temporanei, i log e i risultati restano sul PC: **non caricarli nella repository**. La traduzione opzionale scarica un GGUF di Riva Translate da Hugging Face e ne controlla l'hash SHA-256.

NeMo Studio è un progetto indipendente, non un prodotto ufficiale NVIDIA. NeMo-Speech.cpp e i modelli sono distribuiti dai rispettivi titolari secondo le loro condizioni. Nessun binario o peso di modello è incluso qui.

## Stato delle verifiche

L'interfaccia JavaScript e i comandi FFmpeg sono stati controllati su file di prova. L'avvio completo e la chiusura con `Ctrl+C` devono essere verificati su Windows/CUDA: non sono stati eseguiti nell'ambiente di sviluppo di questa repository.
