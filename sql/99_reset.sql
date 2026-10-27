set sqlblanklines on
set define off
set serveroutput on size unlimited
whenever sqlerror exit failure rollback

-- =====================================================================
-- 99_reset.sql
-- Borra TODAS las tablas del esquema ACCESO_OWNER (con sus datos,
-- constraints, indices y secuencias de identity). Ejecutar como
-- ACCESO_OWNER. Despues se vuelve a cargar con 01 y 02.
--
-- No borra procedimientos ni los permisos EXECUTE de los roles. Los triggers
-- se eliminan junto con sus tablas: despues de recargar 01 y 02 hay que
-- volver a ejecutar 05_triggers.sql (03, 04 y 06 usan create or replace o
-- revocan y otorgan de nuevo, y se pueden repetir sin problema).
-- =====================================================================
begin
    for t in (select table_name
                from user_tables
               order by table_name) loop
        execute immediate 'drop table "' || t.table_name || '" cascade constraints purge';
        dbms_output.put_line('Tabla borrada: ' || t.table_name);
    end loop;
end;
/

select count(*) as tablas_restantes from user_tables;

commit;
