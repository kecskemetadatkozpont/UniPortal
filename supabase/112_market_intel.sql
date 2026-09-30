-- ============================================================
-- 112_market_intel.sql — PIACFIGYELŐ: marketing- és versenytársfigyelés
-- ============================================================
-- MIÉRT: ma senki nem követi rendszeresen, mivel szólítják meg a versenytársak
-- ugyanazokat a diákokat, akikre mi is pályázunk. Ami tudásunk van, az egy-egy
-- kollégának feltűnt poszt. Ez a migráció megadja a tárolást és a lekérdezést;
-- a gyűjtést egy Edge Function tölti be (Apify webhook), a felületet a
-- features/market-intel.jsx adja.
--
-- A LEGFONTOSABB DÖNTÉS: a modul NEM tárol személyes adatot. Nyilvános
-- INTÉZMÉNYI kommunikációt figyel, és abból is aggregátumot (napi
-- pillanatkép, poszt-metrika, hirdetés-metaadat). Kommentelő, követő,
-- magánszemély nem kerül ide — sem oszlopban, sem jsonb-ben.
--
-- MIT TELEPÍT
--   1. mi séma (nem exposed) + jogosultsági segédek ('market_intel' kulcs)
--   2. mi.source        — mit figyelünk (intézmény, platform, kör, saját-e)
--   3. mi.snapshot      — napi pillanatkép forrásonként (követő, poszt, bevonás)
--   4. mi.post          — poszt-szintű metrika (TARTALOM NÉLKÜL: formátum, nyelv, bevonás)
--   5. mi.ad            — hirdetéskönyvtárból: futamidő, célország, téma, landing
--   6. mi.web_change    — tandíj / határidő / kínálat változása
--   7. mi.trend         — keresleti index országonként és kulcsszavanként
--   8. mi.alert         — kezelendő tételek (nem értesítés: van állapota)
--   9. mi.ingest_run    — betöltési napló + frissülés-ellenőrzés
--  10. public.mi_* RPC-k: dashboard, intézmény-lap, forráskezelés, riasztás,
--      és a CSAK service_role által hívható mi_ingest()
--
-- IDEMPOTENS — kétszer lefuttatva ugyanaz az eredmény.
-- FÜGG: 01 (admission_processes), 39 (role_permission), 73 (my_*_permissions).
-- ============================================================

create schema if not exists mi;

-- A séma nem kerül a PostgREST elé: minden hozzáférés a public.mi_* RPC-ken megy.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on schema mi from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema mi from anon';
  end if;
end $$;


-- ============================================================
-- 1. JOGOSULTSÁG
-- ============================================================
-- A három szint (szerepkör / csoport / egyéni) union-ja, a 77-es mintájára.
create or replace function mi.has_perm(p_key text)
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    public.is_superadmin() or public.is_admin()
    or exists (select 1
                 from public.profiles pr
                 join public.role_permission rp on rp.role_kod = pr.role
                where pr.id = auth.uid() and rp.permission = p_key)
    or p_key = any (public.my_group_permissions())
    or p_key = any (public.my_user_permissions()),
  false)
$$;

-- Az admission_processes.created_at SZÖVEG (04_admission_processes.sql), nem
-- időbélyeg: a demó fázisban így készült, és azóta is így hordozza az adatot.
-- Dátumként összehasonlítani csak átalakítás után lehet — enélkül a lekérdezés
-- „operator does not exist: text >= date" hibával áll meg. Ami nem értelmezhető
-- dátum, az null lesz: egyetlen rossz sor nem döntheti el az egész képernyőt.
create or replace function mi.ts(p text)
returns timestamptz
language plpgsql immutable
as $$
begin
  if p is null or p = '' then return null; end if;
  return p::timestamptz;
exception when others then
  return null;
end $$;

create or replace function mi.require_perm()
returns void
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
begin
  if auth.uid() is null then raise exception 'MI_NOT_AUTHENTICATED'; end if;
  if not mi.has_perm('market_intel') then
    raise exception 'MI_FORBIDDEN: ehhez a képernyőhöz piacfigyelő (market_intel) jogosultság kell.';
  end if;
end $$;

insert into public.role_permission (role_kod, permission)
select 'ADMIN', 'market_intel'
where exists (select 1 from public.role_definition where kod = 'ADMIN')
on conflict do nothing;


