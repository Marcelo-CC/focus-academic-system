-- =====================================================================
-- 002 - Rol de docente + permiso para RESTABLECER (borrar) registros
-- Ejecutar en: Supabase -> SQL Editor -> New query -> Run
-- Requiere haber ejecutado antes 001_estudiante_id_y_rls.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tabla de docentes: solo los usuarios de esta tabla pueden borrar
--    registros desde el panel. Los estudiantes NO.
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

-- ---------------------------------------------------------------------
-- 2. Registrar al docente (cambia el correo si es otro).
--    Para agregar más docentes, repite esta línea con su correo.
-- ---------------------------------------------------------------------
insert into public.docentes (user_id)
select id from auth.users where email = 'elvis@continental.edu.pe'
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Función auxiliar: ¿el usuario actual es docente?
-- ---------------------------------------------------------------------
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
-- 4. Solo los docentes pueden borrar alertas y asistencias
-- ---------------------------------------------------------------------
drop policy if exists "alertas_borrar_docente" on public.alertas_inactividad;
create policy "alertas_borrar_docente" on public.alertas_inactividad
  for delete to authenticated
  using (public.es_docente());

drop policy if exists "asistencias_borrar_docente" on public.asistencias;
create policy "asistencias_borrar_docente" on public.asistencias
  for delete to authenticated
  using (public.es_docente());

-- ---------------------------------------------------------------------
-- Comprobación: debe mostrar 1 fila con el correo del docente
-- ---------------------------------------------------------------------
select u.email from public.docentes d join auth.users u on u.id = d.user_id;
