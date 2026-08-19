-- ============================================================
-- UniPortal Pro — Hallgatói fiókok bekötése a jelentkezői sorokhoz
-- ------------------------------------------------------------
-- MIÉRT KELL:
--   A szerepkör-alapú RLS (11/12) a jelentkezőnek a SAJÁT sorait mutatja.
--   Ehhez tudni kell, melyik fiók melyik "students" sorhoz tartozik.
--   Ezt a profiles."studentId" mező köti össze. Ma a legtöbb fióknál üres,
--   ezért a 12-es flip után üres Hallgatói Portált kapnának.
--
-- MIT CSINÁL:
--   Kitölti a profiles."studentId" mezőt ott, ahol a profil e-mail címe
--   PONTOSAN EGY students sor e-mail címével egyezik.
--
-- MIT NEM CSINÁL — szándékosan óvatos:
--   • Nem ír felül meglévő "studentId" értéket.
--   • Nem köt be kétes párosítást (ha egy e-mailre több students sor jut).
--   • Nem hoz létre students sort a párja nélküli fiókoknak (lásd a fájl végén).
--   • Nem nyúl a szerepkörökhöz és a jóváhagyáshoz.
--
-- ELŐTTE: futtasd le a diagnostics/hallgatoi_kotes_elonezet.sql fájlt,
--   és nézd meg, mi fog párosodni. Ez a szkript pontosan azt teszi meg.
--
-- Idempotens — biztonságosan újrafuttatható.
-- ============================================================

-- ---------- 1. bekötés e-mail alapján ----------
with parok as (
  select p.id as profil_id, s.id as student_id
  from public.profiles p
  join public.students s on lower(s.email) = lower(p.email)
  where p.role = 'STUDENT'
    and p."studentId" is null
    and p.email is not null
    -- csak egyértelmű párosítás: az e-mailre pontosan egy students sor jut
    and (select count(*) from public.students s2 where lower(s2.email) = lower(p.email)) = 1
)
update public.profiles p
   set "studentId" = k.student_id
  from parok k
 where p.id = k.profil_id;

-- ---------- 2. mi lett az eredmény ----------
select * from (
  select 1 as ord, 'BEKOTVE most es korabban' as mit,
         (select count(*) from public.profiles where role='STUDENT' and "studentId" is not null)::text as ertek,
         (select count(*) from public.profiles where role='STUDENT')::text as osszes
  union all
  select 2, 'MEG MINDIG KOTETLEN',
         (select count(*) from public.profiles where role='STUDENT' and "studentId" is null)::text,
         (select count(*) from public.profiles where role='STUDENT')::text
  union all
  select 3, 'kotetlen fiokok e-mailje',
         coalesce((select string_agg(email, ', ' order by email) from public.profiles
                    where role='STUDENT' and "studentId" is null), 'nincs'), ''
  union all
  select 4, 'students sor fiok nelkul',
         coalesce((select string_agg(s.email, ', ' order by s.email) from public.students s
                    where not exists (select 1 from public.profiles p
                                       where lower(p.email) = lower(s.email))), 'nincs'), ''
) q order by ord;

-- ============================================================
-- HA A KÖTETLEN FIÓKOKHOZ IS KELL JELENTKEZŐI SOR
-- ------------------------------------------------------------
-- Ha a fenti 2. sor nem nulla, és azokat a fiókokat NEM tesztfióknak szánod,
-- akkor kell hozzájuk egy "students" sor. Az alábbi blokk ezt megteszi:
-- minden kötetlen STUDENT profilhoz létrehoz egy minimális jelentkezői sort,
-- és rögtön be is köti. Vedd ki a kommentből, ha ezt akarod.
--
-- FIGYELEM: ez ADATOT HOZ LÉTRE. Előbb nézd meg a 3. sor listáját.
--
-- do $$
-- declare r record; uj text;
-- begin
--   for r in select id, email, name from public.profiles
--             where role='STUDENT' and "studentId" is null and email is not null
--   loop
--     uj := 'S' || substr(md5(r.email), 1, 8);
--     insert into public.students (id, name, email, status, "appliedAt")
--     values (uj, coalesce(r.name, split_part(r.email,'@',1)), r.email, 'Draft',
--             to_char(now(), 'YYYY.MM.DD'))
--     on conflict (id) do nothing;
--     update public.profiles set "studentId" = uj where id = r.id;
--   end loop;
-- end $$;
-- ============================================================
