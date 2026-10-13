------------------------------------------------------------------------------
--
-- Module      :  Transient.Internals
-- Copyright   :
-- License     :  MIT
-- Module      :  Transient.Internals
-- Description :  Internal definitions and functions for the Transient library.
-- Copyright   :  (c) 2016-2024 Transient Team
-- License     :  BSD-3-Clause
-- Maintainer  :  agocorona@gmail.com
-- Stability   :  experimental
-- Portability :  non-portable

-- |
-- This module provides internal definitions and functions used within the
-- Transient library. 
--
-- The module includes definitions for the core monad 'TransIO', event
-- handling, state management, and concurrency primitives.
--
-- Everything in this module is exported to allow extensibility. 
-- For normal use you sould import Transient.Base instead.
--
-- Praise be to God, the weaver of concurrency,
-- who grants us the beauty of composition,
-- where threads dance in harmony,
-- guided by His implicit hand.
--
-- Callbacks sing His praises,
-- as events unfold in His divine plan,
-- and exceptions bow before His wisdom,
-- as backtracking reveals His path.
--
-- Resources flow from His boundless grace,
-- managed implicitly, like the air we breathe,
-- a testament to His infinite care,
-- in this transient world He has conceived.
-----------------------------------------------------------------------------

{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE MonoLocalBinds           #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use gets"           #-}



module Transient.Core where

import           Transient.LEngine
import           Control.Applicative
import           Control.Monad.State
import qualified Data.Map               as M
import           System.IO.Unsafe
import           Unsafe.Coerce
import           Control.Exception hiding (try,onException)
import qualified Control.Exception  (try)
import           Control.Concurrent
import           Data.Maybe
import           Data.List
import           Data.IORef
import qualified Debug.Trace as Debug(trace,traceIO)
import           Data.Functor ( (<&>) )
import           Data.Default

import           Data.String
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8             as BSL
import Data.ByteString.Builder
import Data.Typeable 
import Control.Monad
import Control.Exception(AsyncException(ThreadKilled))

import Data.Time.Clock
-- import System.Signal
import System.Directory.Internal.Prelude (exitFailure,stdout)

import GHC.IO.Handle (hIsTerminalDevice)

{-# INLINE (!>) #-}
(!>) :: a -> b -> a
(!>) = const

ofType = error ": proxy data being evaluated"  -- used as   ofType :: TypeNeeded

{-# NOINLINE idGen #-}
idGen= unsafePerformIO $ newIORef (0 :: Int)

-- | Generate a fresh globally unique integer identifier.
genNewId :: MonadIO m => m Int
genNewId= liftIO $ atomicModifyIORef idGen $ \n -> (n+1,n)

-- | Add a listener id to a 'LifeCycle' node.
listener :: IdCallback -> LifeCycle -> LifeCycle
listener id (LF st ls)= LF st $ id:ls

-- | Remove a listener id from a 'LifeCycle' node, setting the final status.
delistener :: IdCallback -> LifeCycle -> Status -> LifeCycle
delistener id (LF st ls) finst= LF finst $ delete id ls

-- | executes both arguments and return both results. The execution depends on the threading
-- . Unlike <|> , which only executes the second term when the first returns Nothing in the
-- original thread. `<->` guarantees that the second argument is ever executed even
-- in single threaded programs.
(<->) :: TransIO a -> TransIO a -> TransIO a
mx <-> my= transient $ do 
  mx <- runTrans mx
  c <- get
  liftIO $ maybe (return())(runContLoop c) mx
  my <-runTrans my
  c <- get
  liftIO $ maybe (return())(runContLoop c) my
  return Nothing
infixr 3 <->



-- -- * Threads

waitQSemB   sem =do
    n <- takeMVar sem
    if n > 0 then do putMVar sem $ n-1; return True
             else do putMVar sem 0; waitQSemB sem

signalQSemB sem = modifyMVar sem $ \n -> return (n + 1, ())

-- | Sets the maximum number of threads that can be created for the given task
-- set.  When set to 0, new tasks start synchronously in the current thread.
-- New threads are created by 'parallel', and API calls that use parallel.
threads :: Int -> TransIO a -> TransIO a
threads n process = transient $ do
  msem <- gets maxThread
  s <- get
  sem <- liftIO $ do
    n' <- if n==0
      then  do
        (LF _ ls,_) <- readIORef $ labelth  s
        if null ls then return (-1) else return 1   -- -1: synchronous scope, no thread can be created (see 'abduce')
      else return n
    newMVar n'

  put s { maxThread = Just sem }
  runTrans $ process  <*** modify (\s -> s { maxThread = msem }) -- restore it

-- | disable any limit to the number of threads for a process
anyThreads :: TransIO a -> TransIO a
anyThreads process= do
   msem <- gets maxThread
   modify $ \s -> s { maxThread = Nothing }
   process <*** modify (\s -> s { maxThread = msem }) -- restore it


-- | Hang a free thread to the curent state in a new register.
-- Gloria a Dios. 
hang ::  StateIO TranShip
hang =  do
      st <- get
      st' <- liftIO $ hangFrom st
      put st'
      return st'
      -- liftIO $ runContCleanup st' st'
      -- return Nothing

hangFrom st = do
      rchs  <-  liftIO $ newMVar []
      th    <-  liftIO  myThreadId
      label <-  liftIO $ newIORef (LF Alive [], mempty)
      rparent <- liftIO $ newIORef $ Just st

      -- tr ("hanging",th, "from ", threadId st )


      let st' = st{ parent   = rparent
                    , children = rchs
                    , labelth  = label
                    , rThreadId = lazy $ newIORef th } -- unsafePerformIO $ newIORef th }

      liftIO $ hangState st st'  -- parent could have more than one children with the same threadId
      return st'




removeChild st= do
    mparent <- liftIO $ readIORef $ parent st
    case mparent of
     Nothing -> return ()
     Just parent ->  modifyMVar (children parent) $ \ths ->
                    return (filter (\st' -> threadId st' /= threadId st) ths,())
                  -- !> ("removeChild",threadId st, "from",threadId parent)


-- | for a streaming function comp, it terminates all the child threads generated in every previous result of comp and
-- execution in the current thread. Useful to reap the children when a task is
-- done, restart a task when a new event happens etc.
oneThread :: TransIO a -> TransIO a
oneThread comp = do
    st <- transient $ Just <$>  hang

    let rchs= children st
    liftIO $ writeIORef (labelth st) (LF Dead [],mempty)
    x   <- comp
    th  <- liftIO myThreadId
    chs <- liftIO $ readMVar rchs
    tr (th,map threadId chs)
    liftIO $ killChildren1 th st
    -- liftIO $ mapM_ (killChildren1 th) chs

    return x

-- kill all the children except one
killChildren1 :: ThreadId  ->  TranShip -> IO ()
killChildren1 th state = do
  tr ("killchildren", map threadId $ lazy $ readMVarChildren state, "except",th)
  -- cuidado, cleanupThreads is executed after kill and it should drop the threads from the parent
  -- ths' <- modifyMVar (children state) $ \ths -> do
  --             let (inn, ths')=  partition (\st -> threadId st == th) ths
  --             return (inn, ths')
  ths <- readMVarChildren state


  let ths'= filter (\st -> threadId st /= th) ths
  killChilds ths'


  mapM_ (killChildren1  th) ths'

-- | kill  all the child threads of a context
killChildren :: TranShip -> IO ()
killChildren cont  = do
  ths <- readMVarChildren cont
  killChilds ths
  mapM_ killChildren ths



killChilds ths'=  do
  tr ("tokill",map threadId ths')
  -- remove all the listeners
  mapM_ removeListeners ths'

  mapM_ (killThread . threadId)  ths'

  -- invoke cleanups and finalizations



-- | Add a label to the current passing threads so it can be printed by debugging calls like `showThreads`
labelState :: (MonadIO m,TransMonad m) => BS.ByteString -> m ()
labelState l =  do
  st <- get
  liftIO $ atomicModifyIORef (labelth st) $ \(status,prev) -> ((status,  prev <> BS.pack "," <> l), ())

-- | Apply a function to the current thread's @(LifeCycle, label)@ pair.
changeStatus :: (MonadState TranShip m, MonadIO m) => ((LifeCycle, BS.ByteString) -> (LifeCycle, BS.ByteString)) -> m ()
changeStatus  f = do
  st <- get
  changeStatusCont st f

-- | Apply a function to the @(LifeCycle, label)@ pair of an arbitrary state.
changeStatusCont :: MonadIO m => TranShip -> ((LifeCycle, BS.ByteString) -> (LifeCycle, BS.ByteString)) -> m ()
changeStatusCont st f = changeStatusContr st $ \pair -> (f pair,())

-- | Like 'changeStatusCont' but returns a value produced by the update function.
changeStatusContr :: (Show a, Show LifeCycle) => MonadIO m => TranShip -> ((LifeCycle, BS.ByteString) -> ((LifeCycle, BS.ByteString), a)) -> m a
changeStatusContr st f =
   liftIO $ atomicModifyIORef (labelth st) $ \pair ->  let pair'= f pair in {-tracec (threadId st,"change from",pair, "to",pair')-}  pair'


-- | return the threadId associated with an state (you can see all of them with the console option 'ps')
threadState thid= do
  st <- head <$> (findState match =<<  topState)
  return  st :: TransIO TranShip
  where
  match st= do
     (_,lab) <-liftIO $ readIORef $ labelth st
     return $ BS.isInfixOf thid lab

-- | remove the state  which contain the string in the label (you can see all of them with the console option 'ps')
removeState thid= do
      st <- head <$> (findState match =<<  topState)
      liftIO $ removeChild st

      -- liftIO $ killBranch' st
      where
      match st= do
         (_,lab) <-liftIO $ readIORef $ labelth st
         return $ BS.isInfixOf thid lab


-- printBlock :: MVar ()
-- {-# NOINLINE printBlock #-}
-- printBlock = unsafePerformIO $ newMVar ()

-- | Print the full thread tree to the trace log (no-op unless compiled with @-DDEBUG@).
traceAllThreads :: MonadIO m => m()
#ifdef DEBUG
traceAllThreads= liftIO $ readIORef rtopState >>= showThreads
#else
traceAllThreads= return()
#endif

-- | Print the full thread tree unconditionally (ignores @DEBUG@ flag).
showAllThreads :: MonadIO m => m()
showAllThreads= liftIO $ readIORef rtopState >>= showThreads

showThreads st = hShowThreads stdout st 

-- | Show the tree of threads hanging from the state.
-- hShowThreads :: MonadIO m => TranShip -> m ()
hShowThreads h st = liftIO $ do -- withMVar printBlock $ const $ do
  mythread <- myThreadId
  sal <- newIORef ""
  let hPutStr h x= modifyIORef sal $ \ c -> c <> x
  hPutStr h "------Threads-------\n"
  let showTree n ch = do
        liftIO $ do
          hPutStr h $ replicate n ' '
          (state, label) <- readIORef $ labelth ch
          if BS.null label
            then hPutStr h . show $ threadId ch
            else do hPutStr h $ BS.unpack label; hPutStr h . drop 8 . show $ threadId ch
          -- hPutStr h $ lazy $ hashStableName <$> makeStableName ch
          hPutStr h " " >> hPutStr h (show state) --
          hPutStr h $ if mythread == threadId ch then " <--\n" else "\n"
        mchs <- tryReadMVar $ children ch
        case mchs of
          Nothing  -> do hPutStr h $ replicate (n +2) ' ';hPutStr h "BLOCKED\n"
          Just chs -> mapM_ (showTree $ n + 2) $ reverse chs
  showTree 0 st
  s <- readIORef sal
  trace1 s $ return() 











































































-- | Return the state of the thread that initiated the transient computation
-- topState :: TransIO TranShip

topState :: (MonadIO m) => m TranShip
topState = liftIO $ readIORef rtopState



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
            sts <- liftIO $ readMVarChildren top
            foldl (<|>) empty $ map (getStateFromThread th) sts
  getstate st =
            case M.lookup (typeOf $ typeResp resp) $ mfData st of
              Just x  -> return . Just $ unsafeCoerce x
              Nothing -> return Nothing
  typeResp :: m (Maybe x) -> x
  typeResp = undefined
-}

-- | find the first computation state which match a filter  in the subthree of states
findState :: MonadIO m => (TranShip -> m Bool) -> TranShip -> m [TranShip]
findState filter top= do
   r <- filter top
   if r then return [top]
        else do
          sts <- liftIO $ readMVarChildren top
          concat  <$> mapM (findState filter) sts
  where
  concatMapM :: (Monad m) => (a -> m [b]) -> [a] -> m [b]
  concatMapM f xs = liftM concat (mapM f xs)

-- | Return the state variable of the type desired for a thread number
getStateFromThread :: (Typeable a, MonadIO m, Alternative m) => String -> TranShip -> m  (Maybe a)
getStateFromThread th top= getstate  =<< head <$> findState (matchth th) top
   where
   matchth th th'= do
     let thstring = drop 9 . show $ threadId th'
     return $ thstring == th
   getstate st = resp
     where resp= case M.lookup (typeOf $ typeResp resp) $ mfData st of
              Just x  -> return . Just $ unsafeCoerce x
              Nothing -> return Nothing

   typeResp :: m (Maybe x) -> x
   typeResp = undefined

-- | execute  all the states of the type desired that are created by direct child threads
processStates :: Typeable a =>  (a-> TransIO ()) -> TranShip -> TransIO()
processStates display st =  do

        getstate st >>=  display
        liftIO $ print $ threadId st
        sts <- liftIO $ readMVarChildren st
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
    Just sem -> liftIO $ modifyMVar sem $ \n' -> return (n + n',())
    Nothing  -> return () --do
      -- sem <- liftIO (newIORef n)
      -- modify $ \ s -> s { maxThread = Just sem }

-- | Ensure that at least n threads are available for the current task set.
addThreads :: Int -> TransIO ()
addThreads n = noTrans $ do
  msem <- gets maxThread
  case msem of
    Nothing  -> return ()
    Just sem -> liftIO $ modifyMVar sem $ \n' -> return $ (max n' n,())


