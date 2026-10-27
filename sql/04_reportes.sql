set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 220
set pagesize 100
whenever sqlerror continue

-- =====================================================================
-- 04_reportes.sql
-- Reportes estructurados: procedimientos r_* que devuelven un SYS_REFCURSOR
-- como ultimo parametro (o_cursor). El cliente abre, recorre y cierra el
-- cursor. Propietario: ACCESO_OWNER.
--   docker cp sql/04_reportes.sql oracle-xe:/tmp/04_reportes.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/04_reportes.sql
--
-- Uso desde SQL*Plus:
--   variable c refcursor
--   exec r_asistencia_seccion(1, :c)
--   print c
--
-- Errores: -20001 entrada invalida, -20002 registro inexistente,
-- -20099 error inesperado. Las fechas desde/hasta son inclusivas y un valor
-- nulo significa "sin limite".
-- =====================================================================

-- ---------------------------------------------------------------------
-- r_asistencia_seccion: resumen de asistencia por estudiante de una seccion
-- (solo sesiones cerradas)
-- ---------------------------------------------------------------------
create or replace procedure r_asistencia_seccion (
    p_id_seccion in  number,
    o_cursor     out sys_refcursor
) is
    v_n number;
begin
    if p_id_seccion is null then
        raise_application_error(-20001, 'La seccion es obligatoria');
    end if;
    select count(*) into v_n from secciones where id_seccion = p_id_seccion;
    if v_n = 0 then
        raise_application_error(-20002, 'La seccion ' || p_id_seccion || ' no existe');
    end if;

    open o_cursor for
        select p.codigo,
               p.nombre,
               count(case when a.estado = 'presente' then 1 end) as presentes,
               count(case when a.estado = 'tardanza' then 1 end) as tardanzas,
               count(case when a.estado = 'falta'    then 1 end) as faltas,
               ses.cerradas                                      as sesiones_cerradas,
               round(100 * count(case when a.estado in ('presente', 'tardanza') then 1 end)
                     / nullif(ses.cerradas, 0), 1)               as pct_asistencia,
               i.estado                                          as estado_inscripcion
          from inscripciones i
          join personas p on p.id_persona = i.id_estudiante
         cross join (select count(*) as cerradas
                       from sesiones
                      where id_seccion = p_id_seccion
                        and estado = 'cerrada') ses
          left join (select a2.id_estudiante, a2.estado
                       from asistencias a2
                       join sesiones s2 on s2.id_sesion = a2.id_sesion
                      where s2.id_seccion = p_id_seccion
                        and s2.estado = 'cerrada') a
                 on a.id_estudiante = i.id_estudiante
         where i.id_seccion = p_id_seccion
         group by p.codigo, p.nombre, ses.cerradas, i.estado
         order by p.codigo;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_asistencia_seccion: ' || sqlerrm);
end r_asistencia_seccion;
/

-- ---------------------------------------------------------------------
-- r_asistencia_sesion: detalle de una sesion (un registro por inscrito)
-- ---------------------------------------------------------------------
create or replace procedure r_asistencia_sesion (
    p_id_sesion in  number,
    o_cursor    out sys_refcursor
) is
    v_id_seccion sesiones.id_seccion%type;
begin
    if p_id_sesion is null then
        raise_application_error(-20001, 'La sesion es obligatoria');
    end if;
    begin
        select id_seccion into v_id_seccion from sesiones where id_sesion = p_id_sesion;
    exception
        when no_data_found then
            raise_application_error(-20002, 'La sesion ' || p_id_sesion || ' no existe');
    end;

    open o_cursor for
        select p.codigo,
               p.nombre,
               nvl(a.estado, 'sin_registro')            as asistencia,
               to_char(a.hora_registro, 'HH24:MI:SS')   as hora_registro,
               a.id_acceso,
               i.estado                                 as estado_inscripcion
          from inscripciones i
          join personas p on p.id_persona = i.id_estudiante
          left join asistencias a
                 on a.id_sesion = p_id_sesion
                and a.id_estudiante = i.id_estudiante
         where i.id_seccion = v_id_seccion
         order by p.codigo;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_asistencia_sesion: ' || sqlerrm);
end r_asistencia_sesion;
/

-- ---------------------------------------------------------------------
-- r_alumnos_en_riesgo: estudiantes inhabilitados o a una falta de serlo
-- (nivel = en_riesgo cuando (faltas + 1) * 100 / sesiones cerradas alcanza
-- LIMITE_FALTAS_PCT). p_id_seccion nulo = todas las secciones.
-- ---------------------------------------------------------------------
create or replace procedure r_alumnos_en_riesgo (
    p_id_seccion in  number,
    o_cursor     out sys_refcursor
) is
    v_limite number;
    v_n      number;
