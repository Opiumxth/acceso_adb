set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 220
set pagesize 100
whenever sqlerror continue

-- 04_reportes.sql
-- Reportes estructurados: procedimientos r_* que devuelven un SYS_REFCURSOR
-- como ultimo parametro (o_cursor). El cliente abre, recorre y cierra el
-- cursor. Propietario: ACCESO_OWNER.
--   docker cp sql/04_reportes.sql oracle-xe:/tmp/04_reportes.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/04_reportes.sql

-- Uso desde SQL*Plus:
--   variable c refcursor
--   exec r_asistencia_seccion(1, :c)
--   print c

-- Errores: -20001 entrada invalida, -20002 registro inexistente,
-- -20099 error inesperado. Las fechas desde/hasta son inclusivas y un valor
-- nulo significa "sin limite".

-- HORA LOCAL: las marcas de tiempo estan guardadas en hora del servidor. Los
-- reportes interpretan las fechas que reciben como dias de la hora local
-- (parametro ZONA_HORARIA) y muestran las horas en hora local. f_desfase (01)
-- da la diferencia servidor - local en dias.

-- r_asistencia_seccion: resumen de asistencia por estudiante de una seccion
-- (solo sesiones cerradas)
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

-- r_asistencia_sesion: detalle de una sesion (un registro por inscrito);
-- la hora de registro se muestra en hora local
create or replace procedure r_asistencia_sesion (
    p_id_sesion in  number,
    o_cursor    out sys_refcursor
) is
    v_id_seccion sesiones.id_seccion%type;
    v_off        interval day to second;
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
    v_off := numtodsinterval(f_desfase * 1440, 'minute');

    open o_cursor for
        select p.codigo,
               p.nombre,
               nvl(a.estado, 'sin_registro')                      as asistencia,
               to_char(a.hora_registro - v_off, 'HH24:MI:SS')     as hora_registro,
               a.id_acceso,
               i.estado                                           as estado_inscripcion
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

-- r_alumnos_en_riesgo: estudiantes inhabilitados o a una falta de serlo
-- (nivel = en_riesgo cuando (faltas + 1) * 100 / sesiones cerradas alcanza
-- LIMITE_FALTAS_PCT). p_id_seccion nulo = todas las secciones.
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

-- r_ranking_tardanzas: estudiantes con mas tardanzas entre dos fechas
-- (dias de la hora local, segun el inicio de la sesion), con RANK()
create or replace procedure r_ranking_tardanzas (
    p_desde  in  date,
    p_hasta  in  date,
    o_cursor out sys_refcursor
) is
    v_desf  number;
    v_ini   timestamp;
    v_fin   timestamp;
begin
    if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
        raise_application_error(-20001, 'La fecha desde no puede ser posterior a la fecha hasta');
    end if;
    v_desf := f_desfase;
    v_ini  := case when p_desde is null then null
                   else cast(trunc(p_desde) + v_desf as timestamp) end;
    v_fin  := case when p_hasta is null then null
                   else cast(trunc(p_hasta) + 1 + v_desf as timestamp) end;

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
                   and (v_ini is null or s.hora_inicio >= v_ini)
                   and (v_fin is null or s.hora_inicio <  v_fin)
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

-- r_accesos_denegados: denegados agrupados por motivo y zona, con subtotal
-- por motivo y total general (GROUP BY ROLLUP). Fechas = dias de hora local.
create or replace procedure r_accesos_denegados (
    p_desde  in  date,
    p_hasta  in  date,
    o_cursor out sys_refcursor
) is
    v_desf  number;
    v_off   interval day to second;
    v_ini   timestamp;
    v_fin   timestamp;
