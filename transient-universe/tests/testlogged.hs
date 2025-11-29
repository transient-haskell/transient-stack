{-# LANGUAGE FlexibleInstances, ScopedTypeVariables, RecordWildCards,OverlappingInstances, UndecidableInstances #-}

module Main where

import           Control.Monad
import           Control.Monad.IO.Class
import           System.Environment
import           System.IO
import           Transient.Internals
import           Transient.Move.Logged 
import           Transient.EVars
import           Transient.Parse
import           Transient.Console
import           Transient.Indeterminism
import           Transient.EVars
import           Transient.Move.Internals
import           Transient.Move.Defs
import           Transient.Move.Utils
import           Transient.Move.Job
import           Control.Applicative
import           System.Info
import           Control.Concurrent
import           Data.IORef
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BC
import Data.ByteString.Builder

import qualified Data.TCache.DefaultPersistence as TC
import qualified Data.TCache.Defs  as TC
import Data.TCache  hiding (onNothing)
import Data.TCache.IndexQuery

import System.IO.Unsafe
import Data.Typeable
import Control.Exception hiding (onException)

import qualified Data.Map as M
import System.Directory
import Control.Monad.State
import Data.Maybe
import System.Time
import Control.Concurrent
import Data.Aeson
import Unsafe.Coerce
import Data.String
import GHC.Generics
import Data.Default
import Data.Char
import GHC.Stack
import Data.TCache hiding (onNothing)






data HELLO=HELLO deriving (Read,Show,Typeable)
data WORLD=WORLD deriving (Read,Show,Typeable)

instance (Read a,Show a,Typeable a)=> Loggable a

setc =  do
    (lc,_) <-  setCont Nothing 0
    liftIO $ putStr  "0 ">> print (localClos lc)

setcn n=  do
    (lc,_) <- setCont (Just $ BC.pack n)  0
    liftIO $ putStr  "0 ">> print (localClos lc)


restoren= do
        option ("res" :: String) "restore1" 
        clos <- input (const True) "closure"

        noTrans $ restoreClosure 0 clos 
restore1= do
        restoren
        empty
save= do
    option "sav" "save execution state"
    liftIO  syncCache
    empty

-- firstCont = do
--   cont <- get
--   log <- getLog
--   let rthis = getDBRef "0-0" -- TC.key this
--   tr ("assign", log)
--   when (not $ recover log) $ do
--     ev <- newEVar
--     mv <- liftIO $ newMVar ()

--     let this =
--           LocalClosure
--             { localSession = 0,
--               prevClos = rthis,
--               localLog = partLog log, 
--               localClos = BC.pack"0", -- hashClosure log,
--               localEvar = Just ev,
--               localMvar = mv,
--               localCont = Just cont
--             }

  --   -- n <- getMyNode
  --   -- let url= str "http://" <> str (nodeHost n) <> str "/" <> intt (nodePort n) <>"/0/0/0/0/"

  --   -- liftIO $ print url
  --   liftIO $ atomically $ writeDBRef rthis this
  -- setState $ PrevClos rthis




main= keep $ unCloud $ do
    logged firstCont
    logged restoren <|> logged save <|>  go
  where
  go= do
    logged $ option "go" "go"
    logged $ setcn "one"

    r <-loggedc $  do
          loggedc $ do
                  loggedc $ do
                    logged $ setcn "two"
                    return HELLO
          loggedc $ return WORLD
    logged $ return "hello"
    logged $ setcn "four"

    logged $ tr r


-- -- | Restore the continuation recursively from the most recent alive closure.
-- --  Retrieves the log and continuation from a closure identified by the connection ID (`idConn`) and the closure ID (`clos`).
-- -- If the closure with the given ID is not found in the database, an error is raised.
-- getClosureLog :: Int -> String -> StateIO (Builder, Builder, EventF)
-- getClosureLog idConn "0" = do
--   tr ("getClosureLog", idConn, 0)

--   clos <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos 0 $ BC.pack "0") `onNothing` error "closure 0 not found in DB"
--   let cont = fromMaybe (error "please run firstCont before") $ localCont clos
--   return (localLog clos, mempty, cont)

