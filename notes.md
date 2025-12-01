currently testing transient-universe

extensiones vscode: ANSI colors, Log analysis

cd transient-universe/tests

To compile every change and create the test programs in debug mode

cabal install -f debug test-transient1 --overwrite-policy=always

TO run the monitor in debug mode
runghc -w -threaded -rtsopts  -i../src -i../../transient/src ../app/server/Transient/Move/Services/MonitorService.hs -p start/localhost/3000

To run te test suite in debug mode:
runghc -DDEBUG -w  -threaded -rtsopts  -i../src -i../../transient/src TestSuite.hs

See the logs
[text](transient-universe/tests/log/test-transient1--p-start-localhost-3002.log)


TO USE RUNGHC/GHCI when libraries are not found

repeat:
>cabal install --lib  --package-env . <library>

for each library that does not find

https://discourse.haskell.org/t/could-not-find-module-in-ghci/4385/9

packages to install:

sudo apt-get install zlib1g-dev
cabal install  --lib  --package-env . random directory bytestring containers mtl stm bytestring aeson case-insensitive network websockets network-uri old-time base64-bytestring TCache data-default  network-uri network-bsd     text mime-types process vector TCache hashable signal deepseq data-default HTTP time hashtables

for transient-universe-tls:   tls 


to run examples:
 runghc   -DDEBUG    -w -threaded -rtsopts  -i../src -i../../transient/src flow.hs -p g 2>&1 | tee 8000.ansi 

to compile a example
 ghc   -DDEBUG    -w -threaded -rtsopts  -i../src -i../../transient/src flow.hs 2>&1 | tee 8000.ansi 

to run it

./flow -p g 2>&1 | tee 8000.ansi 

use the extension ANSI colors 


como redefinir <|> para que no sea tan ambiguo.

1       2
        comp
4       3
  
1 y 3 con endpoint, 2 y 3 no

1 y 3 que envien lastWriteEVar, pero sus endpoint estan asegurados
por la closure que ha salvado en el endpoint
    pero esto enlentece, e incluso impide funcionar aplicativos
        aunque a 1 el recuperar le supondria...
            option .... <> runAt....
                no moriria 1 por el option

lo que importa es que processMessage escriba un lastWriteEVar
    pero LastWriteEvar SMore o lastW... SLast?


como hacer un parser que no deje un thread colgado.
esperar por mensajes en lugar de por string completa.

mread -> que llame directamente a readMore sin reactividad.
 pero mread está en listenNew y listenResponses
 que el evar de listenResponses no cuelgue del wormhole

-- set path

usar transient-typelevel para una monad que incluya automaticamente local, onAll o id a cada término.

pero loggedc?

Ver que async ejecuta su argumento en un nuevo thread : si

test de TCache que salva un estado coherente: si

runAt service  que es una compilacion concreta del programa, con macros

cojer los services de las closures?

    
Idea: definir TransIO a = Statet EventF (StreamData a)  (newmnoad.hs)

Idea: closures con nombres aleatorios, timeout en la closure -- genera una closure por cada registro
       necesita proceso de borrado
                recorrer el defPath y ver el campo timeout?
                indexar los LocalClosures?
                proceso de borrado o proceso regresivo en el nodo llamante para llamar la closure anterior
                   si closure no encontrada en remoto -> cloudException -> set clos = prevclos, retry
                        aunque ese timeout se sabe en el nodo llamante porque sabe su timeout

- incluir loggedc en la instancia de aplicativo de cloud en vez de ponerlo explicitamente

incluir loggedc en una version de collect para alternativo : en liftCloud

como evitar chekpoint explicito:
  runAt tiene su checkpoint dentro de un sandbox
  si lo sacamos del sandbox que pasaba? 
      que pasaba algo con el recover? que no podia recuperar la conexion porque el checkpoint estaba fuera
        

class Collectable m where
   collect :: Cloud a -> Cloud [a] 
   collect x = loggedc x

