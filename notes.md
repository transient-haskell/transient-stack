currently testing transient-universe (2025)

extensiones vscode: ANSI colors, Log analysis

cd transient-universe/tests

To compile every change and create the test programs in debug mode

cabal install -f debug test-transient1 --overwrite-policy=always

TO run the monitor in debug mode
 clear & runghc -w -threaded -rtsopts   -itransient-stack/transient/src -itransient-stack/transient-universe/src -iTCache transient-stack/transient-universe/tests/MultiRemote.hs  --start localhost:8000 --add 127.0.0.1:8001 n --add 127.0.0.1 8002 n

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

for cardano-cloud:
  cardano-api-10.19.1.0
  base16-bytestring-1.0.2.0
  cardano-ledger-binary-1.7.0.0



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

idea: type AsyncIO=TransIO   para etiquetar comp TransIO que son asincromas
           EmptyIO = TransIO
           StreamIO= TransIO
           ReactIO

    
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
         React cont <- tryState
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
          Listener id callback <- tryState
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

                  conn <- tryState <|> guessCon
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



backtracking tiene que seguir EVars y conexiones hacia los llamantes?
  si el recovery en el llamado  reinstala los handlers, esos se pueden ejecutar en el nodo llamado

en un collect
   un solo closure con una lista de paths  o cambios de sessionid para que haya muchos closures distintos

   un solo closure con una lista de paths
      mas compacto, no necesita closures y jobs separados ni un elemento especial que los identifique todos para que la siguiente closure los invoque
      pero si ya el session id no distingue
        que pasa con los distintos paths generados por un stream como for, choose, waitEvents?
          una variable de entorno que especifique cuando se duplican los caminos y cuando no?
           no porque se usa cuando varios paths convergen en uno (collect) 
           mientras que el stream es lo contrario: un path se convierte en muchos
             y esa esctructura no vale. ni es necesaria porque 
           para esos casos se precisa y basta un cambio de sesion si se quiere distinguir, tal como se habia pensado
           como se ejecuta? 
            se hace streaming a la evar del a closure la lista completa para que la ejecute.
        
        como se manejan los estados, por ejemplo, el id de usuario que envia al minput
           ese problema lo tienen ambos metodos. es inherente a collect: colapsa la informacion.

  como se recupera una localclosure que ahora tiene una lista de serializaciones, no una sola:
    hayque usar lo que se recibe de un nodo remoto, que es una lista de ahora listas. normalmente son individuales, 
    cuando son varias son producidas por un collect.
    cuando se acaba la lista, coincide con el inicio de la siguiente localclosure.
    
    usar endpointWait, que pasa a ser endpoint
    se lanza toda la lista a la EVar de la localclosure
    pero como se regenera el log?
     con la misma logica actual.
    localClosure (... partLog :: Builder, others ::[Builder]...)
      no partLog pertenece a Log mientras 
      data Log  = Log{ recover :: Bool , partLog :: Builder,  hashClosure :: Int} deriving (Show)
      permanece igual


endpoint cuando lo que sigue es empty, como envia log al alternativo?
  tiene que haber un local que lea  un "w"
  

