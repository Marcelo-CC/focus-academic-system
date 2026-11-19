-- =====================================================================
-- 008 - SEGURIDAD: solo los docentes manejan la clase y ven a todos
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
-- IMPORTANTE: ejecutarlo ANTES de subir el panel nuevo a Vercel
--             (el panel ahora solo deja entrar a cuentas de docente).
--
-- Problemas que corrige:
--   1. Un estudiante podía crear o modificar una "clase activa"
--      (configuracion_sesion) y la app de todos la tomaba como real.
--   2. Cualquier estudiante con sesión podía leer las alertas y
--      asistencias de TODOS sus compañeros.
--   3. Si no se había ejecutado el 002, la tabla "docentes" no tenía
--      permiso de lectura y el panel no podía reconocer al docente.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Docentes (se puede repetir sin problema)
-- ---------------------------------------------------------------------
create table if not exists public.docentes (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  creado_en timestamptz not null default now()
);
alter table public.docentes enable row level security;

drop policy if exists "docentes_ver_propio" on public.docentes;
create policy "docentes_ver_propio" on public.docentes
  for select to authenticated
  using (user_id = auth.uid());

-- Docente(s). Para agregar otro, copia esta línea con su correo.
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
-- 2. La clase (configuracion_sesion): todos la LEEN (la app la necesita),
--    pero solo un DOCENTE puede crearla o cambiarla.
-- ---------------------------------------------------------------------
drop policy if exists "sesion_insertar_docente" on public.configuracion_sesion;
create policy "sesion_insertar_docente" on public.configuracion_sesion
  for insert to authenticated
  with check (docente_id = auth.uid() and public.es_docente());

drop policy if exists "sesion_actualizar_docente" on public.configuracion_sesion;
create policy "sesion_actualizar_docente" on public.configuracion_sesion
  for update to authenticated
  using (docente_id = auth.uid() and public.es_docente())
  with check (docente_id = auth.uid() and public.es_docente());

-- ---------------------------------------------------------------------
-- 3. Alertas y asistencias: el docente ve todas; el estudiante solo las suyas
--    (la app solo consulta las propias, así que sigue funcionando igual).
-- ---------------------------------------------------------------------
drop policy if exists "alertas_leer" on public.alertas_inactividad;
create policy "alertas_leer" on public.alertas_inactividad
  for select to authenticated
  using (public.es_docente() or estudiante_id = auth.uid());

drop policy if exists "asistencias_leer" on public.asistencias;
create policy "asistencias_leer" on public.asistencias
  for select to authenticated
  using (public.es_docente() or estudiante_id = auth.uid());

-- ---------------------------------------------------------------------
-- Comprobación: debe aparecer el correo del docente
-- ---------------------------------------------------------------------
select u.email as docente from public.docentes d join auth.users u on u.id = d.user_id;
