
{-# LANGUAGE ScopedTypeVariables #-}
import Transient.Internals
import Transient.Console
import Transient.Move.Internals
import Transient.Move.Services
import Transient.Move.Utils
import Transient.Logged
import System.IO
import Control.Monad.IO.Class
import Control.Applicative
import Control.Concurrent
import Control.Monad
import Control.Exception
import Data.String
import Transient.Indeterminism
import Data.String
import Data.Maybe
import System.IO.Unsafe
import Data.Typeable
import Data.Map as M hiding (empty)
import Control.Monad.State
-- main= keep $ unCloud $do
--      n <- localIO $ createNode "localhost" 8000
--      listen n <|> onAll abduce
     
--      wormhole n $ do
 
--          return()
         
-- watch =do   local $ fork $ do
--                             st <- getCont
--                             labelState $ fromString "XXXXXX"
--                             fork $ threads 0 $do choose [1..] ; liftIO $ threadDelay 5000000; showThreads st

{-
? que se necesita para que la closure del WH anterior sirva para el siguiente?
-  tiene /e/e/e  al final para ejecutar
-}

data N0=N0 deriving (Typeable,Read,Show)
data N1=N1 deriving (Typeable,Read,Show)
data N2=N2 deriving (Typeable,Read,Show)
data N3=N3 deriving (Typeable,Read,Show)
data N4=N4 deriving (Typeable,Read,Show)

-- >>> read "N1" :: N0
-- *** Exception: Prelude.read: no parse
--




instance Loggable N0 
instance Loggable N1
instance Loggable N2
instance Loggable N3
instance Loggable N4

mainyest= keep $  do
 
        x <- logged (return "hello ") <> logged (return "world")
        liftIO $ print x
        log <-  getLog
        liftIO $ print ("----->",fulLog log,toPath $ fulLog log)


main15= keep $ initNode $ inputNodes <|> do 
    -- local $ do
    --     node1 <- liftIO $createNode "localhost" 8001
    --     addNodes[node1]
    local $ option "h" "salutation"
        
    nodes <- local getNodes
    
    -- x <- loggedc $ (,) <$> (runAt (nodes !! 1) $ return  $ N1) <*>  (runAt (nodes !! 2) $ return  $ N2)
    -- localIO $ print x
    x <- runAt (nodes !! 1) $ do
        -- local $ choose [1,2:: Int]
        localIO $ print "HELLO"
        return N3
    localIO $ print x

    empty
{-
enviar el resultado? no .
   la operación $ se hace en el nodo llamante
   hacer una instancia distinta?
   hacer el valor accesible al remoto
-}
    
    -- y <-  do
    --         z <-  runAt (nodes !! 1) $ do
    --                     localIO $ print ("EXECCCCCCCCCCCCC 8001 22222",x)
    --                     return N2
    --         local $ return()  -- hay que guardar estos logs intermedios?
    --         local $ return()

    --         return  (z,N1)
    -- localIO $ print ("EXECCCCCCCCCCCCC 8000 33333",y)  -- en este punto tiene /N0/(N2,N1)/()/e/e/e/
                                                       
    
    -- runAt (nodes !! 1) $                               -- deberia mandarle: ()/N2/()()/(N0,N1)/()
    --      localIO $ print ("EXECCCCCCCCCCCCC 8001 4444",x,y)

    -- localIO $ print "ENNNNNNNNNNNNNNNNNNNNNNNNND"
    -- empty

    x <- local $ return N0


    (z,t) <- runAt (nodes !! 1) $ do
            local $ return N2
            y <- runAt (nodes !! 2) $  do
                     tr "HEREEEEEEEEEEEE"
                     localIO $ print ("EXECCCCCCCCCCCCC 8000 3333",x)
                     return N3

            localIO $ print ("EXECCCCCCCCCCCCC 8001 ",x,y)
            return  N4

            return (y,N4)
    localIO $ print ("EXECCCCCCCCCCCCC 8000 666666",x,z,t)

{-
Se puede hacer q
-}

         

{-
a nlog1 b nlog2 a
recorrer los closures existentes y añadir nlogs y los e eee que tienen al final?
guardar la longitud de fulLog y quitarla

-}    

    where
    otherNode= local $ do
        ns <- getNodes
        guard (length ns > 1) <|> error "I need to know the other node"
        return $ ns !! 1
    
main1= do 
    name <- getLine
    putStrLn $ "hello "++ name

main2= keep' $ do
    name <- liftIO $ getLine
    liftIO $ putStrLn $ "hello "++ name

main3= keep' $ do                                                                    
    name <- liftIO $ getLine                                                          -- -->-- -->  hello ...
    r <- async (return $ "hello2 "++ name) <|> return  ("hello " ++ name)                   -- -->  hello2 ...
    liftIO $ putStrLn r                                                                       

main4= keep $ do 
    name <- liftIO $ getLine                                                          -- -->
    r <- waitEvents $  return $ "hello "++ name                                            -- -->
    liftIO $ putStrLn r                                                                    -- -->
                                                                                           -- -->
                                                                                           -- ...
    
main5= keep $ do 
    name <- liftIO $ getLine                                                          -- -->
    r <- threads 0 $ waitEvents $ do threadDelay 1000000; return $"hello "++ name           -- -->
    liftIO $ putStrLn r                                                                           -- -->
                                                                                                        -- ..

main6= keep $ do 
    option "hello" "salutation" 
    name <- input (const True) "enter a string"
    threads 0 $ waitEvents $ do threadDelay 1000000; return $ "hello "++ name

main7= keep $ initNode $  inputNodes <|> do                                              -- > runghc program.hs -p start/localhost/8000/add/localhost/8001/n
    local $ option "hello" "salutation"
    name <- local $ input (const True) "enter a string"                                  -- > runghc program.hs -p start/localhost/8001/add/localhost/8000/n
    nodes <- local getNodes
    guard (length nodes > 1) <|> error "I need to know the other node"

    runAt (nodes !! 1) $ localIO $ putStrLn $ "hello "++ name                             -- --> ....> (other node) -- -->


main9= keep $ initNode $ inputNodes <|> do 
    local $ option "hello" "salutation"
    name <- local $ input (const True) "enter a string"
    nodes <- local getNodes
    guard (length nodes > 1) <|> error "I need to know the other node"

    runAt (nodes !! 1) $  localIO $ putStrLn $ "hello "++ name                            -- --> ....> (other node) -- -->....> (calling node)
    localIO $ putStrLn "response received"                                                                                                  -- --> response...

main10= keep $ initNode $ inputNodes <|> do 
    local $ option "hello" "salutation"
    name <- local $ input (const True) "enter a string"
    nodes <- local getNodes
    guard (length nodes > 1) <|> error "I need to know the other node"
    
    send (nodes !! 1) name <|> workInParallel                                         -- -->-- --> "this work in parallel"
                                                                                            -- --> ....> (other node) stop
    where
    send node name =runAt node $ do 
         localIO $ putStrLn $ "hello "++ name
         empty  
    workInParallel= localIO $ putStrLn "this work in parallel"

main11= keep $ initNode $ inputNodes <|> do
    local $ option "hello" "salutation"
    name <- local $ liftIO $ getLine
    nodes <- local getNodes
    guard (length nodes > 1) <|> error "I need to know the other node"

    helloname <- local $ waitEvents $ return $ "hello " ++ name                      -- -->
    runAt (nodes !! 1) $  localIO $ putStrLn helloname                                    -- -->....> (other node) -- --> hello...
                                                                                          -- -->....> (other node) -- --> hello...
                                                                                          -- -->....> (other node) -- --> hello...   
                                                                                          -- ..                       

main12= keep $ initNode $ inputNodes <|> do
    local $ option "hello"  "salutation"
    name <- local $ liftIO $ getLine
    nodes <- local getNodes
    guard (length nodes > 1) <|> error "I need to know the other node"

    helloname <- runAt (nodes !! 1) $ local $ waitEvents $ return $ "hello " ++ name        -- -->....> (other node) -- -->....> (calling node)
    localIO $ putStrLn helloname                                                            -- -->....> (other node) -- -->....> (calling node)                                                     -- --> hello ...
                                                                                            -- -->....> (other node) -- -->....> (calling node)

-- #define shouldRun(x)    (local $ do p <-getMyNode; liftIO $ putStrLn (p,x) ;assert ( p == (x)) (liftIO $ putStrLn p))

-- main6= keep $  initNode $ inputNodes <|> do inputNodes <|> do
--     local $ option "r" "r"
--     nodes <- local getNodes
--     let node0= nodes !! 0
--     let node1= nodes !! 1
--     let node2= nodes !! 2
--     runAt node1 $ runAt node0  $ do localIO $  putStrLn "hello " -- ; empty :: Cloud ()
--     localIO $ putStrLn "WORLD"
 
     
-- {-
--     empty
--     runAt (node1) $ do
--        shouldRun (node1)
--        localIO $ putStrLn "hello "  
--        runAt node2 $  (runAt node1 $ do shouldRun(node1) ; localIO $ putStrLn "hello " ) -- <|>  (shouldRun(node2) >> return "world")
-- -} 
-- main8= keep $  initNode $ inputNodes <|> do
--      r <-  return ("hi ") <>  do localIO $ putStrLn "WORLD"; local $ async (  return "hello ")   <> return "world"
--      localIO $ putStrLn r

-- servname= [("name","serv")]

-- main9= keep $ runService servname 3000  [serve plus2 ] $ trans  <|> service  -- <|> callNodes1
--   -- return ()

-- plus2 (x :: Int) = do
--    return () !> ("PLUS2",x)
--    return $ x + 2

-- callNodes1= do
--     local $ option "call" "callNodes"
--     node <- local getMyNode
--     nodes <- local $ findInNodes servname
--     r <- callNodes' nodes (<>) mempty $ return "hello " 
--     localIO $ putStrLn r

-- trans = do

--     return () !> "BEFORE OPTION"
--     local $ option (str "t") "trans" 
--     callNode <- local getMyNode
--     nodes <- local getNodes

--     n <- local $ return (1 :: Int)  
--     r <- runAt (nodes !! 1)  $ localIO $ do putStrLn callNode ;return $ n +1
--     localIO $ putStrLn r 
--     trans


-- service = do
--     local $ option (str "s") "service"
--     nodes <- local getNodes
--     n <- callService' (nodes !! 1) (1 :: Int)
    
--     onAll $ do
--         log <- getLog
--         rest <- giveParseString
--         return () !> ("LOG AFTER service 111",rest,recover log, buildLog log, fulLog log)    
--     localIO $ return "PEPE"
--     onAll $ do
--         log <- getLog
--         rest <- giveParseString
--         return () !> ("LOG AFTER service 222",rest,recover log, buildLog log, fulLog log)    
--     localIO $ putStrLn (n :: Int)
--     localIO $ putStrLn (n :: Int)
--     onAll $ do
--         log <- getLog
--         rest <- giveParseString
--         return () !> ("LOG AFTER service 333",rest,recover log, buildLog log, fulLog log)   
  
--     local $ option (str "tt") "transs" 
 




--     r <- runAt (nodes !! 1)  $ localIO $ return $ n +1
--     localIO $ putStrLn r 


-- {-
-- newtype Serv= Serv BS.ByteString deriving (Read,Show,Typeable)

-- instance Loggable Serv where
--    serialize (Serv s)= byteString (BSS.pack "srv") <> lazyByteString s
--    deserialize= symbol (BS.pack "srv") >> (Serv <$> tTakeWhile (/= '/'))


-- nserve :: (Loggable a, Loggable b) => BS.ByteString -> (a -> Cloud b) -> Cloud ()
-- nserve name serv= do
--     Serv n <- local empty -- aqui puede registrar el sub-servicio.
--     if n /= name then empty else do
--         p <- local empty
--         loggedc $ serv p
--         teleport
-- -}

   

-- main = keep $ initNode $ inputNodes <|> do inputNodes <|> do
--      local $ option (str "go") "go"
--      nodes <- local getNodes
--      localFix
--      local $ option (str "send") "send"
--      world <- runAt (nodes !! 1) $  localIO $ putStrLn "hello "  >> return "WORld"
--      localIO $ putStrLn world

--      localFixServ False True
--      local $ option (str "send2") "send2"
--      world2 <- runAt (nodes !! 1) $  localIO $ putStrLn "HELLO2"  >> return "WORld2"
--      localIO $ putStrLn world2
     
-- main3 =  keep $ initNode $ inputNodes <|> do inputNodes <|>  do
--      local $ option (str "go")  "go"
--      nodes <- local  getNodes
     
--      r1 <- loggedc' $ wormhole (nodes !! 1) $  do
--                  teleport 
                 
--                  r <- localIO $ putStrLn "hello " >> return "WORLD"
--                  teleport 
--                  localIO $ putStrLn "WORLD" >> return r

--      r2 <- wormhole  (nodes !! 1) $ loggedc $ do

--                      teleport 
--                      r <- local $ getSData <|>  return "NOOOOOO DAAATAAAAAA"
--                      localIO $ putStrLn r
--                      r <- loggedc $ do localIO $ putStrLn $ "HELLO22222" ++ r1;return $ "hello2" ++ r1      
--                      teleport 
                     
--                      return r
--      localIO $ putStrLn $ "WORLD2222222" ++  r2    

     
-- main5  = keep $ initNode $ inputNodes <|> do inputNodes <|>  do
--      local $ option (str "go")  "go"
--      nodes <- local getNodes
--      t1 <- onAll $ liftIO $ getClockTime
--  --    r <- runAt (nodes !! 1) $ return "HELLOOOOOOO"
--      wormhole (nodes !! 1) $ do
--        r  <- atRemote $ localIO $ BS.pack <$> replicateM 10 (randomRIO('a','z'))
--        r2 <- atRemote $ localIO $ BS.pack <$> replicateM 10 (randomRIO('a','z'))

--        localIO $ putStrLn $  "RETURNED: " <>  show (r,r2)
--        t2 <- onAll $ liftIO $ getClockTime 
--        localIO $ putStrLn  $ diffClockTimes  t2 t1
     
-- main2 = keep $ initNode $ inputNodes <|> do inputNodes <|>  do
--      local $ option (str "go")  "go"
--      nodes <- local getNodes
--      runAt (nodes !! 1) $ local $ do
--            n <-  getMyNode
--            handle <- liftIO $ openFile ("test"++ show (nodePort n)) AppendMode
--            setData handle

--      append  nodes  <|> close  nodes 
     
-- append  nodes  = do  
--      local $ option (str "wr")  "write"

--      runAt (nodes !! 1) $ local $ do
--          handle <- getSData <|> error "no handle"
--          liftIO $ hPutStrLn handle "hello "

-- str s= s :: String

-- close nodes  =  do
--         local $ option  (str "cl") "close"

--         runAt (nodes !! 1) $ local $ do
--              handle <- getSData <|> error "no handle"
--              liftIO $ hClose handle

service= Service $ M.fromList
         [("service","test suite")
         ,("executable", "test-transient1")
         ,("package","https://github.com/agocorona/transient-universe")]
     
liftA1 tcomp ccomp= local $ tcomp $ unCloud ccomp

main= keep $ initNode $ inputNodes <|> do
           local $ option ("go" :: String) "go"
           (node1,node2) <- local $ getNodes >>= \ns -> return $ (ns !! 0, ns !! 1)
           r <-  do liftA1 sync1  ( do runAt node2  $ return "returned" -- (local $ option "f" "fire")
                                       localIO $ print "passed1"
                                       local $ topState >>= showThreads) 
                    localIO $ print "passed2"; return "hello" <|>  (return "altermativ eexecuted")
           localIO $ print r
           stop





           h <- onAll $ liftIO $ openFile "../loop.sh" ReadMode
           i  <- local $ parallel $ (SMore <$> hGetLine h) `catch` \(e:: SomeException) -> return SDone
           localIO $ print i
           empty
           node <- local $ getNodes >>= \ns -> return $ ns !! 1
           [node1] <-  requestInstance service 1
           localIO $ print node1
           empty
           r <- local (async (return "hello")) <|> runAt node (return "world")
           localIO $ print (r :: String)