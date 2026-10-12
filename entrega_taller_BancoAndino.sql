-- =====================================================================
-- Bases de Datos 2 · Taller integrador — Banco Andino
-- ENTREGA — Script SQL
-- Integrante 1: ____________________
-- Integrante 2: ____________________
-- =====================================================================
-- Este archivo contiene:
--   1. Las consultas ESCRIBA de la Parte 3
--   2. La secuencia corregida del reto (Parte 4, punto B)
--   3. La consulta optimizada del tablero (Parte 4, punto C)
-- Ejecútenlo bloque por bloque en su propia conexión y peguen los
-- resultados / planes de ejecución en el documento de respuestas.
-- =====================================================================


-- #####################################################################
-- PARTE 2 · ÍNDICES CREADOS (lista definitiva, Ejercicio 2.11)
-- #####################################################################

CREATE INDEX ix_transf_fecha_estado ON transferencia (fecha_transf, estado);
CREATE INDEX ix_transf_fecha_origen ON transferencia (fecha_transf, cuenta_origen);
CREATE INDEX ix_transf_cuenta_origen  ON transferencia (cuenta_origen);
CREATE INDEX ix_transf_cuenta_destino ON transferencia (cuenta_destino);
CREATE INDEX ix_notif_transferencia   ON notificacion  (id_transferencia);
-- ix_mov_transferencia ya existía desde 00_setup.sql

EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'TRANSFERENCIA', cascade => TRUE);
EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, 'NOTIFICACION',  cascade => TRUE);

-- Índices de exploración usados durante el taller y luego descartados
-- (no forman parte de la lista definitiva; se dejan documentados):
--   ix_transf_estado_fecha (2.1)  -> DROP, ver Pregunta 2.3/2.4
--   ix_cliente_nombre (2.2)       -> se reemplazó por índice funcional
--   ix_cliente_nombre_upper ON cliente (UPPER(nombre))
--   ix_transf_estado (2.3)        -> no aportó frente a fecha_estado


-- #####################################################################
-- PARTE 3 · SQL AVANZADO
-- #####################################################################

-- ---------------------------------------------------------------------
-- ESCRIBA 3.1 — Top 3 por familia + porcentaje sobre el total de la familia
-- ---------------------------------------------------------------------
WITH captacion AS (
  SELECT f.id_producto  AS id_familia,
         f.nombre       AS familia,
         p.id_producto,
         p.nombre       AS producto,
         SUM(c.saldo)   AS saldo_captado,
         COUNT(*)       AS cuentas
    FROM cuenta c
    JOIN catalogo_producto p ON p.id_producto = c.id_producto
    JOIN catalogo_producto f ON f.id_producto = p.id_padre
   WHERE c.estado = 'ACTIVA'
   GROUP BY f.id_producto, f.nombre, p.id_producto, p.nombre
),
rankeado AS (
  SELECT v.*,
         DENSE_RANK() OVER (PARTITION BY id_familia
                            ORDER BY saldo_captado DESC)            AS puesto,
         ROUND(100 * RATIO_TO_REPORT(saldo_captado)
                     OVER (PARTITION BY id_familia), 1)             AS pct_familia
    FROM captacion v
)
SELECT familia, producto, cuentas,
       ROUND(saldo_captado) AS saldo_captado,
       pct_familia,
       puesto
  FROM rankeado
 WHERE puesto <= 3
 ORDER BY familia, puesto;