begin
    if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
        raise_application_error(-20001, 'La fecha desde no puede ser posterior a la fecha hasta');
    end if;
    v_desf := f_desfase;
    v_off  := numtodsinterval(v_desf * 1440, 'minute');
    v_ini  := case when p_desde is null then null
                   else cast(trunc(p_desde) + v_desf as timestamp) end;
    v_fin  := case when p_hasta is null then null
                   else cast(trunc(p_hasta) + 1 + v_desf as timestamp) end;

    open o_cursor for
        select case when grouping(a.motivo) = 1 then 'TOTAL GENERAL' else a.motivo end as motivo,
               case when grouping(z.nombre) = 1
                    then case when grouping(a.motivo) = 1 then '-' else 'Subtotal del motivo' end
                    else z.nombre end                                                  as zona,
               count(*)                                                                as total,
               count(distinct a.codigo_leido)                                          as codigos_distintos,
               to_char(min(a.fecha_hora) - v_off, 'YYYY-MM-DD HH24:MI')                as primero,
               to_char(max(a.fecha_hora) - v_off, 'YYYY-MM-DD HH24:MI')                as ultimo
          from accesos a
          join puntos_control pc on pc.id_punto = a.id_punto
          join zonas z           on z.id_zona   = pc.id_zona
         where a.resultado = 'denegado'
           and (v_ini is null or a.fecha_hora >= v_ini)
           and (v_fin is null or a.fecha_hora <  v_fin)
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

-- r_incidencias: filtros opcionales por estado y gravedad; las mas graves
-- primero. La fecha se muestra en hora local.
create or replace procedure r_incidencias (
    p_estado   in  varchar2,
    p_gravedad in  varchar2,
    o_cursor   out sys_refcursor
) is
    v_off interval day to second;
begin
    if p_estado is not null and p_estado not in ('abierta', 'en_revision', 'resuelta') then
        raise_application_error(-20001, 'Estado no valido: ' || p_estado);
    end if;
    if p_gravedad is not null and p_gravedad not in ('baja', 'media', 'alta') then
        raise_application_error(-20001, 'Gravedad no valida: ' || p_gravedad);
    end if;
    v_off := numtodsinterval(f_desfase * 1440, 'minute');

    open o_cursor for
        select i.id_incidencia,
               to_char(i.fecha_hora - v_off, 'YYYY-MM-DD HH24:MI') as fecha,
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

-- r_pases_vigentes: pases activos y dentro de su vigencia ahora; las horas
-- se muestran en hora local
create or replace procedure r_pases_vigentes (
    o_cursor out sys_refcursor
) is
    v_ahora timestamp := systimestamp;
    v_off   interval day to second;
begin
    v_off := numtodsinterval(f_desfase * 1440, 'minute');

    open o_cursor for
        select pa.id_pase,
               v.codigo                                                   as codigo_visitante,
               v.nombre                                                   as visitante,
               a.nombre                                                   as anfitrion,
               z.nombre                                                   as zona_destino,
               to_char(pa.vigente_desde - v_off, 'YYYY-MM-DD HH24:MI')    as desde,
               to_char(pa.vigente_hasta - v_off, 'YYYY-MM-DD HH24:MI')    as hasta,
               round((cast(pa.vigente_hasta as date) - sysdate) * 24, 1)  as horas_restantes,
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

-- r_uso_aulas_vs_sesiones: para una fecha (dia de la hora local), compara
-- por aula/laboratorio las sesiones programadas con el uso real (accesos
-- permitidos y asistentes). p_fecha nula = hoy.
create or replace procedure r_uso_aulas_vs_sesiones (
    p_fecha  in  date,
    o_cursor out sys_refcursor
) is
    v_desf   number;
    v_local  date;    -- el dia pedido, segun la hora local
    v_dia    date;    -- el inicio de ese dia, en hora del servidor
begin
    v_desf  := f_desfase;
    v_local := trunc(nvl(p_fecha, sysdate - v_desf));
    v_dia   := v_local + v_desf;

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
        select to_char(v_local, 'YYYY-MM-DD')         as fecha,
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

