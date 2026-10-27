set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 230
set pagesize 200
set feedback off
whenever sqlerror continue

-- =====================================================================
-- test_04.sql - Prueba de los reportes r_* de 04_reportes.sql
--
-- Ejecutar como ACCESO_OWNER, de preferencia despues de test_03.sql (asi los
-- reportes incluyen las asistencias, denegaciones e incidencias de hoy):
--   docker cp sql/test_04.sql oracle-xe:/tmp/test_04.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/test_04.sql
-- Solo lee datos.
-- =====================================================================

column codigo           format a9
column nombre           format a22
column curso            format a8
column grupo            format a5
column zona             format a28
column zona_destino     format a24
column tipo             format a26
column motivo           format a44 word_wrapped
column nivel            format a13
column estado           format a13
column estado_inscripcion format a19
column asistencia       format a13
column hora_registro    format a13
column persona          format a22
column codigo_persona   format a14
column visitante        format a20
column anfitrion        format a20
column codigo_visitante format a16
column fecha            format a16
column primero          format a16
column ultimo           format a16
column desde            format a16
column hasta            format a16
column origen           format a10
column gravedad         format a9
column descripcion      format a60 word_wrapped
column observacion      format a26
column hora             format a6

variable c refcursor

prompt
prompt =====================================================================
prompt 1. r_asistencia_seccion(1): seccion 1 (SIS301-A), solo sesiones cerradas
prompt =====================================================================
exec r_asistencia_seccion(1, :c)
print c

prompt
prompt === r_asistencia_seccion(3): seccion 3 (SIS201-A, laboratorio)
exec r_asistencia_seccion(3, :c)
print c

prompt
prompt =====================================================================
prompt 2. r_asistencia_sesion(900): detalle de la sesion 900
prompt =====================================================================
exec r_asistencia_sesion(900, :c)
print c

prompt
prompt =====================================================================
prompt 3. r_alumnos_en_riesgo(NULL): todas las secciones (limite = LIMITE_FALTAS_PCT)
prompt =====================================================================
exec r_alumnos_en_riesgo(null, :c)
print c

prompt
prompt === r_alumnos_en_riesgo(1): solo la seccion 1
exec r_alumnos_en_riesgo(1, :c)
print c

prompt
prompt =====================================================================
prompt 4. r_ranking_tardanzas: ultimos 60 dias
prompt =====================================================================
exec r_ranking_tardanzas(trunc(sysdate) - 60, trunc(sysdate), :c)
print c

prompt
prompt === r_ranking_tardanzas(NULL, NULL): sin limites de fecha
exec r_ranking_tardanzas(null, null, :c)
print c

prompt
prompt =====================================================================
prompt 5. r_accesos_denegados: agrupado por motivo y zona (subtotales y total)
prompt =====================================================================
exec r_accesos_denegados(null, null, :c)
print c

prompt
prompt === r_accesos_denegados de los ultimos 3 dias (hoy incluido)
exec r_accesos_denegados(trunc(sysdate) - 3, trunc(sysdate), :c)
print c

prompt
prompt =====================================================================
prompt 6. r_incidencias
prompt =====================================================================
prompt === r_incidencias(NULL, NULL): todas, las mas graves primero
exec r_incidencias(null, null, :c)
print c

prompt
prompt === r_incidencias('abierta', 'alta')
exec r_incidencias('abierta', 'alta', :c)
print c

prompt
prompt =====================================================================
prompt 7. r_pases_vigentes (el pase 1002 fue revocado y el del visitante 99000002 esta vencido)
prompt =====================================================================
exec r_pases_vigentes(:c)
print c

prompt
prompt =====================================================================
prompt 8. r_uso_aulas_vs_sesiones
prompt =====================================================================
prompt === hoy (sesiones 900 y 901 de la seccion 1 en el aula A-101)
exec r_uso_aulas_vs_sesiones(trunc(sysdate), :c)
print c

prompt
prompt === hace 7 dias (una sesion semanal por seccion)
exec r_uso_aulas_vs_sesiones(trunc(sysdate) - 7, :c)
print c

prompt
prompt =====================================================================
prompt 9. r_flujo_por_hora
prompt =====================================================================
prompt === ayer, solo la Puerta Principal (zona 1)
exec r_flujo_por_hora(trunc(sysdate) - 1, 1, :c)
print c

prompt
prompt === hoy, todas las zonas (hora del servidor)
exec r_flujo_por_hora(trunc(sysdate), null, :c)
print c

prompt
prompt =====================================================================
prompt 10. ERRORES ESPERADOS
prompt =====================================================================
declare
    v_c sys_refcursor;
begin
    begin
        r_asistencia_seccion(999, v_c);
    exception when others then
        dbms_output.put_line('10.1 seccion inexistente    -> ' || sqlerrm);
    end;
    begin
        r_incidencias('cerrada', null, v_c);
    exception when others then
        dbms_output.put_line('10.2 estado no valido       -> ' || sqlerrm);
    end;
    begin
        r_ranking_tardanzas(sysdate, sysdate - 10, v_c);
    exception when others then
        dbms_output.put_line('10.3 rango de fechas al reves -> ' || sqlerrm);
    end;
    begin
        r_flujo_por_hora(sysdate, 99, v_c);
    exception when others then
        dbms_output.put_line('10.4 zona inexistente       -> ' || sqlerrm);
    end;
end;
/

commit;
