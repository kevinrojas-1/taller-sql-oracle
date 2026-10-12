
-- UNIVERSIDAD EL BOSQUE — INGENIERIA DE SISTEMAS
-- Asignatura: Bases de Datos 2
-- Docente: Ing., Esp., M.Ed. Christian Felipe Duarte
--
-- TALLER PL/SQL — PLANTILLA DE ENTREGA
--
-- GRUPO No.: 1
-- INTEGRANTES: 1) Julian Felipe Valencia Malaver
--              2) Kariana Rivas
--              3) Kevin Rojas
-- FECHA DE ENTREGA: 03/10/2026
--------------------------------------------------------------------------------
--
-- COMO TRABAJAR
--   1. Ejecute primero, completo, el script 01_esquema_inventario.sql
--   2. Desarrolle cada punto en la seccion correspondiente de este archivo
--   3. No borre los encabezados de cada ejercicio ni cambie los nombres de los
--      objetos solicitados. La revision los busca por nombre: un objeto correcto
--      con otro nombre se califica como no entregado.
--   4. Los esqueletos de la Parte 5 no incluyen la clausula de disparo. Definirla
--      hace parte del ejercicio, de modo que esos bloques no compilan tal como se
--      entregan.
--
-- DISTRIBUCION DEL PUNTAJE                                     Total: 50 puntos
--   Parte 1  Procedimientos almacenados .................  8 puntos
--   Parte 2  Funciones ...................................  8 puntos
--   Parte 3  Cursores .................................... 10 puntos
--   Parte 4  Manejo de excepciones .......................  9 puntos
--   Parte 5  Disparadores ................................ 10 puntos
--   Parte 6  Caso integrador .............................  5 puntos
--
-- CRITERIOS DE EVALUACION
--   Correccion tecnica ....... 40%   El objeto compila y cumple el enunciado
--   Justificacion ............ 40%   Las decisiones de diseno estan argumentadas
--   Analisis operacional ..... 20%   Se anticipa el comportamiento ante
--                                    concurrencia, volumen y error
--
--   Cada objeto debe incluir su justificacion en el espacio marcado. Un ejercicio
--   sin justificacion obtiene como maximo el 40% de su puntaje aunque funcione.
--   Una justificacion que confunde la causa con el efecto no obtiene puntaje.
--   Describir lo que hace el codigo, sin argumentar por que se eligio esa
--   construccion y no otra, equivale a no justificar.
--
-- ENTREGA
--   Este archivo renombrado como TALLER_PLSQL_GRUPO_<n>.sql, junto con un
--   documento que contenga las salidas de DBMS_OUTPUT de cada bloque ejecutado.
--   Ambos archivos deben incluir los nombres de los tres integrantes.
--
-- SUSTENTACION
--   20 minutos por grupo. Los tres integrantes deben poder explicar cualquier
--   parte del codigo, no solamente la que desarrollaron.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON SIZE UNLIMITED


-- PASO 0 — SINCRONIZACION DE SECUENCIAS

-- HALLAZGO: el script 01 inserta productos (1001-1015) y clientes (501-507) con
-- identificador explicito, pero SEQ_PRODUCTO arranca en 1000 y SEQ_CLIENTE en 500
-- y NO fueron sincronizadas (el script solo sincroniza SEQ_PEDIDO y SEQ_MOVIMIENTO).
-- Sin este paso el primer NEXTVAL funciona, pero el segundo choca con una fila ya
-- existente y falla con ORA-00001 sobre la llave primaria. Afecta a 1.1, 4.4 y 5.1.
-- Este bloque avanza ambas secuencias hasta el maximo existente, igual que hace el
-- script 01 con las otras dos. No modifica datos ni estructura.
-- Si vuelve a ejecutar el script 01 (recrea las secuencias), repita este bloque.
DECLARE
    vn_Max NUMBER;
    vn_Val NUMBER;
BEGIN
    SELECT MAX(id_producto) INTO vn_Max FROM PRODUCTO;
    LOOP
        vn_Val := SEQ_PRODUCTO.NEXTVAL;
        EXIT WHEN vn_Val >= vn_Max;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('SEQ_PRODUCTO sincronizada. Ultimo valor consumido: ' || vn_Val);

    SELECT MAX(id_cliente) INTO vn_Max FROM CLIENTE;
    LOOP
        vn_Val := SEQ_CLIENTE.NEXTVAL;
        EXIT WHEN vn_Val >= vn_Max;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('SEQ_CLIENTE sincronizada. Ultimo valor consumido: ' || vn_Val);
END;
/


-- PASO 0B — Indice apoyo

-- No alteran la estructura de las tablas ni los datos. Se crean porque Oracle no
-- indexa automaticamente las llaves foraneas y porque la PK de EXISTENCIA empieza
-- por id_bodega, de modo que las busquedas solo por id_producto (stock consolidado,
-- vista V_STOCK_CONSOLIDADO, punto 3.1) no pueden usarla. Se pueden omitir sin que
-- el resto del archivo deje de funcionar. Es reejecutable: omite los que ya existen.
DECLARE
    PROCEDURE Crear_Indice (p_Nombre IN VARCHAR2, p_Ddl IN VARCHAR2) IS
        vn_N NUMBER;
    BEGIN
        SELECT COUNT(*) INTO vn_N FROM user_indexes WHERE index_name = UPPER(p_Nombre);
        IF vn_N = 0 THEN
            EXECUTE IMMEDIATE p_Ddl;
            DBMS_OUTPUT.PUT_LINE('Indice creado: ' || p_Nombre);
        END IF;
    END Crear_Indice;
BEGIN
    Crear_Indice('ix_Existencia_Producto',
                 'CREATE INDEX ix_Existencia_Producto ON EXISTENCIA (id_producto)');
    Crear_Indice('ix_Pedido_Cliente_Fecha',
                 'CREATE INDEX ix_Pedido_Cliente_Fecha ON PEDIDO (id_cliente, fecha_pedido)');
    Crear_Indice('ix_Movimiento_Producto_Fecha',
                 'CREATE INDEX ix_Movimiento_Producto_Fecha ON MOVIMIENTO_INVENTARIO (id_producto, fecha_mov)');
END;
/


--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 1
-- Autor       : Julian Felipe Valencia Malaver
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Procedimientos almacenados: registrar producto, ajustar stock y crear pedido.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 1 — PROCEDIMIENTOS ALMACENADOS                        (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 1.1 (2 pts)
-- SP_REGISTRAR_PRODUCTO
-- Registra un producto nuevo. Debe asignar el identificador desde SEQ_PRODUCTO,
-- validar que el precio de venta supere el costo unitario, verificar que la
-- categoria exista y manejar el caso de codigo duplicado. Devuelve el
-- identificador generado.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Se valida precio y categoria antes de pedir el id a SEQ_PRODUCTO: la
-- secuencia no se revierte con ROLLBACK y cada rechazo dejaria un hueco.
-- La categoria se verifica con un conteo para dar un mensaje de negocio
-- (-20002) y no un ORA-02291; la llave foranea queda como respaldo.
-- El codigo duplicado se detecta atrapando DUP_VAL_ON_INDEX en el INSERT y no
-- con un SELECT previo, porque entre ambos otra sesion puede insertar el mismo
-- codigo. Se verifica que la restriccion sea uk_producto_codigo, ya que la PK
-- tambien puede chocar (SEQ_PRODUCTO arranca en 1000 y el script 01 carga
-- hasta el 1015; ver PASO 0).
-- No hace COMMIT. Cada llamada toca una fila, el costo no depende del volumen.
CREATE OR REPLACE PROCEDURE SP_REGISTRAR_PRODUCTO (
    p_Codigo        IN  VARCHAR2,
    p_Nombre        IN  VARCHAR2,
    p_Id_Categoria  IN  NUMBER,
    p_Precio        IN  NUMBER,
    p_Costo         IN  NUMBER,
    p_Stock_Minimo  IN  NUMBER DEFAULT 0,
    p_Id_Producto   OUT NUMBER
) IS
    vn_Id_Producto      PRODUCTO.id_producto%TYPE;
    vn_Total_Categoria  NUMBER;
BEGIN
    p_Id_Producto := NULL;

    -- el precio de venta debe superar el costo unitario
    IF p_Precio IS NULL OR p_Costo IS NULL OR p_Precio <= p_Costo THEN
        RAISE_APPLICATION_ERROR(-20001,
            'El precio de venta (' || NVL(TO_CHAR(p_Precio), 'NULL') ||
            ') debe ser mayor al costo unitario (' ||
            NVL(TO_CHAR(p_Costo), 'NULL') || ')');
    END IF;

    -- la categoria debe existir
    SELECT COUNT(*)
      INTO vn_Total_Categoria
      FROM CATEGORIA
     WHERE id_categoria = p_Id_Categoria;

    IF vn_Total_Categoria = 0 THEN
        RAISE_APPLICATION_ERROR(-20002,
            'La categoria ' || NVL(TO_CHAR(p_Id_Categoria), 'NULL') ||
            ' no existe');
    END IF;

    -- identificador desde la secuencia, ya con las validaciones superadas
    vn_Id_Producto := SEQ_PRODUCTO.NEXTVAL;

    BEGIN
        INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria,
                              precio_unitario, costo_unitario, stock_minimo,
                              activo)
        VALUES (vn_Id_Producto, p_Codigo, p_Nombre, p_Id_Categoria,
                p_Precio, p_Costo, NVL(p_Stock_Minimo, 0), 'S');
    EXCEPTION
        WHEN DUP_VAL_ON_INDEX THEN
            IF INSTR(UPPER(SQLERRM), 'UK_PRODUCTO_CODIGO') > 0 THEN
                RAISE_APPLICATION_ERROR(-20003,
                    'Ya existe un producto con el codigo ' || p_Codigo);
            ELSE
                RAISE;
            END IF;
    END;

    p_Id_Producto := vn_Id_Producto;
END SP_REGISTRAR_PRODUCTO;
/



------------------------------------------------------------------- 1.2 (3 pts)
-- SP_AJUSTAR_STOCK
-- Registra una ENTRADA, SALIDA o AJUSTE de inventario sobre una bodega.
-- Debe actualizar EXISTENCIA e insertar el registro en MOVIMIENTO_INVENTARIO,
-- devolviendo el saldo resultante.
--   * Si la combinacion bodega-producto no existe y el tipo es ENTRADA, crearla
--   * Si el tipo es SALIDA y no existe la combinacion, rechazar la operacion
--   * Una SALIDA nunca puede dejar la existencia en negativo
-- Proteja la lectura de la existencia frente a modificaciones concurrentes.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- ENTRADA suma, SALIDA resta y en AJUSTE la cantidad es el nuevo saldo; en ese
-- caso se registra la diferencia absoluta (la tabla exige cantidad > 0) y la
-- observacion guarda "saldo X a Y". Sin diferencia no se registra nada.
-- La fila de EXISTENCIA se lee con FOR UPDATE: sin el bloqueo, dos sesiones
-- podrian leer 10, restar 8 cada una y ambas pasar la validacion
-- (actualizacion perdida). Si la combinacion no existe no hay fila que
-- bloquear: el INSERT se protege con DUP_VAL_ON_INDEX y, si otra sesion la
-- creo, se relee y se hace UPDATE. Solo una ENTRADA puede crearla; SALIDA y
-- AJUSTE se rechazan (-20006).
-- Las validaciones (tipo, cantidad, producto, bodega activa) van antes de
-- escribir. No hace COMMIT: el bloqueo dura hasta que el llamador termine su
-- transaccion, por lo que debe ser corta. Cada llamada toca una fila por PK.
CREATE OR REPLACE PROCEDURE SP_AJUSTAR_STOCK (
    p_Id_Producto  IN  NUMBER,
    p_Id_Bodega    IN  NUMBER,
    p_Tipo         IN  VARCHAR2,
    p_Cantidad     IN  NUMBER,
    p_Observacion  IN  VARCHAR2 DEFAULT NULL,
    p_Saldo_Final  OUT NUMBER
) IS
    vv_Tipo          VARCHAR2(50);
    vn_Dummy          NUMBER;
    vc_Activa        BODEGA.activa%TYPE;
    vb_Existe         BOOLEAN := TRUE;
    vn_Saldo_Actual   EXISTENCIA.cantidad%TYPE;
    vn_Saldo_Nuevo    EXISTENCIA.cantidad%TYPE;
    vn_Cantidad_Mov   MOVIMIENTO_INVENTARIO.cantidad%TYPE;
    vv_Observacion   MOVIMIENTO_INVENTARIO.observacion%TYPE;
