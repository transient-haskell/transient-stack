#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/projects/transient-stack" && runghc  -DDEBUG   -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/axiom/src   $1 ${2} ${3}

{-# LANGUAGE   CPP, OverloadedStrings,ScopedTypeVariables, DeriveDataTypeable, FlexibleInstances, UndecidableInstances #-}


import Transient.Internals 
import Transient.Console
import Transient.EVars
import Transient.Logged
import Transient.Parse
import Transient.Indeterminism
import Data.Typeable
import Control.Applicative
import Data.Monoid
import Data.List
import System.Directory
import System.IO
import System.IO.Error
import System.Random
import Control.Exception hiding (onException)
import qualified Control.Exception(onException)
import Control.Concurrent.MVar 
import Control.Monad.State
import Control.Concurrent 
import           System.IO.Error
import Debug.Trace

import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.ByteString.Builder
import Control.Monad.IO.Class
import System.Time
import Control.Monad
import Data.IORef
import Data.Maybe
import Data.String

import System.IO.Unsafe
import Unsafe.Coerce

-- ```python
-- def fibonacci():
--     a=0
--     b=1
--     while true
--         yield b
--         a,b= b,a+b

-- for(var num : fibonacci) {
--   System.out.println(num);
--   if num > 10_000) break;
-- ```

main= keep' $ do
    r <- sync $ collect' 1 1000000 $ (return "hello" >> empty) <|> return "world"
    liftIO $ print r

{-
mainyield= keep' $ do
    p1 <||> p2
    str <- getState
    liftIO $ print str


class (Show a) => Yield a where
 (<||>) x y= do
     r1 <- X
     modifyData' (++ show r1) r1
-}


atEndThread adquire release = react  (bracket adquire release) (return ())

newtype Finish2= Finish2 String deriving (Show)

finishReact mx handler= do
    st <- get
    (mx, cont) <- (runTransState st (mx `onBack` \(Finish2 r :: Finish2)-> handler r) )
                       `atEndThread` \(mx,cont) ->
                             exceptBackg cont $ Finish2 $ show $ unsafePerformIO myThreadId
    put cont
    return mx


testnothread= keep $  do
    
    option ("f"::String) "fire"
    onFinish $ \f -> liftIO $ putStrLn f
    

    i <-  threads 0 $ choose[1,2::Int]

    liftIO $ print i
{-
ejecutar primero excepciones luego finish
atEndThread mirar si no tien hijos,
   si no tiene hijos, cerrar, ejecutar anteriores. debe haber un stack de ellas.
   si tiene, no cerrar

       cabal update --index-state='2020-05-20T08:40:22Z'
-}

{-
diffThreads=  do
    liftIO $ takeMVar printBlock
    liftIO $ putStrLn ""
    liftIO $ putStrLn "THREAD CHANGES"
    liftIO $ putStrLn ".............."
    list <- getState <|>  return [] 
    list' <- threadString
    setState list'
    let dif = getGroupedDiff  list  list'
    liftIO $ putStrLn $ ppDiff (dif :: [Diff [String]]) 
    liftIO $ putMVar printBlock ()

threadString :: TransIO [String]
threadString = do
    st <- topState
    mythread <- liftIO myThreadId
    let showTree n ch = liftIO $ do
            (state, label) <- liftIO $ readIORef $ labelth ch
            chs <- liftIO $ readMVar $ children ch

            (return 
                [(take (2*n) $ repeat ' ')++

                    if  label == mempty
                        then  show $ threadId ch
                        else  show label ++ drop 8 (show (threadId ch))
                    -- when (state == Dead) $ putStr " dead" -- 
                    ++  " " ++ show state ++ if mythread == threadId ch then " <--" else ""
                ]) 

                <> ((return . concat =<< mapM (showTree $ n + 2) (reverse chs)) ) :: IO [String]
    liftIO $ showTree 0 st



el enviante puede enviar un SLast cuando sus thread exhausted
el receptor tiene que usar ese SLast para disparar el...
como hacer forward del SLast?
    poner un onFinish en wormhole?
 hay que distinguir si es el primero o el segundo teleport
   si está respondiendo o no
 
 SLast no se puede propagar directamente, sino que manda un Finish y el onFinish decide
   el cont sobre el que se ejecutan los back finish es el del teleport, que no tienen colgados threads
     habría que colgar las recepciones
         pero esas llegan y se van. no puede saber cuando han finalizado.
         cada teleport tiene un SLast, luego si se

un teleport puede mandar procesos locales o remotos.
   los threads locales hacen back Finish
   los remotos mandan SLast que manda back Finish
asi que el teleport puede controlar asi cuando manda su SLast

ahora bien cuando es llamada y llama,
-----
!el ultimo teleport de runAt de 2 está esperando envios de 1
!  esto puede aprovecharse no reseteando cada teleport a la closure 0
?      y quitando toda la basura de fixClosure
X      almacenando en connection la ultima closure 
!            no vale, porque puede reutilizarse para otras secciones !
V         un setState  map connection closure 

? como notificar el fin de actividad?
-  1 al final tiene que notificar a 2, pero 2 puede tener thread pendientes en medio
?   como sabe 1 que llega al final?
-     dentro de un wormhole no puede saberlo porque puede haber otro wh debajo
-        cuando un finish llega deshace el evar (hay que quitarlo de la conexion)
-         pero si llega un nuevo envio que llama teleport, vuelve a crear el Evar
-         luego wormhole puede cerrar el evar de 2 con un onFinish mandando SLast, pero no queda disponible para un nuevo WH
!         NO!!! porque no enviará un SLast si hay actividad debajo!!!
V?        luego un onFinish en wormhole puede servir?
!           pero 1 tiene eVars esperando por 2, luego siempre hay actividad y nunca un onFinish se activara en WH 1
X           un nuevo onFinish que no tenga en cuenta threads en espera?
V?               quitar el evar de la lista, con freethreads?
!                  pero es oculta para siempre ese thread y hijos de WH
-                  Tiene que obviar ese EVar, pero colgar sus hijos
-                     evar sabe cual es su padre: hangFrom (parent evar)  
V                            incorporarlo a freeThreads
?           no usar evars y usar la version con cont.
              la version cont no añade threads a wormhole
X     si fuera un solo thread, en keep
X          manda finish al ultimo

-}
testExceptInTree= keep $ do
    this <- get
    throwt $ ErrorCall "hello"
    topState >>= showThreads

mainfreethreads= keep' $ do
    freeThreads $ abduce; abduce; abduce; abduce; abduce; abduce; return "hello"
    topState >>= showThreads -- to verify that the thread is in the tree
    -- option ("op" :: String) "op" 

mainevarfinsh= keep $ do
    ev <- newEVar
    onFinish $ \r ->  liftIO $ print r
    abduce
    r <- readEVar ev <|> do lastWriteEVar ev "hello" >> empty
    liftIO $ print r

data NoMoreWork= NoMoreWork deriving (Typeable,Read,Show)

mainevar= keep' $ do
    -- return () `onBack`  \NoMoreWork ->  tr "nomorework"
    
    -- back NoMoreWork <|> return()
    -- tr "next"
    ev <- newEVar
    r <- threads 0 $ choose [1,2]
    liftIO $ print r
    cont <- get
    chs <- liftIO $ readMVar $ children $ fromJust $ unsafePerformIO $ readIORef $ parent cont
    liftIO $ print $ length chs
    readEVar ev
{-
    No se puede cerrar (onFinish) un recurso mientras haya threads aunque estén bloqueadas en un readEvar
    porque ese recurso está en el stack y puede ser usado mas abajo.

    SLast request -> teleport1 -> telepart2 -> SLast response
    el problema es que teleport2 sigue esperando  por una segunda request.
    como se resuelve?
      distinguir entre onFinish 
  y onNoMoreWorkHere: cuando es seguro que no va hacerse nada en un segmento
        como se detecta?
          en particular en teleport podria tener una serie de thread trabajando de manera que el segundo teleport enviara varios paquetes.
          Cuando un teleport detecta que solo hay un thread trabajando, que mande un SLast directamente
          para saberlo necesita el cont del teleport anterior
            o igual lanzar un back especial y el lanzador detectar si solo hay un thread
            el msend está en el mismo teleport en el que esta la continuacion.

             onBack \NoMoreWorkHere -> do
                 cont <- get
                 chs <- liftIO $ readMVar $ children st
                 if not null chs && null tail chs then doit


-}

mainmove=   keep $ do
    ref <- liftIO $ newIORef undefined
    ex1 ref "hello" <|> ex2 ref "world"

    where
    ex1 ref s= do
        abduce
        onFinish $ const $ liftIO $ print (s,unsafePerformIO myThreadId)

        cont <- getCont
        liftIO $ writeIORef ref cont

    ex2 ref s= do
        abduce
        onFinish $ const $ liftIO $ print (s,unsafePerformIO myThreadId)
        cex1 <- liftIO $ readIORef ref
        topState >>= showThreads
        st <- getCont
        st' <- liftIO $ findAliveParent st
        liftIO $ do
            removeChild st 
            writeIORef (parent st) $ Just st'
            modifyMVar_ (children  st') $ \chs -> return $st:chs
        put st{mfData=mfData cex1}
        tr(threadId st', "<-",threadId st)
        
        
        topState >>= showThreads
        


bracket1 before after thing =
  uninterruptibleMask $ \rest -> do
    a <- before
    r <- rest (thing a) `Control.Exception.onException` after a
    _ <- after a
    return r

testmask= do
    th <- forkIO $ bracket1 (print "open">>threadDelay 10000000 >> print "open2")(const $ print "close") $ const $ do
                threadDelay 1000000
                print "END"
    threadDelay 1000000
    killThread th
    print "end2"

mainfinish2= keep' $ do
    onException $ \(SomeException e) -> liftIO $ print "HANDLER2"

    ref <- liftIO $ myThreadId >>= newIORef
    (do
        abduce
        liftIO $ myThreadId >>= writeIORef ref

        tmask $ do
            liftIO $ print "open"
            liftIO $ myThreadId >>= print

            liftIO $ threadDelay 10000000
            -- onException $ \(SomeException e) -> liftIO $ print("except")

            onFinish $ \e-> liftIO $ print ("close",e)
            liftIO $ print "open2"

        liftIO $ print "OUT"
        liftIO $ threadDelay 10000000
        liftIO $ print "OUT2")
      <|> do
        liftIO $ threadDelay 1000000
        th <- liftIO $ readIORef ref
        liftIO $ print ("2", th)
        liftIO $ killThread $  th
        liftIO $ print "END2"
{-    
    primero se ejecutan las excepciones
    pero exceptions tienen que devolver su cont, manipulando liftIO
        liftIO mx= do
            lr <- Transient $ retunrn Right mx `catch` \(SomeException e) -> return Left e
            cast lr of
                Right x -> return x

                Left e -> do
                    cont <- getCont
                    back (e,cont)


    free tiene que cojer el padre real de cont
    exception que genere un finish, 

    -- x<-(liftIO $ print "open") `finishReact` \r -> liftIO $ print ("close", r)   
    -- abduce
    -- x2<-(liftIO $ print "open2") `finishReact` \r -> liftIO $ print ("close2", r)   
    -- liftIO $ print (x,x2)

-}


mainev= keep $ do
       ev <- newEVar
       option ("f"::String) "fire"
       r <-  collect2 1 0 $ (readEVar ev) <|> ( writeEVar ev "HELLO" >> empty)

       liftIO $ print r
       

testcollectevar= keep $ do
       ev <- liftIO $ newEmptyMVar
       option ("f"::String) "fire"
       r <-  collect2 0 0 $ (parallel (takeMVar ev)>>= checkFinalize) <|> ( liftIO (putMVar ev  $ SMore "HELLO") >> empty)

       liftIO $ print r

testLocalExceptionHandlers= keep $ do
    option ("f" ::String) "fire"
    onException $ \(SomeException e) -> do liftIO $ print ("2",e) ; empty

    localExceptionHandlers $
      onException $ \(SomeException e) -> liftIO $ print ("1",e)
    
    throw $ userError "errrr"
    return()

continueNext :: EventF -> (Maybe x) -> StateIO  (Maybe x)
continueNext cont x=  do
        --  cont <- get
         case event cont of
          Nothing -> do
            liftIO $ 
              runStateT (runCont cont) cont{event= Just $ unsafeCoerce x} `catch` exceptBack cont

            return Nothing

          j@(Just _) -> do
            put cont{event=Nothing}
            return $ unsafeCoerce x

onBackMask :: (Typeable b, Show b) => TransientIO a -> ( b -> TransientIO a) -> TransientIO a
onBackMask ac bac = registerBack (typeof bac) $  do
    Transient $ do
        cont <- get
        (mx,st) <- liftIO $ mask $ \restore -> (flip runStateT) cont $ do
                tr "onBack"
                Backtrack mreason stack  <- getData `onNothing` (return $ backStateOf (typeof bac))
                r <- runTrans $ case mreason of
                            Nothing     -> ac                     -- !>  "ONBACK NOTHING"
                            Just reason -> bac reason             -- !> ("ONBACK JUST",reason)
                st <- get
                (mx,st) <- liftIO $ restore $ (flip  runStateT) st $ continueNext  cont r
                put st
                return mx
        put st
        return mx
   
    where
    typeof :: (b -> TransIO a) -> b
    typeof = undefined



testcontinuenext= keep'' $ do
    x <- Transient $ do
        st <- get
        (mx,st)<- liftIO $ mask $ \rest -> (flip  runStateT) st $ do
                                mx <-runTrans $ return "hello"
                                (mx,st) <- liftIO $ rest $ (flip  runStateT) st $ continueNext st  mx 
                                put st
                                return mx
        put st
        return mx
    liftIO $ print $ x  ++ "world"
 {-
 la cuestion es que el  a `onEsception` b   se ejecute a sin parar y si hay excepciones, ejecutar el handler
     runTrans $ case mreason of
                            Nothing     -> mask ac  `catch` \e -> bac
 -}   

teststateforback= keep'' $ do
    abduce
    labelState "test"
    (do setState ("hello" :: String); liftIO $ threadDelay 10000000 ; back()) `onBackMask` \()-> getState >>= liftIO . putStrLn
    liftIO $ print "never"
--   <|> do
--       liftIO $ threadDelay 1000000
--       st <- threadState "test"
--       liftIO $ killThread $ threadId st

mainpair= keep  $  do
  pair <- (,) <$> consoleInput "left" <*> consoleInput "right"
  liftIO $ print pair

consoleInput op= do
    option op $ "content for the " <> op 
    input (const True ) "content?:" :: TransIO String

testkeep=  do
    r <- keep'' $ threads 1 $ do
        r <- choose [1..1000::Int] -- >>= \i -> liftIO $ threadDelay  (i* 1000000) >> return i
        -- r' <- choose [1..10::Int]
        return r -- (r,r')
    print (r,length r)

testfinish= keep' $ do 
    -- abduce
    st <- getCont
    r <- proc `onBack` \(Finish e) -> do
                            liftIO $ print("fin", e)
                            no <- hasNoChildThreads st
                            guard no
                            liftIO $  print ("NO MORE",e)
                            backtrack
    liftIO $ threadDelay 1000000
    th <- liftIO myThreadId
    liftIO $ print (r,th)
    where
    proc= do
        r <-  choose [1..10]
        liftIO $ threadDelay $ r * 1000000  --autosoler que insert $, liftIO para eliminar errores
        return r

testcollect0=  keep $ do
    -- onException $ \(SomeException e) -> liftIO $ print e
    option ("f" ::String) "fire"
    r <-collect2 1 1000000  (liftIO (print "hello") >>(return $ Just() )) -- <|> liftIO (print "world") -- timeout 100000 (return (Just "world") )-- :: TransIO ( String)
    -- r <- ((sync2 empty) >> empty ) <|> liftIO (print "world")
    -- r <- sync $ choose [1,2] 
        -- -- liftIO $ threadDelay  (i* 1000000) 
    topState >>= showThreads
        -- return i
    liftIO $ print r
    where
    timeout t proc=  do
       tr "init timeout"
       r <-  sync $ collect' 1 t proc
       tr("timeout",length r)
       case r of
          []  -> empty         -- !> "TIMEOUT EMPTY"
          mr:_ -> case mr of
             Nothing -> error "error"
             Just r -> return r   
    
    sync2 proc= do
        mv <- liftIO newEmptyMVar
        (abduce >> proc >>= liftIO . (putMVar mv) >> empty) <|> liftIO (takeMVar mv)


keep'' :: TransIO a -> IO   [a]
keep'' mx  = do
    hSetBuffering stdout LineBuffering
    rexit <- newEmptyMVar 
    void $ forkIO $ do
        void $ runTransient $ do
            onException $ \(e :: SomeException ) -> do
            --  top <- topState
                liftIO $ do
                th <- myThreadId
                putStr $ show th
                putStr ": "
                print e
                -- putStrLn "Threads:"
                -- showThreads top
                empty
            
            onException $ \(e :: IOException) -> 
                when (ioeGetErrorString e ==  "resource busy") $ do
                    liftIO $ do  print e ; putStrLn "EXITING!!!"; putMVar rexit []
                    liftIO $ putMVar rexit []
                    empty
            
            onException $ \ThreadKilled -> empty

            
            r <- collect2 0 0 $ do
                        r <- mx
                        return r -- <|> (back $ Finish $ show $ unsafePerformIO myThreadId)
            liftIO $ putMVar rexit r
    threadDelay 10000
    forkIO execCommandLine
    takeMVar rexit  `catch` \(e :: BlockedIndefinitelyOnMVar) -> return []



testcollect2= keep  $ do 
    option ("f"::String) "fire"
    r <- collect 4 $ threads 0 $  choose[1..100] --  >>= \i -> liftIO $ threadDelay (i * 1000000) >> return i
    liftIO $ print ("result",r,unsafePerformIO myThreadId)
    topState >>= showThreads --hay que reinsertar ese thread en la lista cuando



collect2 :: Int -> Int -> TransIO a -> TransIO [a]
collect2 number time proc' =  do
    res <- liftIO $ newIORef []
    done <- liftIO $ newIORef False  --finalization already executed
    abduce
    cont <- get
    -- liftIO $ atomicModifyIORef (labelth cont) $ \(status, lab) -> ((Parent, lab), ())

    let proc= do
            
            i <- proc'
            tr "WRITE"
            topState >>= showThreads
            liftIO $ atomicModifyIORef res $ \n-> (i:n,())
            empty

        timer =  do
            labelState "timer"
            guard (time > 0) 
            -- addThreads 1
            anyThreads abduce
            -- labelState $ fromString "timer"
            liftIO $ threadDelay time 
            liftIO $ writeIORef done True
            th <- liftIO myThreadId
            liftIO $ killChildren1 th cont

            liftIO $ readIORef res 

        check   (Finish reason) = do
            hasnot <- hasNoChildThreads cont 
            rs <- liftIO $ readIORef res
            guard $ hasnot || (number > 0 && length rs >= number)  -- previous onFinish not triggered
            f <- liftIO $ atomicModifyIORef done $ \x ->(True,x)
            if f then backtrack else do
                tr "forward" 
                forward (Finish ""); 
                
        --  -- hay que colgarlo -- 
                st <- noTrans $ do
                    th <- liftIO $ myThreadId
                    liftIO $ killChildren1 th cont
                    parent <- liftIO $ findAliveParent cont
                    st <- hangFrom parent $ fromString "finish"
                    put st
                    return st
                anyThreads abduce
                liftIO $ atomicModifyIORef (labelth st) $ \(_,l) ->  ((DeadParent,l),())
                liftIO $ print("RS",length rs)

                -- liftIO $ readIORef res
                return rs

    localBack (Finish "") $ timer <|> (anyThreads abduce >>(proc `onBack` check) ) 


    

    
    {-
    opciones:  
      usar kilbrabch i atachear el thread al final
       pero cuando viene por timeout hay que detachearlo
       oneThread: remove task, killbranch, attach to cont
    -}
    -- oneThread comp= do
    --     detach
    --     liftIO $ killBranch
    --     hangFrom cont
    --     where
    --     detach= do
    --         th <-myThreadId
    --         cont <- get
    -- oneThread :: TransIO a -> TransIO a
    -- oneThread comp = do
    --     -- st <- getCont
    --     st  <- noTrans $ cloneInChild "oneThread"
    --     -- liftIO $ modifyMVar (children $ fromJust $ parent st) $ \cs ->return(filter (\c->threadId st /= threadId c)cs,())
    --     put st
         
    --     let rchs= children st
    --     liftIO $ writeIORef (labelth st) (DeadParent,mempty)
    --     x   <- comp
    --     th  <- liftIO myThreadId
    --     chs <- liftIO $ readMVar rchs

    --     liftIO $ mapM_ (killChildren1 th) chs


    --     return x
    --     where 
        
    --     killChildren1 :: ThreadId  ->  EventF -> IO ()
    --     killChildren1 th state = do
    --             ths' <- modifyMVar (children state) $ \ths -> do
    --                         let (inn, ths')=  partition (\st -> threadId st == th) ths
    --                         return (inn, ths')
    --             mapM_ (killChildren1  th) ths'
    --             mapM_ (killThread . threadId) ths'


test= threads 0 $ do
    -- option ("f" ::String) "fire"
    results <- liftIO $ newIORef []

    res <-  do 
                i <-  choose[1..3]
                labelState $ fromString $ "thread from "++ show i
                -- liftIO $ threadDelay (i * 1000000)
                th <- liftIO $ myThreadId
                -- topState >>= showThreads
                liftIO $ atomicModifyIORef results $ \r -> (i:r,())
                liftIO $ print ("end",th)
                empty
        `onFinish1'`  \ e ->  do
                    r <- liftIO $ readIORef results
                    liftIO $ print ("finish",r::[Int],e)
                    
                    forward $ Finish ""
                    return r
    
    liftIO $ print ("returned",res)
    i <- choose [1,2::Int]
    liftIO $ print i

onFinish1 exc= onFinish1' (return())  exc

onFinish1' :: TransIO a -> (String -> TransIO a) -> TransIO a
onFinish1' proc mx= do
    cont <- getCont
    done <- liftIO $ newIORef False  --finalization already executed
    proc  `onBack`  \(Finish reason) -> do
                -- liftIO $ print ("thread end",reason)


                is <- hasNoChildThreads cont
                guard is  -- previous onFinish not triggered
                f <- liftIO $ atomicModifyIORef done $ \x ->(if x then x else not x,x)
                if f then backtrack else 
                    -- liftIO $ writeIORef done True
                    mx reason
            
-- hasNoChildThreads :: EventF -> TransIO Bool
-- hasNoChildThreads st= do
--     chs <- liftIO $ readMVar $ children st
--     tr ("threads=",length chs,unsafePerformIO myThreadId)
--     -- topState >>= showThreads
--     return $ null chs 

-- onFinish1' :: TransIO a -> (String -> TransIO a) -> TransIO a
-- onFinish1' proc mx= do
--     cont <- getCont
--     done <- liftIO $ newIORef False  --finalization already executed
--     proc  `onException'`  \(Finish reason) -> do
            


--             f <- liftIO $ readIORef done
--             if f then backtrack else do
--                 -- topState >>= showThreads

--                 is <- hasNoChildThreads cont
--                 guard is  -- previous onFinish not triggered
--                 liftIO $ writeIORef done True
--                 mx reason
            

-- hasNoChildThreads st= do
--     chs <- liftIO $ readMVar $ children st
--     return $ null  chs
--   <|> do
--       liftIO $ threadDelay 1000000
--       killBranch
    -- abduce
   -- num <- (async $ return "Hello")<|> (async $  return "world")
   -- labelState "abduce"
   -- option ("f" ::String) "fire"
    -- let fibonacci= fib 0 1 
    --     where
    --     fib a b= do liftIO $ print "fib"; (async (return b) <|> fib  b (a+b)) 
   
--    onException $ \ThreadKilled -> empty
    -- rv <- liftIO $ newEmptyMVar
    -- n <-   choose[1..3] 
    -- x <- (do t <- myThreadId; print ("adquire",t); return t) `atEndProcess` \t -> print("release",t)
    -- liftIO $ ( putMVar rv $ Just x)  `catch` \(_ :: BlockedIndefinitelyOnMVar) -> myThreadId>>= killThread
    
   --`onException'` \(ThreadKilled) -> do liftIO $ print ("freed",unsafePerformIO myThreadId); empty
    -- liftIO (myThreadId >>= killThread >> print "after") `onException'` \(e:: SomeException) -> do liftIO $ print ("handler",e) ; empty
    -- liftIO $ print (n,x)

    -- r <- choose'[1..4]  >>(do t <- myThreadId; print ("adquire",t); return t) `atEndThread` \t -> print("release",t)
    -- liftIO $ print r
    
    -- th <- forkIO $ uninterruptibleMask_   $ do
    --     x <- myThreadId
         
    --     threadDelay 10000000
    --     print "adquired"
    --     (do print x; threadDelay 1000000) `onException` print ("release exception")
    --     print ("release",x)
    -- threadDelay 5000000
    -- throwTo th $ userError "err"
    -- threadDelay 50000000
    -- liftIO $ myThreadId >>= killThread
--    when (num > 10000) $ do
--        st <- getCont
--        liftIO $ killBranch' $ fromJust $ parent st 
   -- option ("w" ::String) "works" 
   -- liftIO $ print "WORKS!"
   -- error "Propagate"
   -- return()
--    when (num > 10000) $ do
--             st <- getCont
--             liftIO $ killBranch'  $ fromJust $  parent st




-- fibs = 0 : 1 : zipWith (+) fibs (tail fibs)
-- testfibs= keep $ threads 0 $ do
--     n <- choose fibs
--     liftIO  $ print n
--     -- onException  $ \(e :: SomeException) -> empty
--     when (n > 10000) killBranch  -- need to be more clean 

testone= keep $ do
    r <- collect 3 $ choose' [1..100] >>= \r -> liftIO  (do threadDelay 1000000 ; print r)
    liftIO $ print r

test4= do
    (async $ do threadDelay 1000000; print "hello") <|> liftIO ( print "word")

   
test3=  noTrans $ do
    r <- runTrans $ collect 2 $ choose' ["hello","world" :: String]
    liftIO $ print r
    
test1= do
   t1 <- liftIO $ getClockTime 
   sum <- foldM  (\sum i -> do
      setParseString $  toLazyByteString $ serialize (i:: Int)
      s <- deserialize
      return $ sum+ s)
      0 [1..1000]
   t2 <- liftIO $ getClockTime
   liftIO $ print (sum :: Int)
   
   

  
   