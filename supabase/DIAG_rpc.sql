-- ============================================================================
--  DIAG_rpc.sql — UniPortal
--  MI HIÁNYZIK, ÉS A POSTGREST LÁTJA-E?
-- ============================================================================
--
--  MIKOR KELL: ha a felület azt írja, hogy
--    "Could not find the function public.<valami> ... in the schema cache"
--  Ez a PostgREST PGRST202 hibája, és KÉT különböző dolgot jelenthet:
--    (a) a függvény tényleg nincs meg — a migráció nem futott le,
--    (b) megvan, de a PostgREST séma-gyorsítótára még a régit ismeri.
--  A kettőt eddig nem lehetett megkülönböztetni a felületről. Ez a szkript
--  megkülönbözteti: az első tábla az adatbázisból olvas, a végén pedig
--  frissítjük a gyorsítótárat.
--
--  Futtasd le EGÉSZBEN, és küldd vissza a táblát.
-- ============================================================================

-- ---------- 1. Megvannak-e a legutóbbi migrációk függvényei? ----------
with kellene(migracio, fuggveny) as (values
  ('41 — a félév nem foglalható',      'echo_campaign_create'),
  ('42 — kampányszerkesztő',           'echo_campaign_update'),
  ('42 — célközönség',                 'echo_campaign_audience_set'),
  ('43 — kurzusnyilvántartás',         'echo_course_list'),
  ('43 — kurzusnyilvántartás',         'echo_course_save'),
  ('44 — kurzustörténet',              'echo_course_history'),
  ('45 — élő célközönség-becslés',     'echo_audience_preview'),
  ('47 — névsor a becslés mögé',       'echo_campaign_students'),
  ('48 — kampány kérdőíve adminként',  'echo_campaign_form'),
  ('49 — "melyik az az N kurzus?"',    'echo_student_courses'),
  ('50 — a hallgató saját kurzusai',   'echo_my_enrollments')
)
select k.migracio                                   as migracio,
       k.fuggveny                                   as fuggveny,
       case when p.oid is null then 'HIÁNYZIK — a migráció nem futott le'
            else 'megvan' end                       as allapot,
       coalesce(nullif(pg_get_function_identity_arguments(p.oid), ''), '(nincs paramétere)')
                                                    as parameterek
  from kellene k
  left join pg_namespace n on n.nspname = 'public'
  left join pg_proc p on p.pronamespace = n.oid and p.proname = k.fuggveny
 order by k.migracio, k.fuggveny;


-- ---------- 2. A séma-gyorsítótár frissítése ----------
-- A PostgREST a függvények listáját gyorsítótárazza, és rendszerint magától
-- frissíti DDL után — de ez késhet vagy kimaradhat. Ez a NOTIFY azonnal
-- újraolvastatja vele. Ártalmatlan akkor is, ha nem volt rá szükség.
notify pgrst, 'reload schema';

select 'A séma-gyorsítótár frissítése elküldve.' as mit_csinaltunk,
       'Várj 2-3 másodpercet, majd frissítsd az oldalt (Cmd+Shift+R).' as mi_a_teendo;
