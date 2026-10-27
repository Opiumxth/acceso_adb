set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 200
set feedback off
whenever sqlerror continue

-- =====================================================================
-- test_05_06.sql - Prueba de permisos por rol (06) y de auditoria (05)
--
-- Abre una sesion por cada usuario de aplicacion (las claves son las de
-- 00_admin.sql) y comprueba que:
--   * ningun rol puede leer ni escribir tablas directamente (ORA-00942);
--   * cada rol ejecuta solo los procedimientos que le corresponden
--     (PLS-00201 en los demas);
--   * los cambios en PERSONAS y RESTRICCIONES quedan en AUDITORIA con el
--     usuario real que inicio sesion.
--
--   docker cp sql/test_05_06.sql oracle-xe:/tmp/test_05_06.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/test_05_06.sql
--
-- La prueba modifica datos (crea pases, incidencias y personas de prueba).
-- =====================================================================

column usuario        format a14
column esquema_actual format a14
column nombre         format a24
column tipo           format a12
column estado         format a10
column resultado      format a10
column motivo         format a22
column codigo         format a9
column umbral         format a8
column grupo          format a5
column curso          format a8
column nivel          format a13
column zona           format a22
column total          format 999
column detalle        format a105 word_wrapped
column tabla          format a14
column operacion      format a9
column hora           format a9

variable n    varchar2(100)
variable t    varchar2(20)
variable e    varchar2(20)
variable x    number
variable r    varchar2(20)
variable m    varchar2(40)
variable id   number
variable v    varchar2(100)
variable f    number
variable i    number
variable ip   number
variable ir   number
variable ipase number
variable ii   number
variable acc  varchar2(20)
variable c    refcursor

prompt
prompt =====================================================================
prompt 1. u_punto (rol_punto_control)
prompt =====================================================================
connect u_punto/"Punto#2026"@XEPDB1
alter session set current_schema = ACCESO_OWNER;
show user
select sys_context('USERENV', 'SESSION_USER')   as usuario,
       sys_context('USERENV', 'CURRENT_SCHEMA') as esquema_actual
  from dual;

prompt -- 1.1 SELECT directo sobre accesos: debe FALLAR (ORA-00942)
select count(*) from accesos;
prompt -- 1.2 INSERT directo sobre accesos: debe FALLAR (ORA-00942)
insert into accesos (codigo_leido, id_punto, resultado) values ('00000000', 1, 'permitido');
prompt -- 1.3 SELECT sobre personas y parametros: deben FALLAR (ORA-00942)
select count(*) from personas;
select count(*) from parametros;

prompt -- 1.4 p_verificar_persona funciona
exec p_verificar_persona('90000001', :n, :t, :e, :x)
select :n as nombre, :t as tipo, :e as estado, :x as existe from dual;

