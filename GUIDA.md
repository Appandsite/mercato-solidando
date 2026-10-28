# Mercato Agricolo Solidando: come funziona e come si gestisce

- **Sito** (`index.html`): pubblicato con GitHub Pages sul GitHub "Appandsite".
- **Dati**: database Supabase, nel progetto `mercato-solidando`. Si entra su supabase.com con "Continue with GitHub".

Le tabelle stanno in uno spazio chiamato `privato`, che il sito non può leggere direttamente. La pagina può solo chiamare la funzione `api`, che a ogni richiesta controlla il PIN. Per questo un'azienda vede soltanto i propri dati.

## Installazione (già fatta una volta)

1. supabase.com → New project `mercato-solidando`, region Europe.
2. **SQL Editor → New query**: incollare tutto `supabase.sql` e premere **Run**. Il risultato mostra il **PIN amministratore**.
3. **Project Settings → API Keys**: copiare il *Project URL* e la *publishable key* (oppure la *anon public*) dentro `index.html`, nelle righe `SUPABASE_URL` e `SUPABASE_KEY`.
4. Pubblicare `index.html` su GitHub Pages.

## Uso di tutti i giorni

- **Aziende**: entrano con il loro PIN, scrivono il fatturato della giornata e vedono subito il 3%. Possono correggere toccando una riga.
- **Amministratore**:
  - **Giornata**: chi ha inserito e chi manca, con i totali.
  - **Riepilogo**: le quote per azienda e per periodo, con lo scaricamento in Excel.
  - **Aziende e PIN**: nuove aziende, disattivazioni, nuovi PIN, percentuale e PIN amministratore.

## Cose da sapere

- **Pausa per inattività**: nella versione gratuita, se nessuno usa il sito per 7 giorni (per esempio ad agosto), Supabase mette il progetto in pausa e il sito dà "Connessione non riuscita". Per riattivarlo: supabase.com → progetto → **Restore project**. I dati non si perdono.
- **Copia dei dati**: dal Riepilogo → "Dall'inizio" → "Scarica tutte le giornate (Excel)".
- **Chiavi**: non date a nessuno la password del database, né la chiave *secret* o *service_role*. La chiave *publishable/anon* invece è pubblica per natura e da sola non dà accesso ai dati.
- **Aggiornare le funzioni del database**: si incolla di nuovo `supabase.sql` e si preme Run. I dati e i PIN restano com'erano.

## Prove in locale (per chi modifica il programma)

```bash
npm i @electric-sql/pglite
node prove/prova-database.mjs   # prove automatiche del database
node prove/anteprima.mjs        # sito di prova su http://localhost:8787, PIN di prova su /pin
```
