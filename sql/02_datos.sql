set sqlblanklines on
set define off
set serveroutput on size unlimited
set linesize 200
set pagesize 100
set feedback off
whenever sqlerror exit failure rollback

-- 02_datos.sql
-- Datos de prueba (ficticios). Ejecutar como ACCESO_OWNER despues de 01.
--   docker cp sql/02_datos.sql oracle-xe:/tmp/02_datos.sql
--   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/02_datos.sql
--
-- Todas las fechas son relativas a sysdate, por lo que se puede volver a
-- cargar el mismo dia con 99_reset.sql + 01 + 02. Las horas del dia (clases,
-- ingresos, denegados) estan pensadas en hora LOCAL (parametro ZONA_HORARIA)
-- y se guardan en hora del servidor sumando f_desfase.

-- Parametros del sistema
insert into parametros (nombre, valor, descripcion) values
    ('LIMITE_FALTAS_PCT', '30',
     'Porcentaje de faltas (sobre sesiones cerradas) desde el cual se inhabilita al estudiante');
insert into parametros (nombre, valor, descripcion) values
    ('MIN_TARDANZA', '15',
     'Minutos desde el inicio de la sesion hasta los que aun cuenta como presente');
insert into parametros (nombre, valor, descripcion) values
    ('MIN_MAX_TARDANZA', '30',
     'Minutos desde el inicio hasta los que aun se registra asistencia (como tardanza)');
insert into parametros (nombre, valor, descripcion) values
    ('INTENTOS_PARA_INCIDENCIA', '3',
     'Accesos denegados para generar una incidencia de intentos reiterados');
insert into parametros (nombre, valor, descripcion) values
    ('MIN_VENTANA_INTENTOS', '10',
     'Ventana en minutos para contar los intentos denegados');
insert into parametros (nombre, valor, descripcion) values
    ('UMBRAL_LBPH', '40',
     'Confianza LBPH maxima aceptada por el punto de acceso (menor valor = mayor parecido)');
insert into parametros (nombre, valor, descripcion) values
    ('ZONA_HORARIA', 'America/Lima',
     'Zona horaria con la que se evalua la ventana HH24:MI de permisos_zona');

-- ---------------------------------------------------------------------
-- Escuelas, zonas, puntos de control y permisos por zona
-- ---------------------------------------------------------------------
insert into escuelas (id_escuela, nombre, facultad) values
    (1, 'Ingenieria de Sistemas', 'Facultad de Ingenieria de Sistemas e Informatica');
insert into escuelas (id_escuela, nombre, facultad) values
    (2, 'Ingenieria de Software', 'Facultad de Ingenieria de Sistemas e Informatica');
insert into escuelas (id_escuela, nombre, facultad) values
    (3, 'Ciencias de la Computacion', 'Facultad de Ciencias Matematicas');

insert into zonas (id_zona, nombre, tipo, aforo) values (1, 'Puerta Principal', 'puerta', null);
insert into zonas (id_zona, nombre, tipo, aforo) values (2, 'Biblioteca Central', 'biblioteca', 120);
insert into zonas (id_zona, nombre, tipo, aforo) values (3, 'Aula A-101', 'aula', 40);
insert into zonas (id_zona, nombre, tipo, aforo) values (4, 'Aula A-102', 'aula', 40);
insert into zonas (id_zona, nombre, tipo, aforo) values (5, 'Laboratorio de Computo 1', 'laboratorio', 30);
insert into zonas (id_zona, nombre, tipo, aforo) values (6, 'Oficina de Administracion', 'administrativa', 15);

insert into puntos_control (id_punto, id_zona, nombre, sentido) values (1, 1, 'Puerta ingreso', 'entrada');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (2, 1, 'Puerta salida', 'salida');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (3, 2, 'Biblioteca', 'mixto');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (4, 3, 'Aula A-101', 'mixto');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (5, 4, 'Aula A-102', 'mixto');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (6, 5, 'Laboratorio', 'mixto');
insert into puntos_control (id_punto, id_zona, nombre, sentido) values (7, 6, 'Administracion', 'mixto');

