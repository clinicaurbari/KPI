# Sistema de Gestión del Comité Operativo – Clínica Urbarí

Aplicación web empresarial en español, construida con Next.js + TypeScript + Supabase (PostgreSQL/Auth/RLS/Edge Functions), preparada para desplegar en Vercel.

## Funcionalidades incluidas

- Login con Supabase Auth.
- Dashboard ejecutivo conectado a PostgreSQL.
- Indicadores globales, comparativo dinámico por área y ranking.
- Tablero de objetivos con filtros por área, estado y semáforo.
- Creación de objetivos reservada a Presidencia.
- Registro transaccional de avances por RPC, horas ejecutadas, comentario, causa raíz, plan de acción y enlace de evidencia.
- Gestión de áreas: alta y activación/desactivación sin borrar historial.
- Directorio de usuarios e invitación por correo mediante Edge Function (sin exponer la clave `service_role` al navegador).
- Generador inicial de actas y vista imprimible/guardar como PDF desde el navegador.
- Bitácora inmutable y auditoría administrativa.

## Arquitectura de despliegue elegida

- **Frontend:** Vercel.
- **Backend, Auth y PostgreSQL:** Supabase.
- **Acceso:** internet, con credenciales individuales.
- **Seguridad:** RBAC + RLS + validaciones en funciones PostgreSQL y Edge Functions.

## Requisitos

- Node.js 20 o superior.
- Cuenta de Supabase y proyecto creado.
- Cuenta de Vercel.
- Supabase CLI para desplegar Edge Functions.

## 1. Crear el proyecto Supabase

1. Crear un proyecto en https://supabase.com.
2. Guardar la URL del proyecto y la clave pública `anon` (nunca compartir ni publicar la `service_role`).
3. En **SQL Editor**, ejecutar primero `supabase/schema.sql`.
4. Ejecutar después `supabase/migrations/20261123_hardening.sql`.
5. En **Authentication → Providers**, habilitar Email.
6. Configurar SMTP institucional antes de invitar usuarios a producción. El correo SMTP predeterminado de pruebas de Supabase tiene limitaciones.
7. En **Authentication → URL Configuration**, definir el dominio de producción de Vercel como Site URL y agregar los redirect URLs de producción y pruebas.
8. En **Storage**, crear un bucket privado `evidencias-comite` si se habilitará carga de archivos. Las políticas de Storage deben permitir acceso solo a usuarios autenticados y vinculados al objetivo; no usar bucket público para documentación interna.

## 2. Configuración de usuarios iniciales

Crear/invitar cuentas para Klever, Jefatura de RRHH, Viviana, Wendy, Rafael, Cristian y Mauricio. No se incluyen correos ni contraseñas ficticias.

El trigger crea cada perfil con rol inicial `jefe_area`. Después de crear las cuentas, ejecutar en SQL Editor sustituyendo los correos reales:

```sql
update public.usuarios set nombre='Klever Leaños', rol='presidente' where email='CORREO_KLEVER';
update public.usuarios set nombre='Jefatura de RRHH', rol='secretaria' where email='CORREO_RRHH';

insert into public.area_responsables(area_id, usuario_id, es_principal)
select a.id, u.id, true
from public.areas a
join public.usuarios u on
 (a.nombre='Tesorería' and u.email='CORREO_VIVIANA') or
 (a.nombre='Liquidaciones' and u.email='CORREO_WENDY') or
 (a.nombre='Contabilidad' and u.email='CORREO_RAFAEL') or
 (a.nombre='Compras y Logística' and u.email='CORREO_CRISTIAN') or
 (a.nombre='Sistemas' and u.email='CORREO_MAURICIO');
```

Verificar que cada consulta inserte/asigne exactamente los perfiles esperados. La primera cuenta de Presidencia debe configurarse manualmente por el propietario del proyecto antes de abrir el acceso general.

## 3. Desplegar Edge Function de invitación

La creación de identidades Auth requiere privilegios administrativos; por seguridad se ejecuta en Supabase Edge Functions y nunca desde el navegador.

Desde la raíz del proyecto:

```bash
supabase login
supabase link --project-ref TU_PROJECT_REF
supabase secrets set APP_ORIGIN=https://TU-DOMINIO.vercel.app
supabase secrets set INVITE_REDIRECT_URL=https://TU-DOMINIO.vercel.app
supabase functions deploy admin-invite-user
```

