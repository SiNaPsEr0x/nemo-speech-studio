# NeMo Studio — note di progetto

- Il punto di ingresso è `Avvia-NeMo-Studio.ps1`, un unico script PowerShell 7.2+ per Windows/CUDA con pagina HTML, CSS e JavaScript incorporata.
- Prima di modificarlo controlla l'intero script, i processi figli, i percorsi dei file e il blocco `finally` che chiude NeMo e la traduzione. Conserva la gestione di `Ctrl+C` nel ciclo UI con `TcpListener.Pending()`.
- Il percorso predefinito è `D:\Modelli\NeMo-Speech` in `$Base`. Il runtime, i modelli, la cache, i log e i risultati non devono essere committati.
- Il launcher scarica l'installer ufficiale NVIDIA ed esegue NeMo-Speech.cpp. Il modello GGUF di traduzione ha un hash SHA-256 configurato nello script; aggiorna URL e hash insieme solo dopo verifica.
- Dopo modifiche controlla sintassi PowerShell 7, JavaScript incorporato e comandi FFmpeg. Prova avvio, Stop e `Ctrl+C` su Windows/CUDA quando disponibile; segnala esplicitamente le prove non eseguite.
- Nel README mantieni la distinzione fra il launcher indipendente e i componenti NVIDIA, con i relativi link e condizioni di distribuzione. Non inserire modelli, binari o contenuti di `Output`.