-- ============================================================
-- 2. MIT FIGYELÜNK
-- ============================================================
create table if not exists mi.source (
  id          uuid primary key default gen_random_uuid(),
  -- Stabil kulcs, ezt küldi vissza a betöltő. Kézzel adjuk: 'obuda-instagram'.
  kulcs       text not null unique,
  intezmeny   text not null,
  platform    text not null,
  -- Mit figyelünk rajta: oldal (social), hirdetéskönyvtár, weboldal, kereslet.
  cim         text,
  kor         text not null default 'szuk',
  orszag      text,
  -- A MI oldalunk: ehhez mérjük a részesedést. Több is lehet (kar, program).
  sajat       boolean not null default false,
  aktiv       boolean not null default true,
  -- A betöltő mezőnév-térképe. Így egy másik Actor más mezőneveivel is
  -- működik, KÓDMÓDOSÍTÁS NÉLKÜL: {"kovetok":"followersCount"}.
  mezo_terkep jsonb not null default '{}'::jsonb,
  megjegyzes  text,
  -- Mikor hozott UTOLJÁRA adatot. Nem a pillanatképből számoljuk: egy
  -- weboldal-forrásnak sosincs pillanatképe, és az ilyet a frissülés-
  -- ellenőrzés tévesen „elhallgatott" forrásnak jelölte.
  utolso_adat timestamptz,
  letrehozva  timestamptz not null default now(),
  frissitve   timestamptz not null default now()
);
alter table mi.source add column if not exists utolso_adat timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'mi_source_kor_chk') then
    alter table mi.source add constraint mi_source_kor_chk
      check (kor in ('szuk', 'bo', 'regionalis'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'mi_source_platform_chk') then
    alter table mi.source add constraint mi_source_platform_chk
      check (platform in ('facebook','instagram','tiktok','youtube','linkedin','web','ads','trends'));
  end if;
end $$;

create index if not exists mi_source_intezmeny_idx on mi.source (intezmeny, platform);
comment on table mi.source is
  'Mit figyelünk. Egy sor = egy intézmény egy csatornája. A kulcs stabil: a betöltő ezzel hivatkozik rá.';


-- ============================================================
-- 3. NAPI PILLANATKÉP
-- ============================================================
create table if not exists mi.snapshot (
  id        bigserial primary key,
  source_id uuid not null references mi.source(id) on delete cascade,
  nap       date not null,
  kovetok   bigint,
  poszt_db  integer,
  bevonas   bigint,
  extra     jsonb not null default '{}'::jsonb,
  rogzitve  timestamptz not null default now(),
  unique (source_id, nap)
);
create index if not exists mi_snapshot_nap_idx on mi.snapshot (nap desc, source_id);


-- ============================================================
-- 4. POSZT-SZINTŰ METRIKA — TARTALOM NÉLKÜL
-- ============================================================
-- Szándékosan nincs itt a poszt szövege és nincs szerző. A formátum, a nyelv
-- és a bevonás elég ahhoz, hogy eldöntsük, mit érdemes nekünk forgatni.
create table if not exists mi.post (
  id        bigserial primary key,
  source_id uuid not null references mi.source(id) on delete cascade,
  kulso_id  text not null,
  kelt      timestamptz,
  url       text,
  formatum  text,
  nyelv     text,
  bevonas   bigint,
  tema      text,
  rogzitve  timestamptz not null default now(),
  unique (source_id, kulso_id)
);
create index if not exists mi_post_kelt_idx on mi.post (kelt desc);


-- ============================================================
-- 5. HIRDETÉSEK
-- ============================================================
create table if not exists mi.ad (
  id           bigserial primary key,
  intezmeny    text not null,
  platform     text not null,
  kulso_id     text not null,
  elso_latas   date,
  utolso_latas date,
  orszagok     text[] not null default '{}',
  tema         text,
  landing_url  text,
  kreativ      text,
  rogzitve     timestamptz not null default now(),
  unique (platform, kulso_id)
);
create index if not exists mi_ad_latas_idx on mi.ad (utolso_latas desc);
comment on column mi.ad.kreativ is
  'A hirdetés rövid leírása vagy főcíme a hirdetéskönyvtárból. Nyilvános kereskedelmi közlés, nem személyes adat.';


-- ============================================================
-- 6. WEBOLDAL-VÁLTOZÁS
-- ============================================================
create table if not exists mi.web_change (
  id        bigserial primary key,
  source_id uuid not null references mi.source(id) on delete cascade,
  mezo      text not null,
  regi      text,
  uj        text,
  eszlelve  timestamptz not null default now()
);
create index if not exists mi_web_change_idx on mi.web_change (eszlelve desc);


-- ============================================================
-- 7. KERESLETI INDEX
-- ============================================================
create table if not exists mi.trend (
  id       bigserial primary key,
  orszag   text not null,
  kulcsszo text not null,
  het      date not null,
  ertek    integer,
  unique (orszag, kulcsszo, het)
);


-- ============================================================
-- 8. RIASZTÁSOK — feladatok, nem értesítések
-- ============================================================
create table if not exists mi.alert (
  id          uuid primary key default gen_random_uuid(),
  tipus       text not null,
  cim         text not null,
  reszlet     text,
  sulyossag   text not null default 'info',
  intezmeny   text,
  source_id   uuid references mi.source(id) on delete set null,
  keletkezett timestamptz not null default now(),
  allapot     text not null default 'uj',
  kezelo      uuid,
  lezarva     timestamptz,
  megjegyzes  text,
  -- Ugyanaz az esemény ne keletkezzen kétszer: a betöltő ezt számolja.
  ujjlenyomat text unique
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'mi_alert_allapot_chk') then
    alter table mi.alert add constraint mi_alert_allapot_chk
      check (allapot in ('uj','folyamatban','lezart','nem_erdekes'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'mi_alert_sulyossag_chk') then
    alter table mi.alert add constraint mi_alert_sulyossag_chk
      check (sulyossag in ('info','figyelem','surgos'));
  end if;
end $$;
create index if not exists mi_alert_allapot_idx on mi.alert (allapot, keletkezett desc);


-- ============================================================
-- 9. BETÖLTÉSI NAPLÓ
-- ============================================================
create table if not exists mi.ingest_run (
  id          bigserial primary key,
  forras      text,
  indult      timestamptz not null default now(),
  tetel_db    integer not null default 0,
  ok          boolean not null default true,
  hiba        text
);
create index if not exists mi_ingest_run_idx on mi.ingest_run (indult desc);


-- ============================================================
-- 10. FELÜLETI RPC-K
-- ============================================================

-- A képernyő nyitókérdése: van-e egyáltalán jogosultságunk és adatunk.
create or replace function public.mi_context()
returns jsonb
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
declare v jsonb;
begin
  perform mi.require_perm();
  select jsonb_build_object(
    'forras_db',   (select count(*) from mi.source where aktiv),
    'sajat_db',    (select count(*) from mi.source where aktiv and sajat),
    'adat_van',    (select exists (select 1 from mi.snapshot)
                        or exists (select 1 from mi.ad)
                        or exists (select 1 from mi.trend)),
    'utolso_betoltes', (select max(indult) from mi.ingest_run)
  ) into v;
  return v;
end $$;

-- Mit figyelünk — a Források fül listája.
create or replace function public.mi_sources()
returns jsonb
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
declare v jsonb;
begin
  perform mi.require_perm();
  select coalesce(jsonb_agg(x order by x->>'intezmeny', x->>'platform'), '[]'::jsonb) into v
  from (
    select jsonb_build_object(
      'id', s.id, 'kulcs', s.kulcs, 'intezmeny', s.intezmeny, 'platform', s.platform,
      'cim', s.cim, 'kor', s.kor, 'orszag', s.orszag, 'sajat', s.sajat, 'aktiv', s.aktiv,
      'megjegyzes', s.megjegyzes,
      'utolso_adat', s.utolso_adat,
      'poszt_db', (select count(*) from mi.post p where p.source_id = s.id)
    ) x
    from mi.source s
  ) t;
  return v;
end $$;

-- Forrás felvétele és módosítása. A kulcs egyedi; ha létezik, felülírjuk.
create or replace function public.mi_source_save(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = mi, public, pg_temp
as $$
declare v_id uuid;
begin
  perform mi.require_perm();
  if coalesce(p->>'kulcs', '') = '' then raise exception 'MI_INVALID: a kulcs kötelező.'; end if;
  if coalesce(p->>'intezmeny', '') = '' then raise exception 'MI_INVALID: az intézmény kötelező.'; end if;

  insert into mi.source (kulcs, intezmeny, platform, cim, kor, orszag, sajat, aktiv, megjegyzes, mezo_terkep)
  values (
    p->>'kulcs', p->>'intezmeny', coalesce(p->>'platform','web'), nullif(p->>'cim',''),
    coalesce(p->>'kor','szuk'), nullif(p->>'orszag',''),
    coalesce((p->>'sajat')::boolean, false), coalesce((p->>'aktiv')::boolean, true),
    nullif(p->>'megjegyzes',''), coalesce(p->'mezo_terkep', '{}'::jsonb)
  )
  on conflict (kulcs) do update set
    intezmeny = excluded.intezmeny, platform = excluded.platform, cim = excluded.cim,
    kor = excluded.kor, orszag = excluded.orszag, sajat = excluded.sajat,
    aktiv = excluded.aktiv, megjegyzes = excluded.megjegyzes,
    mezo_terkep = excluded.mezo_terkep, frissitve = now()
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.mi_source_delete(p_id uuid)
returns jsonb
language plpgsql security definer
set search_path = mi, public, pg_temp
as $$
begin
  perform mi.require_perm();
  delete from mi.source where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- A dashboard egyetlen hívásból. p_napok: a vizsgált ablak; p_orszag és p_kor szűr.
create or replace function public.mi_dashboard(
  p_napok integer default 28,
  p_orszag text default null,
  p_kor text default null
)
returns jsonb
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
declare
  v_tol date := current_date - greatest(coalesce(p_napok, 28), 7);
  v_sajat_bevonas bigint;
  v_ossz_bevonas bigint;
  v jsonb;
begin
  perform mi.require_perm();

  select coalesce(sum(sn.bevonas), 0) into v_sajat_bevonas
    from mi.snapshot sn join mi.source s on s.id = sn.source_id
   where sn.nap >= v_tol and s.sajat;

  select coalesce(sum(sn.bevonas), 0) into v_ossz_bevonas
    from mi.snapshot sn join mi.source s on s.id = sn.source_id
   where sn.nap >= v_tol and (p_kor is null or s.kor = p_kor);

  select jsonb_build_object(
    'ablak_tol', v_tol,
    'ablak_ig', current_date,

    -- ---- kártyák ----
    'kartyak', jsonb_build_object(
      'reszesedes', case when v_ossz_bevonas > 0
                         then round(100.0 * v_sajat_bevonas / v_ossz_bevonas, 1) else null end,
      'koveto_valtozas', (
        select coalesce(sum(u.veg - u.kezd), 0) from (
          select (array_agg(sn.kovetok order by sn.nap desc))[1] as veg,
                 (array_agg(sn.kovetok order by sn.nap asc))[1]  as kezd
            from mi.snapshot sn join mi.source s on s.id = sn.source_id
           where sn.nap >= v_tol and s.sajat and sn.kovetok is not null
           group by sn.source_id
        ) u),
      'aktiv_hirdetes', (
        select count(*) from mi.ad a
         where a.utolso_latas >= v_tol
           and (p_orszag is null or p_orszag = any (a.orszagok))),
      'jelentkezes', (
        select count(*) from public.admission_processes ap
         where mi.ts(ap.created_at) >= v_tol
           and (p_orszag is null
                or lower(coalesce(ap.data->'personal'->>'country','')) = lower(p_orszag)))
    ),

    -- ---- idősor: hét · posztok · hirdetések · jelentkezések ----
    'idosor', (
      select coalesce(jsonb_agg(r order by r->>'het'), '[]'::jsonb) from (
        select jsonb_build_object(
          'het', h::date,
          'poszt', (select count(*) from mi.post p
                      join mi.source s on s.id = p.source_id
                     where p.kelt >= h and p.kelt < h + interval '7 day'
                       and (p_kor is null or s.kor = p_kor)),
          'hirdetes', (select count(*) from mi.ad a
                        where a.elso_latas >= h::date and a.elso_latas < (h + interval '7 day')::date
                          and (p_orszag is null or p_orszag = any (a.orszagok))),
          'jelentkezes', (select count(*) from public.admission_processes ap
                           where mi.ts(ap.created_at) >= h
                             and mi.ts(ap.created_at) < h + interval '7 day'
                             and (p_orszag is null
                                  or lower(coalesce(ap.data->'personal'->>'country','')) = lower(p_orszag)))
        ) r
        from generate_series(date_trunc('week', v_tol::timestamptz),
                             date_trunc('week', now()), interval '7 day') h
      ) t),

    -- ---- versenytárs-tábla ----
    'intezmenyek', (
      select coalesce(jsonb_agg(r order by r->>'intezmeny'), '[]'::jsonb) from (
        select jsonb_build_object(
          'intezmeny', s.intezmeny,
          'kor', min(s.kor),
          'sajat', bool_or(s.sajat),
          'csatorna_db', count(distinct s.id),
          'koveto', (select sum(x.veg) from (
                        select (array_agg(sn.kovetok order by sn.nap desc))[1] veg
                          from mi.snapshot sn where sn.source_id in (
                            select s2.id from mi.source s2 where s2.intezmeny = s.intezmeny)
                           and sn.kovetok is not null
                         group by sn.source_id) x),
          'poszt', (select count(*) from mi.post p
                      join mi.source s3 on s3.id = p.source_id
                     where s3.intezmeny = s.intezmeny and p.kelt >= v_tol),
          'bevonas', (select coalesce(avg(p.bevonas), 0)::bigint from mi.post p
                        join mi.source s4 on s4.id = p.source_id
                       where s4.intezmeny = s.intezmeny and p.kelt >= v_tol),
          'hirdetes', (select count(*) from mi.ad a
                        where a.intezmeny = s.intezmeny and a.utolso_latas >= v_tol),
          'utolso_poszt', (select max(p.kelt) from mi.post p
                             join mi.source s5 on s5.id = p.source_id
                            where s5.intezmeny = s.intezmeny)
        ) r
        from mi.source s
        where s.aktiv and (p_kor is null or s.kor = p_kor)
        group by s.intezmeny
      ) t),

    -- ---- hirdetés-fal ----
    'hirdetesek', (
      select coalesce(jsonb_agg(r order by r->>'utolso_latas' desc), '[]'::jsonb) from (
        select jsonb_build_object(
          'id', a.id, 'intezmeny', a.intezmeny, 'platform', a.platform,
          'elso_latas', a.elso_latas, 'utolso_latas', a.utolso_latas,
          'napok', greatest(0, (a.utolso_latas - a.elso_latas)),
          'orszagok', to_jsonb(a.orszagok), 'tema', a.tema,
          'landing_url', a.landing_url, 'kreativ', a.kreativ
        ) r
        from mi.ad a
        where a.utolso_latas >= v_tol
          and (p_orszag is null or p_orszag = any (a.orszagok))
        order by a.utolso_latas desc
        limit 40
      ) t),

    -- ---- országtábla: kereslet · célzás · a mi jelentkezőink ----
    'orszagok', (
      select coalesce(jsonb_agg(r order by (r->>'jelentkezes')::int desc), '[]'::jsonb) from (
        select jsonb_build_object(
          'orszag', o.orszag,
          'kereslet', (select round(avg(t2.ertek)) from mi.trend t2
                        where t2.orszag = o.orszag and t2.het >= v_tol),
          'celzas', (select count(*) from mi.ad a where o.orszag = any (a.orszagok)
                       and a.utolso_latas >= v_tol),
          'jelentkezes', (select count(*) from public.admission_processes ap
                           where mi.ts(ap.created_at) >= v_tol
                             and lower(coalesce(ap.data->'personal'->>'country','')) = lower(o.orszag))
        ) r
        from (
          select distinct orszag from mi.trend where orszag is not null
          union
          select distinct unnest(orszagok) from mi.ad
          union
          select distinct ap.data->'personal'->>'country'
            from public.admission_processes ap
           where mi.ts(ap.created_at) >= v_tol
             and coalesce(ap.data->'personal'->>'country','') <> ''
        ) o(orszag)
        where o.orszag is not null and o.orszag <> ''
      ) t),

    -- ---- riasztások ----
    'riasztasok', (
      select coalesce(jsonb_agg(r order by r->>'keletkezett' desc), '[]'::jsonb) from (
        select jsonb_build_object(
          'id', al.id, 'tipus', al.tipus, 'cim', al.cim, 'reszlet', al.reszlet,
          'sulyossag', al.sulyossag, 'intezmeny', al.intezmeny,
          'keletkezett', al.keletkezett, 'allapot', al.allapot, 'megjegyzes', al.megjegyzes
        ) r
        from mi.alert al
        where al.allapot in ('uj','folyamatban')
        order by al.keletkezett desc
        limit 50
      ) t),

    -- ---- frissülés-ellenőrzés: melyik forrás hallgat el ----
    'nema_forrasok', (
      select coalesce(jsonb_agg(r order by r->>'intezmeny'), '[]'::jsonb) from (
        select jsonb_build_object(
          'kulcs', s.kulcs, 'intezmeny', s.intezmeny, 'platform', s.platform,
          'utolso_adat', s.utolso_adat
        ) r
        from mi.source s
        where s.aktiv and coalesce(s.utolso_adat, now() - interval '999 day') < now() - interval '2 day'
      ) t)
  ) into v;

  return v;
end $$;

-- Egy intézmény lapja: csatornák, idősor, legjobb posztok, hirdetések, változások.
create or replace function public.mi_institution(p_intezmeny text, p_napok integer default 90)
returns jsonb
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
declare
  v_tol date := current_date - greatest(coalesce(p_napok, 90), 7);
  v jsonb;
begin
  perform mi.require_perm();
  select jsonb_build_object(
    'intezmeny', p_intezmeny,
    'csatornak', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'kulcs', s.kulcs, 'platform', s.platform, 'cim', s.cim,
        'koveto', (select sn.kovetok from mi.snapshot sn where sn.source_id = s.id
                    order by sn.nap desc limit 1),
        'utolso_adat', (select max(sn.nap) from mi.snapshot sn where sn.source_id = s.id)
      ) order by s.platform), '[]'::jsonb)
      from mi.source s where s.intezmeny = p_intezmeny),
    'posztok', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'kelt', p.kelt, 'formatum', p.formatum, 'nyelv', p.nyelv,
        'bevonas', p.bevonas, 'tema', p.tema, 'url', p.url
      ) order by p.bevonas desc nulls last), '[]'::jsonb)
      from (select p2.* from mi.post p2 join mi.source s2 on s2.id = p2.source_id
             where s2.intezmeny = p_intezmeny and p2.kelt >= v_tol
             order by p2.bevonas desc nulls last limit 20) p),
    'hirdetesek', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'platform', a.platform, 'elso_latas', a.elso_latas, 'utolso_latas', a.utolso_latas,
        'orszagok', to_jsonb(a.orszagok), 'tema', a.tema, 'kreativ', a.kreativ,
        'landing_url', a.landing_url
      ) order by a.utolso_latas desc), '[]'::jsonb)
      from mi.ad a where a.intezmeny = p_intezmeny and a.utolso_latas >= v_tol),
    'valtozasok', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'mezo', w.mezo, 'regi', w.regi, 'uj', w.uj, 'eszlelve', w.eszlelve
      ) order by w.eszlelve desc), '[]'::jsonb)
      from mi.web_change w join mi.source s3 on s3.id = w.source_id
      where s3.intezmeny = p_intezmeny and w.eszlelve >= v_tol)
  ) into v;
  return v;
