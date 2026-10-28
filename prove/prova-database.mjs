// Prova automatica di supabase.sql su un Postgres in memoria (PGlite).
// Uso: npm i @electric-sql/pglite  poi  node prove/prova-database.mjs
//      (oppure PGLITE=<cartella con node_modules> node prove/prova-database.mjs)
import fs from 'fs';
import path from 'path';
import assert from 'assert';
import { createRequire } from 'module';
import { fileURLToPath, pathToFileURL } from 'url';

const qui = path.dirname(fileURLToPath(import.meta.url));
const base = process.env.PGLITE ? path.join(process.env.PGLITE, 'x.js') : import.meta.url;
const { PGlite } = await import(pathToFileURL(createRequire(base).resolve('@electric-sql/pglite')).href);

const db = new PGlite();
await db.exec(`create role anon nologin; create role authenticated nologin;`);
const sql = fs.readFileSync(path.join(qui, '..', 'supabase.sql'), 'utf8');
await db.exec(sql);
await db.exec(sql); // rieseguire non deve rompere nulla né duplicare

const api = async req => (await db.query('select public.api($1::jsonb) as r', [JSON.stringify(req)])).rows[0].r;
const uno = async (q, p) => (await db.query(q, p)).rows[0];
const pinDi = async nome => (await uno('select pin from privato.aziende where nome = $1', [nome])).pin;
const pinAdmin = (await uno(`select valore from privato.impostazioni where chiave = 'pin_admin'`)).valore;

let n = 0;
async function prova(nome, fn) { await fn(); n++; console.log('ok  ' + nome); }

await prova('19 aziende, PIN unici a 6 cifre, admin a 8, script rieseguibile', async () => {
  const r = (await db.query('select * from privato.aziende order by id')).rows;
  assert.strictEqual(r.length, 19);
  assert.strictEqual(new Set(r.map(x => x.pin)).size, 19);
  r.forEach(x => assert.match(x.pin, /^[1-9]\d{5}$/));
  assert.strictEqual(r.filter(x => x.mar).length, 8);
  assert.strictEqual(r.filter(x => x.gio).length, 19);
  assert.match(pinAdmin, /^[1-9]\d{7}$/);
});

await prova('il sito (ruolo anon) non può leggere le tabelle, solo chiamare api()', async () => {
  await db.exec('set role anon');
  await assert.rejects(db.query('select * from privato.aziende'), /permission denied/);
  await assert.rejects(db.query('select * from privato.fatturati'), /permission denied/);
  await assert.rejects(db.query(`select privato.dati_admin()`), /permission denied/);
  const r = (await db.query(`select public.api('{"azione":"login","pin":"000000"}') as r`)).rows[0].r;
  assert.strictEqual(r.ok, false);
  await db.exec('reset role');
});

await db.exec('delete from privato.pin_errati');
const conte = await api({ azione: 'login', pin: await pinDi('Conte') });
const prada = await api({ azione: 'login', pin: await pinDi('Prada') });
const admin = await api({ azione: 'login', pin: pinAdmin });

await prova('accesso azienda e amministratore', async () => {
  assert.strictEqual(conte.ok, true, conte.errore);
  assert.strictEqual(conte.ruolo, 'azienda');
  assert.strictEqual(conte.azienda.nome, 'Conte');
  assert.ok(!('pin' in conte.azienda));
  assert.strictEqual(admin.ruolo, 'admin');
  assert.strictEqual(admin.aziende.length, 19);
  assert.strictEqual(admin.pinAdmin, pinAdmin);
  assert.match(admin.oggi, /^\d{4}-\d{2}-\d{2}$/);
});

