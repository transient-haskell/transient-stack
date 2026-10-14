{-# LANGUAGE CPP,RecordWildCards,UndecidableInstances,ScopedTypeVariables,FlexibleContexts,MultiParamTypeClasses,
ExistentialQuantification,FlexibleInstances, InstanceSigs #-}

{- |
Continuation-passing engine for the Transient monad (experimental).

Based on <https://gist.github.com/agocorona/2c9149c4d2035f21952fc1d1691b7bde>.
Uses a single type-erased continuation @a -> TransIO b@ (the @t@\/@r@
parameter is erased); the 'Monad' bind operator guarantees type safety by
construction.
-}
module Transient.CEngine where

import Control.Monad
import Control.Monad.State hiding(lift)
import Control.Applicative
import Data.Typeable
import qualified Data.Map                               as M
import Data.IORef
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Exception

import qualified Data.ByteString.Char8                  as BS
import qualified Data.ByteString.Lazy.Char8             as BSL
import Data.String

import System.IO.Unsafe
import Data.Time.Clock


import Data.Functor ( (<&>) )

import Unsafe.Coerce
import qualified Debug.Trace                as Debug






trace _= id
trace1= Debug.trace



-- | Increase the trace indentation level by 2.
indent, outdent :: MonadIO m => m ()

-- | Decrease the trace indentation level by 2.
indent =  liftIO $ modifyIORef rindent $ \n -> n+2
outdent=  liftIO $ modifyIORef rindent $ \n -> n-2


{-# NOINLINE rindent #-}
-- | Global IORef tracking the current trace indentation level.
rindent= unsafePerformIO $ newIORef 0
-- | Format a value with a timestamp, thread-id colour, and current indentation.
color :: Show a => a -> String
color x= unsafePerformIO $ do
    t <- getCurrentTime
    th <- myThreadId
    sps <- readIORef rindent >>= \n -> return $ replicate n ' '
    let col=  read (drop 9 (show th)) `mod` (36-31)+31
    return $ show t <> "\x1b["++ show col ++ ";49m" ++ sps ++ show (th,x) ++ "\x1b[0m\n"
-- | trace if -DDEBUG is set
tr x=  trace (color x) $ return ()

-- | trace to the standard error either even if ghc's flag -DDEBUG is set
ttr :: (Show a, Monad m) => a -> m ()
ttr x= trace1 ( "=======>" <> color x) $  return ()

-- | trace to the standard output
tttr :: (MonadIO m, Show a) => a -> m ()
tttr x = liftIO $ putStrLn $ "\x1b[34mINFO\x1b[0m " <> color x


-- | Conditionally trace @x@ (only when -DDEBUG is set) while returning @f@.
tracec x f= Debug.trace (color x) f

type StateIO = StateT TranShip IO

newtype Transient r m a = Transient { runContT :: (Maybe a -> m  (Maybe r)) -> m  (Maybe r) }

type TransIO a= Transient a StateIO a

{-
Expected: Transient a StateIO (Either String a)
    Actual: Transient a StateIO (Either String a)
-}

transient :: StateIO (Maybe a) -> TransIO a
transient= Transient . const

runTrans :: TransIO a -> StateIO (Maybe a)
runTrans t=   runContT  t  return



type SData = ()


data ExecMode = Remote | Parallel | Serial
  deriving (Typeable, Eq, Show)


type PolyMap = M.Map TypeRep SData


data Status = Dead                   -- killed waiting to be eliminated
              --  | DeadParent             -- Dead with some childs active
               | Alive                  -- working
              --  | Parent                 -- with some childs
              --  | Listener [IdCallback]  -- The number of callbacks inside react ans a MVarS.

  deriving (Eq, Show,Ord)

type Listener= String

data LifeCycle =LF Status [Listener] deriving Show

-- | TranShip describes the context of a TransientIO computation:
data TranShip = forall a b. TranShip
  {
    -- fcomp       :: a -> TransIO b
    -- ^ List of continuations

    mfData      :: PolyMap
    -- ^ State data accessed with get/set/Data/State/RState etc operations

  , mfSequence  :: Int
  , rThreadId   :: IORef ThreadId
  , freeTh      :: Bool
    -- ^ When 'True', threads are not killed using kill primitives

  , parent      :: IORef(Maybe TranShip)
    -- ^ The parent of this thread

  , children    :: MVar [TranShip]
    -- ^ Forked child threads, used only when 'freeTh' is 'False'

  , maxThread   :: Maybe (MVar Int)
    -- ^ Maximum number of threads that are allowed to be created

  , labelth     :: IORef (LifeCycle, BS.ByteString)
    -- ^ Label the thread with its lifecycle state and a label string
  , parseContext :: ParseContext
  , execMode :: ExecMode
  } deriving Typeable

lazy= unsafePerformIO

threadId s= lazy $ readIORef $ rThreadId s

instance Read SomeException where
  readsPrec n str  = [(SomeException $ ErrorCall str,"")] -- $ "attempting to deserialize  error: <"<> str <> ">"

      -- [(s , r)] -> [(SomeException $ ErrorCall s, r)]
      -- _ -> error $ "Can not parse " <> str <>" to type SomeException" 

-- | 'StreamData' represents an result in an stream being generated.
data StreamData a =
      SMore a               -- ^ More  to come
    | SLast a               -- ^ This is the last one
    | SDone                 -- ^ No more, we are done
    | SError SomeException  -- ^ An error occurred
    deriving (Typeable, Show,Read)

instance Functor StreamData where
    fmap :: (a -> b) -> StreamData a -> StreamData b
    fmap f (SMore a)= SMore (f a)
    fmap f (SLast a)= SLast (f a)
    fmap _ SDone= SDone
    fmap _ (SError e)= SError e



data ParseContext  = ParseContext { more   :: TransIO  (StreamData BSL.ByteString)
                                  , buffer :: BSL.ByteString
                                  , done   :: IORef Bool} deriving Typeable

-- | To define primitives for all the transient monads:  TransIO, Cloud and Widget
class MonadState TranShip m => TransMonad m

instance  MonadState TranShip m => TransMonad m

-- instance MonadTrans TransIO  where

--     lift m = Transient ((ety m) >>=)

instance  MonadState  TranShip (Transient r StateIO) where
    get= lift get
    put= lift . put


-- | Run a computation in the underlying state monad. it is a little lighter and
-- performant and it should not contain advanced effects beyond state.
noTrans :: StateIO x -> TransIO  x
noTrans x = transient $ Just <$> x



-- emptyEventF :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [TranShip] -> TranShip
emptyEventF th label par childs =
  TranShip { -- event      = mempty
        --  , xcomp      = empty
          --  fcomp      = const empty
           mfData     = mempty
         , mfSequence = 0
         , rThreadId   = lazy $ newIORef th -- unsafePerformIO $ newIORef th
         , freeTh     = False
         , parent     = par
         , children   = childs
         , maxThread  = Nothing
         , labelth    = label
         , parseContext = ParseContext (return SDone) mempty (unsafePerformIO $ newIORef True)
         , execMode = Serial}

-- | Run a transient computation with a default initial state. This is for basic testing. This does NOT support effects
runTransient :: TransIO a -> IO (Maybe a, TranShip)
runTransient t = do
  th     <- myThreadId
  label  <- newIORef  (LF Alive [], mempty)
  childs <- newMVar []
  par    <- newIORef Nothing
  let topState = emptyEventF th label par childs
  runStateT (runTrans t) topState

-- | only used by keep* primitives
runTransient1 :: TransIO a -> IO (Maybe a, TranShip)
runTransient1 t = do
  th     <- myThreadId
  label  <- newIORef  (LF Alive [], mempty)
  childs <- newMVar []
  par    <- newIORef Nothing
  let topState = emptyEventF th label par childs
  writeIORef rtopState topState
  runStateT (runTrans t) topState

{-#NOINLINE rtopState#-}
-- | Global IORef holding the top-level 'TranShip' state (set by 'runTransient1').
rtopState= unsafePerformIO $ newIORef $ error "no top state defined"

-- | Run a transient computation with a given initial state. This is for basic testing. This does NOT support effects
runTransState :: TranShip -> TransIO x -> IO (Maybe x, TranShip)
runTransState st x = runStateT (runTrans x) st



-- | Get the current continuation (constructed via 'callCC' over the state monad transformer).
getCont :: StateIO (a -> TransIO b)
getCont= do
  let f x = callCC (\k ->   k $ unsafeCoerce  x)
  return $ unsafeCoerce f

-- | Run the continuation included in the state
runCont :: p -> TranShip ->  StateT TranShip IO (Maybe a)
runCont x _ = do
  k <- getCont
  runTrans $ k x

callCC :: ((a -> Transient r m b) -> Transient r m a) -> Transient r m a
callCC f = Transient $ \ c -> runContT (f (\ x -> Transient $ \ _ ->  c $ Just x)) c



-- | Run the continuation included in the state. The result in the IO monad.
runContIO :: p -> TranShip -> IO (Maybe a, TranShip)
runContIO x cont = runStateT (runCont x cont) cont

-- | Compose a list of continuations.
{-# INLINE compose #-}
compose :: (a -> TransIO b) -> (a -> TransIO b)
-- compose []     = const empty
compose =  id -- (f:fs) = \x -> f x >>= compose fs

-- -- | Run the closure  (the 'x' in 'x >>= f') of the current bind operation.
-- -- runClosure :: TranShip -> StateIO (Maybe a)
-- runClosure x   = unsafeCoerce (runTrans x)



-- -- | Save a closure and a continuation ('x' and 'f' in 'x >>= f').
-- setContinuation ::  (a -> TransIO b) -> (c -> TransIO d) -> StateIO ()
-- setContinuation   c fs = modify $ \TranShip{..} -> TranShip {fcomp = c >=> unsafeCoerce fs ,   .. }

-- -- | Save a closure and continuation, run the closure, restore the old continuation.
-- -- | NOTE: The old closure is discarded.
-- withContinuation :: b -> TransIO a -> TransIO a
-- withContinuation c mx = do
--   TranShip { fcomp = fs, .. } <- get
--   put $ TranShip { fcomp = unsafeCoerce c >=> fs, .. }
--   r <- mx
--   restoreStack fs
--   return r

-- | Restore the continuations to the provided ones.
-- | NOTE: Events are also cleared out.
-- restoreStack :: TransMonad m => (a -> TransIO b) -> m ()
-- restoreStack _= return ()



-- Instances for Transient Monad


instance (Monad m) => Functor (Transient r m) where
    fmap f m = Transient $ \c -> runContT m $ \ mx->
             case mx of
                 Just x ->  c $ Just $ f x
                 Nothing ->  return Nothing


-- | the applicative instance executes both terms in parallel if the first term executes in a different thread.
-- Since any of the two terms can return 0, 1 or more results, the result of the applicative will be a stream of
-- results depending on what is the value of each term has in real time. 
--
-- It is not a combinatorial applicative: if one of the terms hasn't returned at least one result, any value produced
-- by the other term is not buffered and it is ignored.
--
-- It has also a Serial execution mode used for parsing. 
instance  Applicative (Transient r StateIO) where
  pure a  = Transient ($ Just a)

  mf <*> mx = do

    r1 <- liftIO $ newIORef Nothing
    r2 <- liftIO $ newIORef Nothing
    fparallel r1 r2 <|> xparallel r1 r2

    where

    fparallel r1 r2= do
      tr "fparallel"
      f <- mf
      liftIO $ writeIORef r1 (Just f)
      mr <- liftIO (readIORef r2)
      case mr of
            Nothing -> empty
            Just x  -> return $ f x

    xparallel r1 r2 = do
      tr "xparallel"
      mr <- liftIO (readIORef r1)
      case mr of
            Nothing -> do

              p <- gets execMode
              tr ("EXECMODE",p)
              if p== Serial then empty else do

                       -- the first term may be being executed in parallel and will give his result later
                       x <- mx
                       liftIO (writeIORef r2 $ Just x)

                       mr <- liftIO (readIORef r1)
                      --  tr ("XPARALELL",isJust mr)
                       case mr of
                         Nothing -> empty
                         Just f  -> return $ f x


            Just f -> do
              x <- mx
              liftIO $ writeIORef r2 (Just x)
              return $ f x




-- | stop the current computation and does not execute any alternative computation
fullStop :: TransIO stop
fullStop= do modify $ \s ->s{execMode= Remote} ; stop

-- #ifndef BROWSER11
instance   Monad (Transient r StateIO) where
    return  = pure
    m >>= k  = Transient $ \c -> runContT m (\a -> runContT (mayb k a) c)
     where
     mayb k (Just x)= k x
     mayb _ Nothing =  empty




lift m = Transient ((Just <$> m) >>=)

instance  MonadIO (Transient r StateIO) where
    liftIO = lift . liftIO

instance (Monoid a) => Monoid (Transient r StateIO a) where
    -- mappend x y = mappend <$> x <*> y
  mempty      = return mempty


  -- mappend  = (<>)

instance Monoid a => Semigroup (Transient r StateIO a) where
    (<>)=  mappendt

-- | Lift 'mappend' into the 'Transient' monad: run both branches and combine their results.
mappendt x y = mappend <$> x <*> y


instance  Alternative (Transient r StateIO) where
    empty=  Transient ( $  Nothing)
    f <|> g= Transient $ \ k ->do
              mr <- runContT f k
              was <- gets execMode
              if was == Remote
                then return Nothing
                else case mr of
                  Nothing  -> runContT g k
                  justr -> return justr








instance MonadFail (Transient r StateIO) where
  fail = error

-- readWithErr :: (Typeable a, Read a) => Int -> String -> IO [(a, String)]
-- readWithErr n line =
--   (v `seq` return [(v, left)])
--      `catch` (\(_ :: SomeException) ->
--                 throw $ ParseError $ "read error trying to read type: \"" ++ show (typeOf v)
--                      ++ "\" in:  " ++ " <" ++ show line ++ "> ")
--   where (v, left):_ = readsPrec n line

newtype ParseError= ParseError String

instance Show ParseError where
   show (ParseError s)= "ParseError " ++ s

instance Exception ParseError

-- | Like 'read' but throws 'ParseError' with type information on failure.
read' s= case readsPrec' 0 s of
    [(x,"")] -> x

    _  -> throw $ ParseError $ "reading " ++ s


-- | Like 'readsPrec' but wraps IO exceptions as 'ParseError'.
readsPrec' n = unsafePerformIO . readWithErr n

  where
  readWithErr :: (Typeable a, Read a) => Int -> String -> IO [(a, String)]
  readWithErr n line =
    (v `seq` return [(v, left)])
      `catch` (\(SomeException e) ->
                  throw $ ParseError $ "read error trying to read type: \"" ++ show (typeOf v)
                      ++ "\" in:  " ++ " <" ++ show line ++ "> ")
    where (v, left):_ = readsPrec n line


-- | A synonym of 'empty' that can be used in a monadic expression. It stops
-- the computation, which allows the next computation in an 'Alternative'
-- ('<|>') composition to run.
stop :: Alternative m => m stopped
stop = empty

instance (Num a,Eq a,Fractional a) =>Fractional (TransIO a)where
     mf / mg = (/) <$> mf <*> mg
     fromRational r =  return $ fromRational r


instance (Num a, Eq a) => Num (TransIO a) where
  fromInteger = return . fromInteger
  mf + mg     = (+) <$> mf <*> mg
  mf * mg     = (*) <$> mf <*> mg
  negate f    = f <&> negate
  abs f       = f <&> abs
  signum f    = f <&> signum


instance (IsString a) => IsString (TransIO a) where
  fromString = return . fromString

class AdditionalOperators m where

  -- | Run @m a@ discarding its result before running @m b@ .
  (**>)  :: m a -> m b -> m b

  -- | Run @m b@ once, discarding its result, after @m a@ is
  -- executed for the first time and before running other operation after it
  --
  (<**)  :: m a -> m b -> m a

  atEnd' :: m a -> m b -> m a
  atEnd' = (<**)

  -- | Run @m b@ discarding its result,  after each thread in @m a@ is executed and
  -- before any other  operation after it
  (<***) :: m a -> m b -> m a

  atEnd  :: m a -> m b -> m a
  atEnd  = (<***)



instance AdditionalOperators (Transient  r StateIO) where

  (**>) f g =
      Transient $ \k ->  runContT f $ \x -> runContT g  k

  (<***) f g =
      Transient $ \k -> runContT f $ \mx -> do
             case mx of
                 Nothing -> return Nothing
                 _ -> runContT g (const $ return Nothing) >>  k mx

  (<**) f g =
      Transient $ \k ->  runContT f $ \mx -> do
             case mx of
                 Nothing -> return Nothing
                 _ -> runContT g (const $ return Nothing) >>  k mx

infixl 4 <***, <**, **>



-- | Run @b@ once, discarding its result when the first task in task set @a@
-- has finished. Useful to start a singleton task after the first task has been
-- setup.
-- (<|) :: TransIO a -> TransIO b -> TransIO a
-- (<|) ma mb = Transient $ do
--   fs  <- getContinuations
--   ref <- liftIO $ newIORef False
--   setContinuation (cont ref)  fs
--   r   <- runTrans ma
--   restoreStack fs
--   return  r
--   where cont ref x = Transient $ do
--           n <- liftIO $ readIORef ref
--           if n
--             then return $ Just x
--             else do liftIO $ writeIORef ref True
--                     runTrans mb
--                     return $ Just x






-- * Threads