end $$;

-- Riasztás állapotának léptetése. Ez teszi feladattá: lezárható és látszik, ki zárta.
create or replace function public.mi_alert_set(p_id uuid, p_allapot text, p_megjegyzes text default null)
returns jsonb
language plpgsql security definer
set search_path = mi, public, pg_temp
as $$
begin
  perform mi.require_perm();
  if p_allapot not in ('uj','folyamatban','lezart','nem_erdekes') then
    raise exception 'MI_INVALID: ismeretlen állapot.';
  end if;
  update mi.alert
     set allapot = p_allapot,
         megjegyzes = coalesce(nullif(p_megjegyzes, ''), megjegyzes),
         kezelo = auth.uid(),
         lezarva = case when p_allapot in ('lezart','nem_erdekes') then now() else null end
   where id = p_id;
  if not found then raise exception 'MI_NOT_FOUND'; end if;
  return jsonb_build_object('ok', true);
end $$;


-- ============================================================
-- 11. BETÖLTÉS — CSAK A SERVICE_ROLE (Edge Function)
-- ============================================================
-- EZ A SZERZŐDÉS a gyűjtő felé. Egy hívás = egy forrás egy futása.
--
-- {
--   "forras": "obuda-instagram",            -- mi.source.kulcs, KÖTELEZŐ
--   "pillanatkep": { "nap": "2026-09-30", "kovetok": 12400, "poszt_db": 4, "bevonas": 1830 },
--   "posztok":    [ { "kulso_id": "...", "kelt": "2026-09-28T10:00:00Z", "url": "...",
--                     "formatum": "reel", "nyelv": "en", "bevonas": 320, "tema": "tandij" } ],
--   "hirdetesek": [ { "kulso_id": "...", "platform": "facebook", "intezmeny": "...",
--                     "elso_latas": "2026-09-01", "utolso_latas": "2026-09-30",
--                     "orszagok": ["Nigeria","India"], "tema": "osztondij",
--                     "landing_url": "...", "kreativ": "Apply now for..." } ],
--   "web":        [ { "mezo": "tandij", "regi": "2500 EUR", "uj": "2700 EUR" } ],
--   "trend":      [ { "orszag": "Nigeria", "kulcsszo": "study in hungary",
--                     "het": "2026-09-28", "ertek": 68 } ],
--   "ures": false                            -- true: a gyűjtő nem talált semmit
-- }
--
-- Minden szakasz elhagyható. A függvény idempotens: ugyanaz a köteg kétszer
-- lefuttatva nem duplikál (kulső azonosító + nap az egyediség alapja).
create or replace function public.mi_ingest(p jsonb)
returns jsonb
language plpgsql security definer
set search_path = mi, public, pg_temp
as $$
declare
  v_src   mi.source%rowtype;
  v_db    integer := 0;
  v_elem  jsonb;
  v_regi  text;