prolongar el log cuando se ejecuta wait para que no ejecute endpoint
pero cuando se ejecuta wait, endpoint ya se ha ejecutado
como detectar endpoint y desviar el log antes de que se ejecute?
el mismo endpoint tiene que detectarlo
  si en recover llega el endpoint, tiene que detectar si el log que sigue es
  para si mismo o para un alternativo. como lo sabe?
    casos en los que se recupera el endpoint
       puede que el log acabe en ese endpoint
       puede que el log se extienda mas alla de ese endpoint
       tiene que poner un signo, un "w" quiza para indicar que lo que viene es para el alternativo?
       en que momento se introduce ese w?
       cuando se genera?
       como tratar un endpoint?
       el endpoint debe ejecutarse siempre
        cuando no esta en recover, añadir un signo  "w" en endpoint? 
          
          no, si el no está en recover y partLog esta vacio, y el log no proviene de un receive, llenarlo con el anterior obviando el teleport 
          el el alternativo, poner que su anterior dbref es el endpoint anterior
          abduce al principio de endpoint

      data LocalClosure = LocalClosure
  { localClos     :: IdClosure,
    localSession  :: Int,
    prevClos      :: DBRef LocalClosure,
    localLog      :: [Builder],
    localMvar     :: MVar (),
    localEvar     :: Maybe (EVar (Either CloudException (StreamData Builder, SessionId, IdClosure, Connection))),
    localCont     :: Maybe TranShip


    se borra others
    se opera igual que ahora con el Builder
    no se necesita Others? quiza no. si para almacenar. en disco, Builder esta vacio. others tiene todos los paths
    Builder es para computar en programa, asi la logica permanece igual
    Solo en el combine de collect se genera un localclosure con una lista completa al salir de collect
     la logica de combine


serilalization de byteString
   crear un newtype  Unquoted a = Unquoted a
   quoted a= case a of 
1
collect
   2 2

2   2
1   1

hay que detectar como estaba el stack antes de entrar (1)
cuando se sumen quitar del stack la parte que ya estaba antes de entar en el collect
como se sabe lo que habia antes?
  al entrar medirlo
    pero como se mete en el combine?
    añadir un tercer parametro:
    combine t -> a -> a -> a
    combine t -> a -> a -> a ->a
    combine :: typerep ainical a a'

el primero siempre es el que habia al entrar : 1
el segundo es el primer resultado  21. se mezclan quitando la longitud de primer: 2(1 qutado)1
el siguiente es otro 21 con 21. queremos sacar 221. la regla es?

truco qutar el de entrada en collect en todos los tipos con stack, añadirlo al final

collect que corte todos los stacks de backtracking y los restaure al final.
   porque provocarian salidas del proceso concurrente
   y collect debe ser un espacio confinado. igual que los aplicativos
   con esto se resuelve el problema.

quitarback = d0
  let mfData'= M.mapWithKey f mfData
  where
  f k x = if tipo backtrack r l then l vacio


collect para que haga caso a los forward de onBack:


caso de uso: situaciones donde un back llega al codigo dentro de collect y necesita un forward para corregir
   la situacion
  ahora mismo no se gestiona ya que collect es un entorno cerrado. collect se desactiva cuando se acaba de ejecutar

  caso de uso:
  votacion: hasta que no acaba la votacion, no se tiene un seguimiento de resultados
    cuando un usuario cambia su voto, se añade a resultados, no cambia el voto anterior
    por lo que hay que guardar tanto los votos como los identificativos para hacer el recuento
      considerando el orden de los votos
      pero no se pueden saber los resultados intermedios
    
    solucion: un collect reactivo, que reaccione tanto a cada voto parcial como a forward dentro de su cuerpo

    alternativa: usar un EVar dentro el cuerpo que que de resultado reactivamente

    collectreactive:

    collectr comp= do
      follow comp <|> gather
      where
      follow comp= do
        evnew <- newEVar
        r <- comp 
        modifyState' (\Total t -> r <> t)
        writeEVar evnew r
        empty

      gather= do
        r <- readEVar evnew
        total <- read results 
        -- return the last produced data and the total
        return(r,total)
    
    este reaccionaria a todo evento en comp incluidos los forward

integrarlo en collect/collectc para tener todas sus propiedades

ahora en collect:
  r <- signal <|> timer <|> (proc `onBack` check)

  r <- signal <|> timer <|> gather <|> (proc `onBack` check)

mientras no salga por numero de resultados, tiempo por no haber threads, collect será reactivo
en lugar de dar una unica respuesta.

Como hacerlo mas compositivo:

poner results y la EVar al alcance desde el exterior:

collect...= do
crear results :: RState, evar :: evar
antes del primer abduce, y poner gather fuera de collect,
  de manera que:

  results <- collect <|> gather

  gather devolverá cada resultado y collect el resultado final?

pero hay casos de uso en que incluso despues del resultado final, es necesario reaccionar a un back
  eso creo que lo puede garantizar gather ya que está fuera del collect.
  hay que envolverlo bien dentro de la monada cloud para que sea persistente


descomponer collect en componentes:



collect n t proc= checkNoActivity n proc <|> signal <|> timer  t <|> gather

para que timer (signal) puedan matar tod el proceso accediendo al parent thread

checkNoActivity :: Int -> TransIO a -> TransIO (Collect [a]) 
checkNoActivity n proc= proc `onBack` check

--
gather  ::  TransIO (Collect [a])
   Buffer ref ev <- tryState <|> "gather :: no buffer defined"
   events <- 
   ..
   ..

timer :: Int -> TransIO (Collect [a])
  Buffer ref .. <- tryState...



como se pasa la sesion al cliente 
 usar el id de sesion? al dar de alta la wallet?
 cookie?
 como se maneja cuando convergen varios usarios 
    ... varias sesiones
          |
          v
    collectc $ minput
          |
          v
    unica sesion
    sesion no puede ser la de un usuario hay que poner una nueva sesion
    todos convergen en una
    que sesion muestra minput en un collect?
       la suya propia.
       collectc tiene que generar su sesion antes de llamar a minput. hecho
         pero ese flujo  generará un collect para cada usuario. no vale
         
         como tener un collect unico para todos los usuarios?

         la app se ejecuta al principio por el usuario master que inicia la aplicacion
         ese usuario se le da la opcion de iniciar.

         los demás usuarios solo ven el link dentro del collect gracias a publish

         keep $ initNode $ userInit <|> do
               |  single main system session (sistem init etc)
               v
         r <- collect.. $ publish ... minput a
         ...
         ..minput b


publish no puede ser un RState simplemente. tiene que ser una variable global indexRState -> map en un IORef

runghc -w  -threaded -rtsopts -itransient-stack/transient/src -itransient-stack/transient-universe/src -icardano-cloud/src cardano-cloud/tests/test.hs --start localhost:8080 --cardanoparams   /ipc/node.socket  preview ./cardano-cloud/tests/payment.skey

        /-----userInit/allEndpoints
        |        |  
        |        v  init, system session
        |----> collect (1)
        |      | | | |    user sessions (1)
        |     v v v v    
        |    end collect
        |       |   system session
        |       v
        |----> collect
         

como se maneja cada user sesion cuando pinchan un minput de un collect?
  mandan la cookie en el envio
  la cookie está relacionada con el estado
  en  collect despues del minput:
    userEnv <-getIndexData cookie
    setState userEnv
    -- no se cambia la session
    
el primer endpoint dentro de collect entra en la system session
luego el segundo si hay, no tiene que cambiar la session 
  porque un solo registro de endpoint admite cualquier numero de paths
  se hace setState userEnv (no se loguea)
  si hay que logear algo, ids , accounts etc de userEnv se logea y eso es suficiente

para que sirve entonces la sesion? 
  Para distinguir distintos flujos en el tiempo o paralelos
    por ejemplo cuando se ejecuta el flujo desde el principio dos veces y queremos tener 
    ambos funcionando por separado (dos wallets de dos usuarios)
  merece la pena mandarlo como cookie????
    si el session el id no aparece en la url, no se pueden distinguir links entre distintas sesiones
      por ejemplo, dos subastas de dos productos
      todo lo que esté en la monad cloud y vaya a usarse varias veces tiene que tener sesiones distintas

los links exportados por otros tienen la sesion del que los creó.
  El que lo pincha entra en la sesión del que creó el link, lo cual esta mal
  como resolver eso
    necesitamos un estado mas que es lo que pretendia solucionar el codigo anterior
    hay closure = nombre del endpoint
    sesion que lo creo= despues del S
    sesion/stableptr del que accede
    necesitamos codificarlo en una cookie?
    el link siempre coje el contexto del que lo exporto. 
      por tanto no pudemos encontrar nuestra wallet en nuestro contexto despues de un link si fue generado por otro
        como podemos recoger nuestro contexto:
        antes: context en tcache con todas las variables serializadas
               pero como se transladaba el idcontext a la url y vuelta?
               el navegador tiene que tener una cookie de idcontext cargado al generar el HTML de su web
               OOOOOKKKk la cookie tiene que generarse al inicion de la sesion, cuando se da de alta la wallet/login:
                     el servidor contesta a la primera llamada con una cookie que es el idsession.
                     el servidor asocia ese idsession con su mfdata actual.
                        puede tener varios estados? algunos endpoints han sido guardados por otros, otrios por uno mismo.
                          cuando son guardados por uno mismo, no se hace caso a la cookie y sigue con el mismo.
                        de momento un solo mfdata por sesion.


    antes la sesion estaba codificada en Context
      como se sabia el contexto del llamante

system session
collect...
     minput   <- todos lo usan


generacion de JSON maqueta
usar           



endpoint sin <|> return() alternativo
  ahora endpoint no tiene "<|> return()" cada segmento se aplica a cada nuevo endpoint para segir la comp.
  pero
    endpoint <|> local otra cosa logeada
    1) no funciona ya que el resto del log lo capta endpoint para seguir monadicamente

    2) teleport necesita <|> return()  pero al ponerlo fuera de teleport
    la llamada de vuelta ejecuta el return() y sigue. Y al mismo tiempo el segmento tiene un e/ adicional que el endpoint lo inyecta y fuerza la ejecución una segunda vez de lo que hay detrás de enndpoint
    antes eso no pasaba ya que el log no venia en fragmentos y el endpoint no inyectaba el siguiente fragmento sino que continuaba por <|> que era en unico camino.

    poner un abduce al principio de teleport resuelve 1) ya que el endpoint no captura el log alternativo
         pero depende del endpoint anterior, no del nuevo creado, haciendolo mas largo
         no resuelve el problema 2 

    eliminar el "e/" evitaría lanzar otra vez la continuacion de teleport
    pero al eliminar el e/ que es el partlog es facil, pero corta el log y el teleport de recepcion se cree que
    no esta en modo recuperacion sino en directo y manda una nueva request al nodo llamado

  problema: teleport

  como saber si el teleport envia o recibe sin mirar recover
    partlog y restlog y parseString
    alguno de los dos es nulo en elguno de los dos casos?
       restlog es el log previo que ha sido generado o que está siendo consumido
       partLog es el que se está generando ahora 
          si está nulo es que esta en recover no porque se genera en ambos casos
       parseString es nulo siempre que está en endpoint

    añadir un "e/" al final del mismo segmento, en teleport, resuelve el problema