-- ---------------------------------------------------------------------
-- ESCRIBA 3.2 — Evolución mensual + promedio móvil de 3 meses
-- ---------------------------------------------------------------------
WITH mensual AS (
  SELECT TRUNC(fecha_transf, 'MM') AS mes,
         SUM(valor)                AS valor_transferido,
         COUNT(*)                  AS operaciones
    FROM transferencia
   WHERE fecha_transf >= DATE '2026-01-01'
     AND fecha_transf <  DATE '2027-01-01'
     AND estado = 'APLICADA'
   GROUP BY TRUNC(fecha_transf, 'MM')
)
SELECT TO_CHAR(mes,'YYYY-MM')                          AS mes,
       operaciones,
       ROUND(valor_transferido)                        AS valor,
       ROUND(SUM(valor_transferido) OVER (ORDER BY mes
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW))      AS acumulado,
       ROUND(LAG(valor_transferido) OVER (ORDER BY mes))             AS mes_anterior,
       ROUND(100 * (valor_transferido - LAG(valor_transferido) OVER (ORDER BY mes))
                 / NULLIF(LAG(valor_transferido) OVER (ORDER BY mes),0), 1) AS var_pct,
       ROUND(AVG(valor_transferido) OVER (ORDER BY mes
             ROWS BETWEEN 2 PRECEDING AND CURRENT ROW))               AS prom_movil_3m
  FROM mensual
 ORDER BY mes;


-- ---------------------------------------------------------------------
-- ESCRIBA 3.3 — Saldo captado por línea de negocio (CTE recursiva)
-- ---------------------------------------------------------------------
WITH arbol (id_producto, nombre, id_padre, id_linea) AS (
  -- ancla: las líneas de negocio son su propia línea
  SELECT id_producto, nombre, id_padre, id_producto
    FROM catalogo_producto
   WHERE id_padre IS NULL
  UNION ALL
  -- recursión: cada hijo hereda la línea de su padre
  SELECT c.id_producto, c.nombre, c.id_padre, a.id_linea
    FROM catalogo_producto c
    JOIN arbol a ON c.id_padre = a.id_producto
)
SELECT l.nombre                    AS linea_negocio,
       COUNT(*)                    AS cuentas_activas,
       ROUND(SUM(cu.saldo))        AS saldo_total
  FROM cuenta cu
  JOIN arbol a  ON a.id_producto = cu.id_producto   -- hoja de producto
  JOIN catalogo_producto l ON l.id_producto = a.id_linea
 WHERE cu.estado = 'ACTIVA'
 GROUP BY l.nombre
 ORDER BY saldo_total DESC;


-- ---------------------------------------------------------------------
-- ESCRIBA 3.4 — MERGE que NO toca las cuentas donde el ajuste no cabe
-- ---------------------------------------------------------------------

-- 1) El MERGE solo actualiza cuando el resultado no queda negativo
MERGE INTO cuenta c
USING (SELECT id_cuenta, SUM(delta) AS delta
         FROM ajuste_saldo
        GROUP BY id_cuenta) a
   ON (c.id_cuenta = a.id_cuenta)
 WHEN MATCHED THEN
   UPDATE SET c.saldo   = c.saldo + a.delta,
              c.version = c.version + 1
   WHERE c.saldo + a.delta >= 0;          -- <-- filtro de la actualización

-- 2) Cuentas que quedaron EXCLUIDAS (su ajuste no se pudo aplicar completo)
SELECT c.id_cuenta, c.saldo AS saldo_actual, a.delta AS ajuste_pendiente,
       c.saldo + a.delta    AS saldo_si_se_aplicara
  FROM cuenta c
  JOIN (SELECT id_cuenta, SUM(delta) AS delta
          FROM ajuste_saldo
         GROUP BY id_cuenta) a ON a.id_cuenta = c.id_cuenta
 WHERE c.saldo + a.delta < 0
 ORDER BY c.id_cuenta;

COMMIT;


-- ---------------------------------------------------------------------
-- ESCRIBA 3.5 — Clientes PREFERENCIAL "en fuga" (>120 días sin transferir)
-- ---------------------------------------------------------------------
WITH ultima_transf AS (
  SELECT c.id_cliente, MAX(t.fecha_transf) AS ultima_fecha
    FROM cuenta c
    JOIN transferencia t ON t.cuenta_origen = c.id_cuenta
   GROUP BY c.id_cliente
),
saldo_prod AS (
  SELECT id_cliente,
         ROUND(SUM(saldo))                              AS saldo_total,
         COUNT(DISTINCT id_producto)                     AS productos
    FROM cuenta
   WHERE estado = 'ACTIVA'
   GROUP BY id_cliente
)
SELECT cl.id_cliente, cl.nombre, cl.ciudad,
       ut.ultima_fecha,
       TRUNC(SYSDATE - ut.ultima_fecha)  AS dias_inactivo,
       NVL(sp.saldo_total, 0)            AS saldo_total,
       NVL(sp.productos, 0)              AS productos_contratados
  FROM cliente cl
  JOIN ultima_transf ut ON ut.id_cliente = cl.id_cliente
  LEFT JOIN saldo_prod sp ON sp.id_cliente = cl.id_cliente
 WHERE cl.segmento = 'PREFERENCIAL'
   AND ut.ultima_fecha < SYSDATE - 120
 ORDER BY dias_inactivo DESC;