BEGIN
    p_Saldo_Final := NULL;
    vv_Tipo := UPPER(TRIM(p_Tipo));

    -- tipo y cantidad validos
    IF vv_Tipo IS NULL OR vv_Tipo NOT IN ('ENTRADA', 'SALIDA', 'AJUSTE') THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Tipo de movimiento invalido (' || NVL(p_Tipo, 'NULL') ||
            '). Use ENTRADA, SALIDA o AJUSTE');
    END IF;

    IF p_Cantidad IS NULL OR p_Cantidad < 0
       OR (p_Cantidad = 0 AND vv_Tipo <> 'AJUSTE') THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Cantidad invalida (' || NVL(TO_CHAR(p_Cantidad), 'NULL') ||
            '). ENTRADA y SALIDA exigen mas de cero; AJUSTE acepta cero o mas ' ||
            'como nuevo saldo');
    END IF;

    -- producto y bodega deben existir y la bodega debe estar activa
    BEGIN
        SELECT 1
          INTO vn_Dummy
          FROM PRODUCTO
         WHERE id_producto = p_Id_Producto;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20005,
                'El producto ' || NVL(TO_CHAR(p_Id_Producto), 'NULL') ||
                ' no existe');
    END;

    BEGIN
        SELECT activa
          INTO vc_Activa
          FROM BODEGA
         WHERE id_bodega = p_Id_Bodega;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20005,
                'La bodega ' || NVL(TO_CHAR(p_Id_Bodega), 'NULL') ||
                ' no existe');
    END;

    IF vc_Activa = 'N' THEN
        RAISE_APPLICATION_ERROR(-20005,
            'La bodega ' || p_Id_Bodega ||
            ' esta inactiva y no admite movimientos');
    END IF;

    -- lectura de la existencia con bloqueo de la fila
    BEGIN
        SELECT cantidad
          INTO vn_Saldo_Actual
          FROM EXISTENCIA
         WHERE id_bodega   = p_Id_Bodega
           AND id_producto = p_Id_Producto
           FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            vb_Existe       := FALSE;
            vn_Saldo_Actual := 0;
    END;

    -- solo una ENTRADA puede crear la combinacion bodega-producto
    IF NOT vb_Existe AND vv_Tipo <> 'ENTRADA' THEN
        RAISE_APPLICATION_ERROR(-20006,
            'No existe existencia del producto ' || p_Id_Producto ||
            ' en la bodega ' || p_Id_Bodega ||
            '; solo una ENTRADA puede crearla (tipo recibido: ' || vv_Tipo || ')');
    END IF;

    -- calculo del nuevo saldo y de la cantidad que se registra en la bitacora
    IF vv_Tipo = 'ENTRADA' THEN
        vn_Saldo_Nuevo  := vn_Saldo_Actual + p_Cantidad;
        vn_Cantidad_Mov := p_Cantidad;
        vv_Observacion := SUBSTR(p_Observacion, 1, 200);

    ELSIF vv_Tipo = 'SALIDA' THEN
        IF p_Cantidad > vn_Saldo_Actual THEN
            RAISE_APPLICATION_ERROR(-20007,
                'Saldo insuficiente: la SALIDA de ' || p_Cantidad ||
                ' dejaria negativa la existencia (disponible: ' ||
                vn_Saldo_Actual || ')');
        END IF;
        vn_Saldo_Nuevo  := vn_Saldo_Actual - p_Cantidad;
        vn_Cantidad_Mov := p_Cantidad;
        vv_Observacion := SUBSTR(p_Observacion, 1, 200);

    ELSE  -- AJUSTE: la cantidad recibida es el nuevo saldo
        vn_Saldo_Nuevo  := p_Cantidad;
        vn_Cantidad_Mov := ABS(p_Cantidad - vn_Saldo_Actual);
        vv_Observacion := SUBSTR(NVL(p_Observacion, 'Ajuste de inventario') ||
                                 ' (saldo ' || vn_Saldo_Actual || ' a ' ||
                                 vn_Saldo_Nuevo || ')', 1, 200);
    END IF;

    -- escritura (un AJUSTE sin diferencia no modifica nada)
    IF vn_Cantidad_Mov > 0 THEN
        IF vb_Existe THEN
            UPDATE EXISTENCIA
               SET cantidad = vn_Saldo_Nuevo
             WHERE id_bodega   = p_Id_Bodega
               AND id_producto = p_Id_Producto;
        ELSE
            BEGIN
                INSERT INTO EXISTENCIA (id_bodega, id_producto, cantidad)
                VALUES (p_Id_Bodega, p_Id_Producto, vn_Saldo_Nuevo);
            EXCEPTION
                WHEN DUP_VAL_ON_INDEX THEN
                    -- otra sesion creo la combinacion entre la lectura y el
                    -- INSERT: se bloquea y la ENTRADA se aplica como UPDATE
                    SELECT cantidad
                      INTO vn_Saldo_Actual
                      FROM EXISTENCIA
                     WHERE id_bodega   = p_Id_Bodega
                       AND id_producto = p_Id_Producto
                       FOR UPDATE;

                    vn_Saldo_Nuevo := vn_Saldo_Actual + p_Cantidad;

                    UPDATE EXISTENCIA
                       SET cantidad = vn_Saldo_Nuevo
                     WHERE id_bodega   = p_Id_Bodega
                       AND id_producto = p_Id_Producto;
            END;
        END IF;

        INSERT INTO MOVIMIENTO_INVENTARIO (id_movimiento, id_producto, id_bodega,
                                           tipo, cantidad, id_pedido,
                                           observacion)
        VALUES (SEQ_MOVIMIENTO.NEXTVAL, p_Id_Producto, p_Id_Bodega,
                vv_Tipo, vn_Cantidad_Mov, NULL, vv_Observacion);
    END IF;

    p_Saldo_Final := vn_Saldo_Nuevo;
END SP_AJUSTAR_STOCK;
/



------------------------------------------------------------------- 1.3 (3 pts)
-- SP_CREAR_PEDIDO
-- Crea la cabecera de un pedido en estado BORRADOR y devuelve el identificador
-- generado. Debe rechazar clientes inactivos y clientes sin cupo de credito
-- disponible, con mensajes distinguibles entre si.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Se valida en orden: existencia, estado y cupo. FN_CUPO_DISPONIBLE retorna 0
-- tanto para inactivo como para inexistente; evaluar el cupo primero
-- confundiria los mensajes (-20008 cliente inexistente o inactivo, con texto
-- distinto; -20009 sin cupo).
-- El cupo se reutiliza de FN_CUPO_DISPONIBLE para que la regla viva en un solo
-- sitio. Esa funcion se crea en el punto 2.2, por lo que este procedimiento se
-- recompila con ALTER PROCEDURE despues de crearla.
-- Crear un BORRADOR no consume cupo, asi que la validacion es orientativa; la
-- definitiva ocurre al facturar (PKG_VENTAS).
CREATE OR REPLACE PROCEDURE SP_CREAR_PEDIDO (
    p_Id_Cliente  IN  NUMBER,
    p_Id_Pedido   OUT NUMBER
) IS
    vc_Activo  CLIENTE.activo%TYPE;
BEGIN
    p_Id_Pedido := NULL;

    -- el cliente debe existir
    BEGIN
        SELECT activo
          INTO vc_Activo
          FROM CLIENTE
         WHERE id_cliente = p_Id_Cliente;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20008,
                'El cliente ' || NVL(TO_CHAR(p_Id_Cliente), 'NULL') ||
                ' no existe');
    END;

    -- el cliente debe estar activo
    IF vc_Activo = 'N' THEN
        RAISE_APPLICATION_ERROR(-20008,
            'El cliente ' || p_Id_Cliente ||
            ' esta inactivo y no puede crear pedidos');
    END IF;

    -- el cliente debe tener cupo de credito disponible
    IF FN_CUPO_DISPONIBLE(p_Id_Cliente) <= 0 THEN
        RAISE_APPLICATION_ERROR(-20009,
            'El cliente ' || p_Id_Cliente ||
            ' no tiene cupo de credito disponible');
    END IF;

    INSERT INTO PEDIDO (id_pedido, id_cliente, fecha_pedido, estado, total)
    VALUES (SEQ_PEDIDO.NEXTVAL, p_Id_Cliente, SYSDATE, 'BORRADOR', 0)
    RETURNING id_pedido INTO p_Id_Pedido;
END SP_CREAR_PEDIDO;
/




