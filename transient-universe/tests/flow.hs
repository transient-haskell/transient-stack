{-# LANGUAGE CPP, ScopedTypeVariables,RecordWildCards,DeriveAnyClass, DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Redundant bracket" #-}
{-# HLINT ignore "Use head" #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE DeriveDataTypeable #-}

{- cabal:
        build-depends:
                       base          >= 4.8.1  &&  < 5
                     , containers    >= 0.5.6
                     , transformers  >= 0.4.2
                     , time          >= 1.5
                     , directory     >= 1.2.2
                     , bytestring    >= 0.10.6
                     , network       >= 3

                     -- libraries not bundled w/ GHC
                     , transient
                     , transient-universe
                     , mtl
                     , stm
                     , random
                     , vector
                     , TCache
                     ,  signal
                     , aeson
                     , data-default
                     , deepseq



    build-depends:
        base >4
    default-language: Haskell2010
    hs-source-dirs: tests src .
    ghc-options: -O0 
-}

-- info: use `sed -i 's/\r//g' file` if message "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- runghc    -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}
-- mkdir -p ./static && ghcjs --make   -i../transient/src -i../transient-universe/src  -i../axiom/src -i../ghcjs-perch/src $1 -o static/out && runghc   -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}



module Main where

import           Control.Monad
import           Control.Monad.IO.Class
import           System.Environment
import           System.IO
import           Transient.Internals
import           Transient.Move.Services
import           Transient.Move.Defs
import           Transient.Move.Logged
import           Transient.Parse
import           Transient.Console
import           Transient.Indeterminism
import           Transient.EVars
import           Transient.Mailboxes
import           Transient.Move.Internals
import           Transient.Move.Utils
import           Transient.MapReduce
import           Transient.Move.Web
import           Transient.Move.IPFS
import           Transient.Move.Job
import           Control.Applicative
import           System.Info
import           Control.Concurrent
import           Data.IORef
import           Data.List
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder

import qualified Data.TCache.DefaultPersistence as TC
import qualified Data.TCache.Defs  as TC
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
import Data.Aeson
import Unsafe.Coerce
import Data.String
import GHC.Generics
import Data.Default
import Data.Char
import System.CPUTime (getCPUTime)
-- import Control.DeepSeq



-- import System.IO.Streams
-- import System.IO.Streams.Handle
import qualified Data.Vector as V
import Transient.Parse (tChar)
import Transient.Base (tr)
import Transient.Internals (LifeCycle(DeadParent))
import System.Random
import Data.TCache (syncCache, getDBRef)
import System.Directory.Internal.Prelude (exitFailure)
import System.Exit (exitSuccess)
import Control.Arrow (ArrowLoop(loop))
import Data.Char (GeneralCategory(InitialQuote))
import Data.ByteString (getLine)
import GHC.IO.Exception (ExitCode(ExitSuccess))
import Control.Exception (SomeException(SomeException))
import Control.Exception.Base (FixIOException(FixIOException))
import qualified Data.TCache.DefaultPersistence as TCache

-- import Control.DeepSeq
import Transient.Move.Internals (runAt)
import Data.TCache.Defs (Status(DoNotExist))

import Data.Data
-- import Debug.Trace

-- mainrerun = keep $ rerun "config" $ do
--   logged $ liftIO $ do
--      putStrLn "configuring the program"
--      putStrLn "The program will not ask again in further executions within this folder"

--   host <- logged $ input (const True)  "host? "
--   liftIO $ print "AFTER HOST"
--   port <- logged $ input (const True)  "port? "
--   endpoint

--   liftIO $ putStrLn $ "Running server at " ++ host ++ ":" ++ show port
--   node <- liftIO $ createNode host port
--   initWebApp node $ return()


{-

como la segunda conexion encuentra la closure?
   la segunda entra por listenNew
necesario identificar connections <-> flows. las conexiones reales cambian.
necesario identificar en la request un identificativo de flow= idConn del que creo el flow
   además, asociar la CONT correspondiente, con todo su state.
   como interactua esto con el resto del endpoint/restore1?
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
  endpoint/createflow  pone como nombre el nombre de la closure final
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
        -- let serial=  serialize (prevClos,getEnd $ partLog log,toLazyByteString $ getLogFromIndex ns  $ partLog log)
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
      _ ->  return ()

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


data HI=HI deriving (Read,Show,Typeable,Eq)
data HELLO=HELLO deriving (Read,Show,Typeable,Eq)
data WORLD=WORLD deriving (Read,Show,Typeable,Eq)
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

    -- tr ("CONTINUING",toPath $ partLog log)
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
    --             let end= getEnd $ partLog log

    --             let lc= LocalClosure{
    --                     localSession= idSession,
    --                     prevClos= prev, 
    --                     localLog= LD $ dropFromIndex ns $ partLog log,  
    --                     localClos=closLocal,
    --                     localEnd=end, 
    --                     localEvar= Just ev,localMvar=mv,localCont= Just cont} -- (closRemote',mv,ev,cont)
    --             -- setState $ PrevClos dblocalclos
    --             tr ("FULLLOG",partLog log)
    --             tr ("DROP",ns,dropFromIndex ns $ partLog log)
    --             return lc


    -- liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert closLocal pair map
    -- liftIO $ atomically $ writeDBRef dblocalclos pair

    -- tr ("writing closure",dblocalclos,prevClos pair)
    -- tr ("partLog in setCont", partLog log,recover log)


    -- return ()

-- deriving instance Generic  BS.ByteString
-- deriving instance FromJSON BS.ByteString
-- deriving instance ToJSON BS.ByteString 


mainnav= keep $ do
  (liftIO $ putStr "ONE ") `onBack` \(Navigation) -> do liftIO $ putStr "one " ; forward Navigation
  (liftIO $ putStr "TWO ") `onBack` \(Navigation) -> do liftIO $ putStr "two "
  (liftIO $ putStr "THREE ") `onBack` \(Navigation) -> do liftIO $ putStr "three "
  (liftIO $ putStr "FOUR ") `onBack` \(Navigation) -> do liftIO $ putStr "four "
  liftIO $ threadDelay 2000000 >> putChar '\n'

  back Navigation
  return ()

mainex= keep $ do
  onException $ \(e::SomeException) -> do liftIO $ putChar '1' ; continue
  onException $ \(e::SomeException) -> do liftIO $ putChar '2'
  onException $ \(e::SomeException) -> do liftIO $ putChar '3'
  onException $ \(e::SomeException) -> do liftIO $ putChar '4'
  liftIO $ putChar '\n'
  liftIO $ threadDelay 1000000
  error "error"
  return ()

newtype TestJSON= TestJSON [String] deriving (Generic,ToJSON,FromJSON)

instance TC.Indexable TestJSON where key= const "TestJSON"

rtext= getDBRef "TestJSON"
mainexp= keep' $ do
  liftIO $ do

     error "err"
     atomically $ writeDBRef  rtext $ TestJSON ["hello","world"]
     syncCache
     atomically $ flushDBRef $ rtext
     r <- atomically $ readDBRef  rtext
     liftIO $ print r

-- setEventCont2 :: TransIO a -> (a -> TransIO b) -> StateIO ()
-- setEventCont2 x f  = modify $ \EventF { fcomp = fs, .. }
--                            -> EventF { xcomp = x
--                                      , fcomp =  unsafeCoerce (\x -> tr "here2" >> f x) :  fs
--                                      , .. }

-- bind :: (Show a) => TransIO a -> MVar (Maybe a) -> (a -> TransIO b) -> TransIO b
-- bind x mv f = Transient $ do
--     setEventCont2 x  (\r -> do tr r; liftIO (tryPutMVar mv $ Just r); f r)
--     mk <- runTrans x
--     resetEventCont mk
--     tr "here"
--     case mk of
--       Just k  ->  runTrans (tr "JUST" >> liftIO (tryPutMVar mv $ Just k) >> f k)
--       Nothing ->  runTrans (tr "NOTHING"  >> empty)

-- synca :: Show a => TransIO a -> TransIO a
-- synca pr= do
--     mv <- liftIO newEmptyMVar
--     -- if pr is empty the computation does not continue. It blocks
--     (bind pr mv (const empty)) <|> do
--            r <- liftIO $(takeMVar mv) `catch` \BlockedIndefinitelyOnMVar -> return Nothing
--            case r of 
--              Just x -> return x
--              Nothing -> empty


mainsync= keep $ do
   r <-  sync (option1 "p" "p") <|> return ["ho"]
   tr ("RESP",r)



mainback1= keep $  do
  return () `onBack` \Navigation -> forward Navigation

  r0 <- inputNav (Just "1111") (const True) "one"
  r1 <- inputNav (Just False) (const True) "two"   :: TransIO Bool
  r2 <- inputNav (Just 3333) (const True) "three"  :: TransIO Int
  r3 <- inputNav (Just "4444") (const True) "four"
  r4 <- inputNav (Just "5555") (const True) "five"

  liftIO $ do print r0  ;  print r1 ; print r2 ;print r3; print r4

  liftIO syncCache
  back Navigation
  return ()








mainalter= keep $ unCloud $ do
  proc <|> restore1 <|> save

  where
  proc= do
    sal "HELLO" <|> (local abduce >> sal "WORLD")
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


mainsimple= keep $  initNode $ do
  -- firstCont
  -- logged $ logged $ do
  proc2 <|> restore1 <|> save


  where
  proc2= do
    logged $ option "p" "process"
    r <-loggedc $ loggedc $ do
          logged setc
          logged $ return HELLO -- liftIO $ print "PARSE ERROR"; error "PARSE ERROR" :: TransIO HELLO 
    localIO $ print r

    r <- loggedc $ loggedc $ do
            logged setc
            logged $ return (HI ,THAT)
    localIO $ print r

    showLog

mainexcept= keep $ initNode $ do
  r <-  local $ return "WORLD" `onException'` \(SomeException e) ->do
                liftIO (print "PASA")
                continue
                return "HELLO"
  showLog
  local $ return "HI"
  error "err"
  return ()

salutation= unsafePerformIO $ newIORef undefined

onSalutation  mx =  writeIORef salutation mx

main2= do
  onSalutation $ \s -> do
    putStr "hello "
    putStrLn s

  invocation "Alberto"
  invocation "Pepe"


invocation s= liftIO $ do
    proc <- readIORef salutation
    proc s

maininvoc= keep' $ installation <|> do
  async (invocation "Alberto") <|> async (putStrLn "some other text") <|> async (invocation "Pepe")
  liftIO $ print "something has been called in parallel"
  where
  installation= do
    s <- react onSalutation $ return ()
    liftIO $ putStr "hello "
    liftIO $ putStrLn s

-- foreign import ccall  ungetc :: Char -> Void Ptr  -> IO ()

mainraw= do
  putStrLn "--------------"

  hSetBuffering System.IO.stdin NoBuffering
  hSetEcho System.IO.stdin False
  x <-  hLookAhead System.IO.stdin
  -- print x

  hSetBuffering System.IO.stdin LineBuffering
  hSetEcho System.IO.stdin True

  -- wr <- System.IO.Streams.takeBytes 1 System.IO.Streams.Handle.stdin
  -- x <- System.IO.Streams.read wr
  -- liftIO $ print x
  -- unRead (BC.singleton x)  System.IO.Streams.Handle.stdin
  -- line <- System.IO.Streams.takeBytesWhile (/='\n') System.IO.Streams.Handle.stdin 
  line <- System.IO.getLine
  print line
  -- termattr <- getTerminalAttributes stdin
  -- let rawtermattr = withoutMode ProcessInput termattr
  -- setTerminalAttributes rawtermattr
  -- c <- getChar
  -- putStrLn c
  -- setTerminalAttributes termattr stdin

{-# NOINLINE ref #-}
ref= unsafePerformIO $ newIORef Nothing
runCont1 x= get >>= \(EventF{fcomp=f}) -> runTrans $ unsafeCoerce f x


mainsaad= do
  r <- keep'  $ return ()
  print r

maincont= runTransient $ do
  liftIO $ print "HELLO"
  r <- Transient $ do
      runCont1  "WORLD"
      runCont1 "WORLD2"
      return $ Just "WORLD3"
  liftIO $ print r


mainasas= keep $ do
  r <- threads 0 $ choose [1..10 :: Int]
  tr r

mainasda= keep' $ do
  res <- withParseString (BS.pack "go") $
                   (Just <$> ((,) <$> parseString <*> giveParseString)) <|> return Nothing
  liftIO $ print (res )

mainzxc= keep' $ do
  r <- return "HELLO " <> return "WORLD"
  tr r

mainasd= keep $ do
  -- onException $ \(e :: SomeException) ->  tr e
  -- r <- option "go" "go"  -- <|> option "ga" "ga"

  r <- react onFollow (return ()) <|> do  liftIO $ threadDelay 1000000;sched "Hello" ; empty

  liftIO $ print  (r :: String)

  -- error "err1"
  return ()
  where
  onFollow f= writeIORef ref $ Just f
  sched ev= liftIO $ do
    mf <- readIORef ref
    case mf of
      Nothing -> error "No callback handler"
      Just f -> f ev

maingold= keep' $ do
    amount :: Int <-   quantity * price
    newExchange <- liftIO $ readIORef newEx
    guard  newExchange -- avoid printing exchanges when price changes. only when quantities of gold are exchanged
    liftIO $ writeIORef newEx False
    liftIO $ putStrLn $ show amount <> "$ exchanged"
  <|> liftIO  externalInvocations

  where
  quantity :: TransIO Int
  quantity= do
    q <- react onQuantity $ return ()
    liftIO $ writeIORef newEx True
    liftIO $ putStrLn $ "quantity exchanged :" <> show q <> " ounces"
    return q

  price :: TransIO Int
  price= do
    p <- react onPriceChange $ return ()
    liftIO $ putStrLn $ "new price for gold: " <> show p
    return p

    -- All the rest should provided by the framework

  -- invoked by the framework
  externalInvocations :: IO()
  externalInvocations= do
      invoqueQuantity 10
      invoqueNewPrice 1000
      invoqueNewPrice 999
      invoqueQuantity (-10)
      invoqueQuantity 100

  newEx= unsafePerformIO $ newIORef False
  quantityCallback= unsafePerformIO $ newIORef Nothing
  priceChangeCallback= unsafePerformIO $ newIORef Nothing
  onQuantity callback= writeIORef quantityCallback $ Just callback
  onPriceChange callback= writeIORef priceChangeCallback $ Just callback

  invoqueQuantity amount= do
      cb <- readIORef quantityCallback
      when (isJust cb) $ (fromJust cb) amount

  invoqueNewPrice price=do
      cb <- readIORef priceChangeCallback
      when (isJust cb) $ (fromJust cb) price

mainexcepterr= keep  $ do

    -- abduce
    -- onFinish $ const $ tr "==============================FINISH"
    r <- return "WORLD" `onException'`  \(SomeException e) -> do
          continue

          option1 "c" "continue"
          return "PASA"
    tr r
    error "---------------------err"
    return ()

mainjob2= keep $ initNode $  do
  runJobs
  local $ option "go" "go"
  job $  localIO $ print "hello"
  job $ local $ option "c" "continue"  <|>( option "s" "stop" >> empty)
  job $  localIO $ print "world"

maincollect0= keep $ do
     option "go" "go"
     r <-    do
                topState >>= showThreads
                r <- collect 0 $ option1 "x" "x" <|> option1 "y" "y" <|> option1 "z" "z"
                topState >>= showThreads
                return r

     liftIO $ print ("r=",r)

mainenter= keep $ do
  option "go" "go"
  i <- input (< 10) "enter"
  liftIO $ print (i:: Int)

a <|||> b= (pr "abduce (" >>  a >> pr ")" >> empty) <|> b
infixr 3 <|||>


mainprior= keep' $ do
   term  "hello" <|||> term  "world" <|||> term  "hi"
  where
  term ::  String -> TransIO ()
  term  x= pr x

pr x= liftIO $ putStr x



mainlogdist= keep $ initNode $  go <|> restore1
  where
  runAt'' n x= loggedc $ do
      logged $ do id <- genPersistId; let nam= n <> "-1-" <> show id in setcn nam >> tr nam >> return nam
      r <- x
      logged $ do id <- genPersistId; let nam= n <> "-2-" <> show id in setcn nam >> tr nam >> return nam
      return r
  go=  do
    let node1="node1"; node2="node2";node3="node3"
    local $ option "go" "go"

    r <- runAt'' (node1) $ do
                  local $ tr "HELLO" >> return HELLO
                  ref <- onAll $ liftIO $  newIORef (0::Int) -- executes in node1(at exec time) and node2(recovery time)
                  r <- runAt'' (node2) $ do
                      onAll $ liftIO $ writeIORef ref 1      -- executes in node2
                      local $ return WORLD
                  tr ("1111",r)
                  runAt'' (node2) $ do
                      i <- onAll $ liftIO $ readIORef ref    -- executes in node2, keep the result of previous invocation
                      local $ return (HI,i)

    onAll $ liftIO $ assert (r== (HI,1)) $ ttr ("OK: non-mutable variables",r)

mainlogtests= keep $ initNode $  go <|> restore1
  where
  go=  do
    local $ option "go" "go"

    r <-loggedc $  do
          loggedc $ do
                    local $ setcn "two"
                    local $ return HELLO
          loggedc $ do
                    local $ setcn "three"
                    local $ return WORLD

    local $ setcn "four"
    local $ tr r


maincomplex = keep $ initNode $ inputNodes <|> do
  r <- proc2 <|> (restore1 >> empty)
  localIO $ print ("res",r)

  where
  proc2= (,) <$> proc3 HELLO <*> proc3 WORLD

  proc3 x =  do
    local $ tr "executing proc3"
    local $ option x $ "process " <> show x
    local $ setc

    return x

  proc1= proc "p1" <|> proc "p2"
  proc op= do
    logged $ option op ("process "++ op)
    r <- logged $ return HELLO

    logged $ liftIO $ putStrLn $ show r ++ op
    r <- loggedc $  loggedc $ logged $ return WORLD
    logged $ liftIO $ putStrLn $ show r ++ op
    loggedc $ do
        logged $ return PRE
        loggedc $ do
            logged $ return  PRE1
            logged setc
            logged $ return POST1
        logged $ return POSTT

    showLog

    logged $ return THAT

    r <- loggedc $  loggedc $ logged $ return WORLD

    logged $ liftIO $ putStrLn $ show r ++ op


    logged setc

    r <- logged $ return HI
    logged $ liftIO $ putStrLn $ show r ++ op

    showLog
    return op

save= logged $ do
    option "save" "save execution state"
    liftIO  syncCache
    empty

restoren= do
        option "res" "restore1"
        clos <- input (const True) "closure"

        noTrans $ restoreClosure 0 clos
        -- noTrans $ processMessage 0 clos 0 (BC.pack "closr") (Right mempty) False

restore1= logged $ do
        restoren
        empty

lprint :: Show a => a -> Cloud ()
lprint= localIO . print

setc =  do
    (lc,_) <-  setCont Nothing 0
    liftIO $ putStr  "0 ">> print (localClos lc)

setcn n=  do
    (lc,_) <- setCont (Just $ BC.pack n)  0
    liftIO $ putStr  "0 ">> print (localClos lc)

setcc= do
  setc
  option1 "c" "continue" <|> (option "n" "abort" >> empty)

showLog=do
  log <- getLog
  -- tr $ ("SHOWLOG",partLog log," ",toPath $ partLog log,"  ",toPathLon $ partLog log)
  onAll $ tr  ("SHOWLOG", partLog log)


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

main22= keep $  initNode $ proc  <|> restore1

  where
  proc= do
    logged $ option "go" "go" >> setc
    logged setc

main1= keep $ unCloud $ do
   onAll firstCont
   proc <|>  save <|>  restore1
 where
 proc= do
  logged $ option "go" "go"
  r <- loggedc $ loggedc $ loggedc $ do
              logged setc
              logged $ return HELLO

  logged $ liftIO $ print r

  r1 <- logged $ do
    setc
    return WORLD
  logged $ liftIO $ print (r,r1)
  log <- getLog
  tr ("partLog",partLog log)


-- mainfin= keep' $ do

--   onFinish $ \e-> liftIO $ print ("finish",e)
--   liftIO $ print "END"

-- rone= unsafePerformIO $ newIORef False
-- mainfinish= keep' $ do
--   abduce

--   cont <- getCont
--   onFinish $ const $ liftIO $ print "finish"

--   fork $ do  one <- liftIO $ readIORef rone
--              guard $ one == False
--              liftIO $ writeIORef rone True
--              (_,cont') <-liftIO $ runStateT (runCont cont) cont 
--              liftIO $ exceptBackg cont' $ Finish $ "job " <> show (unsafePerformIO myThreadId)
--              return()

--   --            return()
--   liftIO $ print "end"

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

mainremote= keep $ do
   (do d <- getState <|> return 0 :: TransIO Int
       tr ("-------",d)
       ((unCloud $ logged $ gets execMode >>= tr)  <***  setState  d ))  <** modify (\s -> s {execMode = Remote})
   tr "END"

{-
NOTA, usar delimitadores para algunos tipos de mensajes:
DELIM _____22323342340
conteheasd
asasda
asdsa
_____22323342340

local:
  en modo ejecucion, ejecuta el codigo y logea el resultado
  em modo recuperacion:
      si es en el log hay un resultado, lo devuelve
      si en el log hay un e/ lo ejecuta
      si hay un w/ devuelve empty
hacer un local que sea mas rapido y
      ejecute solo no esta en modo recuperacion
      no añada nada al log

wormhole                           wormhole
  teleport                            teleport
  logged mx                           logged mx
  teleport                            teleport
-}


maintransitive= keep $ initNode $ inputNodes <|> do
  local $ option "go" "go"
  nodes <- local getNodes
  tr ("nodes",nodes)
  r <- runAt (nodes !! 1) $ do
           localIO $ print "RECEIVED"
           h <- local $ return HELLO
           runAt (nodes !! 2) $ do
              localIO $ print "RECEIVED 2"
              local $ return (h,WORLD)
  tr r

shouldRunIn node = local $ do
                 p <-getMyNode
                 when ( p /= node) $ do
                   let msg= ("error: running at node: ",p, "should be",node)
                   tr msg
                   error $ show msg
                   exitLeft  msg



service= Service $ M.fromList
         [("service","test suite")
         ,("executable", "test-transient1")
         ,("package","https://github.com/agocorona/transient-universe")]

assertResult res expected= if res == expected
                              then liftIO $ print "OK"
                              else exitLeft $ "expected: "++ show expected ++ " but got: "++ show res



moderemote= modify (\s -> s {execMode = Remote}) :: TransIO ()
noSideRemote x = x <|> (moderemote >> empty)
  
    
{-
teleport ponerlo que siempre evite ejecuciones alternativas?
   pero eso no evita que lo que tiene en medio de teleport lo ejecute
poner el primer teleport en modo remoto el flag remoto y restaurarlo en el siguiente teleport
   pero la computacion remota de emmedio necesita ejecutar alternativos.

runat

crear abduceNoALternative 

abduceNoNewThread :: tnreads 0 abduce


-}

maindddd= keep' $ do
  f <|> tr "ALTER"
  
  where
  f= do
    abduce
    async $ tr "HELLO"
    async $ tr "WORLD"

maincond= do
  r <- keep' $ do
          setState (1 :: Int)
          setState "hello"
          sandboxDataCond (\_ _ -> Just (2:: Int)) $ do
             setState (3 :: Int)
             setState "world"

          (,) <$> (getState :: TransIO Int) <*> (getState :: TransIO String)
  print r


maintestlog= keep $ initNode $ go <|> restore1
  where

  go = do
          let node1="node1"
          r <- wormhole1 node1 $ do
                  r <- local $ return "HELLO"
                  teleport1 1
                  r <- local $ return (r,"WORLD")
                  teleport1 2
                  local $ return $ "return:" <> show r
                  return r
          onAll $ liftIO $ assert (r==("HELLO","WORLD")) $ ttr ("OK: wormhole, teleport composition",r)
    
          loggedc $ do

            ttr "------checking applicatives  with atRemote --------"

            r <- loggedc $ wormhole1 node1 $ do
                      let remoteReturn x= do
                                  -- PrevClos dbr _ _ <- onAll getState
                                  -- log <-  onAll $ noTrans $ getClosureLogFrom dbr dbClos0
                                  -- ttr ("LOG",log)
                                  r <- atRemote $ do
                                          local $ return x
                                  -- rem <- gets execMode
                                  -- tr ("REMOTE",rem,r)
                                  return r

                      remoteReturn "HELLO" <> remoteReturn "WORLD"
                    


            onAll $ liftIO $ assert (r== "HELLOWORLD") $ ttr ("OK: applicatives with atRemote",r)

    
teleport1 i = local $ do abduce ; setcn $ "teleport" <> show i
wormhole1 n x = loggedc $ do
        local $ return $ "wormhole" <> show n
        r <- x
        local $ return $ "endwormhole"<> show n
        return r

atRemote1 n x= do
  local abduce
  teleport1 n
  r <- x
  local $ return $ "return:" <> show r

  teleport1 $ n ++ n
  return r

mainmini= keep $ initNode  $ do
  local $ return HELLO
  onAll $ getLog >>= ttr

  loggedc  $ do
     void $ modifyState' (\(PrevClos a b c) -> PrevClos a True c) $ error "error"
     local $ return "pepe"

  local $ return WORLD
  onAll $ getLog >>= ttr


main= keep $ initNode $ do
    r <- liftCloud  (collect 2) $ local (async (return "HELLO")) <|> local(async (return "WORLD"))
    r' <- liftCloud  (collect 2) $ local (async (return "HELLO2")) <|> local(async (return "WORLD2"))
    ttr (r,r')


maintests= keep $ initNode $ inputNodes <|> do

    local $ option "go" "go"

    nodes <- local getNodes


    checkWormholeTeleportComposition nodes
    checkApplicativeWithRemote nodes
    checkAlternativesWithAtRemote nodes
    checkStreaming nodes
    empty
    checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller nodes
    checkAlternativeDistributed nodes
    checkApplicativeDistributed nodes
    checkMonadicDistributed nodes
    checkReentrantDistributed nodes
    checkNonSerializableMutableVariables nodes
    checkMapReduce nodes
    where
    checkWormholeTeleportComposition (node0:node1:node2:_)= loggedc $ do

          ttr "------checking wormhole, teleport composition --------"

          r <- wormhole node1 $ do
                  shouldRunIn node0
                  r <- local $ return "HELLO"
                  teleport
                  shouldRunIn node1
                  r <- local $ return (r,"WORLD")
                  teleport
                  shouldRunIn node0
                  return r
          onAll $ liftIO $ assert (r==("HELLO","WORLD")) $ ttr ("OK: wormhole, teleport composition",r)
    
    checkApplicativeWithRemote (node0:node1:node2:node3:_)= loggedc $ do

          ttr "------checking applicatives  with atRemote --------"
          r <- loggedc $ wormhole' node1 $ do
                    let remoteReturn x= do
                                r <- atRemote $ do
                                        ttr "REMOTERETURN"
                                        shouldRunIn node1
                                        local $ return x
                                shouldRunIn node0
                                rem <- gets execMode
                                tr ("REMOTE",rem,r)
                                return r

                    loggedc $ remoteReturn "APPLI" <> remoteReturn "CATIVE"


          onAll $ liftIO $ assert (r== "APPLICATIVE") $ ttr ("OK: applicatives with atRemote",r)
          return r

    checkAlternativesWithAtRemote (node0:node1:node2:node3:_)= loggedc $ do
          ttr "------checking alternatives  with atRemote --------"

          r <- liftCloud (collect 2) $ wormhole' node1 $ do
                    let remoteReturn x= atRemote $ do
                            shouldRunIn node1
                            local $ return x

                    remoteReturn "ALTER" <|> remoteReturn "NATIVE" 

          onAll $ liftIO $ assert (sort r== ["ALTER","NATIVE"]) $ ttr ("OK: alternatives with atRemote",r)
          return r

    checkStreaming (node0:node1:node2:node3:_)= loggedc $ do

          ttr "------checking streaming --------"

          r <- liftCloud (collect 2) $ wormhole node1 $ do
                  atRemote $ do
                    shouldRunIn node1
                    local $ async (return "%STRE") <|> async (return "AMING")

          onAll $ liftIO $ assert (sort r== ["%STRE","AMING"]) $ ttr ("OK: streaming",r)


    checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller (node0:node1:node2:node3:_)= loggedc $ do

          onAll $ liftIO $  putStrLn "------checking  empty in remote node when the remote call back to the caller #46 --------"

          r <- runAt node1 $ do
                    shouldRunIn (node1)
                    runAt node2 $ runAt node1 (shouldRunIn (node1) >> empty)  <|>   (shouldRunIn (node2) >> local (return "world"))

          -- on every node that executes this, this assertion should be true
          onAll $ liftIO $ assert (r== "world") $ ttr ("OK: empty in remote",r)


    checkAlternativeDistributed (node0:node1:node2:node3:_)= loggedc $ do

          ttr "------checking Alternative distributed: distributed parallelism --------"
          r <- liftCloud (collect 2) $
                              runAt node1 (shouldRunIn (node1) >> return "hello" ) <|>
                              runAt node2 (shouldRunIn (node2) >> return "world" ) -- <|>
          --                     runAt node3 (shouldRunIn(node3) >> return "world2")

          onAll $ liftIO $ assert (sort r== ["hello", "world"]) $   print ("OK: alternative distributed",r)





    checkApplicativeDistributed (node0:node1:node2:node3:_)= loggedc $ do

          ttr "--------------checking Applicative distributed: distributed concurrency--------"

          r <-   loggedc $ runAt node1 (do shouldRunIn ( node1) ; localIO $ do print "HELLO";return "HELLO ")
                    <>  (runAt node2 (shouldRunIn ( node2) >> return "WORLD " ))
                    -- <>  (runAt node3 (shouldRunIn( node3) >> return "WORLD2" ))

          onAll $ liftIO $ assert (r== "HELLO WORLD ") $  print ("OK: applicative distributed",r)
          


    checkMonadicDistributed (node0:node1:node2:node3:_)= loggedc $ do

          ttr "----------------checking monadic, distributed-------------"
          r <-  runAt node1 $ do
                  shouldRunIn (node1)
                  r <- local $ return "HELLO"
                  runAt node2 $ do
                    shouldRunIn (node2)
                    return $ r ++ "WORLD"

                  --   runAt node3 $ do
                  --     shouldRunIn(node3)
                  --     return "WORLD" 


          onAll $ liftIO $ assert (r== "HELLOWORLD") $  print ("OK: monadic distributed",r)

    checkReentrantDistributed (node0:node1:node2:node3:_)= loggedc $ do
          ttr "------------- checking reentrant distributed ----------------"

          r <- runAt node1 $ do
                  shouldRunIn (node1)
                  r <- local $ return "HELLO"
                  runAt node2 $ do
                    shouldRunIn (node2)
                    r <- local $ return (r,"WORLD")
                    runAt node1 $ do
                      shouldRunIn (node1)
                      r <- local $ return (r,"WORLD2")
                      runAt node2 $ do
                        shouldRunIn (node2)
                        return r

          onAll $ liftIO $ assert (r== (("HELLO","WORLD"),"WORLD2")) $  print ("OK: reentrant distributed",r)

    checkNonSerializableMutableVariables (node0:node1:node2:node3:_)= loggedc $ do

          ttr "---checking that non serializable mutable variables in the stack are keept across sucessive invocations ---"

          r <- runAt (node1) $ do
                  h <- local $ return HELLO
                  ref <- onAll $ liftIO $  newIORef (0::Int) -- executes in node1(at exec time) and node2(recovery time)
                  r <- runAt (node2) $ do
                      onAll $ liftIO $ writeIORef ref 1      -- executes in node2
                      local $ return (h,WORLD)
                  runAt (node2) $ do
                      i <- onAll $ liftIO $ readIORef ref    -- executes in node2, keep the result of previous invocation
                      local $ return (r,WORLD,i)
          
          onAll $ liftIO $ assert (r== ((HELLO,WORLD),WORLD,1)) $ ttr ("OK: non-serializable, mutable variables",r)

    checkMapReduce (node0:node1:node2:node3:_)= loggedc $ do

          ttr "----------------checking map-reduce -------------"

          r <- reduce  (+)  . mapKeyB (\w -> (w, 1 :: Int))  $ getText  words "hello world hello"
          onAll $ liftIO $ assert (sort (M.toList r) == sort [("hello",2::Int),("world",1)]) $ ttr ("OK: mapReduce",r)


runAt' node mx = wormhole node $ atRemote' mx


atRemote' mx = do
  teleport
  r <- mx
  teleport
  return r

-- endpoint'= endpoint . Just . BC.pack
  -- Señor, Gracias por todo lo que me das. Dame las gracias necesarias para servirte.

-- añadir a 
mainxxx= keep $ initNode $ inputNodes <|> do
  local $ option "go" "go"
  nodes <- local getNodes
  -- r <- local $ collect 1 $   unCloud $  runAt (nodes !! 1) (return "WORLD ") 
  -- tr ("alternative",r)
  -- tr "=============================================="
  -- r <- runAt (nodes !! 1) (return "WORLD ") 
  -- tr("applicative",r)
  -- empty
  r <- runAt (nodes !! 1) $ do
                  localIO $ print "RECEIVED"
                  h <- local $ return HELLO
                  ref <- onAll $ liftIO $  newIORef (0::Int)
                  runAt (nodes !! 2) $ do
                      onAll $ liftIO $ writeIORef ref 1
                      localIO $ print "RECEIVED 2"
                      local $ return (h,WORLD)
                  runAt (nodes !! 2) $ do
                      i <- onAll $ liftIO $ readIORef ref
                      localIO $ print "RECEIVED 3"
                      local $ return (h,WORLD,i)
  tr r

mainkeep= keep $ do
  return () `onBack` \() ->   forward ()
  liftIO $ print "HELLO"
  back ()
  return ()

maintrans= runTransient $ do
        r <-  return "HELLO"
        liftIO $ print r
        r <-  return ("WORLD",r)
        liftIO $ print r




mainlog= keep' $ unCloud $ do
  proc
  log <- getLog
  onAll $ liftIO $ print $ partLog log
  onAll $ setParseString $ toLazyByteString $ partLog log
  modifyState' (\log -> log{recover=True,partLog=mempty}) (error "error")
  proc
  log <- getLog
  onAll $ liftIO $ print $ partLog log

  where
  proc= do
    logged (do tr "empty"; empty) <|> logged (do tr "HELLO";return HELLO)
    logged $ return WORLD



mainjob3 = keep $ initNode $ do
  runJobs

  str <-minput ("s" :: String) "start"
  localIO $ putStrLn str


  ev <- onAll $ liftIO $ newIORef []
  minput "input" "test" :: Cloud ()



  --  minput "input2"  "test2" :: Cloud()
  job (process ev) <|> report ev

  where
   process ev= do
    i <- local $ threads 1 $ choose [(1 :: Int)..]
    localIO $ threadDelay 10000000
    localIO $ atomicModifyIORef ev $ \l -> (i:l,())
    empty
    return ()

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
--       M.insert partLog log str paths
--       setRState pa <> "/" <> str

-- get all the options of a user
-- allOptions user= do
--   ns <- allReg localSession .==. user
--   let url n= str "http://" <> str (nodeHost n) <> str ":" <> intt (nodePort n) </>    
--                                     intt (localSession n) </> intt (localClos n) </> 
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
  readev1 ev <|> readev2 ev <|>    do   liftIO $ threadDelay 5000000 ; return ()
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

    r <- threads 0 $ choose [1..2]
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

  return ()

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
  return ()


mainerr= keep  $ initNode $ local $ do
  abduce
  topState >>= showThreads
  onFinish $ const $ tr "==============================FINISH"

  -- onException $ \(e:: SomeException) -> throwt e
  throw $ ErrorCall "---------------------err"
  return ()






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
   ac  `catcht` \(e :: SomeException) -> return ()
   i <- getState
   liftIO $ print (i :: Bool)
   where
   ac=  sandbox $ do
    liftIO $ print "inter"
    sandbox $ do
      setState True
      throwt $ ErrorCall "err"



mainappl= keep $ initNode $ inputNodes <|> do
  local $ option "go" "go" -- ::Cloud ()
  nodes <- local getNodes
  r <- local (async (return "world local")) <> do onAll $ tr "runAt" ; runAt (nodes !! 1) (proc ) -- <|> runAt (nodes !! 2) (proc )

  localIO $ print r
  where
  proc = do
      node <- local getMyNode
      localIO $ print $ "hello from " <> show node
      return $ "world "  ++ show node




mainauction = keep $ initNode $ do

    setIPFS

    POSTData (wallet :: Integer,name :: String) <- minput "enterw"  "enter wallet"
    setSessionState wallet
    guessgame name wallet <|> auction
    return ()

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


maintest = keep $ initNode $ test <|>  restore1
  where
  test= do
    -- POSTData (name :: String, wallet :: Integer) 
    -- local $ option "s" "start"

    i :: Int<- minput "enterw"  "enter wallet" -- (11 :: Int)
    guessgame
    return ()

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
            unCloud $ logged $ error "not enough parameters 2" -- read the response, error if response not logged
          else do
            receivee conn (Just $ BC.pack ident)  val
            unCloud $ logged $ error "insuficient parameters 3" -- read the response

      tr ("MINPUT RESULT",idcontext',result)
      return result `asTypeOf` return (type1 response)


    type1 :: Typeable a => Cloud a -> a
    type1 cx = r
      where
        r = error $ show $ typeOf r

receivee conn clos  val= do
  (lc, log) <- setCont clos 0
  s <- giveParseString
  -- tr ("receive PARSESTRING",s,"LOG",toPath $ partLog log)
  if recover log && not (BS.null s)
    then (abduce >> receive1 lc val) <|> return () -- watch this event var and continue restoring
    else  receive1 lc val

  where
  -- receive1 :: (Loggable val) => LocalClosure -> val -> TransIO ()
  receive1 lc val= do


      setParseString $ toLazyByteString  (lazyByteString (BS.pack "0/") <> (serialize val)) :: TransIO ()
      -- setLog 0 (lazyByteString (BS.pack "0/") <> (serialize val)) 0 0 :: TransIO()




maindistrib = keep $ initNode $ inputNodes <|> do
    local $ option "g" "go"
    nodes <- local getNodes
    r <-  runAt (nodes !! 0) (proc "HELLO") <> runAt (nodes !! 1) (proc "WORLD")
    localIO $ print r

    where
    proc x= do
         localIO $ print x
         return x


-- yield that manages blocking tasks
type Task a=  TransIO a
data Yield = forall a.Yield EventF (TransIO a) deriving Typeable

-- | Yields the execution to other tasks and gives some blocking procedure that must 
-- be executed before the task could be awakened again.
yield' :: TransIO a -> TransIO a
yield' task = Transient $ do
  cont <- get
  runTrans $ putMailbox $ Yield cont task
  return Nothing


-- | Runs the scheduler in a single thread.reads yielded continuations from the
-- mailbox queue, execute the blocking task and re executes the continuation
-- if there are more threads available, there will be more parallelism.
-- ideally it should be as much threads as the number of blocking tasks
scheduler= threads 2 $ do
    Yield cont task <- getMailbox
    r <-  task
    liftIO $ runCont' r cont
    empty


mainyield= keep' $ (abduce >> scheduler) <|>  do
  yi 2  <|> yi 1
  where
  yi (i :: Int)= do
    yield' $ return ()
    tr ("before",i)
    l <- yield' $ liftIO $ do threadDelay $ i* 1000000 ; return i
    tr ("after",l)

mainabduce= keep' $ threads 2 $ p 1 <|> p 2
  where
  p i= do
    tr ("before",i)
    abduce
    liftIO $ threadDelay $ 1000000
    tr ("after",i)

mainbuff= keep' $ do
  s <- threads 1 $ buffered $ threads 1 $ waitEvents System.IO.getLine
  liftIO $ threadDelay 5000000
  liftIO $ putStrLn s
  where
  buffered asyncproc= do
    ev <- newEVar
    readEVar ev <|> (asyncproc >>= writeEVar ev >> empty)


-- maincont= keep' $ do
--   cont <- getCont
--   case event cont of
--     Nothing -> do
--        setData cont{event=Just ()}
--        liftIO $ runCont' cont
--        return ()
--     Just r -> do
--       tr "just"
--       setData cont{event=Nothing}
--       liftIO $ print r

--   return HELLO


mainmzero= keep $ do
  r <- async (error "err") `onAnyException` \(e :: SomeException) -> do liftIO $ print e; backtrack
  tr (r :: StreamData String)
  return ()


maindsdds= time $  tr $ filter isPrime [1..10000]


isPrime :: Int ->  Bool
isPrime n =  n== 1 || all (\i-> n `mod` i /= 0) [2..floor (sqrt $ fromIntegral n)::Int]

time f = do
    start <- getCPUTime
    f
    end <- getCPUTime
    putStrLn $ "Execution time: " ++ show (fromIntegral (end - start) / 1e12) ++ " segundos"


mainprimes= time $ keep' $  threads 4 $ do
  l <- collect 0 $ do
          i <- choose' [1000000000..10000000000]
          !r <- guard (isPrime i)
          return r
  tr l

mainsum= time $ keep' $  threads 4 $ do
  l <- collect 0 $ do
          i <- choose' [1..1000000]
          !r <- sum [1,1000000]
          return r
  tr l

mainstrict=  do
  r <- keep' $ do
     l <- collect 0 $ let !s=  sum [1..100000000 :: Integer]  in  return s
     tr l
  tr r

mainkk= do
  mv <- newEmptyMVar
  -- do not print in ghc 9.4.2
  forkIO $ print (sum [1..10000000000 :: Integer])   ; putMVar mv ()
  takeMVar mv

mainasunasd= keep' $ do
   let x= 100000000000 :: Integer
   r <- async (let !r= sum [1.. x]in return r) <|>
        async (let !r= sum [1.. x]in return r) <|>
        async (let !r= sum [1.. x]in return r) <|>
        async (let !r= sum [1.. x]in return r)
   tr r

mainasssas= keep' $ do
      s <- choose [1,2,3,4] -- abduce' <|> abduce' <|> abduce' <|> abduce'
      tr "thread"
      let !r= sum [1.. 100000000]
      tr r
      where
      abduce'= do
        abduce
        liftIO $ myThreadId >>= tr
        return ()

mainasddsd= do
  rr1 <- newEmptyMVar
  rr2 <- newEmptyMVar
  forkIO $ putMVar rr1 $ sum [1..100000000000::Integer]
  forkIO $ putMVar rr2 $ sum [1..100000000000::Integer]
  takeMVar rr1 >>= tr
  takeMVar rr2 >>= tr

data A= A Int String String deriving (Typeable,Read,Show)

instance TC.Indexable A where
   key (A k _ _)= show k

-- instance NFData A where
--   rnf (A a b c)= rnf a `seq` rnf b `seq` rnf c

instance TCache.Serializable A where
  serialize = BS.pack . show
  deserialize= {-force .-} read . BS.unpack


newr reg@(A i _ _)=  writeDBRef (getDBRef $ show i) reg

maindbref= do
  r <- keep $ do
    option "go" "go"
    i :: Int <- input (const True) "give i"
    liftIO $ atomically $ mapM newr [ A i "hello" ( show $ unsafePerformIO myThreadId)  | i <- [0..1000]]
    liftIO $ print "end"

    k <- threads 0 $ choose [0..100]

    liftIO $ atomically $ forM [0..1000] $ \i -> do
        let dbr= getDBRef $ show i
        mx <- readDBRef dbr
        th' <- unsafeIOToSTM myThreadId
        writeDBRef dbr $ A i  (show k) (show th')
    return ()
  liftIO $ print r










instance MonadFail STM where
  fail s= error "fail"


-- teleport' :: Cloud ()
-- teleport' =  do 
--   tr "TELEPORT'"
--   modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}

--   local $ do
--     -- abduce
--     s <- giveParseString

--     log <- getLog
--     tr ("IN TELEPORT, recover, null parseString:", recover log, BS.null s)

--     PrevClos idsess prevclos _ <- getData `onNothing` error "teleport: no prevclos" -- return (PrevClos  0 "0" False)
--     idSession <- if idsess /= 0 then return idsess else  fromIntegral <$> genPersistId

--     conn@Connection {idConn = idConn, connData = contype, synchronous = synchronous} <-
--               getData
--                 `onNothing` error "teleport: No connection defined: use wormhole"
--     tr ("teleport REMOTE NODE", fmap  nodePort $ unsafePerformIO $ readIORef $ remoteNode conn, idConn  )

--     lc <- setCont' (partLog log) (BC.pack $ show $ hashClosure log) idSession
--     -- cuando el ultimo /e es ejecutado
--     when (not $ BS.null s) $ do
--       tr "SET CLOSTORESPOND AND SETINDEXDATA"
--       setState $ ClosToRespond idsess (localClos lc)
--       setIndexData idConn  (Closure idsess (localClos lc) []) 
--       return ()

--     tr ("PREVCLOS",idsess,prevclos)






--         --  labelState  "teleport"


--     when (not $ recover log) $ do
--         -- when a node call itself, there is no need for socket communications
--         ty <- liftIO $ readIORef contype
--         case ty of
--           Just Self -> do
--             modify $ \s -> s {execMode = Parallel} -- setData  Parallel
--             -- wormhole does abduce now
--             abduce
--             -- call himself
--             tr "SELF"
--             liftIO $ do
--               remote <- readIORef $ remoteNode conn
--               writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote
--           _ -> sandboxSide [] $ do
--             -- tr ("teleport remote call", idConn)
--             (sessRemote, closRemote) <-
--                   do
--                   ClosToRespond s c <- getState
--                   tr ("after ClosToRespond",s,c)
--                   delState $ ClosToRespond s c
--                   return (s,c)
--                 <|> do
--                   tr ("getting closure for idConn",idConn)
--                   (Closure s c _) <- getIndexState idConn
--                   tr ("after getIndexState",s,c)
--                   return (s,c)
--                 <|> do
--                   tr "return 0 0"
--                   return (0,BC.pack "0")
--             -- (Closure sessRemote closRemote n) <- getIndexData idConn `onNothing` return (Closure 0 "0" [])
--             -- tr ("getIndexData", idConn, sessRemote, closRemote, n)
--             let prevclosDBRef= getDBRef $ kLocalClos idsess prevclos
--             -- calcula el log entre la ultima closure almacenada localmente (prevclos) y el punto que el nodo ya ha recibido (closremote) 
--             prevlog <- noTrans $ getClosureLogFrom prevclosDBRef sessRemote  closRemote
--             let tosend =  prevlog <> partLog log

--             let closLocal = BC.pack $ show $ hashClosure log

--             do
--               msend conn $ toLazyByteString $ serialize $ SMore $ ClosureData closRemote sessRemote closLocal idSession tosend
--               tr ("RECEIVER NODE", unsafePerformIO $ readIORef $ remoteNode conn, idConn )

--               receive1' lc
--               tr "AFTER RECEIVE"
--   return ()


-- receive conn clos idSession = do
--   tr ("SETCONT TO RECEIVE",unsafePerformIO $ readIORef $ remoteNode conn,clos, idSession)
--   (lc, log) <- setCont clos idSession
--   receive1' lc



-- receive1' lc = do
--       tr "RECEIVE1'"
--       -- when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc 
--       -- tr ("EVAR waiting in", localSession lc, localClos lc)
--       mr <- readEVar $ fromJust $ localEvar lc

--       -- tr ("RECEIVED", mr)

--       case mr of
--         Right (SDone, _, _, _)    -> empty
--         Right (SError e, _, _, _) -> error $ show ("receive:",e)
--         Right (SLast log, s2, closr, conn') -> do
--           -- cdata <- liftIO $ readIORef $ connData conn' -- connection may have been changed
--           -- liftIO $ writeIORef (connData conn) cdata
--           setData conn'
--           -- tr ("RECEIVED <------- SLAST", log)
--           setLog' (idConn conn') log s2 closr
--         Right (SMore log, s2, closr, conn') -> do
--           -- cdata <- liftIO $ readIORef $ connData conn'
--           -- liftIO $ writeIORef (connData conn) cdata
--           setData conn'
--           -- tr ("receive REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn,idConn conn)
--           -- tr ("receive REMOTE NODE'", unsafePerformIO $ readIORef $ remoteNode conn',idConn conn')

--           setLog' (idConn conn') log s2 closr
--         Left except -> do
--           throwt except
--           empty

-- setLog' :: (Typeable b, Ord b, Show b) => b -> Builder -> Int -> BC.ByteString -> TransIO ()
-- setLog' idConn log sessionId closr = do
--   tr ("setting log for",idConn,"Closure",sessionId, closr )
--   setParseString $ toLazyByteString log

--   modifyData' (\l -> l {recover = True}) emptyLog
--   return ()