begin
  if coalesce(p->>'forras','') = '' then raise exception 'MI_INGEST: hiányzik a forrás kulcsa.'; end if;
  select * into v_src from mi.source where kulcs = p->>'forras';
  if not found then raise exception 'MI_INGEST: ismeretlen forrás: %', p->>'forras'; end if;

  -- 1. napi pillanatkép
  if p ? 'pillanatkep' and p->'pillanatkep' <> 'null'::jsonb then
    insert into mi.snapshot (source_id, nap, kovetok, poszt_db, bevonas, extra)
    values (
      v_src.id,
      coalesce((p->'pillanatkep'->>'nap')::date, current_date),
      nullif(p->'pillanatkep'->>'kovetok','')::bigint,
      nullif(p->'pillanatkep'->>'poszt_db','')::integer,
      nullif(p->'pillanatkep'->>'bevonas','')::bigint,
      coalesce(p->'pillanatkep'->'extra', '{}'::jsonb))
    on conflict (source_id, nap) do update set
      kovetok = coalesce(excluded.kovetok, mi.snapshot.kovetok),
      poszt_db = coalesce(excluded.poszt_db, mi.snapshot.poszt_db),
      bevonas = coalesce(excluded.bevonas, mi.snapshot.bevonas),
      extra = excluded.extra;
    v_db := v_db + 1;
  end if;

  -- 2. posztok
  for v_elem in select * from jsonb_array_elements(coalesce(p->'posztok', '[]'::jsonb)) loop
    insert into mi.post (source_id, kulso_id, kelt, url, formatum, nyelv, bevonas, tema)
    values (v_src.id, v_elem->>'kulso_id',
            nullif(v_elem->>'kelt','')::timestamptz, nullif(v_elem->>'url',''),
            nullif(v_elem->>'formatum',''), nullif(v_elem->>'nyelv',''),
            nullif(v_elem->>'bevonas','')::bigint, nullif(v_elem->>'tema',''))
    on conflict (source_id, kulso_id) do update set
      bevonas = coalesce(excluded.bevonas, mi.post.bevonas),
      tema = coalesce(excluded.tema, mi.post.tema);
    v_db := v_db + 1;
  end loop;

  -- 3. hirdetések
  for v_elem in select * from jsonb_array_elements(coalesce(p->'hirdetesek', '[]'::jsonb)) loop
    insert into mi.ad (intezmeny, platform, kulso_id, elso_latas, utolso_latas,
                       orszagok, tema, landing_url, kreativ)
    values (coalesce(nullif(v_elem->>'intezmeny',''), v_src.intezmeny),
            coalesce(nullif(v_elem->>'platform',''), v_src.platform),
            v_elem->>'kulso_id',
            nullif(v_elem->>'elso_latas','')::date, nullif(v_elem->>'utolso_latas','')::date,
            coalesce((select array_agg(x) from jsonb_array_elements_text(
                        coalesce(v_elem->'orszagok','[]'::jsonb)) x), '{}'),
            nullif(v_elem->>'tema',''), nullif(v_elem->>'landing_url',''),
            nullif(v_elem->>'kreativ',''))
    on conflict (platform, kulso_id) do update set
      utolso_latas = greatest(coalesce(excluded.utolso_latas, mi.ad.utolso_latas), mi.ad.utolso_latas),
      orszagok = excluded.orszagok, tema = coalesce(excluded.tema, mi.ad.tema);
    v_db := v_db + 1;
  end loop;

  -- 4. weboldal-változás — csak akkor, ha tényleg más, és riasztást is szül
  for v_elem in select * from jsonb_array_elements(coalesce(p->'web', '[]'::jsonb)) loop
    select w.uj into v_regi from mi.web_change w
     where w.source_id = v_src.id and w.mezo = v_elem->>'mezo'
     order by w.eszlelve desc limit 1;
    if v_regi is distinct from (v_elem->>'uj') then
      insert into mi.web_change (source_id, mezo, regi, uj)
      values (v_src.id, v_elem->>'mezo', coalesce(v_regi, v_elem->>'regi'), v_elem->>'uj');
      insert into mi.alert (tipus, cim, reszlet, sulyossag, intezmeny, source_id, ujjlenyomat)
      values ('web_valtozas',
              v_src.intezmeny || ': ' || (v_elem->>'mezo') || ' változott',
              coalesce(v_regi, v_elem->>'regi', '—') || ' → ' || coalesce(v_elem->>'uj','—'),
              'figyelem', v_src.intezmeny, v_src.id,
              md5(v_src.kulcs || (v_elem->>'mezo') || coalesce(v_elem->>'uj','')))
      on conflict (ujjlenyomat) do nothing;
      v_db := v_db + 1;
    end if;
  end loop;

  -- 5. keresleti index
  for v_elem in select * from jsonb_array_elements(coalesce(p->'trend', '[]'::jsonb)) loop
    insert into mi.trend (orszag, kulcsszo, het, ertek)
    values (v_elem->>'orszag', v_elem->>'kulcsszo',
            (v_elem->>'het')::date, nullif(v_elem->>'ertek','')::integer)
    on conflict (orszag, kulcsszo, het) do update set ertek = excluded.ertek;
    v_db := v_db + 1;
  end loop;

  insert into mi.ingest_run (forras, tetel_db, ok) values (p->>'forras', v_db, true);
  -- A frissülés azt jelenti, hogy a GYŰJTŐ ELÉRT MINKET, nem azt, hogy
  -- változott valami: egy weboldal hetekig lehet változatlan, attól még
  -- működik a figyelés. Ha a gyűjtő üres kézzel jött (a forrásoldal átalakult,
  -- a szelektor nem fog semmit), azt külön jelzi: "ures": true — ilyenkor NEM
  -- frissítünk, és két nap után riasztás lesz belőle.
  update mi.source
     set frissitve = now(),
         utolso_adat = case when coalesce((p->>'ures')::boolean, false)
                            then utolso_adat else now() end
   where id = v_src.id;

  return jsonb_build_object('ok', true, 'tetel_db', v_db);
