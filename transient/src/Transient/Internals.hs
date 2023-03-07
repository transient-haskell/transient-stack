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
-- {-# LANGUAGE MonoLocalBinds            #-}


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
import           Data.Maybe
import           Data.List
import           Data.IORef


import           Data.String
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8             as BSL
import           Data.Typeable
import           Control.Monad.Fail
import           System.Directory
import qualified Debug.Trace as Debug

#ifdef DEBUG
trace= Debug.trace 
#else

trace _ x=  x
#endif

-- tshow ::  a -> x -> x
-- tshow _ y= y

-- {-# INLINE (!>) #-}
-- (!>) :: a -> b -> a
-- (!>) = const
indent, outdent :: MonadIO m => m ()

indent= return()
outdent= return()


{-# NOINLINE rindent #-}
rindent= unsafePerformIO $ newIORef 0
-- tr x= return () !>   unsafePerformIO (printColor x)
-- tr x= trace (show(unsafePerformIO myThreadId, unsafePerformIO $ printColor x))  $ return()

-- {-# NOINLINE tr #-}
tr x=  trace (printColor x) $ return ()

-- {-# NOINLINE printColor #-}
printColor :: Show a => a -> String
printColor x= unsafePerformIO $ do
    th <- myThreadId
    sps <- readIORef rindent >>= \n -> return $ take n $ repeat ' '
    let col=  (read(drop 9(show th)) `mod` (36-31))+31
    return $ "\x1b["++ show col ++ ";49m" ++ sps ++ show (th,x) ++ "\x1b[0m"

    -- 256 colors
    -- let col= toHex $ (read  (drop 9(show th))) `mod` 255
    -- return $ "\x1b[38;5;"++ col++ "m" ++ show (th,x) ++  "\x1b[0m\n"
  -- where
  -- toHex :: Int -> String
  -- toHex 0= mempty
  -- toHex l= 
  --     let (q,r)= quotRem l 16
  --     in toHex q ++ (show $ (if r < 9  then toEnum( fromEnum '0' + r) else  toEnum(fromEnum  'A'+ r -10):: Int))

ttr ::(Show a, MonadIO m) => a -> m()
ttr x= liftIO $ do putStr "=======>" ; putStrLn $ printColor   x

type StateIO = StateT EventF IO


newtype TransIO a = Transient { runTrans :: StateIO (Maybe a) }

type SData = ()

type EventId = Int

type TransientIO = TransIO

data LifeCycle = Alive   -- working
                | Parent -- with some childs
                | Listener -- usually a callback inside react
                | Dead     -- killed waiting to be eliminated
                | DeadParent  -- Dead with some childs active
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

  , parent      :: IORef(Maybe EventF)
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

-- {-# NOINLINE threadId #-}
-- threadId x= unsafePerformIO $ readIORef $ pthreadId x

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



-- emptyEventF :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [EventF] -> EventF
emptyEventF th label par childs =
  EventF { event      = mempty
         , xcomp      = empty
         , fcomp      = []
         , mfData     = mempty
         , mfSequence = 0
         , threadId   = th -- unsafePerformIO $ newIORef th
         , freeTh     = False
         , parent     = par
         , children   = childs
         , maxThread  = Nothing
         , labelth    = label
         , parseContext = ParseContext (return SDone) mempty (unsafePerformIO $ newIORef True)
         , execMode = Serial}

-- | Run a transient computation with a default initial state
runTransient :: TransIO a -> IO (Maybe a, EventF)
runTransient t = do
  th     <- myThreadId
  label  <- newIORef $ (Alive, BS.pack "top")
  childs <- newMVar []
  -- par    <- newIORef Nothing
  runStateT (runTrans t) $ emptyEventF th label (unsafePerformIO $ newIORef Nothing) childs

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
                       tr("XPARALELL",isJust mr)
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

-- #ifndef ghcjs_HOST_OS11
instance Monad TransIO where
  return   = pure
  x >>= f  = Transient $ do
    setEventCont x f
    mk <- runTrans x
    resetEventCont mk
    case mk of
      Just k  -> runTrans (f k)
      Nothing -> return Nothing
-- #else

-- instance Monad TransIO where
--   return =  pure
--   x >>= f = Transient $ do
--        id1 <- genNewId
--        tr id1
--        setEventCont x  f id1
--        delData P.noHtml
--        mk <- runTrans x
--        form1 <- getData `onNothing` return P.noHtml
--        resetEventCont mk
--        case mk of
--          Just k  -> do
--             delData P.noHtml
--             mk <- runTrans $ f k
--             form2 <- getData `onNothing` return P.noHtml
--             setData $ form1 <> (P.span P.! P.id id1 $ form2)
--             return mk
--          Nothing -> do
--             setData  $ form1 <> (P.span P.! P.id id1 $ P.noHtml)
--             return Nothing

-- #endif

-- | Set the current closure and continuation for the current statement
-- #ifndef ghcjs_HOST_OS11

{-# INLINABLE setEventCont #-}


setEventCont :: TransIO a -> (a -> TransIO b) -> StateIO ()
setEventCont x f  = modify $ \EventF { fcomp = fs, .. }
                           -> EventF { xcomp = x
                                     , fcomp = unsafeCoerce f :  fs
                                     , .. }

-- #else
-- setEventCont  x f id = modify $ \EventF { fcomp = fs, .. }
--                            -> EventF { xcomp = strip x
--                                      , fcomp =  unsafeCoerce(rend f id) :  fs
--                                      , .. }  
--   where
--   --rend :: (b ->TransIO b) -> JSString  -> b -> TransIO b
--   rend f id x= runWidgetId ( f x) id `asTypeOf` f x

--   strip x=  do
--     r <- x
--     delData P.noHtml
--     return r

-- --runWidget' :: TransIO b -> Elem   -> TransIO b
-- runWidget' action e  = do
--     mr <- runTrans action -- <*** (noTrans $ do                        -- !> "runVidget'"

--     torender <- getData `onNothing` (return  P.noHtml)
--     tr "build de runWidget"

--     liftIO $ P.build torender e >> return()

--     return mr


-- runWidgetId :: TransIO b -> JSString   -> TransIO b
-- runWidgetId w id= Transient $ do
--     tr ("runWidgetId",id)
--     e <- liftIO $ elemById id  `onNothing` error ("not found" ++ show id)
--     liftIO $ P.clearChildren  e
--     runWidget' w  e

--     where
--     --elemById :: MonadIO m  => JSString -> m (Maybe Elem)
--     elemById id= liftIO $ do
--       re <- elemByIdDOM id
--       fromJSVal re

-- foreign import javascript unsafe  
--       "document.getElementById($1)" 
--       elemByIdDOM
--       :: JSString -> IO JSVal

-- #endif



-- #ifdef ghcjs_HOST_OS11
-- {-#NOINLINE rprefix #-}
-- rprefix= unsafePerformIO $ newIORef 0

-- genNewId ::  (MonadState EventF m, MonadIO m) => m  JSString
-- genNewId=  do
--       r <- liftIO $ atomicModifyIORef rprefix (\n -> (n+1,n))
--       n <- genId
--       let nid= fromString $  ('n':show n)  ++ ('p':show r)
--       nid `seq` return  nid





-- --getPrev ::  StateIO  JSString
-- --getPrev= return $ pack ""
-- #endif


instance MonadIO TransIO where
  liftIO x = Transient $ liftIO x >>= return . Just

instance Monoid a => Monoid (TransIO a) where
  mempty      = return mempty


  mappend  = (<>)

instance (Monoid a) => Semigroup (TransIO a) where
  (<>)=  mappendt




mappendt x y = mappend <$> x <*> y


instance Alternative TransIO where
    empty = Transient $ return  Nothing
    (<|>) = mplus

-- data Alter= Alter  -- when alternative has been executed

-- >>> keep' $ setState Alter >>  ((getState :: TransIO Alter) >>= delState  >> return True) <|> return False
-- [True]
--


instance MonadPlus TransIO where
  mzero     = empty
  mplus x y = Transient $ do
    mx <- runTrans x

    was <- gets execMode

    if was == Remote

      then return Nothing
      else case mx of
            Nothing -> runTrans y

            _ -> return mx

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


instance (IsString a) => IsString (TransIO a) where
  fromString = return . fromString

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

waitQSemB  onemore sem = atomicModifyIORef sem $ \n ->
                    let one =  if onemore then 1 else 0
                    in if n + one > 0 then(n - 1, True) else (n, False)
signalQSemB sem = atomicModifyIORef sem $ \n -> (n + 1, ())

-- | Sets the maximum number of threads that can be created for the given task
-- set.  When set to 0, new tasks start synchronously in the current thread.
-- New threads are created by 'parallel', and API calls that use parallel.
threads :: Int -> TransIO a -> TransIO a
threads n process = do
   msem <- gets maxThread
   sem <- liftIO $ newIORef n
   modify $ \s -> s { maxThread = Just sem }
   r <- process <*** (modify $ \s -> s { maxThread = msem }) -- restore it
   return r

-- | disable any limit to the number of threads for a process
anyThreads :: TransIO a -> TransIO a
anyThreads process= do
   msem <- gets maxThread
   modify $ \s -> s { maxThread = Nothing }
   r <- process <*** (modify $ \s -> s { maxThread = msem }) -- restore it
   return r

-- clone the current state as a child of the current state, with the same thread
-- cloneInChild :: [Char] -> IO EventF
cloneInChild name= do
  st    <-  get
  hangFrom st name

-- hang a free thread in some part of the tree of states, so it no longer is free
hangFrom st name= do
      rchs  <-  liftIO $ newMVar []
      th    <-  liftIO $ myThreadId
      label <-  liftIO $ newIORef (Alive, if not $ null name then BS.pack name else mempty)
      rparent <- liftIO $ newIORef $ Just st
      st''  <-  get

      let st' = st''{ parent   = rparent
                    , children = rchs
                    , labelth  = label
                    , threadId = th } -- unsafePerformIO $ newIORef th }
      liftIO $ do
        hangThread st st'  -- parent could have more than one children with the same threadId
        -- hangThread do it: atomicModifyIORef (labelth st) $ \(status, label) -> ((if status==DeadParent then status else Parent,label),())
        return st'

hangFrom' st name= do
      -- th    <-  liftIO $ myThreadId
      -- label <-  liftIO $ newIORef (Alive, if not $ null name then BS.pack name else mempty)
      -- st''  <-  get

      -- let st' = st''{ parent   = unsafePerformIO $ newIORef $ Just st
      --               , labelth  = label
      --               , threadId = th }
      st' <- get
      liftIO $ writeIORef (parent st')  $ Just st
      liftIO $ do
        hangThread st st'  -- parent could have more than one children with the same threadId
        return st

-- remove the current child task from the tree of tasks. 
-- removeChild :: (MonadIO m,TransMonad m) => m ()
-- removeChild = do
--   st <- get
--   mparent <- removeChild' st
--   when (isJust mparent) $ put $ fromJust mparent

removeChild st= do
    mparent <- liftIO $ readIORef $ parent st
    case mparent of
     Nothing -> return ()
     Just parent ->  modifyMVar (children parent) $ \ths ->
                    return (filter (\st' -> threadId st' /= threadId st) ths,())
                  -- !> ("removeChild",threadId st, "from",threadId parent)

-- removeChild' st= do
--   mparent <- liftIO $ readIORef $ parent st
--   case mparent  of
--      Nothing -> return Nothing
--      Just parent -> do 
--        sts <- liftIO $ modifyMVar (children parent) $ \ths -> do
--                     let (xs,sts)= partition (\st' -> threadId st' /= threadId st) ths
--                     ys <- case sts of
--                             [] -> return []
--                             st':_ -> readMVar $ children st'
--                     return (xs ++ ys,sts)


--        case sts of
--           [] -> return()
--           st':_ -> do
--               (status,_) <- liftIO $ readIORef $ labelth st'
--               if status == Listener || threadId parent == threadId st then return () else liftIO $  (killThread . threadId) st'
--        return $ Just parent

-- | Terminate all the child threads in the given task set and continue
-- execution in the current thread. Useful to reap the children when a task is
-- done, restart a task when a new event happens etc.
oneThread :: TransIO a -> TransIO a
oneThread comp = do
    st  <- noTrans $ cloneInChild "oneThread" >>= \st -> put st >> return st
    -- put st

    let rchs= children st
    liftIO $ writeIORef (labelth st) (DeadParent,mempty)
    x   <- comp
    th  <- liftIO myThreadId
    chs <- liftIO $ readMVar rchs
    tr(th,map threadId chs)
    liftIO $ killChildren1 th st
    -- liftIO $ mapM_ (killChildren1 th) chs

    return x

-- kill all the children except one
killChildren1 :: ThreadId  ->  EventF -> IO ()
killChildren1 th state = do
        ths' <- modifyMVar (children state) $ \ths -> do
                    let (inn, ths')=  partition (\st -> threadId st == th) ths
                    return (inn, ths')
        tr("tokill",map threadId ths')
        mapM_ (killChildren1  th) ths'
        mapM_ (killThread . threadId) ths'

-- oneThread :: TransIO a -> TransIO a
-- oneThread comp = do
--   st <- get 
--   let rchs=  if isJust $ parent st then  children $ fromJust $parent  st else children st

--   x <- comp
--   chs <- liftIO $ readMVar rchs

--   liftIO $ mapM_ killChildren1 chs

--   return x
--   where 

--   killChildren1 ::  EventF -> IO ()
--   killChildren1  state = do
--       forkIO $ do
--           ths <- readMVar $ children state

--           mapM_ killChildren1  ths

--           mapM_ (killThread . threadId) ths
--       return()


-- | Add a label to the current passing threads so it can be printed by debugging calls like `showThreads`
labelState :: (MonadIO m,TransMonad m) => BS.ByteString -> m ()
labelState l =  do
  st <- get
  liftIO $ atomicModifyIORef (labelth st) $ \(status,prev) -> ((status,  prev <> BS.pack "," <> l), ())

-- | return the threadId associated with an state (you can see all of them with the console option 'ps')
threadState thid= do
  st <- findState match =<<  topState
  return  st :: TransIO EventF
  where
  match st= do
     (_,lab) <-liftIO $ readIORef $ labelth st
     return $ if BS.isInfixOf thid lab then True else False

-- | remove the state  which contain the string in the label (you can see all of them with the console option 'ps')
removeState thid= do
      st <- findState match =<<  topState
      liftIO $ removeChild st

      -- liftIO $ killBranch' st
      where
      match st= do
         (_,lab) <-liftIO $ readIORef $ labelth st
         return $ if BS.isInfixOf thid lab then True else False


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
          -- when (state == Dead) $ putStr " dead" -- 
          putStr " " >> putStr (show state) --
          putStrLn $ if mythread == threadId ch then " <--" else ""
        chs <- readMVar $ children ch
        mapM_ (showTree $ n + 2) $ reverse chs
  showTree 0 st
{-
# 933 "/home/user/transient-stack/transient/src/Transient/Internals.hs"

-}
-- | Return the state of the thread that initiated the transient computation
-- topState :: TransIO EventF

topState :: (TransMonad m, MonadIO m) => m EventF
topState = do
  st <- get
  toplevel st
  where
    toplevel st = do
      par <- liftIO $ readIORef $ parent st
      case par of
        Nothing -> return st
        Just p  -> toplevel p


-- changeParent cont=  do
--     th <- liftIO myThreadId
--     st <- get
--     curparent <- liftIO $ readIORef $ parent st

--     tr ("HI",th,threadId $ fromJust curparent)

--     showThreads $ fromJust curparent
--     topState >>= showThreads




    -- st <- get
    -- liftIO $ do
    --   curparent <- readIORef $ parent st
    --   th <-  myThreadId
    --   when(isJust curparent) $ 
    --       let par= fromJust curparent 
    --       in modifyMVar_ (children par) $ \chs -> return $ filterFirst th chs
    --   writeIORef (parent st) $ Just cont
    -- where
    -- filterFirst _ []= [] 
    -- filterFirst th (st:sts)= if threadId st== th then sts else st:filterFirst th sts

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



-- | Add n threads to the limit of threads. If there is no limit, do nothing.
addThreads' :: Int -> TransIO ()
addThreads' n= noTrans $ do
  msem <- gets maxThread
  case msem of
    Just sem -> liftIO $ modifyIORef sem $ \n' -> n + n'
    Nothing  -> return() --do
      -- sem <- liftIO (newIORef n)
      -- modify $ \ s -> s { maxThread = Just sem }

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
-- By default, child threads can be terminated using the kill primitives. Disabling
-- it may improve performance, however, all threads must be well-behaved
-- to exit on their own to avoid a leak.
freeThreads :: TransIO a -> TransIO a
freeThreads process = do
  st <- get
  put st { freeTh = True }
  r  <-  process
  -- hangFrom' st "free"

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
    atomicModifyIORef (labelth cont) $ \(_,lab) -> ((Alive, lab),())

endSiblings= do
  cont <- getCont
  par <- liftIO $ readIORef $ parent cont
  when (isJust par)$
     liftIO $ killChildren1 (threadId cont) $ fromJust par

-- | Kill the current thread and the childs.
killBranch :: TransIO ()
killBranch = noTrans $ do
  st <- get
  liftIO $ killBranch' st

-- | Kill the childs and the thread of a state
killBranch' :: EventF -> IO ()
killBranch' cont = do
  atomicModifyIORef (labelth cont) $ \(_,label) -> ((Dead,label),())

  let thisth  = threadId  cont
      mparent = parent    cont

  killChildren $ children cont
  par <- liftIO $ readIORef $ parent cont

  when (isJust par) $
    modifyMVar_ (children $ fromJust par) $ \sts ->
      return $ filter (\st -> threadId st /= thisth) sts
  killThread $ thisth -- !> ("kill this thread:",thisth)
  return ()


-- * Extensible State: Session Data Management

-- | Same as 'getSData' but with a more conventional interface. If the data is found, a
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
-- If the data item is not found, empty is executed, so the  alternative computation will be executed, if any. 
-- Otherwise, the computation will stop.
-- If you want to print an error message or return a default value, you can use an 'Alternative' composition. For example:
--
-- > getSData <|> error "no data of the type desired"
-- > getInt = getSData <|> return (0 :: Int)
--
-- The later return either the value set or 0.
--
-- It is highly recommended not to use it directly, since his relatively complex behaviour may be confusing sometimes.
-- Use instead a monomorphic alias like "getInt" defined above.
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
-- is deleted. Otherwise, updated.
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
  return $ if isNothing ma then v else unsafeCoerce f $ fromJust  ma
  where
  t          = typeOf v
  alterf  _ _ x = unsafeCoerce $ f $ unsafeCoerce x

-- | Same as `modifyData`
modifyState :: (TransMonad m, Typeable a) => (Maybe a -> Maybe a) -> m ()
modifyState = modifyData

-- | Same as `setData`
setState :: (TransMonad m, Typeable a) => a -> m ()
setState = setData

-- | Delete the data item of the given type from the monad state.
delData :: (TransMonad m, Typeable a) => a -> m ()
delData x = modify $ \st -> st { mfData = M.delete (typeOf x) (mfData st) }

-- | Same as `delData`
delState :: (TransMonad m, Typeable a) => a -> m ()
delState = delData

-- | get a pure state identified by his type and an index
getIndexData n= do
  clsmap <- getData `onNothing` return M.empty
  return $ M.lookup n clsmap

-- | set a pure state identified by his type and an index
setIndexData n val= do
  modifyData' (\map -> M.insert n val map) (M.singleton n val)

withIndexData
  :: (TransMonad m,
      Typeable k,
      Typeable a, Ord k) =>
     k -> a -> (a -> a) -> m (M.Map k a)
withIndexData i n f=
      modifyData' (\map -> case M.lookup i map of
                              Just x -> M.insert i (f x) map
                              Nothing -> map <> (M.singleton i n)) (M.singleton i n)


getIndexState n= Transient $ getIndexData n

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
-- Initialized the first time it is set, but unlike `newRState`, which ever creates a new reference, 
-- this one update it if it exist already
setRState:: (MonadIO m,TransMonad m, Typeable a) => a -> m ()
setRState x= do
    Ref ref <- getData `onNothing` do
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

-- | return the reference value. It has not been  created, the computation stop and executes the anternative computation if any
getRState :: Typeable a => TransIO a
getRState= Transient getRData

delRState x= delState (undefined `asTypeOf` ref x)
  where ref :: a -> Ref a
        ref = undefined

-- | Run an action, if it does not succeed, undo any state changes
-- that may have been caused by the action and allow aternative actions to run with the original state
try :: TransIO a -> TransIO a
try mx = do
  st <- get
  mx <|> (modify (\s' ->s' { mfData = mfData st,parseContext=parseContext st}) >> empty)

-- | Executes the computation and restores all the state variables accessed by Data State, RData, RState and parse primitives.
sandbox :: TransIO a -> TransIO a
sandbox mx = do
  st <- get
  mx <*** modify (\s ->s { mfData = mfData st, parseContext= parseContext st})

-- | executes a computation and restores the concrete state data. Default state is assigned if there isn't any before execution
sandboxData :: Typeable a => a -> TransIO b -> TransIO b
sandboxData def w= do
   d <- getState <|> return  def
   w  <***  setState  d






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
-- > sync (async  whatever) <|>  liftIO (print "hello") -- never print "hello" uf watever return something
--
-- the thread before and after `sync`is the same.
-- If the comp. return more than one result, the first result will be returned

sync :: TransIO a -> TransIO a
sync pr= do
    mv <- liftIO newEmptyMVar
    -- if pr is empty the computation does not continue. It blocks
    (abduce >> pr >>= liftIO . (putMVar mv) >> empty) <|> liftIO (takeMVar mv)
        -- mr <- liftIO $ tryTakeMVar mv   do not work
        -- case mr of
        --    Nothing -> empty
        --    Just r  -> return r
-- si proc,que es asincrono, es empty, no sigue. solo sigue cuando devuelve algo

-- alternative sync 
-- sync x = do
--   was <- gets execMode 
--   -- solo garantiza que el alternativo no se va a ejecutar
--   r <- x <** modify (\s ->s{execMode= Remote})
--   modify $ \s -> s{execMode= was}
--   return r



-- | Another name for `sync`
await :: TransIO a -> TransIO a
await=sync

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



-- | fork an independent process. It is equivalent to forkIO. The thread(s) created 
-- are managed with the thread control primitives of transient
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
    Nothing    -> liftIO $ do
      atomicModifyIORef (labelth cont) $ \(status, lab) -> ((if status==DeadParent then status else Parent, lab), ())
      loop cont ioaction
      return Nothing

-- | Execute the IO action and the continuation
-- loop ::  EventF -> IO (StreamData t) -> IO ()
loop parentc rec = forkMaybe False parentc $ \cont -> do

  liftIO $ atomicModifyIORef (labelth cont) $ \(_,label) -> ((Listener,label),())

  let loop' = do
        (t,lab) <- readIORef $ labelth parentc
        if t==Dead  then  tr ("Dead parent",t,lab,threadId parentc) >> return(Nothing,cont)  else do
          --  tr("loop", unsafePerformIO $ myThreadId)

            atomicModifyIORef (labelth cont)$ \(_,lab)-> ((Parent, lab),())

            mdat <- rec  `catch` \(e :: SomeException) -> return $ SError e
            case mdat of
                se@(SError _)  -> setworker cont >> iocont  se    cont
                SDone          -> do
                  setworker cont
                  -- (_,cont') <- 
                  iocont  SDone cont
                  -- exceptBack cont' $ toException $ Finish $ show $ unsafePerformIO myThreadId

                last@(SLast _) -> do
                  setworker cont
                  -- (_,cont') <- 
                  iocont  last  cont
                  -- exceptBack cont' $ toException $ Finish $ show $ unsafePerformIO myThreadId

                more@(SMore _) -> do
                  r <-forkMaybe False cont $ iocont  more
                  (t,_) <- readIORef $ labelth parentc
                  -- liftIO $ print (t,unsafePerformIO myThreadId)
                  if t==Dead  then return r else loop'
                  -- loop'


          where
          setworker cont=  liftIO $ atomicModifyIORef (labelth cont) $ \(_,lab) -> ((Alive,lab),())

          iocont  dat cont = do

              let cont'= cont{event= Just $ unsafeCoerce dat}
              -- (_,st) <- 
              runStateT (runCont cont')  cont'
              -- exceptBackg st $ Finish $ show $ (1,unsafePerformIO myThreadId)
              -- return ()


  loop'
  -- return ()
  where
  {-# INLINABLE forkMaybe #-}
  forkMaybe :: Bool -> EventF -> (EventF -> IO (Maybe a,EventF)) -> IO (Maybe a,EventF)
  forkMaybe onemore parent  proc = do
    (t,lab) <- readIORef $ labelth parent
    if t==Dead  then return(Nothing,parent) else do
      rparent <- newIORef $ Just parent
      case maxThread parent  of
        Nothing -> forkIt rparent  proc
        Just sem  -> do
          dofork <- waitQSemB onemore sem
          if dofork
            then forkIt rparent proc
            else ( proc parent   >>= \(_,cont) -> exceptBackg cont $ Finish $ show (unsafePerformIO myThreadId,"loop thread ended"))
                              `catch` \e -> exceptBack parent e


  forkIt rparentState  proc= do
     chs <- liftIO $ newMVar []
     Just parentState <- readIORef rparentState
    --  let cont = parentState{parent=Just parentState,children=   chs, labelth= label}
     label <- newIORef (Alive, BS.pack "work")

     void $ forkFinally1  (do
         th <- myThreadId
         tr "thread init"
         let cont'= parentState{parent=rparentState, children= chs, labelth= label,threadId=  th}
         when(not $ freeTh parentState )$ hangThread parentState cont'


         proc cont'  )  -- `catch` execute Finish porque es una excepción no tratada. pero para eso hay que quitar el catch inicial?
                                    -- no porque el estado se conserva hasta el primer exception handler, 
                                    -- por lo que en el ultimo habdler en keep hay que ejecutar el finish.
         $ \me -> do

          --  th <- myThreadId
          --  print ("acaba",th)

           case maxThread parentState of
               Just sem -> signalQSemB sem
               Nothing -> return ()


          --  (status,_) <- liftIO $ readIORef label

           case me of
              Left ( e) -> do
                  exceptBack parentState e -- tiene que hacerse antes de  free, a no ser que se haga hangFrom
                  freelogic  rparentState parentState label
                  th <- myThreadId
                  exceptBackg parentState  $ Finish $ show (th,e)
                  return()

              Right(_,lastCont) -> do
                  freelogic  rparentState parentState label
                  tr ("finalizing normal",threadId lastCont, unsafePerformIO $ readIORef $ labelth lastCont)
                  th <- myThreadId
                  tr "antes de exceptbaack"

      
                  exceptBackg lastCont  $ Finish $ show (th,"async thread ended")
                  return()


     return(Nothing,parentState)--  return ()


  -- forkFinally1 :: IO a -> (Either SomeException a -> IO ()) -> IO ThreadId
  forkFinally1 action and_then =
       mask $ \restore ->  forkIO $ Control.Exception.try (restore action) >>= and_then

freelogic rparentState parentState label =do
  if(freeTh parentState  ) then return False else do -- if was not a free thread
    Just actualParent <-readIORef rparentState
    th <- myThreadId


    (can,lab) <- atomicModifyIORef label $ \(l@(status,lab)) ->
      {-
      -- threads 0 $ choose.... la primera iteracion cierra
      -- abduce <|> threadDelay    cierra antes de que acabe el delay
      -- un proceso puede crear un hijo que muere antes que el padre. si no tiene hijos quien elimina el deadparent?

      solucion:
      deadParent sin hijos-> free de ese deadparent
      no dispara el onFinish cuando no tiene hijos, sino cuando acaba ese thread Y no tiene hijos
      case canfinal of
        DeadParent -> if nochildren free th actualParent
        Listener -> return()
        _ -> free th
      -}
      ((case status of Alive -> Dead ; Parent -> DeadParent; _ -> status, lab),l)
    -- los procesos que acaban de morir sin hijos (deadparent) tambien deben liberarse
    if ({- can /= Parent && can /= DeadParent && -} can /= Listener)
      then do  tr("FREEE",th); free th actualParent  ; return True
      else return False
                  -- !> ("th",th,"actualParent",threadId actualParent,can,lab)

-- free th env = return True  
free th env = do
       threadDelay 1000             -- wait for some activity in the children of the parent thread, to avoid
                                    -- an early elimination
       let sibling=  children env
      --  sb <- readMVar sibling
       (sbs',found) <- modifyMVar sibling $ \sbs -> do
                   let (sbs', found) = drop [] th  sbs
                   return (sbs',(sbs',found))
       if found
         then do

           (typ,_) <- readIORef $ labelth env
           tr ("freeing:",th,typ,"in",threadId env,"childs parent", length sbs',map threadId sbs',isJust (unsafePerformIO $ readIORef $ parent env))
           if (null sbs' && typ /= Listener && isJust (unsafePerformIO $ readIORef $ parent env))
            -- free the parent
              then  do
                (typ,_) <- readIORef $ labelth env
                if typ==DeadParent
                  then do
                      tr "DEADPARENT"
                      free (threadId env) (fromJust $ unsafePerformIO $ readIORef  $ parent env)
                      -- return True 
                  else return False -- if typ== Parent then return True else return False
              else return False


         else return False
       where
       drop processed th []= (processed,False)
       drop processed th (evtss@(ev:evts))
          | th ==  threadId ev=
                    let u= unsafePerformIO
                        typ= fst (u $ readIORef $ labelth ev)
                    in if typ==DeadParent && length (u (readMVar $ children ev))==0
                          || (typ /= Parent && typ /= DeadParent)
                          then
                            (processed ++ evts, True)
                          else (processed ++ evtss,False)
          | otherwise= drop (ev:processed) th evts



hangThread parentProc child =  do
                      let headpths= children parentProc
      --  (s,_) <-liftIO $ readIORef (labelth parentProc)
      --  if s== Dead then tr ("parent dead, killing", threadId child) >> myThreadId >>= killThread 
      --              else 
                      ths <-modifyMVar headpths $ \ths -> return (child:ths,ths)
                      when (null ths) $  atomicModifyIORef (labelth parentProc) $ \(status, label) -> ((if status==DeadParent then status else Parent,label),())

      --  tr ("hangthread",threadId child,"hang from",threadId parentProc)



           --  !> ("hang", threadId child, threadId parentProc,map threadId ths,unsafePerformIO $ readIORef $ labelth parentProc)

-- | kill  all the child threads associated with the continuation context
killChildren childs  = do
        -- forkIO $ do
           ths <- modifyMVar childs  $ \ths -> return ([],ths)
           mapM_ (\th -> do
              (status,_) <- atomicModifyIORef (labelth th) $ \(l@(status,label)) ->
                    ((if status== Alive then Dead else status, label),l)
              when (status /= Listener && status /= Parent) $ killThread $ threadId th  {- !> ("killChildren",threadId th, status)-}) ths  >> return ()
                              -- como choose es parent, no lo puede matar.
           mapM_ (killChildren . children) ths
        -- return ()
          --  putMVar childs []




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
react setHandler iob= Transient $ do
        -- st <- cloneInChild "react"
        -- delete  all  current finish handlers since they should not trigger
        setData $ Backtrack (Nothing `asTypeOf` Just (Finish "")) []

        modify $ \s -> s{execMode=let rs= execMode s in if rs /= Remote then Parallel else rs}
        cont <- get
        -- ttr ("THREADS REACT",threadId cont, threadId st)
        liftIO $ atomicModifyIORef (labelth cont) $ \(_,label) -> ((Listener,label),())


        case event cont of
          Nothing -> do
            liftIO $ setHandler $ \dat ->do
              (_,cont') <- runStateT (runCont cont) cont{event= Just $ unsafeCoerce dat} `catch` exceptBack cont
              -- let rparent=  parent st
              -- Just parent <- liftIO $ readIORef rparent
              th <- liftIO myThreadId
              tr ("THREADID", th)
              -- liftIO $ writeIORef (pthreadId st) th
              -- freelogic rparent st (labelth st)
              exceptBackg cont' $ Finish $ show (unsafePerformIO myThreadId,"react thread ended")

              iob

            return Nothing

          j@(Just _) -> do
            put cont{event=Nothing}

            return $ unsafeCoerce j



-- | Same as `keep` but does not read from the standard input, and therefore
-- the async input APIs ('option' and 'input') cannot respond interactively.
-- However, input can still be passed via command line arguments as
-- described in 'keep'.  Useful for debugging or for creating background tasks,
-- as well as to embed the Transient monad inside another computation. It
-- returns either the value returned by `exit` or Nothing, when there are no
-- more threads running
--




newtype Exit a= Exit a deriving Typeable


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

-- | Collect the results of the first @n@ tasks (first parameter) or in a time t (second)
-- and terminate all the non-free threads remaining before
-- returning the results.  n= 0: collect all the results. t==0: no time limit
collect' :: Int -> Int -> TransIO a -> TransIO [a]
collect' number time proc' = hookedThreads $ do
    res <- liftIO $ newIORef []
    done <- liftIO $ newIORef False  --finalization already executed or not
    anyThreads abduce                -- all spawned threads will hang from this one
    cont <- get
    -- liftIO $ atomicModifyIORef (labelth cont) $ \(status, lab) -> ((Parent, lab), ())

    let proc= do

            i <- proc'
            liftIO $ atomicModifyIORef res $ \n-> (i:n,())
            empty

        timer =  do
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
            guard $ hasnot || (number > 0 && length rs >= number)
            f <- liftIO $ atomicModifyIORef done $ \x ->(True,x) -- previous onFinish not triggered?
            if f then backtrack
              else do
                -- tr "forward" 
                forward (Finish "");

        --  -- the finished thread is free. It must be "hanged" -- 
                st <- noTrans $ do
                    th <- liftIO $ myThreadId
                    liftIO $ killChildren1 th cont  --kill remaining threads
                    parent <- liftIO $ findAliveParent cont
                    st <- hangFrom parent $ fromString "finish"
                    put st
                    return st
                anyThreads abduce
                liftIO $ atomicModifyIORef (labelth st) $ \(_,l) ->  ((DeadParent,l),())

                -- liftIO $ readIORef res
                return rs

    localBack (Finish "") $ timer <|> (anyThreads abduce >> (proc `onBack` check) )


-- | look up in the parent chain for a parent state/thread that is still active
findAliveParent st=  do
      par <- readIORef (parent st) `onNothing`  error "findAliveParent: Nothing"
      (st,_) <- readIORef $labelth par
      case st of
          Dead -> findAliveParent par
          DeadParent -> findAliveParent par
          _    -> return par



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
-- the action to be performed in case of backtracking. When 'back' initiates the backtrack, this second parameter is called
-- An `onBack` action can use `forward` to stop the backtracking process and resume to execute forward. 
{-# NOINLINE onBack #-}
onBack :: (Typeable b, Show b) => TransientIO a -> ( b -> TransientIO a) -> TransientIO a
onBack ac bac = registerBack (typeof bac) $ Transient $ do
     -- ttr "onBack"
     Backtrack mreason stack  <- getData `onNothing` (return $ backStateOf (typeof bac))
    --  ttr ("onBackstack",mreason, length stack)
     runTrans $ case mreason of
                  Nothing     -> ac                     -- !>  "ONBACK NOTHING"
                  Just reason -> bac reason             -- !> ("ONBACK JUST",reason)
     where
     typeof :: (b -> TransIO a) -> b
     typeof = undefined


-- | to register  backtracking points of the type of the first parameter within the computation in the second parameter 
-- out of it, these handlers do not exist and are not triggered.
localBack w mx= sandboxData (backStateOf w) mx

-- | 'onBack' for the default track; equivalent to @onBack ()@.
onUndo ::  TransientIO a -> TransientIO a -> TransientIO a
onUndo x y= onBack x (\() -> y)



-- | Register an undo action to be executed when backtracking. The first
-- parameter is a "witness" whose type is used to uniquely identify this
-- backtracking action. The value of the witness parameter is not used.
--
registerBack :: (Typeable b, Show b) => b -> TransientIO a -> TransientIO a
registerBack witness f  = Transient $ do
  --  tr "registerBack"
   cont@(EventF _ x  _ _ _ _ _ _ _ _ _ _ _)  <- get
 -- if isJust (event cont) then return Nothing else do
   md <- getData `asTypeOf` (Just <$> return (backStateOf witness))

   case md of
        Just (Backtrack b []) ->  setData $ Backtrack b  [cont]
        Just (bss@(Backtrack b (bs@((EventF _ x'  _ _ _ _ _ _ _ _ _ _ _):_)))) ->
          when (isNothing b) $
                setData $ Backtrack b (cont:bs)

        Nothing ->  setData $ Backtrack mwit [cont]

   runTrans $ return () >> f
   where
   mwit= Nothing `asTypeOf` (Just witness)
   --addr x = liftIO $ return . hashStableName =<< (makeStableName $! x)



-- XXX Should we enforce retry of the same track which is being undone? If the
-- user specifies a different track would it make sense?
--  see https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=5ef46626e0e5673398d33afb
--
-- | For a given undo track type, stop executing more backtracking actions and
-- resume normal execution in the forward direction. Used inside an `onBack`
-- action.
--
forward :: (Typeable b, Show b) => b -> TransIO ()
forward reason= noTrans $ do
    Backtrack _ stack <- getData `onNothing`  ( return $ backStateOf reason)
    setData $ Backtrack(Nothing `asTypeOf` Just reason)  stack

-- | put at the end of an backtrack handler intended to backtrack to other previous handlers.
-- This is the default behaviour in transient. `backtrack` is in order to keep the type compiler happy
backtrack :: TransIO a
backtrack= return $ error "backtrack should be called at the end of an exception handler with no `forward`, `continue` or `retry` on it"

-- | 'forward' for the default undo track; equivalent to @forward ()@.
retry= forward ()



-- | Start the backtrackng process for a given backtrack type. Performs all the `onBack`
-- actions registered for that type in reverse order. If there
-- are no more `onBack`  actions registered, the execution is stopped
--
back :: (Typeable b, Show b) => b -> TransIO a
back reason =  do
  -- tr "back"
  bs@(Backtrack mreason stack) <- getData  `onNothing`  return (backStateOf  reason)
  goBackt  bs                                                    --  !>"GOBACK"

  where
  runClosure :: EventF -> TransIO a
  runClosure EventF { xcomp = x } = unsafeCoerce  x
  runContinuation ::  EventF -> a -> TransIO b
  runContinuation EventF { fcomp = fs } =  (unsafeCoerce $ compose fs)


  goBackt (Backtrack _ [] )= empty
  goBackt (Backtrack b (stack@(first : bs)) )= do
        setData $ Backtrack (Just reason) bs --stack
        x <-  runClosure first -- <|> ttr "EMPTY" <|> empty                              --     !> ("RUNCLOSURE",length stack)
        Backtrack back bs' <- getData `onNothing`  return (backStateOf  reason)
        -- ttr ("goBackt",back, length bs')

        case back of
                 Nothing    -> do
                        setData $ Backtrack (Just reason) stack
                        st <- get
                        runContinuation first x `catcht` (\e -> liftIO(exceptBack st e) >> empty)               -- !> "FORWARD EXEC"
                 justreason -> do
                        --setData $ Backtrack justreason bs
                        goBackt $ Backtrack justreason bs      --  !> ("BACK AGAIN",back)
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


-- newtype FinishReason= FinishReason (Maybe SomeException) deriving (Typeable, Show)



-- | Register an action that to be run when the activity below this statement has been finished.
-- 
-- Can be used multiple times to register multiple actions. Actions are run in
-- reverse order. 
--
-- A thread execute the Finish backtrack at the end of execution. onFinish handlers will be executed to check if there are no child threads
-- under it. in this case the finalization action is executed.
-- it does not work with `freeThreads`.
onFinish exc= do
  cont <- getCont
  onFinishCont cont (return())  exc


-- | A binary onFinish which will return a result when all the threads of the first operand terminates so it can return a result. 
-- the first parameter is the action and the second the action to do when all is done.
-- 
-- >>> main=   keep' $ do
-- >>>   container <-  create some mutable container to gather results
-- >>>   results   <- (SomeProcessWith container >> empty) `onFinish'` \_ -> return container
-- >>>
onFinish' :: TransIO a -> (String -> TransIO a) -> TransIO a
onFinish' proc mx= do
    cont <- getCont
    onFinishCont cont proc $ \reason -> do
       forward (Finish "")
       parent <- liftIO $ findAliveParent cont
       st <- hangFrom parent $ fromString "finish"
       put st
       mx reason

onFinishCont cont proc mx= do
    modify $ \s ->s{ freeTh = False }

    done <- liftIO $ newIORef False  --finalization already executed?

    r <- proc `onBack`  \(Finish reason) -> do
                tr ("thread end",reason,threadId cont)
                -- topState >>= showThreads
                nochild <- hasNoChildThreads cont
                dead <- isDead cont
                this <- get
                let isthis = threadId cont == threadId this
                    is     = nochild && (dead || isthis)
                tr ("is",is, "nochild",nochild,threadId this,threadId cont,unsafePerformIO $readIORef $labelth this)

                guard is
                -- previous onFinish not triggered?
                f <- liftIO $ atomicModifyIORef done $ \x ->(if x then x else not x,x)
                if f then backtrack else
                    mx reason
    -- anyThreads abduce  -- necessary for controlling threads 0
    -- to protect the stack of finish. The default exeception mechanism don't know about state
    onException $ \(e::SomeException) -> throwt e
    return r
    where
    isDead st= liftIO $ do
      (can,_) <- readIORef $ labelth st
      return $ can==DeadParent

-- | Abort finish. Stop executing more finish actions and resume normal
-- execution.  Used inside 'onFinish' actions.
-- NOT RECOMMENDED FINISH ACTIONS SHOULD NOT BE ABORTED. USE EXCEPTIONS INSTEAD
noFinish= forward $ Finish ""


-- | trigger the execution of the argument when all the threads under the statement are stopped and waiting for events.
-- usage example https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=61be6ec15a172871a911dd61
onWaitThreads :: (String -> TransIO ()) -> TransIO ()
onWaitThreads   mx= do
    cont <- get
    modify $ \s ->s{ freeTh = False }

    done <- liftIO $ newIORef False  --finalization already executed?

    r <- return() `onBack`  \(Finish reason) -> do
                -- topState >>= showThreads
                tr ("thread cont",threadId cont)
                noactive <- liftIO $ noactiveth cont
                dead <- isDead cont
                this <- get
                let isthis = threadId this == threadId cont
                    is = noactive && (dead || isthis)
                tr is
                guard is
                -- previous onFinish not triggered?
                f <- liftIO $ atomicModifyIORef done $ \x ->(if x then x else not x,x)
                if f then backtrack else
                    mx reason
    -- anyThreads abduce  -- necessary for controlling threads 0

    return r
    where
    isDead st= liftIO $ do
      (can,_) <- readIORef $ labelth st
      return $ can==DeadParent
{-# NOINLINE noactiveth #-}
noactiveth st=
    return $ and $ map (\st' -> (let l=fst (label st')in l == Parent || l == DeadParent)  &&
                                (null (childs st') || (ex $ noactiveth st'))) $ childs st
    where
    childs= ex . readMVar . children
    label = ex . readIORef . labelth
    ex= execWhenEvaluate

{-# NOINLINE execWhenEvaluate #-}
execWhenEvaluate= unsafePerformIO

-- | initiate the Finish backtracking. Normally you do not need to use this. It is initiated automatically by each thread at the end
finish :: String -> TransIO ()
finish reason= back reason

hasNoChildThreads :: EventF -> TransIO Bool
hasNoChildThreads st= do  -- necesario saber si no tiene threads Y NO TIENE LOOP PENDIENTE
    -- para saberlo: si threads están limitadas, cuantas quedan, si quedan 0 es que hay trabajo pendiente?
    --  si el thread es principal, ejecutar onFinish (si thredId th= threadId Cont y threads=0 y...)
    chs <- liftIO $ readMVar $ children st
    -- liftIO $ print ("nomorethreads=",map threadId chs,unsafePerformIO myThreadId)
    -- topState >>= showThreads
    return $ null chs


-- | open a resouce `a` and close it when it is no longer used.
-- See https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=6011851a5500a97f82caed53 
openClose :: (TransIO a) -> (a -> TransIO ()) -> TransIO a
openClose open close= tmask $ do
                res <- open
                onFinish $ \_ -> close res
                return res

-- | Trigger exception when the parameter is SError, stop the computation when the parameter is SDone
checkFinalize v=
   case v of
      SDone ->  stop
      SLast x ->  return x
      SError e -> throwt  e
      SMore x -> return x

------ exceptions ---
--
-- | Install an exception handler. Handlers are executed in reverse (i.e. last in, first out) order when such exception happens in the
-- rest of the code below. Note that multiple handlers can be installed and called for the same exception type. `continue` will stop 
-- the backtracking and resume the excecution forward.
--
-- The semantic is, thus, different than the one of `Control.Exception.Base.onException`
-- onException also catches exceptions initiated by Control.Exception primitives, Sistem.IO.error etc. 
-- It is compatible with ordinary Haskell exceptions.
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

-- | mask exceptions while the argument is excuted
tmask proc= Transient $ do
  st <-get
  (mx,st') <- liftIO $ uninterruptibleMask_ $ runTransState st proc
  -- liftIO $ print "end MASK"
  put st'
  return mx

-- | Binary version of `onException`.  Used mainly for expressing how a resource is treated when an exception happens in the first argument 
-- OR in the rest of the code below. This last should be remarked. It is the semantic of `onBack` but restricted to exceptions.
--
-- If you want to manage exceptions only in the first argument and have the semantics of `catch` in transient, use `catcht`
onException' :: Exception e => TransIO a -> (e -> TransIO a) -> TransIO a
onException' mx f= onAnyException mx $ \e -> do
            -- tr  "EXCEPTION HANDLER EXEC" 
            case fromException e of
               Nothing -> do
                  -- Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)      
                  -- setData $ Backtrack r $ tail stack
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

exceptBack ::  EventF -> SomeException -> IO (Maybe a, EventF)
exceptBack  =  exceptBackg

exceptBackg :: (Typeable e, Show e) => EventF -> e -> IO (Maybe a, EventF)
exceptBackg st e= do
                      -- tr ("back",e)
                      runStateT ( runTrans $  back e ) st                 -- !> "EXCEPTBACK"

-- re execute the first argument as long as the exception is produced within the argument. 
-- The second argument is executed before every re-execution
-- if the second argument executes `empty` the execution is aborted.

whileException :: Exception e =>  TransIO b -> (e -> TransIO())  -> TransIO b
whileException mx fixexc =  mx `catcht` \e -> do fixexc e; whileException mx fixexc

-- | Delete all the exception handlers registered till now.
cutExceptions :: TransIO ()
cutExceptions= backCut  (undefined :: SomeException)

-- | Use it inside an exception handler. it stop executing any further exception
-- handlers and resume normal execution from this point on.
continue :: TransIO ()
continue = forward (undefined :: SomeException)   -- !> "CONTINUE"

-- -- only for single threaded. Not general
-- catcht' :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
-- catcht' mx exc= do
--   st <- get
--   (mx,st') <- liftIO $ runStateT ( runTrans $  mx ) st `catch` \e -> runStateT ( runTrans $  exc e ) st
--   put st' 
--   case mx of
--     Just x -> return x
--     Nothing -> empty

-- | catch an exception in a Transient block
--
-- The semantic is the same than `catch` but the computation and the exception handler can be multirhreaded
catcht :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
catcht mx exc= localExceptionHandlers $ onException' mx  $ \e  ->  continue >> exc e


catcht' :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
catcht' mx exc= do
    rpassed <- liftIO $ newIORef  False
    sandbox  $ do
         r <- onException' mx (\e -> do
                 passed <- liftIO $ readIORef rpassed
                --  return () !> ("CATCHT passed", passed)
                 if not passed then continue >> exc e else do
                    Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)
                    setData $ Backtrack r $ tail stack
                    back e
                    -- return () !> "AFTER BACK"
                    empty )

         liftIO $ writeIORef rpassed True
         return r
   where
   sandbox  mx= do
     exState <- getState <|> return (backStateOf (undefined :: SomeException))
     mx
       <*** do setState exState

-- | throw an exception in the Transient monad keeping the state variables. It initiates the backtraking for the exception of this type.
-- there is a difference between `throw` (from Control.Exception) and `throwt` since the latter preserves the state, while the former does not.
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

-- | to register exception handlers within the computation passed in the parameter. The handlers do not apply outside
--
-- >  onException (e :: ...) -> ...   -- This may be triggered by exceptions anywhere below
-- >  localExceptionHandlers $ do
-- >      onException $ \(e ::IOError) -> do liftIO $ print "file not found" ; empty   -- only triggered inside localExceptionHandlers
-- >      content <- readFile file
-- >      ...
-- >  next...
localExceptionHandlers :: TransIO a -> TransIO a
localExceptionHandlers w= do
   r <- sandboxData (backStateOf  (undefined :: SomeException))  $ w
   onException $ \(SomeException _) -> return()
   return r