await prova('salvataggio e calcolo del 3%', async () => {
  const r = await api({ azione: 'salva', token: conte.token, data: '2026-10-27', mercato: 'mar', importo: 1250.5 });
  assert.strictEqual(r.ok, true, r.errore);
  assert.strictEqual(r.fatturati.length, 1);
  assert.strictEqual(r.fatturati[0].quota, 37.52);
  assert.strictEqual(r.fatturati[0].importo, 1250.5);
  assert.match(r.fatturati[0].inserito, /^\d\d\/\d\d\/\d{4} \d\d:\d\d$/);
  await api({ azione: 'salva', token: conte.token, data: '2026-10-22', mercato: 'gio', importo: '980,40' });
  const p = await api({ azione: 'salva', token: prada.token, data: '2026-10-22', mercato: 'gio', importo: 2000 });
  assert.strictEqual(p.fatturati[0].quota, 60);
});

await prova('correggere la stessa giornata sostituisce, non duplica', async () => {
  const r = await api({ azione: 'salva', token: conte.token, data: '2026-10-27', mercato: 'mar', importo: 1300 });
  const del27 = r.fatturati.filter(f => f.data === '2026-10-27');
  assert.strictEqual(del27.length, 1);
  assert.strictEqual(del27[0].quota, 39);
  assert.ok(del27[0].modificato);
});

await prova('un\'azienda vede solo i propri dati e non può fare operazioni da amministratore', async () => {
  const r = await api({ azione: 'dati', token: conte.token });
  assert.ok(r.fatturati.every(f => f.aziendaId === conte.azienda.id));
  assert.strictEqual(r.fatturati.length, 2);
  assert.ok(!('aziende' in r) && !('pinAdmin' in r));
  for (const azione of ['tutto', 'elimina', 'salvaAzienda', 'nuovoPin', 'impostazioni', 'login2', null]) {
    assert.strictEqual((await api({ azione, token: conte.token, id: 'A01', nome: 'x' })).ok, false, String(azione));
  }
});

await prova('un\'azienda non può scrivere per un\'altra', async () => {
  await api({ azione: 'salva', token: conte.token, aziendaId: prada.azienda.id, data: '2026-10-15', mercato: 'gio', importo: 1 });
  const del15 = (await api({ azione: 'tutto', token: admin.token })).fatturati.filter(f => f.data === '2026-10-15');
  assert.deepStrictEqual(del15.map(f => f.aziendaId), [conte.azienda.id]);
});

await prova('controlli: mercato non suo, data futura, importi e date assurdi', async () => {
  const err = async req => (await api(Object.assign({ token: conte.token }, req))).errore;
  assert.match((await api({ azione: 'salva', token: prada.token, data: '2026-10-27', mercato: 'mar', importo: 5 })).errore, /non partecipa/);
  assert.match(await err({ azione: 'salva', data: '2099-01-01', mercato: 'mar', importo: 5 }), /futura/);
  assert.match(await err({ azione: 'salva', data: '2026-10-20', mercato: 'mar', importo: -5 }), /Importo/);
  assert.match(await err({ azione: 'salva', data: '2026-10-20', mercato: 'mar', importo: 'abc' }), /Importo/);
  assert.match(await err({ azione: 'salva', data: '2026-10-20', mercato: 'mar', importo: 'NaN' }), /Importo/);
  assert.match(await err({ azione: 'salva', data: '2026-10-20', mercato: 'mar', importo: 'Infinity' }), /Importo/);
  assert.match(await err({ azione: 'salva', data: '27/10/2026', mercato: 'mar', importo: 5 }), /Data/);
  assert.match(await err({ azione: 'salva', data: '2026-02-31', mercato: 'mar', importo: 5 }), /Data/);
  assert.match(await err({ azione: 'salva', data: '2026-10-20', mercato: 'xxx', importo: 5 }), /Mercato/);
});

await prova('token inventato o mancante = sessione scaduta', async () => {
  assert.strictEqual((await api({ azione: 'dati', token: 'inventato' })).scaduta, true);
  assert.strictEqual((await api({ azione: 'tutto' })).scaduta, true);
  assert.strictEqual((await api({ azione: 'tutto', token: '00000000-0000-0000-0000-000000000000' })).scaduta, true);
});