--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 2
-- Autor       : Julian Felipe Valencia Malaver
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Funciones: stock disponible, cupo disponible, descuento y consulta desde SQL.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 2 — FUNCIONES                                         (8 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 2.1 (2 pts)
-- FN_STOCK_DISPONIBLE
-- Retorna la cantidad disponible de un producto. Si se indica bodega, devuelve
-- el saldo de esa bodega; si p_Id_Bodega llega nulo, el consolidado de todas.
-- Un producto inexistente debe retornar cero y no una excepcion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- SUM con NVL: una consulta con funcion de grupo siempre devuelve una fila, asi
-- que NO_DATA_FOUND no ocurre y un producto inexistente da 0 sin excepcion.
-- Se usan dos consultas (con y sin bodega) en lugar de
-- NVL(p_Id_Bodega, id_bodega), para que con bodega el acceso sea por la PK.
-- Solo lee, por eso puede usarse desde SQL. Devuelve una foto y no reserva
-- stock. Con mucho volumen, la consulta consolidada (sin bodega) no puede usar la
-- PK porque esta empieza por id_bodega; un indice ix_Existencia_Producto la
-- resuelve (ver PASO 0B).
CREATE OR REPLACE FUNCTION FN_STOCK_DISPONIBLE (
    p_Id_Producto IN NUMBER,
    p_Id_Bodega   IN NUMBER DEFAULT NULL
) RETURN NUMBER IS
    vn_Stock  NUMBER;
BEGIN
    IF p_Id_Bodega IS NULL THEN
        SELECT NVL(SUM(cantidad), 0)
          INTO vn_Stock
          FROM EXISTENCIA
         WHERE id_producto = p_Id_Producto;
    ELSE
        SELECT NVL(SUM(cantidad), 0)
          INTO vn_Stock
          FROM EXISTENCIA
         WHERE id_producto = p_Id_Producto
           AND id_bodega   = p_Id_Bodega;
    END IF;

    RETURN vn_Stock;
END FN_STOCK_DISPONIBLE;
/



------------------------------------------------------------------- 2.2 (2 pts)
-- FN_CUPO_DISPONIBLE
-- Retorna el cupo de credito disponible del cliente, entendido como cupo menos
-- saldo pendiente. Un cliente inactivo retorna cero y el resultado nunca puede
-- ser negativo.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- GREATEST(cupo - saldo, 0) evita resultados negativos, ya que el saldo puede
-- superar el cupo. Inactivo retorna 0. Cliente inexistente retorna 0; solo se
-- atrapa NO_DATA_FOUND para no ocultar otros errores.
-- Una sola consulta por PK lee cupo, saldo y estado.
-- Solo lee. Llamada por fila desde un SELECT implica un cambio de contexto y
-- una consulta por cliente; con muchos clientes conviene calcular
-- cupo - saldo directamente en el SQL.
CREATE OR REPLACE FUNCTION FN_CUPO_DISPONIBLE (
    p_Id_Cliente IN NUMBER
) RETURN NUMBER IS
    vn_Cupo    CLIENTE.cupo_credito%TYPE;
    vn_Saldo   CLIENTE.saldo_pendiente%TYPE;
    vc_Activo CLIENTE.activo%TYPE;
BEGIN
    SELECT cupo_credito, saldo_pendiente, activo
      INTO vn_Cupo, vn_Saldo, vc_Activo
      FROM CLIENTE
     WHERE id_cliente = p_Id_Cliente;

    IF vc_Activo = 'N' THEN
        RETURN 0;
    END IF;

    RETURN GREATEST(vn_Cupo - vn_Saldo, 0);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END FN_CUPO_DISPONIBLE;
/

-- SP_CREAR_PEDIDO (punto 1.3) usa FN_CUPO_DISPONIBLE, que se crea despues en este
-- archivo; se recompila aqui para que quede VALID tras ejecutar el script.
ALTER PROCEDURE SP_CREAR_PEDIDO COMPILE;



------------------------------------------------------------------- 2.3 (3 pts)
-- FN_CALCULAR_DESCUENTO
-- Retorna el VALOR en pesos del descuento aplicable, segun estas reglas
-- acumulables:
--     Monto mayor o igual a 2.000.000 ................. 8%
--     Monto entre 800.000 y 1.999.999 ................. 5%
--     Monto menor a 800.000 ........................... 0%
--     Adicional si el cliente no tiene saldo pendiente . 2%
--     Tope maximo acumulado ........................... 10%
-- La funcion retorna el valor del descuento, no el porcentaje.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- Se acumula el porcentaje, se aplica el tope con
-- LEAST y se convierte a pesos con un solo ROUND, para devolver el valor y no
-- el porcentaje.
-- Los escalones usan >= encadenados con ELSIF, asi 1.999.999,50 no queda sin
-- regla. El 2% se suma a cualquier escalon (reglas acumulables), incluso al de
-- 0%.
-- Los valores de negocio se declaran como constantes (prefijo v_) y no como
-- numeros sueltos en el codigo. Monto nulo o <= 0 y cliente inexistente
-- retornan 0.
-- Solo lee el saldo del momento; en la facturacion se llama con el cliente ya
-- bloqueado, para que el saldo no cambie entre el calculo y la validacion del cupo.
CREATE OR REPLACE FUNCTION FN_CALCULAR_DESCUENTO (
    p_Id_Cliente IN NUMBER,
    p_Monto      IN NUMBER
) RETURN NUMBER IS
    vn_Monto_Alto     CONSTANT NUMBER := 2000000;
    vn_Monto_Medio    CONSTANT NUMBER := 800000;
    vn_Pct_Alto       CONSTANT NUMBER := 8;
    vn_Pct_Medio      CONSTANT NUMBER := 5;
    vn_Pct_Sin_Saldo  CONSTANT NUMBER := 2;
    vn_Pct_Tope       CONSTANT NUMBER := 10;

    vn_Saldo  CLIENTE.saldo_pendiente%TYPE;
    vn_Pct    NUMBER := 0;
BEGIN
    IF p_Monto IS NULL OR p_Monto <= 0 THEN
        RETURN 0;
    END IF;

    SELECT saldo_pendiente
      INTO vn_Saldo
      FROM CLIENTE
     WHERE id_cliente = p_Id_Cliente;

    -- escalon por monto
    IF p_Monto >= vn_Monto_Alto THEN
        vn_Pct := vn_Pct_Alto;
    ELSIF p_Monto >= vn_Monto_Medio THEN
        vn_Pct := vn_Pct_Medio;
    END IF;

    -- adicional por cliente sin saldo pendiente
    IF vn_Saldo = 0 THEN
        vn_Pct := vn_Pct + vn_Pct_Sin_Saldo;
    END IF;

    -- tope maximo acumulado
    vn_Pct := LEAST(vn_Pct, vn_Pct_Tope);

    RETURN ROUND(p_Monto * vn_Pct / 100, 2);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN 0;
END FN_CALCULAR_DESCUENTO;
/



------------------------------------------------------------------- 2.4 (1 pt)
-- Escriba una consulta que liste los clientes activos con su cupo disponible,
-- usando la funcion del punto 2.2, ordenados de mayor a menor.
-- Explique por que una funcion definida por el usuario puede invocarse desde
-- una sentencia SQL y que restriccion debe cumplir para poder hacerlo.
-------------------------------------------------------------------------------
-- RESPUESTA:
-- Una funcion puede usarse en SQL porque devuelve un valor escalar que el motor
-- trata como una expresion mas, ejecutandola una vez por fila. Debe tener solo
-- parametros IN y un tipo que SQL conozca (no BOOLEAN).
-- La restriccion es que no puede modificar la base de datos: sin INSERT,
-- UPDATE, DELETE, DDL ni COMMIT/ROLLBACK (si no, ORA-14551).
-- FN_CUPO_DISPONIBLE solo lee CLIENTE, asi que cumple.

SELECT c.id_cliente,
       c.nombre,
       FN_CUPO_DISPONIBLE(c.id_cliente) AS cupo_disponible
  FROM CLIENTE c
 WHERE c.activo = 'S'
 ORDER BY cupo_disponible DESC;




--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 3
-- Autor       : Kariana Rivas
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Cursores: explicito, parametrizado, FOR UPDATE, REF CURSOR y BULK COLLECT/FORALL.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 3 — CURSORES                                         (10 puntos / 90 min)
--==============================================================================

------------------------------------------------------------------- 3.1 (2 pts)
-- Bloque anonimo que recorra, con un CURSOR EXPLICITO, los productos cuyo stock
-- consolidado este por debajo del stock minimo, e imprima un reporte con codigo,
-- nombre, stock actual, stock minimo y unidades faltantes, mas el total de
-- productos en esa condicion.
-- Debe usar OPEN, FETCH y CLOSE de forma explicita. El ciclo FOR implicito no se
-- acepta en este punto.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) Cursor explicito con OPEN / FETCH / CLOSE: el programador controla cuando se abre y se cierra
--    y puede consultar los atributos %NOTFOUND y %ROWCOUNT. Aqui %ROWCOUNT entrega el total de
--    productos en esa condicion sin una segunda consulta COUNT(*) (que ademas podria dar un valor
--    distinto si otra sesion confirmara entre las dos lecturas).
-- 2) El EXIT va inmediatamente despues del FETCH y antes de usar la fila; si se pusiera al final
--    del ciclo se procesaria dos veces la ultima fila.
-- 3) El stock consolidado se toma de V_STOCK_CONSOLIDADO (LEFT JOIN): un producto sin existencias
--    aparece con 0 y no desaparece del reporte. Por eso aparece 1015 (inactivo, sin stock). Se
--    imprime la columna ACTIVO para que se vea que es un producto inactivo y no una reposicion
--    real; si se quisiera excluirlo bastaria agregar AND p.activo = 'S'.
-- 4) Operacional: la vista agrega todas las existencias (GROUP BY) y se evalua completa; con
--    millones de filas conviene un indice en EXISTENCIA(id_producto), por ejemplo ix_Existencia_Producto. El EXCEPTION cierra el
--    cursor si algo falla para no dejar cursores abiertos (limite OPEN_CURSORS).
DECLARE
    CURSOR c_Bajo_Minimo IS
        SELECT v.codigo, v.producto, v.stock_total, v.stock_minimo, p.activo
          FROM V_STOCK_CONSOLIDADO v
          JOIN PRODUCTO p ON p.id_producto = v.id_producto
         WHERE v.stock_total < v.stock_minimo
         ORDER BY (v.stock_minimo - v.stock_total) DESC, v.codigo;

    r_Fila   c_Bajo_Minimo%ROWTYPE;
    vn_Total  NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('REPORTE: PRODUCTOS BAJO EL STOCK MINIMO');
    DBMS_OUTPUT.PUT_LINE(RPAD('CODIGO', 10) || RPAD('NOMBRE', 34) || LPAD('ACTUAL', 8)
                         || LPAD('MINIMO', 8) || LPAD('FALTAN', 8) || '  ACTIVO');
    DBMS_OUTPUT.PUT_LINE(RPAD('-', 76, '-'));

    OPEN c_Bajo_Minimo;
    LOOP
        FETCH c_Bajo_Minimo INTO r_Fila;
        EXIT WHEN c_Bajo_Minimo%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE(RPAD(r_Fila.codigo, 10) || RPAD(SUBSTR(r_Fila.producto, 1, 32), 34)
                             || LPAD(r_Fila.stock_total, 8) || LPAD(r_Fila.stock_minimo, 8)
                             || LPAD(r_Fila.stock_minimo - r_Fila.stock_total, 8)
                             || '  ' || r_Fila.activo);
    END LOOP;
    vn_Total := c_Bajo_Minimo%ROWCOUNT;
    CLOSE c_Bajo_Minimo;

    DBMS_OUTPUT.PUT_LINE(RPAD('-', 76, '-'));
    DBMS_OUTPUT.PUT_LINE('Total de productos bajo el minimo: ' || vn_Total);
EXCEPTION
    WHEN OTHERS THEN
        IF c_Bajo_Minimo%ISOPEN THEN
            CLOSE c_Bajo_Minimo;
        END IF;
        RAISE;
END;
/



------------------------------------------------------------------- 3.2 (2 pts)
-- Bloque anonimo con un CURSOR PARAMETRIZADO que reciba identificador de cliente
-- y un rango de fechas, y muestre los pedidos CONFIRMADOS de ese cliente en ese
-- rango, con su total y la cantidad de lineas de cada pedido.
-- Pruebelo con el cliente 501 entre 2026-01-01 y 2026-12-31.
-- Los parametros deben declararse en el cursor, no tomarse del alcance del bloque.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) Los parametros (cliente, desde, hasta) se declaran en el cursor y se pasan en el OPEN. Asi el
--    cursor es reutilizable con distintos valores y su significado no depende de variables del
--    bloque que podrian cambiar de valor entre la declaracion y la apertura.
-- 2) La fecha final se trata como limite exclusivo del dia siguiente (fecha < p_Hasta + 1). PEDIDO
--    guarda fecha y hora (DATE): con "BETWEEN desde AND hasta" un pedido del 31-dic a las 15:00
--    quedaria fuera, porque 31-dic equivale a las 00:00.
-- 3) LEFT JOIN + COUNT(d.linea): un pedido confirmado sin lineas aparece con 0 en vez de
--    desaparecer (con INNER JOIN se perderia).
-- 4) Para el cliente 501 en 2026 debe mostrar los pedidos 1 y 2; el pedido 6 es BORRADOR y no entra.
-- 5) Operacional: el filtro por cliente, estado y fecha se beneficia de un indice en
--    PEDIDO(id_cliente, fecha_pedido), por ejemplo ix_Pedido_Cliente_Fecha; con pocos clientes y mucho historico se nota.
DECLARE
    CURSOR c_Pedidos (p_Id_Cliente NUMBER, p_Desde DATE, p_Hasta DATE) IS
        SELECT p.id_pedido, p.fecha_pedido, p.total, COUNT(d.linea) AS lineas
          FROM PEDIDO p
          LEFT JOIN DETALLE_PEDIDO d ON d.id_pedido = p.id_pedido
         WHERE p.id_cliente   = p_Id_Cliente
           AND p.estado       = 'CONFIRMADO'
           AND p.fecha_pedido >= p_Desde
           AND p.fecha_pedido <  p_Hasta + 1
         GROUP BY p.id_pedido, p.fecha_pedido, p.total
         ORDER BY p.fecha_pedido, p.id_pedido;

    vn_Acum NUMBER := 0;
    vn_N    NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('PEDIDOS CONFIRMADOS - CLIENTE 501 - 2026');
    DBMS_OUTPUT.PUT_LINE(RPAD('PEDIDO', 8) || RPAD('FECHA', 14) || LPAD('TOTAL', 14) || LPAD('LINEAS', 8));
    FOR r_Fila IN c_Pedidos(501, TO_DATE('2026-01-01', 'YYYY-MM-DD'), TO_DATE('2026-12-31', 'YYYY-MM-DD')) LOOP
        DBMS_OUTPUT.PUT_LINE(RPAD(r_Fila.id_pedido, 8) || RPAD(TO_CHAR(r_Fila.fecha_pedido, 'YYYY-MM-DD'), 14)
                             || LPAD(TO_CHAR(r_Fila.total, 'FM999G999G990'), 14) || LPAD(r_Fila.lineas, 8));
        vn_Acum := vn_Acum + r_Fila.total;
        vn_N    := vn_N + 1;
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('Pedidos: ' || vn_N || '   Total acumulado: ' || TO_CHAR(vn_Acum, 'FM999G999G990'));
END;
/