-- #####################################################################
-- PARTE 4 · RETO INTEGRADOR
-- #####################################################################

-- ---------------------------------------------------------------------
-- B. SECUENCIA CORREGIDA
--
--   1) FOR UPDATE ordenado por id_cuenta -> elimina el interbloqueo
--   2) UPDATE saldo = saldo +/- delta    -> nunca se pierde una escritura
--   3) Un solo COMMIT al final           -> operación atómica
--   4) UPDATE de estado con WHERE de guarda -> se nota si algo no aplicó
--   5) El CHECK ck_cta_saldo (saldo >= 0), ya existente en la tabla,
--      impide dejar una cuenta en negativo: si el descuento la dejaría
--      negativa, el UPDATE lanza ORA-02290 y toda la transacción se
--      puede revertir con ROLLBACK.
-- ---------------------------------------------------------------------

-- Reinicio para poder demostrarlo (bórrense estas 3 líneas al entregar
-- si ya lo probaron y quieren dejar el estado real)
UPDATE cuenta SET saldo = 1000000, version = 0 WHERE id_cuenta IN (1001, 1002);
UPDATE transferencia SET estado = 'REGISTRADA' WHERE id_transferencia = 950001;
COMMIT;

-- PASO 1 — Bloqueo determinista de las dos cuentas, en un solo SELECT,
--   ordenado por id_cuenta. Este ORDER BY es lo que garantiza que las
--   dos sesiones siempre pidan primero la cuenta de menor id, sin
--   importar si la transferencia es 1001->1002 o 1002->1001.
SELECT id_cuenta, saldo
  FROM cuenta
 WHERE id_cuenta IN (1001, 1002)
 ORDER BY id_cuenta
   FOR UPDATE;

-- PASO 2 — Débito y crédito sobre el valor ACTUAL de la fila
UPDATE cuenta SET saldo = saldo - 300000 WHERE id_cuenta = 1001;   -- origen
UPDATE cuenta SET saldo = saldo + 300000 WHERE id_cuenta = 1002;   -- destino
--> Si el débito dejara el saldo en negativo, esta línea falla con
--  ORA-02290 (viola ck_cta_saldo) y ninguna de las dos escrituras
--  llega a confirmarse porque todavía no hubo COMMIT.

-- PASO 3 — Movimientos contables
INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500003, 1001, 950001, SYSDATE, 'DEBITO', 300000);

INSERT INTO movimiento (id_movimiento, id_cuenta, id_transferencia, fecha_mov, tipo, valor)
VALUES (9500004, 1002, 950001, SYSDATE, 'CREDITO', 300000);

-- PASO 4 — Cambio de estado CONDICIONADO al estado esperado.
--   El WHERE es la guarda: si por alguna razón la transferencia ya no
--   estaba en REGISTRADA (otra sesión la tocó, o ya se había aplicado),
--   esta sentencia afecta 0 filas. Esa es la señal de que algo no se
--   aplicó, y SQL Developer la muestra explícitamente en el mensaje
--   "0 rows updated".
UPDATE transferencia
   SET estado = 'APLICADA'
 WHERE id_transferencia = 950001
   AND estado = 'REGISTRADA';

-- PASO 5 — Verificación manual ANTES de confirmar (no hay PL/SQL, así
--   que la verificación de "cuántas filas afectó cada sentencia" se
--   hace leyendo el mensaje de SQL Developer tras cada paso; si el
--   PASO 4 mostró 0 filas, se hace ROLLBACK en vez de COMMIT).
SELECT id_cuenta, saldo FROM cuenta WHERE id_cuenta IN (1001,1002) ORDER BY id_cuenta;
SELECT id_transferencia, estado FROM transferencia WHERE id_transferencia = 950001;