begin
    v_limite := f_parametro_num('LIMITE_FALTAS_PCT');
    if p_id_seccion is not null then
        select count(*) into v_n from secciones where id_seccion = p_id_seccion;
        if v_n = 0 then
            raise_application_error(-20002, 'La seccion ' || p_id_seccion || ' no existe');
        end if;
    end if;

    open o_cursor for
        select *
          from (
                select sec.id_seccion,
                       c.codigo                                       as curso,
                       sec.grupo,
                       p.codigo,
                       p.nombre,
                       i.faltas,
                       ses.cerradas                                   as sesiones_cerradas,
                       round(i.faltas * 100 / ses.cerradas, 1)        as pct_faltas,
                       v_limite                                       as limite_pct,
                       case when i.estado = 'inhabilitado' then 'inhabilitado'
                            when (i.faltas + 1) * 100 / ses.cerradas >= v_limite then 'en_riesgo'
                       end                                            as nivel
                  from inscripciones i
                  join secciones sec on sec.id_seccion = i.id_seccion
                  join cursos    c   on c.id_curso     = sec.id_curso
                  join personas  p   on p.id_persona   = i.id_estudiante
                  join (select id_seccion, count(*) as cerradas
                          from sesiones
                         where estado = 'cerrada'
                         group by id_seccion) ses
                    on ses.id_seccion = i.id_seccion
                 where i.estado in ('activa', 'inhabilitado')
                   and (p_id_seccion is null or i.id_seccion = p_id_seccion)
               )
         where nivel is not null
         order by pct_faltas desc, codigo, id_seccion;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_alumnos_en_riesgo: ' || sqlerrm);
end r_alumnos_en_riesgo;
/

-- ---------------------------------------------------------------------
-- r_ranking_tardanzas: estudiantes con mas tardanzas entre dos fechas
-- (por la fecha de la sesion), con RANK()
-- ---------------------------------------------------------------------
create or replace procedure r_ranking_tardanzas (
    p_desde  in  date,
    p_hasta  in  date,
    o_cursor out sys_refcursor
) is
begin
    if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
        raise_application_error(-20001, 'La fecha desde no puede ser posterior a la fecha hasta');
    end if;

    open o_cursor for
        select rank() over (order by tardanzas desc)         as puesto,
               codigo,
               nombre,
               tardanzas,
               asistidas,
               round(100 * tardanzas / asistidas, 1)         as pct_tardanza
          from (
                select p.codigo,
                       p.nombre,
                       count(case when a.estado = 'tardanza' then 1 end) as tardanzas,
                       count(*)                                          as asistidas
                  from asistencias a
                  join sesiones s on s.id_sesion = a.id_sesion
                  join personas p on p.id_persona = a.id_estudiante
                 where a.estado in ('presente', 'tardanza')
                   and (p_desde is null or s.hora_inicio >= p_desde)
                   and (p_hasta is null or s.hora_inicio <  p_hasta + 1)
                 group by p.codigo, p.nombre
                having count(case when a.estado = 'tardanza' then 1 end) > 0
               )
         order by puesto, codigo;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_ranking_tardanzas: ' || sqlerrm);
end r_ranking_tardanzas;
/

-- ---------------------------------------------------------------------
-- r_accesos_denegados: denegados agrupados por motivo y zona, con subtotal
-- por motivo y total general (GROUP BY ROLLUP)
-- ---------------------------------------------------------------------
create or replace procedure r_accesos_denegados (
    p_desde  in  date,
    p_hasta  in  date,
    o_cursor out sys_refcursor
) is
begin
    if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
        raise_application_error(-20001, 'La fecha desde no puede ser posterior a la fecha hasta');
    end if;

    open o_cursor for
        select case when grouping(a.motivo) = 1 then 'TOTAL GENERAL' else a.motivo end as motivo,
               case when grouping(z.nombre) = 1
                    then case when grouping(a.motivo) = 1 then '-' else 'Subtotal del motivo' end
                    else z.nombre end                                                  as zona,
               count(*)                                                                as total,
               count(distinct a.codigo_leido)                                          as codigos_distintos,
               to_char(min(a.fecha_hora), 'YYYY-MM-DD HH24:MI')                        as primero,
               to_char(max(a.fecha_hora), 'YYYY-MM-DD HH24:MI')                        as ultimo
          from accesos a
          join puntos_control pc on pc.id_punto = a.id_punto
          join zonas z           on z.id_zona   = pc.id_zona
         where a.resultado = 'denegado'
           and (p_desde is null or a.fecha_hora >= p_desde)
           and (p_hasta is null or a.fecha_hora <  p_hasta + 1)
         group by rollup (a.motivo, z.nombre)
         order by grouping(a.motivo), a.motivo, grouping(z.nombre), count(*) desc, z.nombre;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_accesos_denegados: ' || sqlerrm);
