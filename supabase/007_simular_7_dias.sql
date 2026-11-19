-- =====================================================================
-- 007 - DATOS SIMULADOS LIMPIOS: 7 días de clase (reemplaza 004 y 005)
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
--
-- Qué hace:
--   1. PRIMERO BORRA TODOS los datos creados antes: todas las alertas,
--      todas las asistencias y todas las preguntas relámpago con sus
--      respuestas (no borra usuarios ni docentes).
--   2. Deja la clase del docente FINALIZADA (hoy no hay clase en curso:
--      el Panel en Vivo queda vacío hasta que el docente inicie una).
--   3. Crea 7 días de clase: los 7 días anteriores a hoy, SIN domingos.
--      Cada clase: 08:00 a 09:30 (hora de Perú), 90 minutos, un aula por día.
--   4. Cada estudiante tiene un perfil fijo (según su número):
--        concentrado (la mayoría) · regular (3, 6, 9…) · distraído (5, 10, 15…)
--      y a lo largo de la semana MEJORA: el día 1 hay más distracciones que
--      el día 7 (útil para mostrar el efecto del sistema en la tesis).
--   5. Cada evento lleva su asignatura y aula. Al final de la clase se
--      registra "fin_clase" (igual que la app nueva).
--   6. Si existen las tablas del SQL 006: 2 preguntas relámpago por día.
--
-- Hoy NO se crean datos (el Panel en Vivo queda vacío hasta que el
-- docente inicie una clase real).
-- =====================================================================

do $$
declare
  dias        date[];
  idx         int;
  dia         date;
  v_inicio    timestamptz;
  v_fin       timestamptz;
  v_asig      text := 'TESIS 2';
  v_aula      text;
  aulas       text[] := array['Aula E-201','Aula J-301','Aula B-105','Laboratorio C-402'];
  factor      numeric;      -- 1.5 el día 1 → 0.9 el día 7 (menos distracciones)
  est         record;
  n           int;
  nombre      text;
  perfil      text;
  t           timestamptz;
  t_ingreso   timestamptz;
  r           float;
  fuera       int;
  app         text;
  app2        text;
  apps        text[] := array['WhatsApp','TikTok','Instagram','YouTube','Facebook',
                              'Juegos','Pantalla de inicio','Chrome','Spotify',
                              'Telegram','Messenger','X','ChatGPT'];
  -- preguntas relámpago
  hay_quiz    boolean := to_regclass('public.respuestas_relampago') is not null;
  q           int;
  qi          int;
  v_qid       uuid;
  v_qini      timestamptz;
  v_seg       numeric;
  v_op        int;
  v_ok        boolean;
  p_acierto   float;
  preguntas   text[] := array[
    '¿Qué tipo de investigación busca resolver un problema práctico?',
    '¿Qué diseño NO manipula la variable independiente?',
    '¿Cuál es el instrumento de la técnica de encuesta?',
    '¿Qué nivel de investigación explica causas y efectos?',
    '¿Qué método va de lo general a lo particular?',
    '¿Qué enfoque usa datos numéricos y estadística?',
    '¿Qué es la población en una investigación?',
    '¿Qué indica la hipótesis?',
    '¿Qué parte de la matriz relaciona problema, objetivo e hipótesis?',
    '¿Qué es una variable dependiente?',
    '¿Qué es la muestra?',
    '¿Para qué sirve el marco teórico?',
    '¿Qué mide la confiabilidad de un instrumento?',
    '¿Qué es la operacionalización de variables?'];
  opciones    jsonb[] := array[
    '["Aplicada","Básica","Documental","Histórica"]'::jsonb,
    '["Experimental puro","No experimental","Cuasi experimental","Preexperimental"]'::jsonb,
    '["Entrevista","Cuestionario","Guía de observación","Focus group"]'::jsonb,
    '["Exploratorio","Descriptivo","Explicativo","Correlacional"]'::jsonb,
    '["Inductivo","Deductivo","Analógico","Empírico"]'::jsonb,
    '["Cualitativo","Mixto","Cuantitativo","Hermenéutico"]'::jsonb,
    '["El total de elementos a estudiar","Una parte de la muestra","El instrumento","La variable"]'::jsonb,
    '["Una respuesta tentativa al problema","Un resultado final","Una técnica","Un antecedente"]'::jsonb,
    '["Matriz de consistencia","Cronograma","Presupuesto","Anexos"]'::jsonb,
    '["La que recibe el efecto","La que se manipula","Una constante","Un indicador"]'::jsonb,
    '["Un subconjunto de la población","El total de la población","El instrumento","El objetivo"]'::jsonb,
    '["Sustentar la investigación","Calcular la muestra","Recoger datos","Presentar el presupuesto"]'::jsonb,
    '["La consistencia de los resultados","El tamaño de la muestra","El costo","La duración"]'::jsonb,
    '["Pasar la variable a dimensiones e indicadores","Elegir el título","Redactar conclusiones","Citar autores"]'::jsonb];
  correctas   int[] := array[0, 1, 1, 2, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0];