-- r_flujo_por_hora: las 24 horas (locales) de una fecha con permitidos,
-- denegados, entradas y salidas segun el sentido del punto. p_fecha nula =
-- hoy; p_id_zona nulo = todas las zonas.
create or replace procedure r_flujo_por_hora (
    p_fecha    in  date,
    p_id_zona  in  number,
    o_cursor   out sys_refcursor
) is
    v_desf   number;
    v_off    interval day to second;
    v_dia    date;    -- inicio del dia local pedido, en hora del servidor
    v_n      number;
begin
    if p_id_zona is not null then
        select count(*) into v_n from zonas where id_zona = p_id_zona;
        if v_n = 0 then
            raise_application_error(-20002, 'La zona ' || p_id_zona || ' no existe');
        end if;
    end if;
    v_desf := f_desfase;
    v_off  := numtodsinterval(v_desf * 1440, 'minute');
    v_dia  := trunc(nvl(p_fecha, sysdate - v_desf)) + v_desf;

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
                select a.id_acceso, a.id_persona, a.resultado,
                       a.fecha_hora - v_off as fecha_local, pc.sentido
                  from accesos a
                  join puntos_control pc on pc.id_punto = a.id_punto
                 where a.fecha_hora >= v_dia
                   and a.fecha_hora <  v_dia + 1
                   and (p_id_zona is null or pc.id_zona = p_id_zona)
               ) x
            on extract(hour from x.fecha_local) = h.n
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

-- Catalogos y consultas para el panel web (los roles no leen tablas, asi
-- que las listas desplegables y las pantallas tambien salen de
-- procedimientos)

-- r_escuelas: catalogo para listas desplegables
create or replace procedure r_escuelas (
    o_cursor out sys_refcursor
) is
begin
    open o_cursor for
        select id_escuela, nombre, facultad
          from escuelas
         order by id_escuela;
exception
    when others then
        raise_application_error(-20099, 'r_escuelas: ' || sqlerrm);
end r_escuelas;
/

-- r_zonas: zonas del campus
create or replace procedure r_zonas (
    o_cursor out sys_refcursor
) is
begin
    open o_cursor for
        select id_zona, nombre, tipo, aforo
          from zonas
         order by id_zona;
exception
    when others then
        raise_application_error(-20099, 'r_zonas: ' || sqlerrm);
end r_zonas;
/

-- r_secciones: secciones con su curso, docente, aula y avance de sesiones
create or replace procedure r_secciones (
    o_cursor out sys_refcursor
) is
begin
    open o_cursor for
        select sec.id_seccion,
               c.codigo                                         as curso,
               c.nombre                                         as nombre_curso,
               sec.grupo,
               sec.periodo,
               d.nombre                                         as docente,
               z.nombre                                         as aula,
               (select count(*) from inscripciones i
                 where i.id_seccion = sec.id_seccion
                   and i.estado <> 'retirado')                  as inscritos,
               (select count(*) from sesiones s
                 where s.id_seccion = sec.id_seccion
                   and s.estado = 'cerrada')                    as sesiones_cerradas,
               (select count(*) from sesiones s
                 where s.id_seccion = sec.id_seccion
                   and s.estado <> 'cerrada')                   as sesiones_abiertas
          from secciones sec
          join cursos   c on c.id_curso   = sec.id_curso
          join personas d on d.id_persona = sec.id_docente
          join zonas    z on z.id_zona    = sec.id_aula
         order by c.codigo, sec.grupo;
exception
    when others then
        raise_application_error(-20099, 'r_secciones: ' || sqlerrm);
end r_secciones;
/

-- r_sesiones: sesiones de una seccion (la mas reciente primero) con el
-- conteo de asistencias; las horas en hora local
create or replace procedure r_sesiones (
    p_id_seccion in  number,
    o_cursor     out sys_refcursor
) is
    v_n   number;
    v_off interval day to second;
