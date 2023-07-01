#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- runghc    -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}

--  mkdir -p ./static && ghcjs --make   -i../transient/src -i../transient-universe/src  -i../axiom/src -i../ghcjs-perch/src $1 -o static/out && runghc   -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}

{-# LANGUAGE ScopedTypeVariables,RecordWildCards,DeriveAnyClass, DeriveGeneric #-}

module Main where

import           Control.Monad
import           Control.Monad.IO.Class
import           System.Environment
import           System.IO
import           Transient.Internals
import           Transient.Logged
import           Transient.EVars
import           Transient.Parse
import           Transient.Console
import           Transient.Indeterminism
import           Transient.Logged
import           Transient.EVars
import           Transient.Move.Internals
import           Transient.Move.Utils
import           Transient.Move.Web  
import           Transient.Move.IPFS
import           Control.Applicative
import           System.Info
import           Control.Concurrent
import           Data.IORef
import           Data.List((\\))
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder

import qualified Data.TCache.DefaultPersistence as TC
import Data.TCache  hiding (onNothing)
import Data.TCache.IndexQuery

import System.IO.Unsafe
import Data.Typeable
import Control.Exception hiding (onException)

import qualified Data.Map as M
import System.Directory
import Control.Monad.State
import Data.Maybe
import System.Time
import Control.Concurrent
import Data.Aeson
import Unsafe.Coerce
import Data.String
import GHC.Generics
import Data.Default
import Data.Char
-- mainrerun = keep $ rerun "config" $ do
--   logged $ liftIO $ do
--      putStrLn "configuring the program"
--      putStrLn "The program will not ask again in further executions within this folder"
  
--   host <- logged $ input (const True)  "host? "
--   liftIO $ print "AFTER HOST"
--   port <- logged $ input (const True)  "port? "
--   checkpoint
  
--   liftIO $ putStrLn $ "Running server at " ++ host ++ ":" ++ show port
--   node <- liftIO $ createNode host port
--   initWebApp node $ return()


{-

como la segunda conexion encuentra la closure?
   la segunda entra por listenNew
necesario identificar connections <-> flows. las conexiones reales cambian.
necesario identificar en la request un identificativo de flow= idConn del que creo el flow
   además, asociar la CONT correspondiente, con todo su state.
   como interactua esto con el resto del checkpoint/restore1?
  closremote/closlocal/flow/....
  como gestionarlo?
    
cuestión de cont/evar para recibir:
   cada contexto de conexion tiene una evar
   si
      choose [1..n]
      runAt node $ wathever
   crea instancias que están esperando mensajes y todas ellas reciben. no es correcto
     una opcion es no reutilizar los ev (es lo que habia en teleport) y lanzar lastWriteEVar SDone si habia ev
       hecho
   con cont solo la ultima instancia recibe, necesario meter cont de todas formas para reutilizar estados
      entre varios usuarios.

process si no encuentra el hash tiene que buscarlo en disco.
el log que incluya la closure de partida.
como se accede a su evar?
  la reejecución modifica el map y da de alta el evar, se accede de nuevo al ,map
  checkpoint/createflow  pone como nombre el nombre de la closure final
  como cambia de carpeta, a una hija eso da la jerarquia
     que pasa si hay varios threads en la madre, cual es el bueno?
     solo hay un fichero por closure, por el tipo de hashing.
wakeFlow id= do
  buscar id


createFlow=
  log <-
  crear carpeta con closure
  fichero nombre closure, log con el incremental desde el ultimo createFlow
  como se sabe el incremento
   colocar una señal en el punto del log.
     r <- logged
            logged
                createflow
     logged
     createFlow
  
  hacer como las closures
    getEnd, guardad en closures para esa conexion setIndexData
    buscar el directorio padre para sacar la, buscar el index con getIndexData
    es necesario especificar los puntos de flow?
    pueden ser todos los webPoimt
      asi los closures coinciden

    plan:
      probar log incremanetal
        namedCheckpoint
    en los namedcheckpoint guardar el log total y la prevClos
        siempre guardar el log total en los namedcheckpoints
        podemos hacer que los localcheckpoints no se graben y sean solo temporales.
        asi no hace falta incrementales.
         no habria mezclas de usuarios en el mismo flow
        

closCheckpoint= return()

closCheckpoint = noTrans $ do
    -- conn <- getData `onNothing` error "closCheckpoint: no connection"
    log <- getLog
    let clos= hashClosure log
        name= show clos
    liftIO $ print clos
    if (recover log || clos ==0) 
      then do
        cont <- get
        liftIO $ print ("setIndexData",clos)
        let refclos = getDBRef $ kLocalClos (error "idSession") clos :: DBRef LocalClosure
        -- localClos <- readDBRef refclos
        liftIO $ atomically $ writeDBRef refclos LocalClosure{localCont= Just cont} 
        -- setIndexData  clos cont
        return () 
      else do
        dir <- liftIO $ doesDirectoryExist logs
        when (not dir) $ liftIO $ createDirectory logs
        --setCurrentDirectory name  -- <- no valido, aumentar 



        PrevClos prevClos  <- getData `onNothing` error "prevclos" -- return (PrevClos 0)
        
        ns<- if prevClos== 0 then return [] else  do
              (_ :: Int,ns, _ :: String) <-  return . read =<< liftIO (readFile $ logs <> show prevClos)
              return ns
        -- let serial=  serialize (prevClos,getEnd $ fulLog log,toLazyByteString $ getLogFromIndex ns  $ fulLog log)
        -- liftIO $ BS.writeFile (logs <> name) $ toLazyByteString serial

        return ()

-}

-- getClosureLog :: Int -> Int -> StateIO (LogData, EventF)
-- getClosureLog idConn 0= do
--    liftIO $ print ("getClosureLog",0)

--    clos <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos 0 0) `onNothing` error "closure not found in DB"
--    let cont= fromMaybe  (error "please insert closCheckpoint at the beginning") $localCont clos
--    return (mempty,cont)
{-
 preclos tiene que identificarse no solo por la clos sino por idcon
    o ni siquiera por idcon sino por sessionid, porque puede ser iniciado por consola.

    un usuario crea una sesion y crea closures.
    luego ese usuario puede salir de sesion e iniciar otra, enganchando esa sesion vieja.
    por otro lado un usuario puede crear una sesion general que pueden continuar otros usuarios.
       preclos siempre refiere a su propia sesion?  
          si es una sesion del mismo usuario se podria asimilar como que es una continuacion de la misma sesion.
          pero si es un usuario distinto no pues puede haber diferentes sesiones de continuacion.
    donde se almacena la sesion   
      tiene que ser una variable de estado PrevClos idConn Clos
               
-}
-- getClosureLog idConn clos= do
--     liftIO $ print ("getClosureLog",clos)
--     -- (prevClos :: Int,ns :: [Int], log) <- return . read =<< liftIO (readFile $ logs <> show clos)
--     -- asume se ha creado el registro de la sesion actual y closcheckpoint ha rellenado la continuacion
--     clos <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos idConn clos) `onNothing` error "closure not found in DB"
--     -- let nlog= LogData[ LE $ lazyByteString localLog] 

