import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'Método no permitido' }), { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });

  try {
    const { data: { user: caller }, error: authError } = await callerClient.auth.getUser();
    if (authError || !caller) throw new Error('Sesión no válida.');
    const { data: actor, error: actorError } = await admin.from('usuarios').select('rol,activo').eq('id', caller.id).single();
    if (actorError || !actor?.activo || !['presidente', 'secretaria'].includes(actor.rol)) throw new Error('No tienes permisos para administrar usuarios.');

    const body = await req.json();
    const nombre = String(body.nombre ?? '').trim();
    const email = String(body.email ?? '').trim().toLowerCase();
    const rol = String(body.rol ?? 'jefe_area');
    const areaIds = Array.isArray(body.areaIds) ? body.areaIds.map(String) : [];
    if (!nombre || !email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw new Error('Nombre y correo válido son obligatorios.');
    if (!['presidente', 'secretaria', 'jefe_area'].includes(rol)) throw new Error('Rol inválido.');
    if (actor.rol === 'secretaria' && rol !== 'jefe_area') throw new Error('Secretaría solo puede invitar usuarios con rol Jefe de Área.');
    if (rol === 'jefe_area' && areaIds.length === 0) throw new Error('Asigna al menos un área al jefe de área.');

    if (areaIds.length) {
      const { data: areas, error: areaError } = await admin.from('areas').select('id').in('id', areaIds).eq('activa', true);
      if (areaError || (areas?.length ?? 0) !== new Set(areaIds).size) throw new Error('Una o más áreas no existen o están inactivas.');
    }

    const redirectTo = Deno.env.get('INVITE_REDIRECT_URL');
    const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { nombre }, ...(redirectTo ? { redirectTo } : {}),
    });
    if (inviteError || !invited.user) throw new Error(inviteError?.message ?? 'No se pudo enviar la invitación.');

    const userId = invited.user.id;
    const { error: profileError } = await admin.from('usuarios').upsert({ id: userId, nombre, email, rol, activo: true });
    if (profileError) {
      await admin.auth.admin.deleteUser(userId);
      throw new Error(`No se pudo crear el perfil: ${profileError.message}`);
    }

    if (areaIds.length) {
      const rows = areaIds.map((area_id: string, index: number) => ({ area_id, usuario_id: userId, es_principal: index === 0, created_by: caller.id }));
      const { error: assignmentError } = await admin.from('area_responsables').insert(rows);
      if (assignmentError) {
        await admin.auth.admin.deleteUser(userId);
        throw new Error(`No se pudieron asignar las áreas: ${assignmentError.message}`);
      }
    }

    return new Response(JSON.stringify({ ok: true, userId, message: 'Invitación enviada por correo.' }), { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Error inesperado.' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});
