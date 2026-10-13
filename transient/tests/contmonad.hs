{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, UndecidableInstances #-}
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Trans hiding (lift)
import GHC.Conc
import System.IO.Unsafe
import Data.IORef
import Control.Concurrent.MVar
import qualified Data.Map as M 
import Data.Typeable
import qualified Data.ByteString.Char8 as BS
import Control.Monad.State  hiding(lift)
import Data.Monoid
-- import GHC.Prim 

x !> y= x -- trace (show y) x


type SData= ()

data LifeCycle = Alive | Parent | Listener | Dead
  deriving (Eq, Show)

-- | EventF describes the context of a TransientIO computation:
data EventF = EventF
  { mfData      :: M.Map TypeRep SData
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
  } deriving Typeable

newtype Transient r m a = Transient { runContT :: (Maybe a -> m  (Maybe r)) -> m  (Maybe r) }

type StateIO = StateT EventF IO

type TransIO   a= Transient a StateIO a

instance  (MonadIO m) => Monad (Transient r m) where
    return  = pure
    m >>= k  = Transient $ \c -> runContT m (\a -> runContT (mayb k a) c)
     where
     mayb k (Just x)= k x
     mayb _ Nothing =  empty

instance (MonadIO m,MonadState s m) => MonadState  s (Transient r m) where
    get= lift get
    put= lift . put



-- instance MonadTrans (Transient r) where
--     lift m = Transient ((Just <$> m) >>=)

lift m = Transient ((Just <$> m) >>=)

instance (MonadIO m) => MonadIO (Transient r m) where
    liftIO = lift . liftIO

callCC :: ((a -> Transient r m b) -> Transient r m a) -> Transient r m a
callCC f = Transient $ \ c -> runContT (f (\ x -> Transient $ \ _ ->  c $ Just x)) c

instance (Monad m) => Functor (Transient r m) where
    fmap f m = Transient $ \c -> runContT m $ \ mx->
             case mx of
                 Just x ->  c $ Just $ f x
                 Nothing ->  return Nothing
                 
instance (Monoid a,MonadIO m) => Monoid (Transient r m a) where
    mappend x y = mappend <$> x <*> y
    mempty      = return mempty 

instance (Monoid a,MonadIO m) => Semigroup (Transient r m a) where
    (<>)=  mappend


instance (MonadIO m) => Applicative (Transient r m) where
    pure a  = Transient ($ Just a)
    -- f <*> v = Transient $ \ k -> runContT f $ \ g -> runContT v (k . g)
    f <*> v =   do
          r1 <- liftIO $ newIORef Nothing
          r2 <- liftIO $ newIORef Nothing
          fparallel r1 r2 <|> vparallel r1 r2
      where

      fparallel r1 r2= Transient $ \k  -> do
          runContT f $ \mg -> do
                liftIO $ writeIORef r1 mg !> "f write r1"
                case mg of
                    Nothing -> return Nothing 
                    Just g   -> do 
                          mt <- liftIO $ readIORef r2  !> "f read r2"
                          case mt of
                            Nothing -> return Nothing 
                            Just t -> k . Just $ g t

      vparallel  r1 r2=  Transient $ \k  ->  do 
            runContT v $ \mt ->  do
                 liftIO $ writeIORef r2 mt !> "v write r2"
                 mg <- liftIO $ readIORef r1 !> "v read r2"
                 case mg of 
                    Nothing -> return Nothing
                    Just g -> do
                                   case mt of
                                      Nothing -> return Nothing
                                      Just t -> k . Just $ g t 


instance (MonadIO m) => Alternative (Transient r m) where
    empty=  Transient ( $  Nothing)
    f <|> g= Transient $ \ k ->do
              mr <- runContT f k 
              case mr of 
                  Nothing  -> runContT g k
                  justr -> return justr




emptyEventF :: ThreadId -> IORef (LifeCycle, BS.ByteString) -> MVar [EventF] -> EventF
emptyEventF th label childs =
  EventF { mfData     = mempty
         , mfSequence = 0
         , threadId   = th
         , freeTh     = False
         , parent     = Nothing
         , children   = childs
         , maxThread  = Nothing
         , labelth    = label }

-- | Run a transient computation with a default initial state
runTransient :: TransIO a -> IO (Maybe a, EventF)
-- runTransient :: Transient r (StateT EventF IO) r -> IO (Maybe r, EventF)
runTransient t = do
    th     <- myThreadId
    label  <- newIORef $ (Alive, BS.pack "top")
    childs <- newMVar []
    runTransState (emptyEventF th label childs) t

runTransState :: EventF -> TransIO a ->  IO (Maybe a, EventF)
runTransState st t= runStateT  (runTrans t) st

runTrans :: TransIO a -> StateIO (Maybe a)
runTrans t= ((flip runContT) (return . id)) t
 

inputLoop= getLine >>= \l -> atomically (writeTVar mvline l)  >> inputLoop

no = unsafePerformIO newEmptyMVar

mvline= unsafePerformIO $  newTVarIO ""

option :: String -> TransIO String
--option :: [Char] -> Transient [Char] (StateT t IO) [Char]
option s = waitEvents . atomically $ do
              x <- readTVar mvline
              if  x== s then  writeTVar mvline "" >> return s else retry               

-- callCC :: ((a -> Transient r StateIO b) -> Transient r m a) -> Transient r m a

async :: IO a -> TransIO a 
async io= callCC $ \ret -> do
            st <- lift get
            liftIO $ forkIO $ runTransState st ( liftIO io >>= ret ) >> return () 
            empty 

waitEvents :: IO a -> TransIO a
--waitEvents :: IO a -> Transient a (StateT t IO) a
waitEvents io= callCC $ \ret -> do
  st <- get 
  loop ret st 
  where
  loop ret st=  do
            liftIO $ forkIO $ ((flip runStateT) st $  liftIO io >>= \x -> runTrans (ret x) >> runTrans (loop ret st) >> return Nothing) >> return () 
            empty



main2 = do
   forkIO inputLoop
   (r,_) <- runTransient $ do
        r <-   (option "hello"    >> return "hi")  <>  (option " world")
        liftIO $ print (r ::String) 
        empty
   print r
   takeMVar no


main= runTransient $ do r <- async (return "hola")  <|>  return "que tal"; liftIO $ print r; return "jhi"
   
   
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

instance AdditionalOperators (Transient r StateIO)  where

  -- (**>) :: TransIO a -> TransIO b -> TransIO b
  (**>) f g =
      Transient $ \k ->  runContT f $ \x -> runContT g  k 

  -- (<***) :: TransIO a -> TransIO b -> TransIO a
  (<***) f g =
      Transient $ \k -> runContT f $ \mx -> do
             case mx of
                 Nothing -> return Nothing
                 _ -> runContT g (const $ return Nothing) >>  k mx

  -- (<**) :: TransIO a -> TransIO b -> TransIO a
  (<**) f g =
      Transient $ \k ->  runContT f $ \mx -> do
             case mx of
                 Nothing -> return Nothing
                 _ -> runContT g (const $ return Nothing) >>  k mx

infixr 1 <***, <**, **>  