prompt -- 1.5 p_registrar_acceso funciona (vigilante 90000001 en la puerta, ventana 00:00-23:59)
exec p_registrar_acceso('90000001', 1, 1, 21.5, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 1.6 p_obtener_parametro funciona (el punto lee el umbral LBPH)
exec p_obtener_parametro('UMBRAL_LBPH', :v)
select :v as umbral from dual;

prompt -- 1.7 procedimientos que no le corresponden: deben FALLAR (PLS-00201)
exec p_cerrar_sesion(900, :f, :i)
exec p_registrar_persona('88000009', 'No Debe Crearse', '88000009', null, 'visitante', null, null, null, :ip)
exec r_incidencias(null, null, :c)

prompt
prompt =====================================================================
prompt 2. u_docente (rol_docente)
prompt =====================================================================
connect u_docente/"Docente#2026"@XEPDB1
alter session set current_schema = ACCESO_OWNER;
show user

prompt -- 2.1 r_asistencia_seccion(1) funciona
exec r_asistencia_seccion(1, :c)
print c

prompt -- 2.2 r_alumnos_en_riesgo(2) funciona
exec r_alumnos_en_riesgo(2, :c)
print c

prompt -- 2.3 p_registrar_acceso: debe FALLAR (PLS-00201)
exec p_registrar_acceso('25200001', 1, 1, 20, 'simulado', :r, :m, :id)
prompt -- 2.4 reporte de seguridad r_accesos_denegados: debe FALLAR (PLS-00201)
exec r_accesos_denegados(null, null, :c)
prompt -- 2.5 SELECT directo sobre inscripciones: debe FALLAR (ORA-00942)
select count(*) from inscripciones;

prompt
prompt =====================================================================
prompt 3. u_vigilante (rol_vigilante)
prompt =====================================================================
connect u_vigilante/"Vigil#2026"@XEPDB1
alter session set current_schema = ACCESO_OWNER;
show user

prompt -- 3.1 p_registrar_acceso funciona
exec p_registrar_acceso('90000001', 1, 1, 20.8, 'simulado', :r, :m, :id)
select :r as resultado, nvl(:m, '-') as motivo, :id as id_acceso from dual;

prompt -- 3.2 pases: emitir para el visitante 31 (zona 2) y revocarlo
exec p_emitir_pase(31, 5, 2, systimestamp, systimestamp + interval '2' hour, 'Prueba de permisos', :ipase)
select :ipase as id_pase from dual;
exec p_revocar_pase(:ipase)
prompt -- 3.3 incidencias: registrar y resolver
exec p_registrar_incidencia(1, null, null, 'prueba_permisos', 'baja', 'Incidencia creada por u_vigilante', :ii)
exec p_resolver_incidencia(:ii, 'resuelta', 'Cerrada en la prueba')
select :ii as id_incidencia from dual;

prompt -- 3.3b restricciones: registrar y levantar una al visitante 31 (queda en la auditoria como U_VIGILANTE)
exec p_registrar_restriccion(31, 'Prueba de permisos del vigilante', null, :ir)
exec p_levantar_restriccion(:ir)

prompt -- 3.4 reporte de seguridad r_accesos_denegados de hoy funciona
exec r_accesos_denegados(trunc(sysdate), trunc(sysdate), :c)
print c

prompt -- 3.5 lo que no le corresponde: PLS-00201, PLS-00201 y ORA-00942
exec p_registrar_persona('88000009', 'No Debe Crearse', '88000009', null, 'visitante', null, null, null, :ip)
exec r_asistencia_seccion(1, :c)
select count(*) from pases;

prompt
prompt =====================================================================
prompt 4. u_admin (rol_admin)
prompt =====================================================================
connect u_admin/"Admin#2026"@XEPDB1
alter session set current_schema = ACCESO_OWNER;
show user

prompt -- 4.1 persona 88000001: alta, modificacion, restriccion, levantarla y baja logica
exec p_registrar_persona('88000001', 'Auditoria Prueba Uno', '88000001', 'aud1@campus.test', 'visitante', null, null, null, :ip)
exec p_modificar_persona('88000001', p_nombre => 'Auditoria Prueba Uno Modificada', p_correo => 'aud1.nuevo@campus.test')
exec p_registrar_restriccion(:ip, 'Prueba de auditoria', null, :ir)
exec p_levantar_restriccion(:ir)
exec p_eliminar_persona('88000001', :acc)
select :acc as accion_88000001 from dual;

prompt -- 4.2 persona 88000002 sin historial: alta y eliminacion fisica
exec p_registrar_persona('88000002', 'Auditoria Prueba Dos', '88000002', null, 'visitante', null, null, null, :ip)
exec p_eliminar_persona('88000002', :acc)
select :acc as accion_88000002 from dual;

prompt -- 4.3 reportes y listados funcionan
exec p_buscar_personas('auditoria', null, null, :c)
print c
exec r_pases_vigentes(:c)
print c

prompt -- 4.4 aun siendo administrador no tiene acceso directo a las tablas (ORA-00942)
select count(*) from auditoria;

prompt
prompt =====================================================================
prompt 5. ACCESO_OWNER: bitacora de auditoria generada por los triggers
prompt =====================================================================
connect acceso_owner/"Owner#2026"@XEPDB1
select id_auditoria, tabla, operacion, usuario, to_char(fecha, 'HH24:MI:SS') as hora, detalle
  from auditoria
 order by id_auditoria;

prompt
prompt Resumen por usuario y operacion
select usuario, tabla, operacion, count(*) as total
  from auditoria
 group by usuario, tabla, operacion
 order by usuario, tabla, operacion;

commit;