--     -- mcont <- getIndexData clos -- quien puebla esa estructura? closCheckpoint
    
--     prev <- liftIO $ atomically $ readDBRef (prevClos clos) `onNothing` error "prevClos not found"
--     case localCont clos of
--       Nothing -> do
--         (prevLog,cont) <- getClosureLog (localCon prev)(localClos prev)

--         return (prevLog <> localLog clos,cont)
--       Just cont -> return (localLog clos,cont)
        

-- restoreClosure _ 0= return()
-- restoreClosure idConn (clos :: Int)= Transient $ do
--   (log,cont) <- getClosureLog idConn clos
--   modifyData' (\prevlog->prevlog{fulLog=fulLog prevlog <> log})
--               (emptyLog{fulLog=log})
--   setParseString  $ toLazyByteString $ toPath log
  
--   runContinuation cont ()

{- hay que tener los conexiones en una variable global para reasignar estados
 no hace falta si solo es el estado de la LastClosure
 
 opciones.
   una llamada propia: createFlow entre usuariod
     pero hay que resolver el mantener el estado entre sesioes del mismo usuario.
        guarda conexión idConn pero no state.
        posible almacenar y set el state en conexion?


cuando se llama desde el mismo navegador, guarda localClosures
cuando se llama desde distinto no
en cualquier caso no guarda estado.
 como saber la closure anterior.
 guardar  flow - closures
 tememos un stmap idConnection remoteclosure
 hay que enviar el identificador en la URL
 hay que buscar con ese Id la ultima closlocal que esté accasible globalmente
   localclosures es map clos (clos,mvar,evar,cont)

Pero es necesario que esa closure sea accesible cuando está en localClosures de otra conexion
hay que pasar conexion y closure o un map name- datos necesarios para continuar o reiniciar una closure
global localClosures?
 tenemos Data closnumber EventF
 tiene que ser un map global idcon-closnumber  cont o (mvar,evar,cont)
 en que queda localClosures?
   closures no deberia depender de la conexion ya que se puede reconectar.
   localclosures es un map closnumber (mvar,evar,cont)
   plan eliminar loclalclosures de la conexion, hacerlo global, pero dependiendo de idCon-clos
      map idcon(map clos(mvar,evar,cont) )

      idcon tiene que ser persistente no solo en la app sino en blockchain cuando tiene que ser continuada
      por otro usuario. se mete en TCache y se hace la persistencia donde sea necesario.
      
      setIndexData idClosure cont suprimirla y usar esa estructura persistente
      como eliminarla? con finalizaciones.
      multitask?
      map index (file,mvar,evar,cont)
      index = LocalClos idcon idclosure | NamedClos BS.ByteString
      solo las persistentes pueden
               cambiar de usuario
               serializar y deserializar?
              solo esas persisten y estan en global?
              pero el HTTP 1.0 como cierra conexion, tienen que estar en global
                luego tienen que estar todas en memoria global
                se pueden serializar todas, pero las con nombre, el blockchain o IPFS
        las otras se eliminan despues de un tiempo? con finalizaciones
        que pasa con multithread? se machacan unas con otras si tienen el hash actual
        quepasa con distributed computing? creo que nada, solo que permite reconexiones 

        meter localclosures en TCache?
          meteria el contenido del log directamente : index ((prev,log, border),mvar,evar,cont)
          data LocalClosures= LocalClosures{prevClos,log, border,mvar,evar,cont}

hay que meter la session id idConn en los primeros parametros
estados:
 PrevClos DBRef   -- closure anterior
 (Closure sesion clos,[Int]) -- closures remotas y bordes
 DBRef sesion clos ..... <- todas las closures de todas las sesiones

 PrevClos es la sesion actual
   se debe iniciar en setLog/ closure 0

-}
showNetworkRequest conn= do
  cdata <- liftIO $ readIORef $ connData conn
  liftIO $ print $ case cdata of
    Nothing   -> "Nothing"
    Just Self -> "Self"
    Just (HTTPS2Node ctx) -> "HTTPS2Node"
    Just (HTTP2Node _ sock _ _) -> "HTTP2Node"
    _ ->  "Other"