como detectar el final de un stream remoto?
     detectar los threads remotos? como con collect?
     dentro del comp de wormhole?
            o teleport?
   
   checkpoint que detect el final y se elimime

IDEA: distributed request con POST y GET usando http de Web.hs
      setMode HTTP
      usa HTTP requests
      con la estructura de web
      el modo CLOS usara el binario actual.

IDEA: checkpoint que genere ids aleatorios y los transporte logeados como copyState

uso de POSTData x <- local .... para iniciar modo post

Pero POSTData está hardwired a serializado con JSON
  que hacer para permitir otras codificaciones?
    meterlo en class  Loggable
    definir JSONData en vez de POSTData
            LOGData  para Loggable y cambia a modo POST
      o POSTData x :: JSON <- local

modo CLOS y modo HTTP separados? 
  flag modo= CLOS | HTTP
  o bien añadir modo CLOS 
  data HTTPMethod = CLOS | GET | POST deriving (Read, Show, Typeable, Eq,Generic)

class Loggable where
   metodos actuales +
....
  content-type
  POST o GET
  CurlPrototype:: String
  explanation
como se almacenan los logs?: es un monoid 
logged lo consume elemento a elemento

renombrar getclosurelog -> runcompState
meter timeouts para conexiones y closures (ahora recuperacion es automatica)
estructurar test
mirar ps


problemas:
    checkpoint da parse error
    como meter checkpoints de modo implicito
        meter en applicative?
    reentrant no funciona

meter checkpoint en aplicativos Cloud, para reducir logs
enviar log de checkpoint en wormhole eso optimzaria aplicativos remotos dirigidos al mismo nodo

para permitir que variables mutables no serializables conserven valor despues de ruAtl:
   meter checkpoints dentro de teleport, quitar de runAt
   resetear el checkpoint al final de wormhole solo si está dentro de un aplicativo
   meter applicative como un flag dentro del log. meter hasteleport tambien para evitar que se resetee el log

react un mismo thread con varios react. Se necesitan varios registros con el mismo thread en el arbol de procesos.
 añadir identificativo distinto de thread, un id consecutivo. crear un equivalente a abduce, pero con el mismo thread
 free
 opciones algo similar a delconsoleAction a nivel de react
   necesita un id (aleatorio), pero no es automatico, hay que llamarlo explicitamente
     con un onFinish? 
          react= do
              onFinish remove from the list
              react'
     pero eso solo permitiria un evento, y si react' se pone como listener, onFinish nunca se llamaria
   por tanto como es fijo, necesita ser llamado explicitamente
 en react no puede haber ese mecanismo general ya que tanto el callback como deleteCallback estan definidos para ser externos a transient
    si, es necesario para que option y collect funcionen juntos
    aparte de delconsoleaction, react tiene que tener un identificador aleatorio y cuando se borre el react pueda
    mirar los hijos que tiene su thread y si no tiene ninguno, hacer free del thread.
      cuando se activa un react, se debe poner en state el identificador del react, para poder hacer delReact
      
      delReact= do
         React cont <- getState
      que debe mirar ?  tiene que tener una lista de conts y si esta vacia liberar  
      pero react no maneja directamente una lista de conts
        a no ser que se añada a cada registro de thread una lista de react conts
         y cada cont debe tener un ident 
         para liberar un thread habria que ver que no tiene hijos y no tiene listeners. Listener como  estado eliminar

         para liberar un react, primitiva removeListener:  guardar en un estado el stableName del cont que hay en el callback
           pero ese cont puede tener varios react
          
        react onCallback= do
         crear un id aleatorio
         id
         cont <- get
         atomicModifyIORef listeners cont $ \ls -> id:ls
         resto de react

         r <- react...
         setState $ Listener id
         return r

        delListener delCallback= do
          Listener id callback <- getState
          search id in conts up
          remove id en lista de listeners
          delcallback id callback
          si vacio, quitar el atributo Listener
          liberar si no tiene th hijos

        react necesita un mecanismo para desactivar su listener
        delListener descolgaria todos los react del mismo thread por lo que collect podría funcionar
          pero si no se desactivan los callbacks en el framework externo, seguirán ejecutandose, aunque no se verán sus threads

        en EVars, delLitener descolgaria todos los EVars del mismo thread. aunque si cada evar tuviera su thread, solo lo haria con el suyo propio
        como hace ahora