problema job:
  endpoint con abduce al principio no coje el endpoint suyo creado dentro de job
    alguna opcion para que el job coja el endpoint?
    si: endpoint <|> writeEvar endp SMore 
    (1)pero ese writeEVar necesita saber cual es el endpoint del primer termino, pero se lo ha saltado

    poner el abduce de endpoint ants de receive1
    en modo directo ya esta seteado el endpoint y al alternativo le permite writeEVar...
    en modo recovery, si se pone el primer término como predecesor, estamos en las mismas
    queremos que un endpoint se contruya a partir de otro en la misma expresion aplicativa o no?
      idealmente si
      pero eso lleva a que el endpoint pueda inyectar hacia abajo (monadico) o hacia la derecha (aplicativo) (2=)

      el caso contrario necesitamos writeEVar (evar del primer termino) y eso lleva a 1)
    
    2) como hacer streaming a la derecha:
    streamright left right = do
        
ma <-> mb =
     Transient $ do
       ma <|> mb

el problema es que el segundo termino es desconocido
puedo acceder a toda la computacion, no al segundo termino aislado
en recovery tengo un receive1<|> injectmonadic

el injectmonadic.. puedo hacer un alternativo

hace falta el inject alternative? cuando se está ejecutando un segmento y encuentr un u/ 

