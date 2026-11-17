-- =====================================================================
-- 003 - Crear varias cuentas de estudiante de una sola vez
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
--
-- Crea estudiante3@continental.edu.pe ... estudiante25@continental.edu.pe
-- (estudiante1 y estudiante2 ya existen; si un correo ya existe, se omite).
-- Todas con la contraseña 123456 y el correo ya confirmado.
--
-- Para crear otro rango, cambia los números de "for i in 3..25".
-- =====================================================================

do $$
declare
  i      int;
  uid    uuid;
  correo text;
begin
  for i in 3..25 loop
    correo := 'estudiante' || i || '@continental.edu.pe';

    -- Si ya existe, no se vuelve a crear
    if exists (select 1 from auth.users where email = correo) then
      continue;
    end if;

    uid := gen_random_uuid();

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      -- Deben ser texto vacío (no NULL) o el inicio de sesión falla
      confirmation_token, recovery_token, email_change,
      email_change_token_new, email_change_token_current, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated',
      correo, extensions.crypt('123456', extensions.gen_salt('bf')),
      now(), '{"provider":"email","providers":["email"]}', '{}',
      now(), now(),
      '', '', '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider,
      last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), uid, uid::text,
      jsonb_build_object('sub', uid::text, 'email', correo, 'email_verified', true),
      'email', now(), now(), now()
    );
  end loop;
end $$;

-- Comprobación: lista de estudiantes creados
select email, created_at
from auth.users
where email like 'estudiante%@continental.edu.pe'
order by created_at;
