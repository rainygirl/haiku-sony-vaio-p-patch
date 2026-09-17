# Patch per la webcam del VAIO P

English: [`README.md`](README.md) / 한국어: [`README.ko.md`](README.ko.md) / Italiano: questo file.

Questa cartella contiene le modifiche per la webcam USB (UVC) prese da `../vaio-p-patches.diff`, separate per poterle consegnare a parte. Gli hunk sono copiati senza modifiche: `vaio-p-patches.diff` li contiene ancora, e la build dell'ISO per il VAIO P continua a usare quel file.

Contesto: la fotocamera integrata del Sony VAIO P è un dispositivo UVC USB 2.0 che trasmette in YUY2. L'add-on multimediale `usb_webcam` di Haiku viene distribuito con il supporto UVC escluso dalla compilazione. Anche includendolo, l'acquisizione fallisce a più livelli: l'add-on, lo USB Kit, `usb_raw` e il driver EHCI. Queste patch correggono ciascun livello.

## File

Applicarli in ordine numerico. Ogni diff è un normale `git diff` rispetto alla radice del sorgente.

| File | Ambito | Cosa fa |
|---|---|---|
| `01-usb_webcam-uvc.diff` | `src/add-ons/media/media-add-ons/usb_webcam/` (7 file) | Abilita UVC nel Jamfile e corregge il percorso UVC. La correzione principale: `AcceptVideoFrame()` inviava la posizione nella lista (a partire da 0) come indice di frame UVC (a partire da 1), quindi la fotocamera trasmetteva una risoluzione diversa da quella decodificata dall'host. Inoltre: decodifica YUY2 con controlli sui limiti; decodifica di `wMaxPacketSize` ad alta banda; scansione dei pacchetti a passo fisso; acquisizione a doppio buffer con la nuova API Queue/Wait; deframing ancorato ai cambi di FID; scarto dei frame vecchi; niente lampi neri sui frame persi; ordine di chiusura corretto in `StopTransfer()` (causava il panic "USB object did not become idle"); e un lock attorno a `fFrames.AddItem()` nel thread USB. |
| `02-usbkit-queued-isochronous.diff` | `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h` | Nuove ioctl `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS` e `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()`. Permettono di tenere in sospeso due trasferimenti isocroni contemporaneamente, così il ciclo di acquisizione non lascia intervalli in cui il dispositivo trasmette a vuoto. La vecchia ioctl bloccante resta invariata. **`01` non compila senza questa patch.** |
| `03-ehci-isochronous.diff` | `ehci.cpp`/`.h` | Quattro bug generici nel percorso isocrono EHCI: (1) TLENGTH che sconfina nei bit di stato; (2) un intervallo di 1 ms dovuto a un off-by-one in `fNextStartingFrame`; (3) solo l'ultimo iTD di un trasferimento multi-iTD veniva scollegato, un panic use-after-free; (4) una race nella scelta del frame iniziale. Non è una dipendenza di compilazione, ma senza di essa l'acquisizione USB 2.0 va in panic o perde dati. |
| `04-codycam.diff` | `src/apps/codycam/VideoConsumer.cpp`/`.h` | Visualizzazione in CodyCam: letterbox invece di stiramento, e rotazione su tutte e tre le bitmap quando i buffer appartengono al producer (corregge una race che causava tearing). Indipendente dalle altre. |
| `05-media-event-looper.diff` | `src/kits/media/MediaEventLooper.cpp` | `ControlLoop()` dereferenziava `TimeSource()` senza controlli. Quella chiamata restituisce NULL mentre il media server si arresta, quindi un nodo webcam in chiusura faceva crashare `media_addon_server`, trascinando con sé il mixer audio. Generica e indipendente dalle altre. |

Queste patch presuppongono anche una correzione di `BUSBInterface::SetAlternate()`: senza di essa, `EndpointAt()` continua a restituire gli endpoint dell'alternate 0 e non arriva alcun dato isocrono. Non è inclusa qui perché RenkuOS e Haiku master la contengono già.

## Base e verifica

- I diff sono stati estratti dal set di patch per il VAIO P, la cui base è [RenkuOS](https://github.com/RenkuOS/Source) `f04d7eb54a` (`hrev60072+55`). RenkuOS è un fork di Haiku.
- `git apply --check` passa per ciascun file singolarmente, e `git apply` riesce per tutti e cinque insieme, su:
  - RenkuOS `f04d7eb54a`;
  - RenkuOS `68a8443336` (la nightly del 2026-09-17);
  - Haiku master `d8655a1bdc` (2026-09-17).
- Applicando solo questi cinque diff a RenkuOS `68a8443336` (senza le altre patch per il VAIO P), tutto ciò che toccano compila e linka per `x86_gcc2h` a 32 bit: `usb_webcam.media_addon`, `CodyCam`, `libdevice.so`, `libmedia.so`, `usb_raw` ed `ehci`.
- Sono state sviluppate ed eseguite sul VAIO P come parte del set completo di patch. Non sono state provate su altro hardware.

```sh
cd /path/to/haiku-or-renku-source
git apply /path/to/webcam/*.diff
```

## Note per i test

- **Sostituire un add-on multimediale senza reinstallare.** Una copia in `non-packaged/add-ons/media` viene caricata *in aggiunta* a quella del pacchetto. Entrambe reclamano la fotocamera e nessuna funziona. Nascondere prima il file del pacchetto con `/boot/system/settings/packages`:

  ```
  Package haiku {
  	BlockedEntries {
  		add-ons/media/usb_webcam.media_addon
  	}
  }
  ```

  Poi copiare l'add-on compilato in `/boot/system/non-packaged/add-ons/media/` e riavviare. Rimuovere la blocklist dopo aver installato un pacchetto con la correzione, altrimenti nasconde anche l'add-on corretto.
- **Lato kernel e kit.** `02` modifica insieme `usb_raw` (kernel) e `libdevice.so`, e i nuovi numeri di ioctl devono coincidere. Distribuirli entrambi, oppure nessuno dei due.
- **Un "nessuna fotocamera" che non lo è.** Se non è assegnato un ingresso video predefinito, `BMediaRoster::GetVideoInput()` restituisce `B_NAME_NOT_FOUND` anche se la fotocamera è riconosciuta e produce frame. Controllare prima nel syslog le righe `usb_webcam deframer`.
- **Non caricare un altro add-on UVC accanto a questo.** Ad esempio [haiku-uvc-webcam](https://github.com/atomozero/haiku-uvc-webcam) e questo `usb_webcam` reclamano lo stesso dispositivo.

## Avviso

Queste patch sono state realizzate da una persona che ha lavorato con Claude, e sono state verificate sul VAIO P reale.

**Il progetto Haiku non accetta contributi realizzati con l'assistenza dell'IA, e nulla di tutto ciò è stato o deve essere inviato upstream.** È pubblicato con gli stessi termini MIT del codice che modifica (vedi `../LICENSE`). Se ne riutilizzate una parte, vi preghiamo di riportare anche questo avviso.