el labelState es aplicado al estado             

 ese id aleatorio no existe en EVars pero se puede añadir: EVar name ref
 pero de lo que se trata es de identificar la continuacion dentro de la EVar no la EVar
    data EVar [(id,contcallback),(id,contcallback)]
    como se elimina una readEVar concreta, no una EVar completa?
      necesitamos saber el id de la readEVar
      r <- readEvar ev; delReadEVar; return r
      poniendolo en el state?
        como se eliminan 2 readEVar? con un stack de readEvar names? no usando el mecanismo de react
    
cuando no haya threads en el modo remoto, lanzar un SDone al nodo llamante para que libere los EVars (listeners)

Grand unification

                     unification                    result
CPU codigo maquina

Memory access        microprocessor, Interrupts    batch processing,direct exec of formulas
                     High level laguages(FORTRAN)   (pure numeric algebra)

Disk I/0             DMA, OS with syncronous IO     interactive console apps, algebraic composition with I/0
                     blocking (Linux)               blocking, single threading
                     Disk I/O             OOP (message-based)            spaguetty, no albebraic composition
                     mouse                epoll, message loop
                     communications

                      ------------------------- The OOP Composition Ice Age -----------------------
                                         
                     Multiple I/O
Disk                 OOP (message-based)            spaguetty, no albebraic composition
mouse                epoll, message loop
communications

                     -------------------------- The small global warming --------------------------

Threading            semaphores                     imperative with blocking, no algebraic composition
parallelism          critical sections etc          sync/async: separate modes
concurrency          async/wait

                     -------------------------- Back to the ice age ---------------------------
Web                  Web server, routes, contexts
                     Message loop                   manual state management, no composition

                     -------------------------- The paradise lost  ----------------------------
                     continuations                  Could solve the composition problems but
                                                    abandoned. Largue exec states, OOP dominance
                                                    disconnection of academy from real world programming
                                                    needs, 
                                                    Lack of global vision (get things done). 
                                                    Search for sucedaneous:
                                                    modularity/ encapsulation/ separation of concern.
                                                    Partial solutions: async/await.
                                                    False dichotomies: block programming versus microservices

                     message loop
distributed          actor model
computing            agent programming              no advancement in composition. artisanal programming
                     (OOP with other names)         

client-side          message passing
programming          web services, JSON             no imperative composition, explicit state management
                     (pragmatic distributed
                     computing/OOP)
                     callbacks

Multiuser
workflows            same solutions
(Blockchain
contracts)
                     
         --------------- Grand unification -----------------------------------

                     -new threads could execute 
                     continuations
                     - "async x" is a thread that
                     executed the same continuation
                     with a different result x
                     -parallelism are alternatives
                     with different threads
                     steaming is composition of
                     parallel applicatives
                     -implicit concurrency
                     programmed within applicatives
                     -concurrency are applicatives
                     of different threads
                     -formulas/binary operators
                     could be constructed with
                     applicatives
                     -execution states could be
                     transported as logs and          Transient: Everything should compose with anything
                     restored
                     -callbacks are continuations
                     -streaming is multithreaded
                     nondeterminism
                     - requests/responses
                     send/receive stack states
                     to build the exec stacks of
                     communicating machines upon
                     previous states
                     -web routes are stacks
                     execution logs are seria-
                     lizations of stack
                     - intermediate results can
                     be removed from logs when
                     not in scope
                     -Get Web requests are logs
                     
                     
                     -messages/web/distributed 
                     requests could transport
                     stacks as logs
                     -messages could address previous
                     restored stacks to construct
                     the distributed computing state
                     among different machines
                     
                      -stacks serializes as logs 
                     -deserializes to restore any
                     execution state upon previous
                     states
                     
                    

