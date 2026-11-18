-- =====================================================================
-- 006 - PREGUNTAS RELÁMPAGO (gamificación e interacción académica)
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
-- IMPORTANTE: ejecutarlo ANTES de instalar la nueva versión de la app
--             y de subir el panel a Vercel.
--
-- Cómo funciona:
--   1. El docente lanza una pregunta (4 opciones, 10 a 120 s) desde el panel.
--   2. A los estudiantes conectados les aparece en la app y responden.
--   3. La respuesta se corrige EN EL SERVIDOR (el estudiante nunca recibe
--      cuál es la opción correcta antes de responder).
--   4. Puntos: correcta = 10 + bonus por rapidez (hasta 5)
--              incorrecta = 2 (por participar)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Rol docente (por si no se ejecutó 002_docentes_y_limpieza.sql)
-- ---------------------------------------------------------------------
create table if not exists public.docentes (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  creado_en timestamptz not null default now()
);
alter table public.docentes enable row level security;

insert into public.docentes (user_id)
select id from auth.users where email = 'elvis@continental.edu.pe'
on conflict (user_id) do nothing;

create or replace function public.es_docente()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.docentes where user_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------
-- Pregunta visible para todos (SIN la respuesta correcta)
create table if not exists public.preguntas_relampago (
  id           uuid primary key default gen_random_uuid(),
  docente_id   uuid references auth.users (id) on delete set null,
  asignatura   text,
  grupo        text,
  pregunta     text not null,
  opciones     jsonb not null,          -- ["opción A", "opción B", "opción C", "opción D"]
  duracion_seg int  not null default 30,
  creado_en    timestamptz not null default now(),
  cierra_en    timestamptz not null
);

-- Respuesta correcta: SOLO la ven los docentes
create table if not exists public.preguntas_relampago_clave (
  pregunta_id uuid primary key references public.preguntas_relampago (id) on delete cascade,
  correcta    int not null              -- índice 0..3
);

-- Respuestas de los estudiantes
create table if not exists public.respuestas_relampago (
  id                uuid primary key default gen_random_uuid(),
  pregunta_id       uuid not null references public.preguntas_relampago (id) on delete cascade,
  estudiante_id     uuid not null references auth.users (id) on delete cascade,
  estudiante_nombre text,
  opcion            int not null,
  es_correcta       boolean not null,
  segundos          numeric(6,1) not null,
  puntos            int not null,
  creado_en         timestamptz not null default now(),
  unique (pregunta_id, estudiante_id)
);

create index if not exists respuestas_relampago_creado_idx on public.respuestas_relampago (creado_en);
create index if not exists preguntas_relampago_creado_idx  on public.preguntas_relampago (creado_en);

-- ---------------------------------------------------------------------
-- 2. Seguridad (RLS)
-- ---------------------------------------------------------------------
alter table public.preguntas_relampago       enable row level security;
alter table public.preguntas_relampago_clave enable row level security;
alter table public.respuestas_relampago      enable row level security;

-- Preguntas: todos los usuarios conectados las ven; solo docentes las cierran/borran
drop policy if exists "preguntas_ver" on public.preguntas_relampago;
create policy "preguntas_ver" on public.preguntas_relampago
  for select to authenticated using (true);

drop policy if exists "preguntas_cerrar_docente" on public.preguntas_relampago;
create policy "preguntas_cerrar_docente" on public.preguntas_relampago
  for update to authenticated using (public.es_docente()) with check (public.es_docente());

drop policy if exists "preguntas_borrar_docente" on public.preguntas_relampago;
create policy "preguntas_borrar_docente" on public.preguntas_relampago
  for delete to authenticated using (public.es_docente());

-- Clave: solo docentes
drop policy if exists "clave_ver_docente" on public.preguntas_relampago_clave;
create policy "clave_ver_docente" on public.preguntas_relampago_clave
  for select to authenticated using (public.es_docente());

-- Respuestas: el docente ve todas; el estudiante solo las suyas.
-- Nadie inserta directamente: se responde con la función responder_pregunta().
drop policy if exists "respuestas_ver" on public.respuestas_relampago;
create policy "respuestas_ver" on public.respuestas_relampago
  for select to authenticated
  using (public.es_docente() or estudiante_id = auth.uid());

drop policy if exists "respuestas_borrar_docente" on public.respuestas_relampago;
create policy "respuestas_borrar_docente" on public.respuestas_relampago
  for delete to authenticated using (public.es_docente());

