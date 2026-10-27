set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 100
whenever sqlerror continue

-- =====================================================================
-- 06_permisos.sql
-- Permisos de los roles. Ejecutar como ACCESO_OWNER despues de 03 y 04.
--   docker cp sql/06_permisos.sql oracle-xe:/tmp/06_permisos.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/06_permisos.sql
--
-- Principio: los roles solo tienen EXECUTE sobre procedimientos; ningun rol
-- recibe privilegios sobre tablas. Los procedimientos usan los derechos de
-- su propietario (definer rights), asi que quien los ejecuta puede cambiar
-- datos unicamente por las vias que el procedimiento permite.
--
--   rol_punto_control : p_verificar_persona, p_registrar_acceso y
--                       p_obtener_parametro (el punto lee UMBRAL_LBPH)
--   rol_vigilante     : lo anterior + pases, restricciones, incidencias,
--                       p_buscar_personas (para elegir visitante y anfitrion),
--                       los reportes de seguridad y las consultas del panel
--                       (resumen del dia, bitacora de accesos, zonas,
--                       restricciones vigentes y p_obtener_desfase)
--   rol_docente       : reportes de asistencia y la lista de secciones y
--                       sesiones para elegir a cual consultar
--   rol_admin         : todos los procedimientos y funciones
--
-- Es re-ejecutable: primero se revocan todos los privilegios de objeto de
-- los cuatro roles y luego se vuelven a otorgar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Revocar lo otorgado antes (estado final determinista)
-- ---------------------------------------------------------------------
begin
    for g in (select table_name, privilege, grantee
                from user_tab_privs_made
               where grantee in ('ROL_ADMIN', 'ROL_DOCENTE', 'ROL_VIGILANTE', 'ROL_PUNTO_CONTROL')) loop
        execute immediate 'revoke ' || g.privilege || ' on ' || g.table_name
                          || ' from ' || g.grantee;
    end loop;
end;
/

-- ---------------------------------------------------------------------
-- 2. rol_punto_control
-- ---------------------------------------------------------------------
grant execute on p_verificar_persona to rol_punto_control;
grant execute on p_registrar_acceso  to rol_punto_control;
grant execute on p_obtener_parametro to rol_punto_control;

-- ---------------------------------------------------------------------
-- 3. rol_vigilante
-- ---------------------------------------------------------------------
grant execute on p_verificar_persona     to rol_vigilante;
grant execute on p_registrar_acceso      to rol_vigilante;
grant execute on p_obtener_parametro     to rol_vigilante;
grant execute on p_buscar_personas       to rol_vigilante;
grant execute on p_emitir_pase           to rol_vigilante;
grant execute on p_revocar_pase          to rol_vigilante;
grant execute on p_registrar_restriccion to rol_vigilante;
grant execute on p_levantar_restriccion  to rol_vigilante;
grant execute on p_registrar_incidencia  to rol_vigilante;
grant execute on p_resolver_incidencia   to rol_vigilante;
grant execute on r_accesos_denegados     to rol_vigilante;
grant execute on r_incidencias           to rol_vigilante;
grant execute on r_pases_vigentes        to rol_vigilante;
grant execute on r_flujo_por_hora        to rol_vigilante;
grant execute on p_obtener_desfase       to rol_vigilante;
grant execute on r_resumen_hoy           to rol_vigilante;
grant execute on r_accesos_bitacora      to rol_vigilante;
grant execute on r_zonas                 to rol_vigilante;
grant execute on r_restricciones         to rol_vigilante;

-- ---------------------------------------------------------------------
-- 4. rol_docente
-- ---------------------------------------------------------------------
grant execute on r_asistencia_seccion to rol_docente;
grant execute on r_asistencia_sesion  to rol_docente;
grant execute on r_alumnos_en_riesgo  to rol_docente;
grant execute on r_ranking_tardanzas  to rol_docente;
grant execute on r_secciones          to rol_docente;
grant execute on r_sesiones           to rol_docente;

-- ---------------------------------------------------------------------
-- 5. rol_admin: todos los procedimientos y funciones del esquema
-- ---------------------------------------------------------------------
begin
    for o in (select object_name
                from user_objects
               where object_type in ('PROCEDURE', 'FUNCTION')
               order by object_name) loop
        execute immediate 'grant execute on ' || o.object_name || ' to rol_admin';
    end loop;
end;
/

-- ---------------------------------------------------------------------
-- 6. Verificacion
-- ---------------------------------------------------------------------
prompt
prompt === Matriz de EXECUTE (X = tiene permiso) ===
column objeto    format a26
column punto     format a6
column vigilante format a10
column docente   format a8
column admin     format a6
select o.object_name as objeto,
       max(case when p.grantee = 'ROL_PUNTO_CONTROL' then 'X' end) as punto,
       max(case when p.grantee = 'ROL_VIGILANTE'     then 'X' end) as vigilante,
       max(case when p.grantee = 'ROL_DOCENTE'       then 'X' end) as docente,
       max(case when p.grantee = 'ROL_ADMIN'         then 'X' end) as admin
  from user_objects o
  left join user_tab_privs_made p
         on p.table_name = o.object_name
        and p.privilege = 'EXECUTE'
 where o.object_type in ('PROCEDURE', 'FUNCTION')
 group by o.object_name
 order by o.object_name;

prompt
prompt === Privilegios de los roles sobre TABLAS (debe ser 0) ===
select count(*) as privilegios_sobre_tablas
  from user_tab_privs_made p
  join user_tables t on t.table_name = p.table_name
 where p.grantee in ('ROL_ADMIN', 'ROL_DOCENTE', 'ROL_VIGILANTE', 'ROL_PUNTO_CONTROL');

prompt
prompt === Privilegios distintos de EXECUTE otorgados a los roles (debe salir vacio) ===
select grantee, table_name, privilege
  from user_tab_privs_made
 where grantee in ('ROL_ADMIN', 'ROL_DOCENTE', 'ROL_VIGILANTE', 'ROL_PUNTO_CONTROL')
   and privilege <> 'EXECUTE';

commit;
