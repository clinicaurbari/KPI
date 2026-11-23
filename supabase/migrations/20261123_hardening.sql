-- Endurecimiento de seguridad y trazabilidad. Ejecutar DESPUÉS de schema.sql.
-- No elimina datos existentes. Recomendado validar primero en un proyecto Supabase de pruebas.

-- 1) Jefaturas solo pueden modificar avance mediante registrar_avance(); no hay UPDATE directo.
drop policy if exists objetivos_update on public.objetivos;
create policy objetivos_update_presidente on public.objetivos
  for update to authenticated
  using (public.mi_rol() = 'presidente')
  with check (public.mi_rol() = 'presidente');

-- La función RPC marca internamente la operación autorizada; el trigger rechaza
-- cambios de ejecución realizados directamente por PostgREST.
create or replace function public.proteger_planificacion() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if public.mi_rol() <> 'presidente' and (
    new.titulo is distinct from old.titulo or new.descripcion is distinct from old.descripcion or
    new.area_principal_id is distinct from old.area_principal_id or new.prioridad is distinct from old.prioridad or
    new.kpi_meta is distinct from old.kpi_meta or new.meta_valor is distinct from old.meta_valor or
    new.meta_unidad is distinct from old.meta_unidad or new.fecha_inicio is distinct from old.fecha_inicio or
    new.fecha_limite is distinct from old.fecha_limite or new.activo is distinct from old.activo
  ) then raise exception 'Solo Presidencia puede modificar planificación, metas y plazos.'; end if;

  if public.mi_rol() = 'jefe_area' and (
    new.porcentaje_avance is distinct from old.porcentaje_avance or
    new.estado is distinct from old.estado or
    new.fecha_finalizacion_real is distinct from old.fecha_finalizacion_real
  ) and coalesce(current_setting('app.registro_avance', true), 'off') <> 'on' then
    raise exception 'Registra los avances mediante el formulario de bitácora.';
  end if;

  if public.mi_rol() = 'secretaria' and (
    new.porcentaje_avance is distinct from old.porcentaje_avance or new.estado is distinct from old.estado
  ) then raise exception 'Secretaría no puede modificar avances ni estados operativos.'; end if;
  new.updated_at=now();
  return new;
end; $$;

-- 2) Asignaciones históricas: no se permite borrar ni reescribir quién estuvo asignado.
drop policy if exists asignaciones_admin_all on public.area_responsables;
create policy asignaciones_admin_select on public.area_responsables
  for select to authenticated using (true);
create policy asignaciones_admin_insert on public.area_responsables
  for insert to authenticated with check (public.es_admin());
create policy asignaciones_admin_update on public.area_responsables
  for update to authenticated using (public.es_admin()) with check (public.es_admin());

create or replace function public.proteger_historial_asignacion() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'El historial de responsables no se elimina; cierre la asignación.'; end if;
  if new.area_id is distinct from old.area_id or new.usuario_id is distinct from old.usuario_id
     or new.asignado_desde is distinct from old.asignado_desde or new.created_by is distinct from old.created_by then
    raise exception 'No se puede reescribir una asignación histórica. Cierre y cree una nueva.';
  end if;
  return new;
end; $$;
drop trigger if exists area_responsables_inmutables on public.area_responsables;
create trigger area_responsables_inmutables before update or delete on public.area_responsables
for each row execute function public.proteger_historial_asignacion();

-- 3) Registro de auditoría administrativa para cambios de áreas, usuarios y asignaciones.
create table if not exists public.auditoria_administrativa (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.usuarios(id),
  entidad text not null,
  entidad_id text not null,
  accion text not null,
  datos_anteriores jsonb,
  datos_nuevos jsonb,
  created_at timestamptz not null default now()
);
alter table public.auditoria_administrativa enable row level security;
drop policy if exists auditoria_admin_read on public.auditoria_administrativa;
create policy auditoria_admin_read on public.auditoria_administrativa
  for select to authenticated using (public.es_admin());

create or replace function public.auditar_cambio_administrativo() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_id text; v_old jsonb; v_new jsonb; v_action text;
begin
  if tg_op='INSERT' then v_new=to_jsonb(new); v_id=coalesce(v_new->>'id',v_new->>'usuario_id'); v_action='INSERT';
  elsif tg_op='UPDATE' then v_old=to_jsonb(old); v_new=to_jsonb(new); v_id=coalesce(v_new->>'id',v_new->>'usuario_id'); v_action='UPDATE';
  else v_old=to_jsonb(old); v_id=coalesce(v_old->>'id',v_old->>'usuario_id'); v_action='DELETE'; end if;
  insert into public.auditoria_administrativa(actor_id,entidad,entidad_id,accion,datos_anteriores,datos_nuevos)
  values(auth.uid(),tg_table_name,v_id,v_action,v_old,v_new);
  if tg_op='DELETE' then return old; else return new; end if;
