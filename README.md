# NeMo Studio

![NeMo Studio: dalle onde sonore alle voci, ai sottotitoli e al doppiaggio](assets/nemo-studio-hero.png)

Interfaccia locale per trascrivere audio e video, riconoscere le voci, creare sottotitoli e generare un doppiaggio con [NeMo-Speech.cpp](https://github.com/NVIDIA/NeMo-Speech.cpp).

## Perché nasce

NeMo Studio nasce per colmare un vuoto pratico: ottenere **trascrizione, riconoscimento dei parlanti, sottotitoli, traduzione e doppiaggio in un unico strumento locale**, senza dover passare per software a pagamento o abbonamenti. L'idea è rendere accessibile un flusso completo, dalla registrazione al video pronto, usando componenti aperti e lasciando i propri file sul PC.

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

La repository contiene il launcher Windows e [NeMo Studio per iOS](iOS/README.md), con l'[IPA unsigned nella Release iOS](https://github.com/SiNaPsEr0x/nemo-speech-studio/releases/tag/ios-current), non i pesi. Il runtime, i modelli, i download, i file temporanei, i log e i risultati restano sul dispositivo: **non caricarli nella repository**. La traduzione opzionale scarica un GGUF di Riva Translate da Hugging Face e ne controlla l'hash SHA-256.

NeMo Studio è un progetto indipendente, non un prodotto ufficiale NVIDIA. NeMo-Speech.cpp e i modelli sono distribuiti dai rispettivi titolari secondo le loro condizioni. Nessun binario o peso di modello è incluso qui.

## Licenza e attribuzione

Il contenuto originale di questa repository è distribuito con [Apache License 2.0](LICENSE). Puoi usarlo, modificarlo e ridistribuirlo, anche in un progetto commerciale. **Se lo ridistribuisci o pubblichi una versione derivata**, conserva la licenza, gli avvisi di copyright e l'attribuzione contenuta in [NOTICE](NOTICE): **NeMo Studio di SiNaPsEr0x**, con link a questa repository. Segnala le modifiche ai file che hai cambiato.

Per il solo uso privato non è richiesta una menzione pubblica. Se racconti o mostri un progetto che usa NeMo Studio, una citazione a **SiNaPsEr0x** e un link alla repository sono apprezzati.

La licenza di questa repository non sostituisce le licenze dei componenti e dei modelli scaricati separatamente.

## Stato delle verifiche

L'interfaccia JavaScript e i comandi FFmpeg sono stati controllati su file di prova. L'avvio completo e la chiusura con `Ctrl+C` devono essere verificati su Windows/CUDA: non sono stati eseguiti nell'ambiente di sviluppo di questa repository.
