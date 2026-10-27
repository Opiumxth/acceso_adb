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
-- Solo lee datos. Las fechas son dias de la hora local (f_hoy_local) y las
-- horas que se muestran tambien estan en hora local.
-- =====================================================================

column codigo           format a9
column nombre           format a26
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
column punto            format a16
column tipo_persona     format a14
column resultado        format a10
column metodo           format a10
column nombre_curso     format a34
column docente          format a22
column aula             format a14
column inicio           format a16
column fin              format a16
column desde            format a16
column facultad         format a50
column fecha_hora_local format a16

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
prompt 4. r_ranking_tardanzas: ultimos 60 dias (dias de la hora local)
prompt =====================================================================
exec r_ranking_tardanzas(f_hoy_local - 60, f_hoy_local, :c)
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
exec r_accesos_denegados(f_hoy_local - 3, f_hoy_local, :c)
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
exec r_uso_aulas_vs_sesiones(f_hoy_local, :c)
print c

prompt
prompt === hace 7 dias (una sesion semanal por seccion)
exec r_uso_aulas_vs_sesiones(f_hoy_local - 7, :c)
print c

prompt
prompt =====================================================================
prompt 9. r_flujo_por_hora
prompt =====================================================================
prompt === ayer, solo la Puerta Principal (zona 1)
exec r_flujo_por_hora(f_hoy_local - 1, 1, :c)
print c

prompt
prompt === hoy, todas las zonas (horas locales)
exec r_flujo_por_hora(f_hoy_local, null, :c)
print c

prompt
prompt =====================================================================
prompt 10. PROCEDIMIENTOS DE CONSULTA DEL PANEL WEB
prompt =====================================================================
prompt === r_resumen_hoy: contadores del dia (hora local)
exec r_resumen_hoy(:c)
print c

prompt
prompt === r_accesos_bitacora: ultimos 5 accesos de hoy
exec r_accesos_bitacora(f_hoy_local, f_hoy_local, null, null, null, 5, :c)
print c

prompt
prompt === r_accesos_bitacora: denegados en la puerta (zona 1) de los ultimos 7 dias, maximo 6
exec r_accesos_bitacora(f_hoy_local - 7, f_hoy_local, 'denegado', 1, null, 6, :c)
print c

prompt
prompt === r_accesos_bitacora: busqueda por texto 'torres'
exec r_accesos_bitacora(f_hoy_local - 14, f_hoy_local, null, null, 'torres', 4, :c)
print c

prompt
prompt === r_zonas
exec r_zonas(:c)
print c

prompt
prompt === r_escuelas
exec r_escuelas(:c)
print c

prompt
prompt === r_secciones
exec r_secciones(:c)
print c

prompt
prompt === r_sesiones(1): sesiones de la seccion 1, la mas reciente primero
exec r_sesiones(1, :c)
print c

prompt
prompt === r_restricciones: restricciones vigentes
exec r_restricciones(:c)
print c

prompt
prompt === p_obtener_desfase: minutos servidor - local
variable desf number
exec p_obtener_desfase(:desf)
select :desf as desfase_minutos, round(:desf / 60, 2) as desfase_horas,
       to_char(sysdate, 'YYYY-MM-DD HH24:MI') as hora_servidor,
       to_char(sysdate - :desf / 1440, 'YYYY-MM-DD HH24:MI') as hora_local
  from dual;

prompt
prompt =====================================================================
prompt 11. ERRORES ESPERADOS
prompt =====================================================================
declare
    v_c sys_refcursor;
begin
    begin
        r_asistencia_seccion(999, v_c);
    exception when others then
        dbms_output.put_line('11.1 seccion inexistente    -> ' || sqlerrm);
    end;
    begin
        r_incidencias('cerrada', null, v_c);
    exception when others then
        dbms_output.put_line('11.2 estado no valido       -> ' || sqlerrm);
    end;
    begin
        r_ranking_tardanzas(sysdate, sysdate - 10, v_c);
    exception when others then
        dbms_output.put_line('11.3 rango de fechas al reves -> ' || sqlerrm);
    end;
    begin
        r_flujo_por_hora(sysdate, 99, v_c);
    exception when others then
        dbms_output.put_line('11.4 zona inexistente       -> ' || sqlerrm);
    end;
    begin
        r_sesiones(999, v_c);
    exception when others then
        dbms_output.put_line('11.5 seccion inexistente (sesiones) -> ' || sqlerrm);
    end;
    begin
        r_accesos_bitacora(null, null, 'quizas', null, null, 10, v_c);
    exception when others then
        dbms_output.put_line('11.6 resultado no valido    -> ' || sqlerrm);
    end;
end;
/

commit;