begin
    if p_id_seccion is null then
        raise_application_error(-20001, 'La seccion es obligatoria');
    end if;
    select count(*) into v_n from secciones where id_seccion = p_id_seccion;
    if v_n = 0 then
        raise_application_error(-20002, 'La seccion ' || p_id_seccion || ' no existe');
    end if;
    v_off := numtodsinterval(f_desfase * 1440, 'minute');

    open o_cursor for
        select s.id_sesion,
               to_char(s.hora_inicio - v_off, 'YYYY-MM-DD HH24:MI') as inicio,
               to_char(s.hora_fin - v_off, 'YYYY-MM-DD HH24:MI')    as fin,
               s.estado,
               count(case when a.estado = 'presente' then 1 end)    as presentes,
               count(case when a.estado = 'tardanza' then 1 end)    as tardanzas,
               count(case when a.estado = 'falta'    then 1 end)    as faltas
          from sesiones s
          left join asistencias a on a.id_sesion = s.id_sesion
         where s.id_seccion = p_id_seccion
         group by s.id_sesion, s.hora_inicio, s.hora_fin, s.estado
         order by s.hora_inicio desc;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_sesiones: ' || sqlerrm);
end r_sesiones;
/

-- r_restricciones: restricciones vigentes (no levantadas ni vencidas)
create or replace procedure r_restricciones (
    o_cursor out sys_refcursor
) is
    v_desf number;
begin
    v_desf := f_desfase;
    open o_cursor for
        select r.id_restriccion,
               p.codigo,
               p.nombre,
               r.motivo,
               to_char(r.fecha_inicio - v_desf, 'YYYY-MM-DD HH24:MI')      as desde,
               nvl(to_char(r.fecha_fin - v_desf, 'YYYY-MM-DD HH24:MI'),
                   'indefinida')                                           as hasta
          from restricciones r
          join personas p on p.id_persona = r.id_persona
         where r.estado = 'vigente'
           and (r.fecha_fin is null or r.fecha_fin > sysdate)
         order by r.fecha_inicio desc, r.id_restriccion desc;
exception
    when others then
        raise_application_error(-20099, 'r_restricciones: ' || sqlerrm);
end r_restricciones;
/

-- r_resumen_hoy: una fila con los contadores del dia (hora local) y del
-- estado actual; alimenta el dashboard
create or replace procedure r_resumen_hoy (
    o_cursor out sys_refcursor
) is
    v_desf  number;
    v_dia   date;                       -- inicio del dia local, en hora del servidor
    v_ahora timestamp := systimestamp;
begin
    v_desf := f_desfase;
    v_dia  := trunc(sysdate - v_desf) + v_desf;

    open o_cursor for
        select to_char(sysdate - v_desf, 'YYYY-MM-DD HH24:MI') as fecha_hora_local,
               (select count(*) from accesos
                 where fecha_hora >= v_dia and fecha_hora < v_dia + 1)  as accesos_hoy,
               (select count(*) from accesos
                 where resultado = 'permitido'
                   and fecha_hora >= v_dia and fecha_hora < v_dia + 1)  as permitidos_hoy,
               (select count(*) from accesos
                 where resultado = 'denegado'
                   and fecha_hora >= v_dia and fecha_hora < v_dia + 1)  as denegados_hoy,
               (select count(distinct id_persona) from accesos
                 where resultado = 'permitido'
                   and fecha_hora >= v_dia and fecha_hora < v_dia + 1)  as personas_hoy,
               (select count(*) from incidencias
                 where estado = 'abierta')                              as incidencias_abiertas,
               (select count(*) from incidencias
                 where estado = 'abierta' and gravedad = 'alta')        as incidencias_altas,
               (select count(*) from sesiones
                 where estado = 'en_curso')                             as sesiones_en_curso,
               (select count(*) from pases
                 where estado = 'activo'
                   and v_ahora >= vigente_desde
                   and v_ahora <= vigente_hasta)                        as pases_vigentes,
               (select count(*) from restricciones
                 where estado = 'vigente'
                   and (fecha_fin is null or fecha_fin > sysdate))      as restricciones_vigentes
          from dual;