[seg1,seg2,seg3] en modo directo solo puede haber un segmento con alternativo que  es el primero del modo directo
por ejemplo en   endpoint  <|> otro  por tanto no hay problema. un endpoint no puede generar caminos alternativos solo
el directo pasa por el. luego se

       

    
    .
  si se quita el abduce, como está ahora, el endpoint recien creado por el recovery toma el siguiente segmento como suyo y no del alternativo
  

  señalar con w el inicio del alternativo, pero cuando
    deberia incorporarlo el logged. por que no lo hace?
    cuando hay un endpoint en el primer termino de <|> y hay un alternativo
       addWait de logged ve un preservePath y no graba el "w"
       endpoint deberia lanzar dejar paso al alternativo. eso lo hace en modo directo pero no en modo recover
       por que no lo hace en modo recover? 
        porque detecta que hay log sobrante y eso lo captura para seguir
        por tanto o el propio endpoint graba un "w" o endpoint avisa con un flag a logged para que lo grabe
        mas sencillo que lo grabe endpoint aunque se rompa la responsabilidad
        en donde lo graba? en partLog. tiene que grabarlo en modo recover tambien
          en modo recover en inject debe mirar ese "w/"
          en que momento se pone "w/"
          en partLog en el <|> despues del inject
          antes, que chequee partLog por "w/" y en ese caso que no ejecute inject
          todo eso se puede codificar en inject

            
          