Supabase provee `SUPABASE_URL`, `SUPABASE_ANON_KEY` y `SUPABASE_SERVICE_ROLE_KEY` al entorno de Edge Functions. No copiar `SUPABASE_SERVICE_ROLE_KEY` a Vercel ni a variables `NEXT_PUBLIC_*`.

La Edge Function valida el JWT del solicitante y el rol institucional. Presidencia puede invitar los tres roles; Secretaría solo puede invitar jefaturas. Las jefaturas deben quedar vinculadas al menos a un área activa.

## 4. Configurar y ejecutar localmente

Copiar `.env.example` a `.env.local` y completar:

```env
NEXT_PUBLIC_SUPABASE_URL=https://TU-PROYECTO.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=TU_SUPABASE_ANON_KEY
```

Luego:

```bash
npm install
npm run dev
```

Abrir http://localhost:3000.

## 5. Desplegar en Vercel

1. Subir el contenido del proyecto a un repositorio privado de GitHub institucional.
2. En https://vercel.com, importar ese repositorio.
3. Configurar las variables `NEXT_PUBLIC_SUPABASE_URL` y `NEXT_PUBLIC_SUPABASE_ANON_KEY` en Production, Preview y Development según corresponda.
4. Ejecutar Deploy.
5. Agregar el dominio definitivo en Vercel y registrar ese dominio en Supabase Auth URL Configuration y en `APP_ORIGIN` / `INVITE_REDIRECT_URL` de la Edge Function.
6. Volver a desplegar la Edge Function tras modificar sus secretos.

## 6. Roles y permisos

- `presidente`: administra áreas, invita usuarios, crea objetivos, define metas y plazos, modifica planificación, valida y cierra objetivos, consulta analíticas.
- `secretaria`: consulta el tablero, administra áreas y directorio, invita jefes de área y genera actas; no puede modificar planificación ni avances.
- `jefe_area`: consulta el tablero global y registra avances solo en objetivos vinculados a sus áreas asignadas. El avance debe registrarse mediante `registrar_avance()`; las modificaciones directas quedan bloqueadas.

## 7. Reglas de control y auditoría

- La bitácora de avances es append-only: no permite UPDATE ni DELETE.
- Los cambios de áreas, usuarios y asignaciones generan auditoría administrativa.
- Las asignaciones históricas no se borran ni se reescriben: se cierra `asignado_hasta` y se crea una nueva asignación.
- La función `registrar_avance` registra bitácora y actualiza el objetivo de forma transaccional.
- Para riesgo/bloqueo o un objetivo vencido, la causa raíz y el plan de acción son obligatorios.
- La función `validar_objetivo` reserva el cierre definitivo a Presidencia.
- `horas_ejecutadas` suma horas reportadas; no se infiere del porcentaje.
- `dias_transcurridos` mide tiempo calendario desde el inicio hasta hoy o la fecha real de finalización.

## 8. Antes de producción: checklist obligatorio

- [ ] Ejecutar schema y migración en Supabase de pruebas.
- [ ] Configurar SMTP institucional y probar invitaciones/recuperación de contraseña.
- [ ] Verificar los correos y UUID reales de los siete perfiles iniciales.
- [ ] Probar RLS con una cuenta de cada rol y comprobar acceso cruzado entre áreas.
- [ ] Probar que un jefe no pueda cambiar plazos, metas, áreas ni avance directo por API.
- [ ] Probar que Secretaría no pueda editar metas ni plazos.
- [ ] Probar la validación y cierre por Presidencia.
- [ ] Configurar backups automáticos, monitoreo y política de retención.
- [ ] Definir política institucional de evidencias y datos personales.
- [ ] Ejecutar revisión de seguridad independiente antes de habilitar datos reales.

## Estado de esta entrega

Se amplió la base inicial con administración de áreas, directorio e invitación segura de usuarios, Edge Function de invitación y migración de endurecimiento RLS/auditoría. No se ha conectado a un proyecto Supabase real ni desplegado en Vercel: esas acciones requieren que Clínica Urbarí cree y controle sus propias cuentas y dominios. La compilación de producción debe ejecutarse en el entorno con dependencias instaladas antes de autorizar el uso institucional.