------------------------------------------------------------------- 3.3 (3 pts)
-- Bloque anonimo con un CURSOR FOR UPDATE que recorra los productos de una
-- categoria y ajuste su precio un porcentaje dado, usando WHERE CURRENT OF.
--   * No debe modificar productos inactivos
--   * El precio resultante no puede quedar por debajo del costo mas el margen
--     minimo de la categoria
-- Explique que bloqueo genera FOR UPDATE, cuanto dura, y por que WHERE CURRENT OF
-- es preferible a un UPDATE por clave primaria.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- BLOQUEO QUE GENERA FOR UPDATE: al hacer OPEN, Oracle bloquea con candado exclusivo de FILA todas
-- las filas del conjunto resultado (no solo la que se va leyendo) y las mantiene hasta el
-- COMMIT o ROLLBACK de la transaccion. Otras sesiones pueden LEER esas filas (lectura consistente,
-- sin esperar) pero no modificarlas ni borrarlas: esperan. FOR UPDATE OF precio_unitario limita el
-- bloqueo a la tabla que contiene esa columna (relevante si el cursor tuviera joins). Con NOWAIT o
-- WAIT n se evita esperar indefinidamente. Consecuencia: un COMMIT dentro del ciclo cierra el
-- cursor y el siguiente FETCH falla con ORA-01002; por eso el COMMIT va despues del ciclo.
--
-- WHERE CURRENT OF vs UPDATE POR CLAVE PRIMARIA: WHERE CURRENT OF usa el ROWID de la fila que el
-- cursor acaba de leer y bloquear. Garantiza que se actualiza exactamente esa fila (sin riesgo de
-- que el predicado de la PK apunte a otra por un error de variable), evita una busqueda por indice
-- y deja claro que la lectura y la escritura son una sola operacion. El UPDATE por PK tambien seria
-- correcto, pero la correccion queda en manos del programador.
--
-- DECISIONES: (a) los productos inactivos se omiten, (b) si el precio resultante queda por debajo de
-- costo * (1 + margen/100) el producto se omite y se informa, en lugar de forzarlo al piso: asi no se
-- aplica un cambio distinto al que se pidio. (c) El margen se lee una sola vez de CATEGORIA antes del
-- ciclo. (d) El bloque no confirma: quien lo ejecuta decide COMMIT o ROLLBACK.
-- Operacional: mientras el bloque no termine, los productos de la categoria quedan bloqueados para
-- otras sesiones; la transaccion debe ser corta.
DECLARE
    vn_Id_Categoria CONSTANT NUMBER := 1;     -- categoria a ajustar
    vn_Porcentaje   CONSTANT NUMBER := -22;   -- variacion en %: positivo sube, negativo baja

    vn_Margen   CATEGORIA.margen_minimo%TYPE;
    vn_Nuevo    NUMBER;
    vn_Piso     NUMBER;
    vn_Mod      NUMBER := 0;
    vn_Omit     NUMBER := 0;

    CURSOR c_Prod (p_Id_Categoria NUMBER) IS
        SELECT id_producto, codigo, precio_unitario, costo_unitario, activo
          FROM PRODUCTO
         WHERE id_categoria = p_Id_Categoria
         ORDER BY id_producto
           FOR UPDATE OF precio_unitario;
BEGIN
    SELECT margen_minimo INTO vn_Margen
      FROM CATEGORIA
     WHERE id_categoria = vn_Id_Categoria;

    DBMS_OUTPUT.PUT_LINE('Categoria ' || vn_Id_Categoria || ' - margen minimo ' || vn_Margen
                         || '% - ajuste solicitado ' || vn_Porcentaje || '%');

    FOR r_Fila IN c_Prod(vn_Id_Categoria) LOOP
        IF r_Fila.activo <> 'S' THEN
            DBMS_OUTPUT.PUT_LINE(RPAD(r_Fila.codigo, 10) || 'OMITIDO: producto inactivo');
            vn_Omit := vn_Omit + 1;
        ELSE
            vn_Nuevo := ROUND(r_Fila.precio_unitario * (1 + vn_Porcentaje / 100), 2);
            vn_Piso  := r_Fila.costo_unitario * (1 + vn_Margen / 100);
            IF vn_Nuevo < vn_Piso THEN
                DBMS_OUTPUT.PUT_LINE(RPAD(r_Fila.codigo, 10) || 'OMITIDO: ' || vn_Nuevo
                                     || ' queda bajo el piso de ' || vn_Piso);
                vn_Omit := vn_Omit + 1;
            ELSE
                UPDATE PRODUCTO
                   SET precio_unitario = vn_Nuevo
                 WHERE CURRENT OF c_Prod;
                DBMS_OUTPUT.PUT_LINE(RPAD(r_Fila.codigo, 10) || 'ACTUALIZADO: ' || r_Fila.precio_unitario
                                     || ' -> ' || vn_Nuevo);
                vn_Mod := vn_Mod + 1;
            END IF;
        END IF;
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('Actualizados: ' || vn_Mod || '   Omitidos: ' || vn_Omit);
    -- Sin COMMIT: ejecute COMMIT o ROLLBACK segun corresponda.
END;
/



------------------------------------------------------------------- 3.4 (2 pts)
-- SP_LISTAR_MOVIMIENTOS
-- Procedimiento que reciba un identificador de producto y devuelva un
-- SYS_REFCURSOR con los movimientos de inventario de ese producto, ordenados
-- por fecha. Incluya un bloque anonimo que consuma el cursor devuelto y lo cierre.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) SYS_REFCURSOR permite devolver un conjunto de filas a quien llama sin que el procedimiento
--    sepa que hara con ellas: el llamador (otro PL/SQL, JDBC, una aplicacion) controla la
--    iteracion. Una alternativa seria una coleccion o una tabla temporal, que obligan a materializar
--    todo en memoria o a escribir.
-- 2) El procedimiento solo ABRE el cursor (OPEN ... FOR) y no lo cierra: la responsabilidad de
--    cerrarlo es del consumidor. Por eso el bloque consumidor hace CLOSE, y tambien lo hace en el
--    EXCEPTION, para no dejar un cursor abierto si algo falla a mitad del recorrido.
-- 3) ORDER BY fecha_mov, id_movimiento: la fecha sola no es suficiente porque varios movimientos
--    pueden compartir el mismo dia; el id desempata de forma determinista.
-- 4) El consumidor declara la fila como MOVIMIENTO_INVENTARIO%ROWTYPE y el cursor selecciona *,
--    de modo que la estructura siempre coincide con la tabla.
-- 5) Operacional: un cursor abierto retiene recursos del servidor hasta cerrarse; no debe
--    devolverse un REF CURSOR a capas que puedan olvidar cerrarlo.
CREATE OR REPLACE PROCEDURE SP_LISTAR_MOVIMIENTOS (
    p_Id_Producto IN  NUMBER,
    p_Cursor      OUT SYS_REFCURSOR
) IS
BEGIN
    OPEN p_Cursor FOR
        SELECT *
          FROM MOVIMIENTO_INVENTARIO
         WHERE id_producto = p_Id_Producto
         ORDER BY fecha_mov, id_movimiento;
END SP_LISTAR_MOVIMIENTOS;
/

-- Bloque consumidor:
DECLARE
    c_Mov  SYS_REFCURSOR;
    r_Mov  MOVIMIENTO_INVENTARIO%ROWTYPE;
    vn_N    NUMBER := 0;
BEGIN
    SP_LISTAR_MOVIMIENTOS(1001, c_Mov);

    DBMS_OUTPUT.PUT_LINE('MOVIMIENTOS DEL PRODUCTO 1001');
    DBMS_OUTPUT.PUT_LINE(RPAD('ID', 5) || RPAD('FECHA', 12) || RPAD('TIPO', 9) || RPAD('BODEGA', 8)
                         || LPAD('CANT', 6) || '  OBSERVACION');
    LOOP
        FETCH c_Mov INTO r_Mov;
        EXIT WHEN c_Mov%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE(RPAD(r_Mov.id_movimiento, 5)
                             || RPAD(TO_CHAR(r_Mov.fecha_mov, 'YYYY-MM-DD'), 12)
                             || RPAD(r_Mov.tipo, 9) || RPAD(r_Mov.id_bodega, 8)
                             || LPAD(r_Mov.cantidad, 6) || '  ' || r_Mov.observacion);
        vn_N := vn_N + 1;
    END LOOP;
    CLOSE c_Mov;
    DBMS_OUTPUT.PUT_LINE('Movimientos listados: ' || vn_N);
EXCEPTION
    WHEN OTHERS THEN
        IF c_Mov%ISOPEN THEN
            CLOSE c_Mov;
        END IF;
        RAISE;
END;
/



------------------------------------------------------------------- 3.5 (1 pt)
-- Bloque anonimo que cargue con BULK COLLECT los productos de una categoria en
-- una coleccion y use FORALL para actualizar su stock minimo.
-- Explique que costo concreto elimina esta tecnica y a partir de que volumen
-- empieza a notarse.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- COSTO QUE ELIMINA: los cambios de contexto entre el motor PL/SQL y el motor SQL. Un ciclo FOR con
-- un UPDATE dentro envia al motor SQL una sentencia por fila (N idas y vueltas); BULK COLLECT trae
-- todas las filas en UN solo viaje y FORALL envia todas las modificaciones en UN solo viaje. Cada
-- cambio de contexto es barato, pero multiplicado por muchas filas domina el tiempo total.
-- VOLUMEN: con 3 filas (como aqui) la diferencia es imperceptible; empieza a notarse del orden de
-- miles de filas y con cientos de miles o millones puede ser de una a dos ordenes de magnitud.
-- Con triggers de fila sobre la tabla la mejora es menor, porque los triggers se siguen ejecutando
-- fila a fila.
-- LIMITES: BULK COLLECT sin LIMIT carga todo en memoria de sesion (PGA); para volumenes grandes se
-- usa FETCH ... BULK COLLECT ... LIMIT 1000 dentro de un ciclo. FORALL tolera fallos parciales con
-- SAVE EXCEPTIONS (sin esa clausula, la primera fila que falle revierte la sentencia completa).
DECLARE
    vn_Id_Categoria CONSTANT NUMBER := 3;      -- categoria a ajustar
    vn_Factor       CONSTANT NUMBER := 1.10;   -- aumento del 10% del stock minimo

    TYPE t_Ids     IS TABLE OF PRODUCTO.id_producto%TYPE;
    TYPE t_Minimos IS TABLE OF PRODUCTO.stock_minimo%TYPE;
    v_Ids      t_Ids;
    v_Nuevos   t_Minimos;
BEGIN
    SELECT id_producto, CEIL(stock_minimo * vn_Factor)
      BULK COLLECT INTO v_Ids, v_Nuevos
      FROM PRODUCTO
     WHERE id_categoria = vn_Id_Categoria
       AND activo = 'S';

    DBMS_OUTPUT.PUT_LINE('Productos cargados en la coleccion: ' || v_Ids.COUNT);

    IF v_Ids.COUNT > 0 THEN
        FORALL vn_Indice IN 1 .. v_Ids.COUNT
            UPDATE PRODUCTO
               SET stock_minimo = v_Nuevos(vn_Indice)
             WHERE id_producto = v_Ids(vn_Indice);

        DBMS_OUTPUT.PUT_LINE('Filas actualizadas con FORALL: ' || SQL%ROWCOUNT);
        FOR vn_Indice IN 1 .. v_Ids.COUNT LOOP
            DBMS_OUTPUT.PUT_LINE('  producto ' || v_Ids(vn_Indice) || ' -> nuevo stock minimo ' || v_Nuevos(vn_Indice));
        END LOOP;
    END IF;
    -- Sin COMMIT: ejecute COMMIT o ROLLBACK segun corresponda.
