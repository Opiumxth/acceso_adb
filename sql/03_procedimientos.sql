set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 100
whenever sqlerror continue

-- =====================================================================
-- 03_procedimientos.sql
-- Procedimientos de la aplicacion (propietario: ACCESO_OWNER).
--   docker cp sql/03_procedimientos.sql oracle-xe:/tmp/03_procedimientos.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/03_procedimientos.sql
--
-- Convenciones
--  * Una negacion de acceso NO es un error: se registra en accesos y se
--    devuelve por parametros OUT (o_resultado, o_motivo, o_id_acceso).
--  * Los errores reales usan raise_application_error con estos codigos:
--      -20001  parametro de entrada faltante o invalido
--      -20002  registro referenciado inexistente (persona, punto, sesion...)
--      -20003  el estado actual no permite la operacion
--      -20004  parametro del sistema no configurado en la tabla parametros
--      -20005  registro duplicado (codigo, DNI, restriccion vigente)
--      -20099  error inesperado (se hace rollback y se informa sqlerrm)
--  * Cada procedimiento que modifica datos hace commit al terminar bien y
--    rollback ante cualquier error.
--  * Todas las marcas de tiempo se guardan en hora del servidor; solo la
--    ventana HH24:MI de permisos_zona se evalua en la zona horaria del
--    parametro ZONA_HORARIA.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Auxiliares de parametros
-- ---------------------------------------------------------------------
create or replace function f_parametro (p_nombre in varchar2) return varchar2 is
    v_valor parametros.valor%type;
begin
    select valor into v_valor from parametros where nombre = p_nombre;
    return v_valor;
exception
    when no_data_found then
        raise_application_error(-20004,
            'Parametro del sistema no configurado: ' || p_nombre);
end f_parametro;
/

create or replace function f_parametro_num (p_nombre in varchar2) return number is
begin
    return to_number(f_parametro(p_nombre));
exception
    when value_error or invalid_number then
        raise_application_error(-20004,
            'El parametro del sistema ' || p_nombre || ' no es numerico');
end f_parametro_num;
/

-- Lectura de un parametro para clientes que no tienen acceso a la tabla
-- (por ejemplo el punto de acceso lee UMBRAL_LBPH).
create or replace procedure p_obtener_parametro (
    p_nombre in  varchar2,
    o_valor  out varchar2
) is
begin
    o_valor := null;
    if p_nombre is null or trim(p_nombre) is null then
        raise_application_error(-20001, 'El nombre del parametro es obligatorio');
    end if;
    o_valor := f_parametro(upper(trim(p_nombre)));
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_obtener_parametro: ' || sqlerrm);
end p_obtener_parametro;
/

-- ---------------------------------------------------------------------
-- 1) p_verificar_persona: reemplaza la busqueda en alumnos.csv
--    o_existe = 1 si el codigo existe en personas, 0 si no.
-- ---------------------------------------------------------------------
create or replace procedure p_verificar_persona (
    p_codigo in  varchar2,
    o_nombre out varchar2,
    o_tipo   out varchar2,
    o_estado out varchar2,
    o_existe out number
) is
begin
    o_nombre := null;
    o_tipo   := null;
    o_estado := null;
    o_existe := 0;

    if p_codigo is null or trim(p_codigo) is null then
        raise_application_error(-20001, 'El codigo es obligatorio');
    end if;

    begin
        select nombre, tipo, estado
          into o_nombre, o_tipo, o_estado
          from personas
         where codigo = trim(p_codigo);
        o_existe := 1;
    exception
        when no_data_found then
            o_existe := 0;
    end;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_verificar_persona: ' || sqlerrm);
end p_verificar_persona;
/

