-- ============================================================================
-- teszt_fiokok_javitas.sql — a teszt-fiókok bejelentkezésének javítása
--
-- A HIBA
--   A teszt-fiókok léteznek, de egyikkel sem lehet belépni:
--       nem létező fiók  ->  "Invalid login credentials"
--       teszt-fiók       ->  "Database error querying schema"  (bármely jelszóval)
--
--   A második üzenet nem hitelesítési hiba: a GoTrue el sem jut a jelszóig,
--   mert a sort nem tudja beolvasni. Több auth.users varchar-oszlopot Go
--   string-be olvas, ami NULL-ra elhasal — a normál regisztráció ezeket üres
--   szövegre állítja, az én SQL-beszúrásom viszont NULL-on hagyta.
--
-- MIT CSINÁL
--   A @teszt.hu fiókoknál a NULL-t üres szövegre cseréli az érintett
--   oszlopokban. Valódi felhasználóhoz NEM nyúl.
--
-- IDEMPOTENS és ártalmatlan: az üres szöveg pontosan az, amit a GoTrue vár.
-- ============================================================================

do $$
declare
  v_oszlop text;
  v_n      integer;
  v_ossz   integer := 0;
begin
  -- Csak azokat az oszlopokat írjuk, amik LÉTEZNEK ebben a Supabase-verzióban:
  -- a GoTrue sémája verziónként bővül, és egy hiányzó oszlop miatt nem akarunk
  -- elszállni.
  foreach v_oszlop in array array[
    'confirmation_token', 'recovery_token', 'email_change',
    'email_change_token_new', 'email_change_token_current',
    'phone_change', 'phone_change_token', 'reauthentication_token'
  ]
  loop
    if exists (select 1 from information_schema.columns
                where table_schema = 'auth' and table_name = 'users'
                  and column_name = v_oszlop) then
      execute format(
        'update auth.users set %I = '''' where email like ''%%@teszt.hu'' and %I is null',
        v_oszlop, v_oszlop);
      get diagnostics v_n = row_count;
      v_ossz := v_ossz + v_n;
      if v_n > 0 then
        raise notice '%: % sor javítva', v_oszlop, v_n;
      end if;
    end if;
  end loop;

  -- A visszaigazolt e-mail is kell, különben a belépés "Email not confirmed".
  --
  -- A confirmed_at-ot SZÁNDÉKOSAN nem írjuk: az éles Supabase-ben GENERÁLT
  -- oszlop (least(email_confirmed_at, phone_confirmed_at)), tehát nem írható —
  -- "column confirmed_at can only be updated to DEFAULT". Magától felveszi a
  -- helyes értéket, amint az email_confirmed_at megvan.
  update auth.users
     set email_confirmed_at = now()
   where email like '%@teszt.hu'
     and email_confirmed_at is null;
  get diagnostics v_n = row_count;
  if v_n > 0 then raise notice 'e-mail visszaigazolás pótolva: % sor', v_n; end if;

  raise notice '---';
  raise notice 'Összesen % mezőt javítottunk.', v_ossz;
end $$;

-- ---------------------------------------------------------------------------
-- ELLENŐRZÉS — ez az utolsó eredmény, ezt fogod látni
-- ---------------------------------------------------------------------------
select 'Teszt-fiók összesen'        as "mit", count(*)::text as "érték",
       'jelszó mindenhol: Teszt1234!' as "megjegyzés"
  from auth.users where email like '%@teszt.hu'
union all
select 'Ebből NULL mezővel maradt', count(*)::text,
       case when count(*) = 0 then 'OK — mind belépésre kész'
            else '!! ezekkel még nem lehet belépni' end
  from auth.users
 where email like '%@teszt.hu'
   and (confirmation_token is null or recovery_token is null
        or email_change is null or email_change_token_new is null)
union all
select 'Visszaigazolt e-mail nélkül', count(*)::text,
       case when count(*) = 0 then 'OK' else '!! "Email not confirmed" hibát adna' end
  from auth.users where email like '%@teszt.hu' and email_confirmed_at is null
order by 1;