tcache delDBRef:  que pasa si borro dentro de un atomic y la transaccion hace rollback?
no pasa nada a condicion de que al final se lleve a cabo y sea el mismo registro
para delete, crear un nuevo registro con clave delete:

newtype Deleted a= Deleted a 

instance IResource a => IResource (Deleted a) where
   keyResource (Deleted x)= "DELETED#" <> keyResource x
   readResource (Deleted x)= readResource x
   writeResource (Deleted x)= writeResource
   delResource (Deleted x)= delResource x

instance Indexable a => IResource (Deleted a) where
   key (Deleted x) = "DELETED#" <> keyResource x
   defPath (Deletec x)= defPath x <>"/deleted"

instance (Serializable a) => Serializabla (Deleted a) where
   serialize (Deleted x)= serialize x
   deserialize (Deleted x)= deserialize x
   setPersist (Deleted x)= setPersist x

sustituir 
    safeIOToSTM . criticalSection saving $ delResource x
por
    -- tiene que acceder a la clase para poder restaurar, no vale safeIOToSTMComp
    safeIOToSTMComp( writeResource (Deleted x) >> delResource x)  (readResource (Deleted x) >> writeResource x >> deleteResouce(Deleted x))

    recover x=
      readResource (Deleted x)
      writeResource x


data Transf= forall a.Transf (a -> a -> a)

merge :: [Transf] -> PolyMap -> PolyMap -> PolyMap

secondConn :: Connection -> Connection -> Connection
secondConn _ c2= c2

transf f
combine t x y= do
  tc = typeRepTyCon t
  para cada dato del map pasarle todas las formulas
  if tc == typeRepTyCon (typef f)
    then
        f x y
    else continue


  typef :: (a -> a -> a) -> a
  typef _ = undefined


si la primera  vez el browser tiene una cookie de estado, como detectarlo?
   cuando llama la primera closure. 
      no, puede llamar cualqioera.
    el noparam leer dbref si no existe, asignarle 0
   cuando viene de listen Socket
   caundo conecta la wallet?
     la gestion de sesion iene que ser especifica de cada aplicacion
   hacer la cookie que sea de sesion.
   en processMessage:

como gestionar urls con paths y noparams?:  usar # y ## en lugar de S y T

quitar el endpoint de minput y sacarlo fuera

endpoint Just "wallet"

minput verb payload= do
v <- logged $ return verb
guard v== verb
..
..

...

endpoint (Just "wallet") 
minput "connect ...  <|> minput "assets" ...
se verian endpoints /wallet/connect/....   /wallet/assets/....


minput segments="wallet/connect"...
log <- getLog
guard $ segments `isPrefixOf` log
setLog drop length segments log
 añadir segmentos a la url

no funciona porque no ejecuta el alternativo 

crear varios endpoints con el mismo nombre

usar el path completo como nombre

http://localhost:8080/wallet/connect/#u


------- services called with runAt

crear un named endpoint: endpoint $ Just "syncServices"

service "blockSpitter" blockSpitter


remoteBlockSpitter= runAtNamed "blockSpitter" syncNode blockSpitter

runAtNamed serviceString node proc= do
  wormhole  node $ do
     teleportNamed serviceString session

teleportNamed service= do
  setLastClosureForConnection conn service session
  -- si llamo ahora a teleport, va a crear un endpoint local y eso no interesa o si, si cambiamos la sesion
  -- pero eso crea un nuevo endpoint en cada invocacion. newSession deberia ser unico en funcion de la localizacion eso lo asegura el hash del log
  hash <- hashClosure <$> getLog
  setSession hash
  teleport

    

escritura recursiva de DBRefs
writeResource 


