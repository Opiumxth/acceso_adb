set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 100
whenever sqlerror continue

-- =====================================================================
-- 05_triggers.sql
-- Triggers de auditoria sobre PERSONAS y RESTRICCIONES. Cada INSERT, UPDATE
-- o DELETE deja una fila en AUDITORIA (tabla, operacion, usuario, fecha,
-- detalle). Ejecutar como ACCESO_OWNER despues de 01 y 03.
--   docker cp sql/05_triggers.sql oracle-xe:/tmp/05_triggers.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/05_triggers.sql
--
-- * El usuario registrado es SESSION_USER: la persona que inicio sesion
--   (u_admin, u_punto...), aunque el cambio lo haga un procedimiento del
--   esquema dueno.
-- * La fila de auditoria se inserta en la misma transaccion que el cambio:
--   si el procedimiento hace rollback, la auditoria tambien se deshace.
-- * Los triggers se eliminan junto con sus tablas (99_reset.sql); despues de
--   recargar 01 y 02 hay que volver a ejecutar este script.
-- =====================================================================

create or replace trigger trg_aud_personas
after insert or update or delete on personas
for each row
declare
    v_oper     varchar2(10);
    v_det      varchar2(4000);
    v_cambios  number := 0;

    -- agrega "campo: [antes] -> [despues]" si el valor cambio (nulos incluidos)
    procedure cambio (p_campo in varchar2, p_antes in varchar2, p_despues in varchar2) is
    begin
        if (p_antes is null and p_despues is not null)
           or (p_antes is not null and p_despues is null)
           or (p_antes <> p_despues) then
            v_det := v_det || ' ' || p_campo || ': [' || p_antes || '] -> [' || p_despues || ']';
            v_cambios := v_cambios + 1;
        end if;
    end cambio;
begin
    if inserting then
        v_oper := 'INSERT';
        v_det  := 'id=' || :new.id_persona || ' codigo=' || :new.codigo
                  || ' tipo=' || :new.tipo || ' estado=' || :new.estado
                  || ' nombre=' || :new.nombre;
    elsif updating then
        v_oper := 'UPDATE';
        v_det  := 'id=' || :old.id_persona || ' codigo=' || :old.codigo || ' |';
        cambio('codigo', :old.codigo, :new.codigo);
        cambio('nombre', :old.nombre, :new.nombre);
        cambio('dni',    :old.dni,    :new.dni);
        cambio('correo', :old.correo, :new.correo);
        cambio('tipo',   :old.tipo,   :new.tipo);
        cambio('estado', :old.estado, :new.estado);
        if v_cambios = 0 then
            return;
        end if;
    else
        v_oper := 'DELETE';
        v_det  := 'id=' || :old.id_persona || ' codigo=' || :old.codigo
                  || ' tipo=' || :old.tipo || ' estado=' || :old.estado
                  || ' nombre=' || :old.nombre;
    end if;

    insert into auditoria (tabla, operacion, usuario, fecha, detalle)
    values ('PERSONAS', v_oper,
            substr(sys_context('USERENV', 'SESSION_USER'), 1, 30),
            systimestamp, substr(v_det, 1, 400));
end trg_aud_personas;
/

create or replace trigger trg_aud_restricciones
after insert or update or delete on restricciones
for each row
declare
    v_oper     varchar2(10);
    v_det      varchar2(4000);
    v_cambios  number := 0;

    procedure cambio (p_campo in varchar2, p_antes in varchar2, p_despues in varchar2) is
    begin
        if (p_antes is null and p_despues is not null)
           or (p_antes is not null and p_despues is null)
           or (p_antes <> p_despues) then
            v_det := v_det || ' ' || p_campo || ': [' || p_antes || '] -> [' || p_despues || ']';
            v_cambios := v_cambios + 1;
        end if;
    end cambio;
begin
    if inserting then
        v_oper := 'INSERT';
        v_det  := 'id_restriccion=' || :new.id_restriccion || ' persona=' || :new.id_persona
                  || ' estado=' || :new.estado
                  || ' fecha_fin=' || to_char(:new.fecha_fin, 'YYYY-MM-DD HH24:MI')
                  || ' motivo=' || :new.motivo;
    elsif updating then
        v_oper := 'UPDATE';
        v_det  := 'id_restriccion=' || :old.id_restriccion || ' persona=' || :old.id_persona || ' |';
        cambio('motivo', :old.motivo, :new.motivo);
        cambio('estado', :old.estado, :new.estado);
        cambio('fecha_fin', to_char(:old.fecha_fin, 'YYYY-MM-DD HH24:MI'),
                            to_char(:new.fecha_fin, 'YYYY-MM-DD HH24:MI'));
        if v_cambios = 0 then
            return;
        end if;
    else
        v_oper := 'DELETE';
        v_det  := 'id_restriccion=' || :old.id_restriccion || ' persona=' || :old.id_persona
                  || ' estado=' || :old.estado || ' motivo=' || :old.motivo;
    end if;

    insert into auditoria (tabla, operacion, usuario, fecha, detalle)
    values ('RESTRICCIONES', v_oper,
            substr(sys_context('USERENV', 'SESSION_USER'), 1, 30),
            systimestamp, substr(v_det, 1, 400));
end trg_aud_restricciones;
/

-- ---------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------
prompt
prompt === Errores de compilacion (debe salir vacio) ===
column name format a28
column type format a12
column text format a90
select name, type, line, position, text
  from user_errors
 where name like 'TRG\_%' escape '\'
 order by name, sequence;

prompt
prompt === Triggers ===
column trigger_name format a24
column table_name   format a16
column triggering_event format a24
select trigger_name, table_name, triggering_event, status
  from user_triggers
 order by trigger_name;

commit;
