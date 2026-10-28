-- Mercato Agricolo Solidando — database su Supabase.
-- Incollare TUTTO in Supabase → SQL Editor → Run.
-- Si può rieseguire senza perdere dati (serve per aggiornare le funzioni).
--
-- I dati stanno nello schema "privato", che il sito non può leggere direttamente.
-- La pagina può chiamare solo la funzione public.api(), che controlla il PIN a ogni richiesta.

create schema if not exists privato;
revoke all on schema privato from public;

create table if not exists privato.aziende (
  id     text primary key,
  nome   text not null unique,
  pin    text not null unique,
  mar    boolean not null default false,   -- martedì, via Sacco
  gio    boolean not null default false,   -- giovedì, Largo Augusto (Verziere)
  attiva boolean not null default true
);

create table if not exists privato.fatturati (
  id          uuid primary key default gen_random_uuid(),
  data        date not null,
  mercato     text not null check (mercato in ('mar', 'gio')),
  azienda_id  text not null references privato.aziende(id),
  importo     numeric(12,2) not null check (importo >= 0),
  quota       numeric(12,2) not null,
  percentuale numeric not null,
  inserito    timestamptz not null default now(),
  modificato  timestamptz,
  da          text not null,
  unique (azienda_id, data, mercato)
);

create table if not exists privato.impostazioni (chiave text primary key, valore text not null);
create table if not exists privato.sessioni (
  token uuid primary key default gen_random_uuid(),
  ruolo text not null,
  azienda_id text,
  scade timestamptz not null
);
create table if not exists privato.pin_errati (quando timestamptz not null default now());

/* ------------------------------------------------------------------ utilità */

create or replace function privato.oggi() returns date language sql stable as $$
  select (now() at time zone 'Europe/Rome')::date
$$;

create or replace function privato.ora(t timestamptz) returns text language sql stable as $$
  select coalesce(to_char(t at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI'), '')
$$;

create or replace function privato.percentuale() returns numeric language sql stable as $$
  select coalesce((select valore::numeric from privato.impostazioni where chiave = 'percentuale'), 3)
$$;

create or replace function privato.mercati() returns jsonb language sql immutable as $$
  select jsonb_build_object('mar', 'Martedì · Via Sacco', 'gio', 'Giovedì · Largo Augusto (Verziere)')
$$;

create or replace function privato.nuovo_pin(cifre int) returns text language plpgsql as $$
declare
  p text;
begin
  loop
    p := (1 + floor(random() * 9))::int::text;   -- niente zero iniziale
    while length(p) < cifre loop
      p := p || floor(random() * 10)::int::text;
    end loop;
    exit when not exists (select 1 from privato.aziende where pin = p)
      and not exists (select 1 from privato.impostazioni where chiave = 'pin_admin' and valore = p);
  end loop;
  return p;
end $$;

/* ------------------------------------------------------------------ dati iniziali (solo la prima volta) */

do $$
declare
  r record;
begin
  if not exists (select 1 from privato.aziende) then
    for r in
      select * from (values
        (1, 'Agrestum', true), (2, 'Zappello', true), (3, 'Comunità del cibo', true), (4, 'Lupo', true),
        (5, 'Strie', true), (6, 'Simonelli', true), (7, 'Bufale', true), (8, 'Conte', true),
        (9, 'Prada', false), (10, 'Buoono', false), (11, 'Faggioli', false), (12, 'Longoni', false),
        (13, 'Al Dos', false), (14, 'Schiaffonati', false), (15, 'Miele', false), (16, 'Alpes Agia', false),
        (17, 'Anieda', false), (18, 'Verdebionatura', false), (19, 'Cascina Fraschina', false)
      ) v(n, nome, mar) order by n
    loop
      insert into privato.aziende (id, nome, pin, mar, gio, attiva)
      values ('A' || lpad(r.n::text, 2, '0'), r.nome, privato.nuovo_pin(6), r.mar, true, true);
    end loop;
  end if;
  insert into privato.impostazioni values ('percentuale', '3') on conflict do nothing;
  if not exists (select 1 from privato.impostazioni where chiave = 'pin_admin') then
    insert into privato.impostazioni values ('pin_admin', privato.nuovo_pin(8));
  end if;
end $$;

/* ------------------------------------------------------------------ dati restituiti alla pagina */

create or replace function privato.json_fatturati(filtro_azienda text) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'data', to_char(f.data, 'YYYY-MM-DD'), 'mercato', f.mercato,
      'aziendaId', f.azienda_id, 'azienda', a.nome,
      'importo', f.importo, 'quota', f.quota, 'percentuale', f.percentuale,
      'inserito', privato.ora(f.inserito), 'modificato', privato.ora(f.modificato), 'da', f.da
    ) order by f.data, f.mercato, a.nome), '[]'::jsonb)
  from privato.fatturati f
  join privato.aziende a on a.id = f.azienda_id
  where filtro_azienda is null or f.azienda_id = filtro_azienda
$$;