-- ---------------------------------------------------------------------
-- 2) p_registrar_acceso: una sola transaccion que decide el ingreso,
--    la asistencia y las incidencias.
--
--    Reglas en este orden:
--      a. codigo inexistente              -> codigo_inexistente
--      b. persona con estado <> activo    -> persona_inactiva
--      c. p_rostro_ok = 0                 -> rostro_no_coincide
--      d. restriccion vigente             -> persona_restringida (+ incidencia alta)
--      e. autorizacion de la zona del punto
--           visitante: pase activo y vigente ahora (puerta: cualquier pase;
--                      otra zona: un pase de esa zona)    -> sin_pase_vigente
--           otros    : fila en permisos_zona              -> zona_no_autorizada
--                      hora local dentro de la ventana    -> fuera_de_horario
--      f. si se permite: asistencia / sesion en curso (aula o laboratorio)
--      g. si se deniega: intentos reiterados -> incidencia de gravedad media
-- ---------------------------------------------------------------------
create or replace procedure p_registrar_acceso (
    p_codigo     in  varchar2,
    p_id_punto   in  number,
    p_rostro_ok  in  number,
    p_confianza  in  number,
    p_metodo     in  varchar2,
    o_resultado  out varchar2,
    o_motivo     out varchar2,
    o_id_acceso  out number
) is
    -- la ventana de asistencia se abre 10 minutos antes del inicio
    c_min_antes constant number := 10;

    -- umbrales leidos de la tabla parametros
    v_min_tardanza      number;
    v_min_max_tardanza  number;
    v_intentos          number;
    v_min_ventana       number;
    v_zona_horaria      varchar2(60);

    -- contexto de la lectura
    v_ahora       timestamp := systimestamp;
    v_hora_local  varchar2(5);
    v_codigo      varchar2(20);
    v_metodo      varchar2(12);

    -- punto de control y zona
    v_id_zona       puntos_control.id_zona%type;
    v_estado_punto  puntos_control.estado%type;
    v_tipo_zona     zonas.tipo%type;

    -- persona
    v_id_persona  personas.id_persona%type;
    v_tipo        personas.tipo%type;
    v_estado      personas.estado%type;

    -- decision y registro
    v_motivo      accesos.motivo%type;
    v_resultado   accesos.resultado%type;
    v_id_acceso   accesos.id_acceso%type;

    -- auxiliares
    v_n              number;
    v_desde          permisos_zona.hora_desde%type;
    v_hasta          permisos_zona.hora_hasta%type;
    v_id_sesion      sesiones.id_sesion%type;
    v_hora_inicio    sesiones.hora_inicio%type;
    v_estado_sesion  sesiones.estado%type;
    v_minutos        number;
    v_estado_asist   asistencias.estado%type;

    -- sesion candidata de un estudiante: inscripcion activa en una seccion
    -- cuya aula es la zona del punto, dentro de la ventana
    -- [inicio - 10 min, inicio + MIN_MAX_TARDANZA]; se toma la mas cercana
    cursor c_sesion (cp_estudiante number, cp_zona number,
                     cp_ahora timestamp, cp_max number) is
        select s.id_sesion, s.hora_inicio, s.estado
          from inscripciones i
          join secciones c on c.id_seccion = i.id_seccion
          join sesiones  s on s.id_seccion = c.id_seccion
         where i.id_estudiante = cp_estudiante
           and i.estado = 'activa'
           and c.id_aula = cp_zona
           and s.estado in ('programada', 'en_curso')
           and cp_ahora >= s.hora_inicio - numtodsinterval(c_min_antes, 'minute')
           and cp_ahora <= s.hora_inicio + numtodsinterval(cp_max, 'minute')
         order by abs(cast(s.hora_inicio as date) - cast(cp_ahora as date));