-- PASO 6 — Un solo commit para TODA la operación (o ROLLBACK si el
--   PASO 4 no afectó ninguna fila)
COMMIT;

-- ---------------------------------------------------------------------
-- Cómo se probó (documentar también en el documento de respuestas):
--   1. En la CONEXIÓN A: ejecutar esta secuencia para 1001 -> 1002.
--   2. En la CONEXIÓN B, justo después del PASO 1 de A (antes de que A
--      confirme): ejecutar la misma secuencia para 1002 -> 1001.
--   3. Observar que B queda esperando el FOR UPDATE de A (porque el
--      ORDER BY hace que ambas pidan primero la cuenta 1001), NO hay
--      ORA-00060, y en cuanto A confirma, B continúa y también confirma.
--   4. Verificar que los saldos de 1001 y 1002 cuadran exactamente
--      según las dos transferencias cruzadas (no se perdió ni se
--      inventó dinero).
-- ---------------------------------------------------------------------


-- ---------------------------------------------------------------------
-- C. CONSULTA DEL TABLERO — OPTIMIZADA
--
--   Defecto: TO_CHAR(t.fecha_transf,'YYYY-MM') = '2026-03' envuelve la
--   columna indexada en una función -> Oracle no puede usar ningún
--   índice sobre fecha_transf y hace FULL TABLE SCAN.
--   Además, COUNT(DISTINCT t.id_transferencia) es innecesario: como la
--   consulta no genera fan-out (cada transferencia aparece una sola vez
--   tras los JOIN con CUENTA y SUCURSAL, ambos 1 a 1 por PK), basta con
--   COUNT(*).
--
--   Corrección: reescribir el filtro como un rango sobre la columna sin
--   modificar. Con eso, el índice IX_TRANSF_FECHA_ESTADO (fecha_transf,
--   estado), creado en el Ejercicio 2.1, ya sirve para esta consulta:
--   no hace falta crear un índice nuevo.
-- ---------------------------------------------------------------------

-- Plan ANTES (defectuoso) — captúrenlo tal cual está en la Pieza 2
EXPLAIN PLAN FOR
SELECT s.ciudad,
       COUNT(DISTINCT t.id_transferencia)  AS operaciones,
       ROUND(SUM(t.valor))                 AS valor_total,
       ROUND(AVG(t.valor))                 AS ticket
  FROM transferencia t
  JOIN cuenta        c ON c.id_cuenta   = t.cuenta_origen
  JOIN sucursal      s ON s.id_sucursal = c.id_sucursal
 WHERE TO_CHAR(t.fecha_transf, 'YYYY-MM') = '2026-03'
   AND t.estado = 'APLICADA'
 GROUP BY s.ciudad
 ORDER BY valor_total DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));
--> ANOTE: operación = ______________  COST = ______  consistent gets = ______

-- Consulta corregida
EXPLAIN PLAN FOR
SELECT s.ciudad,
       COUNT(*)                            AS operaciones,
       ROUND(SUM(t.valor))                 AS valor_total,
       ROUND(AVG(t.valor))                 AS ticket
  FROM transferencia t
  JOIN cuenta        c ON c.id_cuenta   = t.cuenta_origen
  JOIN sucursal      s ON s.id_sucursal = c.id_sucursal
 WHERE t.fecha_transf >= DATE '2026-03-01'
   AND t.fecha_transf <  DATE '2026-04-01'
   AND t.estado = 'APLICADA'
 GROUP BY s.ciudad
 ORDER BY valor_total DESC;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY(format => 'BASIC +COST +ROWS'));
--> ANOTE: operación = ______________  COST = ______  consistent gets = ______
--
-- Ejecuten también con F6 (Autotrace) las dos versiones y comparen
-- "consistent gets" real, no solo el COST estimado. Peguen ambas
-- capturas (ANTES / DESPUÉS) en el documento de respuestas.