A ver si lo extendemos a un problema mas general, que es el  centro y objetivo de todo:  este clente general index.html es solo un cliente de referencia para programadores que usen transient para hacer programas cliente REST. Por tanto tiene que haber una llamada rest previa para asignar una cookie.

Por tanto, no se debe asignar la cookie cuando se carga index.html, sino que este, una vez cargado, solicite una cookie y se la autoasigne al principio una vez cargado. 

Ese servicio deberia visualizarse en la interaccion con index.html,  comn dos opciones: use current cookie <|> enter cookie y <|> solicitar cookie. Ese siempre será en start fijo. y por tanto no necesitamos ese tratamiento de /start ni de firstEndpointNames.  Tendria que estar en todos los programas que usan interacciones REST con minput. A no ser eso quiera que sea voluntari

para que published pueda ver sus publicaciones en cold start, es necesario que el otro haya ejecutado su exportacion antes.
  solciones:
   publish que ejecute job
     con eso siempre se ejecuta

  hay alternativa? no porque la computacion no puede adivinar el futuro. se pueden guardar las expowrtaciones en un registro
  
  persitente o en el log con un key=keylog + offset


partLog contiene el log parcial a enviar

si el anterior es 0, solo usar partLog

a          .->  a'
b         /     b'
c        /      c'
teleport/ <-.   teleport    40503000
d'           \  d
              \
teleport   .-->.teleport    60503000
f         /     f'
g        /      g'
teleport/

setLastClosureForConnection
  debe ser en teleport o en donde se recibe el paquete, pero esto ultimo puede venir de un ficher
  cuando se ejecuta teleport en modo recovery

concurrentCloud hace abstracción de PrevClos o de remoteClos? 
  remoteClos cunado hay concurrentCLoud y hay que mandar a un nodo que participó, hay que enviar solo prevclos - concurrentClos

  pero si es un nodo que no participo hay que enviar desde lasClosureForConnection

  hay que: hacer update de lastClosureForConnection cuando participó de esa operacion concurrent

  setConcurrentCloudClosure= do
     (do ConcurrentClosure clos <- tryState
         setLastClosureForConnection clos)  <|> return ()
 

 mejor sandboxear la ejecucion y asi dejar el endpoint previo. 
   en teleport poner updateLast para esa conexion
   no vale, porque eso hace update de todas las closures
     solo hacerlo en esa closure
   otra opcion: una variable 
        data ConcurrentClosure= ConcurrentClosure (DBRef LocalClosure)
        para saber a donde enviar variables:
          closToRespond
          ConcurrentClosure - borrarla despues de usar
          lastClosureForConnection
        no vale porque esa concurrenclosure todavia no ha sido envida
        setearla despues del envio

concurrentCloud :: Loggable a => Cloud a -> Cloud a
concurrentCloud cl=   do
    log <- getLog
    onAll $ do
      ttr "concurrentCloud"
      endpoint Nothing <|> guard (not $ recover log)

    local   $ sandboxData (ofType :: PrevClos)
            $ sandboxData (ofType ::M.Map Int (IORef (DBRef LocalClosure))) -- map of lastClosureForConnection
            $ unCloud cl
y si el aplicativo se resuelve en

una alternativa a concurrentClosure seria que el remoto enviara a su gemelo
 en el nodo llamante y que el aplicativo se resolviera, pero las variables
 ioRef del aplicativo ya no existen ¿¿???
    pero las llamadas remotas son reactivas, deberian permanecer no?
    que es lo que impide que se produzca esa reaccion?
    el problema es que lastClosure para el nodo remoto ha dejado de ser
      la de su nodo gemelo.
      por tanto que concurrentClosure sea un flag que mantenga la closure de  su gemelo llamante a ver que pasa
     
      hay que llamar a la closure de ida en el nodo remoto, no a la de vuelta

      NO SIRVE: el nodo remoto ejecutara el log y al segundo teleport enviara la respuesta al llamante sin ejecutar el resto del log

      en el aplicativo sin concurrentCloud el llamante invoca la segunda closure del elemento aplicativo. El remoto, Para seguir el log, necesita el resultado de todo el aplicativo, que no se suministra.
      el objetivo de cCloud es suministrarlo.
        se puede hacer de otra manera?
        se necesita un endpoint antes del aplicativo



      seria como la llamada anterior de la expresion con aplicativo, pero con mas log.

      como guardar esa closure de ida?
         en processMessage si el flag concurrentclosure, no actualizar setLastClosureFor..

         pero como se borra esa condicion
           cuando se haya usado una vez