-- estudiante: puerta y aulas 07:00-22:00; biblioteca y laboratorio 08:00-20:00
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('estudiante', 1, '07:00', '22:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('estudiante', 3, '07:00', '22:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('estudiante', 4, '07:00', '22:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('estudiante', 2, '08:00', '20:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('estudiante', 5, '08:00', '20:00');
-- docente: todas las zonas 06:30-23:00
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 1, '06:30', '23:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 2, '06:30', '23:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 3, '06:30', '23:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 4, '06:30', '23:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 5, '06:30', '23:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('docente', 6, '06:30', '23:00');
-- vigilante: todas las zonas todo el dia
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 1, '00:00', '23:59');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 2, '00:00', '23:59');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 3, '00:00', '23:59');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 4, '00:00', '23:59');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 5, '00:00', '23:59');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('vigilante', 6, '00:00', '23:59');
-- administrativo: puerta y oficina administrativa 07:00-20:00
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('administrativo', 1, '07:00', '20:00');
insert into permisos_zona (tipo_persona, id_zona, hora_desde, hora_hasta) values ('administrativo', 6, '07:00', '20:00');
-- los visitantes no tienen filas: su acceso depende de un pase

-- ---------------------------------------------------------------------
-- Personas (17): docentes 1-3, vigilante 4, administrativo 5,
-- estudiantes 10-19, visitantes 30-31
-- ---------------------------------------------------------------------
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (1, '10000001', 'Carlos Mendoza Rios', '40100001', 'carlos.mendoza@campus.test', 'docente', 'activo', systimestamp - interval '120' day(3));
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (2, '10000002', 'Lucia Fernandez Soto', '40100002', 'lucia.fernandez@campus.test', 'docente', 'activo', systimestamp - interval '120' day(3));
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (3, '10000003', 'Jorge Paredes Vega', '40100003', 'jorge.paredes@campus.test', 'docente', 'activo', systimestamp - interval '120' day(3));
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (4, '90000001', 'Ricardo Salas Medina', '41000001', 'ricardo.salas@campus.test', 'vigilante', 'activo', systimestamp - interval '120' day(3));
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (5, '80000001', 'Patricia Campos Luna', '42000001', 'patricia.campos@campus.test', 'administrativo', 'activo', systimestamp - interval '120' day(3));

insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (10, '25200001', 'Ana Torres Quispe', '75000010', 'ana.torres@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (11, '25200002', 'Luis Ramirez Huaman', '75000011', 'luis.ramirez@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (12, '25200003', 'Maria Gomez Flores', '75000012', 'maria.gomez@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (13, '25200004', 'Diego Castillo Rojas', '75000013', 'diego.castillo@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (14, '25200005', 'Sofia Herrera Diaz', '75000014', 'sofia.herrera@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (15, '25200006', 'Pedro Vargas Leon', '75000015', 'pedro.vargas@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (16, '25200007', 'Valeria Ortiz Mejia', '75000016', 'valeria.ortiz@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (17, '25200008', 'Andres Silva Cruz', '75000017', 'andres.silva@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (18, '25200009', 'Camila Rojas Prado', '75000018', 'camila.rojas@campus.test', 'estudiante', 'inactivo', systimestamp - interval '60' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (19, '25200010', 'Miguel Navarro Pinto', '75000019', 'miguel.navarro@campus.test', 'estudiante', 'activo', systimestamp - interval '60' day);

insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (30, '99000001', 'Elena Paz Cardenas', '76000030', 'elena.paz@externo.test', 'visitante', 'activo', systimestamp - interval '1' day);
insert into personas (id_persona, codigo, nombre, dni, correo, tipo, estado, fecha_registro) values
    (31, '99000002', 'Hugo Villanueva Rey', '76000031', 'hugo.villanueva@externo.test', 'visitante', 'activo', systimestamp - interval '10' day);

insert into docentes (id_docente, especialidad) values (1, 'Bases de Datos');
insert into docentes (id_docente, especialidad) values (2, 'Ingenieria de Software');
insert into docentes (id_docente, especialidad) values (3, 'Algoritmos y Estructuras de Datos');

insert into estudiantes (id_estudiante, id_escuela, ciclo) values (10, 1, 6);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (11, 1, 6);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (12, 1, 6);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (13, 2, 7);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (14, 1, 7);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (15, 1, 5);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (16, 3, 4);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (17, 2, 5);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (18, 1, 8);
insert into estudiantes (id_estudiante, id_escuela, ciclo) values (19, 3, 3);

-- ---------------------------------------------------------------------
-- Cursos, secciones (periodo 2026-II) e inscripciones
-- ---------------------------------------------------------------------
insert into cursos (id_curso, codigo, nombre, id_escuela, creditos) values
    (1, 'SIS301', 'Administracion de Base de Datos', 1, 4);
insert into cursos (id_curso, codigo, nombre, id_escuela, creditos) values
    (2, 'SIS302', 'Ingenieria de Software', 1, 4);
insert into cursos (id_curso, codigo, nombre, id_escuela, creditos) values
    (3, 'SIS201', 'Estructuras de Datos', 1, 4);
insert into cursos (id_curso, codigo, nombre, id_escuela, creditos) values
    (4, 'CC101', 'Programacion I', 3, 3);

insert into secciones (id_seccion, id_curso, id_docente, id_aula, periodo, grupo, cupo) values (1, 1, 1, 3, '2026-II', 'A', 40);
insert into secciones (id_seccion, id_curso, id_docente, id_aula, periodo, grupo, cupo) values (2, 2, 2, 4, '2026-II', 'A', 40);
insert into secciones (id_seccion, id_curso, id_docente, id_aula, periodo, grupo, cupo) values (3, 3, 3, 5, '2026-II', 'A', 30);
insert into secciones (id_seccion, id_curso, id_docente, id_aula, periodo, grupo, cupo) values (4, 4, 1, 3, '2026-II', 'B', 40);

-- S1: estudiantes 10-15
insert into inscripciones (id_seccion, id_estudiante) values (1, 10);
insert into inscripciones (id_seccion, id_estudiante) values (1, 11);
insert into inscripciones (id_seccion, id_estudiante) values (1, 12);
insert into inscripciones (id_seccion, id_estudiante) values (1, 13);
insert into inscripciones (id_seccion, id_estudiante) values (1, 14);
insert into inscripciones (id_seccion, id_estudiante) values (1, 15);
-- S2: 10, 11, 16, 17
insert into inscripciones (id_seccion, id_estudiante) values (2, 10);
insert into inscripciones (id_seccion, id_estudiante) values (2, 11);
insert into inscripciones (id_seccion, id_estudiante) values (2, 16);
insert into inscripciones (id_seccion, id_estudiante) values (2, 17);
-- S3: 12, 13, 14, 18, 19
insert into inscripciones (id_seccion, id_estudiante) values (3, 12);
insert into inscripciones (id_seccion, id_estudiante) values (3, 13);
insert into inscripciones (id_seccion, id_estudiante) values (3, 14);
insert into inscripciones (id_seccion, id_estudiante) values (3, 18);
insert into inscripciones (id_seccion, id_estudiante) values (3, 19);
-- S4: 15, 16, 17, 19
insert into inscripciones (id_seccion, id_estudiante) values (4, 15);
insert into inscripciones (id_seccion, id_estudiante) values (4, 16);
insert into inscripciones (id_seccion, id_estudiante) values (4, 17);
insert into inscripciones (id_seccion, id_estudiante) values (4, 19);

-- ---------------------------------------------------------------------
-- Pases, restricciones
-- Los dias son de la hora local (ZONA_HORARIA) y se guardan en hora del
-- servidor: f_desfase da la diferencia en dias (servidor - local).
-- ---------------------------------------------------------------------
declare
    v_desf number := f_desfase;
    v_hoy  date   := trunc(sysdate - f_desfase);   -- hoy segun la hora local
begin
    -- pase vigente: visitante 30, anfitrion docente 1, solo biblioteca (zona 2)
    insert into pases (id_visitante, id_anfitrion, id_zona_destino, vigente_desde, vigente_hasta, motivo, estado) values
        (30, 1, 2, cast(v_hoy - 1 + v_desf as timestamp), cast(v_hoy + 30 + v_desf as timestamp),
         'Consulta bibliografica para investigacion', 'activo');
    -- pase vencido: visitante 31, anfitrion administrativo 5, puerta (zona 1)
    insert into pases (id_visitante, id_anfitrion, id_zona_destino, vigente_desde, vigente_hasta, motivo, estado) values
        (31, 5, 1, cast(v_hoy - 10 + v_desf as timestamp), cast(v_hoy - 3 + v_desf as timestamp),
         'Reunion con la oficina de administracion', 'activo');
end;
/

-- restriccion vigente: estudiante 19 (codigo 25200010) desde hace 5 dias
insert into restricciones (id_persona, motivo, fecha_inicio, fecha_fin, estado) values
    (19, 'Sancion disciplinaria pendiente de resolucion', trunc(sysdate - f_desfase) - 5 + f_desfase, null, 'vigente');

-- ---------------------------------------------------------------------
-- Sesiones pasadas (ids 1-24), asistencias simuladas y accesos a aula
--   6 sesiones semanales cerradas por seccion: ids (seccion-1)*6 + 1..6
--   Reparto aleatorio (semilla fija): 78% presente, 12% tardanza, 10% falta
--   Ajustes dirigidos para que pruebas y reportes no dependan del azar:
--     - estudiantes 10 y 11 (usados en test_03): sin faltas
--     - estudiante 13 en seccion 1: 3 faltas (queda inhabilitado)
--     - estudiante 14 en seccion 1: 1 falta (queda en riesgo)
-- ---------------------------------------------------------------------
declare
    v_id_sesion  sesiones.id_sesion%type;
    v_dia        date;
    v_hora       number;
    v_ini        timestamp;
    v_reg        timestamp;
    v_punto      puntos_control.id_punto%type;
    v_acc        accesos.id_acceso%type;
    v_cod_doc    personas.codigo%type;
    v_r          number;
    v_estado     asistencias.estado%type;
    v_desf       number := f_desfase;   -- dias: hora del servidor - hora local
begin
    dbms_random.seed(2026);

    for sec in (select id_seccion, id_docente, id_aula
                  from secciones
                 order by id_seccion) loop

        select id_punto into v_punto
          from puntos_control
         where id_zona = sec.id_aula
           and rownum = 1;

        select codigo into v_cod_doc
          from personas
         where id_persona = sec.id_docente;

        v_hora := case sec.id_seccion when 1 then 8 when 2 then 10 when 3 then 14 else 16 end;

        for k in 1 .. 6 loop
            v_id_sesion := (sec.id_seccion - 1) * 6 + k;
            -- v_hora es la hora de clase LOCAL; se guarda en hora del servidor
            v_dia := trunc(sysdate - v_desf) - 7 * (7 - k) + v_desf;
            v_ini := cast(v_dia + v_hora / 24 as timestamp);

            insert into sesiones (id_sesion, id_seccion, hora_inicio, hora_fin, estado)
            values (v_id_sesion, sec.id_seccion, v_ini, v_ini + interval '90' minute, 'cerrada');

            -- el docente entra al aula unos minutos antes
            insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                                 resultado, metodo, confianza)
            values (sec.id_docente, v_cod_doc, v_punto, v_ini - interval '5' minute,
                    'permitido', 'simulado', round(dbms_random.value(12, 38), 2));

            for ins in (select i.id_estudiante, p.codigo
                          from inscripciones i
                          join personas p on p.id_persona = i.id_estudiante
                         where i.id_seccion = sec.id_seccion
                         order by i.id_estudiante) loop

                v_r := dbms_random.value(0, 100);
                if v_r < 78 then
                    v_estado := 'presente';
                elsif v_r < 90 then
                    v_estado := 'tardanza';
                else
                    v_estado := 'falta';
                end if;

                -- ajustes dirigidos
                if ins.id_estudiante in (10, 11) and v_estado = 'falta' then
                    v_estado := 'presente';
                elsif sec.id_seccion = 1 and ins.id_estudiante = 13 then
                    v_estado := case when k in (2, 4, 5) then 'falta'
                                     when v_estado = 'falta' then 'presente'
                                     else v_estado end;
                elsif sec.id_seccion = 1 and ins.id_estudiante = 14 then
                    v_estado := case when k = 3 then 'falta'
                                     when v_estado = 'falta' then 'presente'
                                     else v_estado end;
                end if;

                if v_estado = 'falta' then
                    insert into asistencias (id_sesion, id_estudiante, estado, hora_registro, id_acceso)
                    values (v_id_sesion, ins.id_estudiante, 'falta', null, null);
                else
                    if v_estado = 'presente' then
                        v_reg := v_ini + numtodsinterval(trunc(dbms_random.value(-8, 15)), 'minute');
                    else
                        v_reg := v_ini + numtodsinterval(trunc(dbms_random.value(16, 30)), 'minute');
                    end if;

                    insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                                         resultado, metodo, confianza)
                    values (ins.id_estudiante, ins.codigo, v_punto, v_reg,
                            'permitido', 'simulado', round(dbms_random.value(12, 38), 2))
                    returning id_acceso into v_acc;

                    insert into asistencias (id_sesion, id_estudiante, estado, hora_registro, id_acceso)
                    values (v_id_sesion, ins.id_estudiante, v_estado, v_reg, v_acc);
                end if;
            end loop;
        end loop;
    end loop;

    -- contador de faltas por inscripcion
    update inscripciones i
       set faltas = (select count(*)
                       from asistencias a
                       join sesiones s on s.id_sesion = a.id_sesion
                      where s.id_seccion = i.id_seccion
                        and a.id_estudiante = i.id_estudiante
                        and a.estado = 'falta');

    -- inhabilitacion: faltas * 100 / sesiones cerradas >= LIMITE_FALTAS_PCT
    update inscripciones i
       set estado = 'inhabilitado'
     where i.faltas * 100 /
           (select count(*) from sesiones s
             where s.id_seccion = i.id_seccion and s.estado = 'cerrada')
           >= (select to_number(valor) from parametros where nombre = 'LIMITE_FALTAS_PCT');
end;
/

-- Sesion 900 (seccion 1, aula A-101): en curso, empezo hace 5 minutos y dura 90.
-- Para volver a moverla a "ahora" antes de probar un acceso, ejecutar:
--   update sesiones
--      set hora_inicio = systimestamp - interval '5' minute,
--          hora_fin    = systimestamp + interval '85' minute,
--          estado      = 'en_curso'
--    where id_sesion = 900;
--   commit;
insert into sesiones (id_sesion, id_seccion, hora_inicio, hora_fin, estado) values
    (900, 1, systimestamp - interval '5' minute, systimestamp + interval '85' minute, 'en_curso');

-- ---------------------------------------------------------------------
-- Accesos simulados de 14 dias (puerta, biblioteca, laboratorio, salidas),
-- 8 accesos denegados de ejemplo y las incidencias asociadas
-- ---------------------------------------------------------------------
declare
    v_dia   date;
    v_in    timestamp;
    v_out   timestamp;
    v_mid   timestamp;
    v_t     timestamp;
    v_a     accesos.id_acceso%type;
    v_a3    accesos.id_acceso%type;
    v_a4    accesos.id_acceso%type;
    v_a5    accesos.id_acceso%type;
    v_a7    accesos.id_acceso%type;
    v_a8    accesos.id_acceso%type;
    v_desf  number := f_desfase;   -- dias: hora del servidor - hora local

    -- instante: hace p_dias dias a las p_h:p_m de la hora LOCAL, en hora del servidor
    function ts (p_dias in number, p_h in number, p_m in number) return timestamp is
    begin
        return cast(trunc(sysdate - v_desf) - p_dias + v_desf + (p_h * 60 + p_m) / 1440 as timestamp);
    end ts;

    procedure acceso (
        p_id_persona in number,
        p_codigo     in varchar2,
        p_punto      in number,
        p_hora       in timestamp,
        p_resultado  in varchar2,
        p_motivo     in varchar2,
        p_metodo     in varchar2,
        p_confianza  in number,
        p_id         out number
    ) is
    begin
        insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                             resultado, motivo, metodo, confianza)
        values (p_id_persona, p_codigo, p_punto, p_hora,
                p_resultado, p_motivo, p_metodo, p_confianza)
        returning id_acceso into p_id;
    end acceso;
begin
    dbms_random.seed(4242);

    -- ingresos y salidas por la puerta; visitas a biblioteca y laboratorio
    for d in 1 .. 14 loop
        v_dia := trunc(sysdate - v_desf) - d + v_desf;   -- inicio del dia local, en hora del servidor
        for p in (select id_persona, codigo, tipo
                    from personas
                   where tipo in ('estudiante', 'docente', 'vigilante', 'administrativo')
                     and id_persona <> 18
                   order by id_persona) loop

            -- el estudiante 19 tiene restriccion vigente desde hace 5 dias
            if not (p.id_persona = 19 and d <= 5)
               and dbms_random.value(0, 100) < 85 then

                v_in  := cast(v_dia + (420 + trunc(dbms_random.value(0, 150))) / 1440 as timestamp);
                v_out := cast(v_dia + (960 + trunc(dbms_random.value(0, 240))) / 1440 as timestamp);

                acceso(p.id_persona, p.codigo, 1, v_in, 'permitido', null, 'simulado',
                       round(dbms_random.value(12, 38), 2), v_a);

                -- visita a la biblioteca (30% de los estudiantes)
                if p.tipo = 'estudiante' and dbms_random.value(0, 100) < 30 then
                    v_mid := cast(v_dia + (600 + trunc(dbms_random.value(0, 300))) / 1440 as timestamp);
                    acceso(p.id_persona, p.codigo, 3, v_mid, 'permitido', null, 'simulado',
                           round(dbms_random.value(12, 38), 2), v_a);
                end if;

                -- practica en el laboratorio (estudiantes de la seccion 3)
                if p.id_persona in (12, 13, 14, 19) and dbms_random.value(0, 100) < 25 then
                    v_mid := cast(v_dia + (900 + trunc(dbms_random.value(0, 180))) / 1440 as timestamp);
                    acceso(p.id_persona, p.codigo, 6, v_mid, 'permitido', null, 'simulado',
                           round(dbms_random.value(12, 38), 2), v_a);
                end if;

                acceso(p.id_persona, p.codigo, 2, v_out, 'permitido', null, 'simulado',
                       round(dbms_random.value(12, 38), 2), v_a);
            end if;
        end loop;
    end loop;

    -- visitas: visitante 30 (pase vigente, ayer) y visitante 31 (hace 8 dias)
    acceso(30, '99000001', 1, ts(1, 9, 30),  'permitido', null, 'qr_rostro', 21.40, v_a);
    acceso(30, '99000001', 3, ts(1, 9, 45),  'permitido', null, 'qr_rostro', 22.10, v_a);
    acceso(30, '99000001', 2, ts(1, 12, 30), 'permitido', null, 'qr_rostro', 19.80, v_a);
    acceso(31, '99000002', 1, ts(8, 8, 50),  'permitido', null, 'qr_rostro', 25.30, v_a);
    acceso(31, '99000002', 2, ts(8, 11, 0),  'permitido', null, 'qr_rostro', 24.70, v_a);

    -- 8 accesos denegados de ejemplo
    -- (1-3) codigo inexistente, tres lecturas seguidas
    acceso(null, '00000000', 1, ts(3, 2, 10), 'denegado', 'codigo_inexistente', 'qr_rostro', null, v_a);
    acceso(null, '00000000', 1, ts(3, 2, 11), 'denegado', 'codigo_inexistente', 'qr_rostro', null, v_a);
    acceso(null, '00000000', 1, ts(3, 2, 12), 'denegado', 'codigo_inexistente', 'qr_rostro', null, v_a3);
    -- (4) rostro que no coincide
    acceso(12, '25200003', 1, ts(4, 8, 5),  'denegado', 'rostro_no_coincide', 'qr_rostro', 68.50, v_a);
    -- (5) biblioteca fuera de horario (cierra a las 20:00)
    acceso(15, '25200006', 3, ts(2, 21, 15), 'denegado', 'fuera_de_horario', 'qr_rostro', 22.90, v_a5);
    -- (6) persona inactiva
    acceso(18, '25200009', 1, ts(6, 9, 40), 'denegado', 'persona_inactiva', 'qr_rostro', 20.10, v_a);
    -- (7) persona restringida
    acceso(19, '25200010', 1, ts(1, 8, 20), 'denegado', 'persona_restringida', 'qr_rostro', 23.60, v_a7);
    -- (8) visitante con pase vencido
    acceso(31, '99000002', 1, ts(2, 10, 5), 'denegado', 'sin_pase_vigente', 'qr_rostro', 26.20, v_a8);

    -- 5 incidencias de ejemplo (la hora se calcula antes: una funcion local
    -- de PL/SQL no puede usarse dentro de una sentencia SQL)
    v_t := ts(3, 2, 12);
    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad, descripcion,
                             fecha_hora, estado, origen)
    values (1, null, v_a3, 'intentos_reiterados', 'media',
            'Intentos denegados reiterados (3 en 10 min). codigo=[00000000]',
            v_t, 'resuelta', 'sistema');

    v_t := ts(1, 8, 20);
    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad, descripcion,
                             fecha_hora, estado, origen)
    values (1, 19, v_a7, 'persona_restringida', 'alta',
            'Intento de ingreso de persona con restriccion vigente: 25200010',
            v_t, 'abierta', 'sistema');

    v_t := ts(3, 16, 40);
    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad, descripcion,
                             fecha_hora, estado, origen)
    values (5, null, null, 'equipo_danado', 'baja',
            'Monitor del puesto 12 del laboratorio con la pantalla rota',
            v_t, 'en_revision', 'vigilante');

    v_t := ts(2, 21, 20);
    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad, descripcion,
                             fecha_hora, estado, origen)
    values (2, 15, v_a5, 'ingreso_fuera_de_horario', 'baja',
            'Estudiante intento ingresar a la biblioteca despues de las 20:00',
            v_t, 'resuelta', 'vigilante');

    v_t := ts(2, 10, 6);
    insert into incidencias (id_zona, id_persona, id_acceso, tipo, gravedad, descripcion,
                             fecha_hora, estado, origen)
    values (1, 31, v_a8, 'visitante_sin_pase_vigente', 'media',
            'Visitante con pase vencido solicito ingreso por la puerta principal',
            v_t, 'abierta', 'vigilante');
