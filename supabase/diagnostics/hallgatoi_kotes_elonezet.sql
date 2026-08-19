-- ============================================================
-- hallgatoi_kotes_elonezet.sql — CSAK OLVAS, semmit nem ír.
-- Megmutatja, melyik STUDENT profil melyik students sorhoz köthető,
-- és mi az, ami párosítatlan marad. Ez alapján dől el, mit írunk.
-- ============================================================
select * from (

  -- 1) STUDENT profilok és a hozzájuk e-mail alapján talált students sor
  select 1 as ord,
         'PROFIL'                                       as tipus,
         p.email                                        as azonosito,
         coalesce(p."studentId", '—')                   as mar_kotve,
         coalesce(s.id, '—')                            as email_alapjan_talalt,
         coalesce(s.name, '')                           as nev,
         case
           when p."studentId" is not null then 'mar be van kotve'
           when s.id is null              then 'NINCS parja a students tablaban'
           else 'KOTHETO → ' || s.id
         end                                            as allapot
  from public.profiles p
  left join public.students s on lower(s.email) = lower(p.email)
  where p.role = 'STUDENT'

  union all

  -- 2) students sorok, amikhez NINCS profil
  select 2, 'HALLGATOI SOR', s.email, coalesce(s.id,'—'), '—', coalesce(s.name,''),
         case when exists (select 1 from public.profiles p where lower(p.email)=lower(s.email))
              then 'van profilja' else 'NINCS fiokja' end
  from public.students s

  union all

  -- 3) összegzés
  select 3, 'OSSZEGZES', 'STUDENT profil', (select count(*)::text from public.profiles where role='STUDENT'),
         'ebbol kotve', (select count(*)::text from public.profiles where role='STUDENT' and "studentId" is not null), ''
  union all
  select 3, 'OSSZEGZES', 'students sor', (select count(*)::text from public.students),
         'e-mail alapjan parosithato',
         (select count(*)::text from public.profiles p where p.role='STUDENT'
            and exists (select 1 from public.students s where lower(s.email)=lower(p.email))), ''
  union all
  select 3, 'OSSZEGZES', 'ketes e-mail (tobb students sor ugyanarra)', '', '',
         coalesce((select string_agg(email, ', ') from
            (select lower(email) as email from public.students group by 1 having count(*)>1) x), 'nincs'), ''

) q order by ord, azonosito;
