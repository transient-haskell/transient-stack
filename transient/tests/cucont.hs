-- from https://gist.github.com/agocorona/2c9149c4d2035f21952fc1d1691b7bde
{-# LANGUAGE MultiParamTypeClasses, ExistentialQuantification, ScopedTypeVariables, FlexibleInstances, FlexibleContexts, UndecidableInstances #-}
module TransientCont where  
-- some imports

import Control.Applicative

import Control.Monad.IO.Class

-- import Control.Monad.Trans 

import GHC.Conc

import System.IO.Unsafe

import Data.IORef

import Control.Concurrent.MVar

import qualified Data.Map as M 

import Data.Typeable

import qualified Data.ByteString.Char8 as BS

import Control.Monad.State hiding (lift) 
import Control.Monad
import Data.Monoid

import Unsafe.Coerce

import Control.Exception hiding (onException)



-- convenient debug operator

import Debug.Trace

x !> y=  trace (show y) x
ttr x= traceShow x $ return ()

infixr 0 !>



{-
The Monad class:
class Monad m where
   return :: m a
   (>>=) :: m a -> (a -> m b) -> m b
The second term of (>>=) is a lambda. It is also a kind of continuation. 
It could be seen also as a callback: 
(>>=) can be read as this: when 'm a' (the first term) is executed, apply the second term as a callback
which will receive the result of the first term.
do x <- mx
   y <- my
   z
-- ... is equivalent to:
do x <- mx
   do y <- my
      z
-- ... desugars to:
mx >>= (\x ->
              my >>= (\y ->
                             z ))
However we want to define 'mx' 'my'   etc as compuatations that know their continuations.
In a 'normal' monad each computation does not know what's next.
-}



{- This is the original Continuation Monad
In the continuation monad, each computation 'mx'... is a lambda  whose parametet 'a -> m r' 
is the continuation 'c', in which 'a' is the value returned by the previous term.
-}



newtype Cont r m a = Cont{runCont :: (a -> m r) -> m r}



instance Functor (Cont r m) where

    fmap f m = Cont $ \ c -> runCont m (c . f)



instance Applicative (Cont r m) where

    pure x  = Cont (\c ->c x) -- Cont ($ x)

    f <*> v = Cont $ \ c -> runCont f $ \ g -> runCont v $ \t -> c $ g t



instance Monad (Cont r m) where

  return x = Cont (\c -> c x) -- Cont ($ x)

  -- (>>=) :: Cont r m a -> (a -> Cont r m b) -> Cont r m b

  m >>= k  = Cont $ \ c -> runCont m $ \ x -> runCont ( k x ) c 



  -- in the continuation monad, each term know what is after it, his continuation "c". 

  -- This allows for the programming of powerful effects as we will know below. 

  -- 'x' is of type 'a'

  -- 'm' is of type 'Cont r m a' 

  -- However the Cont monad is weird. the type of the result 'r' depend on a term that is outside of the

  -- computation itself, since  'Cont r m b` === Cont ((b -> m r) -> m r)

  -- it does not materialize in a result. It needs a final lambda 'b -> m r' to produce a value 'm r'





-- State being carried out by the monad. many of these fields are not used here.

type SData= ()



data LifeCycle = Alive | Parent | Listener | Dead

  deriving (Eq, Show)



-- | TranShip describes the context of a TransientIO computation:

data TranShip = TranShip

  { mfData      :: M.Map TypeRep SData

    -- ^ State data accessed with get or put operations

  , mfSequence  :: Int

  , threadId    :: ThreadId

  , freeTh      :: Bool

    -- ^ When 'True', threads are not killed using kill primitives



  , parent      :: Maybe TranShip

    -- ^ The parent of this thread



  , children    :: MVar [TranShip]

    -- ^ Forked child threads, used only when 'freeTh' is 'False'



  , maxThread   :: Maybe (IORef Int)

    -- ^ Maximum number of threads that are allowed to be created



  , labelth     :: IORef (LifeCycle, BS.ByteString)

    -- ^ Label the thread with its lifecycle state and a label string

  , emptyOut    :: Bool

    -- ^ Used by empty

  } deriving Typeable



-- to avoid a further lambda (b -> m r) to get a result 'r',

-- Type coercion is necessary, since continuations can only be modeled fully within Indexed monads. 

-- See paper P. Wadler "Monads and composable continuations" 

--                http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.94.985&rep=rep1&type=pdf

-- The symtom of that problem in the typical continuation monad is the extra parameter r that complicates

--  reasoning. The monad below eliminates the extra parameter by coercing types since, by construction, 

-- the  parameter 'x' of the second term is of the type of the first term of the bind.

ety :: a -> b 

ety=   dontWorryEverithingisOk

tdyn :: a -> Dyn

tdyn=  dontWorryEverithingisOk

fdyn :: Dyn -> a

fdyn = dontWorryEverithingisOk



dontWorryEverithingisOk= unsafeCoerce



type Dyn= ()



-- the new data definition:



newtype Transient m a = Transient { runTransT :: (Dyn -> m a) -> m a }



-- will carry on an state. use the state monad transformer

type StateIO = StateT TranShip IO



-- load our final monad with the payload state we defined above.

type TransIO  = Transient  StateIO 



instance Monad TransIO  where

    return  = pure  --  Transient ($ tdyn a) ===  Transient (\c -> c $ tdyn a)





    -- (>>=) TransIO a -> (a -> TransIO b) -> TransIO b 

    -- (>>=) Transient ((Dyn -> m a) -> m a) -> (a -> Transient ((Dyn -> m b )) -> m b )

    -- m >>= k  = Transient $ \c -> ety $ runTransT m (\x -> 
    --                              ety $ runTransT ( k $ fdyn x) c)
   
    m >>= k = do
        st <- get

        (x,st') <- liftIO $ runTransState st (
                Transient $ \c -> ety $ runTransT m (\x -> 
                                  ety $ runTransT ( k $ fdyn x) c))
                                          `catch` \(Empty st) -> throw (Empty st)
        put st'
        return x
       



-- the instance, type coercions apart, is identical to the standard continuation. BUT...

-- now we know that the result is the result of the second term. a further lambda/continuation/callback 

-- is not needed



instance MonadState  TranShip TransIO where

    get= lift get

    put= lift . put



-- instance MonadTrans (Transient ) where

lift :: StateIO a -> TransIO a
lift m = Transient ((ety m) >>=)



instance MonadIO TransIO  where

    liftIO = lift . liftIO



callCC :: ((a -> Transient  m b) -> Transient  m a) -> Transient  m a

callCC f = Transient $ \ c -> runTransT (f (\ x -> Transient $ \ _ ->  ety $ c $ tdyn x)) c





-- run the monad with an state 'st'

runTransState :: TranShip -> TransIO  a ->  IO ( a, TranShip)

runTransState st t= runStateT  (runTrans t) st 

  where  

  runTrans :: TransIO a -> StateIO  a

  runTrans t=   runTransT  t  (return . ety id )



-- | Run a transient computation with a default initial state

runTransient :: TransIO a -> IO ( a, TranShip)

runTransient t = do

    th     <- myThreadId

    label  <- newIORef $ (Alive, BS.pack "top")

    childs <- newMVar []

    runTransState (emptyEventF th label childs) t

    where

    emptyEventF :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [TranShip] -> TranShip

    emptyEventF th label childs =

        TranShip { mfData     = mempty

               , mfSequence = 0

               , threadId   = th

               , freeTh     = False

               , parent     = Nothing

               , children   = childs

               , maxThread  = Nothing

               , labelth    = label

               , emptyOut   = False }



-- executing the continuation in CallCC with a value is executing the contination with this value. 

-- the rest of the callCC block is ignored 

callCCTest= runTransient $ do



    r <- callCC $ \ret -> do 

        ret  100

        liftIO  $ print "hello"    -- we are here in the Cont/transient monad

        return 1

    liftIO $ print r

    liftIO $ print "world"



-- > main= callCCTest

--  100

--  "world"



callCCTest1= runTransient $ do 

    r <- Transient $ \ret -> do 

            ret $ tdyn 100         -- we are here in the state monad

            liftIO $ print "hello"

            return 1

    liftIO $ print $ r

    liftIO $ print $ "world"



-- > main= callCCTest1

-- 100

-- "world"

-- "hello"



-- empty means the early finalization of a computation and the execution of a possible alernative computation

-- This is implemented by a Empty exception which carries out a computation state.

-- this exception can be catched by the alternative computation, which continue the execution.



newtype Empty= Empty TranShip deriving Typeable

instance Show Empty where show _= "Empty"

instance Exception Empty



instance  Alternative TransIO where

  empty= get >>= \st -> liftIO . throw $ Empty st



  f <|> g= callCC $ \k -> do

       st <- get

       liftIO $ io st f k `catch` \(Empty st) -> do

                    let c =  emptyOut  st

                    -- when c $ throw (Empty st)  -- when the exception comes from the continuation do not execute g

                    io st g k

       empty



       where

       io st f cont= runTransState st{emptyOut=False}  (f >>= cont' ) 

               where cont' x= do modify $ \st ->st{emptyOut=True} ; cont x



instance Functor (Transient  m) where

    fmap f m = Transient $ \c -> ety $ runTransT m $ \ x -> ety c $ f $ fdyn x





instance Applicative TransIO  where

    pure a  = Transient ($ tdyn a)

    -- -- this would be  the standard definition following the continuation monad

    --f <*> v = ety $ Transient $ \ k -> ety $ runTransT f $ \ g -> ety $ runTransT v $ \t -> k $ (ety g) t

    

    -- but we need to give the opportunity to execute both terms in parallel

    -- so we define it as the composition of two alternative computations

    f <*> v =   do

          r1 <- liftIO $ newIORef Nothing

          r2 <- liftIO $ newIORef Nothing

          (fparallel r1 r2)  <|> (vparallel  r1 r2)

      where

      -- to allow parallel execution of both terms, two mutable variables store the result of each term

      -- one executes f, the other v. 

      -- Each term inspect if the other has finished

      --          if it has not finished, trows empty and the thread finish

      --          if has finished, evaluate the result and execute the continuation `k` with the result

      fparallel :: IORef (Maybe(a -> b)) -> IORef (Maybe a) -> TransIO b 

      fparallel r1 r2= ety $ Transient $ \k  -> 

          runTransT f $ \g -> do

                (liftIO $ writeIORef r1  $ Just (fdyn  g)) !> "f write r1"

                mt <- liftIO $ readIORef r2                !> "f read r2"

                case mt of 

                  Just t -> k $ (fdyn g) t

                  Nothing -> get >>= liftIO . throw . Empty 

                  

      vparallel :: IORef (Maybe(a -> b)) -> IORef (Maybe a) -> TransIO b

      vparallel  r1 r2=  ety $ Transient $ \k  ->  

          runTransT v $ \t ->  do

                 (liftIO $ writeIORef r2 $ Just (fdyn t))  !> "v write r2"

                 mg <- liftIO $ readIORef r1               !> "v read r1"

                 case mg of 

                   Nothing -> get >>= liftIO . throw . Empty  

                   Just g ->  k $ (ety g) t 



-- standard monoid definition. Since is defined in terms of Applicative, it allows parallel execution

-- of x and y.

instance Semigroup a => Semigroup (TransIO a) where
  x <> y = (<>) <$> x <*> y

instance Monoid a => Monoid (TransIO a) where

  mappend = (<>) -- mappend <$> x <*> y

  mempty      = return mempty



-- An "algebra" defined in terms of Applicative, so it allows parallel execution!

instance (Num a, Eq a) => Num (TransIO a) where

    fromInteger = return . fromInteger

    mf + mg     = (+) <$> mf <*> mg

    mf * mg     = (*) <$> mf <*> mg

    negate f    = f >>= return . negate

    abs f       = f >>= return . abs

    signum f    = f >>= return . signum









-- How is this parallel execution permitted?  Because we can create threads that execute continuations

-- these threads execute all alternative computations in parallel.

-- since all combinators are constructes in terms of the Applicative operators which are parallel enabled.

--

-- async execute an 'io' operation, then create a thread and  initiates the execution of the continuation within it.

-- then it leaves the current thread with 'empty' so an alternative computation can use this thread.

async :: IO a -> TransIO a 

async io= callCC $ \ret -> do

              st <-  get

              liftIO $ forkIOE $ do

                        runTransState st ( liftIO io >>= ret )  

                        return ()

              empty 



forkIOE x= forkIO $ (x >> return ())  `catch` \(Empty _)-> return () -- myThreadId >>= killThread 



-- the initiator of the monad. since threads may die with an empty exception,

-- we need to keep the program running even if the only thread running is the

-- console loop



mexit= unsafePerformIO $ newEmptyMVar  
runsingleth mx= do

    (runTransient mx  >> return ()) `catch` \(Empty _) -> return ()



keep mx= do

    forkIO $ (runTransient mx  >> return ()) `catch` \(Empty _) -> return ()

    takeMVar mexit  



-- do the same than 'async' but execute the 'io' operation in a loop. each time it creates a new thread.

waitEvents :: IO a -> TransIO a

waitEvents io= callCC $ \ret -> do

      st <- get 

      loop ret st 

      where

      loop ret st=  do

              liftIO $ forkIOE $ do 

                        runTransState st  (liftIO io >>=  ret )

                        return () 

              loop ret st



testWaitEvents= do 

  r <- waitEvents getLine 

  liftIO $ putStr "received: " >> print r



-- > main= keep testWaitEvents

-- > hello

-- received: "hello"

-- > world

-- received: "world"

-- > ssds

-- received: "ssds"



-- asynchronous programs combine algebraically with (<|>)



-- An IRC client:

--

-- main = do

--  h <- withSocketsDo $ connectTo "irc.freenode.net" $ PortNumber $ fromIntegral 6667

--  keep' $ (waitEvents getLine >>= liftIO . hPutStrLn h) <|> 

--          (waitEvents (hGetLine h) >>= liftIO . putStrLn )





-- choose execute as many alternative 'async' operation as there are values in a list.

-- So each value is returned to the continuation, which is executed in a different thread.

-- So it executes the rest of tjhe computation for all the values in parallel.

-- this initiates a parallel non-deterministic computation.

--

-- it is equivalent to  'async(return x1) <|> async(return x2)....`



choose :: [a] -> TransIO a

choose xs = foldl (<|>) empty $ map (async . return) xs







choosetwo=  do 

  r  <- choose [1..3]

  r' <- choose ['a'..'c']

  th <- liftIO  myThreadId
  
  ttr (r,r', th)



 -- > main=keep choosetwo 

-- (2,'a',ThreadId 79)

-- (2,'b',ThreadId 80)

-- (1,'a',ThreadId 78)

-- (1,'b',ThreadId 82)

-- (1,'c',ThreadId 83)

-- (2,'c',ThreadId 84)

-- (3,'a',ThreadId 85)

-- (3,'b',ThreadId 86)

-- (3,'c',ThreadId 87)



pythagoras =  do

  x <- choose [1..10]

  y <- choose ([1 .. x] :: [Int])

  z <- choose [1 .. round $ sqrt(fromIntegral $ 2*x*x)]



  guard (x*x+y*y==z*z)

  th <- liftIO  myThreadId

  liftIO $ print (x, y, z, th)



-- > main= keep $ pythagoras

-- (4,3,5,ThreadId 173)

-- (8,6,10,ThreadId 565)



  

-- A continuation is a callback. we can cheat a callback handler by giving it our continuation.

--

-- So instead of

--

--  > do

--  >    ....

--  >    setCallback ourCallback -- our logic is interrupted here

--

--  > ourCallback value= do 

--  >      foo value; ..... -- ... and continues here

--  >      ...

--

--  Instead of that, now we can write:

--

--  > do

--  >    ....

--  >    value <- react setCallback  (return ())

--  >    foo value                           -- code is not broken

--  >    ...



react 

  :: ((eventdata ->  IO response) -> IO ())

  -> IO  response

  -> TransIO eventdata

react setCallback iob= callCC $ \ret -> do

            st <- get

            liftIO $ setCallback $  \x ->  do runTransState st $ ret x 

                                              iob

            empty



-- react used for console input



-- Let's define a framework with callbacks. 

--

-- Since we may have many threads/modules/programs, I can create a thread which will input from the keyboard.

-- Other modules, probably running in differen threads may set callbacks which this console input thread 

-- could call when some input line is entered.



rcb= unsafePerformIO $ newIORef [] 



setCallback :: String -> (String ->  IO ()) -> IO ()

setCallback name cb= atomicModifyIORef rcb $ \cbs ->  (reverse $ (name,cb) : cbs,())



delCallback name= atomicModifyIORef rcb $ \cbs -> (filter ((/=) name . fst ) cbs,())





-- `reactOption` set one of these callbacks, when the input matches the string `resp` then

-- it returns it, so the rest of the computation is executed.

-- otherwise, empty stops from doing further actions.



reactOption :: String -> String -> TransIO String

reactOption resp message = do 

    liftIO $ do

      putStr "enter "

      putStr resp

      putStr "\t to:"

      putStrLn message

    x <- react (setCallback resp) (return ())

    if  x /= resp then empty else     -- if it is not the expected value, give up

          return resp                 -- return it to his continuation

  



-- the thread that execute the callbacks in a loop

consoleLoop =  do

    x   <- getLine 

    mbs <- readIORef rcb

    -- for each string entered, execute all the callbacks

    mapM (\(n,cb) -> cb x `catch` \(Empty _) -> return())  mbs

    consoleLoop

   







testAlternative=  do 

    r <- async (return "hello") <|> async (return "world") <|> async (return "world2")

    liftIO $ print r



-- > main= keep testAlternative

-- "hello"

-- "world"

-- "world2"



mainReact = do

    fork consoleLoop

    r <- (reactOption "hello" "hello")  <|>  (reactOption "world" "world")

    liftIO $ putStr "received: " >> print r

    where

    fork f= (async f >> empty) <|> return()



-- > main= keep mainReact

-- enter hello      to:hello

-- enter world      to:world

-- > hello

-- received: "hello"

-- > world

-- received: "world"

-- > hello

-- received: "hello" 

    

combination=  do

    r <-  ( async (threadDelay 10000 >> return "hello ")  <>  return "world")  <|> return "world2"

    liftIO $ putStrLn  r

       

-- > main= keep combination

-- world2

-- hello world



  

  





































looptest= runTransient $ do

    setState "hello"

    r <- liftIO $ newIORef 0

    sum  r 1000000

    s <-   getState 

    liftIO $ putStrLn s

  where

  sum r 0= do r <- liftIO $ readIORef r; liftIO $ print r

  sum r x= do

     liftIO $ modifyIORef r $ \v -> v + x 

     sum r $ x -1 









-- option using STM and waitEvents

inputLoop :: IO()

inputLoop= do

  l <- getLine 

  atomically (writeTVar mvline l)  

  inputLoop



wait = unsafePerformIO newEmptyMVar



mvline= unsafePerformIO $  newTVarIO ""



option :: String -> String -> TransIO  String

--option :: [Char] -> Transient r (StateT t IO) [Char]

option resp message= do

  liftIO $ do

    putStr "enter "

    putStr resp

    putStr "\t to:" 

    putStrLn message

  waitEvents . atomically $ do

              x <- readTVar mvline

              if  x== resp then  writeTVar mvline "" >> return resp else GHC.Conc.retry               

     

     -- callCC :: ((a -> Transient r StateIO b) -> Transient r m a) -> Transient r m a

options=do

  forkIO $ inputLoop

  keep $ do 

    r <- option "hello" "hello" <|> option "world" "world" 

    liftIO $ putStr "received: " >> print r 

     



   

class AdditionalOperators m where



  -- | Run @m a@ discarding its result before running @m b@.

  (**>)  :: m a -> m b -> m b



  -- | Run @m b@ discarding its result, after the whole task set @m a@ is

  -- done.

  (<**)  :: m a -> m b -> m a



  atEnd' :: m a -> m b -> m a

  atEnd' = (<**)



  -- | Run @m b@ discarding its result, once after each task in @m a@, and

  -- every time that an event happens in @m a@

  (<***) :: m a -> m b -> m a



  atEnd  :: m a -> m b -> m a

  atEnd  = (<***)



instance AdditionalOperators (Transient StateIO)  where



  -- (**>) :: TransIO a -> TransIO b -> TransIO b

  (**>) f g =  Transient $ \c -> ety $ runTransT f (\x -> ety $ runTransT  g c)

      



  -- (<***) :: TransIO a -> TransIO b -> TransIO a

  (<***) f g = 

      ety $ Transient $ \k -> ety $ runTransT f $ \x ->  ety $ runTransT g  (\_ -> k x)   

      where 

      f' = callCC $ \c -> g >> c ()



  -- (<**) :: TransIO a -> TransIO b -> TransIO a

  (<**) f g = ety $ Transient $ \k -> ety $ runTransT f $ \x ->  ety $ runTransT g  (\_ -> k x)  

--f >>= g   = Transient $ \k ->  runTransT f $ \x -> ety $ runTransT ( g $ unsafeCoerce x) k

  



infixr 1 <***, <**, **>  

----------------------------------backtracking ------------------------





data Backtrack b= forall a r c. Backtrack{backtracking :: Maybe b

                                     ,backStack :: [(b ->TransIO  c,c -> TransIO  a)] }

                                     deriving Typeable







-- | Delete all the undo actions registered till now for the given track id.

-- backCut :: (Typeable b, Show b) => b -> TransIO ()

backCut reason=

     delData $ Backtrack (Just reason)  [] 



-- | 'backCut' for the default track; equivalent to @backCut ()@.

undoCut ::  TransIO ()

undoCut = backCut ()



-- | Run the action in the first parameter and register the second parameter as

-- the undo action. On undo ('back') the second parameter is called with the

-- undo track id as argument.

--

{-# NOINLINE onBack #-}

onBack :: (Typeable b, Show b) => TransIO a -> ( b -> TransIO a) -> TransIO a

onBack ac back =  do

     -- Backtrack mreason _  <- getData `onNothing` backStateOf (typeof bac) !> "HANDLER1"

    -- r <-ac

    --  case mreason  !> ("mreason",mreason) of

    --               Nothing     -> ac

    --               Just reason -> bac reason

     registerBack  ac back

  

   where

         

   typeof :: (b -> TransIO a) -> b

   typeof = undefined



-- | 'onBack' for the default track; equivalent to @onBack ()@.

onUndo ::  TransIO a -> TransIO a -> TransIO a

onUndo x y= onBack x (\() -> y)







-- | Register an undo action to be executed when backtracking. The first

-- parameter is a "witness" whose data type is used to uniquely identify this

-- backtracking action. The value of the witness parameter is not used.

--

--{-# NOINLINE registerUndo #-}

-- registerBack :: (Typeable a, Show a) => (a -> TransIO a) -> a -> TransIO a

registerBack  ac back = callCC $ \k -> do

   md <- getData `asTypeOf` (Just <$> (backStateOf $ typeof back))  !> "HANDLER"

   case md of

        Just (bss@(Backtrack b (bs@((back',_):_)))) ->

          --  when (isNothing b) $ do

          --      addrx  <- addr back'

          --      addrx' <- addr back        -- to avoid duplicate backtracking points

          --      when (addrx /= addrx') $ do return () !> "ADD"; setData $ Backtrack mwit  ( (back,  k):   unsafeCoerce bs)

           setData $  Backtrack b  ( (back,  k):   unsafeCoerce bs)

        Just (Backtrack b []) -> setData $ Backtrack b  [(back , k)]

        Nothing ->  do

           setData $ Backtrack mwit  [  (back , k)] !> "NOTHING"

   ac

  

   where





   typeof :: (b -> TransIO a) -> b

   typeof = undefined

   mwit= Nothing `asTypeOf` (Just $ typeof back)





-- registerUndo :: TransIO a -> TransIO a

-- registerUndo f= registerBack ()  f



-- XXX Should we enforce retry of the same track which is being undone? If the

-- user specifies a different track would it make sense?

--

-- | For a given undo track id, stop executing more backtracking actions and

-- resume normal execution in the forward direction. Used inside an undo

-- action.

--

forward :: (Typeable b, Show b) => b -> TransIO ()

forward reason=  do

    Backtrack _ stack <- getData `onNothing`  (backStateOf reason)

    setData $ Backtrack(Nothing `asTypeOf` Just reason)  stack













-- | Start the undo process for the given undo track id. Performs all the undo

-- actions registered till now in reverse order. An undo action can use

-- 'forward' to stop the undo process and resume forward execution. If there

-- are no more undo actions registered execution stops and a 'stop' action is

-- returned.

--

back :: (Typeable b, Show b) => b -> TransIO a

back reason = do

  Backtrack _ cs <- getData  `onNothing`  backStateOf  reason

  let  bs= Backtrack (Just reason) cs

  setData bs

  goBackt bs           

                                                    !>"GOBACK"



  where



  goBackt (Backtrack _ [] )= empty                       !> "END"

  goBackt (Backtrack Nothing _ )= error "goback: no reason"



  goBackt (Backtrack (Just reason) ((handler,cont) : bs))= do

        

        -- setData $ Backtrack (Just reason) $ tail stack

        -- unsafeCoerce $ first reason !>  "GOBACK2"

        x <- unsafeCoerce handler reason                                        -- !> ("RUNCLOSURE",length stack)



        Backtrack mreason _ <- getData `onNothing`  backStateOf  reason

        -- setData $ Backtrack mreason bs

        --                                                          -- !> "END RUNCLOSURE"



        -- case mr of

        --    Nothing -> return empty                                     --  !> "END EXECUTION"

        case mreason of

                  Nothing    -> do 

                         --setData $ Backtrack Nothing bs

                         unsafeCoerce $ cont x                          !> "FORWARD EXEC"

                  justreason -> do

                        setData $ Backtrack justreason bs

                        goBackt $ Backtrack justreason bs              !> ("BACK AGAIN")

                        empty



backStateOf :: (Monad m, Show a, Typeable a) => a -> m (Backtrack a)

backStateOf reason= return $ Backtrack (Nothing `asTypeOf` (Just reason)) []







------ exceptions ---

--

-- | Install an exception handler. Handlers are executed in reverse (i.e. last in, first out) order when such exception happens in the

-- continuation. Note that multiple handlers can be installed for the same exception type.

--

-- The semantic is thus very different than the one of `Control.Exception.Base.onException`

onException :: Exception e => (e -> TransIO  ()) -> TransIO ()

onException exc= return () `onException'` exc





onException' :: Exception e => TransIO a -> (e -> TransIO a) -> TransIO a

onException' mx f= onAnyException mx $ \e ->

    case fromException e of

       Nothing -> return $ error "do nothing,this should not be evaluated"

       Just e'  -> f e'

  where

  --onAnyException :: TransIO a -> (SomeException ->TransIO a) -> TransIO a

  onAnyException mx f= ioexp `onBack` f

    where 

    ioexp = callCC $ \cont -> do

       st <- get

       ioexp' $ runTransState st (mx >>=cont ) `catch` exceptBack st

    

    ioexp' mx= do

      (mx,st') <- liftIO  mx

      put st'

      case mx of

        Nothing -> empty 

        Just x  -> return x

  

exceptBack st = \(e ::SomeException) ->   -- recursive catch itself

                      runTransState st  (back e ) 

                `catch` exceptBack st





  



-- | Delete all the exception handlers registered till now.

cutExceptions :: TransIO ()

cutExceptions= backCut  (undefined :: SomeException)



-- | Use it inside an exception handler. it stop executing any further exception

-- handlers and resume normal execution from this point on.

continue :: TransIO ()

continue = forward (undefined :: SomeException) !> "CONTINUE"



-- | catch an exception in a Transient block

--

-- The semantic is the same than `catch` but the computation and the exception handler can be multirhreaded

-- catcht1 mx exc= mx' `onBack` exc

--  where

--  mx'= Transient $ const $do

--   st <- get

--   (mx, st) <- liftIO $ runTransState st mx `catch` exceptBack st

--   put st 

--   return mx





catcht :: Exception e => TransIO a -> (e -> TransIO a) -> TransIO a

catcht mx exc= do

      rpassed <- liftIO $ newIORef False

      sandbox  $ do

         delData $ Backtrack (Just (undefined :: SomeException))  [] 



         r <- onException'  mx $ \e -> do

                  passed <- liftIO $ readIORef rpassed

                  if not passed then unsafeCoerce continue >> exc e  else empty

         liftIO $ writeIORef rpassed True

         return r

         

   where

   sandbox :: TransIO a -> TransIO a

   sandbox  mx= do

     exState <- getData `onNothing` backStateOf (undefined :: SomeException)

     mx   <*** setState exState 



-- | throw an exception in the Transient monad

throwt :: Exception e => e -> TransIO a

throwt= back . toException





-- * Extensible State: Session Data Management



-- | Same as 'getSData' but with a more general type. If the data is found, a

-- 'Just' value is returned. Otherwise, a 'Nothing' value is returned.

getData :: (MonadState TranShip m, Typeable a) => m (Maybe a)

getData = resp

  where resp = do

          list <- gets mfData

          case M.lookup (typeOf $ typeResp resp) list of

            Just x  -> return . Just $ unsafeCoerce x

            Nothing -> return Nothing

        typeResp :: m (Maybe x) -> x

        typeResp = undefined



-- | Retrieve a previously stored data item of the given data type from the

-- monad state. The data type to retrieve is implicitly determined from the

-- requested type context.

-- If the data item is not found, an 'empty' value (a void event) is returned.

-- Remember that an empty value stops the monad computation. If you want to

-- print an error message or a default value in that case, you can use an

-- 'Alternative' composition. For example:

--

-- > getSData <|> error "no data"

-- > getInt = getSData <|> return (0 :: Int)

getSData :: Typeable a => TransIO a

getSData =    do

        mx <- getData

        case mx of

          Nothing -> empty 

          Just x  -> return x



-- | Same as `getSData`

getState :: Typeable a => TransIO a

getState = getSData



-- | 'setData' stores a data item in the monad state which can be retrieved

-- later using 'getData' or 'getSData'. Stored data items are keyed by their

-- data type, and therefore only one item of a given type can be stored. A

-- newtype wrapper can be used to distinguish two data items of the same type.

--

-- @

-- import Control.Monad.IO.Class (liftIO)

-- import Transient.Base

-- import Data.Typeable

--

-- data Person = Person

--    { name :: String

--    , age :: Int

--    } deriving Typeable

--

-- main = keep $ do

--      setData $ Person "Alberto"  55

--      Person name age <- getSData

--      liftIO $ print (name, age)

-- @

setData :: (MonadState TranShip m, Typeable a) => a -> m ()

setData x = modify $ \st -> st { mfData = M.insert t (unsafeCoerce x) (mfData st) }

  where t = typeOf x



-- | Accepts a function that takes the current value of the stored data type

-- and returns the modified value. If the function returns 'Nothing' the value

-- is deleted otherwise updated.

modifyData :: (MonadState TranShip m, Typeable a) => (Maybe a -> Maybe a) -> m ()

modifyData f = modify $ \st -> st { mfData = M.alter alterf t (mfData st) }

  where typeResp :: (Maybe a -> b) -> a

        typeResp   = undefined

        t          = typeOf (typeResp f)

        alterf mx  = unsafeCoerce $ f x'

          where x' = case mx of

                       Just x  -> Just $ unsafeCoerce x

                       Nothing -> Nothing



-- | Same as modifyData

modifyState :: (MonadState TranShip m, Typeable a) => (Maybe a -> Maybe a) -> m ()

modifyState = modifyData



-- | Same as 'setData'

setState :: (MonadState TranShip m, Typeable a) => a -> m ()

setState = setData



-- | Delete the data item of the given type from the monad state.

delData :: (MonadState TranShip m, Typeable a) => a -> m ()

delData x = modify $ \st -> st { mfData = M.delete (typeOf x) (mfData st) }



-- | Same as 'delData'

delState :: (MonadState TranShip m, Typeable a) => a -> m ()

delState = delData





-- STRefs for the Transient monad





-- | If the first parameter is 'Nothing' return the second parameter otherwise

-- return the first parameter..

onNothing :: Monad m => m (Maybe b) -> m b -> m b

onNothing iox iox'= do

       mx <- iox

       case mx of

           Just x -> return x

           Nothing -> iox'





testBack = do



   runTransient $ do

        return () !> "before"

        r <-  async (print "hello")  `onBack` \s ->  liftIO $ print $ "received: 111"++ s 

        r <-  async (print "world")  `onBack` \s ->  liftIO $ print $ "received: 222"++ s 



        back "exception"

        empty

   takeMVar wait





testException= do

   runTransient $ do

        return () !> "before"

        onException $ \(s :: SomeException) -> liftIO $  print $ "received: 111"++ show s 

        async $ print "$$$$$$$$$$$$"

        -- r <-  async (print "hello")  `onException'` \(s :: SomeException) -> liftIO $  print $ "received: 111"++ show s 

        -- r <-  async (print "world")  `onException'` \(s :: SomeException) -> liftIO $  print $ "received: 222"++ show s 

        liftIO $ print "AFTER"

        liftIO $ myThreadId >>= print



        error "exception"

   takeMVar wait



mainCatch= do

   runTransient $ do

        async $ print "hello"

        error "error" 

        return ()

      `catcht` (\(e :: SomeException) -> liftIO $ print $ "RECEIVED " ++ show e)

      

   takeMVar wait

main= keep $ do
    (ttr "hello") <|>  (ttr "world")
    
    return()