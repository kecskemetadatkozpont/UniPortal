-- ============================================================================
-- tesztfiokok_ellenorzes.sql
-- Miért nem látom a teszt-felhasználókat a Regisztrációk / Felhasználók fülön?
-- Egyetlen lekérdezés, egy tábla. Fentről lefelé olvasva derül ki, hol akad el.
-- ============================================================================
with
-- 1. Létrejöttek-e egyáltalán a bejelentkezési fiókok?
auth_db as (
  select 1 as s, 'Bejelentkezési fiók (auth.users)' as mit,
         count(*)::text as ertek,
         case when count(*) = 0
              then '!! A teszt_adatbazis.sql NEM futott le'
              else 'OK' end as megjegyzes
    from auth.users where email like '%@teszt.hu'
),
-- 2. A trigger létrehozta-e a profilokat? Ha nem, a lista üres marad.
prof_db as (
  select 2, 'Profil (public.profiles)',
         count(*)::text,
         case when count(*) = 0 then '!! A profilok hiányoznak — a trigger nem futott'
              when count(*) < (select count(*) from auth.users where email like '%@teszt.hu')
              then '!! Kevesebb profil, mint fiók'
              else 'OK' end
    from public.profiles where email like '%@teszt.hu'
),
-- 3. Melyik FÜL alatt keresd őket? Az alapértelmezett fül a "Jóváhagyásra vár".
allapotok as (
  select 3, 'Ebből: ' || coalesce(approval_status, '(nincs)'),
         count(*)::text,
         case coalesce(approval_status, '')
           when 'approved' then 'a "Felhasználók" fülön'
           when 'pending'  then 'a "Jóváhagyásra vár" fülön'
           when 'rejected' then 'az "Elutasítva" fülön'
           else '!! ismeretlen állapot' end
    from public.profiles where email like '%@teszt.hu'
   group by approval_status
),
-- 4. Van-e olyan fiók, amihez NEM tartozik profil? Ezek sehol nem látszanak.
arva as (
  select 4, 'Profil nélküli fiók', count(*)::text,
         case when count(*) > 0 then '!! ezek SEHOL nem látszanak' else 'OK — nincs ilyen' end
    from auth.users u
   where u.email like '%@teszt.hu'
     and not exists (select 1 from public.profiles p where p.id = u.id)
),
-- 5. A te fiókod tényleg szuperadmin?
en as (
  select 5, 'A te szereped', coalesce(role, '(nincs profil)'),
         case when role = 'SUPERADMIN' then 'OK'
              else '!! a Regisztrációk nézet csak SUPERADMIN-nak látszik' end
    from public.profiles where id = auth.uid()
),
-- 6. Sorszintű biztonság: hány profilt LÁTSZ ténylegesen?
lathato as (
  select 6, 'Összes profil, amit LÁTSZ', count(*)::text,
         'ha ez kevesebb, mint a 2. sor, akkor az RLS szűr' 
    from public.profiles
),
-- 7. A lista dátum szerint rendez — van-e üres created_at?
datum as (
  select 7, 'Teszt-profil üres created_at mezővel', count(*)::text,
         case when count(*) > 0
              then 'a lista created_at szerint rendez — ezek a lista tetejére kerülnek'
              else 'OK' end
    from public.profiles
   where email like '%@teszt.hu' and created_at is null
)
select mit as "mit nézünk", ertek as "érték", megjegyzes as "mit jelent"
  from (select * from auth_db union all select * from prof_db
        union all select * from allapotok union all select * from arva
        union all select * from en union all select * from lathato
        union all select * from datum) t(s, mit, ertek, megjegyzes)
 order by s, mit;
