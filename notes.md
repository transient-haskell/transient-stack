currently testing transient-universe

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
cabal install  --lib  --package-env . random directory bytestring containers mtl stm bytestring aeson case-insensitive network websockets network-uri old-time base64-bytestring TCache data-default  network-uri network-bsd     text mime-types process vector TCache hashable signal deepseq

for transient-universe-tls:   tls 



-- set path

usar transient-typelevel para una monad que incluya automaticamente local, onAll o id a cada término.

pero loggedc?

Ver que async ejecuta su argumento en un nuevo thread : si

test de TCache que salva un estado coherente: si

runAt service  que es una compilacion concreta del programa, con macros

cojer los services de las closures?

    
Idea: definir TransIO a = Statet EventF (StreamData a)  (newmnoad.hs)

Idea: closures con nombres aleatorios, timeout en la closure
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


Grand unification
                     unification                    result
CPU codigo maquina

Memory access        microprocesador, Interrupts    batch processing,direct exec of formulas
                     High level laguages(FOrtran)   (pure numeric algebra)

Disk I/0             DMA, OS with syncronous IO     interactive console apps, algebraic composition with I/0
                     blocking (Linux)               blocking, single threading

Multiple I/O
Disk                 OOP (message-based)            spaguetty, no albebraic composition
mouse                epoll, message loop
communications


Threading            async/wait/semaphores          imperative with blocking, no algebraic composition
parallelism          critical sections etc
concurrency          

Web                  Web server, routes
                     Message loop                   manual state management, no composition


                     continuations                  Could solve the composition problems but
                                                    abandoned. Largue exec states, OOP dominance
                                                    disconnection of academy from real world programming
                                                    needs, 
                                                    Lack of global vision (get things done). 
                                                    Search for sucedaneous:
                                                    modularity/ encapsulation/ separation of concern.
                                                    Partial solutions: async/await.
                                                    False dichotomies: block programming versus distributed

distributed          message loop
                     actor model
computing            agent programming              no advancement in composition. artisanal programming
                     (OOP with other names)         

client-side          message passing
programming          web services, JSON             no imperative composition,need explicit state management
                     (pragmatic distributed
                     computing/OOP)
                     callbacks

Multiuser
workflows            same solutions
(Blockchain
contracts)
                     
                     Grand unification:

                     -web routes are stacks
                     execution logs are seria-
                     lizations of stack
                     - intermediate results can
                     be removed from logs when
                     not in scope
                     -execution states could be
                     transported as logs and          Transient: Everything should compose with anything
                     restored
                     -Get Web requests are logs
                     -threads could execute 
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
                     -messages/web/distributed 
                     requests could transport
                     stacks as logs
                     -messages could address previous
                     restored stacks to construct
                     the distributed computing state
                     among different machines
                     -callbacks are continuations
                     -streaming is multithreaded
                     nondeterminism
                     - remote requests/responses
                     are send/receive stack states
                     to build the exec stacks of local
                     and remote machines
                     -states are stack variables
                     -stored logs can restore any
                     execution state