end; $$;

drop trigger if exists auditoria_areas on public.areas;
create trigger auditoria_areas after insert or update on public.areas for each row execute function public.auditar_cambio_administrativo();
drop trigger if exists auditoria_usuarios on public.usuarios;
create trigger auditoria_usuarios after insert or update on public.usuarios for each row execute function public.auditar_cambio_administrativo();
drop trigger if exists auditoria_asignaciones on public.area_responsables;
create trigger auditoria_asignaciones after insert or update on public.area_responsables for each row execute function public.auditar_cambio_administrativo();

-- La auditoría administrativa tampoco puede alterarse desde el cliente.
create or replace function public.bloquear_edicion_auditoria() returns trigger language plpgsql as $$
begin raise exception 'El registro de auditoría es inmutable.'; end; $$;
drop trigger if exists auditoria_solo_append on public.auditoria_administrativa;
create trigger auditoria_solo_append before update or delete on public.auditoria_administrativa
for each row execute function public.bloquear_edicion_auditoria();

-- 4) RPC endurecida: exige causa raíz y plan cuando el responsable declara bloqueo/riesgo.
create or replace function public.registrar_avance(
 p_objetivo uuid, p_porcentaje numeric, p_horas numeric, p_comentario text,
 p_causa_raiz text default null, p_plan_accion text default null, p_evidencia_url text default null,
 p_estado public.objective_status default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_old numeric; v_status public.objective_status; v_log uuid; v_deadline date;
begin
 if public.mi_rol()<>'jefe_area' then raise exception 'Solo jefes de área pueden registrar avances.'; end if;
 if not public.puede_ver_objetivo(p_objetivo) then raise exception 'No tienes asignación en un área vinculada a este objetivo.'; end if;
 if p_porcentaje is null or p_porcentaje<0 or p_porcentaje>100 or p_horas is null or p_horas<0
    or length(trim(coalesce(p_comentario,'')))=0 then raise exception 'Datos de avance inválidos.'; end if;
 select porcentaje_avance,fecha_limite into v_old,v_deadline from public.objetivos where id=p_objetivo and activo=true for update;
 if not found then raise exception 'Objetivo inexistente o inactivo.'; end if;
 v_status:=coalesce(p_estado,case when p_porcentaje=100 then 'concluido_pendiente_validacion'::public.objective_status when p_porcentaje>0 then 'en_proceso'::public.objective_status else 'no_iniciado'::public.objective_status end);
 if p_porcentaje=100 and v_status<>'concluido_pendiente_validacion' then raise exception 'Al alcanzar 100%%, el objetivo debe quedar pendiente de validación presidencial.'; end if;
 if v_status='concluido_pendiente_validacion' and p_porcentaje<100 then raise exception 'Para solicitar validación, el avance debe ser 100%%.'; end if;
 if (v_status='en_riesgo' or (current_date>v_deadline and p_porcentaje<100)) and
    (length(trim(coalesce(p_causa_raiz,'')))=0 or length(trim(coalesce(p_plan_accion,'')))=0) then
   raise exception 'En situación de riesgo o vencimiento, causa raíz y plan de acción son obligatorios.';
 end if;
 insert into public.bitacora_avances(objetivo_id,usuario_id,porcentaje_anterior,porcentaje_nuevo,horas_ejecutadas,comentario,causa_raiz,plan_accion,evidencia_url)
 values(p_objetivo,auth.uid(),v_old,p_porcentaje,p_horas,trim(p_comentario),nullif(trim(p_causa_raiz),''),nullif(trim(p_plan_accion),''),nullif(trim(p_evidencia_url),'')) returning id into v_log;
 perform set_config('app.registro_avance','on',true);
 update public.objetivos set porcentaje_avance=p_porcentaje,estado=v_status,
  fecha_finalizacion_real=case when p_porcentaje=100 then coalesce(fecha_finalizacion_real,now()) else null end,
  updated_at=now() where id=p_objetivo;
 perform set_config('app.registro_avance','off',true);
 return v_log;
exception when others then
 perform set_config('app.registro_avance','off',true);
 raise;
end; $$;
revoke all on function public.registrar_avance(uuid,numeric,numeric,text,text,text,text,public.objective_status) from public;
grant execute on function public.registrar_avance(uuid,numeric,numeric,text,text,text,text,public.objective_status) to authenticated;

-- 5) Funciones administrativas de invitación se implementan en Edge Function,
-- nunca exponiendo SUPABASE_SERVICE_ROLE_KEY al navegador.