como señalar al nodo remoto que esta dentro de un aplicativo?
  solo en la instancia aplicativo:
    con una variable de entorno

el flag concurrentClosure closure
  se usa para el envio y para el envio de vuelta
  debe guardarse esa closure despues de invocar un nodo en setClosureForConnection, quitando la que setea processMessage
  cuando se borra? cuando el aplicativo ha finalizado? 
     no porque su efecto es para invocaciones posteriores
     no se borra nunca, solo que cuando hay un processMessage y el lastclosurefor era ya == concurrentclosure
       no hay que hacer caso, ya fue usado



teleport
 endpoint
 local $ do
  cuando tiene la clos de envio
    if Applicative  setLastClos clos del endpoint de teleport


setLog
  si no Aplicative setLAstClos clos re recepcion

poner un teleport en el primer elemento del aplicativo
    no poner en sucesivos teleport


concurrenclosure no puede ser general porque la siguiente invocacion puede ser para un nodo que no ha intervenido en el aplicativo.

cuando se quita concurrentClosure?
  no se puede quitar en general. concurrentClosure debe ser por nodo

  debe haber un flag general:  isApplicative que se elimina cuando acaba el aplicativo
  un flag concurrentclosure que lee el flag anterior y lleve la lista de nodos que han pasado por el applicative
  un mecanismo para quitar ese nodo de la lista cuando se invoque por primera vez despues del aplicativo

  alternativa:
  un flag de aplicativo que se elimina cuando acaba
  en teleport, no meter un endpoint si hay aplicativo

  en el remoto hay que meter el teleport siempre  


concurrentCloud ::  Cloud a -> Cloud a
concurrentCloud clcomp=  do
  log <- getLog

  isapp <- gets isApplicative
  modify $ \s ->s{isApplicative= True}
  when (not isapp) $ Cloud $ endpoint Nothing <|> guard (not $ recover log)
  r <-    clcomp <|>  do modify $ \s -> s{isApplicative= isapp} ; empty
  modify $ \s -> s{isApplicative= isapp}
  return r


sobre teleport sin endpoint para resolver aplicativo:
  no puede funcionar ya que teleport es el que devuelve la respuesta de cada termino
  hay que usar el flag de aplicativo para no tener en cuenta ese endpoint en lastClosurefor...


data Cloud a= Cloud a | forall a.Loggable a => Local a

logged x= Local $ do

instance Applicative (Cloud a) where
   Local a <*> Logged a= 

addwait que sustituya el w/ por el resiltado en logged?
  asi se envia al nodo remoto el otro termino del applicativo. pero nunca llamar el endpoint 
  del ternimo sino uno anterior para que contenga todo el aplicativo.

no exactamtente setLasCLosure for connection no es el problema porque es indexado  por conexion y cada conexion tiene su lastclosure distinta. El problema real es que un aplicativo se puede resolver en el nodo local aunque invoque nodos remotos ya que esa invocacion es un detalle interno de cada termino y la misma insancia de TransiIO puede ejecutarlo, elevada a la Cloud monad. El problema es en una invocacion posterior al aplicativo, un nodo invoca a la lastclousre conocida para esa conexion. pero si esa closure es parte de un aplicativo, como es un termino solo , no puede resolver ese aplicativo en el nodo remoto , ya que el otro termino 

----------------------------
   r <-   runAt (nodes !! 1) (local $ return "HELLO ")  <|>  local (return "WORLD") -- runAt (nodes !! 2) (local $ return "WORLD")
  ttr ("RESULT1",r)


  r' <- runAt (nodes !! 1) $ return "HELLO2"
  ttr ("RESULT2",r,r')

antes de que el primer runat se acabe de eejcutar el alternativo ya ha devuelto "WORLD"

asi que practicamente ambos runat se enecutan en paralelo a pesar de que estan uno detras del otro
y abren distintas conexiones.
----------