calentar aceite  sarten 
echar huevo sarten
freir durante 2 minutos. 
echar al plato


echar huevos sarten= do
 cojer huevos de la nevera 
 echar en sarten

cojerhuevosnevera= do
 abrir nevera
 si no huevos `onException` $ \ noHuevos -> conseguir huevos; continue


telepor1; ...; teleport2        teleport1'; proc; teleport2'

como liberar?
  cuando proc no tiene mas que enviar (onWaitThreads?) mandar un SDone

  tambien en el que llama además del llamado?
  el que llama, llamaría a al anterior llamante


problema en onFinish cuando hay solo un thread en un loop. como detectar un loop thread
   se necesitaria crear un registro nuevo con el mismo thread para que funcione onFinish con threads en loops
     en su lugar se puede añadir un flag loop en el registro del thread?
       pero como se quita? al final del thread en lugar en freelogic se quita el flag
          nuevo estado Loop
          Estado Finish también para evitar el crear un thread en onFinish?

          un onFinish necesita un registro sin threads, sin Listeners y sin Loop para detectar que eso sigue asi al finalizar el trhread
              solo en ese momento se ejecuta el onFinish
            puede usarse contadores en lugar de crear un registro nuevo?
            pero como estado ListenerLoop Int Int

como quitar el listener de la continuacion de un option/input cuando se mete otro con el mismo id

      añadir el campo cont a addEvenListener
      un lista global de todas las cont para todos los react. 
        pero necesitan un id.
      necesitarian no un callback

reactId
  :: Ord ident 
  => ident 
  -> (eventdata ->  IO response) -> IO ())
  -> IO  response
  -> TransIO eventdata
