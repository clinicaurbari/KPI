-- Sistema de Gestión del Comité Operativo – Clínica Urbarí
-- Ejecutar en Supabase SQL Editor con una cuenta de propietario del proyecto.
create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('presidente','secretaria','jefe_area');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.objective_status as enum ('no_iniciado','en_proceso','en_riesgo','concluido_pendiente_validacion','validado_cerrado');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.priority_level as enum ('critica','alta','media');
exception when duplicate_object then null; end $$;

create table if not exists public.usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  email text not null unique,
  rol public.app_role not null default 'jefe_area',
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.areas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  codigo text not null unique,
  color text not null default '#2878A8',
  descripcion text,
  activa boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.area_responsables (
  id uuid primary key default gen_random_uuid(),
  area_id uuid not null references public.areas(id),
  usuario_id uuid not null references public.usuarios(id),
  es_principal boolean not null default false,
  asignado_desde timestamptz not null default now(),
  asignado_hasta timestamptz,
  created_by uuid references public.usuarios(id),
  unique(area_id, usuario_id, asignado_desde)
);
create unique index if not exists one_active_primary_per_area on public.area_responsables(area_id) where es_principal and asignado_hasta is null;
create table if not exists public.objetivos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  descripcion text not null,
  area_principal_id uuid not null references public.areas(id),
  prioridad public.priority_level not null default 'media',
  kpi_meta text,
  meta_valor numeric,
  meta_unidad text,
  fecha_inicio date not null,
  fecha_limite date not null,
  porcentaje_avance numeric(5,2) not null default 0 check (porcentaje_avance between 0 and 100),
  estado public.objective_status not null default 'no_iniciado',
  fecha_finalizacion_real timestamptz,
  creado_por uuid not null references public.usuarios(id),
  validado_por uuid references public.usuarios(id),
  validado_en timestamptz,
  activo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (fecha_limite >= fecha_inicio)
);
create table if not exists public.objetivo_areas_apoyo (
  objetivo_id uuid not null references public.objetivos(id) on delete cascade,
  area_id uuid not null references public.areas(id),
  primary key(objetivo_id, area_id)
);
create table if not exists public.bitacora_avances (
  id uuid primary key default gen_random_uuid(),
  objetivo_id uuid not null references public.objetivos(id),
  usuario_id uuid not null references public.usuarios(id),
  tipo_evento text not null default 'avance',
  porcentaje_anterior numeric(5,2),
  porcentaje_nuevo numeric(5,2),
  horas_ejecutadas numeric(10,2) not null default 0 check (horas_ejecutadas >= 0),
  comentario text not null,
  causa_raiz text,
  plan_accion text,
  evidencia_url text,
  created_at timestamptz not null default now()
);
create table if not exists public.actas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null,
  fecha_reunion timestamptz not null default now(),
  periodo_desde date not null,
  periodo_hasta date not null,
  contenido jsonb not null default '{}'::jsonb,
  compromisos jsonb not null default '[]'::jsonb,
  generado_por uuid not null references public.usuarios(id),
  created_at timestamptz not null default now(),
  check(periodo_hasta >= periodo_desde)
);

-- Perfil asociado automáticamente al usuario autenticado. El rol inicial se asigna por administrador.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.usuarios(id,nombre,email,rol)
  values(new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)), new.email, 'jefe_area')
  on conflict(id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.mi_rol() returns public.app_role language sql stable security definer set search_path=public as $$
 select rol from public.usuarios where id=auth.uid() and activo=true limit 1;
$$;
create or replace function public.es_admin() returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.mi_rol() in ('presidente','secretaria'),false);
$$;
create or replace function public.gestiona_area(p_area uuid) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.area_responsables ar join public.usuarios u on u.id=ar.usuario_id
 where ar.area_id=p_area and ar.usuario_id=auth.uid() and ar.asignado_hasta is null and u.activo=true);