await prova('amministratore: vede tutto, inserisce al posto di un\'azienda, elimina', async () => {
  let r = await api({ azione: 'tutto', token: admin.token });
  assert.strictEqual(r.fatturati.length, 4);
  r = await api({ azione: 'salva', token: admin.token, aziendaId: 'A12', data: '2026-10-22', mercato: 'gio', importo: 100 });
  const riga = r.fatturati.find(f => f.aziendaId === 'A12');
  assert.strictEqual(riga.da, 'amministratore');
  r = await api({ azione: 'elimina', token: admin.token, id: riga.id });
  assert.strictEqual(r.fatturati.length, 4);
  assert.match((await api({ azione: 'elimina', token: admin.token, id: riga.id })).errore, /non trovata/);
});

await prova('amministratore: nuova azienda, nome doppio, nuovo PIN', async () => {
  let r = await api({ azione: 'salvaAzienda', token: admin.token, nome: 'Orto Nuovo', mar: true, gio: false, attiva: true });
  const nuova = r.aziende.find(a => a.nome === 'Orto Nuovo');
  assert.strictEqual(nuova.id, 'A20');
  assert.match(nuova.pin, /^\d{6}$/);
  assert.match((await api({ azione: 'salvaAzienda', token: admin.token, nome: 'conte', mar: true, gio: true, attiva: true })).errore, /Esiste già un'azienda chiamata "Conte"/);
  const vecchio = await pinDi('Prada');
  await api({ azione: 'nuovoPin', token: admin.token, id: prada.azienda.id });
  assert.notStrictEqual(await pinDi('Prada'), vecchio);
  assert.strictEqual((await api({ azione: 'login', pin: vecchio })).ok, false);
  assert.strictEqual((await api({ azione: 'login', pin: await pinDi('Prada') })).ok, true);
});

await prova('azienda disattivata perde subito l\'accesso', async () => {
  await api({ azione: 'salvaAzienda', token: admin.token, id: conte.azienda.id, nome: 'Conte', mar: true, gio: true, attiva: false });
  assert.strictEqual((await api({ azione: 'dati', token: conte.token })).scaduta, true);
  assert.strictEqual((await api({ azione: 'login', pin: await pinDi('Conte') })).ok, false);
  await api({ azione: 'salvaAzienda', token: admin.token, id: conte.azienda.id, nome: 'Conte', mar: true, gio: true, attiva: true });
});

await prova('impostazioni: la nuova percentuale vale solo per i nuovi inserimenti', async () => {
  await api({ azione: 'impostazioni', token: admin.token, percentuale: '2,5' });
  const r = await api({ azione: 'salva', token: admin.token, aziendaId: 'A01', data: '2026-10-22', mercato: 'gio', importo: 1000 });
  assert.strictEqual(r.percentuale, 2.5);
  assert.strictEqual(r.fatturati.find(f => f.aziendaId === 'A01').quota, 25);
  assert.strictEqual(r.fatturati.find(f => f.aziendaId === prada.azienda.id).quota, 60);
  assert.match((await api({ azione: 'impostazioni', token: admin.token, pinAdmin: '123' })).errore, /8 cifre/);
  assert.match((await api({ azione: 'impostazioni', token: admin.token, percentuale: 'abc' })).errore, /Percentuale/);
  assert.match((await api({ azione: 'impostazioni', token: admin.token, pinAdmin: await pinDi('Lupo') + '00' })).ok ? 'ok' : 'x', /ok/);
  await api({ azione: 'impostazioni', token: admin.token, percentuale: '3', pinAdmin: pinAdmin });
});

await prova('troppi PIN errati bloccano gli accessi per un quarto d\'ora', async () => {
  for (let i = 0; i < 30; i++) await db.exec('insert into privato.pin_errati default values');
  const r = await api({ azione: 'login', pin: pinAdmin });
  assert.strictEqual(r.ok, false);
  assert.match(r.errore, /Troppi/);
  await db.exec(`update privato.pin_errati set quando = now() - interval '16 minutes'`);
  assert.strictEqual((await api({ azione: 'login', pin: pinAdmin })).ok, true);
});

console.log(`\nTutte le ${n} prove superate.`);