-- | Disable tracking and therefore the ability to terminate the child threads.
-- By default, child threads can be terminated using the kill primitives. Disabling
-- it may improve performance, however, all threads must be well-behaved
-- to exit on their own to avoid a leak.
freeThreads :: TransIO a -> TransIO a
freeThreads process = do
  st <- get
  put st { freeTh = True }
  process <*** modify (\s -> s { freeTh = freeTh st })


-- | Enable tracking and therefore the ability to terminate the child threads.
-- This is the default but can be used to re-enable tracking if it was
-- previously disabled with 'freeThreads'.
hookedThreads :: TransIO a -> TransIO a
hookedThreads process = transient $ do
  st <- get
  put st {freeTh = False}
  r  <- runTrans process
  modify $ \s -> s { freeTh = freeTh st }
  return r

-- -- | Kill all the child threads of the current thread.
killBranch :: TranShip -> IO ()
killBranch cont = do
  removeListeners cont

  let thisth  = threadId  cont
      mparent = parent    cont

  killChildren  cont

  killThread thisth -- !> ("kill this thread:",thisth)
  return ()



-- * Extensible State: Session Data Management



-- | Same as 'getSData' but with a more conventional interface. If the data is found, a
-- 'Just' value is returned. Otherwise, a 'Nothing' value is returned.
getData :: (TransMonad m, Typeable a) => m (Maybe a)
getData= get >>= getDataFrom

getDataFrom st= resp
  where
  resp=  do
    let list= mfData st
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
getSData = transient getData

-- | Same as `getSData`
tryState :: Typeable a => TransIO a
tryState = getSData

-- | return the default value if the state does not exist
getState :: (Default a, Typeable a) => TransIO a
getState = tryState <|> return def

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
setData x = modify $ \st -> st { mfData = M.insert (typeOf x) (unsafeCoerce x) (mfData st) }

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
  return $ maybe v (unsafeCoerce f) ma
  where
  t          = typeOf v
  alterf  _ _ x = unsafeCoerce $ f $ unsafeCoerce x

-- | Same as `modifyData`
modifyState :: (TransMonad m, Typeable a) => (Maybe a -> Maybe a) -> m ()
modifyState = modifyData

-- | Same as modifyData'
modifyState' :: (TransMonad m, Typeable a) => (a ->  a) ->  a -> m a
modifyState'= modifyData'

-- | Same as `setData`
setState :: (TransMonad m, Typeable a) => a  -> m ()
setState = setData

-- | Delete the data item of the given type from the monad state.
delData :: (TransMonad m, Typeable a) => a -> m ()
delData x = modify $ \st -> st { mfData = M.delete (typeOf x) (mfData st) }

-- | Same as `delData`
delState :: (TransMonad m, Typeable a) => a -> m ()
delState = delData


-- | get a pure state identified by his type and an index.
getIndexData :: (MonadState TranShip m, Typeable k, Typeable a, Ord k) =>
     k -> m (Maybe a)
getIndexData n= do
  clsmap <- getData `onNothing` return M.empty
  ttr ("getIndexData",typeOf clsmap)
  ttr ("len indexdata", M.size clsmap)
  return $ M.lookup n clsmap

-- | Look up a value at key @k@ in the mutable indexed map stored via 'setIndexRData'.
getIndexRData :: (TransMonad m, MonadIO m, Typeable k, Typeable a, Ord k) => k -> m (Maybe a)
getIndexRData n= do
  map <- getRData `onNothing`  return M.empty
  return $ M.lookup n map

-- | Insert or overwrite the value at key @k@ in the mutable indexed map for this type pair.
setIndexRData :: (TransMonad m, MonadIO m, Typeable k, Typeable a, Ord k) => k -> a -> m ()
setIndexRData n val=  do 
  map <- getRData `onNothing` do let m= M.empty `asTypeOf` mapka n val
                                 setRState m
                                 return m 
  setRState $ M.insert n val map
  where
  mapka :: k -> a -> M.Map k a
  mapka = error "type function should not be used"
  


-- | Apply @f@ to the value at key @i@, inserting @n@ as default if the key is absent.
withIndexRData :: (TransMonad m,MonadIO m,
      Typeable k,
      Typeable a, Ord k) =>
     k ->  (a -> a) -> a -> m ()
withIndexRData i f n= do
    mv <-  getIndexRData i
    case mv of 
      Just v -> setIndexRData i $ f v
      Nothing -> setIndexRData i n

getIndexState n= transient $ getIndexData n

  -- mref <- getIndexData n
  -- ttr ("getIndexRData",typeOf mref, isJust mref)
  -- mapM (liftIO . readIORef) mref

-- {-# SPECIALIZE getIndexData :: Int  -> StateIO (Maybe Closure) #-}


-- | set a pure state identified by his type and an index.
setIndexData :: (MonadState TranShip m, Typeable k, Typeable a, Ord k) => k -> a -> m (M.Map k a)
setIndexData n val= modifyData' (M.insert n val) (M.singleton n val)






  -- modifyData' (\map -> 
  --    case M.lookup n map of
  --     Just ref -> lazy $ do ttr "write"; writeIORef ref val; return  map
  --     Nothing -> M.insert n (lazy $ newIORef val) map) (M.singleton n $ lazy $ newIORef val)
  -- return()


newtype Ref a = Ref (IORef  (Maybe a))


-- | Initializes a new mutable reference  (similar to STRef in the state monad)
-- It is polimorphic. Each type has his own reference
-- It return the associated IORef, so it can be updated in the IO monad
newRState:: (MonadIO m,TransMonad m, Typeable a) => a -> m (IORef (Maybe a))
newRState x= do
    ttr ("CREATING REF",typeOf x)
    ref@(Ref rx) <- Ref <$> liftIO (newIORef $ Just x)
    setData  ref
    return rx

-- | mutable state reference that can be updated (similar to STRef in the state monad)
-- They are identified by his type.
-- Initialized the first time it is set, but unlike `newRState`, which ever creates a new reference, 
-- this one update it if it already exist
setRState:: (MonadIO m,TransMonad m, Typeable a) => a -> m ()
setRState x= do
    Ref ref <- getData `onNothing` (Ref <$> newRState x)
                          -- do
                          --   ref <- Ref <$> liftIO (newIORef x)
                          --   tr ("CREATING REF",typeOf x)
                          --   setData  ref
                          --   return  ref
    tr ("setRState",typeOf x)
    liftIO $ atomicModifyIORef ref $ const (Just x,())



-- | Get the value of the mutable reference created with newRState
getRData :: (MonadIO m, TransMonad m, Typeable a) => m (Maybe a)
getRData= res where
  res=do
    mref <- getData
    case mref of
     Just (Ref ref) ->  do
       mr <- liftIO (readIORef ref)
       case mr of 
        Nothing -> do delState (ofType  `asTypeOf` typ  res) ;return Nothing
        justr -> return justr
  
       
     Nothing ->  tr "getRData Nothing" >> return Nothing
  
  typ ::  m (Maybe a) -> Ref a
  typ = error "type level"

-- | return the reference value. It has not been  created, the computation stop and executes the anternative computation if any
getRState :: Typeable a => TransIO a
getRState= transient getRData

delRState :: (MonadState TranShip m, MonadIO m, Typeable a) => a -> m ()
delRState x = do
  mref <- getData  
  case mref `asTypeOf`  typ x of
    Nothing -> return()
    Just (Ref ref) ->  do delState (ofType  `asTypeOf` fromJust (typ  x)) ; liftIO $ writeIORef ref Nothing
  where
  typ ::  a -> Maybe (Ref a)
  typ= error "type level"

modifyRState :: (MonadState TranShip m, MonadIO m, Typeable a) => (a ->a)  -> a -> m ()
modifyRState f v= do
  mref <- getData  
  case mref `asTypeOf`  typ v of
    Nothing -> return()
    Just (Ref ref) -> do
      mr <- liftIO (readIORef ref)
      case mr of 
        Nothing -> do liftIO $ writeIORef ref  $ Just v
        Just x ->  liftIO $ writeIORef ref  $ Just  $ f x
  where
  typ ::  a -> Maybe (Ref a)
  typ= error "type level"
  
-- that may have been caused by the action. This allows for aternative actions to run with the original state
try :: TransIO a -> TransIO a
try mx = do
  st <- get
  mx <|> (modify (\s' ->s' { mfData = mfData st,parseContext=parseContext st}) >> empty )

-- | Executes the computation and restores all the state variables accessed by Data State, RData, 
-- RState and parse primitives.
--
-- sandboxing can be tricked by backtracking
--
--  >  r <- sandbox mx `onBack` (forward reason >> return())
--
-- will not sandbox mx if there is a backtrack in mx

-- this version at least is protected against exception backtracking.
-- 
-- The differnce with `try` is that `sandbox` ever undo the state changes, even if the computation is successful.

