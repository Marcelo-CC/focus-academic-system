-- =====================================================================
-- 004 - DATOS SIMULADOS para demostrar el panel docente
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
--
-- Simula 5 días de clase (hoy y los 4 días anteriores) para TODOS los
-- estudiante*@continental.edu.pe (asistencias + eventos de monitoreo).
--
-- Cada estudiante tiene un "perfil" para que las notas sean variadas:
--   - Concentrado  : casi sin distracciones       (notas 18-20)
--   - Regular      : algunas distracciones         (notas 12-17)
--   - Distraído    : muchas salidas y faltas graves (notas < 11)
--
-- Los eventos tienen el MISMO formato que genera la app real.
-- Para borrarlos: en el panel, botón "🧹 Restablecer registros"
-- (o ejecuta el bloque comentado al final de este archivo).
-- =====================================================================

do $$
declare
  est        record;
  dia        int;
  base       timestamptz;  -- inicio de la clase de ese día
  t          timestamptz;  -- momento del evento
  perfil     text;
  incidentes int;
  k          int;
  r          float;
  fuera      int;          -- segundos fuera de la app
  app        text;
  app2       text;
  nombre     text;
  apps       text[] := array['WhatsApp','TikTok','Instagram','YouTube','Facebook',
                             'Juegos','Pantalla de inicio','Chrome','Spotify',
                             'Telegram','Messenger','X','ChatGPT','Otra App'];
  hoy_lima   date := (now() at time zone 'America/Lima')::date;
begin
  for est in
    select id, email
    from auth.users
    where email like 'estudiante%@continental.edu.pe'
    order by email
  loop
    nombre := upper(split_part(est.email, '@', 1)); -- igual que la app: ESTUDIANTE7

    -- Perfil fijo por estudiante (según su número), para que sea coherente entre días
    perfil := case
      when (substring(est.email from 'estudiante(\d+)'))::int % 5 = 0 then 'distraido'
      when (substring(est.email from 'estudiante(\d+)'))::int % 3 = 0 then 'regular'
      else 'concentrado'
    end;

    for dia in 0..4 loop
      -- Algunos estudiantes faltan algún día (8 % de probabilidad)
      if random() < 0.08 then
        continue;
      end if;

      -- Hoy: clase que empezó hace 45 min (para ver el Panel en Vivo con datos).
      -- Días anteriores: clase a las 08:00 hora de Perú.
      if dia = 0 then
        base := now() - interval '45 minutes';
      else
        base := ((hoy_lima - dia) + time '08:00') at time zone 'America/Lima';
      end if;

      -- Ingreso (escaneo del QR) en los primeros 5 minutos
      t := base + (random() * 300) * interval '1 second';

      insert into public.asistencias (estudiante_id, estudiante_nombre, qr_contenido, fecha_hora)
      values (est.id, nombre,
              'CLASE_QR_' || (extract(epoch from t) * 1000)::bigint, t);

      insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
      values (est.id, nombre, 'ingreso', t);

      -- Cantidad de incidentes según el perfil
      incidentes := case perfil
        when 'concentrado' then floor(random() * 2)::int        -- 0 a 1
        when 'regular'     then 1 + floor(random() * 3)::int    -- 1 a 3
        else                    3 + floor(random() * 4)::int    -- 3 a 6
      end;

      for k in 1..incidentes loop
        -- Siguiente incidente entre 2 y 7 minutos después
        t := t + (120 + random() * 300) * interval '1 second';
        r := random();
        app := apps[1 + floor(random() * array_length(apps, 1))::int];

        if r < 0.55 then
          -- Sale a otra app
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'salio_de_app:' || app, t);

          -- A veces cambia a una segunda app estando fuera
          if random() < 0.3 then
            app2 := apps[1 + floor(random() * array_length(apps, 1))::int];
            if app2 <> app then
              insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
              values (est.id, nombre, 'cambio_app:' || app2, t + interval '4 seconds');
            end if;
          end if;

          -- Tiempo fuera: los distraídos tardan más en volver
          fuera := case perfil
            when 'distraido' then 5 + floor(random() * 50)::int   -- 5 a 54 s
            else                  3 + floor(random() * 12)::int   -- 3 a 14 s
          end;

          if fuera >= 10 then
            -- No volvió en 10 s: falta grave + regreso tarde
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
            values (est.id, nombre, 'falta_grave', t + interval '10 seconds');
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
            values (est.id, nombre, 'regreso_tarde:' || fuera, t + fuera * interval '1 second');
          else
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
            values (est.id, nombre, 'regreso', t + fuera * interval '1 second');
          end if;

        elsif r < 0.75 then
          -- Bajó la barra de notificaciones
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'vio_notificaciones', t);

        elsif r < 0.92 then
          -- Bloqueó el celular (no es distracción) y volvió
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'pantalla_bloqueada', t);
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'regreso', t + (30 + random() * 90) * interval '1 second');

        elsif perfil = 'distraido' then
          -- Cerró sesión y volvió a entrar
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'cerro_sesion', t);
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'reingreso_sesion', t + interval '75 seconds');

        else
          -- Cerró la app y la volvió a abrir
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
          values (est.id, nombre, 'reabrio_app', t);
        end if;
      end loop;

      -- HOY: algunos distraídos quedan FUERA en este momento (rojo en Panel en Vivo)
      if dia = 0 and perfil = 'distraido' and random() < 0.6 then
        app := apps[1 + floor(random() * array_length(apps, 1))::int];
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
        values (est.id, nombre, 'salio_de_app:' || app, now() - interval '20 seconds');
        insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora)
        values (est.id, nombre, 'falta_grave', now() - interval '10 seconds');
      end if;
    end loop;
  end loop;
end $$;

-- Resumen: eventos simulados por día
select (fecha_hora at time zone 'America/Lima')::date as dia,
       count(*) as eventos,
       count(distinct estudiante_nombre) as estudiantes
from public.alertas_inactividad
group by 1
order by 1 desc;

-- ---------------------------------------------------------------------
-- (OPCIONAL) BORRAR TODOS LOS DATOS de alertas y asistencias.
-- Quita los "--" de las dos líneas de abajo SOLO si quieres empezar de cero.
-- ---------------------------------------------------------------------
-- delete from public.alertas_inactividad where true;
-- delete from public.asistencias where true;

-- NOTA: si ejecutas este script DESPUÉS de 005_clase_y_aula.sql, los datos
-- nuevos quedarán sin aula. Para completarlos, vuelve a ejecutar la sección 2
-- de 005_clase_y_aula.sql (solo rellena los registros que no tienen aula).
