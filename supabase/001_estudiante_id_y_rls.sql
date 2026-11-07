-- =====================================================================
-- 001 - Identificar estudiantes por user.id + activar seguridad (RLS)
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
-- Ejecutarlo ANTES de instalar la nueva versión de la app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Columna estudiante_id (vinculada al usuario de Supabase Auth)
--    Los registros antiguos quedan con estudiante_id = NULL (no se pierden).
-- ---------------------------------------------------------------------
alter table public.asistencias
  add column if not exists estudiante_id uuid
  references auth.users (id) on delete set null
  default auth.uid();

alter table public.alertas_inactividad
  add column if not exists estudiante_id uuid
  references auth.users (id) on delete set null
  default auth.uid();

create index if not exists asistencias_estudiante_id_idx
  on public.asistencias (estudiante_id);
create index if not exists alertas_inactividad_estudiante_id_idx
  on public.alertas_inactividad (estudiante_id);

-- ---------------------------------------------------------------------
-- 2. Activar RLS (quita la etiqueta UNRESTRICTED)
-- ---------------------------------------------------------------------
alter table public.asistencias          enable row level security;
alter table public.alertas_inactividad  enable row level security;
alter table public.configuracion_sesion enable row level security;

-- ---------------------------------------------------------------------
-- 3. Políticas
--    Solo usuarios con sesión iniciada (authenticated) pueden acceder.
--    Un estudiante solo puede insertar registros a SU nombre (su user.id).
-- ---------------------------------------------------------------------

-- asistencias
drop policy if exists "asistencias_insertar_propias" on public.asistencias;
create policy "asistencias_insertar_propias" on public.asistencias
  for insert to authenticated
  with check (estudiante_id = auth.uid());

drop policy if exists "asistencias_leer" on public.asistencias;
create policy "asistencias_leer" on public.asistencias
  for select to authenticated
  using (true);

-- alertas_inactividad
drop policy if exists "alertas_insertar_propias" on public.alertas_inactividad;
create policy "alertas_insertar_propias" on public.alertas_inactividad
  for insert to authenticated
  with check (estudiante_id = auth.uid());

drop policy if exists "alertas_leer" on public.alertas_inactividad;
create policy "alertas_leer" on public.alertas_inactividad
  for select to authenticated
  using (true);

-- configuracion_sesion (la crea/edita solo el docente dueño; todos la leen)
drop policy if exists "sesion_leer" on public.configuracion_sesion;
create policy "sesion_leer" on public.configuracion_sesion
  for select to authenticated
  using (true);

drop policy if exists "sesion_insertar_docente" on public.configuracion_sesion;
create policy "sesion_insertar_docente" on public.configuracion_sesion
  for insert to authenticated
  with check (docente_id = auth.uid());

drop policy if exists "sesion_actualizar_docente" on public.configuracion_sesion;
create policy "sesion_actualizar_docente" on public.configuracion_sesion
  for update to authenticated
  using (docente_id = auth.uid())
  with check (docente_id = auth.uid());

-- ---------------------------------------------------------------------
-- 4. (OPCIONAL) Borrar la tabla "latidos", que no se usa en ningún lado.
--    Quita los guiones (--) de la línea de abajo solo si estás seguro.
-- ---------------------------------------------------------------------
-- drop table if exists public.latidos;
