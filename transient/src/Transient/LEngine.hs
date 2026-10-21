{-# LANGUAGE CPP,RecordWildCards,UndecidableInstances,ScopedTypeVariables,FlexibleContexts,MultiParamTypeClasses,
ExistentialQuantification,FlexibleInstances,InstanceSigs #-}

{- |
The continuation-list engine for the Transient monad.

Each @>>=@ step stores its @f@ fragment in the 'fcomp' list of the 'TranShip'
state (@(x >>= f) >>= f'@ becomes @[f, f']@). When a new thread is forked the
full list is copied, giving each thread its own continuation chain.

This was the first engine implementation and benchmarks faster than the
function-composition engine ('FEngine') for typical workloads.
-}
module Transient.LEngine where

import Control.Monad
import Control.Monad.State
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
import Data.ByteString.Builder (Builder, string7)

import System.IO.Unsafe
import Data.Time.Clock


import Data.Functor ( (<&>) )

import Unsafe.Coerce
import qualified Debug.Trace                as Debug

#ifdef DEBUG
trace= Debug.trace
trace1= Debug.trace
#else

trace _= id
trace1= Debug.trace
#endif


-- | Increase the trace indentation level by 2.
indent :: MonadIO m => m ()
-- | Decrease the trace indentation level by 2.
outdent :: MonadIO m => m ()

indent =  liftIO $ modifyIORef rindent $ \n -> n+2
outdent=  liftIO $ modifyIORef rindent $ \n -> n-2