guardNetworkRequest conn= do
    cdata <- liftIO $ readIORef $ connData conn
    case cdata of
      Nothing   -> do liftIO $ print "Nothing"; empty
      Just Self -> do liftIO $ print "Self";empty
      -- Just (HTTPS2Node ctx) -> return()
      -- Just (HTTP2Node _ sock _) -> return()
      _ ->  return()

-- maingetClos= keep' $ do
--    closCheckpoint
--    (r,_) <- noTrans $ getClosureLog 0 3000  
--    liftIO $ print r
   
-- mainhelloword= keep' $ do
--   closCheckpoint
--   x <- logged $ return "hello "
--   closCheckpoint
--   y <- logged $ return "wolrd"
--   closCheckpoint
--   logged $ liftIO $ print $ x <> y

haply x= x <|> return()

{-
flowAssign=  do

      cont <- get
      log <- getLog
      let rs= getDBRef "0-0"-- TC.key this

      tr ("assign",log)
      when (not $ recover log) $ do

        let this=LocalClosure{
                localCon= 0,
                prevClos= rs, 
                localLog=   fulLog log, -- codificar en flow.hs
                localClos= 0, -- hashClosure log,
                localEnd=getEnd $ fulLog log, -- codificar en flow.hs
                localEvar= Nothing,localMvar=error "no mvar",localCont= Just cont}

        tr ("end", localEnd this, fulLog log)

        liftIO $ atomically $ writeDBRef rs this
      setState $ PrevClos rs
-}
{-
processMessage para que reciba de un proceso IO
actualmente recibe un Log de builder
EVar(Either CloudException (StreamData Builder, SessionId,IdClosure,Connection))

un mailBox resolvería el problema?- necesitaria setCont,
lo de arriba es un mailbox con todo lo necesario
programar getPersistMailBox' como minput


ahora es necesario generalizarla EVar


como evitar
-}
-- (<||>) x y= (abduce >> x) <|> y


data HI=HI deriving (Read,Show,Typeable)
data HELLO=HELLO deriving (Read,Show,Typeable)
data WORLD=WORLD deriving (Read,Show,Typeable)
data PRE=PRE deriving (Read,Show,Typeable)
data POSTT= POSTT deriving (Read,Show,Typeable)
data PRE1=PRE1 deriving (Read,Show,Typeable)
data POST1=POST1 deriving (Read,Show,Typeable)
data THAT=THAT deriving (Read,Show,Typeable)
data THAT1=THAT1 deriving (Read,Show,Typeable)

instance Loggable HI
instance Loggable HELLO
instance Loggable WORLD
instance Loggable PRE
instance Loggable POSTT
instance Loggable PRE1
instance Loggable POST1
instance Loggable THAT
instance Loggable THAT1