create or replace function privato.dati_azienda(az_id text) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'azienda', jsonb_build_object('id', a.id, 'nome', a.nome, 'mar', a.mar, 'gio', a.gio),
    'fatturati', privato.json_fatturati(a.id),
    'percentuale', privato.percentuale(),
    'mercati', privato.mercati(),
    'oggi', to_char(privato.oggi(), 'YYYY-MM-DD'))
  from privato.aziende a where a.id = az_id
$$;

create or replace function privato.dati_admin() returns jsonb language sql stable as $$
  select jsonb_build_object(
    'aziende', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', id, 'nome', nome, 'pin', pin, 'mar', mar, 'gio', gio, 'attiva', attiva) order by id), '[]'::jsonb)
      from privato.aziende),
    'fatturati', privato.json_fatturati(null),
    'percentuale', privato.percentuale(),
    'pinAdmin', (select valore from privato.impostazioni where chiave = 'pin_admin'),
    'mercati', privato.mercati(),
    'oggi', to_char(privato.oggi(), 'YYYY-MM-DD'))
$$;

/* ------------------------------------------------------------------ operazioni */

create or replace function privato.login(p_pin text) returns jsonb language plpgsql as $$
declare
  v_pin text := regexp_replace(coalesce(p_pin, ''), '\D', '', 'g');
  v_ruolo text;
  v_azienda privato.aziende;
  v_token uuid;
begin
  delete from privato.pin_errati where quando < now() - interval '15 minutes';
  delete from privato.sessioni where scade < now();
  if (select count(*) from privato.pin_errati) >= 30 then
    return jsonb_build_object('ok', false, 'errore', 'Troppi PIN errati. Riprova tra un quarto d''ora.');
  end if;

  if length(v_pin) >= 6 then
    if v_pin = (select valore from privato.impostazioni where chiave = 'pin_admin') then
      v_ruolo := 'admin';
    else
      select * into v_azienda from privato.aziende a where a.pin = v_pin and a.attiva;
      if found then v_ruolo := 'azienda'; end if;
    end if;
  end if;

  if v_ruolo is null then
    insert into privato.pin_errati default values;
    perform pg_sleep(0.7);
    return jsonb_build_object('ok', false, 'errore', 'PIN non valido.');
  end if;

  insert into privato.sessioni (ruolo, azienda_id, scade)
  values (v_ruolo, v_azienda.id, now() + interval '8 hours')
  returning token into v_token;

  return (case when v_ruolo = 'admin' then privato.dati_admin() else privato.dati_azienda(v_azienda.id) end)
    || jsonb_build_object('ok', true, 'token', v_token, 'ruolo', v_ruolo);
end $$;

create or replace function privato.salva(az_id text, p_data text, p_mercato text, p_importo text, chi text)
returns void language plpgsql as $$
declare
  v_az privato.aziende;
  v_data date;
  v_imp numeric;
  v_perc numeric := privato.percentuale();
begin
  select * into v_az from privato.aziende where id = az_id;
  if not found then raise exception 'Azienda non trovata.'; end if;

  if coalesce(p_data, '') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Data non valida.'; end if;
  begin
    v_data := p_data::date;
  exception when others then
    raise exception 'Data non valida.';
  end;
  if v_data > privato.oggi() then raise exception 'Non si può inserire il fatturato di una data futura.'; end if;

  if p_mercato is null or p_mercato not in ('mar', 'gio') then raise exception 'Mercato non valido.'; end if;
  if (p_mercato = 'mar' and not v_az.mar) or (p_mercato = 'gio' and not v_az.gio) then
    raise exception '% non partecipa al mercato di %.', v_az.nome, privato.mercati() ->> p_mercato;
  end if;

  begin
    v_imp := replace(btrim(p_importo), ',', '.')::numeric;
  exception when others then
    raise exception 'Importo non valido.';
  end;
  if v_imp is null or v_imp = 'NaN' or v_imp < 0 or v_imp > 1000000 then raise exception 'Importo non valido.'; end if;
  v_imp := round(v_imp, 2);

  insert into privato.fatturati (data, mercato, azienda_id, importo, quota, percentuale, da)
  values (v_data, p_mercato, v_az.id, v_imp, round(v_imp * v_perc / 100, 2), v_perc, chi)
  on conflict (azienda_id, data, mercato) do update
    set importo = excluded.importo, quota = excluded.quota, percentuale = excluded.percentuale,
        modificato = now(), da = excluded.da;
end $$;

create or replace function privato.elimina(p_id text) returns void language plpgsql as $$
begin
  delete from privato.fatturati where id::text = p_id;
  if not found then raise exception 'Riga non trovata: forse è già stata eliminata.'; end if;
end $$;

create or replace function privato.salva_azienda(req jsonb) returns void language plpgsql as $$
declare
  v_id text := nullif(req ->> 'id', '');
  v_nome text := btrim(coalesce(req ->> 'nome', ''));
  v_mar boolean := coalesce((req ->> 'mar')::boolean, false);
  v_gio boolean := coalesce((req ->> 'gio')::boolean, false);
  v_attiva boolean := coalesce((req ->> 'attiva')::boolean, false);
  v_doppione text;
  v_n int;
