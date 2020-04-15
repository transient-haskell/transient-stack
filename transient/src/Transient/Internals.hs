------------------------------------------------------------------------------
--
-- Module      :  Transient.Internals
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | See http://github.com/transient-haskell/transient 
-- Everything in this module is exported in order to allow extensibility.
-----------------------------------------------------------------------------
{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ConstraintKinds           #-}
--{-# LANGUAGE StrictData                #-}


module Transient.Internals where

import           Control.Applicative
import           Control.Monad.State
--import           Data.Dynamic
import qualified Data.Map               as M
import           System.IO.Unsafe
import           Unsafe.Coerce
import           Control.Exception hiding (try,onException)
import qualified Control.Exception  (try)
import           Control.Concurrent
-- import           GHC.Real
-- import           GHC.Conc(unsafeIOToSTM)
-- import           Control.Concurrent.STM hiding (retry)
-- import qualified Control.Concurrent.STM  as STM (retry)
import           System.Mem.StableName
import           Data.Maybe
import           Data.List
import           Data.IORef
import           System.Environment
import           System.IO
import           System.IO.Error


import           Data.String
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8             as BSL
import           Data.Typeable
import           Control.Monad.Fail
import           System.Directory

#ifdef DEBUG

import           Debug.Trace
import           System.Exit

tshow :: Show a => a -> x -> x
tshow= Debug.Trace.traceShow
{-# INLINE (!>) #-}
(!>) :: Show a => b -> a -> b
(!>) x y =  trace (show (unsafePerformIO myThreadId, y))  x
infixr 0 !>

#else
tshow ::  a -> x -> x
tshow _ y= y
{-# INLINE (!>) #-}
(!>) :: a -> b -> a
(!>) = const


#endif
tr x= return () !> x


type StateIO = StateT EventF IO


newtype TransIO a = Transient { runTrans :: StateIO (Maybe a) }

type SData = ()

type EventId = Int

type TransientIO = TransIO

data LifeCycle = Alive | Parent | Listener  | Dead
  deriving (Eq, Show)

-- | EventF describes the context of a TransientIO computation:
data EventF = forall a b. EventF
  { event       :: Maybe SData
    -- ^ Not yet consumed result (event) from the last asynchronous computation

  , xcomp       :: TransIO a
  , fcomp       :: [b -> TransIO b]
    -- ^ List of continuations

  , mfData      :: M.Map TypeRep SData
    -- ^ State data accessed with get or put operations

  , mfSequence  :: Int
  , threadId    :: ThreadId
  , freeTh      :: Bool
    -- ^ When 'True', threads are not killed using kill primitives

  , parent      :: Maybe EventF
    -- ^ The parent of this thread

  , children    :: MVar [EventF]
    -- ^ Forked child threads, used only when 'freeTh' is 'False'

  , maxThread   :: Maybe (IORef Int)
    -- ^ Maximum number of threads that are allowed to be created

  , labelth     :: IORef (LifeCycle, BS.ByteString)
    -- ^ Label the thread with its lifecycle state and a label string
  , parseContext :: ParseContext
  , execMode :: ExecMode
  } deriving Typeable

data ParseContext  = ParseContext { more   :: TransIO  (StreamData BSL.ByteString)
                                  , buffer :: BSL.ByteString
                                  , done   :: IORef Bool} deriving Typeable

-- | To define primitives for all the transient monads:  TransIO, Cloud and Widget
class MonadState EventF m => TransMonad m
instance  MonadState EventF m => TransMonad m


instance MonadState EventF TransIO where
  get     = Transient $ get   >>= return . Just
  put x   = Transient $ put x >>  return (Just ())
  state f =  Transient $ do
    s <- get
    let ~(a, s') = f s
    put s'
    return $ Just a

-- | Run a computation in the underlying state monad. it is a little lighter and
-- performant and it should not contain advanced effects beyond state.
noTrans :: StateIO x -> TransIO  x
noTrans x = Transient $ x >>= return . Just

-- | filters away the Nothing responses of the State monad.
-- in principle the state monad should return a single response, but, for performance reasons,
-- it can run inside elements of transient monad (using `runTrans`) which may produce 
-- many results
liftTrans :: StateIO (Maybe b) -> TransIO b
liftTrans  mx= do
    r <- noTrans mx
    case r of
            Nothing -> empty
            Just x  -> return x 
    
emptyEventF :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [EventF] -> EventF
emptyEventF th label childs =
  EventF { event      = mempty
         , xcomp      = empty
         , fcomp      = []
         , mfData     = mempty
         , mfSequence = 0
         , threadId   = th
         , freeTh     = False
         , parent     = Nothing
         , children   = childs
         , maxThread  = Nothing
         , labelth    = label
         , parseContext = ParseContext (return SDone) mempty undefined
         , execMode = Serial}

-- | Run a transient computation with a default initial state
runTransient :: TransIO a -> IO (Maybe a, EventF)
runTransient t = do
  th     <- myThreadId
  label  <- newIORef $ (Alive, BS.pack "top")
  childs <- newMVar []
  runStateT (runTrans t) $ emptyEventF th label childs

-- | Run a transient computation with a given initial state
runTransState :: EventF -> TransIO x -> IO (Maybe x, EventF)
runTransState st x = runStateT (runTrans x) st



emptyIfNothing :: Maybe a -> TransIO a
emptyIfNothing =  Transient  . return


-- | Get the continuation context: closure, continuation, state, child threads etc
getCont :: TransIO EventF
getCont = Transient $ Just <$> get

-- | Run the closure and the continuation using the state data of the calling thread
runCont :: EventF -> StateIO (Maybe a)
runCont EventF { xcomp = x, fcomp = fs } = runTrans $ do
  r <- unsafeCoerce x
  compose fs r

-- | Run the closure and the continuation using its own state data.
runCont' :: EventF -> IO (Maybe a, EventF)
runCont' cont = runStateT (runCont cont) cont

-- | Warning: Radically untyped stuff. handle with care
getContinuations :: StateIO [a -> TransIO b]
getContinuations = do
  EventF { fcomp = fs } <- get
  return $ unsafeCoerce fs

{-
runCont cont = do
  mr <- runClosure cont
  case mr of
    Nothing -> return Nothing
    Just r -> runContinuation cont r
-}

-- | Compose a list of continuations.
{-# INLINE compose #-}
compose :: [a -> TransIO a] -> (a -> TransIO b)
compose []     = const empty
compose (f:fs) = \x -> f x >>= compose fs

-- | Run the closure  (the 'x' in 'x >>= f') of the current bind operation.
runClosure :: EventF -> StateIO (Maybe a)
runClosure EventF { xcomp = x } = unsafeCoerce (runTrans x)

-- | Run the continuation (the 'f' in 'x >>= f') of the current bind operation with the current state.
runContinuation ::  EventF -> a -> StateIO (Maybe b)
runContinuation EventF { fcomp = fs } =
  runTrans . (unsafeCoerce $ compose $  fs)

-- | Save a closure and a continuation ('x' and 'f' in 'x >>= f').
setContinuation :: TransIO a -> (a -> TransIO b) -> [c -> TransIO c] -> StateIO ()
setContinuation  b c fs = do
  modify $ \EventF{..} -> EventF { xcomp = b
                                  , fcomp = unsafeCoerce c : fs
                                  , .. }

-- | Save a closure and continuation, run the closure, restore the old continuation.
-- | NOTE: The old closure is discarded.
withContinuation :: b -> TransIO a -> TransIO a
withContinuation c mx = do
  EventF { fcomp = fs, .. } <- get
  put $ EventF { xcomp = mx
               , fcomp = unsafeCoerce c : fs
               , .. }
  r <- mx
  restoreStack fs
  return r

-- | Restore the continuations to the provided ones.
-- | NOTE: Events are also cleared out.
restoreStack :: TransMonad m => [a -> TransIO a] -> m ()
restoreStack fs = modify $ \EventF {..} -> EventF { event = Nothing, fcomp = fs, .. }

-- | Run a chain of continuations.
-- WARNING: It is up to the programmer to assure that each continuation typechecks
-- with the next, and that the parameter type match the input of the first
-- continuation.
-- NOTE: Normally this makes sense to stop the current flow with `stop` after the
-- invocation.
runContinuations :: [a -> TransIO b] -> c -> TransIO d
runContinuations fs x = compose (unsafeCoerce fs)  x

-- Instances for Transient Monad

instance Functor TransIO where
  fmap f mx = do
    x <- mx
    return $ f x
    

instance Applicative TransIO where
  pure a  = Transient . return $ Just a

  mf <*> mx = do -- do f <- mf; x <- mx ; return $ f x
    
    r1 <- liftIO $ newIORef Nothing
    r2 <- liftIO $ newIORef Nothing
    fparallel r1 r2 <|> xparallel r1 r2
    
    where

    fparallel r1 r2= do
      f <- mf 
      liftIO $ (writeIORef r1 $ Just f)
      mr <- liftIO (readIORef r2) 
      case mr of
            Nothing -> empty 
            Just x  -> return $ f x
          
    xparallel r1 r2 = do
      
      mr <- liftIO (readIORef r1)
      case mr of
            Nothing -> do

              p <- gets execMode
              
              if p== Serial then empty else do
                       x <- mx
                       liftIO $ (writeIORef r2 $ Just x)
                       
                       mr <- liftIO (readIORef r1)
                       case mr of
                         Nothing -> empty 
                         Just f  -> return $ f x

              
            Just f -> do
              x <- mx
              liftIO $ (writeIORef r2 $ Just x)
              return $ f x


     

data ExecMode = Remote | Parallel | Serial
  deriving (Typeable, Eq, Show)
  
-- | stop the current computation and does not execute any alternative computation
fullStop :: TransIO stop
fullStop= do modify $ \s ->s{execMode= Remote} ; stop

instance Monad TransIO where
  return   = pure
  x >>= f  = Transient $ do
    setEventCont x f
    mk <- runTrans x
    resetEventCont mk
    case mk of
      Just k  -> runTrans (f k)
      Nothing -> return Nothing

instance MonadIO TransIO where
  liftIO x = Transient $ liftIO x >>= return . Just

instance Monoid a => Monoid (TransIO a) where
  mempty      = return mempty

#if MIN_VERSION_base(4,11,0) 
  mappend  = (<>) 
  
instance (Monoid a) => Semigroup (TransIO a) where
  (<>)=  mappendt
#else
  mappend= mappendt
#endif

mappendt x y = mappend <$> x <*> y


instance Alternative TransIO where
    empty = Transient $ return  Nothing
    (<|>) = mplus

instance MonadPlus TransIO where
  mzero     = empty
  mplus x y = Transient $ do
    mx <- runTrans x

    was <- gets execMode -- getData `onNothing` return Serial
    if was == Remote

      then return Nothing
      else case mx of
            Nothing -> runTrans y

            justx -> return justx

instance MonadFail TransIO where
  fail _ = mzero

readWithErr :: (Typeable a, Read a) => Int -> String -> IO [(a, String)]
readWithErr n line =
  (v `seq` return [(v, left)])
     `catch` (\(_ :: SomeException) ->
                throw $ ParseError $ "read error trying to read type: \"" ++ show (typeOf v)
                     ++ "\" in:  " ++ " <" ++ show line ++ "> ")
  where (v, left):_ = readsPrec n line

newtype ParseError= ParseError String

instance Show ParseError where
   show (ParseError s)= "ParseError " ++ s 

instance Exception ParseError

read' s= case readsPrec' 0 s of
    [(x,"")] -> x

    _  -> throw $ ParseError $ "reading " ++ s
    


readsPrec' n = unsafePerformIO . readWithErr n





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
  negate f    = f >>= return . negate
  abs f       = f >>= return . abs
  signum f    = f >>= return . signum

class AdditionalOperators m where

  -- | Run @m a@ discarding its result before running @m b@.
  (**>)  :: m a -> m b -> m b

  -- | Run @m b@ discarding its result, after the whole task set @m a@ is
  -- done.
  (<**)  :: m a -> m b -> m a

  atEnd' :: m a -> m b -> m a
  atEnd' = (<**)

  -- | Run @m b@ discarding its result, once after each task in @m a@, and
  -- once again after the whole task set is done.
  (<***) :: m a -> m b -> m a

  atEnd  :: m a -> m b -> m a
  atEnd  = (<***)


   
instance AdditionalOperators TransIO where

  --(**>) :: TransIO a -> TransIO b -> TransIO b
  (**>) x y =
    Transient $ do
      runTrans x
      runTrans y

  --(<***) :: TransIO a -> TransIO b -> TransIO a
  (<***) ma mb =
    Transient $ do
      fs  <- getContinuations
      setContinuation ma (\x -> mb >> return x)  fs
      a <- runTrans ma
      runTrans mb
      restoreStack fs
      return  a

  --(<**) :: TransIO a -> TransIO b -> TransIO a
  (<**) ma mb =
    Transient $ do
      a <- runTrans ma
      runTrans  mb
      return a

infixl 4 <***, <**, **>

-- | Run @b@ once, discarding its result when the first task in task set @a@
-- has finished. Useful to start a singleton task after the first task has been
-- setup.
(<|) :: TransIO a -> TransIO b -> TransIO a
(<|) ma mb = Transient $ do
  fs  <- getContinuations
  ref <- liftIO $ newIORef False
  setContinuation ma (cont ref)  fs
  r   <- runTrans ma
  restoreStack fs
  return  r
  where cont ref x = Transient $ do
          n <- liftIO $ readIORef ref
          if n == True
            then return $ Just x
            else do liftIO $ writeIORef ref True
                    runTrans mb
                    return $ Just x

-- | Set the current closure and continuation for the current statement
{-# INLINABLE setEventCont #-}
setEventCont :: TransIO a -> (a -> TransIO b) -> StateIO ()
setEventCont x f  = modify $ \EventF { fcomp = fs, .. }
                           -> EventF { xcomp = x
                                     , fcomp = unsafeCoerce f :  fs
                                     , .. }


-- | Reset the closure and continuation. Remove inner binds than the previous
-- computations may have stacked in the list of continuations.
-- resetEventCont :: Maybe a -> EventF -> StateIO ()
{-# INLINABLE resetEventCont #-}
resetEventCont mx  =
   modify $ \EventF { fcomp = fs, .. }
          -> EventF { xcomp = case mx of
                        Nothing -> empty
                        Just x  -> unsafeCoerce (head fs) x
                    , fcomp = tailsafe fs
                    , .. }


-- | Total variant of `tail` that returns an empty list when given an empty list.
{-# INLINE tailsafe #-}
tailsafe :: [a] -> [a]
tailsafe []     = []
tailsafe (_:xs) = xs




--instance MonadTrans (Transient ) where
--  lift mx = Transient $ mx >>= return . Just

-- * Threads

waitQSemB   sem = atomicModifyIORef sem $ \n ->
                    if n > 0 then(n - 1, True) else (n, False)
signalQSemB sem = atomicModifyIORef sem $ \n -> (n + 1, ())

-- | Sets the maximum number of threads that can be created for the given task
-- set.  When set to 0, new tasks start synchronously in the current thread.
-- New threads are created by 'parallel', and APIs that use parallel.
threads :: Int -> TransIO a -> TransIO a
threads n process = do
   msem <- gets maxThread
   sem <- liftIO $ newIORef n
   modify $ \s -> s { maxThread = Just sem }
   r <- process <*** (modify $ \s -> s { maxThread = msem }) -- restore it
   return r

-- clone the current state as a child of the current state, with the same thread
cloneInChild name= do
  st    <-  get
  rchs   <- liftIO $ newMVar []
  label <- liftIO $ newIORef (Alive, if not $ null name then BS.pack name else mempty)
  let st' = st { parent   = Just st
               , children = rchs
               , labelth  = label }
  liftIO $ do
     atomicModifyIORef (labelth st) $ \(_, label) -> ((Parent,label),())
     hangThread st st'  -- parent could have more than one children with the same threadId

  return st'

-- remove the current child task from the tree of tasks. 
-- If the child and parent threads are different, the child is killed
removeChild :: (MonadIO m,TransMonad m) => m ()
removeChild = do
  st <- get
  let mparent = parent st
  case mparent of
     Nothing -> return ()
     Just parent -> do 
       sts <- liftIO $ modifyMVar (children parent) $ \ths -> do
                    let (xs,sts)= partition (\st' -> threadId st' /= threadId st) ths
                    ys <- case sts of
                            [] -> return []
                            st':_ -> readMVar $ children st'
                    return (xs ++ ys,sts)
       
       put parent
       case sts of
          [] -> return()
          st':_ -> do
              (status,_) <- liftIO $ readIORef $ labelth st'
              if status == Listener || threadId parent == threadId st then return () else liftIO $  (killThread . threadId) st'
-- | Terminate all the child threads in the given task set and continue
-- execution in the current thread. Useful to reap the children when a task is
-- done, restart a task when a new event happens etc.
--
oneThread :: TransIO a -> TransIO a
oneThread comp = do
  st <- cloneInChild "oneThread"
  
  let rchs= children st
  x   <-  comp
  th  <- liftIO myThreadId
               -- !> ("FATHER:", threadId st)
  chs <- liftIO $ readMVar rchs

  liftIO $ mapM_ (killChildren1 th) chs
               --  !> ("KILLEVENT1 ", map threadId chs )
  return x
  where 
  
  killChildren1 :: ThreadId  ->  EventF -> IO ()
  killChildren1 th state = do
      forkIO $ do
          ths' <- modifyMVar (children state) $ \ths -> do
                    let (inn, ths')=  partition (\st -> threadId st == th) ths
                    return (inn, ths')
          mapM_ (killChildren1  th) ths'
          mapM_ (killThread . threadId) ths'
      return()


-- | Add a label to the current passing threads so it can be printed by debugging calls like `showThreads`
labelState :: (MonadIO m,TransMonad m) => BS.ByteString -> m ()
labelState l =  do
  st <- get
  liftIO $ atomicModifyIORef (labelth st) $ \(status,_) -> ((status,  l), ())

-- | return the threadId associated with an state (you can see all of them with the console option 'ps')
threadState thid= do   
  st <- findState match =<<  topState
  return $ threadId st :: TransIO ThreadId
  where
  match st= do
     (_,lab) <-liftIO $ readIORef $ labelth st
     return $ if lab == thid then True else False

-- | kill the thread subtree labeled as such (you can see all of them with the console option 'ps')
killState thid= do
      st <- findState match =<<  topState
      liftIO $ killBranch' st
      where
      match st= do
         (_,lab) <-liftIO $ readIORef $ labelth st
         return $ if lab == thid then True else False
    

printBlock :: MVar ()
printBlock = unsafePerformIO $ newMVar ()

-- | Show the tree of threads hanging from the state.
showThreads :: MonadIO m => EventF -> m ()
showThreads st = liftIO $ withMVar printBlock $ const $ do
  mythread <- myThreadId

  putStrLn "---------Threads-----------"
  let showTree n ch = do
        liftIO $ do
          putStr $ take n $ repeat ' '
          (state, label) <- readIORef $ labelth ch
          if BS.null label
            then putStr . show $ threadId ch
            else do BS.putStr label; putStr . drop 8 . show $ threadId ch
                    when (state == Dead) $ putStr " dead" -- putStr " " >> putStr (take 3 $ show state) --
          putStrLn $ if mythread == threadId ch then " <--" else ""
        chs <- readMVar $ children ch
        mapM_ (showTree $ n + 2) $ reverse chs
  showTree 0 st

-- | Return the state of the thread that initiated the transient computation
-- topState :: TransIO EventF
topState :: TransMonad m => m EventF
topState = do
  st <- get
  return $ toplevel st
  where toplevel st = case parent st of
                        Nothing -> st
                        Just p  -> toplevel p

{-

getStateFromThread th top = resp
  where
  resp = do
          let thstring = drop 9 . show $ threadId top
          if thstring == th
          then getstate top
          else do
            sts <- liftIO $ readMVar $ children top
            foldl (<|>) empty $ map (getStateFromThread th) sts
  getstate st =
            case M.lookup (typeOf $ typeResp resp) $ mfData st of
              Just x  -> return . Just $ unsafeCoerce x
              Nothing -> return Nothing
  typeResp :: m (Maybe x) -> x
  typeResp = undefined
-}

-- | find the first computation state which match a filter  in the subthree of states
findState :: (MonadIO m, Alternative m) => (EventF -> m Bool) -> EventF -> m EventF 
findState filter top= do
   r <- filter top 
   if r then return top 
        else do
          sts <- liftIO $ readMVar $ children top
          foldl (<|>) empty $ map (findState filter) sts


-- | Return the state variable of the type desired for a thread number
getStateFromThread :: (Typeable a, MonadIO m, Alternative m) => String -> EventF -> m  (Maybe a)
getStateFromThread th top= getstate  =<< findState (matchth th) top
   where
   matchth th th'= do
     let thstring = drop 9 . show $ threadId th'
     return $ if thstring == th then True else False
   getstate st = resp
     where resp= case M.lookup (typeOf $ typeResp resp) $ mfData st of
              Just x  -> return . Just $ unsafeCoerce x
              Nothing -> return Nothing
              
   typeResp :: m (Maybe x) -> x
   typeResp = undefined

-- | execute  all the states of the type desired that are created by direct child threads
processStates :: Typeable a =>  (a-> TransIO ()) -> EventF -> TransIO()
processStates display st =  do

        getstate st >>=  display
        liftIO $ print $ threadId st
        sts <- liftIO $ readMVar $ children st
        mapM_ (processStates display) sts
        where
        getstate st =
            case M.lookup (typeOf $ typeResp display) $ mfData st of
              Just x  -> return $ unsafeCoerce x
              Nothing -> empty
        typeResp :: (a -> TransIO()) -> a
        typeResp = undefined



-- | Add n threads to the limit of threads. If there is no limit, the limit is set.
addThreads' :: Int -> TransIO ()
addThreads' n= noTrans $ do
  msem <- gets maxThread
  case msem of
    Just sem -> liftIO $ modifyIORef sem $ \n' -> n + n'
    Nothing  -> do
      sem <- liftIO (newIORef n)
      modify $ \ s -> s { maxThread = Just sem }

-- | Ensure that at least n threads are available for the current task set.
addThreads :: Int -> TransIO ()
addThreads n = noTrans $ do
  msem <- gets maxThread
  case msem of
    Nothing  -> return ()
    Just sem -> liftIO $ modifyIORef sem $ \n' -> if n' > n then n' else  n

--getNonUsedThreads :: TransIO (Maybe Int)
--getNonUsedThreads= Transient $ do
--   msem <- gets maxThread
--   case msem of
--    Just sem -> liftIO $ Just <$> readIORef sem
--    Nothing -> return Nothing

-- | Disable tracking and therefore the ability to terminate the child threads.
-- By default, child threads are terminated automatically when the parent
-- thread dies, or they can be terminated using the kill primitives. Disabling
-- it may improve performance a bit, however, all threads must be well-behaved
-- to exit on their own to avoid a leak.
freeThreads :: TransIO a -> TransIO a
freeThreads process = Transient $ do
  st <- get
  put st { freeTh = True }
  r  <- runTrans process
  modify $ \s -> s { freeTh = freeTh st }
  return r

-- | Enable tracking and therefore the ability to terminate the child threads.
-- This is the default but can be used to re-enable tracking if it was
-- previously disabled with 'freeThreads'.
hookedThreads :: TransIO a -> TransIO a
hookedThreads process = Transient $ do
  st <- get
  put st {freeTh = False}
  r  <- runTrans process
  modify $ \s -> s { freeTh = freeTh st }
  return r

-- | Kill all the child threads of the current thread.
killChilds :: TransIO ()
killChilds = noTrans $ do
  cont <- get
  liftIO $ do
    killChildren $ children cont
    writeIORef (labelth cont) (Alive, mempty)
       -- !> (threadId cont,"relabeled")
  return ()

-- | Kill the current thread and the childs.
killBranch :: TransIO ()
killBranch = noTrans $ do
  st <- get
  liftIO $ killBranch' st

-- | Kill the childs and the thread of an state
killBranch' :: EventF -> IO ()
killBranch' cont = do
  forkIO $ do
    killChildren $ children cont
    let thisth  = threadId  cont
        mparent = parent    cont
    when (isJust mparent) $
      modifyMVar_ (children $ fromJust mparent) $ \sts ->
        return $ filter (\st -> threadId st /= thisth) sts
    killThread $ thisth !> ("kill this thread:",thisth)
  return ()
-- * Extensible State: Session Data Management

-- | Same as 'getSData' but with a more general type. If the data is found, a
-- 'Just' value is returned. Otherwise, a 'Nothing' value is returned.
getData :: (TransMonad m, Typeable a) => m (Maybe a)
getData = resp
  where resp = do
          list <- gets mfData
          case M.lookup (typeOf $ typeResp resp) list of
            Just x  -> return . Just $ unsafeCoerce x
            Nothing -> return Nothing
        typeResp :: m (Maybe x) -> x
        typeResp = undefined



-- | Retrieve a previously stored data item of the given data type from the
-- monad state. The data type to retrieve is implicitly determined by the data type.
-- If the data item is not found, empty is executed, so the  alternative computation will be executed, if any, or
-- Otherwise, the computation will stop..
-- If you want to print an error message or a default value, you can use an 'Alternative' composition. For example:
--
-- > getSData <|> error "no data of the type desired"
-- > getInt = getSData <|> return (0 :: Int)
getSData :: Typeable a => TransIO a
getSData = Transient getData

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
setData :: (TransMonad m, Typeable a) => a -> m ()
setData x = modify $ \st -> st { mfData = M.insert t (unsafeCoerce x) (mfData st) }
  where t = typeOf x

-- | Accepts a function which takes the current value of the stored data type
-- and returns the modified value. If the function returns 'Nothing' the value
-- is deleted otherwise updated.
modifyData :: (TransMonad m, Typeable a) => (Maybe a -> Maybe a) -> m ()
modifyData f = modify $ \st -> st { mfData = M.alter alterf t (mfData st) }
  where typeResp :: (Maybe a -> b) -> a
        typeResp   = undefined
        t          = typeOf (typeResp f)
        alterf mx  = unsafeCoerce $ f x'
          where x' = case mx of
                       Just x  -> Just $ unsafeCoerce x
                       Nothing -> Nothing

-- | Either modify according with the first parameter or insert according with the second, depending on if the data exist or not. It returns the
-- old value or the new value accordingly.
--
-- > runTransient $ do                   modifyData' (\h -> h ++ " world") "hello new" ;  r <- getSData ; liftIO $  putStrLn r   -- > "hello new"
-- > runTransient $ do setData "hello" ; modifyData' (\h -> h ++ " world") "hello new" ;  r <- getSData ; liftIO $  putStrLn r   -- > "hello world"
modifyData' :: (TransMonad m, Typeable a) => (a ->  a) ->  a -> m a
modifyData' f  v= do
  st <- get
  let (ma,nmap)=  M.insertLookupWithKey alterf t (unsafeCoerce v) (mfData st)
  put st { mfData =nmap}
  return $ if isNothing ma then v else unsafeCoerce $ fromJust  ma
  where t          = typeOf v
        alterf  _ _ x = unsafeCoerce $ f $ unsafeCoerce x

-- | Same as modifyData
modifyState :: (TransMonad m, Typeable a) => (Maybe a -> Maybe a) -> m ()
modifyState = modifyData

-- | Same as 'setData'
setState :: (TransMonad m, Typeable a) => a -> m ()
setState = setData

-- | Delete the data item of the given type from the monad state.
delData :: (TransMonad m, Typeable a) => a -> m ()
delData x = modify $ \st -> st { mfData = M.delete (typeOf x) (mfData st) }

-- | Same as 'delData'
delState :: (TransMonad m, Typeable a) => a -> m ()
delState = delData


-- STRefs for the Transient monad

newtype Ref a = Ref (IORef a)


-- | Initializes a new mutable reference  (similar to STRef in the state monad)
-- It is polimorphic. Each type has his own reference
-- It return the associated IORef, so it can be updated in the IO monad
newRState:: (MonadIO m,TransMonad m, Typeable a) => a -> m (IORef a)
newRState x= do 
    ref@(Ref rx) <- Ref <$> liftIO (newIORef x)
    setData  ref
    return rx

-- | mutable state reference that can be updated (similar to STRef in the state monad)
-- They are identified by his type.
-- Initialized the first time it is set.
setRState:: (MonadIO m,TransMonad m, Typeable a) => a -> m ()
setRState x= do
    Ref ref <- getData `onNothing` do
                            return () !> "SETRSTATE NOTHING"
                            ref <- Ref <$> liftIO (newIORef x)
                            setData  ref
                            return  ref
    liftIO $ atomicModifyIORef ref $ const (x,())

getRData :: (MonadIO m, TransMonad m, Typeable a) => m (Maybe a)
getRData= do
    mref <- getData
    case mref of
     Just (Ref ref) -> Just <$> (liftIO $ readIORef ref)
     Nothing -> return Nothing

    
getRState :: Typeable a => TransIO a
getRState= Transient getRData

delRState x= delState (undefined `asTypeOf` ref x)
  where ref :: a -> Ref a
        ref = undefined

-- | Run an action, if it does not succeed, undo any state changes
-- that may have been caused by the action and allow aternative actions to run with the original state
try :: TransIO a -> TransIO a
try mx = do
  s <- get
  mx <|> (modify (const s) >> empty)

-- | Executes the computation and reset the state either if it fails or not.
sandbox :: TransIO a -> TransIO a
sandbox mx = do
  sd <- gets mfData
  mx <*** modify (\s ->s { mfData = sd})

-- | generates an identifier that is unique within the current program execution
genGlobalId  :: MonadIO m => m Int
genGlobalId= liftIO $ atomicModifyIORef rglobalId $ \n -> (n +1,n)

rglobalId= unsafePerformIO $ newIORef (0 :: Int)

-- | Generator of identifiers that are unique within the current monadic
-- sequence They are not unique in the whole program.
genId :: TransMonad m => m Int
genId = do
  st <- get
  let n = mfSequence st
  put st { mfSequence = n + 1 }
  return n

getPrevId :: TransMonad m => m Int
getPrevId = gets mfSequence

instance Read SomeException where

  readsPrec n str = [(SomeException $ ErrorCall s, r)]
    where [(s , r)] = readsPrec n str

-- | 'StreamData' represents an result in an stream being generated.
data StreamData a =
      SMore a               -- ^ More  to come
    | SLast a               -- ^ This is the last one
    | SDone                 -- ^ No more, we are done
    | SError SomeException  -- ^ An error occurred
    deriving (Typeable, Show,Read)
    
instance Functor StreamData where
    fmap f (SMore a)= SMore (f a)
    fmap f (SLast a)= SLast (f a)
    fmap _ SDone= SDone

-- | A task stream generator that produces an infinite stream of results by
-- running an IO computation in a loop, each  result may be processed in different threads (tasks)
-- depending on the thread limits stablished with `threads`.
waitEvents :: IO a -> TransIO a
waitEvents io = do
  mr <- parallel (SMore <$> io)
  case mr of
    SMore  x -> return x
    SError e -> back   e

-- | Run an IO computation asynchronously  carrying
-- the result of the computation in a new thread when it completes.
-- If there are no threads available, the async computation and his continuation is executed
-- in the same thread before any alternative computation.

async :: IO a -> TransIO a
async io = do
  mr <- parallel (SLast <$> io)
  case mr of
    SLast  x -> return x
    SError e -> back   e

-- | Avoid the execution of alternative computations when the computation is asynchronous
--
-- > sync (async  whatever) <|>  liftIO (print "hello") -- never print "hello"
sync :: TransIO a -> TransIO a
sync x = do
  was <- gets execMode -- getSData <|> return Serial
  r <- x <** modify (\s ->s{execMode= Remote}) -- setData Remote
  modify $ \s -> s{execMode= was}
  return r

-- | create task threads faster, but with no thread control: @spawn = freeThreads . waitEvents@
spawn :: IO a -> TransIO a
spawn = freeThreads . waitEvents

-- | An stream generator that run an IO computation periodically at the specified time interval. The
-- task carries the result of the computation.  A new result is generated only if
-- the output of the computation is different from the previous one.  
sample :: Eq a => IO a -> Int -> TransIO a
sample action interval = do
  v    <- liftIO action
  prev <- liftIO $ newIORef v
  waitEvents (loop action prev) <|> return v
  where 
  loop action prev = loop'
    where 
    loop' = do
            threadDelay interval
            v  <- action
            v' <- readIORef prev
            if v /= v' then writeIORef prev v >> return v else loop'


-- | Runs the rest of the computation in a new thread. Returns 'empty' to the current thread
abduce = async $ return ()


-- | fork an independent process. It is equivalent to forkIO. The thread created 
-- is managed with the thread control primitives of transient
fork :: TransIO () -> TransIO ()
fork proc= (abduce >> proc >> empty) <|> return()
 

-- | Run an IO action one or more times to generate a stream of tasks. The IO
-- action returns a 'StreamData'. When it returns an 'SMore' or 'SLast' a new
-- result is returned with the result value. If there are threads available, the res of the
-- computation is executed in a new thread. If the return value is 'SMore', the
-- action is run again to generate the next result, otherwise task creation
-- stop.
--
-- Unless the maximum number of threads (set with 'threads') has been reached,
-- the task is generated in a new thread and the current thread returns a void
-- task.
parallel :: IO (StreamData b) -> TransIO (StreamData b)
parallel ioaction = Transient $ do
  --was <- gets execMode -- getData `onNothing` return Serial
  --when (was /= Remote) $ modify $ \s -> s{execMode= Parallel}
  modify $ \s -> s{execMode=let rs= execMode s in if rs /= Remote then Parallel else rs}
  cont <- get
          --  !>  "PARALLEL"
  case event cont of
    j@(Just _) -> do
      put cont { event = Nothing }
      return $ unsafeCoerce j
    Nothing    -> do
      liftIO $ atomicModifyIORef (labelth cont) $ \(_, lab) -> ((Parent, lab), ())

      liftIO $ loop cont ioaction

      return Nothing

-- | Execute the IO action and the continuation
loop ::  EventF -> IO (StreamData t) -> IO ()
loop parentc rec = forkMaybe parentc $ \cont -> do
  -- Execute the IO computation and then the closure-continuation
  liftIO $ atomicModifyIORef (labelth cont) $ \(_,label) -> ((Listener,label),())
  let loop'=   do
         mdat <- rec  `catch` \(e :: SomeException) -> return $ SError e
         case mdat of
             se@(SError _)  -> setworker cont >> iocont  se    cont
             SDone          -> setworker cont >> iocont  SDone cont
             last@(SLast _) -> setworker cont >> iocont  last  cont

             more@(SMore _) -> do
                  forkMaybe cont $ iocont  more
                  loop'

         where
         setworker cont= liftIO $ atomicModifyIORef (labelth cont) $ \(_,lab) -> ((Alive,lab),())

         iocont  dat cont = do

              let cont'= cont{event= Just $ unsafeCoerce dat}
              runStateT (runCont cont')  cont'
              return ()


  loop'
  return ()
  where
  {-# INLINABLE forkMaybe #-}
  forkMaybe :: EventF -> (EventF -> IO ()) -> IO ()
  forkMaybe parent  proc = do
     case maxThread parent  of
       Nothing -> forkIt parent  proc
       Just sem  -> do
             dofork <- waitQSemB sem
             if dofork then forkIt parent proc 
                       else proc parent  
                                `catch` \e ->exceptBack parent e >> return()
              

  forkIt parent  proc= do
     chs <- liftIO $ newMVar []

     label <- newIORef (Alive, BS.pack "work")
     let cont = parent{parent=Just parent,children=   chs, labelth= label}

     forkFinally1  (do
         th <- myThreadId
         let cont'= cont{threadId=th}
         when(not $ freeTh parent )$ hangThread parent   cont'
                                   --  !>  ("thread created: ",th,"in",threadId parent )

         proc cont')
         $ \me -> do
           case  me of
              Left e -> (exceptBack cont e >> return ())    -- !> "exceptBack 2"



              _ -> return ()  
           case maxThread cont of
               Just sem -> signalQSemB sem              -- !> "freed thread"
               Nothing -> return ()
           when(not $ freeTh parent  )  $ do -- if was not a free thread

                 th <- myThreadId  
                 (can,label) <- atomicModifyIORef (labelth cont) $ \(l@(status,label)) ->
                    ((if status== Alive then Dead else status, label),l)
                 when (can /= Parent ) $ free th parent


     return ()


  forkFinally1 :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
  forkFinally1 action and_then = 
       mask $ \restore ->  forkIO $ Control.Exception.try (restore action) >>= and_then

free th env= do
--       return ()                                       !> ("freeing",th,"in",threadId env)
       threadDelay 1000             -- wait for some activity in the children of the parent thread, to avoid
                                    -- an early elimination
       let sibling=  children env

       (sbs',found) <- modifyMVar sibling $ \sbs -> do
                   let (sbs', found) = drop [] th  sbs
                   return (sbs',(sbs',found))



       if found
         then do

--                                             !> ("new list for",threadId env,map threadId sbs')

           (typ,_) <- readIORef $ labelth env
           if (null sbs' && typ /= Listener && isJust (parent env))
            -- free the parent
            then free (threadId env) ( fromJust $ parent env)
            else return ()


         else return () -- putMVar sibling sbs
                                                     -- !>  (th,"orphan")

       where
       drop processed th []= (processed,False)
       drop processed th (ev:evts)| th ==  threadId ev= (processed ++ evts, True)
                                  | otherwise= drop (ev:processed) th evts



hangThread parentProc child =  do

       let headpths= children parentProc

       modifyMVar_ headpths $ \ths -> return (child:ths)



           --  !> ("hang", threadId child, threadId parentProc,map threadId ths,unsafePerformIO $ readIORef $ labelth parentProc)

-- | kill  all the child threads associated with the continuation context
killChildren childs  = do
        forkIO $ do
           ths <- modifyMVar childs $ \ths -> return ([],ths)
           mapM_ (killChildren . children) ths
           mapM_ (\th -> do
              (status,_) <- readIORef $ labelth th
              when (status /= Listener && status /= Parent) $ killThread $ threadId th !> ("killChildren",threadId th, status)) ths  >> return ()  
        return ()




-- | capture a callback handler so that the execution of the current computation continues 
-- whenever an event occurs. The effect is called "de-inversion of control"
--
-- The first parameter is a callback setter. The second parameter is a value to be
-- returned to the callback; if the callback expects no return value it
-- can just be @return ()@. The callback setter expects a function taking the
-- @eventdata@ as an argument and returning a value; this
-- function is the continuation, which is supplied by 'react'.
--
-- Callbacks from foreign code can be wrapped into such a handler and hooked
-- into the transient monad using 'react'. Every time the callback is called it
-- continues the execution on the current transient computation.
--
-- >     
-- >  do
-- >     event <- react  onEvent $ return ()
-- >     ....
-- >
react
  :: ((eventdata ->  IO response) -> IO ())
  -> IO  response
  -> TransIO eventdata
react setHandler iob= do
   st <- cloneInChild "react"
   liftIO $ atomicModifyIORef (labelth st) $ \(_,label) -> ((Listener,label),())
   Transient $ do
        modify $ \s -> s{execMode=let rs= execMode s in if rs /= Remote then Parallel else rs}
        cont <- get

        case event cont of
          Nothing -> do
            liftIO $ setHandler $ \dat ->do
              runStateT (runCont cont) st{event= Just $ unsafeCoerce dat} `catch` exceptBack cont
              iob

            return Nothing

          j@(Just _) -> do
            put cont{event=Nothing}
            return $ unsafeCoerce j
      

-- * Non-blocking keyboard input

-- getLineRef= unsafePerformIO $ newTVarIO Nothing


-- | listen stdin and triggers a new task every time the input data
-- matches the first parameter.  The value contained by the task is the matched
-- value i.e. the first argument itself. The second parameter is a message for
-- the user. The label is displayed in the console when the option match.
option :: (Typeable b, Show b, Read b, Eq b) =>
          b -> String  -> TransIO b
option =  optionf False

-- Implements the same functionality than `option` but only wait for one input
option1 :: (Typeable b, Show b, Read b, Eq b) =>
          b -> String  -> TransIO b
option1= optionf True


optionf :: (Typeable b, Show b, Read b, Eq b) =>
          Bool -> b -> String  -> TransIO b
optionf flag ret message  = do
  let sret= if typeOf ret == typeOf "" then unsafeCoerce ret else show ret
  liftIO $ putStrLn $ "Enter  "++sret++"\t\tto: " ++ message
  inputf flag sret message Nothing ( == sret)
  liftIO $ putStr "\noption: " >> putStrLn sret
  -- abduce
  return ret

-- | General asynchronous console input
-- 
-- inputf <remove input listener after sucessful or not> <listener identifier> <prompt> <Maybe default value> <validation proc>
inputf ::  (Show a, Read a,Typeable a)  => Bool -> String -> String -> Maybe a -> (a -> Bool) -> TransIO a
inputf flag ident message mv cond= do
    str <- react (addConsoleAction ident message) (return ())

    when flag $  do removeChild; liftIO $ delConsoleAction ident 
    c <- liftIO $ readIORef rconsumed
    if c then returnm mv else do
        if null str then do liftIO $ writeIORef rconsumed True; returnm mv  else do 
            let rr = read1 str 
        
            case   rr  of
               Just x -> if cond x 
                             then liftIO $ do
                                   writeIORef rconsumed True  
                                   print x
                                   -- hFlush stdout
                                   return x
                             else do liftIO $  when (isJust mv) $ putStrLn "";  returnm mv
               _      -> do liftIO $  when (isJust mv) $ putStrLn ""; returnm mv 

    where
    returnm (Just x)= return x
    returnm _ = empty
    
    -- read1 :: String -> Maybe a
    read1 s= r 
      where
      typ= typeOf $ fromJust r
      r = if typ == typeOf ""                 then Just $ unsafeCoerce s
          else if typ == typeOf (BS.pack "")  then Just $ unsafeCoerce $ BS.pack  s
          else if typ == typeOf (BSL.pack "") then Just $ unsafeCoerce $ BSL.pack  s
          else case reads s of
              [] ->  Nothing
              [(x,"")] -> Just x



-- | Waits on stdin and return a value when a console input matches the
-- predicate specified in the first argument.  The second parameter is a string
-- to be displayed on the console before waiting.
input :: (Typeable a, Read a,Show a) =>  (a -> Bool) -> String -> TransIO a
input= input' Nothing

-- | `input` with a default value
input' :: (Typeable a, Read a,Show a) => Maybe a -> (a -> Bool) -> String -> TransIO a
input' mv cond prompt= do  
  liftIO $ putStr prompt >> hFlush stdout 
  inputf True "input" prompt  mv cond
  




rcb= unsafePerformIO $ newIORef [] :: IORef [ (String,String,String -> IO())]

addConsoleAction :: String -> String -> (String ->  IO ()) -> IO ()
addConsoleAction name message cb= atomicModifyIORef rcb $ \cbs ->  ((name,message, cb) : filter ((/=) name . fst) cbs ,())
 where
 fst (x,_,_)= x

delConsoleAction :: String -> IO ()
delConsoleAction name= atomicModifyIORef rcb $ \cbs -> (filter ((/=) name . fst) cbs,())
 where
 fst (x,_,_)= x


reads1 s=x where
      x= if typeOf(typeOfr x) == typeOf "" then unsafeCoerce[(s,"")] else readsPrec' 0 s
      typeOfr :: [(a,String)] ->  a
      typeOfr  = undefined

read1 s= let [(x,"")]= reads1 s  in x



rprompt= unsafePerformIO $ newIORef "> "
inputLoop= do
    line <- getLine
    threadDelay 1000000

    processLine line

    prompt <- readIORef rprompt
    when (not $ null prompt) $ do putStr prompt ; hFlush stdout
    inputLoop



{-# NOINLINE rconsumed #-}
rconsumed = unsafePerformIO $ newIORef False
{-# NOINLINE lineprocessmode #-}
lineprocessmode= unsafePerformIO $ newIORef False

processLine r = do

    linepro <- readIORef lineprocessmode
    if linepro then do

            mapM' invokeParsers [r]
            
       else do
            let rs = breakSlash [] r
            mapM' invokeParsers rs

    
    where
    invokeParsers x= do
       mbs <- readIORef rcb
       mapM_ (\cb -> cb x) $ map (\(_,_,p)-> p) mbs
       
    mapM' f []= return ()
    mapM' f (xss@(x:xs)) =do
        f x
        r <- readIORef rconsumed

        if  r
          then do
            writeIORef riterloop 0
            writeIORef rconsumed False
            mapM' f xs

          else do
            threadDelay 1000
            n <- atomicModifyIORef riterloop $ \n -> (n+1,n)
            if n==100
              then do
                when (not $ null x) $ hPutStr  stderr x >> hPutStrLn stderr ": can't read, skip"
                writeIORef riterloop 0
                writeIORef rconsumed False
                mapM' f xs
              else mapM' f xss

    riterloop= unsafePerformIO $ newIORef 0
breakSlash :: [String] -> String -> [String]
breakSlash [] ""= [""]
breakSlash s ""= s
breakSlash res ('\"':s)=
    let (r,rest) = span(/= '\"') s
    in breakSlash (res++[r]) $ tail1 rest

breakSlash res s=
    let (r,rest) = span(\x -> (not $ elem x "/,:") && x /= ' ') s
    in breakSlash (res++[r]) $ tail1 rest

tail1 []= []
tail1 x= tail x

-- >>> breakSlash [] "test.hs/0/\"-prof -auto\""
-- ["test.hs","0","-prof -auto"]
--




-- | Wait for the execution of `exit` and return the result or the exhaustion of thread activity

stay rexit=  takeMVar rexit
 `catch` \(e :: BlockedIndefinitelyOnMVar) -> return Nothing

newtype Exit a= Exit a deriving Typeable

-- | Runs the transient computation in a child thread and keeps the main thread
-- running until all the user threads exit or some thread 'exit'.
--
-- The main thread provides facilities for accepting keyboard input in a
-- non-blocking but line-oriented manner. The program reads the standard input
-- and feeds it to all the async input consumers (e.g. 'option' and 'input').
-- All async input consumers contend for each line entered on the standard
-- input and try to read it atomically. When a consumer consumes the input
-- others do not get to see it, otherwise it is left in the buffer for others
-- to consume. If nobody consumes the input, it is discarded.
--
-- A @/@ in the input line is treated as a newline.
--
-- When using asynchronous input, regular synchronous IO APIs like getLine
-- cannot be used as they will contend for the standard input along with the
-- asynchronous input thread. Instead you can use the asynchronous input APIs
-- provided by transient.
--
-- A built-in interactive command handler also reads the stdin asynchronously.
-- All available options waiting for input are displayed when the
-- program is run.  The following commands are available:
--
-- 1. @ps@: show threads
-- 2. @log@: inspect the log of a thread
-- 3. @end@, @exit@: terminate the program
--
-- An input not handled by the command handler can be handled by the program.
--
-- The program's command line is scanned for @-p@ or @--path@ command line
-- options.  The arguments to these options are injected into the async input
-- channel as keyboard input to the program. Each line of input is separated by
-- a @/@. For example:
--
-- >  foo  -p  ps/end
--
keep :: Typeable a => TransIO a -> IO (Maybe a)
keep mx = do
   liftIO $ hSetBuffering stdout LineBuffering
   rexit <- newEmptyMVar
   forkIO $ do
--       liftIO $ putMVar rexit  $ Right Nothing
       let logFile= "trans.log"

       runTransient $ do
           liftIO $ removeFile logFile `catch`  \(e :: IOError) -> return ()
           onException $ \(e :: SomeException) -> do
              top <- topState
              let exc = (do showThreads top ; print e;  appendFile logFile $ show e ++ "\n") `catch` \(e:: IOError) -> exc
              liftIO exc >> empty
           -- onException $ \(e :: SomeException ) -> liftIO $ putStr  "keep: " >> print e 
           
           onException $ \(e :: IOException) -> do
             when (ioeGetErrorString e ==  "resource busy") $ do
                 liftIO $ do print e ; putStrLn "EXITING!!!";  putMVar rexit Nothing
                 empty
                 
           st <- get
           setData $ Exit rexit
           (abduce >> labelState (fromString "input") >> liftIO inputLoop >> empty)
            <|> do
                   option "options" "show all options"
                   mbs <- liftIO $ readIORef rcb

                   liftIO $ mapM_  (\c ->do putStr c; putStr "|") $ map (\(fst,_,_) -> fst)mbs

                   d <- input' (Just "n") (\x -> x=="y" || x =="n" || x=="Y" || x=="N") "\nDetails? N/y "
                   when  (d == "y") $
                       let line (x,y,_)= do putStr x; putStr "\t\t"; putStrLn y
                       in liftIO $ mapM_ line  mbs
                   liftIO $ putStrLn ""
                   empty
            <|> do
                   option "ps" "show threads"
                   liftIO $ showThreads st
                   empty
            <|> do
                    option "errs" "show exceptions log"
                    c <- liftIO $ readFile logFile `catch` \(e:: IOError) -> return ""
                    liftIO . putStrLn $  if null c then  "no errors logged" else c
                    empty
                   {-
            <|> do
                   option "log" "inspect the log of a thread"
                   th <- input (const True)  "thread number>"
                   ml <- liftIO $ getStateFromThread th st
                   liftIO $ print $ fmap (\(Log _ _ log _) -> reverse log) ml
                   empty
                   -}
            <|> do
                   option "end" "exit"
                   liftIO $ putStrLn "exiting..."
                   abduce
                   killChilds
                   liftIO $ putMVar rexit Nothing
                   empty

            <|>    mx
       return ()
   threadDelay 10000
   execCommandLine
   stay rexit

   where
   type1 :: TransIO a -> Either String (Maybe a)
   type1= undefined

-- | Same as `keep` but does not read from the standard input, and therefore
-- the async input APIs ('option' and 'input') cannot be used in the monad.
-- However, keyboard input can still be passed via command line arguments as
-- described in 'keep'.  Useful for debugging or for creating background tasks,
-- as well as to embed the Transient monad inside another computation. It
-- returns either the value returned by `exit`.  or Nothing, when there are no
-- more threads running
--

keep' :: Typeable a => TransIO a -> IO  (Maybe a)
keep' mx  = do
   liftIO $ hSetBuffering stdout LineBuffering
   rexit <- newEmptyMVar 
   forkIO $ do
           runTransient $ do
              onException $ \(e :: SomeException ) -> do
                 top <- topState
                 liftIO $ do
                    th <- myThreadId
                    putStr $ show th
                    putStr ": "
                    print e
                    print "at:"
                    showThreads top
                 empty
              
              onException $ \(e :: IOException) -> do
                 when (ioeGetErrorString e ==  "resource busy") $ do
                     liftIO $ do  print e ; putStrLn "EXITING!!!"; putMVar rexit Nothing
                     liftIO $ putMVar rexit Nothing
                     empty
                     
              setData $ Exit rexit
              mx

           return ()
   threadDelay 10000
   forkIO $ execCommandLine
   stay rexit

execCommandLine= do
    args <- getArgs
    let mindex =  findIndex (\o ->  o == "-p" || o == "--path" ) args
    when (isJust mindex) $ do
         let i= fromJust mindex +1
         when (length  args >= i) $ do
           let path=  args !! i 
           print $ drop (i-1) args
           putStr "Executing: " >> print  path
           processLine  path


-- | Exit the main thread with a result, and thus all the Transient threads (and the
-- application if there is no more code)
exit :: Typeable a => a -> TransIO a
exit x= do
  Exit rexit <- getSData <|> error "exit: not the type expected"  `asTypeOf` type1 x
  liftIO $  putMVar  rexit  $ Just x
  stop
  where
  type1 :: a -> TransIO (Exit (MVar (Maybe a)))
  type1= undefined




-- | If the first parameter is 'Nothing' return the second parameter otherwise
-- return the first parameter..
onNothing :: Monad m => m (Maybe b) -> m b -> m b
onNothing iox iox'= do
       mx <- iox
       case mx of
           Just x -> return x
           Nothing -> iox'





----------------------------------backtracking ------------------------


data Backtrack b= Show b =>Backtrack{backtracking :: Maybe b
                                    ,backStack :: [EventF] }
                                    deriving Typeable



-- | Delete all the undo actions registered till now for the given track id.
backCut :: (Typeable b, Show b) => b -> TransientIO ()
backCut reason= Transient $ do
     delData $ Backtrack (Just reason)  []
     return $ Just ()

-- | 'backCut' for the default track; equivalent to @backCut ()@.
undoCut ::  TransientIO ()
undoCut = backCut ()

-- | Run the action in the first parameter and register the second parameter as
-- the undo action. On undo ('back') the second parameter is called with the
-- undo track id as argument.
--
{-# NOINLINE onBack #-}
onBack :: (Typeable b, Show b) => TransientIO a -> ( b -> TransientIO a) -> TransientIO a
onBack ac bac = registerBack (typeof bac) $ Transient $ do
     tr "onBack"
     Backtrack mreason stack  <- getData `onNothing` (return $ backStateOf (typeof bac))
     runTrans $ case mreason of
                  Nothing     -> ac                     -- !>  "ONBACK NOTHING"
                  Just reason -> do

                      -- setState $ Backtrack mreason $ tail stack -- to avoid recursive call tot he same handler
                      bac reason                        -- !> ("ONBACK JUST",reason)
     where
     typeof :: (b -> TransIO a) -> b
     typeof = undefined

-- | 'onBack' for the default track; equivalent to @onBack ()@.
onUndo ::  TransientIO a -> TransientIO a -> TransientIO a
onUndo x y= onBack x (\() -> y)



-- | Register an undo action to be executed when backtracking. The first
-- parameter is a "witness" whose data type is used to uniquely identify this
-- backtracking action. The value of the witness parameter is not used.
--
{-# NOINLINE registerUndo #-}
registerBack :: (Typeable b, Show b) => b -> TransientIO a -> TransientIO a
registerBack witness f  = Transient $ do
   cont@(EventF _ x  _ _ _ _ _ _ _ _ _ _ _)  <- get
 -- if isJust (event cont) then return Nothing else do
   md <- getData `asTypeOf` (Just <$> return (backStateOf witness))

   case md of
        Just (Backtrack b []) ->  setData $ Backtrack b  [cont] 
        Just (bss@(Backtrack b (bs@((EventF _ x'  _ _ _ _ _ _ _ _ _ _ _):_)))) ->
          when (isNothing b) $ do
                addrx  <- addr x
                addrx' <- addr x'         -- to avoid duplicate backtracking points
                setData $ Backtrack b  $ if addrx == addrx' then (cont:tail bs) else  (cont:bs)
               --setData $ Backtrack b (cont:bs)

        Nothing ->  setData $ Backtrack mwit [cont]

   runTrans f
   where
   mwit= Nothing `asTypeOf` (Just witness)
   addr x = liftIO $ return . hashStableName =<< (makeStableName $! x)


registerUndo :: TransientIO a -> TransientIO a
registerUndo f= registerBack ()  f

-- XXX Should we enforce retry of the same track which is being undone? If the
-- user specifies a different track would it make sense?
--
-- | For a given undo track type, stop executing more backtracking actions and
-- resume normal execution in the forward direction. Used inside an undo
-- action.
--
forward :: (Typeable b, Show b) => b -> TransIO ()
forward reason= noTrans $ do
    Backtrack _ stack <- getData `onNothing`  ( return $ backStateOf reason)
    setData $ Backtrack(Nothing `asTypeOf` Just reason)  stack

-- | 'forward' for the default undo track; equivalent to @forward ()@.
retry= forward ()

-- | Abort finish. Stop executing more finish actions and resume normal
-- execution.  Used inside 'onFinish' actions.
--
noFinish= continue

-- | Start the undo process for a given undo track identifier type. Performs all the undo
-- actions registered for that type in reverse order. An undo action can use
-- 'forward' to stop the undo process and resume forward execution. If there
-- are no more undo actions registered, execution stop
--
back :: (Typeable b, Show b) => b -> TransIO a
back reason =  do
  bs <- getData  `onNothing`  return (backStateOf  reason)           
  goBackt  bs                                                    --  !>"GOBACK"

  where
  runClosure :: EventF -> TransIO a
  runClosure EventF { xcomp = x } = unsafeCoerce  x
  runContinuation ::  EventF -> a -> TransIO b
  runContinuation EventF { fcomp = fs } =  (unsafeCoerce $ compose fs)


  goBackt (Backtrack _ [] )= empty
  goBackt (Backtrack b (stack@(first : bs)) )= do
        setData $ Backtrack (Just reason) stack
        x <-  runClosure first                                      !> ("RUNCLOSURE",length stack)
        Backtrack back bs' <- getData `onNothing`  return (backStateOf  reason)

        case back of
                 Nothing    -> runContinuation first x             !> "FORWARD EXEC"
                 justreason -> do
                        setData $ Backtrack justreason bs
                        goBackt $ Backtrack justreason bs      -- !> ("BACK AGAIN",back)
                        empty

backStateOf :: (Show a, Typeable a) => a -> Backtrack a
backStateOf reason= Backtrack (Nothing `asTypeOf` (Just reason)) []

data BackPoint a = BackPoint (IORef [a -> TransIO()])

-- | a backpoint is a location in the code where callbacks can be installed and will be called when the backtracing pass trough that point.
-- Normally used for exceptions.
backPoint :: (Typeable reason,Show reason) => TransIO (BackPoint reason)
backPoint = do
    point <- liftIO $ newIORef  []
    return () `onBack` (\e -> do
              rs <- liftIO $ readIORef point
              mapM_ (\r -> r e) rs)

    return $ BackPoint point

-- | install a callback in a backPoint

onBackPoint :: MonadIO m => BackPoint t -> (t -> TransIO ()) -> m ()
onBackPoint (BackPoint ref) handler= liftIO $ atomicModifyIORef ref $ \rs -> (handler:rs,())

-- | 'back' for the default undo track; equivalent to @back ()@.
--
undo ::  TransIO a
undo= back ()


------ finalization

newtype Finish= Finish String deriving Show

instance Exception Finish

-- newtype FinishReason= FinishReason (Maybe SomeException) deriving (Typeable, Show)

-- | Clear all finish actions registered till now.
-- initFinish= backCut (FinishReason Nothing)

-- | Register an action that to be run when 'finish' is called. 'onFinish' can
-- be used multiple times to register multiple actions. Actions are run in
-- reverse order. Used in infix style.
--
onFinish :: (Finish ->TransIO ()) -> TransIO ()
onFinish f= onException' (return ()) f


-- | Run the action specified in the first parameter and register the second
-- parameter as a finish action to be run when 'finish' is called. Used in
-- infix style.
--
onFinish' ::TransIO a ->(Finish ->TransIO a) -> TransIO a
onFinish' proc f= proc `onException'` f


-- | Execute all the finalization actions registered up to the last
-- 'initFinish', in reverse order and continue the execution.  Either an exception or 'Nothing' can be
initFinish = cutExceptions
-- passed to 'finish'.  The argument passed is made available in the 'onFinish'
--
finish :: String -> TransIO ()
finish reason= (throwt $ Finish reason) <|> return()



-- | trigger finish when the stream of data ends
checkFinalize v=
   case v of
      SDone ->  stop
      SLast x ->  return x
      SError e -> throwt  e
      SMore x -> return x

------ exceptions ---
--
-- | Install an exception handler. Handlers are executed in reverse (i.e. last in, first out) order when such exception happens in the
-- continuation. Note that multiple handlers can be installed for the same exception type.
--
-- The semantic is, thus, very different than the one of `Control.Exception.Base.onException`
onException :: Exception e => (e -> TransIO ()) -> TransIO ()
onException exc= return () `onException'` exc

-- | set an exception point. Thi is a point in the backtracking in which exception handlers can be inserted with `onExceptionPoint`
-- it is an specialization of `backPoint` for exceptions.
--
-- When an exception backtracking reach the backPoint it executes all the handlers registered for it.
--
-- Use case: suppose that when a connection fails, you need to stop a process.
-- This process may not be started before the connection. Perhaps it was initiated after the socket read
-- so an exception will not backtrack trough the process, since it is downstream, not upstream. The process may
-- be even unrelated to the connection, in other branch of the computation.
--
-- in this case you only need to create a `exceptionPoint` before stablishin the connection, and use `onExceptionPoint`
-- to set a handler that will be called when the connection fail.
exceptionPoint :: Exception e => TransIO (BackPoint e)
exceptionPoint = do
    point <- liftIO $ newIORef  []
    return () `onException'` (\e -> do
              rs<-  liftIO $ readIORef point
              mapM_ (\r -> r e) rs)

    return $ BackPoint point



-- | in conjunction with `backPoint` it set a handler that will be called when backtracking pass 
-- trough the point
onExceptionPoint :: Exception e => BackPoint e -> (e -> TransIO()) -> TransIO ()
onExceptionPoint= onBackPoint


onException' :: Exception e => TransIO a -> (e -> TransIO a) -> TransIO a 
onException' mx f= onAnyException mx $ \e -> do
            return () !>  "EXCEPTION HANDLER EXEC" 
            case fromException e of
               Nothing -> do
                  Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)      
                  setData $ Backtrack r $ tail stack
                  back e
                  empty
               Just e' -> f e'


   
  where
  onAnyException :: TransIO a -> (SomeException ->TransIO a) -> TransIO a
  onAnyException mx exc= ioexp  `onBack` exc
 
  ioexp    = Transient $ do
    st <- get

    (mr,st') <- liftIO $ (runStateT
      (do
        case event st of
          Nothing -> do
                r <- runTrans  mx  
                modify $ \s -> s{event= Just $ unsafeCoerce r}
                runCont st
              --  was <- gets execMode -- getData `onNothing` return Serial
              --  when (was /= Remote) $ modify $ \s -> s{execMode= Parallel}
                modify $ \s -> s{execMode=let rs= execMode s in if rs /= Remote then Parallel else rs}

                return Nothing

          Just r -> do
                modify $ \s ->  s{event=Nothing}
                return  $ unsafeCoerce r) st)
                   `catch` exceptBack st
    put st'
    return mr

exceptBack st = \(e ::SomeException) -> do  -- recursive catch itself
                      runStateT ( runTrans $  back e ) st                 -- !> "EXCEPTBACK"
                  `catch` exceptBack st

  
-- | Delete all the exception handlers registered till now.
cutExceptions :: TransIO ()
cutExceptions= backCut  (undefined :: SomeException)

-- | Use it inside an exception handler. it stop executing any further exception
-- handlers and resume normal execution from this point on.
continue :: TransIO ()
continue = forward (undefined :: SomeException)   -- !> "CONTINUE"

-- | catch an exception in a Transient block
--
-- The semantic is the same than `catch` but the computation and the exception handler can be multirhreaded
catcht :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
catcht mx exc= do
    rpassed <- liftIO $ newIORef  False
    sandbox  $ do
         r <- onException' mx (\e -> do
                 passed <- liftIO $ readIORef rpassed
                 return () !> ("CATCHT passed", passed)
                 if not passed then continue >> exc e else do
                    Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)      
                    setData $ Backtrack r $ tail stack
                    back e 
                    return () !> "AFTER BACK"
                    empty )
                    
         liftIO $ writeIORef rpassed True
         return r
   where
   sandbox  mx= do
     exState <- getState <|> return (backStateOf (undefined :: SomeException))
     mx
       <*** do setState exState

-- | throw an exception in the Transient monad
-- there is a difference between `throw` and `throwt` since the latter preserves the state, while the former does not.
-- Any exception not thrown with `throwt`  does not preserve the state.
--
-- > main= keep  $ do
-- >      onException $ \(e:: SomeException) -> do
-- >                  v <- getState <|> return "hello"
-- >                  liftIO $ print v
-- >      setState "world"
-- >      throw $ ErrorCall "asdasd"
-- 
-- the latter print "hello". If you use `throwt` instead, it prints "world"     
     
throwt :: Exception e => e -> TransIO a

throwt =  back . toException 

