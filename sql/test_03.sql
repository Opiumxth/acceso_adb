set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 200
set feedback off
whenever sqlerror continue

-- =====================================================================
-- test_03.sql - Pruebas de los procedimientos de 03_procedimientos.sql
--
-- Ejecutar como ACCESO_OWNER sobre datos recien cargados (99_reset + 01 + 02):
--   docker cp sql/test_03.sql oracle-xe:/tmp/test_03.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/test_03.sql
--
-- La prueba modifica datos (asistencias de la sesion 900, faltas, personas de
-- prueba). Para repetirla hay que recargar la base. Las ventanas horarias de
-- los estudiantes se abren todo el dia al inicio, para que el resultado no
-- dependa de la hora de ejecucion, y se restauran al final.
-- =====================================================================

column resultado format a10
column motivo    format a22
column id_acceso format 99999
column nombre    format a26
column codigo    format a9
column estado    format a13
column tipo      format a28
column gravedad  format a9
column origen    format a10
column descripcion format a70
column hora      format a9
column inicio    format a17
column accion    format a12

variable r    varchar2(20)
variable m    varchar2(40)
variable id   number
variable n    varchar2(100)
variable t    varchar2(20)
variable e    varchar2(20)
variable x    number
variable falt number
variable inh  number
variable ip   number
variable ir   number
variable ipase number
variable ii   number
variable acc  varchar2(20)
variable c    refcursor
variable t0   varchar2(30)

prompt
prompt =====================================================================
prompt 0. PREPARACION
prompt =====================================================================
-- instante de inicio: el resumen final cuenta solo lo generado por esta prueba
exec :t0 := to_char(systimestamp, 'YYYY-MM-DD HH24:MI:SS')
select to_char(sysdate, 'YYYY-MM-DD HH24:MI:SS') as hora_servidor,
       to_char(systimestamp at time zone 'America/Lima', 'HH24:MI') as hora_lima
  from dual;

-- ventanas de estudiantes y docentes abiertas todo el dia (se restauran al final)
update permisos_zona set hora_desde = '00:00', hora_hasta = '23:59'
 where tipo_persona in ('estudiante', 'docente');
-- el pase del visitante 30 (99000001) se deja vigente ahora, solo biblioteca
update pases
   set vigente_desde = systimestamp - interval '1' hour,
       vigente_hasta = systimestamp + interval '1' day
 where id_visitante = 30 and estado = 'activo';
commit;

prompt
prompt =====================================================================
prompt 1. p_verificar_persona
prompt =====================================================================
prompt -- 1.1 codigo existente (25200001): debe existir = 1
exec p_verificar_persona('25200001', :n, :t, :e, :x)
select :n as nombre, :t as tipo, :e as estado, :x as existe from dual;
prompt -- 1.2 codigo inexistente (00000000): existe = 0 (no es error)
exec p_verificar_persona('00000000', :n, :t, :e, :x)
select :n as nombre, :t as tipo, :e as estado, :x as existe from dual;