END;
/




--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 4
-- Autor       : Kariana Rivas
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Excepciones: predefinidas, propias, RAISE_APPLICATION_ERROR, EXCEPTION_INIT y registro autonomo.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 4 — MANEJO DE EXCEPCIONES                             (9 puntos / 75 min)
--==============================================================================

------------------------------------------------------------------- 4.1 (2 pts)
-- FN_PRECIO_PRODUCTO
-- Funcion que reciba el CODIGO de un producto y retorne su precio, manejando
-- explicitamente NO_DATA_FOUND y TOO_MANY_ROWS, con retorno de -1 y -2
-- respectivamente, e imprimiendo un mensaje descriptivo en cada caso.
-- Explique en que situacion real se produciria TOO_MANY_ROWS sobre esta tabla,
-- considerando las restricciones que hoy tiene.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) SELECT ... INTO exige exactamente una fila: cero filas lanza NO_DATA_FOUND y mas de una lanza
--    TOO_MANY_ROWS. Ambas se atrapan por separado para devolver codigos distintos (-1 y -2) que el
--    llamador puede diferenciar. Un WHEN OTHERS unico no permitiria distinguirlas.
-- 2) Se usan -1 y -2 porque ningun precio valido puede ser negativo (CK_PRODUCTO_PRECIO > 0), asi
--    que no se confunden con un precio real. Cada caso imprime un mensaje descriptivo.
-- 3) Cualquier otro error (por ejemplo, un problema de privilegios) NO se atrapa: debe propagarse
--    en vez de convertirse silenciosamente en un valor.
--
-- CUANDO OCURRIRIA TOO_MANY_ROWS: con UK_PRODUCTO_CODIGO activa, una busqueda por igualdad sobre
-- CODIGO nunca puede devolver dos filas: la restriccion unica lo impide. Solo ocurriria si (a) la
-- restriccion se deshabilita o se elimina y se insertan codigos repetidos, o (b) la funcion
-- comparara de forma que ignore la restriccion, por ejemplo UPPER(codigo) = UPPER(p_Codigo): la
-- unicidad es sensible a mayusculas, asi que 'hm-0001' y 'HM-0001' pueden coexistir y ambas
-- coincidirian. Por la misma razon, la rama de -2 no se puede reproducir con los datos actuales.
-- Operacional: la busqueda por codigo usa el indice unico UK_PRODUCTO_CODIGO (una lectura).
CREATE OR REPLACE FUNCTION FN_PRECIO_PRODUCTO (
    p_Codigo IN VARCHAR2
) RETURN NUMBER IS
    vn_Precio PRODUCTO.precio_unitario%TYPE;
BEGIN
    SELECT precio_unitario
      INTO vn_Precio
      FROM PRODUCTO
     WHERE codigo = p_Codigo;
    RETURN vn_Precio;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        DBMS_OUTPUT.PUT_LINE('FN_PRECIO_PRODUCTO: no existe un producto con el codigo ' || p_Codigo);
        RETURN -1;
    WHEN TOO_MANY_ROWS THEN
        DBMS_OUTPUT.PUT_LINE('FN_PRECIO_PRODUCTO: hay mas de un producto con el codigo ' || p_Codigo);
        RETURN -2;
END FN_PRECIO_PRODUCTO;
/



------------------------------------------------------------------- 4.2 (2 pts)
-- SP_VALIDAR_DESPACHO
-- Procedimiento que verifique si puede despacharse una cantidad de un producto
-- desde una bodega. Debe declarar una EXCEPCION PROPIA, levantarla con RAISE
-- cuando la cantidad solicitada supere el disponible, y capturarla en el bloque
-- EXCEPTION.
-- Argumente por que conviene nombrar esa condicion en lugar de resolverla con un
-- condicional.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- POR QUE UNA EXCEPCION NOMBRADA Y NO UN CONDICIONAL: un IF resuelve la condicion en el sitio donde
-- se detecta; la excepcion separa DONDE se detecta de DONDE se decide que hacer. (1) Interrumpe de
-- inmediato el flujo normal, aunque la condicion se detecte en un nivel profundo de llamadas, sin que
-- cada nivel intermedio tenga que propagar un codigo de retorno que alguien podria ignorar.
-- (2) Se maneja por nombre: el llamador distingue "stock insuficiente" de cualquier otro fallo
-- (ORA-xxxx) sin comparar textos ni numeros. (3) Documenta el contrato del procedimiento.
-- (4) El camino exitoso queda sin anidamiento de IF.
--
-- DISENO: el manejador imprime el detalle y vuelve a lanzar el error con RAISE_APPLICATION_ERROR
-- (-20040). Si solo imprimiera, el llamador no sabria que el despacho no es posible: un procedimiento
-- sin parametro OUT que traga el error deja al programa seguir como si todo estuviera bien. No usa
-- SP_REGISTRAR_ERROR porque ese procedimiento se crea mas adelante (4.5).
-- Operacional: la validacion es una lectura sin bloqueo; entre validar y despachar el stock puede
-- cambiar. La garantia real la da el descuento atomico de TRG_DETALLE_AI_STOCK (5.4).
CREATE OR REPLACE PROCEDURE SP_VALIDAR_DESPACHO (
    p_Id_Producto IN NUMBER,
    p_Id_Bodega   IN NUMBER,
    p_Cantidad    IN NUMBER
) IS
    e_Stock_Insuficiente EXCEPTION;
    vn_Disponible NUMBER;
BEGIN
    IF p_Cantidad IS NULL OR p_Cantidad <= 0 OR p_Id_Bodega IS NULL THEN
        RAISE_APPLICATION_ERROR(-20041, 'Debe indicar una bodega y una cantidad mayor a cero');
    END IF;

    vn_Disponible := FN_STOCK_DISPONIBLE(p_Id_Producto, p_Id_Bodega);

    IF p_Cantidad > vn_Disponible THEN
        RAISE e_Stock_Insuficiente;
    END IF;

    DBMS_OUTPUT.PUT_LINE('OK: se pueden despachar ' || p_Cantidad || ' unidades del producto '
                         || p_Id_Producto || ' desde la bodega ' || p_Id_Bodega
                         || ' (disponible: ' || vn_Disponible || ')');
EXCEPTION
    WHEN e_Stock_Insuficiente THEN
        DBMS_OUTPUT.PUT_LINE('NO DESPACHABLE: se solicitan ' || p_Cantidad || ' y solo hay '
                             || vn_Disponible || ' del producto ' || p_Id_Producto
                             || ' en la bodega ' || p_Id_Bodega);
        RAISE_APPLICATION_ERROR(-20040, 'Stock insuficiente para despachar ' || p_Cantidad
                                || ' unidades (disponible: ' || vn_Disponible || ')');
END SP_VALIDAR_DESPACHO;
/



------------------------------------------------------------------- 4.3 (2 pts)
-- SP_ANULAR_PEDIDO
-- Procedimiento que anule un pedido, usando RAISE_APPLICATION_ERROR con estos
-- codigos:
--     -20010  el pedido no existe
--     -20011  el pedido ya esta anulado
--     -20012  el pedido tiene mas de 30 dias
-- Explique la diferencia entre RAISE y RAISE_APPLICATION_ERROR, y en que caso el
-- cliente de la base de datos puede distinguirlos.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- RAISE vs RAISE_APPLICATION_ERROR:
--  * RAISE lanza una excepcion que ya existe (predefinida o declarada por el programador) o
--    re-lanza la que se esta manejando. No permite ponerle texto ni numero propio.
--  * RAISE_APPLICATION_ERROR(codigo, mensaje) lanza un error con un numero entre -20000 y -20999 y
--    un mensaje definido por el programador, que viaja intacto hasta el cliente como ORA-200xx.
-- CUANDO EL CLIENTE LOS DISTINGUE: cuando la excepcion sale sin manejar del PL/SQL. Una excepcion
-- de usuario lanzada con RAISE llega como ORA-06510 (excepcion de usuario no manejada) sin importar
-- cual sea: todas se ven iguales y sin mensaje util. Una lanzada con RAISE_APPLICATION_ERROR llega
-- con su propio codigo y texto (ORA-20010, 20011, 20012), de modo que la aplicacion puede decidir
-- por el codigo. Si la excepcion se maneja dentro del mismo PL/SQL, el cliente no ve diferencia.
--
-- DISENO: (1) La fila del pedido se lee con FOR UPDATE para que dos anulaciones simultaneas no
-- pasen ambas la validacion de estado. (2) El orden de validaciones es: existe, ya anulado,
-- antiguedad; asi cada codigo describe una causa unica. (3) La antiguedad usa SYSDATE - fecha > 30
-- (dias, con fraccion). (4) Consecuencias de anular, que el enunciado no menciona pero que son
-- necesarias para no dejar el inventario y el credito inconsistentes: como TRG_DETALLE_AI_STOCK
-- descuenta el stock al insertar cada linea, anular obliga a devolverlo (se reutiliza SP_AJUSTAR_STOCK
-- con una ENTRADA por linea), y si el pedido estaba CONFIRMADO se reduce el saldo del cliente.
-- (5) Todo ocurre en una sola transaccion sin COMMIT: o se anula todo o no se anula nada.
CREATE OR REPLACE PROCEDURE SP_ANULAR_PEDIDO (
    p_Id_Pedido IN NUMBER
) IS
    vv_Estado   PEDIDO.estado%TYPE;
    vd_Fecha    PEDIDO.fecha_pedido%TYPE;
    vn_Cliente  PEDIDO.id_cliente%TYPE;
    vn_Total    PEDIDO.total%TYPE;
    vn_Saldo    NUMBER;
BEGIN
    BEGIN
        SELECT estado, fecha_pedido, id_cliente, total
          INTO vv_Estado, vd_Fecha, vn_Cliente, vn_Total
          FROM PEDIDO
         WHERE id_pedido = p_Id_Pedido
           FOR UPDATE;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20010, 'El pedido ' || p_Id_Pedido || ' no existe');
    END;

    IF vv_Estado = 'ANULADO' THEN
        RAISE_APPLICATION_ERROR(-20011, 'El pedido ' || p_Id_Pedido || ' ya esta anulado');
    END IF;

    IF SYSDATE - vd_Fecha > 30 THEN
        RAISE_APPLICATION_ERROR(-20012, 'El pedido ' || p_Id_Pedido || ' tiene '
            || TRUNC(SYSDATE - vd_Fecha) || ' dias: no se puede anular despues de 30');
    END IF;

    -- Devolver al inventario lo que cada linea desconto
    FOR r_Fila IN (SELECT id_producto, id_bodega, cantidad
                FROM DETALLE_PEDIDO
               WHERE id_pedido = p_Id_Pedido
               ORDER BY linea) LOOP
        SP_AJUSTAR_STOCK(r_Fila.id_producto, r_Fila.id_bodega, 'ENTRADA', r_Fila.cantidad,
                         'Devolucion por anulacion del pedido ' || p_Id_Pedido, vn_Saldo);
    END LOOP;

    -- Un pedido confirmado habia aumentado el saldo del cliente
    IF vv_Estado = 'CONFIRMADO' THEN
        UPDATE CLIENTE
           SET saldo_pendiente = GREATEST(saldo_pendiente - vn_Total, 0)
         WHERE id_cliente = vn_Cliente;
    END IF;

    UPDATE PEDIDO
       SET estado = 'ANULADO'
     WHERE id_pedido = p_Id_Pedido;
END SP_ANULAR_PEDIDO;
/