begin
    o_resultado := null;
    o_motivo    := null;
    o_id_acceso := null;

    -- ---- validacion de entradas ----
    if p_codigo is null or trim(p_codigo) is null then
        raise_application_error(-20001, 'El codigo leido es obligatorio');
    end if;
    if p_id_punto is null then
        raise_application_error(-20001, 'El punto de control es obligatorio');
    end if;
    if p_rostro_ok is null or p_rostro_ok not in (0, 1) then
        raise_application_error(-20001,
            'p_rostro_ok debe ser 1 (rostro coincide) o 0 (no coincide)');
    end if;
    if p_confianza is not null and (p_confianza < 0 or p_confianza > 9999.99) then
        raise_application_error(-20001, 'p_confianza fuera de rango (0 a 9999.99)');
    end if;
    v_metodo := nvl(p_metodo, 'qr_rostro');
    if v_metodo not in ('qr_rostro', 'manual', 'simulado') then
        raise_application_error(-20001, 'Metodo no valido: ' || p_metodo);
    end if;
    v_codigo := substr(trim(p_codigo), 1, 20);

    -- ---- punto de control y zona ----
    begin
        select pc.id_zona, pc.estado, z.tipo
          into v_id_zona, v_estado_punto, v_tipo_zona
          from puntos_control pc
          join zonas z on z.id_zona = pc.id_zona
         where pc.id_punto = p_id_punto;
    exception
        when no_data_found then
            raise_application_error(-20002,
                'El punto de control ' || p_id_punto || ' no existe');
    end;
    if v_estado_punto <> 'activo' then
        raise_application_error(-20003,
            'El punto de control ' || p_id_punto || ' esta inactivo');
    end if;

    -- ---- umbrales y hora local ----
    v_min_tardanza     := f_parametro_num('MIN_TARDANZA');
    v_min_max_tardanza := f_parametro_num('MIN_MAX_TARDANZA');
    v_intentos         := f_parametro_num('INTENTOS_PARA_INCIDENCIA');
    v_min_ventana      := f_parametro_num('MIN_VENTANA_INTENTOS');
    v_zona_horaria     := f_parametro('ZONA_HORARIA');

    -- asignacion directa: dentro de un SELECT, "at time zone <variable>" da ORA-00907
    v_hora_local := to_char(systimestamp at time zone v_zona_horaria, 'HH24:MI');

    -- ---- persona ----
    begin
        select id_persona, tipo, estado
          into v_id_persona, v_tipo, v_estado
          from personas
         where codigo = v_codigo;
    exception
        when no_data_found then
            v_id_persona := null;
    end;

    -- ---- decision (reglas a - e) ----
    if v_id_persona is null then
        v_motivo := 'codigo_inexistente';                              -- a
    elsif v_estado <> 'activo' then
        v_motivo := 'persona_inactiva';                                -- b
    elsif p_rostro_ok = 0 then
        v_motivo := 'rostro_no_coincide';                              -- c
    else
        select count(*)
          into v_n
          from restricciones
         where id_persona = v_id_persona
           and estado = 'vigente'
           and (fecha_fin is null or fecha_fin > sysdate);

        if v_n > 0 then
            v_motivo := 'persona_restringida';                         -- d
        elsif v_tipo = 'visitante' then                                -- e (visitante)
            select count(*)
              into v_n
              from pases
             where id_visitante = v_id_persona
               and estado = 'activo'
               and v_ahora >= vigente_desde
               and v_ahora <= vigente_hasta
               and (v_tipo_zona = 'puerta' or id_zona_destino = v_id_zona);
            if v_n = 0 then
                v_motivo := 'sin_pase_vigente';
            end if;
        else                                                           -- e (demas tipos)
            begin
                select hora_desde, hora_hasta
                  into v_desde, v_hasta
                  from permisos_zona
                 where tipo_persona = v_tipo
                   and id_zona = v_id_zona;
                if v_hora_local < v_desde or v_hora_local > v_hasta then
                    v_motivo := 'fuera_de_horario';
                end if;
            exception
                when no_data_found then
                    v_motivo := 'zona_no_autorizada';
            end;
        end if;
    end if;

    v_resultado := case when v_motivo is null then 'permitido' else 'denegado' end;

    -- ---- registro del acceso (permitido o denegado) ----
    insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                         resultado, motivo, metodo, confianza)
    values (v_id_persona, v_codigo, p_id_punto, v_ahora,
            v_resultado, v_motivo, v_metodo, p_confianza)
    returning id_acceso into v_id_acceso;

    if v_resultado = 'permitido' then
        -- ---- f. asistencia / inicio de sesion en aulas y laboratorios ----
        if v_tipo_zona in ('aula', 'laboratorio') then
            if v_tipo = 'estudiante' then
                open c_sesion(v_id_persona, v_id_zona, v_ahora, v_min_max_tardanza);
                fetch c_sesion into v_id_sesion, v_hora_inicio, v_estado_sesion;
                if c_sesion%found then
                    v_minutos := (cast(v_ahora as date) - cast(v_hora_inicio as date)) * 1440;
                    if v_minutos <= v_min_tardanza then
                        v_estado_asist := 'presente';
                    else
                        v_estado_asist := 'tardanza';
                    end if;

                    -- no duplicar ni degradar una asistencia ya registrada
                    begin
                        insert into asistencias (id_sesion, id_estudiante, estado,
                                                 hora_registro, id_acceso)
                        values (v_id_sesion, v_id_persona, v_estado_asist,
                                v_ahora, v_id_acceso);
                    exception
                        when dup_val_on_index then
                            null;
                    end;

                    if v_estado_sesion = 'programada' then
                        update sesiones
                           set estado = 'en_curso'
                         where id_sesion = v_id_sesion
                           and estado = 'programada';
                    end if;
                end if;
                close c_sesion;

            elsif v_tipo = 'docente' then
                -- el docente solo hace pasar la sesion de su aula a en_curso
                update sesiones s
                   set s.estado = 'en_curso'
                 where s.estado = 'programada'
                   and s.id_seccion in (select c.id_seccion
                                          from secciones c
                                         where c.id_docente = v_id_persona
                                           and c.id_aula = v_id_zona)
                   and v_ahora >= s.hora_inicio - numtodsinterval(c_min_antes, 'minute')
                   and v_ahora <= s.hora_inicio + numtodsinterval(v_min_max_tardanza, 'minute');
            end if;
        end if;
    else
        -- ---- d. incidencia por persona restringida ----
        if v_motivo = 'persona_restringida' then
            insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad,
                                     descripcion, fecha_hora, estado, origen)
            values (v_id_zona, v_id_persona, v_id_acceso, 'persona_restringida', 'alta',
                    'Intento de ingreso de persona con restriccion vigente: ' || v_codigo,
                    v_ahora, 'abierta', 'sistema');
        end if;

        -- ---- g. intentos reiterados en la misma zona ----
        select count(*)
          into v_n
          from accesos a
          join puntos_control pc on pc.id_punto = a.id_punto
         where a.resultado = 'denegado'
           and pc.id_zona = v_id_zona
           and a.fecha_hora >= v_ahora - numtodsinterval(v_min_ventana, 'minute')
           and (a.codigo_leido = v_codigo
                or (v_id_persona is not null and a.id_persona = v_id_persona));

        if v_n >= v_intentos then
            -- incidencia automatica equivalente que siga abierta
            select count(*)
              into v_n
              from incidencias
             where tipo = 'intentos_reiterados'
               and origen = 'sistema'
               and estado in ('abierta', 'en_revision')
               and id_zona = v_id_zona
               and ((v_id_persona is not null and id_persona = v_id_persona)
                    or (v_id_persona is null and id_persona is null
                        and instr(descripcion, '[' || v_codigo || ']') > 0));

            if v_n = 0 then
                insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad,
                                         descripcion, fecha_hora, estado, origen)
                values (v_id_zona, v_id_persona, v_id_acceso, 'intentos_reiterados', 'media',
                        'Intentos denegados reiterados (minimo ' || v_intentos || ' en '
                        || v_min_ventana || ' min). codigo=[' || v_codigo || ']',
                        v_ahora, 'abierta', 'sistema');
            end if;
        end if;
    end if;

    commit;

    o_resultado := v_resultado;
    o_motivo    := v_motivo;
    o_id_acceso := v_id_acceso;
