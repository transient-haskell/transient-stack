# Transcripción Verbatim de la Conversación

Este documento contiene la transcripción exacta palabra por palabra de nuestra conversación sobre Transient y Cardano.

---

**Usuario:** lee los docs y dime que es

**Antigravity:** Basándome en los documentos y la estructura del proyecto, este repositorio contiene **Transient** y todas sus bibliotecas asociadas (`transient`, `transient-universe`, `transient-universe-tls`, y `axiom`).

En resumen, **Transient es un framework avanzado (y una mónada de efectos extensible) para Haskell diseñado para lograr una "composabilidad sin restricciones".** 

Aquí destaco los puntos principales de qué hace y para qué sirve:

1. **Unificación de Efectos Complejos ("Impuros"):**
   Transient permite manejar problemas típicos del mundo real que usualmente rompen la elegancia de la programación funcional pura. Esto incluye: concurrencia, paralelismo múltiple, manejo de excepciones (incluso con backtracking y continuación asíncrona), entradas/salidas asíncronas (async I/O), eventos, computación distribuida (mover procesos entre nodos) y desarrollo web tanto del lado cliente (navegador) como lado servidor.

2. **Composabilidad Matemática Estándar:**
   Normalmente en Haskell manejar cosas que tienen diferentes efectos obligaría a un complejo anidamiento de transformadores de monadas. Transient permite combinar estas aplicaciones y lógicas complejas mediante simples operadores monádicos y aplicativos:
   - `<$>` `<*>` y `<>` para concurrencia.
   - `<|>` (Alternativa) para paralelismo o *backtracking* ante excepciones.
   - `>>=` para operaciones asíncronas encadenadas o pasos serializados.

3. **Arquitectura y Escalabilidad:**
   El ecosistema se divide en módulos que asumen distintas capas:
   - **`transient`**: El núcleo que gestiona control de hilos, continuaciones asíncronas, eventos y excepciones en memoria/estado.
   - **`transient-universe` y `tls`**: Extensiones para transportar esta lógica sobre la red de forma transparente (creando *clusters* de computación distribuida donde un hilo/cálculo puede viajar de un nodo servidor a otro o a un navegador web usando teletransporte).
   - **`axiom`**: Un framework que expone estas capacidades hacia el navegador, permitiendo interfaces de usuario (formularios, widgets web) entrelazadas en la misma lógica concurrente.

El objetivo general es lograr que puedas programar cosas sumamente difíciles (como aplicaciones de streaming de microservicios con recuperación ante fallos o apps web con cálculos distribuidos) como si estuvieras programando funciones matemáticas puras regulares, todo en una sola línea de lógica elegante en la misma mónada `TransIO`.

---

**Usuario:** veo que tiene async.   para que sirve? esa orde se usa como siempre?