end;
/

-- ---------------------------------------------------------------------
-- Accesos de HOY (hora local): solo los que ya ocurrieron al cargar los
-- datos, para que el dashboard del panel no salga vacio. Usa una semilla
-- propia y asi no cambia los accesos de los dias anteriores. Los
-- estudiantes 18 (inactivo) y 19 (restringido) no ingresan.
-- ---------------------------------------------------------------------
declare
    v_desf   number := f_desfase;
    v_dia    date   := trunc(sysdate - f_desfase) + f_desfase;  -- hoy 00:00 local, en hora del servidor
    v_limite timestamp := cast(sysdate - 5 / 1440 as timestamp); -- no se inventan accesos futuros
    v_in     timestamp;
    v_out    timestamp;
begin
    dbms_random.seed(777);
    for p in (select id_persona, codigo
                from personas
               where tipo in ('estudiante', 'docente', 'vigilante', 'administrativo')
                 and id_persona not in (18, 19)
               order by id_persona) loop
        if dbms_random.value(0, 100) < 85 then
            v_in  := cast(v_dia + (420 + trunc(dbms_random.value(0, 150))) / 1440 as timestamp);
            v_out := cast(v_dia + (960 + trunc(dbms_random.value(0, 240))) / 1440 as timestamp);
            if v_in <= v_limite then
                insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                                     resultado, metodo, confianza)
                values (p.id_persona, p.codigo, 1, v_in, 'permitido', 'simulado',
                        round(dbms_random.value(12, 38), 2));
            end if;
            if v_out <= v_limite then
                insert into accesos (id_persona, codigo_leido, id_punto, fecha_hora,
                                     resultado, metodo, confianza)
                values (p.id_persona, p.codigo, 2, v_out, 'permitido', 'simulado',
                        round(dbms_random.value(12, 38), 2));
            end if;
        end if;
    end loop;
