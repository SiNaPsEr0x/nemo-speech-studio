# NeMo Studio iOS — porting in corso

Questo è un **checkpoint tecnico, non una versione completa**. L'app SwiftUI importa file audio/video, offre i preset della UI desktop, una cartella modelli persistente e un log di sessione esportabile. L'elaborazione è intenzionalmente disabilitata: NVIDIA NeMo-Speech.cpp non fornisce oggi un runtime iOS integrato e validato per Nemotron 3.5, Sortformer, Riva Translate, MagpieTTS/NanoCodec. Non vengono simulati risultati né vengono sostituiti i modelli senza indicarlo.

Il log `Application Support/session.log` viene troncato all'avvio del processo. Il flag **Debug** si trova in Impostazioni iOS → NeMo Studio e attiva le righe dettagliate; avvio ed errori essenziali restano registrati. Un arresto improvviso può lasciare nel log solo le ultime righe riuscite: iOS non garantisce che un crash o una terminazione per memoria venga scritto dal processo stesso. I file importati restano sul telefono.

Per compilare su macOS: installare Xcode e [XcodeGen](https://github.com/yonaskolb/XcodeGen), poi in questa cartella eseguire `xcodegen generate` e `xcodebuild -project NeMoStudio.xcodeproj -scheme NeMoStudio -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build`. La firma e l'installazione su dispositivo sono separate.

L'eventuale IPA per ESign e la Release unica verranno abilitate **solo dopo** una build iOS riuscita e test del motore reale sul dispositivo. Il backend Windows/CUDA esistente non viene toccato.