exception
    when others then
        raise_application_error(-20099, 'r_resumen_hoy: ' || sqlerrm);
end r_resumen_hoy;
/

-- r_accesos_bitacora: bitacora de accesos con filtros opcionales (fechas =
-- dias de la hora local, resultado, zona y texto sobre el codigo o el nombre).
-- Devuelve como maximo p_max filas (por defecto 200, tope 1000), las mas
-- recientes primero.
create or replace procedure r_accesos_bitacora (
    p_desde      in  date,
    p_hasta      in  date,
    p_resultado  in  varchar2,
    p_id_zona    in  number,
    p_texto      in  varchar2,
    p_max        in  number,
    o_cursor     out sys_refcursor
) is
    v_desf   number;
    v_off    interval day to second;
    v_ini    timestamp;
    v_fin    timestamp;
    v_max    number;
    v_texto  varchar2(120);
    v_n      number;
begin
    if p_desde is not null and p_hasta is not null and p_desde > p_hasta then
        raise_application_error(-20001, 'La fecha desde no puede ser posterior a la fecha hasta');
    end if;
    if p_resultado is not null and p_resultado not in ('permitido', 'denegado') then
        raise_application_error(-20001, 'Resultado no valido: ' || p_resultado);
    end if;
    if p_id_zona is not null then
        select count(*) into v_n from zonas where id_zona = p_id_zona;
        if v_n = 0 then
            raise_application_error(-20002, 'La zona ' || p_id_zona || ' no existe');
        end if;
    end if;

    v_desf  := f_desfase;
    v_off   := numtodsinterval(v_desf * 1440, 'minute');
    v_ini   := case when p_desde is null then null
                    else cast(trunc(p_desde) + v_desf as timestamp) end;
    v_fin   := case when p_hasta is null then null
                    else cast(trunc(p_hasta) + 1 + v_desf as timestamp) end;
    v_max   := least(greatest(nvl(p_max, 200), 1), 1000);
    v_texto := case when trim(p_texto) is null then null
                    else '%' || lower(trim(p_texto)) || '%' end;

    open o_cursor for
        select *
          from (
                select a.id_acceso,
                       to_char(a.fecha_hora - v_off, 'YYYY-MM-DD HH24:MI:SS') as fecha_hora,
                       a.codigo_leido                                         as codigo,
                       nvl(p.nombre, '(codigo no registrado)')                as persona,
                       p.tipo                                                 as tipo_persona,
                       z.nombre                                               as zona,
                       pc.nombre                                              as punto,
                       a.resultado,
                       a.motivo,
                       a.metodo,
                       a.confianza
                  from accesos a
                  join puntos_control pc on pc.id_punto = a.id_punto
                  join zonas z           on z.id_zona   = pc.id_zona
                  left join personas p   on p.id_persona = a.id_persona
                 where (v_ini is null or a.fecha_hora >= v_ini)
                   and (v_fin is null or a.fecha_hora <  v_fin)
                   and (p_resultado is null or a.resultado = p_resultado)
                   and (p_id_zona is null or pc.id_zona = p_id_zona)
                   and (v_texto is null
                        or lower(a.codigo_leido) like v_texto
                        or lower(p.nombre) like v_texto)
                 order by a.fecha_hora desc, a.id_acceso desc
               )
         where rownum <= v_max;
exception
    when others then
        if sqlcode between -20999 and -20000 then
            raise;
        end if;
        raise_application_error(-20099, 'r_accesos_bitacora: ' || sqlerrm);
end r_accesos_bitacora;
/

-- Verificacion de compilacion (no debe listar errores)
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
prompt === Reportes y catalogos ===
column object_name format a28
select object_name, object_type, status
  from user_objects
 where object_name like 'R\_%' escape '\'
 order by object_name;

commit;