exception when others then
  insert into mi.ingest_run (forras, tetel_db, ok, hiba) values (p->>'forras', v_db, false, sqlerrm);
  raise;
end $$;

-- A betöltő ebből tudja meg, MIT kell gyűjtenie és milyen mezőnevekkel.
-- Csak a service_role hívhatja: a mezőtérkép és a figyelt címek nem tartoznak
-- a bejelentkezett felhasználóra.
create or replace function public.mi_ingest_plan()
returns jsonb
language plpgsql stable security definer
set search_path = mi, public, pg_temp
as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
    'kulcs', s.kulcs, 'intezmeny', s.intezmeny, 'platform', s.platform,
    'cim', s.cim, 'orszag', s.orszag, 'kor', s.kor, 'mezo_terkep', s.mezo_terkep
  ) order by s.platform, s.kulcs), '[]'::jsonb) into v
  from mi.source s where s.aktiv;
  return v;
end $$;

-- Új kampány és kiugró poszt felismerése. A betöltés UTÁN hívja a függvény.
create or replace function public.mi_detect_alerts()
returns jsonb
language plpgsql security definer
set search_path = mi, public, pg_temp
as $$
declare v_db integer := 0;
begin
  -- Új hirdetés-kampány: ma először látott hirdetés.
  insert into mi.alert (tipus, cim, reszlet, sulyossag, intezmeny, ujjlenyomat)
  select 'uj_kampany',
         a.intezmeny || ': új hirdetés indult',
         coalesce(a.tema, '') || case when a.orszagok <> '{}' then ' · ' || array_to_string(a.orszagok, ', ') else '' end,
         'info', a.intezmeny,
         md5('kampany' || a.platform || a.kulso_id)
    from mi.ad a
   where a.elso_latas >= current_date - 1
  on conflict (ujjlenyomat) do nothing;
  get diagnostics v_db = row_count;

  -- Kiugró poszt: a forrás 30 napos mediánjának háromszorosa fölött.
  insert into mi.alert (tipus, cim, reszlet, sulyossag, intezmeny, source_id, ujjlenyomat)
  select 'kiugro_poszt',
         s.intezmeny || ': kiugróan teljesítő poszt',
         'bevonás ' || p.bevonas || ' (medián ' || m.med || ')',
         'info', s.intezmeny, s.id,
         md5('kiugro' || p.source_id::text || p.kulso_id)
    from mi.post p
    join mi.source s on s.id = p.source_id
    join (select source_id, percentile_cont(0.5) within group (order by bevonas) med
            from mi.post where kelt >= current_date - 30 and bevonas is not null
           group by source_id) m on m.source_id = p.source_id
   where p.kelt >= current_date - 2 and m.med > 0 and p.bevonas > 3 * m.med
  on conflict (ujjlenyomat) do nothing;

  -- Elhallgatott forrás: két napja nincs adat, pedig aktív.
  insert into mi.alert (tipus, cim, reszlet, sulyossag, intezmeny, source_id, ujjlenyomat)
  select 'nema_forras', s.intezmeny || ': a gyűjtés nem hoz adatot',
         s.platform || ' — utoljára: ' || coalesce(s.utolso_adat::date::text, 'soha'),
         'figyelem', s.intezmeny, s.id,
         md5('nema' || s.kulcs || current_date::text)
    from mi.source s
   where s.aktiv and coalesce(s.utolso_adat, now() - interval '999 day') < now() - interval '2 day'
  on conflict (ujjlenyomat) do nothing;

  return jsonb_build_object('ok', true);