exception
    when others then
        rollback;
        o_resultado := null;
        o_motivo    := null;
        o_id_acceso := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_registrar_acceso: ' || sqlerrm);
end p_registrar_acceso;
/

-- ---------------------------------------------------------------------
-- 3) p_cerrar_sesion
--    Cierra la sesion, registra "falta" para cada inscrito activo sin
--    asistencia (un solo INSERT ... SELECT), suma la falta en inscripciones
--    e inhabilita si faltas * 100 / sesiones cerradas >= LIMITE_FALTAS_PCT.
-- ---------------------------------------------------------------------
create or replace procedure p_cerrar_sesion (
    p_id_sesion     in  number,
    o_faltas        out number,
    o_inhabilitados out number
) is
    v_id_seccion  sesiones.id_seccion%type;
    v_estado      sesiones.estado%type;
    v_limite      number;
    v_cerradas    number;
begin
    o_faltas        := 0;
    o_inhabilitados := 0;

    if p_id_sesion is null then
        raise_application_error(-20001, 'La sesion es obligatoria');
    end if;

    v_limite := f_parametro_num('LIMITE_FALTAS_PCT');

    begin
        select id_seccion, estado
          into v_id_seccion, v_estado
          from sesiones
         where id_sesion = p_id_sesion
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002, 'La sesion ' || p_id_sesion || ' no existe');
    end;
    if v_estado = 'cerrada' then
        raise_application_error(-20003, 'La sesion ' || p_id_sesion || ' ya esta cerrada');
    end if;

    update sesiones
       set estado = 'cerrada'
     where id_sesion = p_id_sesion;

    -- suma la falta a los mismos inscritos a los que se les inserta abajo
    -- (inscripcion activa sin asistencia en esta sesion)
    update inscripciones i
       set i.faltas = i.faltas + 1
     where i.id_seccion = v_id_seccion
       and i.estado = 'activa'
       and not exists (select 1
                         from asistencias a
                        where a.id_sesion = p_id_sesion
                          and a.id_estudiante = i.id_estudiante);

    insert into asistencias (id_sesion, id_estudiante, estado, hora_registro, id_acceso)
    select p_id_sesion, i.id_estudiante, 'falta', null, null
      from inscripciones i
     where i.id_seccion = v_id_seccion
       and i.estado = 'activa'
       and not exists (select 1
                         from asistencias a
                        where a.id_sesion = p_id_sesion
                          and a.id_estudiante = i.id_estudiante);
    o_faltas := sql%rowcount;

    select count(*)
      into v_cerradas
      from sesiones
     where id_seccion = v_id_seccion
       and estado = 'cerrada';

    update inscripciones i
       set i.estado = 'inhabilitado'
     where i.id_seccion = v_id_seccion
       and i.estado = 'activa'
       and i.faltas * 100 / v_cerradas >= v_limite;
    o_inhabilitados := sql%rowcount;

    commit;
exception
    when others then
        rollback;
        o_faltas        := null;
        o_inhabilitados := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_cerrar_sesion: ' || sqlerrm);
end p_cerrar_sesion;
/

-- ---------------------------------------------------------------------
-- 4a) Pases de visitantes
-- ---------------------------------------------------------------------
create or replace procedure p_emitir_pase (
    p_id_visitante    in  number,
    p_id_anfitrion    in  number,
    p_id_zona_destino in  number,
    p_vigente_desde   in  timestamp,
    p_vigente_hasta   in  timestamp,
    p_motivo          in  varchar2,
    o_id_pase         out number
) is
    v_ahora   timestamp := systimestamp;
    v_desde   timestamp;
    v_tipo    personas.tipo%type;
    v_estado  personas.estado%type;
    v_n       number;