------------------------------------------------------------------- 4.4 (2 pts)
-- Bloque anonimo que intente insertar un producto con una categoria inexistente
-- y capture el error de integridad referencial asociando ORA-02291 a una
-- excepcion con nombre.
-- Explique que aporta esa asociacion frente a atrapar el error en un manejador
-- generico.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- QUE APORTA PRAGMA EXCEPTION_INIT: ORA-02291 no tiene nombre predefinido en PL/SQL. EXCEPTION_INIT
-- le asigna uno (e_Categoria_Inexistente) para poder escribir WHEN e_Categoria_Inexistente.
-- Frente a WHEN OTHERS:
--  * Precision: WHEN OTHERS atrapa TODO (ORA-00001 por duplicado, ORA-01400 por nulo, ORA-02290 por
--    una CHECK, errores de memoria...). Para reaccionar solo al caso de la categoria habria que
--    preguntar IF SQLCODE = -2291 dentro del generico, y un olvido del IF trataria cualquier error
--    como si fuera ese.
--  * Seguridad: los demas errores siguen propagandose en lugar de quedar ocultos.
--  * Legibilidad: el nombre documenta la intencion; el numero -2291 no.
--  * Reutilizacion: la excepcion nombrada se puede declarar una vez en un paquete y usarse en
--    muchos bloques.
-- Nota: ORA-02291 es "no se encontro la clave padre" (insertar un hijo huerfano). Su opuesto,
-- ORA-02292 ("existen registros hijo"), tiene otro numero y requeriria su propia excepcion.
-- Se usa un id_producto explicito para no consumir la secuencia en la prueba.
DECLARE
    e_Categoria_Inexistente EXCEPTION;
    PRAGMA EXCEPTION_INIT(e_Categoria_Inexistente, -2291);
BEGIN
    INSERT INTO PRODUCTO (id_producto, codigo, nombre, id_categoria,
                          precio_unitario, costo_unitario, stock_minimo, activo)
    VALUES (9001, 'TS-9001', 'Producto con categoria inexistente', 99, 50000, 30000, 5, 'S');

    DBMS_OUTPUT.PUT_LINE('Inesperado: el producto se inserto');
    ROLLBACK;
EXCEPTION
    WHEN e_Categoria_Inexistente THEN
        DBMS_OUTPUT.PUT_LINE('Capturado ORA-02291 (integridad referencial): la categoria 99 no existe');
        DBMS_OUTPUT.PUT_LINE('Mensaje original: ' || SQLERRM);
END;
/



------------------------------------------------------------------- 4.5 (1 pt)
-- SP_REGISTRAR_ERROR
-- Procedimiento que reciba el origen y registre en LOG_ERRORES el SQLCODE y el
-- SQLERRM actuales. El registro debe persistir aunque la transaccion principal
-- termine en ROLLBACK.
-- Explique por que se requiere esa independencia transaccional y describa un
-- escenario en el que esa misma independencia oculte informacion en lugar de
-- preservarla.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- POR QUE AUTONOMOUS_TRANSACTION: LOG_ERRORES forma parte de la misma base de datos, de modo que si
-- el registro del error se hiciera dentro de la transaccion principal, el ROLLBACK que normalmente
-- sigue a un error borraria tambien el registro y el error quedaria sin rastro. Con
-- PRAGMA AUTONOMOUS_TRANSACTION el procedimiento corre en una transaccion independiente: su COMMIT
-- confirma solo el INSERT del log, sin confirmar ni revertir nada de la transaccion principal, y el
-- ROLLBACK principal no lo alcanza. Por eso el procedimiento debe terminar con COMMIT o ROLLBACK
-- propio (si no, Oracle lanza ORA-06519).
--
-- DISENO: SQLCODE y SQLERRM se copian a variables al inicio, antes de ejecutar cualquier sentencia,
-- porque una sentencia SQL posterior podria cambiar su valor. Si no hubiera un manejador activo
-- (SQLCODE = 0), se intenta recuperar el error de DBMS_UTILITY.FORMAT_ERROR_STACK. Si el propio INSERT
-- del log falla, se hace ROLLBACK y se sigue SIN lanzar: un error al registrar un error nunca debe
-- reemplazar al error original.
--
-- ESCENARIO EN QUE LA INDEPENDENCIA OCULTA INFORMACION: (1) El log queda confirmado aunque la
-- operacion se revirtio: alguien que lea LOG_ERRORES ve un "error al facturar el pedido 7" y puede
-- creer que hubo datos a medio escribir, cuando en la tabla PEDIDO no quedo nada; sin una referencia
-- al resultado final de la transaccion, el log y los datos cuentan historias distintas. (2) La
-- transaccion autonoma NO ve los cambios sin confirmar de la principal: si el procedimiento intentara
-- leer la fila problematica para enriquecer el mensaje, no la encontraria. (3) Si la autonoma intenta
-- tocar una fila bloqueada por la principal, la sesion se bloquea a si misma (ORA-00060).
CREATE OR REPLACE PROCEDURE SP_REGISTRAR_ERROR (
    p_Origen  IN VARCHAR2,
    p_Detalle IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    vn_Codigo  NUMBER         := SQLCODE;
    vv_Mensaje VARCHAR2(500)  := SUBSTR(SQLERRM, 1, 500);
    vv_Stack   VARCHAR2(4000);
BEGIN
    IF vn_Codigo = 0 THEN
        vv_Stack := DBMS_UTILITY.FORMAT_ERROR_STACK;
        IF vv_Stack IS NOT NULL THEN
            vn_Codigo  := -TO_NUMBER(REGEXP_SUBSTR(vv_Stack, 'ORA-([0-9]+)', 1, 1, NULL, 1));
            vv_Mensaje := SUBSTR(vv_Stack, 1, 500);
        END IF;
    END IF;

    INSERT INTO LOG_ERRORES (id_log, origen, codigo_error, mensaje, detalle)
    VALUES (SEQ_LOG.NEXTVAL, SUBSTR(p_Origen, 1, 60), vn_Codigo, vv_Mensaje, SUBSTR(p_Detalle, 1, 500));
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;  -- nunca enmascarar el error original
END SP_REGISTRAR_ERROR;
/




--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 5
-- Autor       : Kevin Rojas
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Disparadores: cliente, auditoria de precio, margen, stock, total (compound) e INSTEAD OF.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 5 — DISPARADORES                                     (10 puntos / 90 min)
--==============================================================================
-- Los esqueletos de esta parte no incluyen la clausula de disparo. Definirla
-- hace parte del ejercicio.
--==============================================================================

------------------------------------------------------------------- 5.1 (2 pts)
-- TRG_CLIENTE_BI
-- Al insertar un cliente debe asignar el identificador desde SEQ_CLIENTE si
-- llega nulo, convertir el nombre a mayusculas sin espacios sobrantes y forzar
-- el estado activo a 'S' si no se indica.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) BEFORE INSERT FOR EACH ROW: solo un trigger BEFORE de fila puede MODIFICAR :NEW. En uno AFTER
--    los valores ya se escribieron y asignar a :NEW es un error de compilacion. Ademas, un BEFORE
--    se ejecuta antes de verificar NOT NULL y las demas restricciones, por lo que puede corregir
--    los valores a tiempo (por ejemplo, un id nulo que de otro modo violaria NOT NULL).
-- 2) Identificador: si llega nulo, SEQ_CLIENTE.NEXTVAL. Si llega informado se respeta.
-- 3) Nombre: UPPER(TRIM(...)) y REGEXP_REPLACE para colapsar espacios internos repetidos
--    ("sin espacios sobrantes" incluye los de adentro).
-- 4) Estado: la columna ya tiene DEFAULT 'S', pero el DEFAULT solo aplica si la columna se OMITE;
--    si el INSERT envia NULL explicito, el trigger lo corrige antes del NOT NULL.
-- 5) Operacional: la secuencia no hace rollback, asi que genera huecos pero es segura bajo
--    concurrencia (dos sesiones nunca reciben el mismo numero). OJO: SEQ_CLIENTE arranca en 500 y
--    los clientes cargados llegan hasta 507; sin el PASO 0 el segundo cliente nuevo chocaria con
--    uno existente (ORA-00001 en PK_CLIENTE).
CREATE OR REPLACE TRIGGER TRG_CLIENTE_BI
BEFORE INSERT ON CLIENTE
FOR EACH ROW
BEGIN
    IF :NEW.id_cliente IS NULL THEN
        :NEW.id_cliente := SEQ_CLIENTE.NEXTVAL;
    END IF;

    :NEW.nombre := REGEXP_REPLACE(UPPER(TRIM(:NEW.nombre)), ' {2,}', ' ');

    IF :NEW.activo IS NULL THEN
        :NEW.activo := 'S';
    END IF;
END TRG_CLIENTE_BI;
/



------------------------------------------------------------------- 5.2 (2 pts)
-- TRG_PRODUCTO_AU_PRECIO
-- Debe registrar en AUDITORIA_PRECIO todo cambio de precio, calculando la
-- variacion porcentual, y dispararse unicamente cuando el precio efectivamente
-- cambie, resolviendo esa condicion con la clausula WHEN y no dentro del cuerpo.
-- Explique la diferencia entre ambas formas.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- DIFERENCIA ENTRE WHEN Y UN IF EN EL CUERPO: con la clausula WHEN, Oracle evalua la condicion
-- ANTES de ejecutar el trigger; si es falsa, el cuerpo PL/SQL no se invoca para esa fila. Con un IF
-- dentro del cuerpo, el trigger se dispara y se ejecuta siempre, y recien adentro se descarta. En
-- una actualizacion masiva (por ejemplo 3.3 sobre miles de productos, donde muchos precios no
-- cambian) la diferencia es el costo de invocar el cuerpo del trigger por cada fila no afectada.
-- Ademas la condicion queda visible en la definicion del trigger. WHEN solo puede usarse en
-- triggers de FILA y en ella los correlativos se escriben SIN dos puntos: NEW y OLD.
--
-- TAMBIEN SE USA "UPDATE OF precio_unitario": limita el disparo a sentencias que nombran esa columna
-- en el SET. No reemplaza al WHEN: un UPDATE que escribe el mismo valor si nombra la columna y
-- dispararia el trigger; WHEN descarta ese caso porque compara los VALORES.
--
-- AFTER y no BEFORE: la auditoria solo debe registrar cambios que efectivamente se confirmen. En un
-- trigger AFTER la fila ya paso las restricciones y el trigger de margen (5.3); en un BEFORE se
-- registraria un cambio que luego podria rechazarse (aunque Oracle lo revertiria con la sentencia).
-- La variacion porcentual divide por :OLD.precio_unitario, que nunca es cero (CK_PRODUCTO_PRECIO).
-- Operacional: la auditoria es parte de la misma transaccion; si se hace ROLLBACK desaparece.
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_AU_PRECIO
AFTER UPDATE OF precio_unitario ON PRODUCTO
FOR EACH ROW
WHEN (NEW.precio_unitario <> OLD.precio_unitario)
BEGIN
    INSERT INTO AUDITORIA_PRECIO
           (id_auditoria, id_producto, precio_anterior, precio_nuevo, variacion_pct)
    VALUES (SEQ_AUDITORIA.NEXTVAL, :OLD.id_producto, :OLD.precio_unitario, :NEW.precio_unitario,
            ROUND((:NEW.precio_unitario - :OLD.precio_unitario) / :OLD.precio_unitario * 100, 2));
END TRG_PRODUCTO_AU_PRECIO;
/