end r_accesos_denegados;
/

-- ---------------------------------------------------------------------
-- r_incidencias: filtros opcionales por estado y gravedad; las mas graves
-- primero
-- ---------------------------------------------------------------------
create or replace procedure r_incidencias (
    p_estado   in  varchar2,
    p_gravedad in  varchar2,
    o_cursor   out sys_refcursor
) is
begin
    if p_estado is not null and p_estado not in ('abierta', 'en_revision', 'resuelta') then
        raise_application_error(-20001, 'Estado no valido: ' || p_estado);
    end if;
    if p_gravedad is not null and p_gravedad not in ('baja', 'media', 'alta') then
        raise_application_error(-20001, 'Gravedad no valida: ' || p_gravedad);
    end if;

    open o_cursor for
        select i.id_incidencia,
               to_char(i.fecha_hora, 'YYYY-MM-DD HH24:MI') as fecha,
               z.nombre                                    as zona,
               i.tipo,
               i.gravedad,
               i.estado,
               i.origen,
               p.codigo                                    as codigo_persona,
               p.nombre                                    as persona,
               i.id_acceso,
               i.descripcion
          from incidencias i
          join zonas z          on z.id_zona    = i.id_zona
          left join personas p  on p.id_persona = i.id_persona
         where (p_estado   is null or i.estado   = p_estado)
           and (p_gravedad is null or i.gravedad = p_gravedad)
         order by case i.gravedad when 'alta' then 1 when 'media' then 2 else 3 end,
                  i.fecha_hora desc;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_incidencias: ' || sqlerrm);
end r_incidencias;
/

-- ---------------------------------------------------------------------
-- r_pases_vigentes: pases activos y dentro de su vigencia ahora
-- ---------------------------------------------------------------------
create or replace procedure r_pases_vigentes (
    o_cursor out sys_refcursor
) is
    v_ahora timestamp := systimestamp;
begin
    open o_cursor for
        select pa.id_pase,
               v.codigo                                          as codigo_visitante,
               v.nombre                                          as visitante,
               a.nombre                                          as anfitrion,
               z.nombre                                          as zona_destino,
               to_char(pa.vigente_desde, 'YYYY-MM-DD HH24:MI')   as desde,
               to_char(pa.vigente_hasta, 'YYYY-MM-DD HH24:MI')   as hasta,
               round((cast(pa.vigente_hasta as date) - sysdate) * 24, 1) as horas_restantes,
               pa.motivo
          from pases pa
          join personas v on v.id_persona = pa.id_visitante
          join personas a on a.id_persona = pa.id_anfitrion
          join zonas z    on z.id_zona    = pa.id_zona_destino
         where pa.estado = 'activo'
           and v_ahora >= pa.vigente_desde
           and v_ahora <= pa.vigente_hasta
         order by pa.vigente_hasta, pa.id_pase;
exception
    when others then
        raise_application_error(-20099, 'r_pases_vigentes: ' || sqlerrm);
end r_pases_vigentes;
/

-- ---------------------------------------------------------------------
-- r_uso_aulas_vs_sesiones: para una fecha, compara por aula/laboratorio las
-- sesiones programadas con el uso real (accesos permitidos y asistentes).
-- p_fecha nula = hoy.
-- ---------------------------------------------------------------------
create or replace procedure r_uso_aulas_vs_sesiones (
    p_fecha  in  date,
    o_cursor out sys_refcursor
) is
    v_dia date := trunc(nvl(p_fecha, sysdate));
