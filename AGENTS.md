# NeMo Studio — note di progetto

- Il punto di ingresso è `Avvia-NeMo-Studio.ps1`, un unico script PowerShell 7.2+ per Windows/CUDA con pagina HTML, CSS e JavaScript incorporata.
- Prima di modificarlo controlla l'intero script, i processi figli, i percorsi dei file e il blocco `finally` che chiude NeMo e la traduzione. Conserva la gestione di `Ctrl+C` nel ciclo UI con `TcpListener.Pending()`.
- Il percorso predefinito è `D:\Modelli\NeMo-Speech` in `$Base`. Il runtime, i modelli, la cache, i log e i risultati non devono essere committati.
- Il launcher scarica l'installer ufficiale NVIDIA ed esegue NeMo-Speech.cpp. Il modello GGUF di traduzione ha un hash SHA-256 configurato nello script; aggiorna URL e hash insieme solo dopo verifica.
- Dopo modifiche controlla sintassi PowerShell 7, JavaScript incorporato e comandi FFmpeg. Prova avvio, Stop e `Ctrl+C` su Windows/CUDA quando disponibile; segnala esplicitamente le prove non eseguite.
- Nel README mantieni la distinzione fra il launcher indipendente e i componenti NVIDIA, con i relativi link e condizioni di distribuzione. Non inserire modelli, binari o contenuti di `Output`.
- Mantieni `assets/nemo-studio-hero.png` referenziato dal README con un percorso relativo. Il progetto è distribuito con Apache 2.0: conserva `LICENSE` e `NOTICE` e la citazione a SiNaPsEr0x quando aggiorni o redistribuisci contenuti originali.

- La sola Action iOS (`.github/workflows/ios-port-check.yml`) usa esclusivamente `workflow_dispatch`: nessun `push`, `pull_request` o altro trigger automatico. Completa e controlla prima tutte le modifiche; poi avvia manualmente la build da GitHub Actions quando appropriato. La build riuscita aggiorna l'unica Release `ios-current` con un solo asset IPA unsigned.
- Per iOS esamina anche `iOS/README.md` e il codice Swift interessato, risolvi i warning alla fonte, conserva import da File e Foto. Verifica con campioni reali H.264 e H.265/HEVC, audio AAC e tracce sottotitoli selezionabili nell'MKV; prova le funzioni su iPhone prima di descriverle come funzionanti su dispositivo.
