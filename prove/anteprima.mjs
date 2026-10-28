// Anteprima locale: la pagina vera + supabase.sql su un Postgres in memoria (PGlite).
// Uso: node prove/anteprima.mjs  →  http://localhost:8787   (i PIN di prova sono su /pin)
import http from 'http';
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
import { fileURLToPath, pathToFileURL } from 'url';

const radice = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const base = process.env.PGLITE ? path.join(process.env.PGLITE, 'x.js') : import.meta.url;
const { PGlite } = await import(pathToFileURL(createRequire(base).resolve('@electric-sql/pglite')).href);

const db = new PGlite();
await db.exec('create role anon nologin; create role authenticated nologin;');
await db.exec(fs.readFileSync(path.join(radice, 'supabase.sql'), 'utf8'));

http.createServer(async (req, res) => {
  const url = req.url.split('?')[0];
  if (req.method === 'POST' && url === '/rest/v1/rpc/api') {
    let corpo = '';
    for await (const pezzo of req) corpo += pezzo;
    await db.exec('set role anon');
    const r = (await db.query('select public.api($1::jsonb) as r', [JSON.stringify(JSON.parse(corpo).req)])).rows[0].r;
    await db.exec('reset role');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(r));
  }
  if (url === '/pin') {
    const r = await db.query(`select nome, pin from privato.aziende union all
      select 'AMMINISTRATORE', valore from privato.impostazioni where chiave = 'pin_admin'`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(Object.fromEntries(r.rows.map(x => [x.nome, x.pin]))));
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(fs.readFileSync(path.join(radice, 'index.html')));
}).listen(process.env.PORT || 8787, () => console.log('Anteprima pronta'));