**Antigravity:** En **Transient**, la orden `async` no funciona exactamente "como siempre" en otros lenguajes (como JavaScript o C#) ni como en la librería tradicional `async` de Haskell.

Aquí tienes un resumen basado en la documentación y comentarios internos del código:

### ¿Para qué sirve?
Sirve para tomar una computación de entrada/salida (tipo `IO a`) y ejecutarla de forma asíncrona dentro de la mónada `TransIO`. 
Manda esa computación a un hilo de fondo liberando el hilo actual y, cuando termina, retoma la ejecución del flujo de código llevándose el resultado consigo en un nuevo hilo cooperativo de Transient.

### ¿Se usa como en otros lenguajes (await / async)?
**Definitivamente NO**. En el código fuente hay una advertencia explícita sobre esto:
> *"NOTE: `async` and `await` DOES NOT WORK like in other languages. Every LLM tries to use the pattern of async-await and transient does not work that way."*

En otros lenguajes o librerías, es común hacer esto:
```haskell
-- Esto NO hace lo que crees en Transient
do
   x <- async tarea1
   y <- async tarea2
   resultadoX <- await x 
   resultadoY <- await y
```
Si escribes eso en Transient, **se ejecutará secuencialmente**. `tarea2` no empezará hasta que `tarea1` haya terminado, porque en el flujo monádico (`do` / `>>=`), `async` detiene el avance de esa secuencia hasta obtener el valor.

### ¿Cómo se usa correctamente entonces?
En Transient, `async` es bloqueante en la secuencia monádica, pero **no bloqueante en las operaciones algebraicas**. 

Para conseguir verdadero paralelismo con `async`, debes combinarlos usando los operadores especiales de Transient:

**Para ejecutarlos en paralelo (cada uno en su hilo continuará por su cuenta):**
```haskell
async tarea1 <|> async tarea2
```

**Para recolectar los resultados de ambos procesos paralelos en un solo punto:**
```haskell
await $ async tarea1 <|> async tarea2
-- o también:
collect 0 $ async tarea1 <|> async tarea2
```

En resumen: En lugar de crear promesas y esperar por ellas llanamente, en Transient las operaciones asíncronas se componen directamente usando operadores algebraicos (`<|>`, `<$>`, `<*>`) para establecer flujos concurrentes o paralelos.

---

**Usuario:** react?

**Antigravity:** En Transient, **`react`** es la "pieza mágica" que sirve como puente entre el desorden de las APIs del mundo exterior (basadas en *callbacks* o eventos) y el elegante flujo secuencial de Transient.

### ¿Para qué sirve?
Mientras que la mayoría del código asíncrono en sistemas manejados por eventos resulta en un "Callback Hell" (funciones dentro de funciones dentro de funciones), `react` toma una API que espera un *callback* (como un "onClick" de un botón o un "onMessage" de WebSocket) y la transforma en un valor monádico normal (`TransIO a`).

De este modo tu código se ve secuencial y plano, pero por debajo *Transient* está gestionando que cuando el evento exterior ocurra, esa línea se despierte y emita el valor.

### Su firma y uso
Conceptualmente, la firma es algo así:
`react :: ((a -> IO ()) -> IO ()) -> TransIO () -> TransIO a`
*(El segundo parámetro suele ser una acción de limpieza o simplemente `return ()`).*

### Ejemplo práctico
Imagina que tienes una librería que tiene una función `onButtonClick` a la que le pasas una función (callback) para ejecutar cuando el usuario haga clic.

**En código tradicional (Callback Hell):**
```haskell
onButtonClick $ \coordenadaX -> do
    -- Haz algo con X
    onMouseClick $ \coordenadaY -> do
         -- Haz algo con Y
```

**Con Transient usando `react`:**
```haskell
do
    coordenadaX <- react onButtonClick (return ())
    -- El código avanza mágicamente solo cuando ocurre el click en el botón
    
    coordenadaY <- react onMouseClick (return ())
    -- Ahora avanzamos solo cuando ocurre un click en el ratón
    
    liftIO $ print (coordenadaX, coordenadaY)
```

### ¿Por qué es genial?
Al usar `react`, este evento de click ahora es un bloque de construcción que puede combinarse usando operadores algebraicos al igual que veíamos con `async`.

Por ejemplo, podrías iniciar dos `react` al mismo tiempo y esperar a que ocurra cualquiera de los dos eventos para continuar, sin enredos asíncronos:
```haskell
    resultado <- react onEventX (return()) <|> react onEventY (return())
```

En resumen: **`react` domestica a las APIs asíncronas externas (basadas en *callbacks*)**, atándolas al motor de procesamiento paralelo de Transient.

---

**Usuario:** minput?

**Antigravity:** En el ecosistema de Transient, **`minput`** (abreviatura que suele referirse a *monadic input* o algo similar) es una función relacionada con la interfaz de usuario, específicamente dentro del módulo web/distribuido (`Transient.Move.Web`).

### ¿Para qué sirve?
Sirve para **solicitar datos (input) de manera declarativa** al usuario y pausar la ejecución del flujo (dentro de la mónada `Cloud`) hasta que ese dato sea devuelto.

### ¿Cómo funciona en la práctica?
Normalmente en el desarrollo web tradicional, pedir datos implica crear un formulario HTML en un archivo, programar el endpoint en el backend que reciba el POST, parsear los datos y validarlos.

Con `minput`, todo eso se reduce a una sola línea de código en Haskell:

```haskell
idUsuario <- minput "usuarioId" "Por favor, introduce tu ID de usuario:"
```

Esa línea hace todo el trabajo "mágico" por detrás:
1. Renderiza (o asume) una interfaz web/consola que le muestra el texto "Por favor, introduce tu ID..." al usuario.
2. Crea el campo de entrada llamado `"usuarioId"`.
3. Pausa la ejecución de ese "hilo" monádico.
4. Cuando el usuario envía el formulario (ya sea por GET o POST), Transient recupera el valor enviado, revisa que concuerde con el tipo esperado de Haskell y reanuda la ejecución asignándole ese valor a la variable `idUsuario`.

### Su firma típica
En los ejemplos del código, la firma suele lucir similar a:
```haskell
minput :: (Loggable a, ToHTTPReq a) => String -> String -> Cloud a
```
Esto significa que toma dos `String` (el identificador/nombre y la etiqueta o prompt a mostrar al usuario) y devuelve un valor de tipo `a` dentro de la mónada `Cloud` (que es la mónada distribuida de Transient).

En resumen: **Es la forma de crear puntos de entrada de datos (inputs o formularios) integrados cien por ciento con el flujo lógico asíncrono, automatizando el "request y response" del ciclo web clásico.**

---

**Usuario:** puede enviar y recibir JSION a/del browser?

**Antigravity:** Sí, **absolutamente**. Transient puede enviar y recibir JSON desde y hacia el navegador (o cualquier otro cliente/servidor) sin problemas.

El framework de Transient tiene una integración directa y profunda con **Aeson** (la librería estándar y más rápida de Haskell para JSON). 

De lo que se deduce del diseño del código de Transient:

1. **Uso de Clases de Tipos:** Todo se basa en implementar las clases `ToJSON` y `FromJSON` para tus tipos de datos en Haskell. Incluso la librería tiene soporte incorporado para sus propios tipos internos (Nodos, MVar, ByteStrings, Identificadores de sesión, etc.).
2. **APIs REST y WebSockets:** Tanto las comunicaciones por sockets entre nodos como las llamadas RESTful o WebSockets desde una SPA (Single Page Application) en el navegador envían y reciben el "payload" en formato JSON si así se declara.
3. **Módulo Web Dedicado:** Existe un módulo `Transient.Move.JSON` dentro de `transient-universe` diseñado específicamente para la serialización y deserialización de estructuras hacia constructores/respuestas red.

**Cómo funciona en la práctica:**
No tienes que parsear cadenas de texto manualmente una y otra vez. Si defines una estructura como:

```haskell
data Persona = Persona { nombre :: String, edad :: Int } 
  deriving (Generic, ToJSON, FromJSON)
```

Al utilizar endpoints como `minput` enviando POST, o realizar operaciones de red en la mónada `Cloud`, si el cliente (JavaScript o el navegador usando `JSON.parse` / `JSON.stringify`) manda un objeto JSON coincidente, Transient lo convertirá de forma automática y tipada y tu código Haskell recibirá una variable `Persona` pura y válida.

---

**Usuario:** Tiene alguna otra funcion que no se ve en otras librerias?

**Antigravity:** Sí, Transient está repleto de primitivas únicas. Debido a que basa su arquitectura en continuaciones serializables y control de estado completo de la mónada, hay un conjunto de funciones que casi **nunca vas a ver en librerías estándar** de otros lenguajes.

Aquí te destaco las más peculiares e interesantes:

### 1. `teleport` (y `wormhole`)
Probablemente la más extravagante de todas. Transient permite computación distribuida de forma que el *código mismo* decide dónde se ejecuta a mitad de camino.
*   **¿Para qué sirve?** Si tienes una función que se ejecuta en tu servidor, pero necesitas mostrar una alerta al usuario y recoger su respuesta web, o necesitas procesar unos cálculos paralelos pesados en un clúster de nodos, usas estas primitivas.
*   **¿Qué hace?** Serializa el estado de tu ejecución y tus variables, lo manda por la red, "salta" a ese otro ordenador o navegador web del cliente, continúa ejecutándose allí, y luego puede regresar al servidor trayéndose el resultado de vuelta. Literalmente teletransporta el hilo de ejecución por la red.

### 2. `abduce`
*   **¿Para qué sirve?** Es el núcleo de la eficiencia asíncrona ("abducción" de hilos).
*   **¿Qué hace?** Libera inmediatamente el hilo físico de Haskell (tu procesador) en el que se estaba ejecutando esa línea, permitiendo al sistema hacer otra cosa en paralelo. En la siguiente línea de código, la mónada reaparecerá automáticamente sobre otro hilo libre ("devuelto por los aliens"). A diferencia del `fork`, esto permite que la concurrencia en Transient pueda manejar millones de operaciones paradas sin saturar los hilos del procesador host.

### 3. `sandbox`
*   **¿Para qué sirve?** Máquina del tiempo de variables de estado.
*   **¿Qué hace?** Supón que entras en un cálculo largo que modifica bases de datos locales, el estado global de la sesión del usuario o configuraciones, y al final algo falla o decides cancelar el proceso (backtracking). `sandbox` envolverá eso, de modo que si el cálculo que contiene dentro finaliza de forma fallida (con un `stop` explícito u otra razón), el sistema deshace *todas las modificaciones al estado monádico* devolviendo al programa a la instantánea del milisegundo anterior a ejecutar `sandbox`.

### 4. `logged` y `loggedc`
*   **¿Para qué sirve?** Guardado inquebrantable de estado para no perder nunca la ejecución (Tolerancia a Fallos).
*   **¿Qué hace?** Si envuelves operaciones de I/O importantes o grandes bloques de tu programa con `logged`, el estado y valor devuelto de esa línea se escribirá en disco de forma automatizada. Si hay un apagón total de energía, al reiniciar el proceso compilado, Transient *no* ejecutará todo de cero; saltará como un rayo leyendo los logs y "resucitará" el programa exactamente en la línea posterior a la que tuvo el apagón, con todos los estados de memoria precisos reconstituidos automágicamente.

### 5. ¿`try - catch` invertido? (`onException`, `onUndo`, `continue`, `forward`)
En casi todo lenguaje existe un `try {...} catch (e) {...}`. Transient no funciona así. Usa un sistema de "vuelta atrás monádica".
*   Cuando configuras `onException`, estos manejadores se adjuntan al hilo (incluso si creas nuevos hilos "hijos", los heredan de regalo).
*   Si salta una excepción, en lugar de atraparse "hacia arriba", el proceso retrocede paso a paso ejecutando todas las opciones de apagado / limpieza en sucesión desde el manejo más interno hasta el más externo.
*   Tienes comandos de nivel de excepción puros como **`continue`** que le pueden decir a la mónada en medio de ese desastre: "Detén la propagación del error y reanuda el código como si todo hubiera estado bien", lo cual otorga un nivel altísimo de tolerancia a bloqueos que no existe de manera estándar en nada comparable.

---

**Usuario:** he oido que tiene streaming y reactividad

**Antigravity:** Efectivamente, Transient tiene un enfoque radicalmente distinto (y potente) para el **streaming** y la **reactividad**. A diferencia de otras librerías donde tienes que aprender un conjunto de primitivas o tipos de datos completamente diferentes para manejar "Flujos" (como `Stream`, `Observable`, `Conduit`, `Pipes`, etc.), en Transient **el streaming es un efecto predeterminado siempre disponible**.

### Reactividad (`Push` vs `Pull`)
La mayoría de lenguajes usan un enfoque *Pull* (tiras del flujo iterándolo para pedir el siguiente dato en un bucle `while` o `for`). 
Transient usa una reactividad pura basada en **Push**. No pides el siguiente dato; simplemente declaras tu código asíncrono y **reaccionas** a los datos a medida que el sistema los "empuja" hacia tu hilo, utilizando exactamente los mismos operadores (`<|>`, `<*>`, etc.) que usas para cualquier otra tarea concurrente. 

### ¿Cómo funciona el Streaming entonces?
En transient, una computación —sin importar si es local o remota a través de la red— no está limitada a devolver *un solo* resultado. Puede devolver **cero, uno o múltiples resultados a lo largo del tiempo**. 

Si combinas esto con la computación distribuida, el streaming surge mágicamente:

```haskell
-- Esto se ejecuta en el navegador (local)
onBrowser $ do
   resultado <- atRemote $ repetirYSuspendese "Hola desde Servidor"
   -- Este print (en la consola del navegador) se llamará 
   -- automáticamente cada vez que el servidor escupa un dato por red.
   liftIO $ print resultado 
```

**Puntos clave del streaming en Transient:**
1. **Implícito sobre la red**: Cero configuración de WebSockets. Un simple bloque de código `atRemote` puede generar resultados de manera infinita; Transient mantiene la conexión abierta y transporta cada resultado como si fuera un stream de WebSockets en tiempo real.
2. **Multihilo por defecto**: Si el generador emite datos muy rápido, el sistema gestiona procesarlos de forma paralela asignando hilos según lleguen.
3. **Control desde el receptor (Feedback)**: Como es un sistema *Push*, ¿qué pasa si el servidor inunda al cliente? Simple; el proceso remoto cliente puede usar un mecanismo en el que envía una señal o excepción "hacia arriba" (`killChilds`) para cerrar el grifo del stream del servidor, o pausar silenciosamente su producción.

Básicamente, el "streaming reactivo" en Transient significa: Las funciones *pueden devolver múltiples resultados a lo largo del tiempo*, y tú simplemente escribes tu código asumiendo "cuando llegue un nuevo dato, ejecútame aquí", unificando el código serial asíncrono y las listas infinitas en una sola abstracción.

---

**Usuario:** cual es la ultima version de cardano-api

**Antigravity:** **En el ecosistema Haskell de Cardano, `cardano-api` no tiene una "última versión" universal y aislada como ocurre con librerías tradicionales en Hackage.** 

De hecho, IntersectMBO (y anteriomente IOHK) **no publican `cardano-api` en el repositorio público de Hackage**, ya que sus dependencias del ledger y el consenso son muy complejas.

### ¿Cómo saber qué versión usar entonces?

La versión correcta de `cardano-api` a utilizar depende exclusivamente de la versión del **Nodo de Cardano (`cardano-node`)** con la que quieras que tu aplicación o Smart Contract sea compatible.

Para obtener la última y la correcta, este es el procedimiento estandarizado:

1.  **Copiar la configuración del Nodo:** Debes dirigirte al repositorio de GitHub del nodo ([IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node/releases/latest)), revisar la última *Release* o salto importante (como la serie 9.x.x o 10.x.x).
2.  **Extraer el `cabal.project`:** Copiar las dependencias y la configuración del archivo `cabal.project` de esa versión del nodo. Ese archivo define mágicamente la versión anidada exacta y probada de `cardano-api` y del ledger.
3.  **Usar CHaP:** Para que tu compilador Haskell pueda descargar `cardano-api`, vas a necesitar añadir el **Cardano Haskell Packages (CHaP)** a tu archivo `cabal.project`. La estrofa luce así:

```haskell
repository cardano-haskell-packages
  url: https://chap.intersectmbo.org/
  secure: True
  root-keys:
    3e0cce471cf09815f930210f7827266fd09045445d65923e6d0238a6cd15126f
    443abb7fb497a134c343faf52f0b659bd7999bc06b7f63fa76dc99d631f9bea1
    a86a1f6ce86c449c46666bda44268677abf29b5b2d2eb5ec7af903ec2f117a82
    bcec67e8e99cabfa7764d75ad9b158d72bfacf70ca1d0ec8bc6b4406d1bf8413
    c00aae8461a256275598500ea0e187588c35a5d5d7454fb57eac18d9edb86a56
    d4a35cd3121aa00d18544bb0ac01c3e1691d618f462c46129271bccf39f7e8ee
```

**Resumen:** No busques instalar `cabal install cardano-api` de manera aislada. Busca la versión del nodo que necesites, y deja que el `index-state` de CHaP de esa release resuelva tu versión de la API de manera automática y segura.
