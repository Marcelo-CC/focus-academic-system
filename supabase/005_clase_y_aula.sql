-- =====================================================================
-- 005 - Guardar en QUÉ CLASE y AULA ocurrió cada registro
--       + datos simulados para ESTUDIANTE1 y ESTUDIANTE2
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
-- IMPORTANTE: ejecutarlo ANTES de instalar la nueva versión de la app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Nuevas columnas: asignatura y grupo/aula
-- ---------------------------------------------------------------------
alter table public.alertas_inactividad add column if not exists asignatura text;
alter table public.alertas_inactividad add column if not exists grupo      text;
alter table public.asistencias         add column if not exists asignatura text;
alter table public.asistencias         add column if not exists grupo      text;

-- ---------------------------------------------------------------------
-- 2. Registros que ya existen (no tenían aula): se completan.
--    - Los de HOY: con la clase configurada actualmente por el docente.
--    - Los de días anteriores: se reparten entre aulas de ejemplo
--      (son datos de prueba), para que el panel muestre aulas distintas.
-- ---------------------------------------------------------------------
do $$
declare
  hoy_lima   date := (now() at time zone 'America/Lima')::date;
  asig_hoy   text;
  grupo_hoy  text;
begin
  select asignatura, grupo into asig_hoy, grupo_hoy
  from public.configuracion_sesion
  order by creado_en desc
  limit 1;

  asig_hoy  := coalesce(asig_hoy, 'TESIS 2');
  grupo_hoy := coalesce(grupo_hoy, 'Aula J-301');

  -- Hoy
  update public.alertas_inactividad
     set asignatura = asig_hoy, grupo = grupo_hoy
   where asignatura is null
     and (fecha_hora at time zone 'America/Lima')::date = hoy_lima;

  update public.asistencias
     set asignatura = asig_hoy, grupo = grupo_hoy
   where asignatura is null
     and (fecha_hora at time zone 'America/Lima')::date = hoy_lima;

  -- Días anteriores: un aula distinta según el día
  update public.alertas_inactividad
     set asignatura = asig_hoy,
         grupo = (array['Aula E-201','Aula J-301','Aula B-105','Laboratorio C-402'])
                 [1 + (extract(doy from fecha_hora at time zone 'America/Lima')::int % 4)]
   where asignatura is null;

  update public.asistencias
     set asignatura = asig_hoy,
         grupo = (array['Aula E-201','Aula J-301','Aula B-105','Laboratorio C-402'])
                 [1 + (extract(doy from fecha_hora at time zone 'America/Lima')::int % 4)]
   where asignatura is null;
end $$;

-- ---------------------------------------------------------------------
-- 3. Datos simulados para ESTUDIANTE1 y ESTUDIANTE2 (hoy y 4 días atrás)
--    ESTUDIANTE1: atento con alguna distracción leve
--    ESTUDIANTE2: varias salidas y una falta grave por día
-- ---------------------------------------------------------------------
do $$
declare
  est       record;
  dia       int;
  base      timestamptz;
  t         timestamptz;
  nombre    text;
  asig      text;
  aula      text;
  hoy_lima  date := (now() at time zone 'America/Lima')::date;
  apps      text[] := array['WhatsApp','TikTok','Instagram','YouTube','Juegos','Pantalla de inicio'];
begin
  for est in
    select id, email from auth.users
    where email in ('estudiante1@continental.edu.pe', 'estudiante2@continental.edu.pe')
  loop
    nombre := upper(split_part(est.email, '@', 1));

    for dia in 0..4 loop
      if dia = 0 then
        base := now() - interval '40 minutes';
      else
        base := ((hoy_lima - dia) + time '08:00') at time zone 'America/Lima';
      end if;

      -- Misma clase/aula que el resto de estudiantes ese día
      select a.asignatura, a.grupo into asig, aula
      from public.alertas_inactividad a
      where (a.fecha_hora at time zone 'America/Lima')::date = (hoy_lima - dia)
        and a.grupo is not null
      limit 1;
      asig := coalesce(asig, 'TESIS 2');
      aula := coalesce(aula, 'Aula J-301');

      t := base + (random() * 240) * interval '1 second';

      insert into public.asistencias (estudiante_id, estudiante_nombre, qr_contenido, fecha_hora, asignatura, grupo)
      values (est.id, nombre, 'CLASE_QR_' || (extract(epoch from t) * 1000)::bigint, t, asig, aula);

      insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
      values (est.id, nombre, 'ingreso', t, asig, aula);

      if nombre = 'ESTUDIANTE1' then
        -- Atento: una salida corta (vuelve a tiempo) y a veces mira notificaciones
        t := t + (300 + random() * 600) * interval '1 second';
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'salio_de_app:' || apps[1 + floor(random() * 6)::int], t, asig, aula);
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'regreso', t + (3 + floor(random() * 6)::int) * interval '1 second', asig, aula);

        if random() < 0.5 then
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'vio_notificaciones', t + interval '6 minutes', asig, aula);
        end if;
      else
        -- Varias salidas, una de ellas con falta grave
        t := t + (180 + random() * 300) * interval '1 second';
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'salio_de_app:' || apps[1 + floor(random() * 6)::int], t, asig, aula);
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'regreso', t + interval '6 seconds', asig, aula);

        t := t + (240 + random() * 300) * interval '1 second';
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'salio_de_app:TikTok', t, asig, aula);
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'cambio_app:Instagram', t + interval '5 seconds', asig, aula);
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'falta_grave', t + interval '10 seconds', asig, aula);
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'regreso_tarde:' || (15 + floor(random() * 30)::int), t + interval '25 seconds', asig, aula);

        t := t + (200 + random() * 200) * interval '1 second';
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
        values (est.id, nombre, 'vio_notificaciones', t, asig, aula);
      end if;
    end loop;
  end loop;
end $$;

-- Comprobación: registros por día y aula
select (fecha_hora at time zone 'America/Lima')::date as dia, asignatura, grupo, count(*) as eventos
from public.alertas_inactividad
group by 1, 2, 3
order by 1 desc;