begin
  -- -------------------------------------------------------------------
  -- 1. Borrar TODOS los datos creados anteriormente
  -- -------------------------------------------------------------------
  delete from public.alertas_inactividad where true;
  delete from public.asistencias         where true;
  if hay_quiz then
    delete from public.preguntas_relampago where true;   -- borra también claves y respuestas
  end if;

  -- -------------------------------------------------------------------
  -- 2. Los 7 días de clase (anteriores a hoy, sin domingos), del más antiguo al más reciente
  -- -------------------------------------------------------------------
  select array_agg(d order by d) into dias
  from (
    select d::date as d
    from generate_series((now() at time zone 'America/Lima')::date - 1,
                         (now() at time zone 'America/Lima')::date - 10,
                         interval '-1 day') as d
    where extract(isodow from d) <> 7
    order by d desc
    limit 7
  ) x;

  -- Clase del docente: terminada (hoy no hay clase en curso)
  update public.configuracion_sesion
     set estado = 'FINALIZADA', duracion = 90,
         creado_en = (dias[7] + time '08:00') at time zone 'America/Lima'
   where true;

  -- -------------------------------------------------------------------
  -- 3. Simular cada día
  -- -------------------------------------------------------------------
  for idx in 1..7 loop
    dia      := dias[idx];
    v_inicio := (dia + time '08:00') at time zone 'America/Lima';
    v_fin    := v_inicio + interval '90 minutes';
    v_aula   := aulas[1 + (idx - 1) % array_length(aulas, 1)];
    factor   := 1.5 - (idx - 1) * 0.1;

    for est in
      select id, email from auth.users
      where email ~ '^estudiante\d+@continental\.edu\.pe$'
    loop
      -- 7 % de inasistencia
      continue when random() < 0.07;

      n := (substring(est.email from 'estudiante(\d+)'))::int;
      nombre := 'ESTUDIANTE' || n;
      perfil := case
        when n % 5 = 0 then 'distraido'
        when n % 3 = 0 then 'regular'
        else 'concentrado'
      end;

      -- Escanea el QR en los primeros 5 minutos
      t_ingreso := v_inicio + (random() * 300) * interval '1 second';
      t := t_ingreso;

      insert into public.asistencias (estudiante_id, estudiante_nombre, qr_contenido, fecha_hora, asignatura, grupo)
      values (est.id, nombre, 'CLASE_QR_' || (extract(epoch from t) * 1000)::bigint, t, v_asig, v_aula);
      insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
      values (est.id, nombre, 'ingreso', t, v_asig, v_aula);

      -- Incidentes hasta 3 minutos antes del final
      loop
        t := t + ((case perfil
                     when 'concentrado' then 900 + random() * 1200   -- cada 15-35 min
                     when 'regular'     then 420 + random() * 480    -- cada 7-15 min
                     else                    180 + random() * 300    -- cada 3-8 min
                   end) / factor) * interval '1 second';
        exit when t > v_fin - interval '3 minutes';

        r := random();
        app := apps[1 + floor(random() * array_length(apps, 1))::int];

        if r < 0.6 then
          -- Sale a otra app
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'salio_de_app:' || app, t, v_asig, v_aula);

          if random() < 0.25 then
            app2 := apps[1 + floor(random() * array_length(apps, 1))::int];
            if app2 <> app then
              insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
              values (est.id, nombre, 'cambio_app:' || app2, t + interval '4 seconds', v_asig, v_aula);
            end if;
          end if;

          fuera := round((case perfil
                            when 'distraido' then 6 + random() * 55   -- 6 a 61 s
                            when 'regular'   then 4 + random() * 14   -- 4 a 18 s
                            else                  3 + random() * 6    -- 3 a 9 s
                          end) * factor)::int;

          if fuera >= 10 then
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
            values (est.id, nombre, 'falta_grave', t + interval '10 seconds', v_asig, v_aula);
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
            values (est.id, nombre, 'regreso_tarde:' || fuera, t + fuera * interval '1 second', v_asig, v_aula);
          else
            insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
            values (est.id, nombre, 'regreso', t + fuera * interval '1 second', v_asig, v_aula);
          end if;

        elsif r < 0.82 then
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'vio_notificaciones', t, v_asig, v_aula);

        elsif r < 0.95 then
          -- Bloqueó el celular (no es distracción)
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'pantalla_bloqueada', t, v_asig, v_aula);
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'regreso', t + (30 + random() * 90) * interval '1 second', v_asig, v_aula);

        elsif perfil = 'distraido' then
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'cerro_sesion', t, v_asig, v_aula);
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'reingreso_sesion', t + (40 + random() * 60) * interval '1 second', v_asig, v_aula);

        else
          insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
          values (est.id, nombre, 'reabrio_app', t, v_asig, v_aula);
        end if;
      end loop;

      -- Fin de la clase
      insert into public.alertas_inactividad (estudiante_id, estudiante_nombre, evento, fecha_hora, asignatura, grupo)
      values (est.id, nombre, 'fin_clase', v_fin, v_asig, v_aula);
    end loop;

    -- -----------------------------------------------------------------
    -- Preguntas relámpago del día (08:30 y 09:05)
    -- -----------------------------------------------------------------
    if hay_quiz then
      for q in 1..2 loop
        qi     := 1 + ((idx - 1) * 2 + (q - 1)) % array_length(preguntas, 1);
        v_qini := v_inicio + (case q when 1 then 30 else 65 end) * interval '1 minute';

        insert into public.preguntas_relampago (asignatura, grupo, pregunta, opciones, duracion_seg, creado_en, cierra_en)
        values (v_asig, v_aula, preguntas[qi], opciones[qi], 30, v_qini, v_qini + interval '30 seconds')
        returning id into v_qid;
        insert into public.preguntas_relampago_clave (pregunta_id, correcta) values (v_qid, correctas[qi]);

        for est in
          select estudiante_id, estudiante_nombre from public.asistencias
          where (fecha_hora at time zone 'America/Lima')::date = dia and estudiante_id is not null
        loop
          continue when random() < 0.1;   -- 10 % no responde

          n := (substring(est.estudiante_nombre from '(\d+)'))::int;
          p_acierto := case
            when n % 5 = 0 then 0.40
            when n % 3 = 0 then 0.60
            else 0.75
          end + idx * 0.02;                 -- mejoran durante la semana

          v_seg := round((3 + random() * 24)::numeric, 1);
          v_op  := case when random() < p_acierto
                        then correctas[qi]
                        else (correctas[qi] + 1 + floor(random() * (jsonb_array_length(opciones[qi]) - 1))::int)
                             % jsonb_array_length(opciones[qi])
                   end;
          v_ok  := v_op = correctas[qi];

          insert into public.respuestas_relampago
            (pregunta_id, estudiante_id, estudiante_nombre, opcion, es_correcta, segundos, puntos, creado_en)
          values
            (v_qid, est.estudiante_id, est.estudiante_nombre, v_op, v_ok, v_seg,
             case when v_ok then 10 + greatest(0, round(5 * (1 - v_seg / 30)))::int else 2 end,
             v_qini + v_seg * interval '1 second')
          on conflict (pregunta_id, estudiante_id) do nothing;
        end loop;
      end loop;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Comprobación: resumen por día (deberían bajar las distracciones)
-- ---------------------------------------------------------------------
select (fecha_hora at time zone 'America/Lima')::date                       as dia,
       min(grupo)                                                          as aula,
       count(distinct estudiante_nombre)                                   as estudiantes,
       count(*) filter (where evento like 'salio_de_app%')                 as salidas,
       count(*) filter (where evento = 'falta_grave')                      as faltas_graves,
       count(*) filter (where evento = 'vio_notificaciones')               as notificaciones
from public.alertas_inactividad
where estudiante_nombre like 'ESTUDIANTE%'
group by 1
order by 1;