begin
    o_id_pase := null;

    if p_id_visitante is null or p_id_anfitrion is null
       or p_id_zona_destino is null or p_vigente_hasta is null then
        raise_application_error(-20001,
            'Visitante, anfitrion, zona destino y vigente_hasta son obligatorios');
    end if;
    if p_id_visitante = p_id_anfitrion then
        raise_application_error(-20001, 'El visitante y el anfitrion deben ser personas distintas');
    end if;

    v_desde := nvl(p_vigente_desde, v_ahora);
    if p_vigente_hasta <= v_desde then
        raise_application_error(-20001, 'vigente_hasta debe ser posterior a vigente_desde');
    end if;
    if p_vigente_hasta <= v_ahora then
        raise_application_error(-20001, 'El pase ya estaria vencido: vigente_hasta esta en el pasado');
    end if;

    -- visitante
    begin
        select tipo, estado into v_tipo, v_estado
          from personas where id_persona = p_id_visitante;
    exception
        when no_data_found then
            raise_application_error(-20002, 'El visitante ' || p_id_visitante || ' no existe');
    end;
    if v_tipo <> 'visitante' then
        raise_application_error(-20003, 'La persona ' || p_id_visitante || ' no es de tipo visitante');
    end if;
    if v_estado <> 'activo' then
        raise_application_error(-20003, 'El visitante ' || p_id_visitante || ' no esta activo');
    end if;

    -- anfitrion
    begin
        select tipo, estado into v_tipo, v_estado
          from personas where id_persona = p_id_anfitrion;
    exception
        when no_data_found then
            raise_application_error(-20002, 'El anfitrion ' || p_id_anfitrion || ' no existe');
    end;
    if v_tipo = 'visitante' then
        raise_application_error(-20003, 'Un visitante no puede ser anfitrion');
    end if;
    if v_estado <> 'activo' then
        raise_application_error(-20003, 'El anfitrion ' || p_id_anfitrion || ' no esta activo');
    end if;

    -- zona
    select count(*) into v_n from zonas where id_zona = p_id_zona_destino;
    if v_n = 0 then
        raise_application_error(-20002, 'La zona ' || p_id_zona_destino || ' no existe');
    end if;

    insert into pases (id_visitante, id_anfitrion, id_zona_destino,
                       vigente_desde, vigente_hasta, motivo, estado)
    values (p_id_visitante, p_id_anfitrion, p_id_zona_destino,
            v_desde, p_vigente_hasta, substr(trim(p_motivo), 1, 150), 'activo')
    returning id_pase into o_id_pase;

    commit;
exception
    when others then
        rollback;
        o_id_pase := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_emitir_pase: ' || sqlerrm);
end p_emitir_pase;
/

create or replace procedure p_revocar_pase (
    p_id_pase in number
) is
    v_estado pases.estado%type;
begin
    if p_id_pase is null then
        raise_application_error(-20001, 'El pase es obligatorio');
    end if;

    begin
        select estado into v_estado
          from pases
         where id_pase = p_id_pase
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002, 'El pase ' || p_id_pase || ' no existe');
    end;
    if v_estado = 'revocado' then
        raise_application_error(-20003, 'El pase ' || p_id_pase || ' ya esta revocado');
    end if;

    update pases set estado = 'revocado' where id_pase = p_id_pase;
    commit;
exception
    when others then
        rollback;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_revocar_pase: ' || sqlerrm);
end p_revocar_pase;
/

-- ---------------------------------------------------------------------
-- 4b) Restricciones
-- ---------------------------------------------------------------------
create or replace procedure p_registrar_restriccion (
    p_id_persona     in  number,
    p_motivo         in  varchar2,
    p_fecha_fin      in  date,
    o_id_restriccion out number
) is
    v_n number;
begin
    o_id_restriccion := null;

    if p_id_persona is null then
        raise_application_error(-20001, 'La persona es obligatoria');
    end if;
    if p_motivo is null or trim(p_motivo) is null then
        raise_application_error(-20001, 'El motivo de la restriccion es obligatorio');
    end if;
    if p_fecha_fin is not null and p_fecha_fin <= sysdate then
        raise_application_error(-20001, 'fecha_fin debe ser una fecha futura (o nula si es indefinida)');
    end if;

    select count(*) into v_n from personas where id_persona = p_id_persona;
    if v_n = 0 then
        raise_application_error(-20002, 'La persona ' || p_id_persona || ' no existe');
    end if;

    select count(*)
      into v_n
      from restricciones
     where id_persona = p_id_persona
       and estado = 'vigente'
       and (fecha_fin is null or fecha_fin > sysdate);
    if v_n > 0 then
        raise_application_error(-20005,
            'La persona ' || p_id_persona || ' ya tiene una restriccion vigente');
    end if;

    insert into restricciones (id_persona, motivo, fecha_inicio, fecha_fin, estado)
    values (p_id_persona, substr(trim(p_motivo), 1, 200), sysdate, p_fecha_fin, 'vigente')
    returning id_restriccion into o_id_restriccion;

    commit;
exception
    when others then
        rollback;
        o_id_restriccion := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_registrar_restriccion: ' || sqlerrm);
end p_registrar_restriccion;
/

create or replace procedure p_levantar_restriccion (
    p_id_restriccion in number
) is
    v_estado  restricciones.estado%type;
begin
    if p_id_restriccion is null then
        raise_application_error(-20001, 'La restriccion es obligatoria');
    end if;

    begin
        select estado into v_estado
          from restricciones
         where id_restriccion = p_id_restriccion
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002,
                'La restriccion ' || p_id_restriccion || ' no existe');
    end;
    if v_estado = 'levantada' then
        raise_application_error(-20003,
            'La restriccion ' || p_id_restriccion || ' ya esta levantada');
    end if;

    update restricciones
       set estado    = 'levantada',
           fecha_fin = case when fecha_fin is null or fecha_fin > sysdate
                            then greatest(sysdate, fecha_inicio)
                            else fecha_fin end
     where id_restriccion = p_id_restriccion;

    commit;
exception
    when others then
        rollback;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_levantar_restriccion: ' || sqlerrm);
end p_levantar_restriccion;
/