sandbox :: TransIO a -> TransIO a
sandbox mx = do
  st <- get

  onException $ \(SomeException e) -> do
      let mf = mfData st
          def= backStateOf $ SomeException $ ErrorCall "err"

      bs <- tryState <|> return def
      let  mf'= M.insert (typeOf def) (unsafeCoerce bs) mf

      modify $ \s ->s { mfData = mf', parseContext= parseContext st}

  mx <*** modify (\s ->s { mfData = mfData st, parseContext= parseContext st})

-- Lighther version of `sandbox` with no exception guard
sandbox' :: TransIO a -> TransIO a
sandbox' mx = do
  st <- get
  mx <*** modify (\s ->s { mfData = mfData st, parseContext= parseContext st})

-- | Sandbox the data only to other terms of a formula made of binary operators,applicatives and alternatives.
-- It is not sandboxed for the next term in the monad (the imperative sequence)
-- The list of types are the types that would NOT be sandboxed and will be leaked 
sandboxSide :: [TypeRep] -> TransIO a  -> TransIO a
sandboxSide ts mx = do
  st <- get

  mx <|> (modify (\s ->s { mfData = modif (mfData st) (mfData s), parseContext= parseContext st}) >> empty)
  where
  modif mapold m = M.union (M.fromList $ mapMaybe
        (\t ->case M.lookup t m of
                Nothing -> Nothing
                Just x  -> Just (t,x)) ts) mapold


-- | executes a computation and restores the concrete state data. the first parameter is used as withness of the type
--
-- As said in `sandbox`, sandboxing can be tricked by backtracking

sandboxData :: Typeable a => a -> TransIO b -> TransIO b
sandboxData def w= do
   d <- getData
   w  <*** if isJust d then setState (fromJust d `asTypeOf` def) else delState def



-- | sandbox some data depending on a function that takes into account the previous and new state
sandboxDataCond :: Typeable a => (Maybe a -> Maybe a -> Maybe a) -> TransIO b -> TransIO b
sandboxDataCond cond w= do
  prev <- getData
  w <***  modifyState (`cond` prev)

-- | sandbox all the state data except data of type 'a' on a function that takes into accout his previous and new state
sandboxCond :: Typeable a => (Maybe a -> Maybe a -> Maybe a) -> TransIO b -> TransIO b
sandboxCond cond w= do
  prev <- getData
  sandbox w <*** modifyState (`cond` prev)


-- --  | full sabdboxing, including the continuation
-- sandboxCont mx= do
--   st <- get
--   mx  <*** put st

-- | generates an identifier that is unique within the current program execution
genGlobalId  :: MonadIO m => m Int
genGlobalId= liftIO $ atomicModifyIORef rglobalId $ \n -> (n +1,n)

{-# NOINLINE rglobalId #-}
rglobalId= unsafePerformIO $ newIORef (0 :: Int)

-- | Generator of identifiers that are unique within the current monadic
-- sequence. It is not unique in the whole program.
genId :: TransMonad m => m Int
genId = do
  st <- get
  let n = mfSequence st
  put st { mfSequence = n + 1 }
  return n

-- | Return the current sequence counter without incrementing it (i.e. the id that was last generated).
getPrevId :: TransMonad m => m Int
getPrevId = gets mfSequence






-- | A task stream generator that produces an infinite stream of results by
-- running an IO computation in a loop, each  result may be processed in different threads (tasks)
-- depending on the thread limits stablished with `threads`.
waitEvents :: IO a -> TransIO a
waitEvents io= do
  abduce
  waitEvents1 io
  where
  waitEvents1 io= async1 io <|> waitEvents1 io

  -- block for a response and process it asynchronously one time
  async1 io= do
    r <- liftIO io
    abduce
    return r
  


-- | Run an IO computation asynchronously  carrying
-- the result of the computation in a new thread when it completes.
-- If there are no threads available, the async computation and his continuation is executed
-- in the same thread before any alternative computation.
async :: IO b -> TransIO b
async mx= do
   abduce
   liftIO  mx


-- | sync executes an asynchronous computation, until no thread in that computation is active, 
-- and return the list of results without executing any alternative computation. 
-- if the list of results is empty, the alternative computation is executed.
--
-- > ghci> keep' $ sync (abduce >> empty) <|> return "hello"
-- > ["hello"]
-- >
-- > ghci> keep' $ sync (abduce >> return "hello") <|> return "world"
-- > ["hello"]
--
-- But, withou sync:
--
-- > ghci> keep' $ (abduce >> return "hello") <|> return "world"
-- > ["world","hello"]
--
-- Network operations usually do not work well with sync at this moment, since it is difficult to determine his termination if they have 
-- use sync1 which forces termination after the first result.
sync :: TransIO a -> TransIO [a]
sync x = syncCollect  0 0  x

-- | to wait in the current thread until all the results have been collected
-- If no result, the alternative computation is executed.
syncCollect :: Int -> Int -> TransIO a -> TransIO [a]
syncCollect n t x=  do
    mv <- liftIO newEmptyMVar
    do
      -- anyThreads abduce
      r <- collect' n t x
      liftIO (putMVar mv r)
      empty

     <|> do
      r <- liftIO (takeMVar mv)
      case r of
        [] -> empty
        rs -> return  rs



-- | return the first result and kill any other thread in the argument
sync1 :: TransIO a -> TransIO a
sync1 x = do rs <- syncCollect 1 0 x; return $ head rs

-- | timeout is a synchronous operation that fails if no result has been found in a time t
timeout :: Int -> TransIO b -> TransIO b
timeout t proc = do
      r <- syncCollect 1 t proc
      case r of
        [] -> tr "TIMEOUT EMPTY" >> empty
        r : _ -> return r

-- | Another name for `sync`
-- NOTE: `async` and `await` DOES NOT WORK like in other languages.
-- Every LLM tries to use the pattern of async-await and transient does not work that way. Like in most of the asynchronous transient
-- primitives, async is blocking in the sequence (monad) but it is non-blocking in the algebraic (applicative/alternative) side. This makes
-- transient have the best of both worlds.
-- 
-- await does not wait for a single thread. it collects all the results of all the threads that have been spawned in his argument
--
-- Taking this into account, this produces sequential code. The last two lines does not type check in the first place.
-- > do
-- >    x <- async mx
-- >    y <- async my
-- >    z <- await x 
-- >    t <- await y
--
-- Since the second async does not execute until the first has completed, and the same happens with await.
-- If you want to execute mx and my in parallel in different threads, use:

-- >  r <- async mx <|> async my

-- r would be instantiated two times with each one of the results.
-- If you want to collect the results of both in a single threads use
--
-- >  await $ async mx <|> async my   
--
-- or  
--
-- > collect 0 $ async mx <|> async my     
--
-- In general you can execute and combine terms that work in different threads callbacks with algebraic formulas or any kind of binary operators/functions defined with <$> and <*>
--
-- >  (async .. +  collect...) * await...* react... `func` runAt node...
--
-- In general await and `collect` could be used when the expression is not an algebraic formula
--
-- unlike collect which is non blocking algebraically, await is blocking in
-- the sense that it stop every execution flow until his argument exhaust his threads 
--

await :: TransIO a -> TransIO [a]
await= sync

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


-- | Runs the rest of the computation in a new thread. it looks like a 'empty' computation to the current thread,
-- so alternative and applicative computations see them like empty. This allos for the multithreaded execution of expressions created with these operations
abduce :: TransIO ()
abduce= transient $  do
  c <- get
  put c{execMode=let rs= execMode c in if rs /= Remote then Parallel else rs}
  liftIO $ do
    let free= freeTh c
    if free then  void $ forkIO $ void $ runContIO () c{parent= lazy $ newIORef Nothing}
    else do
      sync <- scopeIsSynchronous c
      if sync
        then runContLoop c ()   -- 'threads 0': the task starts synchronously in the current thread, like 'branch'
        else do
          c' <- hangFrom c
          sem <- waitFork c
          void $ forkIO $ runContCleanup c' () `finally` when(isJust sem) (signalQSemB $ fromJust sem)

  return Nothing
  where

  -- the scope was created by `threads 0`: it has a negative semaphore, nobody would ever release a thread
  scopeIsSynchronous c = case maxThread c of
      Just sem -> (< 0) <$> readMVar sem
      Nothing  -> return False

  waitFork c = liftIO $ do
        case maxThread c  of
          Nothing   -> return Nothing
          Just sem  ->waitQSemB sem >> return (Just sem)

 
-- | branch semantically is like `abduce` but it does not create a new thread. it's like threads 0 abduce.
-- it executes the continuation and then executes any alternative expression
branch :: TransIO ()
branch = transient $ do
  c <- get
  liftIO $ runContLoop c ()
  return Nothing



-- | Run @proc@ in a detached thread and immediately return @()@ in the current thread.
-- The spawned thread is registered in the thread tree and managed by the normal thread-control
-- primitives. When @proc@ finishes the thread finishes.
-- __Note__: @fork@ does not compose well algebraically; prefer 'abduce' for composable branching.
fork :: TransIO () -> TransIO ()
fork proc= (abduce >> proc >> empty) <|> return ()


  

-- | Run an IO action one or more times to generate a stream of tasks. The IO
-- action returns a 'StreamData'. When it returns an 'SMore' or 'SLast' a new
-- result is returned with the result value. If there are threads available, the res of the
-- computation is executed in a new thread. If the return value is 'SMore', the
-- action is run again to generate the next result, otherwise task creation
-- stop.
--
-- Unless the maximum number of threads (set with 'threads') has been reached,
-- the task is generated in a new thread otherwise the same thread is used.
--
-- unlike normal loops, two or more parallel actions can be composed algebraically using binary operators
-- . See also `choose`
parallel :: IO (StreamData b) -> TransIO (StreamData b)
parallel io= do
  r <- async io
  case r of
    SMore x  -> async (return $ SMore x) <|> parallel io
    SLast x -> return $ SLast x
    SDone   -> empty

-- prerequisite: if the st is Alive, has listeners or has children it will not be freed. Otherwise it will be freed
-- activethis: if the register should be eliminated or not
-- final: should be marked as dead
freelogic :: Bool ->  TranShip -> IO (Maybe TranShip)
freelogic activethis  sthis= liftIO $ do
  tr ("freelogic", threadId sthis)


  mparent <-  liftIO $ readIORef $ parent sthis
  if isNothing mparent then tr "NO PARENT" >> return Nothing else do

    tr ("trying to block",threadId <$> mparent)
    chsparent <- takeMVar  (children $ fromJust mparent)
    do
      tr ("blocking",threadId <$> mparent)
      (lc,lab) <- readIORef $ labelth sthis

      -- deadthis <- isDead sthis

      let othersInParent = deleteBy (\s s' -> threadId s == threadId s') sthis chsparent
          stparent= fromJust mparent
          deadparent = isDeadAndNoListeners stparent
          isActiveParent= not $ null othersInParent && deadparent



      -- si está vivo o tiene hijos y el padre tiene mas hijos que el, no hacer nada, devolver el padre
      tr ("activethis,activeparent,childsparent",threadId sthis,threadId stparent,activethis,isActiveParent,map threadId chsparent)
      
      case(activethis, isActiveParent) of
        (True,True) -> do


          putMVar (children stparent) chsparent
          return mparent
        (False,True) -> do -- return (othersInParent,mparent)
          -- writeIORef (parent sthis) Nothing
          tr("setting children for",threadId stparent, map threadId othersInParent)
          putMVar (children stparent) othersInParent
          tr ("freelogic before return",fmap threadId mparent)
          return mparent

        (_,False) -> do

          mfirstactivest <- freelogic isActiveParent  stparent
          -- traceAllThreads
          tr ("afer recursive return freelogic",threadId $ fromJust mfirstactivest )
          -- when (not activethis || isNothing mfirstactivest) $ writeIORef (parent sthis) Nothing
          if activethis
            then do
              when (isJust mfirstactivest) $ do
                -- hang from the active thread
                let firstactivest= fromJust mfirstactivest
                modifyMVar_ (children firstactivest) $ \chsfree -> do
                            liftIO $ writeIORef (parent sthis) $ Just firstactivest -- hang from the active parent
                            return (sthis:chsfree)
              -- return ([] {-error $ show (threadId stparent,"this should be a dead register")]-},mfirstactivest)
              -- writeIORef (parent sthis) Nothing
              putMVar (children stparent) []
              return mfirstactivest
            else do
              -- return (othersInParent,mfirstactivest)
              putMVar (children stparent) othersInParent
              return mfirstactivest




-- notify that the thread is ready for kill/free
setDead st= liftIO $ changeStatusCont st $ \(_,l) -> (LF Dead [],l)
  -- -- let label= labelth st
  -- tr ("set dead:",threadId st)
  -- void $ atomicModifyIORef label $ \(LF _ ls,lab) -> (LF Dead ls,lab)
  --       -- ((case status of Alive -> Dead ; Parent -> DeadParent; _ -> status, lab),l)

-- | Mark a thread as dead in the lifecycle label while preserving its listener list.
setThreadDead :: MonadIO m => TranShip -> m ()
setThreadDead st= liftIO $ changeStatusCont st $ \(LF _ ls,l) -> (LF Dead ls,l)
--- | is the thread dead?
isDead st= lazy $ do
      (LF lc _,_) <- readIORef $ labelth st
      tr ("isDead", threadId st,lc)
      return $ lc== Dead

isDeadAndNoListeners st= lazy $ do
      (LF lc ls,_) <- readIORef $ labelth st
      return $ lc == Dead &&  null ls

noListeners st= lazy $ do
      (LF lc ls,_) <- readIORef $ labelth st
      return $   null ls

isActive st= not $ isDeadAndNoListeners st && noChilds st

hasParent st= isJust $ lazy $ do
  r <- readIORef $ parent st
  assert (case r of Nothing -> False; _ -> True) return r-- $ tr (threadId st, "NO PARENT")

-- | Return 'True' if the given state has no child threads registered.
noChilds :: TranShip -> Bool
noChilds st= null $ lazy $ readMVarChildren st

hanged= BS.pack "hanged"
-- isDeadOrHanged st= liftIO $ do
--       (LF lf _,lab) <- readIORef $ labelth st
--       -- if the parent is dead or the parent is of the same thread and not hanged (that happens when two onFinish are defiend for the same thread)
--       return $   lf== Dead  || (lazy myThreadId == threadId st && lab /= hanged)

-- freelogic th rparentState parentState label =  liftIO $ if freeTh parentState then return False else do -- if was not a free thread
--   Just actualParent <- readIORef rparentState
--   tr ("freelogic",th,"from",threadId parentState)
--   -- threadDelay 1000000
--   (can,lab) <- atomicModifyIORef label $ \l@(status,lab) ->

--     ((case status of Alive -> Dead ; Parent -> DeadParent; _ -> status, lab),l)
--   if not $ can `eq2` Listener [] 
--     then do   free th actualParent  ; return True
--     else return False
--                   -- !> ("th",th,"actualParent",threadId actualParent,can,lab)

-- -- free th env = return True  
-- free th env =  do
--       --  threadDelay 1000             -- wait for some activity in the children of the parent thread, to avoid
--                                     -- an early elimination
--        tr ("freeing", th, "from", threadId env)
--        let sibling=  children env
--       --  sb <- readMVar sibling
--        (sbs',found) <- modifyMVar sibling $ \sbs -> do
--                    tr("in parent",map threadId sbs)
--                    let (sbs', found) = drop [] th  sbs
--                    return (sbs',(sbs',found))
--        if found
--          then do

--            (typ,_) <- readIORef $ labelth env
--            tr ("checking parent:",th,typ,"in",threadId env,"childs parent", length sbs',map threadId sbs',isJust (unsafePerformIO $ readIORef $ parent env))
--            if null sbs' &&  (typ < Listener []) && isJust (unsafePerformIO $ readIORef $ parent env)
--             -- free the parent
--               then  do
--                       free (threadId env) (fromJust $ unsafePerformIO $ readIORef  $ parent env)
--               else do
--                 return False


--          else do
--           tr("free: thread has childrens can not be freed",th)
--           return False
--        where
--        drop processed th []= (processed,True)
--        drop processed th evtss@(ev:evts)
--           | th ==  threadId ev= 
--                     let chs= lazy $ readMVarChildren ev  -- que no es listener ya lo verifico en freelogic
--                     in if null chs 
--                       then (processed ++ evts, True)
--                       else (tracec ("children",map threadId chs, False )$ processed ++ evtss,False)

--           | otherwise= drop (ev:processed) th evts


-- | Attach @child@ as a child of @parentProc@, returning the previous child list.
hangState :: TranShip -> TranShip -> IO [TranShip]
hangState parentProc child =  do
  let rchs= children parentProc
  -- ths <-
  modifyMVar rchs $ \ths -> return (child:ths,ths)
  -- when (null ths) $  changeStatusCont parentProc $ \(status, label) -> (change status,label)

      --  tr ("hangthread",threadId child,"hang from",threadId parentProc)

    -- where
    -- change Dead=  DeadParent
    -- -- change DeadParent= DeadParent
    -- change status
    --   | status `eq2` Listener [] = status
    -- change _= Parent

           --  !> ("hang", threadId child, threadId parentProc,map threadId ths,unsafePerformIO $ readIORef $ labelth parentProc)

-- -- | kill  all the child threads of a context
-- killChildren :: TranShip -> IO ()
-- killChildren cont  = do
--   -- ths <- modifyMVar (children cont)  $ \ths -> return ([],ths)
--   ths <- readMVarChildren cont
--   killChilds ths
--   mapM_ killChildren ths



data TypeCallback= ConsoleCallback | EVarCallback | Other String deriving Eq
type IdCallback= String
type Message= String
data Callback= forall a.Callb a

-- | Extract the raw callback function from a 'Callback', unsafely coercing to the expected type.
getCb ::  Callback -> a -> IO b
getCb callback=
   case callback  of
     Callb cb -> unsafeCoerce cb

type CallbackData= (IdCallback, TypeCallback, Message, TranShip, Callback)

{-# NOINLINE rcallbacks#-}
-- | Global registry of active callbacks (react/reactId handlers).
rcallbacks :: MVar [CallbackData]
rcallbacks = unsafePerformIO $ newMVar []
consoleCallback (_,ConsoleCallback,_,_,_)= True
consoleCallback _ = False

-- | Return only the console-type callbacks from the global registry.
consoleCallbacks :: MonadIO m => m[CallbackData]
consoleCallbacks= liftIO $ filter consoleCallback <$> readMVar rcallbacks

-- | Register a callback in the global registry, replacing any previous entry with the same id and scheduling cleanup of the old continuation.
addInternalCallbackData :: IdCallback ->TypeCallback -> Message -> TranShip -> Callback -> IO ()
addInternalCallbackData name t message cont cb = do 
  cbs <- takeMVar rcallbacks
  (prev,rest) <- delc cbs name
  -- need cleanupThreads of the deleted continuation
  putMVar rcallbacks $ (name,t, message,cont, cb) : rest
  mapM_ (\(id,_,_,c,_) -> cleanupThreads 6 c) prev




-- {-# NOINLINE cbSection #-}
-- cbSection = lazy $ newMVar ()



-- exclusive ::  MVar () -> IO b -> IO b
-- exclusive cb mx =
--   do  -- liftIO $ bracket (takeMVar cb)  (const $ putMVar cb ()) (const mx)
--     liftIO $ takeMVar cb
--     r <- mx
--     liftIO $ tryPutMVar cb ()
--     return r

-- exclusive1 ::  MVar a -> (a -> TransIO b) -> TransIO b
-- exclusive1 mvar mx= do
--   r1 <- liftIO $ takeMVar mvar
--   mx  r1  <** liftIO (putMVar mvar r1)

-- To deactivate a callback with the given key and if the continuation is dead (no child threads, no more callbacks (listeners) attached) remove that task in the list of tasks and invoke finalizers. usually invoked when adding `reactId` callbacks with the same id or in one shoot console actions like option1 and input'
-- specially in console actions
-- delListener :: String -> IO ()
-- internalCallbaclCleanup name = do -- exclusive cbSection $ 
--   cbs <- takeMVar1 name rcallbacks
--   ([(id,_,_,c,_)],rest) <- delc cbs name
--   putMVar1 name rcallbacks rest

--   -- react uses runContLoop which does not cleanupThreads. 
--   -- It is done here at the end of the listener
--   -- Glory to God
--   cleanupThreads 4 c
  -- where
  -- takeMVar1 n mv= do
  --   tr ("takeMVar callback",n)
  --   takeMVar mv
  -- putMVar1 n mv= do
  --   tr ("putMVar callback",n)
  --   putMVar mv





-- | remove all the listeners of a state
removeListeners :: TranShip -> IO ()
removeListeners st= do -- exclusive cbSection $ do
  ls <- changeStatusContr st $ \(LF st ls, lab ) -> ((LF Dead [],lab),ls)
  -- (lf,lab) <- readIORef $ labelth st
  -- case lf of
  --   -- remove all the listeners of this task from the global list rcallbacks
  modifyMVar rcallbacks $ \all -> return $ (filter (\cb -> fst cb `notElem` ls) all,())
  --   _ -> return ()
  -- writeIORef (labelth st) (Dead,lab) -- (if null ( lazy $ readMVarChildren st) then Alive else Parent,lab)
  where
  fst (x,_, _, _,_) = x


{- | Gives the callback data that may be necessary for the removal of a handler by an external event system
For example in Javascript to remove an event listener it is necessary to know the handler funcion, to remove the callback after the first event is triggered (pseudocode):

>>>  event <- reactId "myclickevent" (Other "jscript") (foreign "element.addEventListener('click', %1)")
>>>  (_,_,_,_,myHandler) <- getCallbackData "myclickevent" 
>>>  delListener "myclickevent" 
>>>  foreign... "element.removeEventListener('click', myHandler)"
-}
getCallbackData :: MonadIO m => IdCallback -> m (Maybe CallbackData)
getCallbackData ident=do
  cbs <- liftIO $ readMVar rcallbacks
  return $ find (\c -> fst c == ident) cbs
  where
  fst :: CallbackData -> IdCallback
  fst (x,_, _, _,_) = x

-- | capture a callback handler so that the execution of the current computation continues 
-- whenever an event occurs. The effect is called "de-inversion of control"
--
-- The first parameter is a callback setter. The second parameter is a value to be
-- returned to the callback; If the callback expects no return value it just
-- can be @return ()@. The callback setter expects a function taking the
-- @eventdata@ as an argument and returning a value; this
-- function is the continuation, which is supplied by 'react'.
--
-- Callbacks from foreign code can be wrapped into such a handler and hooked
-- into the transient monad using 'react'. Every time the callback is called it
-- continues the execution inside of the current transient computation.
--
-- This allows the composition of callbacks/event handlers with any other transient code, eliminating the callback hell
-- 
--
-- >     
-- >  do
-- >     event <- react  onEvent $ return ()
-- >     ....
-- >
--
--  See: https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$NL4k640LPNwRp03Zlnek_xOhRkIJ1al5TzxfMksCclI?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu
--
-- Gloria a Dios
--
-- Note that Mailboxes, that uses react, provides a higher integration level with less complications;: See `putMailbox`

react
  :: ((eventdata ->  IO response) -> IO b)
  -> IO  response
  -> TransIO eventdata
react = reactId False "" (Other "") ""

-- | unary react.. the most common case in which the event setter is not interested in the handler response
react1 x = react x $ return()

{- |
  'reactId', like `react` gives the continuation as the function to be called when an external event happens, but also register internally the callback data  in order to clean the callback environment when a new callback is registered with the same identifier. This happens frequently in console actions, which are invoked internally by transient, but also it is necessary for freeing and finalizing resources when an external callback is removed. In that case `getCallbackData` gives the data that the external source of events may need for the removal. Alabado sea Dios.
-}
reactId :: Bool -> String -> TypeCallback -> String -> ((eventdata -> IO response) -> IO b) -> IO response -> TransIO eventdata
reactId keepIt id t msg setHandler iob= transient $ do
        modify $ \s -> s{execMode=let rs= execMode s in if rs /= Remote then Parallel else rs}

        cont <- get
        when keepIt $ changeStatusCont cont $ \(status, lab) -> ((listener id status,lab )) -- <> BS.pack ",react"))

        let cb dat = do
              tr "callback"
              cont' <- hangFrom cont -- not needed the register of the thread that called react  impersonate the external incoming thread
              --runContLoop does not execute freelogic. in the last call.
              -- delListener does it in the last call
              -- yes it is neeeded to hang the new thread too since this thread may be alive long after the
              -- react/readEVar option/input has been freed. 
              -- This thread has to have his own life: be hannged from the father and been cleaned up.
              -- example    readEVar1 ev >>= longcomputation: keep'/collect/await could kill the thread if not hanged
              runContCleanup cont' dat 
              iob
        when keepIt $ liftIO $ addInternalCallbackData id t msg cont $ Callb cb
        handlerReturn <- liftIO $ setHandler  cb
        setState $ HandlerReturn handlerReturn

        return Nothing

-- | Some handlers setters return something. For example, System.Posix.Signal.installHandler returns the previous handler. 
-- This response is keep in the state for possible use
data HandlerReturn= forall a.HandlerReturn a deriving Typeable


-- | Run the continuation stored in @cont@ with value @dat@, then call 'cleanupThreads' when it finishes.
runContCleanup :: TranShip -> p -> IO ()
runContCleanup cont dat= mask $ \unmask -> do
  th <- myThreadId

  writeIORef (rThreadId cont) th

  (_,c) <- unmask(runContIO dat cont) `catch` backExceptIO cont
  cleanupThreads 3 c


runContLoop cont dat= mask  $ \unmask ->  do
  th <- myThreadId
  writeIORef (rThreadId cont) th
  (_,c) <- unmask(runContIO dat cont)  `catch` backExceptIO cont -- catch necessary or react wont redirect exceptions for the external thread. Praise God
  tr "runContLoop afer execution before finish"
  -- traceAllThreads

  when (noChilds c) $ do
    -- needed for onFinish and collect n 
    -- exclusiveclean  $
     void $ backIO c $ Finish $ show (unsafePerformIO myThreadId,"loop thread ended")


-- | It is a single threaded for loop with de-inversion of control
--
-- >> do
-- >>   i <- for [1..10]
-- >>   liftIO $ print i
--
-- unlike normal loops, it composes with any other transient primitives or expression that includes them, including itself.
--
-- >> main= keep  $  do
-- >>  x <- for[1..10::Int] <|> (option ("n" :: String) "enter another number < 10" >> input (< 10 ) "number? >")
-- >>  liftIO $ print (x * 2)
--
-- for executes sequentially within a single thread, but when there are asynchronous call in the
-- loop that interrupt the flow or introduces new threads, like async, abduce, option, react, input etc
-- the single thread leaves the work to the new thread or callback an continues with the rest of the loop. 
-- If you need to stop the loop and wait for user input, you need to use sync. For example:
--
-- >>> i  <- for[1..10]
-- >>> sync $ option1 ("start" <> show i) ("to process " <> show i)
-- >>> process i
--
-- Each iteration will wait for the user to select the option before continuing.
-- otherwhise, without sync1, it would execute the complete loop without waiting for the user input
-- and the 10 options will be available in the console at the end of the loopl. 'process i' will be
-- called when the user types "start<i>" in the console.
-- 


-- | Equivalent to 'threads 0 . choose' but a bit faster

for :: [a] -> TransIO a
for xs= transient $ do
  c <- get
  liftIO $ mapM (runContLoop c) xs
  return Nothing


{-# NOINLINE cleanblock #-}
-- | Mutex used to serialise thread cleanup sections (currently unused but kept for future use).
cleanblock :: MVar ()
cleanblock= unsafePerformIO $ newMVar ()

-- | Read the list of child 'TranShip' states without removing them.
readMVarChildren :: TranShip -> IO [TranShip]
readMVarChildren st= do
  tr ("readMVar children",threadId st)
  readMVar $ children st

-- | Mark a state as dead, trigger 'Finish' backtracking if it has no remaining children, and call 'freelogic' to detach it from the tree.
cleanupThreads :: Show b => b -> TranShip -> IO ()
cleanupThreads n c= liftIO $ do -- exclusive cleanblock $ do

  traceAllThreads

  childs <- takeMVar $ children c
  tr ("cleanupThreads",n,threadId c,map threadId childs)
  setThreadDead c
  putMVar (children c) childs

  when (null childs && noListeners c) $ do
    void $ freelogic False  c
  -- threads with collect can have a collect listener 
  -- they are freed at collect
  when (null childs) $ do

    tr ("CALLING finish", threadId c)
    void $ backIO c $ Finish $ show (threadId c,"thread ended")

    tr ("AFTER FINISH")


  -- setThreadDead c


  -- when  (noChilds  &&  hasParent c && noListeners c) $ do
  --     tr "freelogic final"
  --     void $ freelogic (not $ isDeadAndNoListeners c)   c


-- -- | Removes a Listener is a thread that has finished but is
-- -- waiting for a event from a callback (react, input/option) or a readEVar or a getMaibox. The effect is that the
-- -- thread will be marked as dead and detached from the thread tree, so that if `collect 0`
-- --  is waiting for absence of thread activity could succeed and return a value. It returns the register of the
-- -- listener thread if it was found.
delListener  :: MonadIO m => IdCallback -> m ()
delListener id= liftIO $ do
  rcb <- takeMVar rcallbacks
  (prev,rcb') <- delc rcb id
  putMVar rcallbacks rcb'
  -- react uses runContLoop which does not cleanupThreads. 
  -- It is done here at the end of the listener
  -- Glory to God
  mapM_ (\(id,_,_,c,_) -> cleanupThreads 6 c) prev
  
-- | Partition @cbs@ into entries matching @name@ and the rest, demoting the matched entry's lifecycle.
delc :: [CallbackData] -> IdCallback -> IO ([CallbackData],[CallbackData])
delc cbs name= do
    let (prevhand,rest)= partition ((==) name . fst) cbs
    demote prevhand
    return (prevhand,rest)
    where
      demote []= return ()
      demote [(id,_,_,c,_)]= do
        atomicModifyIORef (labelth c) $ \(stat,lab) -> ((delistener id  stat Dead,lab),())
        tr ("demote",name,threadId c)

      fst (x,_, _, _,_) = x

  -- c <- get
  -- r <- liftIO $ delListener1 id c
  -- liftIO $ modifyMVar rcallbacks $ \all -> return (filter (\cb -> fst cb /= id) all,())
  -- return r
  -- where
  -- fst (x,_, _, _,_) = x

  -- delListener1 id c= do
  --   found <- changeStatusContr c $ \lb@(LF st ls, lab) ->
  --       let (found,rest) = partition (== id) ls
  --       in if not $ null found then ((LF st rest,lab),True) else ((LF st ls,lab),False)

  --   if found
  --     then return $ Just c
  --     else do
  --       p <- readIORef $ parent c
  --       if (isJust p) then delListener1 id $ fromJust p else return Nothing


-- | Collect the results of the first @n@ tasks (first parameter) or in a time t (second)
-- and terminate all the non-free threads remaining before
-- returning the results.  
--
-- @n@ = 0: collect all the results until no thread is active. 
-- @t@ == 0: no time limit.
--
-- Concerning thread activity, all react, option primitives which listen for events will maintain threads active.
-- Use option1 which finalizes the listener thread to allow collect 0 to finish.
--
-- *Parameters:*
--
--     *   @number@ :: @Int@ - The number of results to collect. If 0, collect all results until no thread is active.
--     *   @time@ :: @Int@ - The time (in microseconds) to wait for results. If 0, there is no time limit.
--     *   @proc'@ :: @TransIO a@ - The TransIO computation to execute and collect results from.
collect' :: Int -> Int -> TransIO a -> TransIO [a]
collect'  = collectSignal False

-- | Like 'collect'' but in case of signal (like termination of the process) save the results collected.
collectSignal :: Bool -> Int -> Int -> TransIO a -> TransIO [a]
collectSignal saveOnSignal  number time proc'= localBack (Finish "") $ do
  anyThreads abduce         -- necessary for alternatives/applicatives. all spawned threads will hang from this one
  do
    -- evexit <- getEVarFromMailbox
    idev <- genNewId
    let id' = show idev

    res <- liftIO $ newIORef []
    done <- liftIO $ newIORef False  --collect already executed or not
    cont <- get
    let id= "collect" <> id'
    -- tr id
    -- rstates <- liftIO $ newIORef M.empty
    changeStatusCont cont  $ \(status, lab) -> (listener id status,lab)

    -- RState handle that `endCollect` uses to terminate this collect on demand.
    -- newRState shares a single Ref (by type) across the whole collect subtree, so
    -- the collected action can flip it; nested collects shadow it, so `endCollect`
    -- always ends the innermost one. We keep the underlying IORef to read it in
    -- `check` without threading state through the backtrack handler. Glory to God
    forceEnd <- newRState (EndCollect False)

    let proc= do
            anyThreads abduce
            -- labelState $ BS.pack  id
            i <- proc'
            liftIO $ atomicModifyIORef res $ \n-> (i:n,())
            empty

        signal= do
          guard saveOnSignal
          -- to save results on exit so that collect could log the partial results. This is necessary for durable operations in the cloud monad
          liftIO $ writeIORef save True
          -- react on signal received
          Exit _ _ <- getMailbox 

          liftIO $ readIORef res  -- the thread continues doing wathever necessary after collect
          
        timer =  do
          guard (time > 0)
          anyThreads abduce
          -- labelState $ fromString "timer"
          liftIO $ threadDelay time
          liftIO $ writeIORef done True
          th <- liftIO myThreadId
          
          liftIO $ killChildren1 th cont
          
          changeStatusCont cont $ \(status, lab) -> ((delistener id status Dead,lab ))
          
          c <- get
          -- sts <- liftIO $ readIORef rstates
          put c{mfData= mfData cont} -- set the state of the initial thread. Glory to our Savior Jesus Christ

          liftIO $ readIORef res

        check  (Finish reason) = do 

          st <- get


          rs <- liftIO $ readIORef res

          tr ("collect check", threadId st,threadId cont)

          -- `endCollect` sets this flag to force termination regardless of remaining
          -- listeners/threads (e.g. event listeners that would never die by themselves).
          forced <- liftIO $ (\m -> case m of Just (EndCollect b) -> b; _ -> False) <$> readIORef forceEnd
          hasnot <- if forced then return True else hasNoAliveThreads st cont id
          tr ("in collect, no more threads left",threadId cont,hasnot)
          if not(hasnot || number > 0 && length rs >= number) then backtrack else do
          
            f <- liftIO $ atomicModifyIORef done $ \x ->(True,x) -- previous onFinish not triggered?
            
            if f then backtrack   -- already processed. let execute other finish/collect above
              else do
                tr "changeStatusCont"
                changeStatusCont cont $ \(status, lab) ->(delistener id status Dead,lab )
                -- liftIO $ killChildren1 (threadId st)  cont  --kill remaining threads

                c <- liftIO $ fromJust <$> readIORef (parent cont)

                -- localBack finish to preserve the current stack of finalizations
                localBack (Finish "") $ put c{mfData= mfData cont} -- set the state of the inital thread. Glory to our Savior Jesus Christ
                
                forward (Finish "");

                anyThreads abduce -- hang from the parent of the finish thread, inherit the state
                liftIO $ killChildren cont  --kill remaining threads
                
                labelState $ BS.pack $ "collected" <> id'

                liftIO $ freelogic False cont 

                -- read the results again to make sure all the results are read
                tr ("AFTER COLLECT",threadId c)
                liftIO $ readIORef res

    signal <|> timer <|> (proc `onBack` check)


-- | Flag shared (as an RState) between a `collect`/`collect'` and its action, set by
-- `endCollect` to force the collect to terminate.
newtype EndCollect = EndCollect Bool deriving (Typeable, Show)

-- | Terminate the innermost enclosing `collect`/`collect'` from inside its action.
--
-- It makes the collect return the results gathered so far, killing every thread and
-- listener spawned within it (the cleanup runs from the collect's parent context via
-- the normal `Finish` path, so it works even though `endCollect` is called from deep
-- inside the collect's thread hierarchy).
--
-- This is the way to stop a @collect 0 0@ whose action installs event listeners
-- (`option`, `react`, web endpoints, ...) that would otherwise keep it alive forever:
-- those listeners are dead threads with a callback annotation, not active threads, so
-- the collect never sees \"no alive threads\" by itself.
endCollect :: TransIO ()
endCollect = do
  EndCollect _ <- getRState <|> error "endCollect: not inside a collect"
  setRState $ EndCollect True
  back $ Finish "endCollect"


data Exit  = forall a. Exit TypeRep (MVar a) deriving Typeable


-- | Exit the keep and keep' thread with a result, and thus all the Transient threads (and the
-- application if there is no more code). The result should have the type expected. Otherwise an error will be produced at runtime.
exit :: Typeable a => a -> TransIO ()
exit x= do
  ex@(Exit typeofIt rexit) <- tryState <|> error " no Exit state: use keep or keep'"
  when (typeOf x /= typeofIt) $ error $ " exit of type not expected. (expected, sent)= ("<> show typeofIt <> ", "<>  show (typeOf x)
  -- warn anyone interested
  putMailbox ex
  liftIO $ threadDelay 1000000

  liftIO $  do
    putMVar  rexit  $ unsafeCoerce $ Right x
    myThreadId >>= killThread
  stop

{-# NOINLINE save #-}
save= unsafePerformIO $ newIORef False
-- | exit the keep and keep' blocks with no result. keep will return Nothing and keep' will return []
exitLeft :: (Typeable a, Show a) => a -> TransIO ()
exitLeft cause= do
  tr "exitLeft"
  liftIO $ putStrLn "exiting..."
  exit@(Exit typeofIt rexit) <- tryState <|> error " no Exit state: use keep or keep'"
  
  -- warn anyone interested
  putMailbox exit
  liftIO $ threadDelay 1000000

  liftIO $ do
    putMVar  rexit $ unsafeCoerce $ Left $ show1 cause
    --  myThreadId >>= killThread

  where
  show1 x
    |typeOf x== typeOf (ofType :: String)= unsafeCoerce x
    |otherwise= show x

-- {-# NOINLINE rreps#-}
findAliveParent st=  do
      par <- readIORef (parent st) `onNothing` return st --  error "findAliveParent: Nothing"
      (st,_) <- readIORef $ labelth par
      case st of
          LF Dead [] -> findAliveParent par
          _    -> return par



-- | If the first parameter returns 'Nothing' then the second parameter is executed, otherwise
--  the result of the first parameter is returned
onNothing :: Monad m => m (Maybe b) -> m b -> m b
onNothing iox iox'= do
       mx <- iox
       maybe iox' return mx





----------------------------------backtracking ------------------------


-- data Backtrack b= Show b =>Backtrack{backtracking :: Maybe b
--                                     ,backStack :: [TranShip] }
--                                     deriving Typeable
data Backtrack b= forall a r c. Backtrack{backtracking :: Maybe b
                                     ,backStack :: [(b ->TransIO c,c -> TransIO a)] }
                                     deriving Typeable



-- | Delete all the undo actions registered till now for the given track id.
backCut :: (Typeable b, Show b) => b -> TransIO ()
backCut reason= transient $ do
     delData $ Backtrack (Just reason)  []
     return $ Just ()

-- | 'backCut' for the default track; equivalent to @backCut ()@.
undoCut ::  TransIO ()
undoCut = backCut ()

-- -- | The 'Log' data type represents the current log data, which includes information about whether recovery is enabled, the partial log builder, and the hash closure.
-- data Log  = Log{ recover :: Bool , partLog :: Builder, rest :: [[builder]],  hashClosure :: Int} deriving (Show)

-- data LogDataElem= LE  Builder  | LX LogData deriving (Read,Show, Typeable)

-- -- | Get the current log data.
instance Read Builder where
   readsPrec n str= -- [(lazyByteString $ read str,"")]
     let [(x,r)] = readsPrec n str
     in [(byteString x,r)]

-- | unary `onBack` 
onBack1 x = return() `onBack` x

-- | Run the action in the first parameter and register the second parameter as
-- the action to be performed in case of backtracking. When 'back' initiates the backtrack, this second parameter is called
-- An `onBack` action can use `forward` to stop the backtracking process and resume to execute forward. 
{-# NOINLINE onBack #-}
onBack :: (Typeable b, Show b) => TransIO a -> ( b -> TransIO a) -> TransIO a
onBack ac bac = transient $ do
  registerBack  bac 
  runTrans ac
  where
  eventOf :: (b -> TransIO a) -> b
  eventOf = undefined

  -- | Register an undo action to be executed when backtracking. The first
  registerBack :: (Typeable b, Show b) =>  (b ->TransIO a) -> StateIO ()
  registerBack  handler  = do
    k  <- getCont
    modifyData' (\(Backtrack b bs) -> Backtrack b  $ (handler,unsafeCoerce k):unsafeCoerce bs)
               (Backtrack mwit [(  handler,unsafeCoerce k)])
    return ()
    where

    eventOf :: (b -> TransIO  a) -> b
    eventOf = undefined
    mwit= Nothing `asTypeOf` Just (eventOf handler)



-- | to register  backtracking points of the type of the first parameter within the computation in the second parameter. Out of it, these handlers do not exist and are not triggered.
localBack w = sandboxData (backStateOf w)

-- | 'back' for the default undo track; equivalent to @back ()@.
--
undo ::  TransIO a
undo= back ()

-- | 'onBack' for the default track; equivalent to @onBack ()@.
onUndo ::  TransIO a -> TransIO a -> TransIO a
onUndo x y= onBack x (\() -> y)

-- XXX Should we enforce retry of the same track which is being undone? If the
-- user specifies a different track would it make sense?
--  see https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=5ef46626e0e5673398d33afb
--
-- | For a given undo track type, stop executing more backtracking actions and
-- resume normal execution in the forward direction. Used inside an `onBack`
-- action. Note that this only change a flag in the the state so that the flow should continue forward
-- once the current handler has finished. It does not enforce immediate resumption.
-- the handler then could return a value after forward that can be used for the resumumption
--
-- forward :: (Typeable b, Show b) => b -> TransIO ()
forward reason= noTrans $ do
    Backtrack _ stack <- getData `onNothing`  return (backStateOf reason)
    setData $ Backtrack (Nothing `asTypeOf` Just reason)  stack
    -- tr "set backtrack to Nothing"



-- | A terminal placeholder for use at the end of an 'onBack' handler when no
-- 'forward', 'retry', or 'continue' is needed — i.e. backtracking should
-- continue up to the previous registered handler.
--
-- __Important:__ @backtrack@ must only appear as the *final* expression of a
-- handler branch. In the middle of an expression it does NOT initiate
-- backtracking; it merely satisfies the type checker (it is a polymorphic
-- @return@). The actual backtracking is driven by the absence of 'forward'.
--
-- > onBack1 $ \x ->
-- >     if shouldUndo x
-- >         then backtrack          -- no forward: continue up the undo stack
-- >         else forward x >> act   -- stop backtracking, resume forward
--
-- If the value returned by @backtrack@ is ever forced at runtime, it means
-- it was placed in a non-final position and its result was accidentally
-- evaluated.
backtrack :: Monad m => m a
backtrack = return $ error
    "backtrack: value was forced — backtrack must be the final expression of a handler, not used where its result is evaluated"

-- | 'forward' for the default undo track; equivalent to @forward ()@.
retry= forward ()





newtype NotHandled a= NotHandled a deriving Typeable
instance (Typeable a) => Show (NotHandled a) where show (NotHandled x)= "backtracking of type " <> show (typeOf  x) <> " not handled"
instance Typeable a => Exception (NotHandled a)

-- | Start the backtracking process for a given backtrack type. Performs all the
-- actions registered for that type in reverse order. The first handler should
-- not backtrack: it should either stop ('empty') or should execute
-- 'forward'.
--
-- Since when the backtracking has no more backtracking actions registered for
-- this type, the execution sends a 'NotHandled' exception. This notifies the
-- programmer that no final handler has been provided. This applies to all the
-- kinds of backtraking. For exceptions, 'keep' provides the final
-- backtracking actions, but you could provide your own final 'onException'
-- handler, since any handler that stops (executes 'empty') will finish the
-- backtracking.

back :: (Typeable b, Show b) => b -> TransIO a
back reason =  do
  bs@(Backtrack mreason stack) <- getData  `onNothing`  return (backStateOf  reason)
  tr ("back", reason,length stack)
  
  goBackt  bs

  where

  goBackt (Backtrack x [] ) = empty
      --  | typeOf x == typeOf (Just $ Finish "") = empty  -- finish is executed after any other backtracking, including throwt exception
      --  | otherwise = do  liftIO $ putStrLn $ NotHandled x --"backtracking of type " <>  show (typeOf x) <> " not handled\n\n" ; empty   -- Ad Maiorem Dei Gloriam

  goBackt (Backtrack _ stack@((f,k) : bs) )= do
        setData $ Backtrack (Just reason) bs
        tr ("gobackt",reason,length stack)
        -- log <- getLog  -- reset the log to the
        x <-  f  reason
        Backtrack back bs' <- getData `onNothing`  return (backStateOf  reason)
        case back of
                 Nothing    -> do
                        setData $ Backtrack back stack
                        unsafeCoerce k x -- `catcht` (\e -> liftIO(backExceptIO st e) >> empty)    causes a loop in trowt excep `onException'` 
                 justreason -> do
                        goBackt $ Backtrack justreason bs
                        empty

backStateOf :: (Show a, Typeable a) => a -> Backtrack a
backStateOf reason= Backtrack (Nothing `asTypeOf` Just reason) []

-- | length of the backtracking stack for a backtracking reason
lengthStack reason= do
  (Backtrack _ stack) <-  getData  `onNothing`  return (backStateOf  reason)
  return $ length stack

lengthStackFrom st reason= do
  (Backtrack _ stack) <-  getDataFrom st  `onNothing`  return (backStateOf  reason)
  return $ length stack

newtype BackPoint a = BackPoint (IORef [a -> TransIO()])

-- | set a BackPoint. A backpoint is a location in the code where callbacks can be installed using onBackPoint and will be called when the backtracing pass trough that point. Normally used for exceptions.  
backPoint :: (Typeable reason,Show reason) => reason -> TransIO () -- (BackPoint reason)
backPoint r= do
    point <- liftIO $ newIORef  []
    onBack1 $ \e -> do
              rs <- liftIO $ readIORef point
              mapM_ (\f -> f (e  `asTypeOf` r)) rs

    setState $ BackPoint point

-- | install a callback in the last backPoint set for this backtracking reason/event

-- onBackPoint :: TransMonad m =>  (t -> TransIO ()) -> m ()
-- onBackPoint  handler= do
--    BackPoint ref <- getData `onNothing` error "onBackPoint: no back point"
--    liftIO $ atomicModifyIORef ref $ \rs -> (handler:rs,())




------ finalization

newtype Finish= Finish String deriving Show


-- newtype FinishReason= FinishReason (Maybe SomeException) deriving (Typeable, Show)



-- | Register an action to be run when all child threads finish execution.
--
-- Can be used multiple times to register multiple actions. Actions are run in
-- reverse order of registration.
--
-- A `onFinish` handler is executed by a thread when it finishes, provided it has no
-- active children. The finalization action is executed in this case.
-- Finalizations are also called if threads are interrupted by a `ThreadKilled` exception.
--
-- `collect` forces the execution of finalizations within its scope before returning.
-- However, since these may be executed in different threads and in parallel, there is
-- no guarantee that they complete in the same order or before `collect` returns.
--
-- For example:
--
-- >  r <- collect 2 $ do
-- >      r <- liftIO $ randomRIO(1,10:: Int)
-- >      onFinish $ const $ tr ("1FINISH",r )
-- >      x <-  for [i.. i+10 ::Int]
-- >      liftIO $ threadDelay 10000
-- >      onFinish $ const $ tr ("2FINISH",x )
-- >      tr ("RS",x)
-- >      return x
-- >  tr ("RESULTS",r)
--
-- Produces a log similar to this:
--
-- > (ThreadId 166,("RS",1)
-- > ThreadId 168,("RS",2)
-- > (ThreadId 166,("2FINISH",1)
-- > ThreadId 168,("2FINISH",2)
-- > (ThreadId 170,("RS",3)
-- > (ThreadId 164,("1FINISH",5)
-- > (ThreadId 171,("RESULTS",[1,2])
-- > (ThreadId 170,("2FINISH",3)
--
-- The first onFinish is executed one time. The second is executed until collect has enough results
-- and maybe more if the killThread(s) sent by collect are not honored fast enough by the threads.
-- In any case, for each result, the second finalization is executed.
-- But the first finalization is initiated just before the results are collected.
-- if some results are discarded, like in the one of the thread 170 their finalization could execute after the result has been returned. 
--

onFinish :: (String -> TransIO ()) -> TransIO ()
onFinish mx= hookedThreads $ do
    -- id' <-  show <$> genNewId
    -- let id = "finish" <> id'

    anyThreads abduce    -- needed when mx has threads 0
    cont <- get

    done <- liftIO $ newIORef False  --finalization already executed?

    onBack1 $ \(Finish reason) ->  tmask $ do
          -- -- possible optimization
          -- guard $  not $ lazy $ readIORef done

          st <- get
          tr ("onFinishCont", threadId st, threadId cont)
          has <-  hasNoAliveThreads st cont "id"
          tr ("execute onFinish", has)

          if not has then backtrack {- to allow collect n -} else do
            f <- liftIO $ atomicModifyIORef done $ \x ->(True,x) -- previous onFinish not triggered?
            if f then backtrack else do

              mx reason
    -- Praise God: The excep. handler keep the Finish handler in the state, to be executed in case of exception.
    -- Praise God: but when the exception is a kill it free the thread and triggers the Finish handlers
    onException $ \(e :: SomeException) -> do
      case fromException e of
        -- para las excepciones sincronas, se continua ejecutando el stack de handlers
        -- pero throwt preserva el estado de ejecución, que incluye el stack de finalizaciones
        Nothing -> throwt e
        Just ThreadKilled -> do
          -- ThreadKilled es capturado y ejecuta el stack de finalizaciones
          tr ("onFinish triggered by exception", e)
          st <- get
          liftIO $ freelogic False st
          back $ Finish $ show (unsafePerformIO myThreadId,"Thread killed")
          empty



-- | A binary onFinish which will return a result when all the threads of the first operand terminates
-- the first parameter is the action and the second the action to do when all is done.
-- 
-- >>> main=   keep' $ do
-- >>>   container <-  create some mutable container to gather results
-- >>>   results   <- (SomeProcessWith container >> empty) `onFinish'` \_ -> return container
-- >>> 
-- DELETED SINCE THE USE CASE IS INCLUDED IN `collect`

-- | initiate the Finish backtracking. Normally you do not need to use this. It is initiated automatically by each thread at the end
finish :: String -> TransIO ()
finish = back . Finish

-- | trigger the execution of the argument when all the threads under the statement are stopped and waiting for events.
-- usage example https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=61be6ec15a172871a911dd61
onWaitThreads :: (String -> TransIO ()) -> TransIO ()
onWaitThreads   mx= do
    cont <- get
    modify $ \s ->s{ freeTh = False }

    done <- liftIO $ newIORef False  --finalization already executed?

    onBack1 $   \(Finish reason) -> do
                -- topState >>= showThreads
                ttr ("onWaitThreads cont",threadId cont)
                noactive <- liftIO $ noactiveth cont
                ttr ("noactive",noactive)
                -- dead <- isDead cont
                this <- get
                let isthis = threadId this == threadId cont
                    is = noactive && (isDead cont || isthis)
                tr is
                guard is
                -- previous onFinish not triggered?
                f <- liftIO $ atomicModifyIORef done $ \x ->(if x then x else not x,x)
                if f then backtrack else
                    mx reason
    -- anyThreads abduce  -- necessary for controlling threads 0



-- | recursivamente busca que ningun thread hijo esta ejecutandose
-- aunque tenga event handlers. Gloria a Dios
{-# NOINLINE noactiveth #-}
noactiveth st=
    return $ all (\st' -> null (childs st') || lazy (noactiveth st')) (childs st)
    where
    childs=  lazy . readMVar . children
    -- listeners st=  let LF _ ls= fst $ lazy $ readIORef $ labelth st
    --                in  ls
    -- label = lazy . readIORef . labelth





--  si no tiene threads o esta muerto
hasNoAliveThreads st masterst event = liftIO $ do
  traceAllThreads
  let isSelf= threadId st == threadId masterst
  -- -- the master has died so the finish/collect label should be eliminated
  -- when isSelf $ do
  --   changeStatusCont masterst $ \(status, lab) ->(delistener event status Dead,lab )
  --   tr ("changed",event,threadId masterst)
  --   traceAllThreads


  childsMaster <- liftIO $ readMVarChildren masterst

  -- tr ("threads:",threadId (head childsMaster),threadId st)

  tr ("hasNoAliveThreads entry",threadId st,threadId masterst)

  let
      LF lc ls = fst $ lazy $ readIORef $ labelth masterst
      deadMaster= lc == Dead
      -- last event listener is at the top of the list
      -- Glory to God
      hasNoEvents = null ls || head ls == event 
      hasNot =(isSelf && deadMaster || (deadMaster && null childsMaster)) && hasNoEvents

  tr ("childsMaster",length childsMaster)
  tr ("deadMaster",deadMaster)
  tr ("isSelf",isSelf)
  tr ("hasNoEvents",hasNoEvents)
  -- tr ("onlyHasThisThread",onlyHasThisThread)
  return hasNot




-- | open a resouce and close it when there is no thread in scope that can use it.
-- See https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$ZQK1tPKUWfRbEUbPufz3IHY9U2e5PglpzBYQpCS16Pg?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu 
openClose :: TransIO a -> (a -> TransIO ()) -> TransIO a
openClose open close= tmask $ do
                res <- open
                onFinish  $ const $ close res
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

-- | set an exception point. Thi is a point in the backtracking in which exception handlers can be inserted with `onExceptionPoint`.
-- It is an specialization of `backPoint` for exceptions.
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
-- exceptionPoint ::  TransIO ()
-- exceptionPoint = backPoint SomeException
  
  --  do
  --   point <- liftIO $ newIORef  []
  --   onException (\e -> do
  --             rs<-  liftIO $ readIORef point
  --             mapM_ (\r -> r e) rs)

  --   return $ BackPoint point



-- | in conjunction with `backPoint` it set a handler that will be called when backtracking pass 
-- trough the point
-- onExceptionPoint :: Exception e => (e -> TransIO()) -> TransIO ()
-- onExceptionPoint f= onBackPoint $ \e -> do
--               case fromException e of
--                 Nothing -> empty
--                 Just e' -> f e'

-- | mask exceptions while the argument is excuted
tmask proc= transient $ do
  st <-get
  (mx,st') <- liftIO $ uninterruptibleMask_ $ runTransState st proc
  -- liftIO $ print "end MASK"
  put st'
  return mx

-- | Binary version of `onException`.  Used mainly for expressing where a resource is treated when an exception happens in the first argument 
-- OR in the rest of the code below. This last should be remarked. It is the semantic of `onBack` but restricted to exceptions.
--
-- If you want to manage exceptions occuring only in the first argument and have the semantics of `catch` in transient, use `catcht`
onException' :: Exception e => TransIO a -> (e -> TransIO a) -> TransIO a
onException' mx f= onAnyException mx $ \e -> do
            -- tr  "EXCEPTION HANDLER EXEC" 
            case fromException e of
               Nothing -> do
                  -- Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)
                  -- setData $ Backtrack r $ tail stack
                  back e

               Just e' -> f e'




-- | Like 'onException'' but the handler receives a raw 'SomeException' (no type filtering).
onAnyException :: TransIO a -> (SomeException ->TransIO a) -> TransIO a
onAnyException mx exc=   ioexp   `onBack` exc
    where

    ioexp = transient $ do
       mr <- runTrans mx
       if isJust mr
        then do
          st <- get
          ioexp' $ runContIO (fromJust mr) st   `catch` backExceptIO st
        else return Nothing

    ioexp' comp= do
      (mx,st') <- liftIO  comp
      put st'
      return mx


-- | Run exception backtracking from an IO context, re-catching any further exceptions so that
-- chained handlers are always invoked. Alabado sea Dios.
backExceptIO ::  TranShip -> SomeException -> IO (Maybe a, TranShip)
backExceptIO st e =   backIO st e `catch` \e' -> backExceptIO  st e'

-- | Initiate general backtracking from pure IO, running 'back' inside the given state.
backIO :: (Typeable e, Show e) => TranShip -> e -> IO (Maybe a, TranShip)
backIO st e= runStateT ( runTrans $  back e ) st

-- -- re execute the first argument as long as the exception is produced within the argument. 
-- -- The second argument is executed before every re-execution
-- -- if the second argument executes `empty` the execution is aborted.

-- | Re-execute @mx@ each time it throws an exception of type @e@, calling @fixexc@ before each retry.
whileException :: Exception e =>  TransIO b -> (e -> TransIO())  -> TransIO b
whileException mx fixexc =  mx `catcht` \e -> do fixexc e; whileException mx fixexc

-- | For the rest of the computation, delete all the exception handlers registered till now.
cutExceptions :: TransIO ()
cutExceptions= backCut  (ofType :: SomeException)

-- | Use it inside an exception handler. it stop executing any further exception
-- handlers and resume normal (forward) execution from this point on.
continue :: TransIO ()
continue = forward (ofType :: SomeException)   -- !> "CONTINUE"


-- | catch an exception in a Transient block
--
-- The semantic is the same than `catch` but the computation and the exception handler can be multirhreaded
catcht :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
catcht mx exc= localExceptions $ onException' mx  $ \e  ->  continue >> exc e

-- old version
-- catcht' :: Exception e => TransIO b -> (e -> TransIO b) -> TransIO b
-- catcht' mx exc= do
--     rpassed <- liftIO $ newIORef  False
--     sandbox  $ do
--          r <- onException' mx (\e -> do
--                  passed <- liftIO $ readIORef rpassed
--                 --  return () !> ("CATCHT passed", passed)
--                  if not passed then continue >> exc e else do
--                     Backtrack r stack <- getData  `onNothing`  return (backStateOf  e)
--                     setData $ Backtrack r $ tail stack
--                     back e
--                     -- return () !> "AFTER BACK"
--                     empty )

--          liftIO $ writeIORef rpassed True
--          return r
--    where
--    sandbox  mx= do
--      exState <- tryState <|> return (backStateOf (ofType :: SomeException))
--      mx
--        <*** setState exState

-- | throw an exception in the Transient monad keeping the state variables. It initiates the backtraking for the exception of this type.
-- there is a difference between `throw` (from Control.Exception) and `throwt` since the latter preserves the state, while the former does not.
-- Any exception not thrown with `throwt`  does not preserve the state.
--
-- > main= keep  $ do
-- >      onException $ \(e:: SomeException) -> do
-- >                  v <- tryState <|> return "hello"
-- >                  liftIO $ print v
-- >      setState "world"
-- >      throw $ ErrorCall "asdasd"
-- 
-- the latter print "hello". If you use `throwt` instead, it prints "world"     

throwt :: Exception e => e -> TransIO a

throwt =  back . toException

-- | to register exception handlers within the computation passed in the parameter. The handlers defined inside the block do not apply outside
--
-- >  onException (e :: ...) -> ...   -- This may be triggered by exceptions anywhere below
-- >  localExceptions $ do
-- >      onException $ \(e ::IOError) -> do liftIO $ print "file not found" ; empty   -- only triggered inside localExceptions
-- >      content <- readFile file
-- >      ...
-- >  next...
localExceptions :: TransIO a -> TransIO a
localExceptions w= do
      r <- localBack (ofType :: SomeException) w
      onException $ \(SomeException _) -> return ()
      return r


------ EVARS ------


-- | An event variable that can hold values of type 'a'.
-- EVars implement a publish-subscribe pattern where writers can publish values
-- and readers can subscribe to receive updates.
newtype EVar a = EVar (IORef [(Int, a -> IO())])

newtype EVarId = EVarId Int deriving Typeable


-- | Creates a new EVar.
--
-- EVars are event variables that implement a publish-subscribe pattern. Key features:
--
-- * Writers can publish values using 'writeEVar'
-- * Readers can subscribe using 'readEVar'
-- * Non-blocking operations
-- * Composable with other TransIO code
-- * Supports multiple readers and writers
-- * Readers execute in parallel when threads are available
--
-- Example:
--
-- @
-- do
--   ev <- newEVar
--   r <- readEVar ev <|> do
--     writeEVar ev "hello"
--     writeEVar ev "world"
--     empty
--   liftIO $ putStrLn r
-- @
--
-- see https://www.schoolofhaskell.com/user/agocorona/publish-subscribe-variables-transient-effects-v
--
newEVar :: MonadIO m => m (EVar a)
newEVar = liftIO $ do
    ref <- newIORef []
    return $ EVar ref


-- | Reads a stream of events from an EVar.
--
-- Important notes:
--
-- * Only succeeds when the EVar has a value written to it
-- * Waits for events until the stream is finished
-- * No explicit loops needed as this is the default behavior
-- * Remains active until 'cleanEVar', 'lastWriteEVar' or 'delReadEvarPoint` are called
-- * If it is in a loop it will register the continuation multiple times. Loops are not ok in Transient
-- * Use 'cleanEVar' to avoid multiple registrations if needed
readEVar :: EVar a -> TransIO a
readEVar ev= do
       id <- genNewId
       readEVar' True id ev

-- | creates a new subscription point for an EVar. This subscription could be removed with delReadEVarPoint 
readEVarId id= readEVar' True id

-- | creates a transient EVar subscription for one single read
readEVar1 ev = do
       id <- genNewId
       readEVar' False id ev

-- | creates a subscription to an EVar with an identifier. The second parameter defines either if the subcription is once or permanent
readEVar' :: Bool -> Int -> EVar a -> TransIO a
readEVar' keep id ev@(EVar ref)= do
       tr ("readEVar",id)
       setState $ EVarId id
       r <- reactId keep (nameId id) EVarCallback "" (onEVarUpdated id) (return ())
       when (keep== False) $ delReadEVarPoint ev id
       return r
       where
       onEVarUpdated id callback= do
              atomicModifyIORef' ref $ \rs -> ((id,callback):rs,())


nameId id= show id <> " EVar"

-- | Removes the most recent read handler for an EVar.
-- Must be invoked after executing readEVar.
delReadEVar :: EVar a -> TransIO ()
delReadEVar evar =  do
       EVarId id <- tryState <|> error "delReadEVar should be after a readEVar in the flow"
       delReadEVarPoint evar id
       -- liftIO $ do
       --        rs <- readIORef ref
       --        tr ("evar callbacks", Prelude.map fst rs)
       --        liftIO $ atomicModifyIORef ref $ \cs -> (Prelude.filter (\c -> fst c /= id) cs,())
       --        delListener $ nameId id

-- | unsuscribe the read handler with the given identifier
delReadEVarPoint (EVar ref) id =liftIO $ do
      --  rs <- readIORef ref
      --  tr ("evar callbacks", Prelude.map fst rs)
       liftIO $ atomicModifyIORef ref $ \cs -> (Prelude.filter (\c -> fst c /= id) cs,())
       delListener $ nameId id

-- | Writes a value to an EVar.
--
-- * All registered readers will receive the new value
-- * Readers are notified in "last in-first out" order
-- * Non-blocking operation
--
-- Now, writeEVar is syncrhonous. It means that it is single threaded and the thread does not return until all the subscribed handlers have been executed unless the handlers continues in its own thread using `abduce`
writeEVar :: MonadIO m => EVar a -> a -> m ()
writeEVar (EVar ref) x = do
       conts <- liftIO $ readIORef ref
       ttr ("WRITE EVAR subscriptions",map fst conts)
       -- freThreads to detach the forked thread from the calling context tree. 
       -- it will be atached to the called context. Glory to God
      --  freeThreads $ fork $  <-- the threads should'nt be free and run in the same thread to allow synchronous execution if wanted
       liftIO $  mapM_ (\(_,f) -> f x)   conts




-- | Writes a final value to an EVar and removes all readers.
--
-- This is equivalent to calling 'writeEVar' followed by 'cleanEVar'.
lastWriteEVar :: MonadIO m => EVar a -> a -> m ()
lastWriteEVar ev x= writeEVar ev x >> cleanEVar ev

-- | Removes all reader subscriptions from an EVar.
--
-- Use this to clean up resources and prevent memory leaks
-- when you no longer need to use an EVar.
cleanEVar :: MonadIO m =>EVar a -> m ()
cleanEVar (EVar ref)= do
       ids <- liftIO $ atomicModifyIORef ref $ \evs -> ([], Prelude.map (nameId . fst) evs)
       tr ("cleanEVar", ids)

       liftIO $ mapM_ delListener ids




-- -- | a continuation var (CVar) wraps a continuation that expect a parameter of type a
-- -- this continuation is at the site where the CVar is read.
-- -- there is only one readCVar active for each CVar created with newCVar
-- -- once a readEVar is called, all previous readCVar are removed and freed.
-- -- 
{-#NOINLINE mailboxes#-}
mailboxes :: IORef (M.Map MailboxId (EVar SData))
mailboxes= unsafePerformIO $ newIORef M.empty

data MailboxId =  forall a .(Typeable a, Ord a) => MailboxId a TypeRep
instance Eq MailboxId where
   id1 == id2 =  id1 `compare` id2== EQ

instance Ord MailboxId where
   MailboxId n t `compare` MailboxId n' t'=
     case typeOf n `compare` typeOf n' of
         EQ -> case n `compare` unsafeCoerce n' of
                 EQ -> t `compare` t'
                 LT -> LT
                 GT -> GT

         other -> other

instance Show MailboxId where
    show ( MailboxId _ t) = show t

-- | Write to the mailbox
-- Mailboxes are application-wide, for all processes 
-- Internally, each mailbox is in a EVar stored in a global container, indexed by the type of the data.
-- 
-- Since putMailbox can run even in the IO Monad, it can be used to publish events directly from external callback handlers
-- with clear advantages over `react`: It can be one-to-many instead of one to one, absolute decoupling, simpler and cleaner integration:
--
-- Just insert putMailbox in the external event handler:
--
-- > onEvent (\event -> putMailbox event)   -->   onEvent putMailbox
--
-- or, more efficient. because it avoid to iterate the loockup of the EVar for each individual event:
--
-- > evar <- getEVarFromMailbox
-- > onEvent (\ev -> writeMVar evar event )
--
-- And all the `getMailBox` of the same type will receive the stream of events.
--
putMailbox :: (MonadIO m,Typeable val) => val -> m ()
putMailbox = putMailbox' (0::Int)

-- | write to a mailbox identified by an identifier besides the type
-- Internally the mailboxes use EVars from the module EVars.
putMailbox' :: (MonadIO m, Typeable key, Ord key, Typeable val) =>  key -> val -> m ()
putMailbox' idbox dat= getEVarFromMailbox' idbox >>= \ev -> writeEVar ev dat



-- | Create a new mailbox with the given 'MailboxId'.
-- Mailboxes are application-wide, for all processes.
-- Internally, the mailbox is stored in a global container,
-- indexed by the 'MailboxId' and the type of the data stored in the mailbox.
newMailbox :: MonadIO m => MailboxId -> m ()
newMailbox name= do
--   return ()  -- !> "newMailBox"
   ev <- newEVar
   liftIO $ atomicModifyIORef mailboxes $ \mv ->   (M.insert name ev mv,())



-- | Get messages from the mailbox that match the expected type.
-- This function is reactive: each new message triggers the execution of the continuation.
-- Each message invokes up all `getMailbox` computations waiting for it in FIFO sequence. if the continuation
-- invokes `abduce` the invocation thread will be freed to continue invocation in parallel.
--
-- This also implies that getMailbox remains active waiting for events until deleteMailbox or lastPutMailbox are invoked.
-- Consequently, `collect 0` and `keep'` will not complete until this happens.
getMailbox :: Typeable val => TransIO val
getMailbox =  getMailbox' (0 :: Int)

-- | read from a mailbox identified by an identifier besides the type
getMailbox' :: (Typeable key, Ord key, Typeable val) => key -> TransIO val
getMailbox' mboxid= getEVarFromMailbox >>= \ev -> readEVar ev

-- | Retrieve the 'EVar' backing the default mailbox for values of type @val@.
--
-- The mailbox is identified solely by the type @val@. This is the low-level
-- counterpart of 'getMailbox': instead of immediately reading a value it hands
-- back the underlying 'EVar' so the caller can write to it directly, which
-- avoids repeating the mailbox lookup on every event:
--
-- > evar <- getEVarFromMailbox
-- > onEvent (\ev -> writeEVar evar ev)
--
-- If no mailbox for @val@ exists yet it is created automatically.
getEVarFromMailbox :: (MonadIO m,Typeable val) => m (EVar val)
getEVarFromMailbox= getEVarFromMailbox' (0 :: Int)

-- | Like 'getEVarFromMailbox' but selects the mailbox by both a user-supplied
-- key and the type @val@, matching the keyed variants 'getMailbox'' and
-- 'putMailbox''.
--
-- The key allows multiple independent mailboxes for the same value type to
-- coexist. The lookup uses a global 'IORef' map indexed by @'MailboxId' key
-- (typeOf val)@. If no entry is found for the given @(key, type)@ pair a new
-- mailbox is created and the lookup is retried.
getEVarFromMailbox' :: (MonadIO m,Typeable key, Ord key, Typeable val) => key -> m (EVar val)
getEVarFromMailbox' mboxid= ev where
  ev = do
   let name= MailboxId mboxid $ typeOf $ typeOfEv ev
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   tr("getEVarFromMailbox",length mbs, name, isJust mev)
   case mev of
     Nothing ->newMailbox name >> getEVarFromMailbox' mboxid
     Just ev ->return $ unsafeCoerce ev
  typeOfEv ::  m(EVar a) -> a
  typeOfEv = undefined

-- | write the mailbox and all the subscriptions are deleted after the data is read
lastPutMailbox :: MonadIO m => Typeable a => a -> m ()
lastPutMailbox= lastPutMailbox' (0 :: Int)

-- | write the mailbox and all the subscriptions are deleted after the data is read
lastPutMailbox' :: (MonadIO m, Typeable key, Ord key, Typeable a) => key ->  a -> m ()
lastPutMailbox'  mboxid x= do
   let name= MailboxId mboxid $ typeOf x
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> return()
     Just ev -> do lastWriteEVar ev $ unsafeCoerce x
                   liftIO $ atomicModifyIORef mailboxes $ \bs -> (M.delete name bs,())


-- | delete all subscriptions for that mailbox expecting this kind of data
deleteMailbox :: Typeable a => a -> TransIO ()
deleteMailbox = deleteMailbox'  (0 ::Int)

-- | delete all subscriptions for that mailbox expecting this kind of data identified by an Int and the type
deleteMailbox' :: (Typeable key, Ord key, Typeable a) => key ->  a -> TransIO ()
deleteMailbox'  mboxid witness= do
   let name= MailboxId mboxid $ typeOf witness
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> return()
     Just ev -> do cleanEVar ev
                   liftIO $ atomicModifyIORef mailboxes $ \bs -> (M.delete name bs,())


-- | Unsubscribe the current thread from the mailbox for
-- the type indicated by @witness@, then remove the mailbox entry from the
-- global registry.
--
-- This is a convenience wrapper around 'deleteThisMailboxReader'' that always
-- uses @(0 :: Int)@ as the mailbox key, matching the default used by
-- 'getMailbox' / 'putMailbox'. The @mboxid@ argument is ignored.
--
-- Unlike 'deleteMailbox'' (which calls 'cleanEVar' and removes *all*
-- subscribers), this function calls 'delReadEVar' and therefore only removes
-- the subscription registered by the *current* thread. Other readers of the
-- same mailbox are not affected.
--
-- Example:
--
-- @
-- getMailbox                          -- subscribe
-- ...                                 -- process events
-- deleteThisMailboxReader () witness  -- unsubscribe only this reader
-- @
deleteThisMailboxReader :: Typeable a =>  a -> TransIO ()
deleteThisMailboxReader   witness= deleteThisMailboxReader'  (0:: Int) witness

-- | Unsubscribe the current thread from the mailbox identified by @mboxid@
-- and the type of @witness@
--
-- The mailbox is looked up by @MailboxId mboxid (typeOf witness)@. If no
-- mailbox exists for that key, the call is a no-op.
--
-- Calls 'delReadEVar' internally, which removes only the subscription
-- registered by the *most recent* 'readEVar' in the current thread — other
-- readers of the same mailbox continue to receive events.
--
-- Use this when a single consumer wants to leave a shared mailbox without
-- disrupting the rest. Use 'deleteMailbox'' instead if you want to shut down
-- the mailbox entirely and remove all subscribers.
deleteThisMailboxReader' :: (Typeable key, Ord key, Typeable a) => key ->  a -> TransIO ()
deleteThisMailboxReader'  mboxid witness= do
   let name= MailboxId mboxid $ typeOf witness
   mbs <- liftIO $ readIORef mailboxes
   let mev =  M.lookup name mbs
   case mev of
     Nothing -> return()
     Just ev -> delReadEVar ev
                   