begin
    open o_cursor for
        with
        aulas as (
            select id_zona, nombre, tipo, aforo
              from zonas
             where tipo in ('aula', 'laboratorio')
        ),
        ses as (
            select x.id_zona, count(*) as sesiones, sum(x.inscritos) as inscritos
              from (
                    select sec.id_aula as id_zona,
                           s.id_sesion,
                           (select count(*)
                              from inscripciones i
                             where i.id_seccion = s.id_seccion
                               and i.estado = 'activa') as inscritos
                      from sesiones s
                      join secciones sec on sec.id_seccion = s.id_seccion
                     where s.hora_inicio >= v_dia
                       and s.hora_inicio <  v_dia + 1
                   ) x
             group by x.id_zona
        ),
        acc as (
            select pc.id_zona,
                   count(*)                     as accesos,
                   count(distinct a.id_persona) as personas
              from accesos a
              join puntos_control pc on pc.id_punto = a.id_punto
             where a.resultado = 'permitido'
               and a.fecha_hora >= v_dia
               and a.fecha_hora <  v_dia + 1
             group by pc.id_zona
        ),
        asi as (
            select sec.id_aula as id_zona,
                   count(distinct a.id_estudiante) as asistentes
              from asistencias a
              join sesiones s    on s.id_sesion  = a.id_sesion
              join secciones sec on sec.id_seccion = s.id_seccion
             where a.estado in ('presente', 'tardanza')
               and s.hora_inicio >= v_dia
               and s.hora_inicio <  v_dia + 1
             group by sec.id_aula
        )
        select to_char(v_dia, 'YYYY-MM-DD')           as fecha,
               z.nombre                               as zona,
               z.tipo,
               z.aforo,
               nvl(ses.sesiones, 0)                   as sesiones,
               nvl(ses.inscritos, 0)                  as inscritos_esperados,
               nvl(acc.accesos, 0)                    as accesos_permitidos,
               nvl(acc.personas, 0)                   as personas_distintas,
               nvl(asi.asistentes, 0)                 as asistentes,
               case when z.aforo is null then null
                    else round(nvl(acc.personas, 0) * 100 / z.aforo, 1) end as ocupacion_pct,
               case when nvl(ses.sesiones, 0) = 0 and nvl(acc.accesos, 0) > 0
                         then 'uso sin sesion programada'
                    when nvl(ses.sesiones, 0) > 0 and nvl(acc.accesos, 0) = 0
                         then 'sesion sin accesos'
                    when nvl(ses.sesiones, 0) = 0
                         then 'sin actividad'
                    else 'normal' end                 as observacion
          from aulas z
          left join ses on ses.id_zona = z.id_zona
          left join acc on acc.id_zona = z.id_zona
          left join asi on asi.id_zona = z.id_zona
         order by z.id_zona;
exception
    when others then
        raise_application_error(-20099, 'r_uso_aulas_vs_sesiones: ' || sqlerrm);
end r_uso_aulas_vs_sesiones;
/

-- ---------------------------------------------------------------------
-- r_flujo_por_hora: las 24 horas de una fecha con permitidos, denegados,
-- entradas y salidas segun el sentido del punto. p_fecha nula = hoy;
-- p_id_zona nulo = todas las zonas.
-- ---------------------------------------------------------------------
create or replace procedure r_flujo_por_hora (
    p_fecha    in  date,
    p_id_zona  in  number,
    o_cursor   out sys_refcursor
) is
    v_dia date := trunc(nvl(p_fecha, sysdate));
    v_n   number;
begin
    if p_id_zona is not null then
        select count(*) into v_n from zonas where id_zona = p_id_zona;
        if v_n = 0 then
            raise_application_error(-20002, 'La zona ' || p_id_zona || ' no existe');
        end if;
    end if;

    open o_cursor for
        select to_char(h.n, 'FM00') || ':00'                                             as hora,
               count(case when x.resultado = 'permitido' then 1 end)                     as permitidos,
               count(case when x.resultado = 'denegado'  then 1 end)                     as denegados,
               count(x.id_acceso)                                                        as total,
               count(case when x.resultado = 'permitido' and x.sentido = 'entrada' then 1 end) as entradas,
               count(case when x.resultado = 'permitido' and x.sentido = 'salida'  then 1 end) as salidas,
               count(distinct x.id_persona)                                              as personas_distintas
          from (select level - 1 as n from dual connect by level <= 24) h
          left join (
                select a.id_acceso, a.id_persona, a.resultado, a.fecha_hora, pc.sentido
                  from accesos a
                  join puntos_control pc on pc.id_punto = a.id_punto
                 where a.fecha_hora >= v_dia
                   and a.fecha_hora <  v_dia + 1
                   and (p_id_zona is null or pc.id_zona = p_id_zona)
               ) x
            on extract(hour from x.fecha_hora) = h.n
         group by h.n
         order by h.n;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_flujo_por_hora: ' || sqlerrm);
end r_flujo_por_hora;
/

-- ---------------------------------------------------------------------
-- Verificacion de compilacion (no debe listar errores)
-- ---------------------------------------------------------------------
prompt
prompt === Errores de compilacion (debe salir vacio) ===
column name format a28
column type format a12
column text format a90
select name, type, line, position, text
  from user_errors
 where name like 'R\_%' escape '\'
 order by name, sequence;

prompt
prompt === Reportes ===
column object_name format a28
select object_name, object_type, status
  from user_objects
 where object_name like 'R\_%' escape '\'
 order by object_name;

commit;
