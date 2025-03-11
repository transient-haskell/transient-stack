 {-#Language OverloadedStrings, FlexibleContexts, GeneralizedNewtypeDeriving, RecordWildCards #-}
-----------------------------------------------------------------------------
--
-- Module      :  Transient.Logged
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
-- 
--
-- Author: Alabado sea Dios que inspira todo lo bueno que hago. Porque Él es el que obra en mi
--
-- | The 'logged' primitive is used to save the results of the subcomputations
-- of a transient computation (including all its threads) in a  buffer.  The log
-- contains purely application level state, and is therefore independent of the
-- underlying machine architecture. The saved logs can be sent across the wire
-- to another machine and the computation can then be resumed on that machine.
-- We can also save the log to gather diagnostic information.
--

-----------------------------------------------------------------------------
{-# LANGUAGE  CPP, ExistentialQuantification, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
module Transient.Move.Logged(Cloud(..),
Loggable(..), logged, checkpoint, received, param, getLog, exec,wait, emptyLog, Log(..),hashExec,genPersistId,persistDBRef,setCont,setCont',receive1,firstCont, dbClos0,setLastClosureForConnection) where

import Data.Typeable
import Data.Maybe
import Unsafe.Coerce
import Transient.Internals
import Transient.EVars
import Transient.Indeterminism(choose)
import Transient.Parse
import Transient.Loggable
import Transient.Move.Defs

import Control.Applicative
import Control.Monad.State
import System.Directory
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString                        as B(ByteString)
import qualified Data.Map as M
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC

import Data.IORef
import System.IO.Unsafe ( unsafePerformIO )
import GHC.Stack

import Data.ByteString.Builder

import Data.TCache (getDBRef)

import Control.Concurrent.MVar
import Control.Applicative
import System.Random


u= unsafePerformIO
exec=  lazyByteString $ BS.pack "e/"
wait=  lazyByteString $ BS.pack "w/"





-- | last closure/continuation executed for each remote connection in this branch of execution. Other branches could have other closures so the container should be pure. All further calls from this node to each node/connection should be directed to this corresponding closure.
setLastClosureForConnection :: Int -> Closure -> TransIO (M.Map Int Closure)
setLastClosureForConnection a b= do
  ttr  ("setLastClosureForConnection",a, b)
  setIndexData a b



-- | Log the result of the applicative computation.
--
-- In the cloud monad, all applicatives and binary operators involving distributed operations like number invocations of remote nodes  (defined through the applicative operator `<*>`) including monoids `<>`, should be prefixed by 'logApp' to log the result.
-- This ensures that further computations use the result of the operation and bypass the applicative in recovery mode when they invoke 
-- closures beyond the binary combinations, further in the monad. The reason behind this is that,
-- after the finalization of the applicative, no closures inside the applicative should be invoked in the remote node.
-- Otherwise, this could cause a deadlock in the remote nodes, as each invoked term, even in recovery mode (when the result
-- of the term has been alnready executed in a previous invocation), will wait for the execution of the other term, which could have been
-- executed in a different node. This is because the remote node need the result of the whole operation in order to progress locally the recovery until the target closure, which is beyond the applicative,
--
-- This primitive "erases" these closures. No other primitives should be used to log applicatives but this.
--
-- it should be prefixing of a chain of applicatives or binary operators, for expample:
--
-- > formula :: Cloud Int -> Cloud Int -> Cloud Int -> Cloud Int
-- > formula= logApp $ a * b + c
--
-- where a, b and c involve at least one distributed computations.



-- | stablish a checkpoint
checkpoint mclosLocal= Cloud $ do
  log <-  getLog

  PrevClos dbr <- getData `onNothing` error "teleport: please use `initNode to perform distrubuted computing"
  idSession <- localSession <$> liftIO (atomically $ readDBRef dbr `onNothing` error "logApp: no prevClos")
  -- closLocal <- BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int) -- hashClosure log
  let closLocal= if isJust mclosLocal then fromJust mclosLocal else BSS.pack $ show $ hashClosure log
  -- let closLocal= BSS.pack $ show $ hashClosure log
  lc <- setCont' (partLog log) closLocal idSession
  receive1 lc <|> return ()
  return ()
  -- Alabado sea Dios
 


newtype PersistId = PersistId Integer deriving (Read, Show, Typeable)

instance TC.Indexable PersistId where key _ = "persistId"

persistDBRef = getDBRef "persistId" :: DBRef PersistId

genPersistId :: TransIO Integer
genPersistId = liftIO $
  atomically $ do
    PersistId n <- readDBRef persistDBRef `onNothing` return (PersistId 0)
    writeDBRef persistDBRef $ PersistId $ n + 1
    return n


receive1 :: LocalClosure -> TransIO ()
receive1 lc = do
      tr "RECEIVE1'"
      -- when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc 
      -- tr ("EVAR waiting in", localSession lc, localClos lc)
      mr <- readEVar $ fromJust $ localEvar lc

      -- tr ("RECEIVED", mr)

      case mr of
        Right (SDone, _, _, _)    -> empty
        Right (SError e, _, _, _) -> error $ show ("receive:",e)
        Right (SLast log, s2, closr, conn') -> do
          -- cdata <- liftIO $ readIORef $ connData conn' -- connection may have been changed
          -- liftIO $ writeIORef (connData conn) cdata
          setData conn'
          -- tr ("RECEIVED <------- SLAST", log)
          setLog (idConn conn') log s2 closr
        Right (SMore log, s2, closr, conn') -> do
          -- cdata <- liftIO $ readIORef $ connData conn'
          -- liftIO $ writeIORef (connData conn) cdata
          setData conn'
          -- tr ("receive REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn,idConn conn)
          -- tr ("receive REMOTE NODE'", unsafePerformIO $ readIORef $ remoteNode conn',idConn conn')

          setLog (idConn conn') log s2 closr
        Left except -> do
          throwt except
          empty


setLog :: Int -> Builder -> Int -> B.ByteString -> TransIO ()
setLog idConn log sessionId closr = do
  tr ("setLog for",idConn,"Closure",sessionId, closr )
  -- void $ setLastClosureForConnection idConn (getDBRef $ kLocalClos sessionId closr) --  (Closure sessionId closr [])
  setParseString $ toLazyByteString log

  modifyData' (\l -> l {recover = True}) emptyLog
  setState $ ClosToRespond $ getDBRef $ kLocalClos sessionId closr
  -- setCont' log closr sessionId
  return ()

setCont :: Maybe B.ByteString -> Int -> TransIO (LocalClosure, Log)
setCont mclos idSession = do
  log <- getLog
  closLocal <- case mclos of
                    Just cls -> return cls
                    _ -> BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int) -- hashClosure log



  -- let dblocalclos = getDBRef $ kLocalClos idSession closLocal :: DBRef LocalClosure

  -- log <- getLog

  lc <- setCont' (partLog log) closLocal idSession
  return (lc, log)

setCont' :: Builder -> B.ByteString -> Int -> TransIO LocalClosure
setCont' logstr closName idSession=  do

  PrevClos dbprevclos <- getState <|> error "setCont: PrevClos not set, use initNode"

  let dblocalclos = getDBRef $ kLocalClos idSession closName :: DBRef LocalClosure

  -- tr "RESET LOG"
  modifyState' (\log -> log{partLog= mempty}) (error "setCont: no log")

  ev <- newEVar
  tr ("SETSTATE PREVCLOS",idSession, closName)

  cont <- get




  mr <- liftIO $ atomically $ readDBRef dblocalclos
  closure <- case mr of
    Just (locClos@LocalClosure {..}) -> do
      tr "found dblocalclos"
      if toLazyByteString logstr== mempty -- two consecutive checkpoints
        then return locClos 
        else return locClos {localEvar = Just ev, localCont = Just cont,localLog= logstr} 
    _ -> do
      mv <- liftIO $ newEmptyMVar


      return $
            LocalClosure
              { localSession = idSession,
                prevClos = dbprevclos,
                localLog =  logstr,
                localClos = closName,
                localEvar = Just ev,
                localMvar = mv,
                localCont = Just cont
              }


  tr ("SETCONT", closName, idSession,"PREVCLOS",dbprevclos,logstr)

  setState $ PrevClos  dblocalclos

  liftIO $ atomically $ writeDBRef dblocalclos closure


  return closure


dbClos0= getDBRef $ kLocalClos 0 "0"


firstCont = do
  cont <- get
  log <- getLog

  ev <- newEVar
  mv <- liftIO $ newMVar ()

  let this =
        LocalClosure
          { localSession = 0,
            prevClos = dbClos0,
            localLog = partLog log,
            localClos = BSS.pack "0", -- hashClosure log,
            localEvar = Just ev,
            localMvar = mv,
            localCont = Just cont
          }

  liftIO $ atomically $ writeDBRef dbClos0 this
  setState $ PrevClos dbClos0
  return this


-- hashExec= 10000000
-- hashWait= 100000
-- hashDone= 1000

hashDone= 10000000
hashExec= 100000
hashWait= 1000


-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--
logged :: Loggable a => TransIO a -> Cloud a
logged mx =  Cloud $ do

    r <- res <** outdent

    tr ("finish logged stmt of type",typeOf res, "with value", r)


    return r
    where

    res = do
          initialLog <- getLog
          -- tr "resetting PrevClos"

          debug <- getParseBuffer
          tr (if recover initialLog then "recovering" else "excecuting" <> " logged stmt of type",typeOf res,"parseString", debug,"PARTLOG",partLog initialLog)
          indent
          let segment= partLog initialLog


          rest <- getParseBuffer


          setData initialLog{partLog=  segment <> exec, hashClosure= hashClosure initialLog + hashExec}

          r <-(if not $ BS.null rest
                then recoverIt
                else do
                  -- tr "resetting PrevClos"
                  -- modifyState' (\(PrevClos a b _) -> PrevClos a b False) (error "logged: no prevclos") -- (PrevClos 0 "0" False) -- 11

                  mx)  <|> addWait segment

          rest <- giveParseString

          let add= serialize r <> "/" -- lazyByteString (BS.pack "/")
              recov= not $ BS.null rest
              parlog= segment <> add

          -- PrevClos s c hadTeleport <- getData `onNothing` (error $ "logged: no prevclos") -- return (PrevClos 0 "0" False)
          -- tr ("HADTELEPORT", hadTeleport)
          -- mapplic <- getData
          let hash= hashClosure initialLog{-Alabado sea Dios-} + hashDone -- hashClosure finalLog
          -- ttr ("HASHCLOSURE",hash)
          -- when (recover initialLog && not recov) $ ttr ("AQUI DEBERIA IR SETCONT2",hash)

          -- if isJust (mapplic :: Maybe IsApplicative2)
          --   then do
          --     delData IsApplicative2
          --     tr "LOGGED: ISAPPLICATIVE"
          --     modifyState' (\finalLog -> finalLog{recover=recov, partLog= add, hashClosure= hash }) emptyLog
          --   else

          do
              modifyState'  (\finalLog ->  -- problemsol 10
                        -- if  hadTeleport -- Gracias mi Dios y señor -- && not recov
                        --   then finalLog{recover=recov, partLog= mempty, hashClosure= hash }
                          -- else 
                            finalLog{recover=recov, partLog= parlog, hashClosure= hash }
                        )
                        emptyLog



          return r


    -- when   p1 <|> p2, to avoid the re-execution of p1 at the
    -- recovery when p1 is asynchronous or  empty
    addWait segment= do
      -- tr ("ADDWAIT",segment)
      -- outdent

      tr ("finish logged stmt of type",typeOf res, "with empty")
      modifyData' (\log -> log{partLog=segment <> wait, hashClosure=hashClosure log + hashWait})
                  emptyLog
      empty




    recoverIt = do

        s <- giveParseString

        let (h,t)=  BS.splitAt 2 s
        case  (BS.unpack h,t) of
          ("e/",r) -> do
            -- tr "EXEC"
            setParseString r
            mx

          ("w/",r) -> do
            tr "WAIT"
            setParseString r
            modify $ \s -> s{execMode= if execMode s /= Remote then Parallel else Remote}
                          -- in recovery, execmode can not be parallel(NO; see below)
            empty

          _ -> value s

    value s = r
      where
      typeOfr :: TransIO a -> a
      typeOfr _= undefined

      r= (do
        -- tr "VALUE"
        -- set serial for deserialization, restore execution mode
        x <- do mod <- gets execMode;modify $ \s -> s{execMode=Serial}; r <- deserialize; modify $ \s -> s{execMode= mod};return r
        tr ("value parsed",x)
        psr <- giveParseString
        tr ("parsestring after deserialize",psr)

        when (not $ BS.null psr) $ void (tChar '/')

        return x) <|> errparse

      errparse :: TransIO a
      errparse = do
        -- psr <- getParseBuffer;
        error  ("error parsing <" <> BS.unpack s <> ">  to " <> show (typeOf $ typeOfr r) <> "\n")





-------- parsing the log for API's

received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       Transient.Internals.try (void (tChar '/'))<|> return () --maybe there is a '/' to drop
       --(Transient.Internals.try $ tTakeWhile (/= '/') >>= liftIO . print >> empty) <|> return ()
       if      t == typeRep (Proxy :: Proxy String)     then unsafeCoerce . BS.unpack <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BS.ByteString) then unsafeCoerce <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BSS.ByteString)  then unsafeCoerce . BS.toStrict <$> tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