-- setc1    = 
    -- let idSession=0
    -- PrevClos prev <- getData `onNothing` error "no previous session"
    -- -- idSession <-  let ind= read $ takeWhile (/= '-') $ keyObjDBRef prev
    -- --               in  if ind==0 then fromIntegral <$> genPersistId else return ind --idConn conn
    -- closLocal <- hashClosure <$> getLog
    -- let dblocalclos = getDBRef $ kLocalClos idSession closLocal  :: DBRef LocalClosure
    -- tr ("previous data",prev)   
    -- setState $ PrevClos dblocalclos

    -- cont <- get

    -- log <- getLog
    -- setData $ log{fromCont=True}

    -- tr ("CONTINUING",toPath $ fulLog log)
    -- ev <- newEVar
    
    -- tr "newevar"
    -- mr <- liftIO $ atomically $ readDBRef dblocalclos
    -- pair <- case mr of

    --     Just (locClos@LocalClosure{..}) -> do
    --         tr "found dblocalclos"
    --         return locClos{localEvar=Just ev,localCont=Just cont} -- (localClos,localMVar,ev,cont)

    --     _ ->   do 
    --             mv <- liftIO $ newEmptyMVar
      
    --             mprevClosData <- liftIO $ atomically $ readDBRef  prev -- `onNothing` error "no previous session data"

    --             let ns = if isJust mprevClosData then localEnd (fromJust mprevClosData) else []
    --             let end= getEnd $ fulLog log

    --             let lc= LocalClosure{
    --                     localCon= idSession,
    --                     prevClos= prev, 
    --                     localLog= LD $ dropFromIndex ns $ fulLog log,  
    --                     localClos=closLocal,
    --                     localEnd=end, 
    --                     localEvar= Just ev,localMvar=mv,localCont= Just cont} -- (closRemote',mv,ev,cont)
    --             -- setState $ PrevClos dblocalclos
    --             tr ("FULLLOG",fulLog log)
    --             tr ("DROP",ns,dropFromIndex ns $ fulLog log)
    --             return lc
    

    -- liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert closLocal pair map
    -- liftIO $ atomically $ writeDBRef dblocalclos pair
    
    -- tr ("writing closure",dblocalclos,prevClos pair)
    -- tr ("fulLog in setCont", fulLog log,recover log)


    -- return ()

mainalter= keep $ do
  -- flowAssign
  proc <|> restore1 <|> save

  where 
  proc= do
    sal "HELLO" <|> (abduce >> sal "WORLD")
    showLog
  
  sal x= do 
    logged setc 
    lprint x

(</>) x y= Transient $ do
    mx <- runTrans x

    was <- gets execMode
    
    if was == Remote

      then return Nothing
      else case mx of
            Nothing ->   runTrans  y

            _ -> return mx


mainsimple= keep $  initNode $ Cloud $ do
  -- firstCont
  -- logged $ logged $ do
  proc2 <|> restore1 <|> save
  
  
  where
  proc2= do
    logged $ option "p" "process"
    r <-logged $ logged $ do
        setc
        logged $ return HELLO -- liftIO $ print "PARSE ERROR"; error "PARSE ERROR" :: TransIO HELLO 
    liftIO $ print r

    r <- logged $ logged $ do
       setc
       logged $ return (HI ,THAT)
    liftIO $ print r

    showLog

 

maincomplex= keep $  initNode $ Cloud $ do
  
  -- firstCont
  proc1 <|> restore1 <|> save

  where

  proc1= proc "p1"   <|> proc "p2"
  proc op= do
    logged $ option op ("process "++ op)
    r <- logged $ return HELLO
    
    logged $ liftIO $ putStrLn $ show r ++ op
    r <- logged $  logged $ logged $ return WORLD
    logged $ liftIO $ putStrLn $ show r ++ op
    logged $ do
        logged $ return PRE
        logged $ do
            logged $ return  PRE1
            setc
            logged $ return POST1
        logged $ return POSTT
        
    showLog

    logged $ return THAT

    r <- logged $  logged $ logged $ return WORLD

    logged $ liftIO $ putStrLn $ show r ++ op


    setc

    r <- logged $ return HI
    logged $ liftIO $ putStrLn $ show r ++ op

    showLog
    
save= do
    option "save" "save execution state"
    liftIO $ syncCache

restore1= do
        option "res" "restore1" 
        s    <- input (const True) "sesion  >"
        clos <- input (const True) "closure >"

        noTrans $ restoreClosure s clos 
      
lprint :: Show a => a -> TransIO ()
lprint= liftIO . print

setc =  do
    (lc,_) <-  setCont Nothing 0
    liftIO $ putStr  "0 ">> print (localClos lc)

showLog=do
  log <- getLog
  tr $ ("SHOWLOG",fulLog log," ",toPath $ fulLog log,"  ",toPathLon $ fulLog log)


{- 
  Que hay diferente entre setc y teleport?
    el teleport recibe un log el problema es saber, cuando envia, cual es el incremento.
       cuando está a punto de acabar
       pero el envio se hace cuando los exe han sido resueltos. Filtrar los LX? cuales?
          por cada sybslast, recalcular?
          descartar todos los lx desde el final del anterior 
          update setindexdata mientras parsestring== null y esté en un loggedc
  
  el setIndexData es equivalente a la DBRef pero sin log, solo con ends
-}

main2= keep $  save <|> restore1 <|> proc
  
  where
  proc= initNode $ Cloud $ do  
    logged $ option "go" "go" >> setc
    logged setc

main1= keep $ do
   firstCont
   proc <|>  save <|>  restore1
 where
 proc= do
  logged $ option "go" "go"
  r <- logged $ logged $ logged $ do
    setc
    logged $ return HELLO

  logged $ liftIO $ print r
  
  r1 <- logged $ do
    setc
    return WORLD
  logged $ liftIO $ print (r,r1)
  log <- getLog
  tr ("fulLog",fulLog log)


mainfin= keep' $ do
  
  onFinish $ \e-> liftIO $ print ("finish",e)
  liftIO $ print "END"

rone= unsafePerformIO $ newIORef False
mainfinish= keep' $ do
  abduce

  cont <- getCont
  onFinish $ const $ liftIO $ print "finish"

  fork $ do  one <- liftIO $ readIORef rone
             guard $ one == False
             liftIO $ writeIORef rone True
             (_,cont') <-liftIO $ runStateT (runCont cont) cont 
             liftIO $ exceptBackg cont' $ Finish $ "job " <> show (unsafePerformIO myThreadId)
             return()
             
  --            return()
  liftIO $ print "end"
  
{-
 tiene que ser un canal en minput que reciba del proceso
 minput 
 receive <- evar
 minput 
-}


mainshow= keep  $ initNode $ do
  minput "s" "start" :: Cloud ()

  minput "s2" "cont" :: Cloud ()
  local showURL

  minput "next" "next" :: Cloud String
  

str :: IsString a => String -> a
str= fromString

mainjob= keep  $ initNode $ do
  runJobs

  str <-minput ("s" :: String) "start"
  localIO $ putStrLn str


  ev <- onAll $ liftIO $ newIORef []
  minput "input" "test" :: Cloud ()


   
  --  minput "input2"  "test2" :: Cloud()
  job(process ev) <|> report ev 

  where
   process ev= do
    i <- local $ threads 1 $ choose [(1 :: Int)..]
    localIO $ threadDelay 10000000
    localIO $ atomicModifyIORef ev $ \l -> (i:l,())
    empty
    return()

   report ev=  do
    minput "log"  "show log" :: Cloud()

    e <- localIO $ readIORef ev
    minput "" $ reverse e :: Cloud ()
    empty



mparallel mx=  job $ local $ parallel mx


{-
borrado de registros por timeout
localClosures estan ahora en registros TCache. 
pueden ser limpiados por el mecanismo de TCache clearsynccache. no necesita loopClosures
pero necesita borraarlo del permanent storage
en IPFS se autoeliminarian solos
en disco necesita limpiar?

-}
-- main20=keep $ syncFlush <|>  initNode (do
--    onAll flowAssign
--    local $ return "HI"
--    r <- minput "enter msg1"  :: Cloud String 
--    onAll $ liftIO $ print "RECEIVEDDDDD llll"
--    localIO $ print (r ::String)
 
--   --  conn <- Cloud getState
--   --  path "msgs1"
--    r2 <- minput "enter msg21"  <|> minput "enter msg22" :: Cloud String -- <|>  Cloud( do liftIO $ threadDelay 1000000; msend conn ( BS.pack "0\r\n\r\n"))
--    localIO $ liftIO $ print (r,r2)
--    r3 <- minput "enter msg3" :: Cloud String
--    localIO $ print (r,r2,r3))
{-
 como se gestiona la historia del navegador
 gestion de cookies
 el navegador no guarda las URL por mucho tiempo a no ser que grave en su base de datos
 cuando un usuario entra y ha hecho cosas, que opciones se le presenta?
 puede una cookie servir de id de sesion y para recuperar estado?
     cookie -> query tcache -> enviar todas las URLs?
es la cookie la solucion para mantener datos de sesion en el navegador por largo tiempo?
   no, debería ser la autentificacion, que deberia dar un id de usuario.
   en cualquier caso deberia ser generado por el navegador.

autentificacion? investigar
-}
-- type Paths= M.Map BS.ByteString BS.ByteString
-- rpaths = unsafePerformIO $ newIORef Paths

-- path str= do
--   log <- getLog
--   when(not $recover log) $ do
--       paths <- readIORef rpaths
--       M.insert fulLog log str paths
--       setRState pa <> "/" <> str

-- get all the options of a user
-- allOptions user= do
--   ns <- allReg localCon .==. user
--   let url n= str "http://" <> str (nodeHost n) <> str ":" <> intt (nodePort n) </>    
--                                     intt (localCon n) </> intt (localClos n) </> 
--                                     intt 0 </> intt 0 </>
--                                     str "$" <> (str $ show $ typeOf $ type1 response)
--   return map url ns
--   where 
--   str=   BS.pack
--   type1:: Cloud a -> a
--   type1= undefined
  -- falta response

-- mainwait = do
--   r<- keepCollect 0 0 $ do
--     labelState $ BC.pack "here"
--     onFinish $ const $ liftIO $ print "FIN"
--     -- aqui el parent thread puede lanzar threads y hay que esperar
--     liftIO $ myThreadId >>= print
--     -- abduce
--     abduce <|> liftIO (threadDelay 1000000)
--     liftIO $ print "END"
--   print r


-- onWaitThreads  mx= do
--     cont <- getCont

--     modify $ \s ->s{ freeTh = False }

--     done <- liftIO $ newIORef False  --finalization already executed?

--     r <- return() `onBack`  \(Finish reason) -> do
--                 -- liftIO $ print ("thread end",reason)
--                 -- topState >>= showThreads
--                 noactiveth <- noactiveth cont
--                 dead <- isDead cont
--                 this <- get
--                 let isthis = threadId this == threadId cont
--                     is = noactiveth && (dead ||isthis) 
--                 guard is  
--                 -- previous onFinish not triggered?
--                 f <- liftIO $ atomicModifyIORef done $ \x ->(if x then x else not x,x)
--                 if f then backtrack else 
--                     mx reason
--     -- anyThreads abduce  -- necessary for controlling threads 0

--     return r
--     where
--     isDead st= liftIO $ do
--       (can,_) <- readIORef $ labelth st
--       return $ can==DeadParent

--     noactiveth st= do
--       return $ and $ map (\st' -> fst (label st')== Parent && null (childs st')) $ childs st
--       where 
--       childs= unsafePerformIO . readMVar . children
--       label = unsafePerformIO . readIORef . labelth

mainonwait= keep $ do
  ev <- newEVar
  -- ev2 <- newEVar
  -- onFinish $  const $ liftIO $ print "FIN"
  -- onWaitThreads  const $ liftIO $ print "WAIT"
  readev1 ev <|> readev2 ev <|>    do   liftIO $ threadDelay 5000000 ; return()
  -- topState >>= showThreads
  liftIO $ print "hello"
  where 
  readev1 ev= do
      -- par <- get -- >>= \st ->  liftIO $ readIORef (parent st ) >>= \mp -> return (fromJust mp)
      onWaitThreads  $ const $ do
          -- topState >>= showThreads
          liftIO $ print "WAIT"
      liftIO $ print "readevar"
      readEVar ev
  readev2 ev= do
      liftIO $ threadDelay 1000000
      liftIO $ print "readevar"
      readEVar ev
{-
opciones crear un nuevo estado Waiting
meter un label especial y preguntar por el temporalmente

-}

maincollect =do
  r <- keepCollect 0 0 $ do

    labelState $ BC.pack "here"
    -- se ejecuta todo en el parent thread
    -- pero deberia activarse onFinish
    liftIO $ myThreadId >>= print
    
    r <- threads 0 $ choose[1..2]
    onFinish $ const $ liftIO $ print ("FIN",r)

    liftIO $ threadDelay 1000000
    liftIO $ print ("END",r)

  print r


{-
es un parent. como definir un onFinish parcial onListeners
que cuente...
definir un nuevo estado listener . cuando todos
sean listeners, lanzar el onListeners
-}  

syncFlush= do

  option "sf" "syncFlush"
  -- n <- input (const True) "key to flush > "  :: TransIO String

  liftIO syncCache
  -- liftIO $ atomically $ flushDBRef $ (getDBRef n :: DBRef LocalClosure)



-- teleport1 :: Cloud ()
-- teleport1  =  do

--   modify $ \s -> s{execMode=if execMode s == Remote then Remote else Parallel}
--   local $ do
--     tr "TELEPORTTT"
--     conn@Connection{idConn= idConn,connData=contype, synchronous=synchronous} <- getData
--                              `onNothing` error "teleport: No connection defined: use wormhole"


--     Transient $ do
--     --  labelState  "teleport"

    
--      log <- getLog


--      if not $ recover log  

--       then  do

--         -- when a node call itself, there is no need for socket communications
--         ty <- liftIO $ readIORef contype
--         case ty of
--          Just Self -> runTrans $ do
--                modify $ \s -> s{execMode= Parallel}  -- setData  Parallel
--                abduce    -- !> "SELF" -- call himself
--                liftIO $ do
--                   remote <- readIORef $ remoteNode conn
--                   writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote

--          _ -> do


                
--           (Closure sess closRemote,n) <- getIndexData idConn `onNothing` return (Closure 0 0,[0]::[Int])


--           let tosend= getLogFromIndex n $ fulLog log
--           tr  ("idconn",idConn,"REMOTE CLOSURE",closRemote,"FULLLOG",fulLog log,n,"CUT FULLOG",tosend)
                 
               


--           let closLocal= hashClosure log



--           runTrans $ do
--             msend conn $ toLazyByteString $ serialize $ SMore $ ClosureData sess closRemote idConn closLocal tosend 
--             receive  conn   closLocal 
                  

--           -- return Nothing  

--       else return $ Just ()

-- newtype OpCounter= OpCounter Int

-- minput :: Loggable a => String -> Cloud a
-- minput msg= response 
--  where
--  response= do

--   modify $ \s -> s{execMode=if execMode s == Remote then Remote else Parallel}
--   local $ do
--       log <-getLog
--       connected log  <|> commandLine  log
  

--   where 
--   type1:: Cloud a -> a
--   type1= undefined


--   commandLine log = do

--      guard (not $ recover log)

--      OpCounter n <- modifyData' (\(OpCounter n) -> OpCounter $ n+1) (OpCounter 1)
--      option n $ msg <> ": "
--      input (const True) msg


--   -- connected :: Loggable a => TransIO a
--   connected log = do

--     conn <- getState -- if connection not available, execute alternative computation


--     -- log  <- getLog
--     let closLocal= hashClosure log

--     pstring <- giveParseString
--     if (not $ recover log)  || BS.null pstring

--       then  do
--         tr "EN NOTRECOVER"
--         (Closure sess closRemote,ns) <- getIndexData (idConn conn) `onNothing` return (Closure 0 0,[0]::[Int])
                 
--         n <- getMyNode

--         let url= str "http://" <> str (nodeHost n) <> str ":"<> intt (nodePort n) </>    
--                                     intt (idConn conn) </> intt closLocal </> 
--                                     intt sess </> intt closRemote </>
--                                     str "$" <> (str $ show $ typeOf $ type1 response)

--         ty <- liftIO $ readIORef $ connData conn
--         case ty of
--          Just Self -> do
--           liftIO $ print url
--           receive conn closLocal
--           tr "SELF"

--           logged $ error "insuficient parameters 1" -- read the response

          
          


--          _ -> sync $ do

--           -- insertar typeof response
--           let tosend= str "{ \"msg\"=\""  <> str msg  <> str "\", cont=\""  <> url <> str "\"}"
--           let l = BS.length tosend


           
--           -- keep HTTP 1.0 no chunked encoding. HTTP 1.1 Does not render progressively well. It waits for end.
--           msend conn $ str "Content-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend 
--           mclose conn
--           receive  conn closLocal    -- toHex (fromIntegral l) <> str "\r\n" <> tosend <> str "\r\n0\r\n\r\n"
--           tr "after msend"


--           logged $ error "insuficient parameters 2" -- read the response
          

--       else do



--         receive conn closLocal
--         tr "else"

   


--         logged $ error "insuficient parameters 3" -- read the response
        
--       where 
--       (</>) x y= x <> str "/" <> y
--       str=   BS.pack
--       intt= str . show
--       -- toHex 0= mempty
--       -- toHex l= 
--       --     let (q,r)= quotRem l 16
--       --     in toHex q <> (BS.singleton $ if r < 9  then toEnum( fromEnum '0' + r) else  toEnum(fromEnum  'A'+ r -10))
  


-- >>> toHex 17
-- "11"
--








    
-- setCont idSession log = do    
--     cont <- get
   
--     ev <- newEVar
--     let closLocal = hashClosure log
--     let dblocalclos = getDBRef $ kLocalClos idSession closLocal  :: DBRef LocalClosure
--     mr <- liftIO $ atomically $ readDBRef dblocalclos
--     pair <- case mr of

--         Just (locClos@LocalClosure{..}) -> do

--             return locClos{localEvar=Just ev,localCont=Just cont} -- (localClos,localMVar,ev,cont)

--         _ ->   do 
--                 mv <- liftIO $ newEmptyMVar
--                 PrevClos prev <- getData `onNothing` error "no previous session"
--                 tr ("previous data",prev)
--                 prevClosData <- liftIO $ atomically $ readDBRef  prev `onNothing` error "no previous session data"
--                 log <- getLog
--                 let ns = localEnd prevClosData
--                 tr ("FULLOG",fulLog log,toPath $ fulLog log)
                
--                 let lc= LocalClosure{
--                         localCon= idSession,
--                         prevClos= prev, 
--                         localLog= LogData[LE $ getLogFromIndex ns  $ fulLog log], -- codificar en flow.hs
--                         localClos=closLocal,
--                         localEnd=getEnd $ fulLog log, -- codificar en flow.hs
--                         localEvar= Just ev,localMvar=mv,localCont= Just cont} -- (closRemote',mv,ev,cont)
--                 setState $ PrevClos dblocalclos
--                 return lc


--     -- liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert closLocal pair map
--     liftIO $ atomically $ writeDBRef dblocalclos pair
--     tr ("writing",dblocalclos)
--     return pair

-- receive  conn   closLocal = do
--     log <- getLog
--     let idSession= if (recover log) then idConn conn -1 else idConn conn

--     lc <- setCont idSession log 
--     when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc

--     mr@(Right(a,b,c,_)) <-  readEVar (fromJust $ localEvar lc)
    
--     tr ("RECEIVED",(a,b,c))
    
--     case mr  of
--       Right(SDone,_,_,_)    -> empty 
--       Right(SError _,_,_,_) -> error "teleport: SERROR"
--       Right(SLast log,s2,closr,conn') -> do
--         cdata <- liftIO $ readIORef $ connData conn'
--         liftIO $ writeIORef (connData conn) cdata
--         tr ("RECEIVEDDDDDDDDDDDDDDDDDDDDDDD SLAST",log)

--         setLog (idConn conn) log s2 closr

--       Right(SMore log,s2, closr,conn') -> do
--         cdata <- liftIO $ readIORef $ connData conn'
--         liftIO $ writeIORef (connData conn) cdata
--         tr ("RECEIVEDDDDDDDDDDDDDDDDDDDDDDD",log,closr)
--         setLog (idConn conn) log s2 closr


--       Left except -> do
--         throwt except
--         empty


  
{-
imposible serializar la direccion del procedimiento
imposible saber sin ejecutar la continuacion que procedimiento hay que escuchar
hayq que hacer restoreClosure inmediatamente.

jobs debe almacenar la lista de sesiones y closures que hay que ejecutar de inmediato

-}
data Jobs= Jobs{pending :: [(Int,BC.ByteString)]}  deriving (Read,Show)

instance TC.Indexable Jobs where key _= "__Jobs"

-- newtype CloudCounter= CCount Int
-- genCCounter= modifyData' (\(CCount n) -> CCount $ n+1) (CCount 0) :: TransIO CloudCounter

{-
se crean automaticamente
como se eleminan esos jobs?
usando onFinish?


Como se notifica al usuario?
 ev <- newEVar
 job ev x <|> jobstatus ev
 
 jobstatus= do
    st <- readEVar status
    minput stream st -> strean json lines until end.

como se acaba? jobstatus pinta el link para continuar

-}
-- | if the state of the program is commited (saved) the created thread is restored
-- when the program is restarted by `initNode` as a job.
--
-- if the thread and all his children becomes inactive, the job is removed and the list of result are returned
job mx = do
  this@(idSession,_) <- local $ do
    idSession <- fromIntegral <$> genPersistId
    log <- getLog <|> error "job: no log"
    let this = (idSession,BC.pack $ show $ hashClosure log + 10000000) -- es la siguiente closure

    Jobs  pending <- liftIO $ atomically $ readDBRef rjobs `onNothing` return (Jobs[])
    liftIO $ print ("creating job",this)
    liftIO $ atomically $ writeDBRef rjobs $ Jobs $ this:pending
    return this

  local $ do
      (clos,_)<- setCont Nothing idSession 
      liftIO $ print $ localClos clos

  rs <- local $ collect 0 $ runCloud mx
  
  local $ remove this -- snd $ head rs
  return $  rs

  
  where

  remove conclos= liftIO $ atomically $ do
        unsafeIOToSTM $ print "REMOVE"
        Jobs  pending <- readDBRef rjobs `onNothing` return (Jobs [])
        writeDBRef rjobs $ Jobs  $ pending \\ [conclos]

rjobs = getDBRef "__Jobs"

runJobs= local $ fork $ do
    Jobs  pending <-liftIO $ atomically $ readDBRef rjobs `onNothing` return (Jobs  [])
    th <- liftIO myThreadId
    liftIO $ print ("runJobs",pending,th )
    (id,clos) <- choose pending
    noTrans $  restoreClosure id clos

data Dat= Dat{field1:: Int,field2 :: Int} deriving (Typeable, Generic,Default)

instance ToJSON Dat

instance FromJSON Dat

instance Default Node where def= Node "" 0 Nothing []

data Kv= Kv{key1 :: String, val ::String} deriving (Generic,Default,ToJSON,FromJSON)


mainimput= keep $ initNode $ do
  minput "s" "start"  :: Cloud()
  -- local $  (fork $ liftIO $ threadDelay 1000000) 
  -- localIO $ tr "bEFOrE ERROR"
  -- onAll $  throwt $ ErrorCall "error"
  moutput "end" :: Cloud ()

  return()

mainfinish2= keep $  do
  -- threads 0 abduce
  onFinish $ const $ liftIO $ print ("FINISH", unsafePerformIO myThreadId)

  option "t" "test"
  liftIO $ print "PROGRESS"

  -- error "error"
  -- fork $ do
  -- --   -- bs@(Backtrack mreason stack) <- getData  `onNothing`  return (Backtrack (Just $ Finish "")  [])
  -- --   -- tr ("SIZE", length stack)
  --    liftIO $ threadDelay 1000000
  -- topState >>= showThreads
  return()
  
  
mainerr= keep  $ initNode $ local $ do
  abduce
  topState >>= showThreads
  onFinish $ const $ tr "==============================FINISH"

  -- onException $ \(e:: SomeException) -> throwt e
  throw $ ErrorCall "---------------------err"
  return()
  

  



mainlocalrem= keep $ initNode $ inputNodes <|> do
  local $ option "g" "go"
  node <- local $ do
       ns <- getNodes
       liftIO $ print ns
       return  $ ns !! 1
  node2 <- local $ getNodes >>= return . flip (!!) 2
  modify $ \s -> s{execMode=Parallel}
  r <- runAt node  (localIO $ print "remoto" >> return "\"remoto \"")  -- <->   runAt node2 (localIO $ print "remoto2" >> return "remoto2")
  localIO $ print "LOCAL"
  localIO $ print ("RESULT",r)

(<->) a b= (do
  
  onAll (liftIO $ print "BEFORE") 
  a <* onAll (liftIO $ print "AFTER") )
  <> b

runAt2 a b= do
    onAll $ liftIO $ print "RUNAT2"
    runAt a b 

mainsand= keep $ do
  sandbox1 $ throwt $ ErrorCall "err"
  return ()


sandbox1 :: TransIO a -> TransIO a
sandbox1 mx = do
  st <- get
  onException $ \(SomeException e) -> do
    let mf = mfData st
        def= backStateOf $ SomeException $ ErrorCall "err"

    bs <- getState <|> return def
        
    let  mf'= M.insert (typeOf def) (unsafeCoerce bs) mf
    modify (\s ->s { mfData = mf', parseContext= parseContext st})
  mx  <*** modify (\s ->s { mfData = mfData st, parseContext= parseContext st})
    


mainsandb= keep $ do
   setState False  
   sandbox $ liftIO $ print "hello"
   ac  `catcht` \(e :: SomeException) -> return()
   i <- getState
   liftIO $ print (i :: Bool)
   where
   ac=  sandbox $ do
    liftIO $ print "inter"
    sandbox $ do
      setState True
      throwt $ ErrorCall "err"

main= keep $ initNode $ inputNodes <|> do
  local $ option "go" "go"
  nodes <- local getNodes 
  nod <- local getMyNode
  r <- local $ collect 2 $ runCloud $ runAt (nodes !! 0 ) (proc nod)  <|> runAt (nodes !! 1) (proc nod) -- <|> runAt (nodes !! 2) (proc nod)

  localIO $ print r
  where
  proc nod= do
      node <- local getMyNode
      localIO $ print $ "hello from " <> show nod
      return $ "world "  ++ show node




mainauction = keep $ initNode $ do

    setIPFS

    POSTData (wallet :: Integer,name :: String) <- minput "enterw"  "enter wallet" 
    setSessionState wallet
    guessgame name wallet <|> auction  
    return()

    where
    guessgame name wallet= do

       minput "guessgame" "play guessgame"  <|> published "lock" :: Cloud ()
       lock  :: Int <- minput "enterlock" $ name <> ": lock a number to guess it"
       guessn:: Int <- public "lock" $ minput "enterguess" $ "guess the number entered by: " <>  name  
       wallet' :: Integer <- local getSessionState
       minput "entered"  [("entered number", show guessn)
                         ,("wallet lock", show wallet)
                         ,("wallet guess",show wallet')
                         ,("success",show $ lock == guessn)] :: Cloud()

    auction= do
       minput "auction" "play auction" :: Cloud()
       error "auction: not implemented"


maintest = keep $ initNode $ test <|> onAll restore1
  where
  test= do
    -- POSTData (name :: String, wallet :: Integer) 
    -- local $ option "s" "start"

    i :: Int<- minput "enterw"  "enter wallet" -- (11 :: Int)
    guessgame
    return()

    where
    guessgame= do

       minput "guessgame" "play guessgame" :: Cloud()
       guessn:: Int <-minput "enternumber" "enter a number"  -- (2 :: Int)
       onAll $ liftIO $ print $ (">>>>>>>>>>>>>>>>>>>>>", guessn :: Int)
      --  minput1 "entered"  ("entered number", guessn) :: Cloud()

    -- auction= do
    --    minput1 "auction" "play auction" :: Cloud()
    --    error "auction: not implemented"


minput1 :: (Loggable a, ToHTTPReq a,Loggable val) => String  ->  val -> Cloud a
minput1 ident val = response
  where
    response = do
      -- idSession <- local $ fromIntegral <$> genPersistId
      modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
      local $ do
        log <- getLog
        conn <- getState -- if connection not available, execute alternative computation
        let closLocal = hashClosure log
        mynode <- getMyNode



        let idSession = 0

        
        params <- toHTTPReq $ type1 response
        
        connected log  idSession conn closLocal    

    

    connected log  idSession conn closLocal    = do
      cdata <- liftIO $ readIORef $ connData conn

  

      -- onException $ \(e :: SomeException) -> do liftIO $ print "THROWT"; throwt e; empty

      (idcontext' :: Int, result) <- do
        pstring <- giveParseString
        if (not $ recover log) || BS.null pstring
          then do
            receivee conn (Just $ BC.pack ident)  val
            logged $ error "not enough parameters 2" -- read the response, error if response not logged
          else do
            receivee conn (Just $ BC.pack ident)  val
            logged $ error "insuficient parameters 3" -- read the response

      tr ("MINPUT RESULT",idcontext',result)
      return result `asTypeOf` return (type1 response)
 
  
    type1 :: Typeable a => Cloud a -> a
    type1 cx = r
      where
        r = error $ show $ typeOf r

receivee conn clos  val= do
  (lc, log) <- setCont clos 0
  s <- giveParseString
  -- tr ("receive PARSESTRING",s,"LOG",toPath $ fulLog log)
  if recover log && not (BS.null s)
    then (abduce >> receive1 lc val) <|> return() -- watch this event var and continue restoring
    else  receive1 lc val
  
  where
  -- receive1 :: (Loggable val) => LocalClosure -> val -> TransIO ()
  receive1 lc val= do


      setParseString $ toLazyByteString  (lazyByteString (BS.pack "0/") <> (serialize val)) :: TransIO ()
      -- setLog 0 (lazyByteString (BS.pack "0/") <> (serialize val)) 0 0 :: TransIO()