-- ---------------------------------------------------------------------
-- 4c) Incidencias registradas por el vigilante
-- ---------------------------------------------------------------------
create or replace procedure p_registrar_incidencia (
    p_id_zona        in  number,
    p_id_persona     in  number,
    p_id_acceso      in  number,
    p_tipo           in  varchar2,
    p_gravedad       in  varchar2,
    p_descripcion    in  varchar2,
    o_id_incidencia  out number
) is
    v_n number;
begin
    o_id_incidencia := null;

    if p_id_zona is null then
        raise_application_error(-20001, 'La zona es obligatoria');
    end if;
    if p_tipo is null or trim(p_tipo) is null then
        raise_application_error(-20001, 'El tipo de incidencia es obligatorio');
    end if;
    if p_gravedad is null or p_gravedad not in ('baja', 'media', 'alta') then
        raise_application_error(-20001, 'La gravedad debe ser baja, media o alta');
    end if;

    select count(*) into v_n from zonas where id_zona = p_id_zona;
    if v_n = 0 then
        raise_application_error(-20002, 'La zona ' || p_id_zona || ' no existe');
    end if;
    if p_id_persona is not null then
        select count(*) into v_n from personas where id_persona = p_id_persona;
        if v_n = 0 then
            raise_application_error(-20002, 'La persona ' || p_id_persona || ' no existe');
        end if;
    end if;
    if p_id_acceso is not null then
        select count(*) into v_n from accesos where id_acceso = p_id_acceso;
        if v_n = 0 then
            raise_application_error(-20002, 'El acceso ' || p_id_acceso || ' no existe');
        end if;
    end if;

    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad,
                             descripcion, fecha_hora, estado, origen)
    values (p_id_zona, p_id_persona, p_id_acceso, substr(trim(p_tipo), 1, 40), p_gravedad,
            substr(trim(p_descripcion), 1, 300), systimestamp, 'abierta', 'vigilante')
    returning id_incidencia into o_id_incidencia;

    commit;
exception
    when others then
        rollback;
        o_id_incidencia := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_registrar_incidencia: ' || sqlerrm);
end p_registrar_incidencia;
/

-- p_estado: 'en_revision' o 'resuelta' (por defecto 'resuelta').
-- El comentario se agrega al final de la descripcion.
create or replace procedure p_resolver_incidencia (
    p_id_incidencia in number,
    p_estado        in varchar2 default 'resuelta',
    p_comentario    in varchar2 default null
) is
    v_estado       incidencias.estado%type;
    v_descripcion  incidencias.descripcion%type;
    v_nota         varchar2(300);
begin
    if p_id_incidencia is null then
        raise_application_error(-20001, 'La incidencia es obligatoria');
    end if;
    if p_estado is null or p_estado not in ('en_revision', 'resuelta') then
        raise_application_error(-20001, 'El nuevo estado debe ser en_revision o resuelta');
    end if;

    begin
        select estado, descripcion
          into v_estado, v_descripcion
          from incidencias
         where id_incidencia = p_id_incidencia
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002,
                'La incidencia ' || p_id_incidencia || ' no existe');
    end;
    if v_estado = 'resuelta' then
        raise_application_error(-20003,
            'La incidencia ' || p_id_incidencia || ' ya esta resuelta');
    end if;

    if p_comentario is not null and trim(p_comentario) is not null then
        v_nota := ' | ' || p_estado || ' ' || to_char(sysdate, 'YYYY-MM-DD HH24:MI')
                  || ': ' || trim(p_comentario);
        v_descripcion := substr(nvl(v_descripcion, '') || v_nota, 1, 300);
    end if;

    update incidencias
       set estado      = p_estado,
           descripcion = v_descripcion
     where id_incidencia = p_id_incidencia;

    commit;
exception
    when others then
        rollback;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_resolver_incidencia: ' || sqlerrm);
end p_resolver_incidencia;
/

-- ---------------------------------------------------------------------
-- 4d) CRUD de personas (la clave publica es el codigo del QR)
-- ---------------------------------------------------------------------

-- Inserta en personas y en su subtipo (estudiantes / docentes) en una
-- sola transaccion.
create or replace procedure p_registrar_persona (
    p_codigo        in  varchar2,
    p_nombre        in  varchar2,
    p_dni           in  varchar2,
    p_correo        in  varchar2,
    p_tipo          in  varchar2,
    p_id_escuela    in  number,      -- solo estudiantes
    p_ciclo         in  number,      -- solo estudiantes
    p_especialidad  in  varchar2,    -- solo docentes
    o_id_persona    out number
) is
    v_n number;