begin
  if v_nome = '' then raise exception 'Scrivi il nome dell''azienda.'; end if;
  select nome into v_doppione from privato.aziende where lower(nome) = lower(v_nome) and id is distinct from v_id;
  if found then raise exception 'Esiste già un''azienda chiamata "%".', v_doppione; end if;

  if v_id is not null then
    update privato.aziende set nome = v_nome, mar = v_mar, gio = v_gio, attiva = v_attiva where id = v_id;
    if not found then raise exception 'Azienda non trovata.'; end if;
  else
    select coalesce(max(nullif(regexp_replace(id, '\D', '', 'g'), '')::int), 0) + 1 into v_n from privato.aziende;
    insert into privato.aziende (id, nome, pin, mar, gio, attiva)
    values ('A' || lpad(v_n::text, 2, '0'), v_nome, privato.nuovo_pin(6), v_mar, v_gio, v_attiva);
  end if;
end $$;

create or replace function privato.rigenera_pin(p_id text) returns void language plpgsql as $$
begin
  update privato.aziende set pin = privato.nuovo_pin(6) where id = p_id;
  if not found then raise exception 'Azienda non trovata.'; end if;
end $$;

create or replace function privato.salva_impostazioni(req jsonb) returns void language plpgsql as $$
declare
  v_pin text := nullif(btrim(coalesce(req ->> 'pinAdmin', '')), '');
  v_testo text := nullif(btrim(coalesce(req ->> 'percentuale', '')), '');
  v_perc numeric;
begin
  if v_pin is not null then
    if v_pin !~ '^\d{8,}$' then raise exception 'Il PIN amministratore deve avere almeno 8 cifre.'; end if;
    if exists (select 1 from privato.aziende where pin = v_pin) then
      raise exception 'Questo PIN è già usato da un''azienda: scegline un altro.';
    end if;
    update privato.impostazioni set valore = v_pin where chiave = 'pin_admin';
  end if;
  if v_testo is not null then
    begin
      v_perc := replace(v_testo, ',', '.')::numeric;
    exception when others then
      raise exception 'Percentuale non valida.';
    end;
    if v_perc = 'NaN' or v_perc < 0 or v_perc > 100 then raise exception 'Percentuale non valida.'; end if;
    update privato.impostazioni set valore = v_perc::text where chiave = 'percentuale';
  end if;
end $$;

/* ------------------------------------------------------------------ unico punto d'ingresso per la pagina */

create or replace function public.api(req jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_azione text := req ->> 'azione';
  v_token uuid;
  v_sessione privato.sessioni;
  v_azienda privato.aziende;
  v_scaduta constant jsonb := jsonb_build_object('ok', false, 'scaduta', true, 'errore', 'Sessione scaduta: rientra con il tuo PIN.');
  v_vietato constant jsonb := jsonb_build_object('ok', false, 'errore', 'Operazione non consentita.');
begin
  if v_azione = 'login' then return privato.login(req ->> 'pin'); end if;

  begin
    v_token := (req ->> 'token')::uuid;
  exception when others then
    v_token := null;
  end;
  select * into v_sessione from privato.sessioni where token = v_token and scade > now();
  if not found then return v_scaduta; end if;

  if v_sessione.ruolo = 'azienda' then
    -- un'azienda disattivata perde subito l'accesso; scrive sempre e solo sul proprio conto
    select * into v_azienda from privato.aziende where id = v_sessione.azienda_id and attiva;
    if not found then return v_scaduta; end if;
    if v_azione = 'salva' then
      perform privato.salva(v_azienda.id, req ->> 'data', req ->> 'mercato', req ->> 'importo', 'azienda');
    elsif v_azione is distinct from 'dati' then
      return v_vietato;
    end if;
    return privato.dati_azienda(v_azienda.id) || '{"ok": true}'::jsonb;
  end if;

  if v_sessione.ruolo <> 'admin' then return v_vietato; end if;
  case v_azione
    when 'tutto' then null;
    when 'salva' then
      perform privato.salva(req ->> 'aziendaId', req ->> 'data', req ->> 'mercato', req ->> 'importo', 'amministratore');
    when 'elimina' then perform privato.elimina(req ->> 'id');
    when 'salvaAzienda' then perform privato.salva_azienda(req);
    when 'nuovoPin' then perform privato.rigenera_pin(req ->> 'id');
    when 'impostazioni' then perform privato.salva_impostazioni(req);
    else return v_vietato;
  end case;
  return privato.dati_admin() || '{"ok": true}'::jsonb;
exception when others then
  return jsonb_build_object('ok', false, 'errore', sqlerrm);
end $$;

/* ------------------------------------------------------------------ permessi */

revoke all on all tables in schema privato from public, anon, authenticated;
revoke all on all functions in schema privato from public, anon, authenticated;
revoke all on function public.api(jsonb) from public;
grant execute on function public.api(jsonb) to anon, authenticated;

-- Il risultato qui sotto mostra il vostro PIN amministratore: segnatelo.
select 'PIN amministratore' as cosa, valore as pin from privato.impostazioni where chiave = 'pin_admin';