-- ---------------------------------------------------------------------
-- 3. Funciones
-- ---------------------------------------------------------------------
-- El docente lanza una pregunta. Devuelve el id de la pregunta.
create or replace function public.lanzar_pregunta(
  p_pregunta   text,
  p_opciones   jsonb,
  p_correcta   int,
  p_duracion   int,
  p_asignatura text default null,
  p_grupo      text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_duracion int := greatest(10, least(coalesce(p_duracion, 30), 120));
begin
  if not public.es_docente() then
    raise exception 'Solo un docente puede lanzar preguntas';
  end if;
  if coalesce(trim(p_pregunta), '') = '' then
    raise exception 'Escribe la pregunta';
  end if;
  if jsonb_typeof(p_opciones) <> 'array' or jsonb_array_length(p_opciones) not between 2 and 4 then
    raise exception 'La pregunta debe tener entre 2 y 4 opciones';
  end if;
  if p_correcta is null or p_correcta < 0 or p_correcta >= jsonb_array_length(p_opciones) then
    raise exception 'Marca cuál es la opción correcta';
  end if;

  -- Solo una pregunta abierta a la vez: se cierran las anteriores
  update public.preguntas_relampago set cierra_en = now() where cierra_en > now();

  insert into public.preguntas_relampago
    (docente_id, asignatura, grupo, pregunta, opciones, duracion_seg, cierra_en)
  values
    (auth.uid(), p_asignatura, p_grupo, trim(p_pregunta), p_opciones, v_duracion,
     now() + v_duracion * interval '1 second')
  returning id into v_id;

  insert into public.preguntas_relampago_clave (pregunta_id, correcta) values (v_id, p_correcta);
  return v_id;
end;
$$;

-- El estudiante responde. Se corrige aquí y se devuelve el resultado.
create or replace function public.responder_pregunta(
  p_pregunta uuid,
  p_opcion   int,
  p_nombre   text
) returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_preg      public.preguntas_relampago%rowtype;
  v_correcta  int;
  v_segundos  numeric;
  v_ok        boolean;
  v_puntos    int;
begin
  if v_uid is null then
    raise exception 'Debes iniciar sesión';
  end if;

  select * into v_preg from public.preguntas_relampago where id = p_pregunta;
  if not found then
    raise exception 'La pregunta no existe';
  end if;

  -- 3 s de tolerancia por la demora de la red
  if now() > v_preg.cierra_en + interval '3 seconds' then
    raise exception 'Se acabó el tiempo para responder';
  end if;

  if exists (select 1 from public.respuestas_relampago
             where pregunta_id = p_pregunta and estudiante_id = v_uid) then
    raise exception 'Ya respondiste esta pregunta';
  end if;

  select correcta into v_correcta from public.preguntas_relampago_clave where pregunta_id = p_pregunta;

  v_segundos := least(extract(epoch from now() - v_preg.creado_en), v_preg.duracion_seg);
  v_ok := (p_opcion = v_correcta);
  v_puntos := case
    when v_ok then 10 + greatest(0, round(5 * (1 - v_segundos / v_preg.duracion_seg)))::int
    else 2
  end;

  insert into public.respuestas_relampago
    (pregunta_id, estudiante_id, estudiante_nombre, opcion, es_correcta, segundos, puntos)
  values
    (p_pregunta, v_uid, p_nombre, p_opcion, v_ok, round(v_segundos, 1), v_puntos);

  return json_build_object(
    'correcta', v_ok,
    'opcion_correcta', v_correcta,
    'puntos', v_puntos,
    'segundos', round(v_segundos, 1)
  );
end;
$$;

revoke all on function public.lanzar_pregunta(text, jsonb, int, int, text, text) from public, anon;
revoke all on function public.responder_pregunta(uuid, int, text) from public, anon;
grant execute on function public.lanzar_pregunta(text, jsonb, int, int, text, text) to authenticated;
grant execute on function public.responder_pregunta(uuid, int, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Tiempo real: avisar al instante a la app y al panel
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'preguntas_relampago') then
    alter publication supabase_realtime add table public.preguntas_relampago;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and tablename = 'respuestas_relampago') then
    alter publication supabase_realtime add table public.respuestas_relampago;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 5. DATOS SIMULADOS: 2 preguntas por día (4 días anteriores) respondidas