$$;
create or replace function public.puede_ver_objetivo(p_objetivo uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.es_admin() or exists(select 1 from public.objetivos o where o.id=p_objetivo and
 (public.gestiona_area(o.area_principal_id) or exists(select 1 from public.objetivo_areas_apoyo oa where oa.objetivo_id=o.id and public.gestiona_area(oa.area_id))));
$$;

-- Inmutabilidad de bitácora: no se permite editar ni borrar eventos históricos.
create or replace function public.proteger_bitacora() returns trigger language plpgsql as $$
begin raise exception 'La bitácora es inmutable: no se permite modificar ni eliminar registros.'; end; $$;
drop trigger if exists bitacora_no_update on public.bitacora_avances;
create trigger bitacora_no_update before update or delete on public.bitacora_avances for each row execute function public.proteger_bitacora();

-- Solo Presidencia puede cambiar planificación, meta, prioridad y áreas del objetivo.
create or replace function public.proteger_planificacion() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if public.mi_rol() <> 'presidente' and (
  new.titulo is distinct from old.titulo or new.descripcion is distinct from old.descripcion or
  new.area_principal_id is distinct from old.area_principal_id or new.prioridad is distinct from old.prioridad or
  new.kpi_meta is distinct from old.kpi_meta or new.meta_valor is distinct from old.meta_valor or
  new.meta_unidad is distinct from old.meta_unidad or new.fecha_inicio is distinct from old.fecha_inicio or
  new.fecha_limite is distinct from old.fecha_limite or new.activo is distinct from old.activo
 ) then raise exception 'Solo Presidencia puede modificar la planificación y las metas.'; end if;
 if public.mi_rol() = 'secretaria' and (new.porcentaje_avance is distinct from old.porcentaje_avance or new.estado is distinct from old.estado) then
  raise exception 'Secretaría no puede modificar avances ni estados operativos.';
 end if;
 new.updated_at=now(); return new;
end; $$;
drop trigger if exists objetivos_proteger_plan on public.objetivos;
create trigger objetivos_proteger_plan before update on public.objetivos for each row execute function public.proteger_planificacion();

-- RLS
alter table public.usuarios enable row level security;
alter table public.areas enable row level security;
alter table public.area_responsables enable row level security;
alter table public.objetivos enable row level security;
alter table public.objetivo_areas_apoyo enable row level security;
alter table public.bitacora_avances enable row level security;
alter table public.actas enable row level security;

create policy usuarios_read on public.usuarios for select to authenticated using (true);
create policy usuarios_admin_insert on public.usuarios for insert to authenticated with check (public.mi_rol()='presidente');
create policy usuarios_admin_update on public.usuarios for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy areas_read on public.areas for select to authenticated using (true);
create policy areas_admin_insert on public.areas for insert to authenticated with check (public.es_admin());
create policy areas_admin_update on public.areas for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy asignaciones_read on public.area_responsables for select to authenticated using (true);
create policy asignaciones_admin_all on public.area_responsables for all to authenticated using (public.es_admin()) with check (public.es_admin());
create policy objetivos_read on public.objetivos for select to authenticated using (true);
create policy objetivos_presidente_insert on public.objetivos for insert to authenticated with check (public.mi_rol()='presidente' and creado_por=auth.uid());
create policy objetivos_update on public.objetivos for update to authenticated using (public.mi_rol()='presidente' or (public.mi_rol()='jefe_area' and public.gestiona_area(area_principal_id))) with check (public.mi_rol()='presidente' or (public.mi_rol()='jefe_area' and public.gestiona_area(area_principal_id)));
create policy apoyo_read on public.objetivo_areas_apoyo for select to authenticated using (true);
create policy apoyo_presidente_all on public.objetivo_areas_apoyo for all to authenticated using (public.mi_rol()='presidente') with check (public.mi_rol()='presidente');
create policy bitacora_read on public.bitacora_avances for select to authenticated using (public.puede_ver_objetivo(objetivo_id));
create policy bitacora_insert on public.bitacora_avances for insert to authenticated with check (usuario_id=auth.uid() and public.mi_rol()='jefe_area' and public.puede_ver_objetivo(objetivo_id));
create policy actas_read on public.actas for select to authenticated using (true);
create policy actas_insert on public.actas for insert to authenticated with check (public.es_admin() and generado_por=auth.uid());

-- Vista de métricas. Horas ejecutadas provienen de los registros acumulados en bitácora.
create or replace view public.v_objetivos_metricas with (security_invoker=true) as
select o.*, a.nombre as area_nombre, a.codigo as area_codigo, a.color as area_color,
 greatest(0, (o.fecha_limite-o.fecha_inicio))::numeric as dias_estimados,
 round(coalesce(sum(b.horas_ejecutadas),0),2) as horas_ejecutadas,
 case when o.fecha_finalizacion_real is not null then round(extract(epoch from (o.fecha_finalizacion_real::date-o.fecha_inicio::timestamp))/86400,2)
 else round(extract(epoch from (now()-o.fecha_inicio::timestamp))/86400,2) end as dias_transcurridos,
 max(b.created_at) as ultima_actualizacion,
 case when o.fecha_finalizacion_real is not null then
   case when extract(epoch from (o.fecha_finalizacion_real::date-o.fecha_inicio::timestamp))/86400 <= greatest(1,o.fecha_limite-o.fecha_inicio) then 'verde' else 'rojo' end
 when current_date > o.fecha_limite then 'rojo'
 when max(b.created_at) < now()-interval '7 days' or (max(b.created_at) is null and o.created_at < now()-interval '7 days') then 'amarillo'
 when o.porcentaje_avance < greatest(0, least(100, (current_date-o.fecha_inicio)::numeric/nullif((o.fecha_limite-o.fecha_inicio),0)*100))-15 then 'amarillo'
 else 'verde' end as semaforo,
 (case when o.fecha_finalizacion_real is not null then round(extract(epoch from (o.fecha_finalizacion_real::date-o.fecha_inicio::timestamp))/86400,2) else round(extract(epoch from (now()-o.fecha_inicio::timestamp))/86400,2) end - greatest(1,(o.fecha_limite-o.fecha_inicio))) as desviacion_dias,
 case when (case when o.fecha_finalizacion_real is not null then extract(epoch from (o.fecha_finalizacion_real::date-o.fecha_inicio::timestamp))/86400 else extract(epoch from (now()-o.fecha_inicio::timestamp))/86400 end) <= 0 then null
 else round((greatest(1,(o.fecha_limite-o.fecha_inicio))::numeric / nullif((case when o.fecha_finalizacion_real is not null then extract(epoch from (o.fecha_finalizacion_real::date-o.fecha_inicio::timestamp))/86400 else extract(epoch from (now()-o.fecha_inicio::timestamp))/86400 end),0))*100,2) end as eficiencia_tiempo_pct
from public.objetivos o join public.areas a on a.id=o.area_principal_id
left join public.bitacora_avances b on b.objetivo_id=o.id
group by o.id,a.id;

-- Datos iniciales. Ejecutar después de crear/invitar usuarios en Supabase Auth y completar sus UUID.
insert into public.areas(nombre,codigo,color,descripcion) values
 ('Tesorería','TES','#2477A8','Gestión de tesorería y flujo de fondos'),
 ('Liquidaciones','LIQ','#168B83','Liquidaciones y procesos de facturación'),
 ('Contabilidad','CON','#6B70B5','Registro contable y cierres'),
 ('Compras y Logística','LOG','#C18B35','Abastecimiento, compras y logística'),
 ('Sistemas','SIS','#66788A','Tecnología, sistemas y soporte')
on conflict(nombre) do nothing;

-- Recomendación: promover a Klever a presidente y a RRHH a secretaria desde SQL Editor
-- una vez que sus cuentas hayan sido creadas en Authentication > Users:
-- update public.usuarios set nombre='Klever Leaños', rol='presidente' where email='CORREO_KLEVER';
-- update public.usuarios set nombre='Jefatura de RRHH', rol='secretaria' where email='CORREO_RRHH';
-- Los responsables Viviana, Wendy, Rafael, Cristian y Mauricio se vinculan mediante area_responsables
-- usando los UUID de sus usuarios y el UUID de su área. No se inventan correos ni credenciales.

-- Registro transaccional de avance: admite al jefe del área principal o de apoyo.
-- Inserta bitácora y actualiza estado/porcentaje en una única operación.
create or replace function public.registrar_avance(
 p_objetivo uuid, p_porcentaje numeric, p_horas numeric, p_comentario text,
 p_causa_raiz text default null, p_plan_accion text default null, p_evidencia_url text default null,
 p_estado public.objective_status default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_old numeric; v_new_status public.objective_status; v_log uuid;
begin
 if public.mi_rol()<>'jefe_area' then raise exception 'Solo jefes de área pueden registrar avances.'; end if;
 if not public.puede_ver_objetivo(p_objetivo) then raise exception 'No tienes asignación en un área vinculada a este objetivo.'; end if;
 if p_porcentaje<0 or p_porcentaje>100 or p_horas<0 or length(trim(coalesce(p_comentario,'')))=0 then raise exception 'Datos de avance inválidos.'; end if;
 select porcentaje_avance into v_old from public.objetivos where id=p_objetivo for update;
 v_new_status:=coalesce(p_estado,case when p_porcentaje=100 then 'concluido_pendiente_validacion'::public.objective_status when p_porcentaje>0 then 'en_proceso'::public.objective_status else 'no_iniciado'::public.objective_status end);
 insert into public.bitacora_avances(objetivo_id,usuario_id,porcentaje_anterior,porcentaje_nuevo,horas_ejecutadas,comentario,causa_raiz,plan_accion,evidencia_url)
 values(p_objetivo,auth.uid(),v_old,p_porcentaje,p_horas,trim(p_comentario),p_causa_raiz,p_plan_accion,p_evidencia_url) returning id into v_log;
 update public.objetivos set porcentaje_avance=p_porcentaje, estado=v_new_status,
 fecha_finalizacion_real=case when p_porcentaje=100 then coalesce(fecha_finalizacion_real,now()) else null end,
 updated_at=now() where id=p_objetivo;
 return v_log;
end; $$;
grant execute on function public.registrar_avance(uuid,numeric,numeric,text,text,text,text,public.objective_status) to authenticated;

-- Trazabilidad automática de creación y cambios en la ficha del objetivo.
create or replace function public.auditar_objetivo() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='INSERT' then
  insert into public.bitacora_avances(objetivo_id,usuario_id,tipo_evento,comentario)
  values(new.id,coalesce(auth.uid(),new.creado_por),'creacion','Objetivo creado: '||new.titulo);
  return new;
 elsif tg_op='UPDATE' then
  if row(new.titulo,new.descripcion,new.area_principal_id,new.prioridad,new.kpi_meta,new.meta_valor,new.meta_unidad,new.fecha_inicio,new.fecha_limite,new.activo)
     is distinct from row(old.titulo,old.descripcion,old.area_principal_id,old.prioridad,old.kpi_meta,old.meta_valor,old.meta_unidad,old.fecha_inicio,old.fecha_limite,old.activo) then
   insert into public.bitacora_avances(objetivo_id,usuario_id,tipo_evento,comentario)
   values(new.id,coalesce(auth.uid(),new.creado_por),'modificacion_plan','Planificación del objetivo modificada por usuario autorizado');
  end if;
  return new;
 end if;
 return null;
end; $$;
drop trigger if exists objetivos_auditoria on public.objetivos;
create trigger objetivos_auditoria after insert or update on public.objetivos for each row execute function public.auditar_objetivo();

-- Validación y cierre exclusivo de Presidencia.
create or replace function public.validar_objetivo(p_objetivo uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 if public.mi_rol()<>'presidente' then raise exception 'Solo Presidencia puede validar y cerrar objetivos.'; end if;
 update public.objetivos set estado='validado_cerrado',validado_por=auth.uid(),validado_en=now(),porcentaje_avance=100,
 fecha_finalizacion_real=coalesce(fecha_finalizacion_real,now()),updated_at=now()
 where id=p_objetivo and estado='concluido_pendiente_validacion';
 if not found then raise exception 'El objetivo no está pendiente de validación.'; end if;
 insert into public.bitacora_avances(objetivo_id,usuario_id,tipo_evento,porcentaje_anterior,porcentaje_nuevo,comentario)
 values(p_objetivo,auth.uid(),'validacion',100,100,'Objetivo validado y cerrado por Presidencia');
end; $$;
grant execute on function public.validar_objetivo(uuid) to authenticated;

-- Evita escalamiento de privilegios: Secretaría puede mantener el directorio, pero solo Presidencia cambia roles.
create or replace function public.proteger_rol_usuario() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.rol is distinct from old.rol and public.mi_rol()<>'presidente' then
  raise exception 'Solo Presidencia puede asignar o modificar roles del sistema.';
 end if;
 new.updated_at=now();
 return new;
end; $$;
drop trigger if exists usuarios_proteger_rol on public.usuarios;
create trigger usuarios_proteger_rol before update on public.usuarios for each row execute function public.proteger_rol_usuario();