------------------------------------------------------------------- 5.3 (2 pts)
-- TRG_PRODUCTO_BIU_MARGEN
-- Debe impedir que se guarde un producto cuyo precio no alcance el margen minimo
-- de su categoria, segun la formula precio >= costo * (1 + margen/100),
-- rechazando la operacion con el error -20020.
-- Considere que debe ocurrir cuando la categoria indicada no existe, y justifique
-- su decision.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- 1) BEFORE INSERT OR UPDATE FOR EACH ROW: la validacion debe ocurrir antes de escribir la fila.
--    Se limita con UPDATE OF precio_unitario, costo_unitario, id_categoria: solo esas columnas
--    pueden cambiar el resultado de la formula; actualizar nombre o stock_minimo (por ejemplo en
--    3.5) no dispara la validacion.
-- 2) Formula: precio >= costo * (1 + margen/100), sobre NUMBER (decimal exacto, sin errores de
--    redondeo binario).
-- 3) DECISION SOBRE CATEGORIA INEXISTENTE: el trigger NO rechaza; deja pasar la fila. La existencia
--    de la categoria ya la garantiza la llave foranea FK_PRODUCTO_CATEGORIA, que responde con
--    ORA-02291, un error preciso. Si el trigger lanzara -20020 ("no alcanza el margen"), el mensaje
--    seria enganoso (no es un problema de margen) y ademas ocultaria el error de integridad, que es
--    el que el ejercicio 4.4 necesita ver, porque los triggers BEFORE se ejecutan antes de comprobar
--    las restricciones. Una regla, un responsable.
-- 4) Limites: el trigger lee CATEGORIA sin bloquear; si alguien sube el margen de una categoria,
--    los productos ya guardados no se revalidan hasta que se modifiquen. Y como lee otra tabla
--    (CATEGORIA) no hay error de tabla mutante.
CREATE OR REPLACE TRIGGER TRG_PRODUCTO_BIU_MARGEN
BEFORE INSERT OR UPDATE OF precio_unitario, costo_unitario, id_categoria ON PRODUCTO
FOR EACH ROW
DECLARE
    vn_Margen  CATEGORIA.margen_minimo%TYPE;
    vn_Minimo  NUMBER;
BEGIN
    BEGIN
        SELECT margen_minimo INTO vn_Margen
          FROM CATEGORIA
         WHERE id_categoria = :NEW.id_categoria;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN;  -- categoria inexistente: la FK se encarga (ORA-02291)
    END;

    vn_Minimo := :NEW.costo_unitario * (1 + vn_Margen / 100);

    IF :NEW.precio_unitario < vn_Minimo THEN
        RAISE_APPLICATION_ERROR(-20020, 'Precio ' || :NEW.precio_unitario
            || ' por debajo del margen minimo de la categoria (' || vn_Margen
            || '%): el precio minimo permitido es ' || vn_Minimo);
    END IF;
END TRG_PRODUCTO_BIU_MARGEN;
/



------------------------------------------------------------------- 5.4 (2 pts)
-- TRG_DETALLE_AI_STOCK
-- Al insertar una linea de pedido debe descontar el stock de la bodega indicada
-- y registrar el movimiento de SALIDA correspondiente. Si no hay stock suficiente
-- debe abortar la operacion con el error -20030.
-- Explique por que el momento de disparo que eligio es el correcto y que dejaria
-- de funcionar con el contrario.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- POR QUE AFTER INSERT FOR EACH ROW: este trigger produce EFECTOS SECUNDARIOS en otras tablas
-- (descuenta EXISTENCIA e inserta en MOVIMIENTO_INVENTARIO) y no necesita modificar la fila nueva.
-- Con AFTER, la linea ya paso su PK, sus FK (pedido, producto, bodega) y sus CHECK, de modo que el
-- inventario solo se mueve por lineas validas.
-- QUE PASARIA CON EL MOMENTO CONTRARIO (BEFORE): el resultado final seria el mismo, porque si algo
-- falla Oracle revierte la sentencia completa; la diferencia es de orden y costo, no de correccion.
-- Con BEFORE el descuento y el bloqueo de EXISTENCIA se harian antes de comprobar las restricciones
-- de la linea, es decir, sobre filas que luego podrian rechazarse. Y al reves: lo que NO se puede
-- hacer en un AFTER es modificar :NEW (por ejemplo calcular el subtotal), que es justamente el uso
-- propio de un BEFORE; aqui el subtotal llega ya calculado, por eso no se necesita.
--
-- DESCUENTO ATOMICO: UPDATE EXISTENCIA SET cantidad = cantidad - n ... AND cantidad >= n. Un solo
-- UPDATE condicionado hace la lectura, la validacion y la escritura de forma indivisible: la fila se
-- bloquea y, si otra sesion la estaba modificando, la condicion se reevalua con el valor
-- confirmado. Sin esa condicion (un SELECT y luego un UPDATE) dos pedidos simultaneos podrian
-- vender la misma unidad. Si no se afecta ninguna fila (SQL%ROWCOUNT = 0) hay stock insuficiente
-- o no existe la combinacion: se aborta con -20030, y como la sentencia INSERT completa se revierte
-- (atomicidad de sentencia) no queda ni la linea ni el descuento.
-- No usa SP_AJUSTAR_STOCK para poder registrar el id_pedido en la bitacora y devolver el error -20030
-- que exige el enunciado.
-- Limite conocido: el enunciado solo pide AFTER INSERT; un UPDATE o DELETE de lineas NO devuelve ni
-- descuenta stock y deja el inventario desajustado. En un sistema real tambien deberian cubrirse.
CREATE OR REPLACE TRIGGER TRG_DETALLE_AI_STOCK
AFTER INSERT ON DETALLE_PEDIDO
FOR EACH ROW
BEGIN
    UPDATE EXISTENCIA
       SET cantidad = cantidad - :NEW.cantidad
     WHERE id_bodega   = :NEW.id_bodega
       AND id_producto = :NEW.id_producto
       AND cantidad   >= :NEW.cantidad;

    IF SQL%ROWCOUNT = 0 THEN
        RAISE_APPLICATION_ERROR(-20030, 'Stock insuficiente: producto ' || :NEW.id_producto
            || ' en bodega ' || :NEW.id_bodega || ' (disponible '
            || FN_STOCK_DISPONIBLE(:NEW.id_producto, :NEW.id_bodega)
            || ', solicitado ' || :NEW.cantidad || ')');
    END IF;

    INSERT INTO MOVIMIENTO_INVENTARIO
           (id_movimiento, id_producto, id_bodega, tipo, cantidad, id_pedido, observacion)
    VALUES (SEQ_MOVIMIENTO.NEXTVAL, :NEW.id_producto, :NEW.id_bodega, 'SALIDA', :NEW.cantidad,
            :NEW.id_pedido, 'Despacho linea ' || :NEW.linea || ' del pedido ' || :NEW.id_pedido);
END TRG_DETALLE_AI_STOCK;
/



------------------------------------------------------------------- 5.5 (1 pt)
-- TRG_DETALLE_TOTAL
-- Debe recalcular el total de la cabecera del pedido despues de cualquier
-- insercion, actualizacion o borrado de sus lineas.
-- Documente el error que obtiene en su primer intento, en que momento aparece,
-- y como lo resuelve la construccion que finalmente utilizo.
-- Este punto no se califica sin esa explicacion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- PRIMER INTENTO Y SU ERROR: un trigger AFTER INSERT OR UPDATE OR DELETE ... FOR EACH ROW que hacia
-- UPDATE PEDIDO SET total = (SELECT SUM(subtotal) FROM DETALLE_PEDIDO WHERE id_pedido = ...).
-- Error obtenido al insertar una linea (en EJECUCION, no al compilar; el trigger se crea sin
-- problemas):
--      ORA-04091: la tabla <ESQUEMA>.DETALLE_PEDIDO esta mutando; es posible que el
--                 activador/la funcion no puedan verlo
--      ORA-06512: en "<ESQUEMA>.TRG_DETALLE_TOTAL", linea n
-- (pegue aqui el texto exacto que obtuvo en su captura.)
--
-- QUE ES LA TABLA MUTANTE: mientras una sentencia DML esta en curso sobre una tabla, esta se
-- encuentra en un estado intermedio (unas filas ya cambiadas, otras no). Si un trigger de FILA
-- disparado por esa sentencia intenta LEER (o modificar) esa misma tabla, veria un resultado que
-- depende del orden en que se procesan las filas. Oracle lo prohibe con ORA-04091 en lugar de
-- devolver datos inconsistentes. La causa es leer la tabla desde un trigger de fila que se dispara
-- mientras se modifica; el sintoma es el error.
--
-- COMO LO EVITA EL COMPOUND TRIGGER: tiene secciones con momentos de disparo distintos y variables
-- compartidas durante UNA sentencia. En AFTER EACH ROW solo se ANOTAN los id_pedido afectados en una
-- coleccion (no se lee la tabla). En AFTER STATEMENT, la sentencia ya termino y la tabla ya no esta
-- mutando: alli si se puede hacer SUM(subtotal) sobre DETALLE_PEDIDO y actualizar PEDIDO una vez
-- por pedido. Ventajas frente a la solucion clasica (variables de paquete + varios triggers): el
-- estado vive y se destruye con la sentencia (no hay que limpiarlo a mano si falla), y todo queda
-- en un unico objeto. Se usa el id de :OLD en DELETE y en UPDATE (por si cambiara id_pedido).
-- Operacional: se recalcula con SUM sobre las lineas actuales, no con deltas, asi que es
-- autocorregible. Un INSERT de muchas lineas del mismo pedido provoca un solo UPDATE de cabecera.
-- Limite: si un pedido ya esta CONFIRMADO con descuento aplicado (PKG_VENTAS), modificar sus lineas
-- reemplazaria el total por la suma bruta; en la practica un pedido confirmado no deberia editarse.
CREATE OR REPLACE TRIGGER TRG_DETALLE_TOTAL
FOR INSERT OR UPDATE OR DELETE ON DETALLE_PEDIDO
COMPOUND TRIGGER

    TYPE t_Ids IS TABLE OF PEDIDO.id_pedido%TYPE INDEX BY PLS_INTEGER;
    v_Ids t_Ids;

    PROCEDURE anotar (p_Id IN NUMBER) IS
    BEGIN
        IF p_Id IS NOT NULL
           AND (v_Ids.COUNT = 0 OR v_Ids(v_Ids.LAST) <> p_Id) THEN
            v_Ids(v_Ids.COUNT + 1) := p_Id;
        END IF;
    END anotar;

    AFTER EACH ROW IS
    BEGIN
        IF INSERTING OR UPDATING THEN
            anotar(:NEW.id_pedido);
        END IF;
        IF DELETING OR UPDATING THEN
            anotar(:OLD.id_pedido);
        END IF;
    END AFTER EACH ROW;

    AFTER STATEMENT IS
    BEGIN
        FOR vn_Indice IN 1 .. v_Ids.COUNT LOOP
            UPDATE PEDIDO p
               SET p.total = (SELECT NVL(SUM(d.subtotal), 0)
                                FROM DETALLE_PEDIDO d
                               WHERE d.id_pedido = p.id_pedido)
             WHERE p.id_pedido = v_Ids(vn_Indice);
        END LOOP;
        v_Ids.DELETE;
    END AFTER STATEMENT;

END TRG_DETALLE_TOTAL;
/



