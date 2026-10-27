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
-- No borra procedimientos, triggers ni permisos: los scripts 03 a 06 usan
-- create or replace y se pueden volver a ejecutar.
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