--    por los estudiantes que asistieron ese día. (Opcional, para la demo.)
-- ---------------------------------------------------------------------
do $$
declare
  dia       int;
  q         int;
  v_id      uuid;
  v_inicio  timestamptz;
  v_corr    int;
  est       record;
  hoy_lima  date := (now() at time zone 'America/Lima')::date;
  preguntas text[] := array[
    '¿Qué tipo de investigación busca resolver un problema práctico?',
    '¿Qué diseño NO manipula la variable independiente?',
    '¿Cuál es un instrumento de la técnica de encuesta?',
    '¿Qué nivel de investigación explica causas y efectos?',
    '¿Qué método va de lo general a lo particular?',
    '¿Qué enfoque usa datos numéricos y estadística?',
    '¿Qué es la población en una investigación?',
    '¿Qué indica la hipótesis?'];
  opciones jsonb[] := array[
    '["Aplicada","Básica","Documental","Histórica"]'::jsonb,
    '["Experimental puro","No experimental","Cuasi experimental","Preexperimental"]'::jsonb,
    '["Entrevista","Cuestionario","Observación","Focus group"]'::jsonb,
    '["Exploratorio","Descriptivo","Explicativo","Correlacional"]'::jsonb,
    '["Inductivo","Deductivo","Analógico","Empírico"]'::jsonb,
    '["Cualitativo","Mixto","Cuantitativo","Hermenéutico"]'::jsonb,
    '["El total de elementos a estudiar","Una parte de la muestra","El instrumento","La variable"]'::jsonb,
    '["Una respuesta tentativa al problema","Un resultado final","Una técnica","Un antecedente"]'::jsonb];
  correctas int[] := array[0, 1, 1, 2, 1, 2, 0, 0];
  idx int;
begin
  -- No duplicar si ya se simuló antes
  if exists (select 1 from public.preguntas_relampago where pregunta = preguntas[1]) then
    return;
  end if;

  for dia in 1..4 loop
    for q in 1..2 loop
      idx := 1 + ((dia * 2 + q) % array_length(preguntas, 1));
      v_inicio := ((hoy_lima - dia) + time '08:15' + (q - 1) * interval '20 minutes') at time zone 'America/Lima';
      v_corr := correctas[idx];

      insert into public.preguntas_relampago
        (asignatura, grupo, pregunta, opciones, duracion_seg, creado_en, cierra_en)
      select a.asignatura, a.grupo, preguntas[idx], opciones[idx], 30, v_inicio, v_inicio + interval '30 seconds'
      from (select asignatura, grupo from public.alertas_inactividad
            where (fecha_hora at time zone 'America/Lima')::date = hoy_lima - dia
              and grupo is not null limit 1) a
      right join (select 1) x on true
      returning id into v_id;

      insert into public.preguntas_relampago_clave (pregunta_id, correcta) values (v_id, v_corr);

      -- Responden los que asistieron ese día (90 % de ellos)
      for est in
        select distinct estudiante_id, estudiante_nombre
        from public.asistencias
        where (fecha_hora at time zone 'America/Lima')::date = hoy_lima - dia
          and estudiante_id is not null
      loop
        if random() < 0.9 then
          declare
            v_seg numeric := round((3 + random() * 25)::numeric, 1);
            v_op  int := case when random() < 0.7 then v_corr else floor(random() * 4)::int end;
            v_ok  boolean;
          begin
            v_ok := (v_op = v_corr);
            insert into public.respuestas_relampago
              (pregunta_id, estudiante_id, estudiante_nombre, opcion, es_correcta, segundos, puntos, creado_en)
            values
              (v_id, est.estudiante_id, est.estudiante_nombre, v_op, v_ok, v_seg,
               case when v_ok then 10 + greatest(0, round(5 * (1 - v_seg / 30)))::int else 2 end,
               v_inicio + v_seg * interval '1 second')
            on conflict (pregunta_id, estudiante_id) do nothing;
          end;
        end if;
      end loop;
    end loop;
  end loop;
end $$;

-- Comprobación
select (p.creado_en at time zone 'America/Lima')::date as dia, p.pregunta,
       count(r.id) as respuestas, count(*) filter (where r.es_correcta) as correctas
from public.preguntas_relampago p
left join public.respuestas_relampago r on r.pregunta_id = p.id
group by 1, 2
order by 1 desc;
