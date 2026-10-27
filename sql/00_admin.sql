set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 100
whenever sqlerror exit failure rollback

-- =====================================================================
-- 00_admin.sql
-- Sistema de Control de Acceso, Asistencia y Seguridad Universitaria
--
-- Ejecutar como SYSTEM conectado a XEPDB1:
--   docker cp sql/00_admin.sql oracle-xe:/tmp/00_admin.sql
--   docker exec -i oracle-xe sqlplus -s 'system/"admin123"@XEPDB1' @/tmp/00_admin.sql
--
-- Crea: tablespaces, esquema dueno (acceso_owner), roles y usuarios de
-- aplicacion. Es re-ejecutable: lo que ya existe se omite.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tablespaces (el directorio se toma de los datafiles existentes)
--    datos: tablas maestras y academicas
--    log  : tablas de alto volumen (accesos, asistencias, auditoria)
--    idx  : indices secundarios
-- ---------------------------------------------------------------------
declare
    v_dir varchar2(500);

    procedure crear_tablespace (
        p_nombre in varchar2,
        p_tam    in varchar2,
        p_max    in varchar2
    ) is
        v_n number;
    begin
        select count(*) into v_n
          from dba_tablespaces
         where tablespace_name = upper(p_nombre);
        if v_n = 0 then
            execute immediate 'create tablespace ' || p_nombre
                || ' datafile ''' || v_dir || p_nombre || '01.dbf'''
                || ' size ' || p_tam
                || ' autoextend on next 10m maxsize ' || p_max;
            dbms_output.put_line('Tablespace creado : ' || p_nombre);
        else
            dbms_output.put_line('Tablespace ya existia: ' || p_nombre);
        end if;
    end crear_tablespace;
begin
    select substr(name, 1, greatest(instr(name, '/', -1), instr(name, '\', -1)))
      into v_dir
      from v$datafile
     where file# = (select min(file#) from v$datafile);

    dbms_output.put_line('Directorio de datafiles: ' || v_dir);
    crear_tablespace('ts_acceso_datos', '50m', '500m');
    crear_tablespace('ts_acceso_log',   '50m', '500m');
    crear_tablespace('ts_acceso_idx',   '30m', '200m');
end;
/

-- ---------------------------------------------------------------------
-- 2. Usuarios y roles (solo se crean si no existen)
-- ---------------------------------------------------------------------
declare
    procedure crear_rol (p_rol in varchar2) is
        v_n number;
    begin
        select count(*) into v_n from dba_roles where role = upper(p_rol);
        if v_n = 0 then
            execute immediate 'create role ' || p_rol;
            dbms_output.put_line('Rol creado    : ' || p_rol);
        else
            dbms_output.put_line('Rol ya existia: ' || p_rol);
        end if;
    end crear_rol;

    procedure crear_usuario (p_usuario in varchar2, p_clave in varchar2, p_extra in varchar2) is
        v_n number;
    begin
        select count(*) into v_n from dba_users where username = upper(p_usuario);
        if v_n = 0 then
            execute immediate 'create user ' || p_usuario
                || ' identified by "' || p_clave || '" ' || p_extra;
            dbms_output.put_line('Usuario creado    : ' || p_usuario);
        else
            dbms_output.put_line('Usuario ya existia: ' || p_usuario);
        end if;
    end crear_usuario;
begin
    -- esquema dueno de todos los objetos
    crear_usuario('acceso_owner', 'Owner#2026',
        'default tablespace ts_acceso_datos '
        || 'quota unlimited on ts_acceso_datos '
        || 'quota unlimited on ts_acceso_log '
        || 'quota unlimited on ts_acceso_idx');

    -- roles de aplicacion
    crear_rol('rol_admin');
    crear_rol('rol_docente');
    crear_rol('rol_vigilante');
    crear_rol('rol_punto_control');

    -- un usuario de aplicacion por rol (sin cuota: no son duenos de objetos)
    crear_usuario('u_admin',     'Admin#2026',   '');
    crear_usuario('u_docente',   'Docente#2026', '');
    crear_usuario('u_vigilante', 'Vigil#2026',   '');
    crear_usuario('u_punto',     'Punto#2026',   '');
end;
/

-- ---------------------------------------------------------------------
-- 3. Privilegios
-- ---------------------------------------------------------------------
grant create session, create table, create view, create sequence,
      create procedure, create trigger, create type, create job
   to acceso_owner;

grant create session to rol_admin;
grant create session to rol_docente;
grant create session to rol_vigilante;
grant create session to rol_punto_control;

grant rol_admin         to u_admin;
grant rol_docente       to u_docente;
grant rol_vigilante     to u_vigilante;
grant rol_punto_control to u_punto;

-- ---------------------------------------------------------------------
-- 4. Verificacion
-- ---------------------------------------------------------------------
prompt
prompt === Tablespaces del proyecto ===
column tablespace_name format a20
column file_name       format a60
column mb              format 999,990
column autoextensible  format a5
select d.tablespace_name,
       d.file_name,
       round(d.bytes / 1024 / 1024) as mb,
       d.autoextensible
  from dba_data_files d
 where d.tablespace_name like 'TS\_ACCESO%' escape '\'
 order by d.tablespace_name;

prompt
prompt === Usuarios del proyecto ===
column username           format a15
column default_tablespace format a18
select username, default_tablespace, account_status
  from dba_users
 where username in ('ACCESO_OWNER', 'U_ADMIN', 'U_DOCENTE', 'U_VIGILANTE', 'U_PUNTO')
 order by username;

prompt
prompt === Roles asignados ===
column grantee      format a15
column granted_role format a20
select grantee, granted_role
  from dba_role_privs
 where grantee in ('U_ADMIN', 'U_DOCENTE', 'U_VIGILANTE', 'U_PUNTO')
 order by grantee;

commit;