reactId id callback ret= noTrans $ do
  cont <- get
  atomicModifyIORef allcbscbs $ \cbs -> (hash ident, cont,callback (no necesario= \x -> runCont' cont x), custom)
  react callback ret

removeListener id= do
   cont <- filter same id
   atomicModifyIORef  labelth cont $ \(stat,lab) -> ((delistener stat,lab)())

como eliminar un readEVar? filtrando por la cont

suple al actual mbs
puede usarse para EVars y deleteReadEVar usando delListener >>= \cont -> eliminar cont del EVar ref
      necesitaria el cont en la lista del EVar, no un id
      se podrian poner en la lista de cada EVar solo los ids y buscar en mbs las continuaciones y los callbacks
       para delReadEvar, retorna cont, buscar por cont en mbs y borrar ese registro
          necesitaria tener 
       el callback incluye no solo runCont' x cont, sino la preparacion Listener y el cleanup final
puede usarse para dar de baja callbacks por id

hay que llamar todos los callbacks de consola, de EVar en la estructura, se necesita un campo tipo

delReadEvar deberia eliminar el ultimo evar ejecutado, no el ultimo añadido
el viejo detecta la cont que le corresponde por dellistener que lo busca
el actual debe saber el id que ha provocado el readEvar
   como lo puede notificar el writeEvar

debe un killChildren llamar a finalizadores o solo a freelogic?
   si porque puede haber recursos que liberar, aunque tambien puede llamar a collect

killChildren el th que hace el cleanup puede no necesitar llamar finish porque sabe que finish
no va a dispararse? 

dos onFinish seguidos. Como se liberan los hang si solo se permite un nivel de
hang
  hang

clean puede eliminar el thread collect antes de que otros threads acaben
  un theread 
     bloquea
     limpia
     hace finish
       si es el ultimo thread activo del collect,termina
  otro thread proc 92 hace abduce bloquea y limpia todo

algo distinto de hang para onfinish? un nuevo lifecycle?
    onFinish 
    async <|> return

    no funcionaria sin nuevo registro

necesita su propio registro, por tanto necesita hang o un abduce

poniendo un abduce para onFinish, el thread que se va puede acabar antes de que se creen los hijos y
activar collect 0 . cualquier abduce dentro de collect puede provocarlo
   abduce (parallel, que no acabe hasta que no se haya colgado el thread hijo)

   el readMVar para que el hijo se cuelgue, ponerlo antes de finish

hacer el freelogic despues del Finish.
  asi evita necesidad de bloqueo global en finalizations
  cambios:
    en collect, 
       en lugar de null mirar que el cont tenga un solo hijo que es threaId st , el  thread del registro en ejecucion
       findAlive parent es opcional pero recomendado, si no, se acumularian deadparents en cascada
          actualmente opera cuando los registros parent han sido detacheados por freelogic
          quiza hacer freelogic antes de findAliveparent ahi o que freelogic devuelva el liveparent
             antes de llamar a freelogic, si el padre esta activo, dejar al hijo colgando y no hacer hang
             un freelogic posterior, el del cleanup no tendria efecto, 
                 pero testear en freelogic que el registro no tiene hijos posteriormente a la ejecucion de finish/collect
                    ya que ese thread ejecuta toda la contunuacion hacia adelante.
          freelogic 
             antes de llamar a freelogic, comprobar que el padre
             no deberia poner label dead, ya que puede continuar con collect
               dead lo pondria cleanup
             deberia devolver el th del padre no dead

manejo de onFinish con excepciones.
 que todo se ejecute bajo el exception handler


cuando es un for y tiene un onFinish en un elemento
del bucle, como detecta el final de un elemento?

hay que detectar el Finish de bucle y ejecutar los onFinish
de el.
antes del bucle, cojer la pila de finish
despues del bucle, ejecutar los finish añadidos despues.

si isSelf (el thread de onFinish es el mismo que ha acabado)
el finish se elecuta si es posterior





Hash para log:

data Value = A | B | C deriving (Eq, Show)

listHash :: [Value] -> Int
listHash values = foldl (\acc v -> acc * 3 + valueToInt v) 0 values
  where
    valueToInt A = 0
    valueToInt B = 1
    valueToInt C = 2

main :: IO ()
main = do
  let list1 = [A, B, C]
  let list2 = [C, B, A]
  let list3 = [A, A, A]

  print $ listHash list1 -- Output: 5
  print $ listHash list2 -- Output: 18
  print $ listHash list3 -- Output: 0


  crypto con blockchain donde algunos bloques puedan desaparecer:

  cada hash de bloque se consigue con el hash del anterior + el hash del bloque actual
  de esta manera:
  si falta un bloque y fraudulentamente se fabrica ese bloque, se podrá saber si es falso
  el bloque o bloques que fantan deben ser tiempo anteriores a la cadena de bloques establecida
    eso permite que se puedan perder algunos bloques antiguos pero no nuevos.
    
    el blockchain debe buscar verificar y replicar bloques en los telefonos para que no se pierda ninguno
    pero algunos pueden estar offline.
    dos tipos de participacion: pasiva sirve bloques solo ejecuta el servidor, con un protocolo que puede ser google drive
    o otra cloud. activa: con el soft completo.
    merkle tree
    cada app tiene que almacenar al menos los bloques en los que está mencionado


    como hacer que no haya un thread colgado por el parsecontext
    Parsecontext cont done

    el cont es llamado por un... pero eso impide que stateIO pueda hacer de parser



problemas en wormhole teleport

1   2
3   4

solo usan evar 1 y 4.
  1 puede recibir de 4 y 4 de una peticion siguiente.
      pero 4 puede ser efimero
        porque 4 se puede reactivar si no está a partir del log
      y 1 tambien, pero tienen que "engancharse"

hay que poner un evar para 1 y 4

cada teleport necesita un onFinish al final

teleportx
onFinish enviar un last al nodo del wormhole

2 lanza un Slast al enviante el 1

si hay vuelta, 4 lanza un SLast al enviante el 3

closTorespond? o remoteclosdbref?

pero ese SLast recibido por ejemplo por 3
   el EVar tiene que desregistrarse y lanzar un Finish
   puede ser obedecido o no segun el nodo remoto 
   tenga threads
       wormhole
         teleport 2(pasivo, su onFinish lanzara a 1
         proceso (activo o pasivo)
         teleport 3(activo, su evar, que recibe del 4, lanza el Finish)

pero eso implica lanzar un Last por cada mensaje
recibido si el thread finaliza

como quitar el evar que escucha en el teleport 4

el finish despues de 4 manda un SLast al teleport 3
el teleport3 cierra y hace un finish que llega al teleport2
que manda al 1
pero queda el 3 todavia esperando
que el teleport3 mande al 4 un slast 
   no puede mandar porque puede haber mas envios
   eso lo sabe solo el teleport2
  
el teleport 1 su evar recibe
  loz demás solo son llamados 

el 3 puede ser llamado posteriormente y el cuatro de vuelta mas abajo?
el 1 se llama desde el remoto
el 2 no es seguro reaprovecharlo en runAt repetidos porque
el log anterior al teleport puede ser distinto en cada llamada

en resumen en receive1
  onFinish removeEVar ev
  readEVar ev 
en resumen, usar contVars?
  no porque collect saltaria al primer resultado
  solo el primer teleport tiene que mantenerse por collect
  alternativamente, crear un listener "remote" por parte de wormhole
    que se quita cuando su primer teleport recibe un SLast
    pero si el worm tiene varios teleport
    un teleport en remoto sabe que es remoto por recover
    el teleport local lo recibe y dispara un finish
    pero a la hora de recibir, donde se cuelga la contVar
  no vale eso porque un wormhole puede tener varios teleport
    y sobre todo, un collect despues de un wormhole no podria funcionar
  luego el listener tiene que estar en el teleport llamante
    el recipiente el teleport 3 puede evitarlo?  NO
      wormhole
        teleport
        collect   -- este collect en el remoto llama al llamante
            teleport   
  si es llamante, evar
    si es receptor (recover) podria ser CVar
  
  el llamante se desactiva por un SLast

usar la logica de contVar para react? id de react nulo y siempre el mismo problematico
        se pierde su info internallcallbackData

1     2
4     3

3 manda a 1 y en recover, 1 y 3 hacen notifyfinishtoremote al 3
que mande el 1 al 3 y no envie el 4 al 3

4 que haga cleanEvar en finish, pero no envie
   como se evita que envie?
     4 cuando hace el onFinish esta en modo normal
         if not recover then not send
         if recover send

no vale todo eso porque el primer SLast que envia el nodo llamante desmonta todo el tinglado
   nay que esperar hasta que el nodo llamado reporte el fin
   para ello el 3 no tiene que mantener un listener.
   cuando el 2 detecte el final, manda un slast al 1, 
      que borra su listener.
   el 4 no tiene que mantener su listener, ni el 2
   solo el 1 con listener

   el nodo llamado no puede tener un collect al que siga un teleport de respuesta
      teleport
      yaddayadda
      collect  <- no tiene sentido si el teleport siguiente es de respuesta
        teleport
  como detectar que un teleport es el primero?
     no tiene clostoRespond
     
  if no clostorespond, EVar, else Nothing?
   pero Nothing no puede ser porque ese endpoint puede ser llamado posteriormente
   si viene de un recover poner EVar?
   pero si estaba en memoria? necesita una evar.

   poner evar siempre pero quitarla despues de endpoint(1) y su cont excepto si no tiene clostorespond
   eso liberará la closure y su arbol
   si llega un request la recompondrá a partir de su log
        pero una cosa es que no este el thread y otra que este el registro STM
     si esta en memoria el reigistro STM con nothing en evar y se hace un evar...
     si llega una request del nodo llamante al endpoint remoto es porque el collect ya se ha ejecutado.
        la evar se cerrara (1) y etc.

  en processmessage el 3 3 y 4 encontrará:
     localClosure (ev=nothing, localcont just o nothing)
       se supone que restoreclosure pondrá el ev
    pero ahora hay una nueva condicion:
       ev=Nothing, cont= Just
      para ello además, despues de endpoint ademas de borrar evar, hay que sobreescribir el localClosure con ev=Nothing
  
  hay alguna forma de evitar el evar?. quitar el flag listener de manera que cleanup lo elimine cuando no hay threads por debajo?

  de momento en setCont: 
  setCont
    si clostorespond then crear evar
     else dejarlo en Nothing
     receive si hay lc ejecutarlo si no, salir
    si no  clostorespond evar
      
1 2
4 3

2 es el quwe tiene que enviar el SLast. como distinguir 2?
   1 opera en directo
   2 opera en recovery
   3 en directo
   4 en recovery
4 debe enviar finish? no en principio
como distinguir 2 de 4 flag calling?

varios teleport en composicion puede enviar un SLast cada uno

teleport <> teleport=  onfinish send <> onFinish send
abduce

cuando se llama a 2 o 3 o 4 no hay un evar
  pero pueden recibir streaming
 una cosa es que la computacion "pase por el"
   otra cosa es que se invoque
   si no tiene evar, invocar el cont directamente
...

como hacer set-getLasClosureForConnection refleje la ultima clos 
  en definitiva que el siguiente envio a una misma closure refiera ya ese closure y no su historia para crearla
en msend set la closure a la que se va a enviar
  pero eso no va "rio arriba"
  almacenar para cada teleport un tercer dato booleano: si esa closure se ha creado ya por un envio previo
  con new newRState Created False pero tiene que ser creado antes del for/choose waitEvents..
    y eso es el setLastClosureForConnection
     por ejemplo se crea en la c
  tiene que ser una estructura permanente que tenge
     conexion/node   closure que se quiere enviar   ultima closure padre de ella o ella misma

data remoteClosures=  H.fromList [] 



getLastClosureForClosure cl = do
     mcl <- Data.HashTable.IO.lookup remoteClosures cl
     case mcl of
       Nothing -> 0
       Just cl' -> if cl' > cl then cl else cl'

getLastClosureforconnection deberia ser persistente.
y NodeToRespond tambien ya que las conexiones son transient pero runAt es persisntente

connectio <-> node

la cadena de localclosures puede tener un flag enviado o no
  la cadena asegura que si una closure quiere mandar a otro nodo, solo tiene que ir para atras y localizar ese flag a 1.
    pero s el program se he recuperado de 0, tiene que saber a que nodo se refiere.
    por tanto cada closure debe tener una lista de nodos? no porque siempre es un solo nodo.
      cada closure tiene un nodo asociado para enviar de vuelta (clostorespond)
        o solo la closure que tiene asignado una vuelta, los demás no.
          pero como no todos las closures han pasado por todos los nodos(verificar)
             hay que asignar el nodo para cada closure
             y si se quiere que todos los logs sean iguales, los dos nodos implicados (quien llamo a quien)
             ademas el nodo pendiente de respuesta tiene que tener un flag
  para closTorespond:
    lo mas trivial seria un registro DBRef
         pero puede haber varios  anidados    
    un flag  
       clos1 nodo0
         clos2 nodo1
           clos21 nodo2
           clos22 nodo2
         clos3 nodo1
       clos4 nodo0

al final data lastClosureForConnection = M.Map Int (DBRef Closure) : setIndexData int dbref

problema: como setIndexData es en definitiva un setData $ map ind closue
  collect no lo respeta si hay un collect sobre una comp. distribuida, lo ignora
  si caen los nodos, se pierde ese dato
  solucion para lo primero:
     tiene que ser un setRState en wormhole
        leer todo el map
        newRState del map

para que sea permanente,  lastclosureforconnection no puede tener como index la conexion porque eso no es recuperable de log
tiene que ser  map node lastclosure. Se puede desagregar? 

solo logear node, clos cada vez. el map construirlo solo en memoria

(node,clos) <- persist (node,clos) -- desagrega el problema de procesamiento en memoria y el procesamento en frio
persist = local . return
IORef (Map node (IORef Closure))

y si se almacena junto con el registro de la closure los nodos que la tienen?
y si se manda la closure y si el nodo remoto no la tiene, lo diga? y retroceda hasta que hay una que si la tenga?
y si manda la lista de numeros de closures y el remote contesta con la mas reciente?
   pero eso no se puede hacer para cada llamada. al final hay que almacenar ultimas closures para cada nodo

creacion del index en wormhole

update del closure en teleport

consulta en ....

almacenar en el log closures que van a apareciendo
updateLastClosureForConnection node clos= do
    ref <- getIndexRData node
    liftIO $ writeIORef ref clos

-- consulta
getLastClosureForConnection= do
   rclos <- getIndexRData
   liftIO $ readIORef rclos

-- update
setLastClosureForConnectionnode clos= do
   

setIndexRData node val= do
    ref <- getData `onNothing` return (newIORef M.empty)
    map <- liftIO $ readIORef ref
    writeIORef ref M.insert node val

getIndexRData node= do
   mref <- getData
   case mref of
     Nothing -> do
      ref <- liftIO $ newIORef M.singleton node DBClos0
      setData ref
      return DBClos0
     Just ref ->do
       map <- readIORef ref
       return $ lookup node map

newIndexRData= do
    mref <- getData
    case mref of
       Nothing -> liftIO $ newIORef M.empty
       Jst ref -> do
         map <- readIORef ref
         ref' <- newIORef map
         setData $ ref'


setCloudState :: Loggable b => b -> Cloud ()
setCloudState x = do
  r <- local $ return x
  onAll $ setData r

setCloudState cuando se invoca por primera vez y en sucesivas invocaciones mas adelante 
   el estado permanece porque la continuacion mantiene su estado mientras esta en memoria
   pero cuando esa continuacion hay que crearla de nuevo porque se ha ido de memoria,
      ese estado ya no está disponible cuando se sale de scope
        a no se que la semantica de hasTeleport garantize que setCloudState se va a ejecutar
        no, porque  runAt node $ loggeedc $ setCloudState.. no lo garantiza
        a no ser que setCloudState setee hasTeleport
  
  
    que cada clos tenga el nodo que la creó.
     cuando la computaciojn se despierta en cada uno de los clos y tiene un telepor sabe a donde tiene
     que enviar?
       clos22 no sabe si es un teleport para responder o para enviar a un cuarto nodo
          teleport tiene que notificar a que nodo se está dirigiendo 
             conn
             clostorespond
             tienen que tener datos permanentes

teleport que tenga 2 mvars para cada uno de los sentidos
la mvar de salida que sea inpermanente
pero para que para salida? conque teleport no genere nuevos threads es suficiente

bifurcate
hace

wormhole que evite crear threads y labels


             si el primer teleport genera una closure con nodo actual, nodo al que se dirige
             el siguiente teleport puede
                ver la conexion si no ha despertado
                  si acaba de despertar, ver el telport anterior si tiene nodo y nodo de destino
                     entonces es un teleport de vuelta
                  se considera que el primer teleport despues de wormhole siempre se ejecuta vivo

                  conn <- getState <|> guessCon
                  endpoint (crear closure[closOrig,closDest])

                  guessCon=do
                   buscar prevClos 
                   leer [nodorig,nordestine]
                   conectar con nodorig

          simplemente hacer copyState de comm y clostorespond

liftCloud f x= local $
    si no recovery f x
    else x

instance applicative Cloud where
   si no recover x <*> y else (x >> empty)<|> (y >> empty)

setcont sin receive y con receive
setContreceive
 solo cuando no es Just lanzar la lectura de lo contrario ya esta leyendo





resetRemote stopRemoteJob, single, unique  -- como tratarlo con la nueva gestion de remoto






job:  
1 smart contract se ejecutaria con distintas wallets/usuarios y con distintas sesiones por lo que
no se pisarian unas a otras. no habria S0

job: usar siempre con collect paa asegurar que acaba. 
  pero se puede llamar recursivamente job -> job y un collect dentro de otro collect
    y un job que sucede al anterior debe borrar el anterior
  
  job que cree un state que será borrado el siguiente. Solo puede haber un solo job en la linea de ejecucion