-- getClosureLog idConn clos = do
--   tr ("getClosureLog", idConn, clos)
--   closReg <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos idConn $ BC.pack clos) `onNothing` error ("closure not found in DB:" <> show (idConn,clos))
--   prev <- liftIO $ atomically $ readDBRef (prevClos closReg) `onNothing` error "prevClos not found"
--   case localCont closReg of
--     Nothing -> do
--       (baselog, prevLog, cont) <- getClosureLog (localSession prev) (BC.unpack $ localClos prev)
--       let locallogclos = localLog closReg
--       tr ("PREVLOG",  prevLog)
--       tr ("LOCALLOG",  locallogclos)
--       tr ("SUM",  prevLog <> locallogclos)
--       return (baselog, prevLog <> locallogclos, cont)
--     Just cont -> do
--       tr ("JUST",idConn,clos)
--       return (localLog closReg, mempty, cont)

-- -- | cold restore  of the closure from the log from data stored in permanent storage, and run from that point on
-- -- | Restores a closure from the log stored in permanent storage, and runs the continuation from that point on.
-- -- The closure is identified by the connection ID (`idConn`) and the closure ID (`clos`).
-- -- The function retrieves the log and continuation from the closure, and sets up the execution context to continue from that point.
-- -- If the closure with the given ID is not found in the database, an error is raised.
-- restoreClosure :: Int -> String -> StateIO ()
-- restoreClosure _ "0" = return ()
-- restoreClosure idConn clos  = do
--   tr ("restoreclosure", idConn, clos)
--   (_, log, cont) <- getClosureLog idConn clos
--   -- cont is the nearest continuation above which is loaded and running
--   -- log contains what is necessary to recover the continuation that we want to restore
--   let mf = mfData cont
--   let logbase = fromMaybe emptyLog $ unsafeCoerce $ M.lookup (typeOf emptyLog) mf
--       lb = partLog logbase
--   -- let log'=  LD $ lb <> log

--   -- tr ("TOTAL LOG", log')

--   let mf' = M.insert (typeOf emptyLog) (unsafeCoerce $ logbase {recover = True {-,fromCont=False -}}) mf

--   let parses = toLazyByteString  log
--   let cont' = cont {parseContext = (parseContext cont) {buffer = parses}, mfData = mf'}
--   tr ("SET parseString",  log)
--   modify (\s -> s{execMode=Remote})
--   void $ liftIO $  runStateT (runCont cont') cont' `catch` exceptBack cont'


-- data LocalClosure = LocalClosure
--   { localSession :: Int,
--     prevClos :: DBRef LocalClosure,
--     localLog :: Builder,
--     localClos :: IdClosure,
--     localMvar :: MVar (),
--     localEvar :: Maybe (EVar (Either CloudException (StreamData Builder, SessionId, IdClosure, Connection))),
--     localCont :: Maybe EventF
--   }

-- instance TC.Indexable LocalClosure where
--   key LocalClosure {..} = kLocalClos localSession localClos

-- kLocalClos idCon clos = BC.unpack clos <> "-" <> show idCon

-- instance TC.Serializable LocalClosure where
--   serialize LocalClosure {..} = TC.serialize (localSession, prevClos, localLog, localClos)
--   deserialize str =
--     let (localSession, prevClos, localLog,  localClos) = TC.deserialize str
--         block = unsafePerformIO $ newMVar ()
--      in LocalClosure localSession prevClos localLog  localClos block Nothing Nothing

-- newtype PrevClos = PrevClos {unPrevClos :: DBRef LocalClosure}


-- setCont mclos idSession = do
--   mprev <- getData

--   closLocal <- case mclos of Just cls -> return cls; _ -> BC.pack <$> show <$> hashClosure <$> getLog
--   let dblocalclos = getDBRef $ kLocalClos idSession closLocal :: DBRef LocalClosure

--   setState $ PrevClos  dblocalclos

--   cont <- get

--   log <- getLog
--   setState log{partLog= mempty}

--   ev <- newEVar

--   mr <- liftIO $ atomically $ readDBRef dblocalclos
--   pair <- case mr of
--     Just (locClos@LocalClosure {..}) -> do
--       tr "found dblocalclos"
--       return locClos {localEvar = Just ev, localCont = Just cont} -- localCont=Just cont} -- (localClos,localMVar,ev,cont)
--     _ -> do
--       mv <- liftIO $ newEmptyMVar
--       mprevClosData <- if isJust mprev then liftIO $ atomically $ readDBRef $ fromJust $ fmap unPrevClos mprev 
--                                        else return Nothing


--       let lc =
--             LocalClosure
--               { localSession = idSession,
--                 prevClos = fromMaybe dblocalclos $ fmap unPrevClos mprev,
--                 localLog = partLog log,
--                 localClos = closLocal,
--                 localEvar = Just ev,
--                 localMvar = mv,
--                 localCont = Just cont 
--               }


--       return lc

--   liftIO $ atomically $ writeDBRef dblocalclos pair


--   return (pair, log)