end $$;


-- ============================================================
-- 12. JOGOK — ÉLESBEN AZ ALAPÉRTELMEZÉS TÚL BŐKEZŰ
-- ============================================================
-- A Supabase minden ÚJ public függvényre megadja az EXECUTE-ot az
-- authenticated szerepkörnek. A betöltőt ezért expliciten el kell venni,
-- különben bárki, aki be van jelentkezve, tölthetne a piacfigyelőbe.
do $mi$
declare
  f text;
  has_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  has_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  has_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  foreach f in array array['mi.has_perm(text)', 'mi.require_perm()', 'mi.ts(text)'] loop
    execute format('revoke all on function %s from public', f);
    if has_anon then execute format('revoke all on function %s from anon', f); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f); end if;
  end loop;

  foreach f in array array[
    'public.mi_context()',
    'public.mi_sources()',
    'public.mi_source_save(jsonb)',
    'public.mi_source_delete(uuid)',
    'public.mi_dashboard(integer,text,text)',
    'public.mi_institution(text,integer)',
    'public.mi_alert_set(uuid,text,text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    if has_anon then execute format('revoke all on function %s from anon', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;

  foreach f in array array[
    'public.mi_ingest(jsonb)', 'public.mi_detect_alerts()', 'public.mi_ingest_plan()'
  ] loop
    execute format('revoke all on function %s from public', f);
    if has_anon then execute format('revoke all on function %s from anon', f); end if;
    if has_auth then execute format('revoke all on function %s from authenticated', f); end if;
    if has_srv then execute format('grant execute on function %s to service_role', f); end if;
  end loop;
end $mi$;

-- A táblákra a kliens semmilyen jogot nem kap: minden az RPC-ken megy.
do $$
declare t text;
begin
  for t in select format('mi.%I', tablename) from pg_tables where schemaname = 'mi' loop
    execute format('revoke all on table %s from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('revoke all on table %s from anon', t);
    end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then
      execute format('revoke all on table %s from authenticated', t);
    end if;
  end loop;
end $$;


-- ============================================================
-- 13. ÖNELLENŐRZÉS
-- ============================================================
do $chk$
declare v_n integer;
begin
  select count(*) into v_n from pg_tables where schemaname = 'mi';
  if v_n < 8 then raise exception 'MI: hiányzó tábla (% van)', v_n; end if;

  if exists (select 1 from pg_roles where rolname = 'authenticated')
     and has_function_privilege('authenticated', 'public.mi_ingest(jsonb)', 'execute') then
    raise exception 'MI: a betöltő hívható bejelentkezett felhasználóval — a revoke nem futott le.';
  end if;

  if not exists (select 1 from pg_proc where proname = 'mi_dashboard') then
    raise exception 'MI: hiányzik a mi_dashboard.';
  end if;

  raise notice 'MI OK: % tábla, RPC-k a helyükön.', v_n;
end $chk$;