end;
/

-- ---------------------------------------------------------------------
-- Verificacion
-- ---------------------------------------------------------------------
set feedback on
prompt
prompt === Filas por tabla ===
select 'escuelas' as tabla, count(*) as filas from escuelas
union all select 'personas',       count(*) from personas
union all select 'estudiantes',    count(*) from estudiantes
union all select 'docentes',       count(*) from docentes
union all select 'zonas',          count(*) from zonas
union all select 'puntos_control', count(*) from puntos_control
union all select 'accesos',        count(*) from accesos
union all select 'cursos',         count(*) from cursos
union all select 'secciones',      count(*) from secciones
union all select 'inscripciones',  count(*) from inscripciones
union all select 'sesiones',       count(*) from sesiones
union all select 'asistencias',    count(*) from asistencias
union all select 'permisos_zona',  count(*) from permisos_zona
union all select 'restricciones',  count(*) from restricciones
union all select 'pases',          count(*) from pases
union all select 'incidencias',    count(*) from incidencias
union all select 'parametros',     count(*) from parametros
union all select 'auditoria',      count(*) from auditoria;

prompt
prompt === Personas por tipo ===
select tipo, count(*) as total from personas group by tipo order by tipo;

prompt
prompt === Inscripciones: faltas y estado tras la simulacion ===
column estudiante format a24
select i.id_seccion, p.codigo, p.nombre as estudiante, i.faltas, i.estado
  from inscripciones i
  join personas p on p.id_persona = i.id_estudiante
 order by i.id_seccion, p.codigo;

commit;