begin
    o_id_persona := null;

    if p_codigo is null or not regexp_like(trim(p_codigo), '^[0-9]{8}$') then
        raise_application_error(-20001, 'El codigo debe tener exactamente 8 digitos');
    end if;
    if p_dni is null or not regexp_like(trim(p_dni), '^[0-9]{8}$') then
        raise_application_error(-20001, 'El DNI debe tener exactamente 8 digitos');
    end if;
    if p_nombre is null or trim(p_nombre) is null then
        raise_application_error(-20001, 'El nombre es obligatorio');
    end if;
    if p_tipo is null
       or p_tipo not in ('estudiante', 'docente', 'visitante', 'vigilante', 'administrativo') then
        raise_application_error(-20001, 'Tipo de persona no valido: ' || p_tipo);
    end if;
    if p_correo is not null and not regexp_like(trim(p_correo), '^[^@ ]+@[^@ ]+\.[^@ ]+$') then
        raise_application_error(-20001, 'El correo no tiene un formato valido');
    end if;

    if p_tipo = 'estudiante' then
        if p_id_escuela is null or p_ciclo is null then
            raise_application_error(-20001, 'Un estudiante necesita escuela y ciclo');
        end if;
        if p_ciclo not between 1 and 12 then
            raise_application_error(-20001, 'El ciclo debe estar entre 1 y 12');
        end if;
        select count(*) into v_n from escuelas where id_escuela = p_id_escuela;
        if v_n = 0 then
            raise_application_error(-20002, 'La escuela ' || p_id_escuela || ' no existe');
        end if;
    end if;

    select count(*) into v_n from personas where codigo = trim(p_codigo);
    if v_n > 0 then
        raise_application_error(-20005, 'Ya existe una persona con el codigo ' || trim(p_codigo));
    end if;
    select count(*) into v_n from personas where dni = trim(p_dni);
    if v_n > 0 then
        raise_application_error(-20005, 'Ya existe una persona con el DNI ' || trim(p_dni));
    end if;

    insert into personas (codigo, nombre, dni, correo, tipo, estado)
    values (trim(p_codigo), trim(p_nombre), trim(p_dni), trim(p_correo), p_tipo, 'activo')
    returning id_persona into o_id_persona;

    if p_tipo = 'estudiante' then
        insert into estudiantes (id_estudiante, id_escuela, ciclo)
        values (o_id_persona, p_id_escuela, p_ciclo);
    elsif p_tipo = 'docente' then
        insert into docentes (id_docente, especialidad)
        values (o_id_persona, trim(p_especialidad));
    end if;

    commit;
exception
    when dup_val_on_index then
        rollback;
        o_id_persona := null;
        raise_application_error(-20005, 'Ya existe una persona con ese codigo o DNI');
    when others then
        rollback;
        o_id_persona := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_registrar_persona: ' || sqlerrm);
end p_registrar_persona;
/

-- Los parametros nulos significan "no cambiar". El tipo y el codigo no se
-- pueden modificar. Escuela y ciclo solo aplican a estudiantes y la
-- especialidad solo a docentes (en otros tipos se ignoran).
create or replace procedure p_modificar_persona (
    p_codigo        in varchar2,
    p_nombre        in varchar2 default null,
    p_dni           in varchar2 default null,
    p_correo        in varchar2 default null,
    p_estado        in varchar2 default null,
    p_id_escuela    in number   default null,
    p_ciclo         in number   default null,
    p_especialidad  in varchar2 default null
) is
    v_id    personas.id_persona%type;
    v_tipo  personas.tipo%type;
    v_n     number;
begin
    if p_codigo is null or trim(p_codigo) is null then
        raise_application_error(-20001, 'El codigo de la persona es obligatorio');
    end if;
    if p_nombre is null and p_dni is null and p_correo is null and p_estado is null
       and p_id_escuela is null and p_ciclo is null and p_especialidad is null then
        raise_application_error(-20001, 'Indique al menos un dato a modificar');
    end if;
    if p_dni is not null and not regexp_like(trim(p_dni), '^[0-9]{8}$') then
        raise_application_error(-20001, 'El DNI debe tener exactamente 8 digitos');
    end if;
    if p_correo is not null and not regexp_like(trim(p_correo), '^[^@ ]+@[^@ ]+\.[^@ ]+$') then
        raise_application_error(-20001, 'El correo no tiene un formato valido');
    end if;
    if p_estado is not null and p_estado not in ('activo', 'inactivo', 'suspendido') then
        raise_application_error(-20001, 'Estado no valido: ' || p_estado);
    end if;
    if p_ciclo is not null and p_ciclo not between 1 and 12 then
        raise_application_error(-20001, 'El ciclo debe estar entre 1 y 12');
    end if;

    begin
        select id_persona, tipo
          into v_id, v_tipo
          from personas
         where codigo = trim(p_codigo)
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002, 'No existe la persona con codigo ' || trim(p_codigo));
    end;

    if p_dni is not null then
        select count(*) into v_n
          from personas
         where dni = trim(p_dni) and id_persona <> v_id;
        if v_n > 0 then
            raise_application_error(-20005, 'Ya existe otra persona con el DNI ' || trim(p_dni));
        end if;
    end if;

    update personas
       set nombre = nvl(trim(p_nombre), nombre),
           dni    = nvl(trim(p_dni), dni),
           correo = nvl(trim(p_correo), correo),
           estado = nvl(p_estado, estado)
     where id_persona = v_id;

    if v_tipo = 'estudiante' and (p_id_escuela is not null or p_ciclo is not null) then
        if p_id_escuela is not null then
            select count(*) into v_n from escuelas where id_escuela = p_id_escuela;
            if v_n = 0 then
                raise_application_error(-20002, 'La escuela ' || p_id_escuela || ' no existe');
            end if;
        end if;
        update estudiantes
           set id_escuela = nvl(p_id_escuela, id_escuela),
               ciclo      = nvl(p_ciclo, ciclo)
         where id_estudiante = v_id;
    elsif v_tipo = 'docente' and p_especialidad is not null then
        update docentes
           set especialidad = trim(p_especialidad)
         where id_docente = v_id;
    end if;

    commit;