{-# NOINLINE rindent #-}
-- | Global indentation counter used by the trace helpers.
rindent= unsafePerformIO $ newIORef 0

-- | Format a value for coloured terminal trace output, prefixed with timestamp and thread id.
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


-- | Always-on coloured trace (same as 'Debug.trace' but with 'color' formatting).
tracec x f= Debug.trace (color x) f

type StateIO = StateT TranShip IO

newtype TransIO a = Transient { runTrans :: StateIO (Maybe a) }

transient= Transient

type SData = ()

type EventId = Int

type TransientIO = TransIO


data ExecMode = Remote | Parallel | Serial 
  deriving (Typeable, Eq, Show)


type PolyMap = M.Map TypeRep SData


data Status = Dead                   -- Finished waiting to be eliminated
            | Alive                  -- working

  deriving (Eq, Show,Ord)

type Listener= String

data LifeCycle =LF Status [Listener] deriving Show

-- | A segment of the log of the execution of a distributed computation ('Log'). The instances, the renderer and the
-- operations are in "Transient.Move.Defs": here are only the declarations that the state and the applicative need.
data LogSeg
  = Fixed Builder
    -- ^ immutable segment
  | Wait (IORef Builder)
    -- ^ written by @addWait@ in an applicative term that is asynchronous; it contains @w\/@ until the term is resolved
  | Pending (IO LogB)
    -- ^ the log of a term of an applicative that may not be resolved yet: it is read when the log is serialised

-- | Log builder made of immutable and mutable segments.
newtype LogB = LogB [LogSeg]

type ClosureKey = String

-- | A single element of the execution log: a serialised value, a set of parallel branches, or a cross-session link.
data FragmentType= Fragment{unFragment :: LogB} | Collect [LogB] | Jump ClosureKey

-- | The log of the execution: whether it is being recovered, the part written since the last closure, the
-- segments that remain to be replayed and the hash of the path ('hashClosure').
data Log  = Log{ recover :: Bool , partLog :: LogB, restLog :: [FragmentType],  hashClosure :: Int}

emptyLog :: Log
emptyLog= Log False (LogB []) []  0

-- | Steps of the hash of the path, combined with 'hashStep': entering a logged statement, finishing it,
-- an alternative branch (@w\/@), and the end of an applicative.
hashStep :: Int -> Int -> Int
hashStep h c = (h * 31 + c) `mod` 2147483647

hashExec, hashDone, hashWait, hashApp, hashTerm, hashNode :: Int
hashExec= 1
hashDone= 2
hashWait= 3
hashApp= 4
hashNode= 6   -- entering a node of an applicative: nested nodes start at different points of the path
hashTerm= 5   -- the first term of an applicative, whatever its steps: it can not coincide with the path inside the term

-- | TranShip describes the context of a TransientIO computation:
data TranShip = forall a b. TranShip
  {
    fcomp       :: [a -> TransIO a]
    -- ^ List of continuations

  , mfData      :: PolyMap
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
  , isApplicative :: Bool
  , mfLog :: Log
    -- ^ the log of the execution of a distributed computation. A field and not an entry of 'mfData': it is used in every step
  } deriving Typeable

-- data IsApplicative= NoApp | AppFirst | AppSecond deriving Eq

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


instance MonadState TranShip TransIO where
  get     = Transient $ gets Just
  put x   = Transient $ put x >>  return (Just ())
  state f =  Transient $ do
    s <- get
    let ~(a, s') = f s
    put s'
    return $ Just a

-- | Run a computation in the underlying state monad. it is a little lighter and
-- performant and it should not contain advanced effects beyond state.
noTrans :: StateIO x -> TransIO  x
noTrans x = Transient (x <&> Just)



-- emptyTranShip :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [TranShip] -> TranShip
emptyTranShip th label par childs =
  TranShip {
           fcomp      = []
         , mfData     = mempty
         , mfSequence = 0
         , rThreadId   = lazy $ newIORef th -- unsafePerformIO $ newIORef th
         , freeTh     = False
         , parent     = par
         , children   = childs
         , maxThread  = Nothing
         , labelth    = label
         , parseContext = ParseContext (return SDone) mempty (unsafePerformIO $ newIORef True)
         , execMode = Serial
         , isApplicative= False
         , mfLog= emptyLog}

-- | Run a transient computation with a default initial state. This is for basic testing. This does NOT support effects
runTransient :: TransIO a -> IO (Maybe a, TranShip)
runTransient t = do
  th     <- myThreadId
  label  <- newIORef  (LF Alive [], mempty)
  childs <- newMVar []
  par    <- newIORef Nothing
  let topState = emptyTranShip th label par childs
  runStateT (runTrans t) topState

-- | Like 'runTransient' but also writes the top state to 'rtopState'. Used by the @keep*@ primitives.
runTransient1 :: TransIO a -> IO (Maybe a, TranShip)
runTransient1 t = do
  th     <- myThreadId
  label  <- newIORef  (LF Alive [], mempty)
  childs <- newMVar []
  par    <- newIORef Nothing
  let topState = emptyTranShip th label par childs
  writeIORef rtopState topState
  runStateT (runTrans t) topState

{-#NOINLINE rtopState#-}
-- | Global reference to the root 'TranShip' state. Initialised by 'runTransient1'.
rtopState= unsafePerformIO $ newIORef $ error "no top state defined"

-- | Run a transient computation with a given initial state. This is for basic testing. This does NOT support effects
runTransState :: TranShip -> TransIO x -> IO (Maybe x, TranShip)
runTransState st x = runStateT (runTrans x) st



-- | Lift a 'Maybe' into 'TransIO': 'Just' succeeds, 'Nothing' stops with 'empty'.
emptyIfNothing :: Maybe a -> TransIO a
emptyIfNothing =  Transient  . return


-- | Get the continuation context
getCont :: StateIO (a -> TransIO b)
getCont = do
  TranShip{ fcomp = f } <- get
  return  $ unsafeCoerce $ compose f

-- | Run the continuation included in the state
runCont :: p -> TranShip -> StateT TranShip IO (Maybe a)
runCont x TranShip { fcomp = fs } = runTrans $
  compose fs $ unsafeCoerce x


-- | Run the continuation included in the state. The result in the IO monad.
runContIO :: p -> TranShip -> IO (Maybe a, TranShip)
runContIO x cont = runStateT (runCont x cont) cont



-- | Compose a list of continuations. substitutes : for  >=>
{-# INLINE compose #-}
compose :: [a -> TransIO a] -> (a -> TransIO b)
compose = foldr (>=>) (const empty)





-- | Save a closure and a continuation ('x' and 'f' in 'x >>= f').
setContinuation ::  (a -> TransIO b) -> [c -> TransIO c] -> StateIO ()
setContinuation   c fs = do
  modify $ \TranShip{..} 
                -> TranShip {fcomp =  unsafeCoerce c :  fs
                                  , .. }






-- Instances for Transient Monad

instance Functor TransIO where
  -- Alabado sea Dios y Jesucristo su Hijo
  fmap f mx = do   -- do not change this for f <$> mx. mx can be an stream
    x <- mx
    return $ f x


-- | the applicative instance executes both terms in parallel if the first term executes in a different thread.
-- Since any of the two terms can return 0, 1 or more results, the result of the applicative will be a stream of
-- results depending on what is the value of each term has in real time. 
--
-- It is not a combinatorial applicative: if one of the terms hasn't returned at least one result, any value produced
-- by the other term is not buffered and it is ignored.
--
-- It has also a Serial execution mode used for parsing. 
instance Applicative TransIO where
  pure :: a -> TransIO a
  pure a  = Transient . return $ Just a

  (<*>) :: TransIO (a -> b) -> TransIO a -> TransIO b
  mf <*> mx = apTransIO mf mx

-- | The applicative of 'TransIO'. Each @<*>@ is a node with two sides, the left term L and the right term R, that
-- can be other nodes, so it works with any number of terms.
--
-- == The log of the applicative
--
-- If the first term is asynchronous, L and R run in parallel in different threads. The thread that completes
-- the node is the one that gets the last result, and its log would have only its own side: a remote node (or a
-- restart) that replays it could not complete the applicative. The two 'IORef' of the node, that hold the result
-- of each term, hold also what the term added to the log ('mfLog'):
--
--  * At the end of L, in whatever thread, @r1@ gets the value of L and the segments that L added to the log.
--  * R starts with the log of the start of the node followed by a 'Pending' hole that reads @r1@: the log of L if
--    it is known when the log is serialised, @w\/@ if it is not. The partial steps of L that its thread left in the
--    log (e.g. its first endpoint) are not part of the log of R. At the end of R, @r2@ gets its value and its
--    segments.
--  * The thread that sees both results completes the node with the log of the start followed by the segments of L and
--    of R, in whichever order they arrived.
--
-- Hash: L counts as one step (@hashTerm@), the same in every thread and in the replay of a log with @w\/@, whatever
-- the number of statements of L. At the end of the node the hash advances with @hashApp@, also in the thread that
-- gets no result from the node.
--
-- When L finishes in the same thread as R (an applicative of synchronous terms) nothing is added to the log.
apTransIO :: TransIO (a -> b) -> TransIO a -> TransIO b
apTransIO mf mx =  do

    isapp <- gets isApplicative
    modify $ \s ->s{isApplicative= True}

    -- the log and the hash at the start of the node. Entering the node advances the hash, so the nodes nested in the
    -- first term do not repeat the path of this one
    Log{partLog= LogB seg0, hashClosure= hc} <- gets mfLog
    let h0= hashStep hc hashNode
    modify $ \s -> s{mfLog= (mfLog s){hashClosure= h0}}
    let n0   = length seg0
        hL   = hashStep h0 hashTerm     -- after the first term, whatever its steps
        hEnd = hashStep h0 hashApp      -- after the node

    r1 <- liftIO $ newIORef Nothing     -- value of the first term, the segments that it added to the log, and the thread that got it
    r2 <- liftIO $ newIORef Nothing     -- the same for the second one

    let restoreflag= modify $ \s -> s{isApplicative= isapp}
        setLog segs h= modify $ \s -> s{mfLog= (mfLog s){partLog= LogB segs, hashClosure= h}}
        setHash h= modify $ \s -> s{mfLog= (mfLog s){hashClosure= h}}
        addedSince n= gets $ \s -> let LogB segs= partLog (mfLog s) in drop n segs

        -- the thread that sees both results completes the node
        join ld rd= setLog (seg0 ++ ld ++ rd) hEnd

        fparallel= do
          tr "fparallel"
          f <- mf
          ld <- addedSince n0
          me <- liftIO myThreadId
          liftIO $ writeIORef r1 (Just (f, ld, me))
          setHash hL
          mr <- liftIO (readIORef r2)
          case mr of
                Nothing      -> empty
                Just (x, rd) -> do join ld rd; return $ f x

        xparallel= do
          tr "xparallel"
          mr <- liftIO (readIORef r1)
          case mr of
                Nothing -> do
                  p <- gets execMode
                  tr ("EXECMODE",p)
                  -- the first term may be being executed in parallel and will give its result later
                  if p== Serial then empty else runR
                Just (_, ld, t) -> do
                  me <- liftIO myThreadId
                  -- the first term finished in this thread: its segments are already in the log, the second term goes
                  -- on after them and only the hash is normalised. Otherwise (it finished in another thread while this
                  -- one was starting) the log of this thread has to be rebuilt.
                  if t == me then runSync ld else runR

        runSync ld= do
          x <- mx
          rd <- addedSince (n0 + length ld)
          liftIO $ writeIORef r2 (Just (x, rd))
          mr <- liftIO (readIORef r1)
          case mr of
            Nothing          -> empty
            Just (f, _, _)   -> do setHash hEnd; return $ f x

        runR= do
          -- the log of the second term: the start of the node followed by a hole for the first term. If the first
          -- term is not resolved when the log is serialised, the hole is what the first term has left in this thread
          -- (the tokens @w\/@ of the terms that are pending, so a replay skips them), without the values that the
          -- statements of the term get later: the term may go on after them. When it is resolved, the hole is
          -- all that the term added.
          pending <- addedSince n0
          let frozen (Wait _)= Fixed $ string7 "w/"
              frozen sg      = sg
              hole= Pending $ do
                      m <- readIORef r1
                      return $ case m of
                         Just (_, ld, _) -> LogB ld
                         Nothing      -> LogB (map frozen pending)
          setLog (seg0 ++ [hole]) hL
          x <- mx
          rd <- addedSince (n0 + 1)
          liftIO $ writeIORef r2 (Just (x, rd))
          mr <- liftIO (readIORef r1)
          case mr of
            Nothing      -> empty
            Just (f, ld, _) -> do join ld rd; return $ f x

    r <-  (fparallel <|> xparallel) <|> (restoreflag >> setHash hEnd >> empty)
    restoreflag
    return r



-- | stop the current computation and does not execute any alternative computation
fullStop :: TransIO stop
fullStop= do modify $ \s ->s{execMode= Remote} ; stop

-- #ifndef BROWSER11
instance Monad TransIO where
  return   = pure
  x >>= f  = Transient $ do
    setEventCont x f
    mk <- runTrans x
    resetEventCont
    case mk of
      Just r  -> runTrans (f r)
      Nothing -> return Nothing



{-# INLINABLE setEventCont #-}
-- | Push the continuation @f@ of @x >>= f@ onto the 'fcomp' stack before executing @x@.
setEventCont :: TransIO a -> (a -> TransIO b) -> StateIO ()
setEventCont x f  = modify $ \TranShip { fcomp = fs, .. }
                           -> TranShip {fcomp = unsafeCoerce f :  fs
                                        , .. }

{-# INLINABLE resetEventCont #-}
-- | Pop the topmost continuation off the 'fcomp' stack after @x@ in @x >>= f@ has run.
resetEventCont   =
   modify $ \TranShip { fcomp = fs, .. }
          -> TranShip { fcomp = tailsafe fs, .. }

{-# INLINE tailsafe #-}
-- | 'tail' that returns @[]@ on an empty list instead of throwing.
tailsafe :: [a] -> [a]
tailsafe []     = []
tailsafe (_:xs) = xs



instance MonadIO TransIO where
  liftIO x = Transient $ liftIO x <&> Just

instance Monoid a => Monoid (TransIO a) where
  mempty      = return mempty


  mappend  = (<>)

instance (Monoid a) => Semigroup (TransIO a) where
  (<>)=  mappendt


instance (Monoid a,Monad m) => Semigroup (StateT s m a) where
  (<>)=  mappendt

-- | Lift 'mappend' through the applicative, combining two monoidal computations.
mappendt x y = mappend <$> x <*> y


instance Alternative TransIO where
    empty = Transient $ return  Nothing
    (<|>) x y = Transient $ do
                mx <- runTrans x
                was <- gets execMode
                if was == Remote
                  then return Nothing
                  else case mx of
                        Nothing ->  runTrans y
                        _ -> return mx








instance MonadFail TransIO where
  fail = error



newtype ParseError= ParseError String

instance Show ParseError where
   show (ParseError s)= "ParseError " ++ s

instance Exception ParseError

-- | Total 'read': throws 'ParseError' instead of raising an impure error on parse failure.
read' s= case readsPrec' 0 s of
    [(x,"")] -> x
    _  -> throw $ ParseError $ "reading " ++ s

-- | 'readsPrec' lifted to IO so that parse errors can be caught and re-thrown as 'ParseError'.
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

  -- | Run @m a@, then @m b@ (once, discarding its result), and return the result of @m a@.
  --
  -- If @m b@ has events (a callback that resumes the computation, like the ones of 'react' or 'getMailbox'),
  -- every time one happens the rest of @m b@ is executed, then @m a@ is __executed again__, and the computation
  -- that follows @m a \<** m b@ continues with the new result of @m a@. The value of the event is not passed
  -- on, and neither is the result of @m b@. If @m b@ has no events, @m a@ is executed only once.
  --
  -- It is meant for forms, where @m a@ reads the fields and @m b@ is the button that submits them:
  --
  -- > (name, age) <- render $ (,) <$> inputString Nothing <*> inputInt Nothing <** inputSubmit "send" `fire` OnClick
  --
  -- Each click executes the fields again, which read the content of the page, and continues with their result.
  --
  -- __This definition is necessary for @\<**@ to attend to events in its second term__, above all in Axiom (the web
  -- widgets of the browser). When @m b@ resumes the computation, the continuation that is run is the one of the
  -- point where the event was set. If @\<**@ did not push @m a@ in that continuation, the code that follows would receive
  -- the value of the event (the button) instead of the result of @m a@ (the fields), and @m a@ would not read the page
  -- again. Pushing it is what makes the fields be evaluated again in every event, and only then, with their current
  -- content. See "GHCJS.HPlay.View" in Axiom, where the widgets are combined with this operator.
  --
  -- @m a@ is executed again with the same sequence of identifiers ('genId') that it had the first time. A widget that
  -- creates an element in the page with an identifier takes the same one and finds it, instead of asking for a new one
  -- that does not exist.
  (<**)  :: m a -> m b -> m a

  atEnd' :: m a -> m b -> m a
  atEnd' = (<**)

  -- | Run @m b@ discarding its result,  after each thread in @m a@ is executed and
  -- before any other  operation after it
  (<***) :: m a -> m b -> m a

  atEnd  :: m a -> m b -> m a
  atEnd  = (<***)



instance AdditionalOperators TransIO where

  (**>) :: TransIO a -> TransIO b -> TransIO b
  (**>) x y =
    Transient $ do
      runTrans x
      runTrans y

  (<***) :: TransIO a -> TransIO b -> TransIO a
  (<***) ma mb =
    Transient $ do
      fs  <- getContinuations
      setContinuation (\x -> mb >> return x)  fs
      a <- runTrans ma
      runTrans mb
      restoreStack fs
      return  a
      where
      -- | Warning: Radically untyped stuff. handle with care
      getContinuations :: StateIO [a -> TransIO b]
      getContinuations = do
        TranShip { fcomp = fs } <- get
        return $ unsafeCoerce  fs
      -- | Restore the continuations to the provided ones.
      -- | NOTE: Events are also cleared out.
      restoreStack :: TransMonad m => [a -> TransIO a] -> m ()
      restoreStack fs = modify $ \TranShip {..} -> TranShip {  fcomp = fs, .. }


  (<**) :: TransIO a -> TransIO b -> TransIO a
  (<**) ma mb =
    Transient $ do
      seq0 <- gets mfSequence
      a <- runTrans ma
      fs  <- getContinuations
      -- an event in mb continues executing ma again; its result is the one of the whole
      setContinuation (\_ -> again seq0) fs
      runTrans mb
      restoreStack fs
      return a
      where
      -- ma is executed with the same sequence of identifiers as the first time, so that it finds again what it created
      again seq0 = Transient $ do
        seq1 <- gets mfSequence
        modify $ \TranShip {..} -> TranShip { mfSequence = seq0, .. }
        r <- runTrans ma
        modify $ \TranShip {..} -> TranShip { mfSequence = seq1, .. }
        return r
      getContinuations :: StateIO [a -> TransIO b]
      getContinuations = do
        TranShip { fcomp = fs } <- get
        return $ unsafeCoerce fs
      restoreStack :: TransMonad m => [a -> TransIO a] -> m ()
      restoreStack fs = modify $ \TranShip {..} -> TranShip { fcomp = fs, .. }

infixl 4 <***, <**, **>



-- -- | Run @b@ once, discarding its result when the first task in task set @a@
-- -- has finished. Useful to start a singleton task after the first task has been
-- -- setup.
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


