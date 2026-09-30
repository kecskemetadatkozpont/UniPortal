-- ============================================================
-- 113_market_intel_datum.sql — JAVÍTÁS a 112-höz
-- ============================================================
-- KÉT HIBÁT JAVÍT. Idempotens, és akkor is lefuttatható, ha egyszer már futott.
--
-- 1. „operator does not exist: text >= date" — a képernyő meg sem jelent.
--    Az `admission_processes.created_at` oszlop SZÖVEG
--    (04_admission_processes.sql), nem időbélyeg; a 112-es mi_dashboard
--    viszont dátumként hasonlította össze. Mostantól mi.ts(text) alakítja át,
--    és ami nem értelmezhető dátum (üres, null, '2026-02-30', szöveg), az
--    NULL lesz — egyetlen rossz sor nem döntheti el az egész képernyőt.
--
-- 2. „elhallgatott forrás” riasztás frissen felvett forrásra. A 112 mindent
--    jelzett, amiről két napja nincs adat — beleértve azt is, amiről még
--    SOHA nem volt. Egy új forrás nem üzemzavar; a Források fülön „még nincs”
--    felirattal látszik. Mostantól csak az számít elnémultnak, ami MÁR hozott
--    adatot, és azóta hallgat.
--
-- CSAK EZT KELL LEFUTTATNI, ha a 112 már lefutott. (A 112 maga is javítva van,
-- friss telepítésnél elég az.)
-- FÜGG: 112.
-- ============================================================

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
        -- ELHALLGATOTT, nem ÚJ: csak az számít, ami MÁR hozott adatot, és
        -- azóta elnémult. Egy frissen felvett forrás még nem hiba — a
        -- Források fülön „még nincs" felirattal látszik.
        where s.aktiv and s.utolso_adat is not null
          and s.utolso_adat < now() - interval '2 day'
      ) t)
  ) into v;

  return v;
end $$;


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
         s.platform || ' — utoljára: ' || s.utolso_adat::date::text,
         'figyelem', s.intezmeny, s.id,
         md5('nema' || s.kulcs || current_date::text)
    from mi.source s
   where s.aktiv and s.utolso_adat is not null
     and s.utolso_adat < now() - interval '2 day'
  on conflict (ujjlenyomat) do nothing;

  return jsonb_build_object('ok', true);
end $$;

-- A segédfüggvényt senki nem hívhatja kívülről; a felületi RPC joga maradjon.
do $mi$
begin
  execute 'revoke all on function mi.ts(text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function mi.ts(text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function mi.ts(text) from authenticated';
  end if;

  execute 'revoke all on function public.mi_dashboard(integer,text,text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.mi_dashboard(integer,text,text) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.mi_dashboard(integer,text,text) to authenticated';
  end if;

  -- A riasztás-felismerő CSAK a service_role-é (Edge Function).
  execute 'revoke all on function public.mi_detect_alerts() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.mi_detect_alerts() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on function public.mi_detect_alerts() from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.mi_detect_alerts() to service_role';
  end if;
end $mi$;

-- Önellenőrzés: szöveges és ROSSZ dátumokkal is le kell futnia.
do $chk$
begin
  if mi.ts('ez nem datum') is not null or mi.ts('2026-02-30') is not null
     or mi.ts('') is not null or mi.ts(null) is not null then
    raise exception 'MI: a dátum-átalakító rossz értéket adott vissza.';
  end if;
  if mi.ts('2026-09-30') is null then
    raise exception 'MI: a dátum-átalakító a JÓ dátumot sem fogadta el.';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated')
     and has_function_privilege('authenticated', 'public.mi_detect_alerts()', 'execute') then
    raise exception 'MI: a riasztás-felismerő hívható bejelentkezett felhasználóval.';
  end if;
  raise notice 'MI 113 OK: dátum-összehasonlítás és néma-forrás jelzés javítva.';
end $chk$;
