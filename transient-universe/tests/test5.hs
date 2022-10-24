
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB=/projects/transient-stack/ && ghc  -DDEBUG -threaded  -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1 && ./`basename $1 .hs` ${2} ${3}

-- mkdir -p ./static && ghcjs --make   -i../transient/src -i../transient-universe/src -i../transient-universe-tls/src  -i../axiom/src   $1 -o static/out && runghc   -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}
-- 

-- cd /projects/transient && cabal install -f debug --force-reinstalls && cd ../transient-universe && cabal install --force-reinstalls &&  runghc $1 $2 $3 $4

{-# LANGUAGE ScopedTypeVariables, FlexibleInstances, OverloadedStrings,ExistentialQuantification #-}
{-# LANGUAGE DeriveGeneric,DeriveAnyClass #-}
module Main where

import Transient.Base
import Transient.Console
import Transient.Move.Internals
import Transient.Move.Web hiding (minput)
import qualified Transient.Move.Web as Web(minput)
import Transient.Parse
import Transient.Internals
import Transient.Move.Utils
import Transient.Parse
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.State
import qualified Data.Vector as V hiding (empty)
import Control.Concurrent
import Transient.EVars
-- import Transient.Move.Services
import Transient.Mailboxes
import Transient.Indeterminism
import Data.TCache hiding (onNothing)
import System.IO.Unsafe
import Data.IORef
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Typeable
-- import Data.TCache.DefaultPersistence
import Data.Default
import Data.Aeson
import GHC.Generics
import Data.List
import Data.Char

-- main2= keep $ do 
--      i <- threads 0 $ choose[0..]
--      abduce
--      liftIO $ threadDelay 1000000

--      liftIO $ print (i :: Int)

-- main5= keep' $ initNode $ do
--     result <- local $ heavycomputation
--     teleport
--     str <- local $ return "firstparam"
--     str2 <- local $ return "secondparam"
--     showURL
--     process result str str2
--     teleport
--     where
--     heavycomputation= return "heavycompresult"
--     process result  str str2= local $ return  $ result++ str++str2

-- main3 = keep $ initNode $ hi "hello" <|> hi "world"
--   where
--   hi text= do
--      showURL
--      localIO $ putStrLn text
--      teleport  <** modify (\s -> s{execMode=Remote})
    {- 
main4 = do initTLS; keep $ initNode $ inputNodes <|> hi
  where
  ps= onAll $ do
            conn <- getSData
            sdata <- liftIO $ readIORef $ connData conn
            case sdata of
                Just (HTTPS2Node _) -> liftIO$ print "SSL XXXXXXXXXXXXXXXXXXX"

                Just (TLSNode2Node _) -> liftIO$ print "SSL XXXXXXXXXXXXXXXXXXX"
                _ -> liftIO $ print "NOSSL YYYYYYYYYYYYYYYYYYY"
  hi = do
        ps 
        showURL
        localIO $ putStrLn "hello"
        let x= "hello "
        ps
        teleport
        showURL 
        localIO $ print $ x ++ "world"
        teleport
        
-}



str2= "0001\r\n2\r\n0\r\n\r\n"

-- main= keep $  do
--   setParseString "333"
--   string "333e" <|> return ""
  
--   snap <- withParseString str2 $ do
--      dechunk |- int

--   liftIO $ print snap
  



minput ::  (Loggable a, ToRest a) => String -> String -> Cloud a
minput a b= Web.minput a (BS.pack b)

data HELLO= HELLO deriving (Read,Show)
instance Loggable HELLO

data WORLD= WORLD deriving (Read,Show)
instance Loggable WORLD

data WORLD2= WORLD2 deriving (Read,Show)
instance Loggable WORLD2

save= local $ do
    option ("save" :: String) "save execution state"
    liftIO syncCache

data INTER= INTER deriving (Read,Show)

instance Loggable INTER





main= keep $ initNode $ do
    id <- minput "id" "enter your id"
    (number::Int) <- minput "lock" "enter a lock number"
    tr ("LOCK NUMBER RECEIVED=", number)
    -- ventaja: el almacenamiento del lock number es automático
    number' <- minput ("g" ++ id)  $ "guess " ++ id ++ " number"
    tr ("GUESS NUMBER RECEIVED=", number')

    minput "" (if number== number' then "YES" else "NO") :: Cloud()

mainpost= keep $ initNode $ do
  (str,POSTData test) <- minput "id" "enter a string and a test value "
  minput "next" "next step" :: Cloud ()
  localIO $ print (str:: String, test :: Test)


{-
AHora es un entorno multiusuario. No deben verse las opciones que no son propias
Como restringir ? el usuario solo debe ver las opciones creadas por encima de el, no las laterales
las URL se presentan secuencialmente o acumulativamente?
    en el primer caso, el frontend almacena URLS
        no tiene en cuenta opciones creadas por otros browsers/usuarios
    en el segundo, todas las opcioneslas suministra el backend
        necesita saber cuales son las opciones siguentes
  
  mezcla de los dos:
    presentar secueencialmente
    opcion de pedir todas las opciones disponibles que ahora son todas las ejecutadas
    en el caso de consola asi es. el cliente puede saltarse el flujo como ocurre el consola
       como evitar que se presenten opciones que no corresponden a ese usuario?
         por ejemplo el guess tiene que acceder a todos los locks de distintos usuarios pero en algunos casos hay que filtrar?
         se pueden pedir seleccionar por usaurio (sesiom) los que esten en su estado
           en realidad se está haciendo uso de una estructura de datos que existe la de callbacks de consola
           si se crea una nueva estructura, puede almacenar también continuaciones (URLs)
             se tiene la flexibilidad de poder seleccionar a gusto de la app y el almacenamiento de variables en el stack de la cont
-}



mainequal= keep $ initNode $ do

    -- r <- minput "x" "init2" :: Cloud String
    -- localIO $ print r
    -- tienen igual el hash de closure:
    r <- ((local abduce :: Cloud ()) >> local empty <|> minput "a" "a" ) <|> do local $return() ;minput "b" "b"
    localIO $ putStrLn r

mainsimple= keep $ initNode $ do
  s <- minput "s1" "una string"
  local $ do
    log <- getLog
    ttr ("LOG after MINPUT", toPathLon $ fulLog log)
  setState s
  s2 <- minput "s2" "otra string"
  local $ do
    log <- getLog
    ttr ("LOG after MINPUT", toPathLon $ fulLog log)
  caller <- local getSessionState
  rec <- local getState
  localIO $ print (s :: String, s2 :: String)
  localIO $ print (caller :: String, rec :: String)

{-
Locks debe recuperarse
acceder al contexto del llamante
usar el stack como almacenamiento para locks y tcache?
  NO: estarian repetidos en cada stack de ejecucion
-}
-- locks = getDBRef "lockList"
-- instance Indexable [InputData] where
--   key= const "lockList"
{-
como hacer post de JSON
minput que solo coja el get.
que parsee el cuerpo 
alternativamente, que ensaye parse de post
-}

mainsimplw= keep $ initNode $ Cloud $ restore1 <|> do
      -- onAll $ ttr "MINPUT"
      -- r <- minput "go" "go"
      -- localIO $ putStrLn r
      -- log <- getLog
      -- localIO $ print (fulLog log,toPath $fulLog log,toPathLon $ fulLog log)


  r <- logged $ do
        setParseString "HELLO/WORLD/"
        log <- getLog
        setCont Nothing 0
        setState $ log{recover=True}
        setCont Nothing 0
        (x,y) <-  logged $ return (HELLO, WORLD)
        return y
  liftIO $ print r
  log <- getLog
  liftIO $ print (fulLog log,toPath $fulLog log,toPathLon $ fulLog log)

restore1= do
        option "res" "restore1"  :: TransIO String
        s    <- input (const True) "sesion  >"
        clos <- input (const True) "closure >"
        noTrans $ restoreClosure s clos

{-
minput que soporte entrada post
 como se dicta que tenga post?
 con se manda una URL con post?
   mandar todo: la URL y el header con un ejemplo JSON
       ejemplo json con Data.Default
         haskellData <- minput
         process toJson def :: HaskellData
         para que una parte solo se envie como POST
           (a,b, POST C) <- minput  
             instance toREST (POST a) where
                modifyState BODY x -> BODY process toJSON def
                return ""
            data POST= POST forall a(Default a,Typeable a)=> a
            
           buscar campos del JSON generado y sustituirlo por $campo
            o ir por campos:
              type : GET default, POST
              url
              headers
              body (JSON)
        cuando llega el POST:
         parsear los campos get
         mirar si hay post  

-}
-- newtype BODY= BODY [BS.ByteString] deriving (Typeable,Show)
-- newtype POSTD a=   POSTD a deriving (Typeable, Show ,Read)
-- instance (Typeable a, Read a, Show a) => Loggable (POSTD a)
-- instance (Typeable a, Show a, Read a,Default a,ToJSON a) => ToRest (POSTD a) where
--   toRest (POSTD x)= do
--     nelem <- process $ encode (def `asTypeOf` x)
--     return mempty{reqbody=nelem}
--     where
--     process ::  BS.ByteString -> TransIO BS.ByteString
--     process s= do
--       frags <- withParseString s $ many $ do
--                 prev <- tTakeUntilToken "\""
--                 var <- tTakeUntilToken "\""
--                 val <- chainManyTill BS.cons anyChar ( sandbox $ tChar ',' <|> tChar '}')
--                 sep <- anyChar -- tChar ',' <|> tChar '}'

--                 return $  prev <> "\"" <> var <> "\":" <> "$" <> var <> BS.singleton sep
--       return $ BS.concat frags
--       -- where
--       -- mod var val =
--       --   if BS.head val == '\"' then "\"" <> "$" <> var <> "\""  else "$" <> var

-- data Test= Test{a:: Int} deriving (Generic,Show,Read,Typeable)


-- instance ToJSON Test

-- instance Default Test

mainpar=   keep $ do r <- opval  1  * opval 2 ; liftIO $ print ("result",r :: Int)
  where
  opval op = option (op :: Int) ("parameter " ++ show op) >> input (const True) "val?"


data Test= Test{field1 :: String, field2 :: Int} deriving (Generic,Default,ToJSON, FromJSON)
data Test1= Test1{f1 :: [Int],f2 :: String} deriving (Generic,Default,ToJSON, FromJSON)

maingame= keep $ initNode $ do
  local $  newRState ([] :: [InputData]) >> return ()
  id :: String   <- minput "id" "enter your id "
  newSessionState id
  id' <- local getSessionState <|> return "NO CALLER"
  localIO $ print ("CALLER",id' :: String)
  myGameSequence id  <|> otherGames
  where
  myGameSequence id= do
    
    number ::String <- minput "lock" "enter a lock number"
    local $ ttr (id :: String,"locked",number)
    number' <- minput ("guess"++ id) ("guess a number for user " ++ id)  <|> addToOptions
    id' <- local $ getSessionState <|>  return "no caller state"
    localIO $ print (number, number')
    (minput ""  $ if number== number' then id' ++ " guessed the number of " ++ id else "NO") :: Cloud ()

  addToOptions :: Loggable a => Cloud a
  addToOptions=  do
        idata :: InputData <- local getState
        -- liftIO $ atomically $ do
        lcks :: [InputData] <- local getRState --  readDBRef locks `onNothing` return []
        local $ setRState $ idata:lcks -- writeDBRef locks $ idata:lcks 
        empty


  otherGames = do
      inputdatas <-  local getRState -- liftIO $ atomically $ readDBRef locks `onNothing` return []
      tr ("Options",inputdatas)
      local $ foldr (<|>) empty $ map (\(InputData id msg url) -> sendOption msg url) inputdatas



mainpath= keep $ initNode $ do
    minput "init" "init game" :: Cloud ()
    left <|> right
    where
    left= do
      minput "left" "go to left"  :: Cloud ()
      whatever
    right= do
      minput "right" "go to right" :: Cloud ()
      whatever
    whatever= localIO $ print "wathever"
      
{-
-- | initili
newRPState x= onAll $ newRState x

getRPState :: (Typeable a,Loggable a) => Cloud a
getRPState = local getRState

setRPState :: (Typeable a,Loggable a) =>  a -> Cloud ()
setRPState val = do
  val' <- local $ return val
  onAll $ setRState val'
  
withRPState f = onAll $ do
    ref <- getState 
    liftIO $ atomicModifyIORef ref f




  -- keep HTTP 1.0 no chunked encoding. HTTP 1.1 Does not render progressively well. It waits for end.
  -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend 
  -- mclose conn

  msend conn $  toHex l <> str "\r\n" <> tosend <> "\r\n"-- <>  "\r\n0\r\n\r\n"
       
  where
  toHex 0= mempty
  toHex l=
          let (q,r)= quotRem  l 16
          in toHex q <> (BS.singleton $ if r <= 9  then toEnum( fromEnum '0' + r) else  toEnum(fromEnum  'A'+ r -10))

  str=   BS.pack


      
maindistgame= keep $ initNode $ inputNodes <|> do
  id <- inputString
  game <|> options
  where
  game= do
    lock  <- inputInt 
    guess <- inputInt <|> getMailbox  $ "guessbox"++id
    if lock== guess...
    
  options= do
    ids <-getAllids
    id <- wlink ids
    option id
  option id= do
    guess <- inputInt
    putMailbox "guessbox" guess
-}

maindist =  keep' $  initNode $ inputNodes <|>  do
    local $ option  ("go" :: String) "go"
    node <- local $ getNodes >>= return . (!! 1)
    x <- local $ return HELLO
    -- h <- runAt node $ do
    --        r <- localIO $ do print x ; return INTER
    --        localIO $ return WORLD
    h <- wormhole node $ loggedc $ do
          loggedc teleport
          localIO $ print x
          r <- localIO $ return WORLD
          teleport
          return r

    local $ do
      log <-getLog
      tr log
      liftIO $ print h

    -- h <- runAt node $ do

    --      localIO $ print x 
    --      localIO $ return WORLD2
    h <- wormhole node $  do
          loggedc teleport
          localIO $ print x
          r <- localIO $ return WORLD2
          teleport
          return r
    localIO $ print h

--     node <- otherNode

--     wormhole node $ local $  do
--         void $ local $ option "r" "run"
--         i <-  atRemote $ do 
--                 showURL
--                 localIO $ print "hello"

--                 i <- local $   threads 0 $ choose[1:: Int ..]
--                 localIO $ threadDelay 1000000
--                 return i
--         localIO $ print i
--    where
--    otherNode= local $ do
--            nodes <-  getNodes
--            guard $ length nodes > 1
--            return $ nodes !! 1
--    atOtherNode doit= do
--      node <- otherNode
--      runAt node  doit

-- test8 =  do
--     --local $ option "r" "r"
--     delData Serial
--     n <- local getMyNode
--     r <- (runAt n (local getMailbox) <> runAt n (local getMailbox) <> runAt n (local getMailbox)) <|> (local $ putMailbox "hello " >> empty) 
--     -- r <- (return [3] <> (async (do print "here";return [5]:: IO [Int]) >> empty)) <|> liftIO (do print "here2"; return [7])
--     localIO $ print (r  :: String)

-- --initNode $ inputNodes <|> test7


-- service= [("service","test suite")
--          ,("executable", "test-transient1")
--          ,("package","https://github.com/agocorona/transient-universe")]


-- test7= do 
--     ins <- requestInstance service 1 
--     localIO $ print ins

-- test6= do
--     -- setData Parallel
--     ((async getLine  >> return ())<> (liftIO $ print "world")) -- <|> liftIO (print "hello") 

-- test5= do
--    -- option "r" "run"
--    v1 <- liftIO $ newEmptyMVar

--    setData Parallel
--    (proc v1 <> proc2 ) <|> 
--             (do  liftIO $ threadDelay 1000000 ; async $ putMVar v1 ("hello" :: String) )
--    -- liftIO $ print (r :: String) 
--    where
--    proc2= liftIO $ print "world"
--    proc v1=do
--       --v <-  liftIO . atomically $ dupTChan v1
--       liftIO $ print "PROC"

--       (async $ do (readMVar v1) >>= print)

{-
mainsample= keep $ initNode $ do
  othernode <- localIO $ createNode "somehost" 8000
  r <-  (local $ do
          option 1 "one"                        <|> 
            async (return 2)                    <|>
            choose (repeat 3)                   <|>
            (do react' someCallback ; return 4) <|>
            return 5)
                                                <|>
        (runAt othernode $ local $ do
          option 6 "six"                        <|>
            async (return 7)                    <|>
            choose (repeat 8)                   <|>
            (do react' someCallback ; return 9) <|>
            return 10)

    
  localIO $ print $ case r of
      1 -> "console input"
      2 -> "asynchronous result"
      3 -> "An infinite stream of '3's"
      4 -> "some callback invoked"
      5 -> "synchronous result"
      6 -> "console input in the other node"
      7 -> "asynchronous result from the other node"
      8 -> "A stream of '8's from the other node"
      9 -> "some callback invoked in the other node"
      10 -> "synchronous result from the other node"
  where
    someCallback :: (a -> IO ()) -> IO ()
    someCallback= undefined
    react' x= react x $ return()

-}


-- test3= do
--     v <- newEVar
--     -- option "r" "run"
--     setData Parallel
--     r <- (readEVar v <> readEVar v) <|> (do liftIO $ threadDelay 1000000; writeEVar v "hello" >> empty)
--     liftIO $ print (r :: String)

-- test2=  do
--   option "r" "run"
--   setData Parallel
--   r <- (async (return "1") ) <> (async (return "2")) <|> (do liftIO $ threadDelay 10000000;async (print "3") >> empty)

--   --r <- (getMailbox <> getMailbox) <|> (do liftIO $ threadDelay 10000000; putMailbox (1 :: Int) >> empty)

--   liftIO $ print (r :: String)

-- test12= do
--     local $ option "r" "run"
--     ns <- local getNodes
--     r  <- runAt (ns !! 1) proc1 <> runAt (ns !! 2) proc2
--     localIO $ print r
--     where
--     proc2= local $ return "hello from 3001"

--     proc1= local $ do
--             n <- getMyNode
--             liftIO $ threadDelay 5000000
--             return "hello from 3000" 


-- test1= do
--     local $ option "r" "run"
--     n <- local $ do ns <- getNodes; return $ ns !! 1
--     localIO $ return () !> "RRRRRR"
--     r <- (mclustered  (local getMailbox))  <|> do
--                 local $ option "s" "run"
--                 localIO $ return () !> "SSSSSS"
--                 runAt n $ local $ do 
--                     putMailbox $ "hello "
--                     empty

--     localIO $ print (r :: String)

-- test= do
--         let content= "hello world hello"
--         local $ option "r" "run"  
--         r <- reduce (+) $ mapKeyB (\w -> (w, 1 :: Int))  $ distribute $ V.fromList $ words content
--    --     localIO $ print  ("MAP RESULT=", dds)
--   --      -- local $ option "red" "reduce"
-- --        localIO $ getNodes >>= \n -> print ("NODES1", n)
--     --    r <- reduce (+) $ DDS $ return dds
--         localIO $ putStr "result:" >> print r

--         localIO $ print "DONE"
        