------------------------------------------------------------------- 5.6 (1 pt)
-- TRG_V_STOCK_IO
-- Debe permitir actualizar el precio y el stock minimo del producto a traves de
-- la vista V_STOCK_CONSOLIDADO.
-- Explique por que esa vista no es actualizable de forma directa.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- POR QUE LA VISTA NO ES ACTUALIZABLE DIRECTAMENTE: V_STOCK_CONSOLIDADO contiene GROUP BY, la
-- funcion de agregacion SUM y un LEFT JOIN de tres tablas. Cada fila de la vista resume varias
-- filas de EXISTENCIA; no corresponde a una fila identificable de una unica tabla base. Oracle no
-- puede traducir "cambia este valor de la vista" a "cambia esta fila de esta tabla": por ejemplo,
-- stock_total no existe en ninguna tabla, es un calculo. Por eso responde
-- ORA-01732: operacion de manipulacion de datos no valida en esta vista.
-- (La causa es la agregacion; el ORA-01732 es solo el sintoma.)
--
-- QUE HACE EL TRIGGER INSTEAD OF: intercepta el UPDATE y lo sustituye por uno que el programador
-- define sobre la tabla real (PRODUCTO), solo para las dos columnas pedidas. Es un trigger de fila
-- sobre vista y se dispara EN LUGAR de la operacion, que no se ejecuta. Como actualiza PRODUCTO,
-- tambien se disparan sus triggers (auditoria de precio 5.2 y validacion de margen 5.3), de modo que
-- las reglas de negocio no se pueden esquivar por la vista.
-- Decision: si el UPDATE intenta cambiar una columna derivada o de identificacion (stock_total,
-- codigo, producto, categoria, id_producto) se rechaza con -20050 en lugar de ignorarse en silencio:
-- un cambio descartado sin aviso es peor que un error.
CREATE OR REPLACE TRIGGER TRG_V_STOCK_IO
INSTEAD OF UPDATE ON V_STOCK_CONSOLIDADO
FOR EACH ROW
BEGIN
    IF :NEW.id_producto <> :OLD.id_producto
       OR :NEW.codigo     <> :OLD.codigo
       OR :NEW.producto   <> :OLD.producto
       OR :NEW.categoria  <> :OLD.categoria
       OR :NEW.stock_total <> :OLD.stock_total THEN
        RAISE_APPLICATION_ERROR(-20050, 'Solo se pueden actualizar precio_unitario y stock_minimo '
            || 'a traves de V_STOCK_CONSOLIDADO');
    END IF;

    UPDATE PRODUCTO
       SET precio_unitario = :NEW.precio_unitario,
           stock_minimo    = :NEW.stock_minimo
     WHERE id_producto = :OLD.id_producto;
END TRG_V_STOCK_IO;
/




--------------------------------------------------------------------------------
-- Script      : TALLER_PLSQL_GRUPO_1.sql — Parte 6
-- Autor       : Kevin Rojas
-- Creacion    : 03/10/2026
-- Version     : 1.0
-- Descripcion : Caso integrador: paquete PKG_VENTAS con SP_FACTURAR_PEDIDO.
--------------------------------------------------------------------------------

--==============================================================================
-- PARTE 6 — CASO INTEGRADOR                                   (5 puntos / 45 min)
--==============================================================================

-------------------------------------------------------------------------------
-- PKG_VENTAS
-- Construya un PAQUETE que exponga el procedimiento SP_FACTURAR_PEDIDO, el cual,
-- para un pedido en estado BORRADOR, debe:
--
--   1. Validar que el pedido exista y este en BORRADOR
--   2. Recorrer sus lineas con un cursor y acumular el subtotal
--   3. Calcular el descuento con FN_CALCULAR_DESCUENTO
--   4. Validar contra FN_CUPO_DISPONIBLE que el cliente tenga cupo suficiente
--   5. Actualizar el total del pedido y cambiar su estado a CONFIRMADO
--   6. Incrementar el saldo pendiente del cliente
--   7. Usar SAVEPOINT y revertir parcialmente ante cualquier fallo, registrando
--      el error con SP_REGISTRAR_ERROR
--   8. Devolver por parametros OUT el total facturado y el descuento aplicado
--
-- Firma esperada:
--   PKG_VENTAS.SP_FACTURAR_PEDIDO(p_Id_Pedido IN NUMBER,
--                                 p_Total     OUT NUMBER,
--                                 p_Descuento OUT NUMBER)
--
-- Se evalua la integracion. El procedimiento debe apoyarse en los objetos de las
-- partes 1 a 5 y no reimplementar su logica: uno que vuelva a codificar el
-- calculo del descuento pierde la mitad del puntaje de esta parte.
-- Defina explicitamente el alcance transaccional y justifique donde decidio
-- ubicar la confirmacion de la transaccion.
-------------------------------------------------------------------------------
-- JUSTIFICACION:
-- ALCANCE TRANSACCIONAL: SP_FACTURAR_PEDIDO es una unidad "todo o nada" dentro de la transaccion del
-- llamador. Marca un SAVEPOINT al entrar; ante cualquier fallo registra el error (SP_REGISTRAR_ERROR,
-- que es autonoma y por eso sobrevive) y hace ROLLBACK TO SAVEPOINT, deshaciendo SOLO lo que hizo
-- este procedimiento, sin tocar el trabajo previo del llamador (por ejemplo, el pedido y sus lineas
-- que acaba de crear), y vuelve a lanzar el error para que el llamador lo conozca.
--
-- DONDE ESTA EL COMMIT Y POR QUE: el procedimiento NO confirma. Un COMMIT dentro del paquete
-- confirmaria TODO lo pendiente de la sesion, no solo la facturacion: si el llamador habia hecho
-- otras escrituras que dependian de este resultado, quedarian confirmadas sin querer. Dejar la
-- decision en el llamador permite componer la facturacion con otras operaciones (por ejemplo,
-- facturar varios pedidos y confirmar al final) y probarla con ROLLBACK. La unica confirmacion
-- interna es la del registro de errores, aislada en su propia transaccion autonoma.
--
-- INTEGRACION (no reimplementa logica): descuento -> FN_CALCULAR_DESCUENTO; cupo -> FN_CUPO_DISPONIBLE;
-- error -> SP_REGISTRAR_ERROR. El stock ya fue descontado por TRG_DETALLE_AI_STOCK al insertar cada
-- linea y el total de la cabecera mantenido por TRG_DETALLE_TOTAL; este procedimiento no los repite.
--
-- CONCURRENCIA: bloquea primero el PEDIDO y despues el CLIENTE (siempre en ese orden, para evitar
-- deadlocks entre facturaciones). Bloquear al cliente ANTES de calcular el descuento y el cupo es
-- imprescindible: ambos dependen del saldo, y si dos facturas del mismo cliente corrieran a la vez
-- cada una veria el saldo anterior y podrian sobrepasar el cupo. El bloqueo del pedido evita que se
-- facture dos veces el mismo.
--
-- DECISIONES DE NEGOCIO: el cupo se compara contra el total NETO (subtotal - descuento), que es lo
-- que se carga al saldo. El descuento se calcula ANTES de aumentar el saldo, porque el 2% depende de
-- que el saldo sea cero. Un pedido sin lineas se rechaza. Los parametros OUT quedan en 0 si falla.
-- LIMITE: el total confirmado incluye el descuento; si luego se editaran lineas, TRG_DETALLE_TOTAL
-- recalcularia el total bruto (ver 5.5).
CREATE OR REPLACE PACKAGE PKG_VENTAS IS
    PROCEDURE SP_FACTURAR_PEDIDO (
        p_Id_Pedido IN  NUMBER,
        p_Total     OUT NUMBER,
        p_Descuento OUT NUMBER
    );
END PKG_VENTAS;
/

CREATE OR REPLACE PACKAGE BODY PKG_VENTAS IS

    PROCEDURE SP_FACTURAR_PEDIDO (
        p_Id_Pedido IN  NUMBER,
        p_Total     OUT NUMBER,
        p_Descuento OUT NUMBER
    ) IS
        CURSOR c_Lineas (p_Pedido NUMBER) IS
            SELECT linea, subtotal
              FROM DETALLE_PEDIDO
             WHERE id_pedido = p_Pedido
             ORDER BY linea;

        vn_Id_Cliente  PEDIDO.id_cliente%TYPE;
        vv_Estado      PEDIDO.estado%TYPE;
        vc_Activo      CLIENTE.activo%TYPE;
        vn_Subtotal    NUMBER := 0;
        vn_Lineas      NUMBER := 0;
        vn_Cupo        NUMBER;
    BEGIN
        p_Total     := 0;
        p_Descuento := 0;

        SAVEPOINT sp_facturar;

        -- 1. El pedido debe existir y estar en BORRADOR (se bloquea la cabecera)
        BEGIN
            SELECT id_cliente, estado
              INTO vn_Id_Cliente, vv_Estado
              FROM PEDIDO
             WHERE id_pedido = p_Id_Pedido
               FOR UPDATE;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20301, 'El pedido ' || p_Id_Pedido || ' no existe');
        END;

        IF vv_Estado <> 'BORRADOR' THEN
            RAISE_APPLICATION_ERROR(-20302, 'El pedido ' || p_Id_Pedido
                || ' esta en estado ' || vv_Estado || ': solo se factura un BORRADOR');
        END IF;

        -- Bloqueo del cliente ANTES de leer saldo y cupo
        SELECT activo INTO vc_Activo
          FROM CLIENTE
         WHERE id_cliente = vn_Id_Cliente
           FOR UPDATE;

        IF vc_Activo <> 'S' THEN
            RAISE_APPLICATION_ERROR(-20305, 'El cliente ' || vn_Id_Cliente || ' esta inactivo');
        END IF;

        -- 2. Recorrer las lineas con un cursor y acumular el subtotal
        FOR r_Fila IN c_Lineas(p_Id_Pedido) LOOP
            vn_Subtotal := vn_Subtotal + r_Fila.subtotal;
            vn_Lineas   := vn_Lineas + 1;
        END LOOP;

        IF vn_Lineas = 0 THEN
            RAISE_APPLICATION_ERROR(-20303, 'El pedido ' || p_Id_Pedido || ' no tiene lineas');
        END IF;

        -- 3. Descuento (funcion de la Parte 2; se calcula antes de tocar el saldo)
        p_Descuento := FN_CALCULAR_DESCUENTO(vn_Id_Cliente, vn_Subtotal);
        p_Total     := vn_Subtotal - p_Descuento;

        -- 4. Cupo suficiente para el total a cargar
        vn_Cupo := FN_CUPO_DISPONIBLE(vn_Id_Cliente);
        IF p_Total > vn_Cupo THEN
            RAISE_APPLICATION_ERROR(-20304, 'Cupo insuficiente: el pedido requiere ' || p_Total
                || ' y el cliente solo tiene ' || vn_Cupo || ' disponibles');
        END IF;

        -- 5. Total definitivo y estado
        UPDATE PEDIDO
           SET total  = p_Total,
               estado = 'CONFIRMADO'
         WHERE id_pedido = p_Id_Pedido;

        -- 6. Saldo pendiente del cliente
        UPDATE CLIENTE
           SET saldo_pendiente = saldo_pendiente + p_Total
         WHERE id_cliente = vn_Id_Cliente;

        -- Sin COMMIT: la confirmacion le corresponde al llamador (ver JUSTIFICACION)
    EXCEPTION
        WHEN OTHERS THEN
            -- 7. Registrar (transaccion autonoma) y revertir solo lo hecho aqui
            SP_REGISTRAR_ERROR('PKG_VENTAS.SP_FACTURAR_PEDIDO', 'id_pedido=' || p_Id_Pedido);
            ROLLBACK TO sp_facturar;
            p_Total     := 0;
            p_Descuento := 0;
            RAISE;
    END SP_FACTURAR_PEDIDO;

END PKG_VENTAS;
/




--==============================================================================
-- FIN DE LA PLANTILLA
--==============================================================================

-- Para comprobar los objetos si son VALID o INVALID
SELECT object_type,
       object_name,
       status
FROM user_objects
WHERE object_name IN (
    'SP_REGISTRAR_PRODUCTO',
    'SP_AJUSTAR_STOCK',
    'SP_CREAR_PEDIDO',
    'FN_STOCK_DISPONIBLE',
    'FN_CUPO_DISPONIBLE',
    'FN_CALCULAR_DESCUENTO',
    'SP_LISTAR_MOVIMIENTOS',
    'FN_PRECIO_PRODUCTO',
    'SP_VALIDAR_DESPACHO',
    'SP_ANULAR_PEDIDO',
    'SP_REGISTRAR_ERROR',
    'TRG_CLIENTE_BI',
    'TRG_PRODUCTO_AU_PRECIO',
    'TRG_PRODUCTO_BIU_MARGEN',
    'TRG_DETALLE_AI_STOCK',
    'TRG_DETALLE_TOTAL',
    'TRG_V_STOCK_IO',
    'PKG_VENTAS'
)
ORDER BY object_type, object_name;