exception
    when dup_val_on_index then
        rollback;
        raise_application_error(-20005, 'Ya existe otra persona con ese DNI');
    when others then
        rollback;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_modificar_persona: ' || sqlerrm);
end p_modificar_persona;
/

-- Baja logica (estado = inactivo) si la persona tiene historial: accesos,
-- inscripciones, asistencias, restricciones, pases, incidencias o secciones
-- a su cargo. Sin historial se elimina fisicamente (subtipo y persona).
-- o_accion devuelve 'baja_logica' o 'eliminada'.
create or replace procedure p_eliminar_persona (
    p_codigo  in  varchar2,
    o_accion  out varchar2
) is
    v_id  personas.id_persona%type;
    v_n   number;
begin
    o_accion := null;

    if p_codigo is null or trim(p_codigo) is null then
        raise_application_error(-20001, 'El codigo de la persona es obligatorio');
    end if;

    begin
        select id_persona
          into v_id
          from personas
         where codigo = trim(p_codigo)
           for update;
    exception
        when no_data_found then
            raise_application_error(-20002, 'No existe la persona con codigo ' || trim(p_codigo));
    end;

    select (select count(*) from accesos       where id_persona = v_id)
         + (select count(*) from inscripciones where id_estudiante = v_id)
         + (select count(*) from asistencias   where id_estudiante = v_id)
         + (select count(*) from restricciones where id_persona = v_id)
         + (select count(*) from pases         where id_visitante = v_id or id_anfitrion = v_id)
         + (select count(*) from incidencias   where id_persona = v_id)
         + (select count(*) from secciones     where id_docente = v_id)
      into v_n
      from dual;

    if v_n > 0 then
        update personas set estado = 'inactivo' where id_persona = v_id;
        o_accion := 'baja_logica';
    else
        delete from estudiantes where id_estudiante = v_id;
        delete from docentes    where id_docente = v_id;
        delete from personas    where id_persona = v_id;
        o_accion := 'eliminada';
    end if;

    commit;
exception
    when others then
        rollback;
        o_accion := null;
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'p_eliminar_persona: ' || sqlerrm);
end p_eliminar_persona;
/

create or replace procedure p_listar_personas (
    o_cursor out sys_refcursor
) is
begin
    open o_cursor for
        select p.id_persona, p.codigo, p.nombre, p.dni, p.correo, p.tipo, p.estado,
               p.fecha_registro,
               e.nombre   as escuela,
               s.ciclo,
               d.especialidad
          from personas p
          left join estudiantes s on s.id_estudiante = p.id_persona
          left join escuelas    e on e.id_escuela    = s.id_escuela
          left join docentes    d on d.id_docente    = p.id_persona
         order by p.id_persona;
exception
    when others then
        raise_application_error(-20099, 'p_listar_personas: ' || sqlerrm);
end p_listar_personas;
/

-- Filtros opcionales: texto (codigo, nombre o DNI), tipo y estado.
create or replace procedure p_buscar_personas (
    p_texto   in  varchar2,
    p_tipo    in  varchar2,
    p_estado  in  varchar2,
    o_cursor  out sys_refcursor
) is
    v_texto varchar2(102) := '%' || lower(trim(p_texto)) || '%';
begin
    open o_cursor for
        select p.id_persona, p.codigo, p.nombre, p.dni, p.correo, p.tipo, p.estado,
               p.fecha_registro,
               e.nombre   as escuela,
               s.ciclo,
               d.especialidad
          from personas p
          left join estudiantes s on s.id_estudiante = p.id_persona
          left join escuelas    e on e.id_escuela    = s.id_escuela
          left join docentes    d on d.id_docente    = p.id_persona
         where (p_texto is null
                or lower(p.codigo) like v_texto
                or lower(p.nombre) like v_texto
                or p.dni like v_texto)
           and (p_tipo   is null or p.tipo   = p_tipo)
           and (p_estado is null or p.estado = p_estado)
         order by p.id_persona;
exception
    when others then
        raise_application_error(-20099, 'p_buscar_personas: ' || sqlerrm);
end p_buscar_personas;
/

-- ---------------------------------------------------------------------
-- Verificacion de compilacion (no debe listar errores)
-- ---------------------------------------------------------------------
prompt
prompt === Errores de compilacion (debe salir vacio) ===
column name   format a28
column type   format a12
column text   format a90
select name, type, line, position, text
  from user_errors
 order by name, type, sequence;

prompt
prompt === Procedimientos y funciones ===
column object_name format a28
select object_name, object_type, status
  from user_objects
 where object_type in ('PROCEDURE', 'FUNCTION')
 order by object_type, object_name;

commit;