prompt
prompt =====================================================================
prompt 2. p_registrar_acceso - DENEGACIONES (no son errores)
prompt =====================================================================
prompt -- 2.1 00000000 en la puerta (punto 1): codigo_inexistente, id_persona nulo
exec p_registrar_acceso('00000000', 1, 1, 30, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select id_acceso, id_persona, codigo_leido, resultado, motivo from accesos where id_acceso = :id;

prompt -- 2.2 25200009 (estado inactivo) en la puerta: persona_inactiva
exec p_registrar_acceso('25200009', 1, 1, 22, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 2.3 25200003 con rostro que no coincide (rostro_ok = 0): rostro_no_coincide
exec p_registrar_acceso('25200003', 1, 0, 68.5, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 2.4 25200010 (restriccion vigente): persona_restringida + incidencia alta
exec p_registrar_acceso('25200010', 1, 1, 23, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select i.id_incidencia, i.tipo, i.gravedad, i.estado, i.origen
  from incidencias i
 where i.id_acceso = :id;

prompt -- 2.5 estudiante 25200001 en Administracion (punto 7): zona_no_autorizada
exec p_registrar_acceso('25200001', 7, 1, 20, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 2.6 ventana del estudiante en la puerta fuera de la hora actual: fuera_de_horario
declare
    v_hora varchar2(5);
begin
    v_hora := to_char(systimestamp at time zone f_parametro('ZONA_HORARIA'), 'HH24:MI');
    if v_hora < '12:00' then
        update permisos_zona set hora_desde = '23:00', hora_hasta = '23:59'
         where tipo_persona = 'estudiante' and id_zona = 1;
    else
        update permisos_zona set hora_desde = '00:00', hora_hasta = '01:00'
         where tipo_persona = 'estudiante' and id_zona = 1;
    end if;
    commit;
    dbms_output.put_line('Hora local ' || v_hora || ': ventana de la puerta movida fuera de la hora actual');
end;
/
exec p_registrar_acceso('25200001', 1, 1, 20, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
update permisos_zona set hora_desde = '00:00', hora_hasta = '23:59'
 where tipo_persona = 'estudiante' and id_zona = 1;
commit;

prompt
prompt =====================================================================
prompt 3. p_registrar_acceso - VISITANTES
prompt =====================================================================
prompt -- 3.1 99000001 en la puerta (cualquier pase vale): permitido
exec p_registrar_acceso('99000001', 1, 1, 21, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 3.2 99000001 en el aula A-101 (punto 4, su pase es de la biblioteca): sin_pase_vigente
exec p_registrar_acceso('99000001', 4, 1, 21, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 3.3 99000001 en la biblioteca (punto 3, pase de esa zona): permitido
exec p_registrar_acceso('99000001', 3, 1, 21, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 3.4 99000002 en la puerta (su pase esta vencido): sin_pase_vigente
exec p_registrar_acceso('99000002', 1, 1, 26, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt
prompt =====================================================================
prompt 4. ASISTENCIA (sesion 900, seccion 1, aula A-101 = punto 4)
prompt =====================================================================
prompt -- 4.1 sesion 900 programada que inicia en 3 minutos; el docente 10000001 entra
update sesiones
   set hora_inicio = systimestamp + interval '3' minute,
       hora_fin    = systimestamp + interval '93' minute,
       estado      = 'programada'
 where id_sesion = 900;
commit;
exec p_registrar_acceso('10000001', 4, 1, 18, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select id_sesion, estado from sesiones where id_sesion = 900;

prompt -- 4.2 sesion 900 movida a "ahora" (empezo hace 5 min); entra 25200001
update sesiones
   set hora_inicio = systimestamp - interval '5' minute,
       hora_fin    = systimestamp + interval '85' minute,
       estado      = 'en_curso'
 where id_sesion = 900;
commit;
exec p_registrar_acceso('25200001', 4, 1, 24.5, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select p.codigo, a.estado, to_char(a.hora_registro, 'HH24:MI:SS') as hora, a.id_acceso
  from asistencias a join personas p on p.id_persona = a.id_estudiante
 where a.id_sesion = 900
 order by p.codigo;

prompt -- 4.3 repetir con 25200001: permitido, pero NO se duplica la asistencia
exec p_registrar_acceso('25200001', 4, 1, 24.5, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select count(*) as filas_25200001_en_sesion_900
  from asistencias a join personas p on p.id_persona = a.id_estudiante
 where a.id_sesion = 900 and p.codigo = '25200001';

prompt -- 4.4 la sesion pasa a 20 minutos de retraso; entra 25200002: tardanza
update sesiones
   set hora_inicio = systimestamp - interval '20' minute,
       hora_fin    = systimestamp + interval '70' minute
 where id_sesion = 900;
commit;
exec p_registrar_acceso('25200002', 4, 1, 25, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 4.5 25200001 vuelve a pasar con 20 min de retraso: no se degrada a tardanza
exec p_registrar_acceso('25200001', 4, 1, 24.5, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 4.6 25200007 (no inscrito en la seccion 1) en el punto 4: permitido sin asistencia
exec p_registrar_acceso('25200007', 4, 1, 27, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 4.7 asistencias de la sesion 900 hasta ahora (solo 25200001 y 25200002)
select p.codigo, a.estado, to_char(a.hora_registro, 'HH24:MI:SS') as hora, a.id_acceso
  from asistencias a join personas p on p.id_persona = a.id_estudiante
 where a.id_sesion = 900
 order by p.codigo;

prompt
prompt =====================================================================
prompt 5. INTENTOS REITERADOS (codigo 12345678, 3 denegados seguidos en la puerta)
prompt =====================================================================
prompt -- 5.1 primer intento: sin incidencia
exec p_registrar_acceso('12345678', 1, 1, null, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 5.2 segundo intento: sin incidencia
exec p_registrar_acceso('12345678', 1, 1, null, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 5.3 tercer intento: se crea la incidencia intentos_reiterados (media)
exec p_registrar_acceso('12345678', 1, 1, null, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
prompt -- 5.4 cuarto intento: no se duplica la incidencia abierta
exec p_registrar_acceso('12345678', 1, 1, null, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select id_incidencia, tipo, gravedad, estado, origen, descripcion
  from incidencias
 where instr(descripcion, '[12345678]') > 0;

prompt
prompt =====================================================================
prompt 6. p_cerrar_sesion
prompt =====================================================================
prompt -- 6.1 cerrar la sesion 900: falta para los inscritos activos sin asistencia
prompt --     (S1: 25200001 y 25200002 asistieron; 25200004 esta inhabilitado)
exec p_cerrar_sesion(900, :falt, :inh)
select :falt as o_faltas, :inh as o_inhabilitados from dual;
select p.codigo, a.estado, to_char(a.hora_registro, 'HH24:MI:SS') as hora
  from asistencias a join personas p on p.id_persona = a.id_estudiante
 where a.id_sesion = 900
 order by p.codigo;
select p.codigo, p.nombre, i.faltas, i.estado
  from inscripciones i join personas p on p.id_persona = i.id_estudiante
 where i.id_seccion = 1
 order by p.codigo;

prompt -- 6.2 sesion extra 901 (cerrada sin asistencias): 25200005 llega a 3 faltas
prompt --     de 8 sesiones (37.5 por ciento >= 30) y queda inhabilitado
insert into sesiones (id_sesion, id_seccion, hora_inicio, hora_fin, estado)
values (901, 1, systimestamp - interval '3' hour, systimestamp - interval '90' minute, 'en_curso');
commit;
exec p_cerrar_sesion(901, :falt, :inh)
select :falt as o_faltas, :inh as o_inhabilitados from dual;
select p.codigo, p.nombre, i.faltas, i.estado
  from inscripciones i join personas p on p.id_persona = i.id_estudiante
 where i.id_seccion = 1
 order by p.codigo;

prompt -- 6.3 cerrar otra vez la sesion 900: error esperado ORA-20003
declare
    v_f number; v_i number;
begin
    p_cerrar_sesion(900, v_f, v_i);
    dbms_output.put_line('ERROR: debio fallar');
exception
    when others then
        dbms_output.put_line('Error esperado -> ' || sqlerrm);
end;
/

prompt
prompt =====================================================================
prompt 7. SEGURIDAD Y ADMINISTRACION
prompt =====================================================================
prompt -- 7.1 p_registrar_persona: estudiante nuevo 25200012 (personas + estudiantes)
exec p_registrar_persona('25200012', 'Persona de Prueba', '75000099', 'prueba@campus.test', 'estudiante', 1, 3, null, :ip)
select :ip as id_persona_nueva from dual;
select p.id_persona, p.codigo, p.nombre, p.tipo, p.estado, s.id_escuela, s.ciclo
  from personas p join estudiantes s on s.id_estudiante = p.id_persona
 where p.codigo = '25200012';

prompt -- 7.2 codigo repetido: error esperado ORA-20005
declare
    v_id number;
begin
    p_registrar_persona('25200012', 'Otra Persona', '75000098', null, 'visitante', null, null, null, v_id);
    dbms_output.put_line('ERROR: debio fallar');
exception
    when others then
        dbms_output.put_line('Error esperado -> ' || sqlerrm);
end;
/

prompt -- 7.3 p_modificar_persona: cambia nombre y correo
exec p_modificar_persona('25200012', p_nombre => 'Persona Modificada', p_correo => 'modificada@campus.test')
select codigo, nombre, correo, estado from personas where codigo = '25200012';

prompt -- 7.4 p_buscar_personas('modificada'): busca por texto
exec p_buscar_personas('modificada', null, null, :c)
print c

prompt -- 7.5 p_listar_personas: total de filas
declare
    v_c    sys_refcursor;
    v_n    number := 0;
    type t_cols is record (
        id_persona number, codigo char(8), nombre varchar2(100), dni char(8),
        correo varchar2(100), tipo varchar2(15), estado varchar2(12),
        fecha_registro timestamp, escuela varchar2(100), ciclo number,
        especialidad varchar2(100));
    v_r t_cols;
begin
    p_listar_personas(v_c);
    loop
        fetch v_c into v_r;
        exit when v_c%notfound;
        v_n := v_n + 1;
    end loop;
    close v_c;
    dbms_output.put_line('p_listar_personas devolvio ' || v_n || ' filas (17 de la carga + 1 de prueba)');
end;
/

prompt -- 7.6 restriccion: se registra, la persona es denegada con incidencia alta y luego se levanta
exec p_registrar_restriccion(:ip, 'Restriccion de prueba', null, :ir)
select :ir as id_restriccion from dual;
exec p_registrar_acceso('25200012', 1, 1, 22, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
select i.tipo, i.gravedad, i.estado, i.origen from incidencias i where i.id_acceso = :id;
exec p_levantar_restriccion(:ir)
select id_restriccion, estado, to_char(fecha_fin, 'YYYY-MM-DD HH24:MI') as fecha_fin from restricciones where id_restriccion = :ir;
exec p_registrar_acceso('25200012', 1, 1, 22, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 7.7 pases: se emite un pase para 99000002 al aula A-101 (zona 3), entra, se revoca y vuelve a ser denegado
exec p_emitir_pase(31, 5, 3, systimestamp - interval '1' minute, systimestamp + interval '2' hour, 'Visita de prueba', :ipase)
select :ipase as id_pase from dual;
exec p_registrar_acceso('99000002', 4, 1, 26, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;
exec p_revocar_pase(:ipase)
select id_pase, estado from pases where id_pase = :ipase;
exec p_registrar_acceso('99000002', 4, 1, 26, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 7.8 incidencias del vigilante: se registra, pasa a en_revision y se resuelve
exec p_registrar_incidencia(5, null, null, 'puerta_laboratorio_abierta', 'media', 'Puerta del laboratorio abierta fuera de horario', :ii)
select :ii as id_incidencia from dual;
exec p_resolver_incidencia(:ii, 'en_revision', 'Se avisa al encargado')
exec p_resolver_incidencia(:ii, 'resuelta', 'Puerta cerrada con llave')
select id_incidencia, tipo, gravedad, estado, origen, descripcion from incidencias where id_incidencia = :ii;

prompt -- 7.9 p_eliminar_persona: 25200012 tiene accesos, entonces baja logica
exec p_eliminar_persona('25200012', :acc)
select :acc as accion from dual;
select codigo, estado from personas where codigo = '25200012';
exec p_registrar_acceso('25200012', 1, 1, 22, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 7.10 persona sin historial (25200013): se elimina fisicamente
exec p_registrar_persona('25200013', 'Persona Sin Historial', '75000097', null, 'administrativo', null, null, null, :ip)
exec p_eliminar_persona('25200013', :acc)
select :acc as accion from dual;
select count(*) as filas_25200013 from personas where codigo = '25200013';

prompt
prompt =====================================================================
prompt 8. ERRORES INESPERADOS (raise_application_error, sin dejar datos a medias)
prompt =====================================================================
declare
    v_r varchar2(20); v_m varchar2(40); v_id number; v_antes number; v_despues number;
begin
    select count(*) into v_antes from accesos;

    begin
        p_registrar_acceso('25200001', 99, 1, 20, 'simulado', v_r, v_m, v_id);
    exception when others then
        dbms_output.put_line('8.1 punto inexistente -> ' || sqlerrm);
    end;
    begin
        p_registrar_acceso('25200001', 1, 5, 20, 'simulado', v_r, v_m, v_id);
    exception when others then
        dbms_output.put_line('8.2 rostro_ok invalido -> ' || sqlerrm);
    end;
    begin
        p_registrar_acceso('  ', 1, 1, 20, 'simulado', v_r, v_m, v_id);
    exception when others then
        dbms_output.put_line('8.3 codigo vacio -> ' || sqlerrm);
    end;
    begin
        p_registrar_acceso('25200001', 1, 1, 20, 'telepatia', v_r, v_m, v_id);
    exception when others then
        dbms_output.put_line('8.4 metodo invalido -> ' || sqlerrm);
    end;
    begin
        p_levantar_restriccion(999999);
    exception when others then
        dbms_output.put_line('8.5 restriccion inexistente -> ' || sqlerrm);
    end;

    select count(*) into v_despues from accesos;
    dbms_output.put_line('Accesos antes y despues de los 4 llamados fallidos: '
                         || v_antes || ' y ' || v_despues || ' (sin cambios)');
end;
/

prompt
prompt =====================================================================
prompt 9. RESTAURAR VENTANAS HORARIAS Y RESUMEN
prompt =====================================================================
update permisos_zona set hora_desde = '07:00', hora_hasta = '22:00'
 where tipo_persona = 'estudiante' and id_zona in (1, 3, 4);
update permisos_zona set hora_desde = '08:00', hora_hasta = '20:00'
 where tipo_persona = 'estudiante' and id_zona in (2, 5);
update permisos_zona set hora_desde = '06:30', hora_hasta = '23:00'
 where tipo_persona = 'docente';
commit;

column tipo_persona format a15
column zona format a28
select p.tipo_persona, z.nombre as zona, p.hora_desde, p.hora_hasta
  from permisos_zona p join zonas z on z.id_zona = p.id_zona
 where p.tipo_persona in ('estudiante', 'docente')
 order by p.tipo_persona, z.id_zona;

prompt -- accesos generados por esta prueba (metodo simulado), por resultado y motivo
select resultado, nvl(motivo, '-') as motivo, count(*) as total
  from accesos
 where metodo = 'simulado'
   and fecha_hora >= to_timestamp(:t0, 'YYYY-MM-DD HH24:MI:SS')
 group by resultado, motivo
 order by resultado, motivo;

prompt -- incidencias creadas por esta prueba
select id_incidencia, tipo, gravedad, estado, origen
  from incidencias
 where fecha_hora >= to_timestamp(:t0, 'YYYY-MM-DD HH24:MI:SS')
 order by id_incidencia;

commit;
