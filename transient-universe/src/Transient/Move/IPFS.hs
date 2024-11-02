{-  USING IPFS to store all the Transient data: closure information and other persistent TCache data

NEEDS a local KUBO daemon  https://github.com/ipfs/kubo/releases
https://docs.ipfs.tech/reference/kubo/rpc

curl -X POST "http://127.0.0.1:5001/api/v0/key/gen?arg=testname"
curl -X POST "http://127.0.0.1:5001/api/v0/cat?arg=QmcP6mZWbgQSegoJZW7m65jKxCZAZRThqP1doCWVDHxHpi"


-}

{-#LANGUAGE OverloadedStrings, FlexibleContexts, ScopedTypeVariables,DeriveDataTypeable,FlexibleInstances,UndecidableInstances #-}
module Transient.Move.IPFS where -- (setIPFS) where
import Data.TCache as TC
import Data.TCache.DefaultPersistence as TC
import Transient.Internals
import Transient.Indeterminism
import Transient.Move.Defs
import Transient.Move.Internals
import  qualified Transient.Move.Services  as Services
import Transient.Loggable
import Transient.Parse
import qualified Data.Map as M
import Transient.Console
import Control.Monad.IO.Class
import Data.IORef
import Data.Maybe
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Aeson 
--import Data.Aeson.KeyMap(lookup)
import qualified Data.Vector as V
import Control.Applicative
import Control.Monad
import Data.Typeable
import Data.List (isPrefixOf)
import Control.Concurrent(threadDelay)
import System.IO.Unsafe
import Control.Exception hiding (onException)
{-
https://docs.ipfs.tech/reference/kubo/rpc

curl -X POST "http://127.0.0.1:5001/api/v0/key/gen?arg=testname"
curl -X POST "http://127.0.0.1:5001/api/v0/cat?arg=QmcP6mZWbgQSegoJZW7m65jKxCZAZRThqP1doCWVDHxHpi"


-}


ipfsHeader req body= Service $ M.fromList $ [("service","IPFS"), ("type","HTTP")
        ,("nodehost","localhost")
        ,("nodeport","5001")
        ,("HTTPstr",req <> " HTTP/1.1\r\nHost: $hostnode" <> 
            -- (if take 4 req/="POST" then "" else 
            "\r\nContent-Length: "<> 
            show (Prelude.length body) <>"\r\n\r\n" <> body)]

ipfsCat = ipfsHeader "POST /api/v0/cat?arg=$1" ""


ipfsAddmUpload body = Service $ M.fromList 
        [("service","IPFS"),("type","HTTP")
        ,("nodehost","localhost")
        ,("nodeport","5001")
        ,("HTTPstr","POST /api/v0/add HTTP/1.1\r\n" <>
              "Host: localhost\r\n" <>
              "Content-Type: multipart/form-data; boundary=---------------------------735323031399963166993862150\r\n"<>
              "Content-Length: "<> show (Prelude.length body1)<>"\r\n\r\n" <> body1)]
   where
   body1= body <> fileend

   tcachedir=  "-----------------------------735323031399963166993862150\r\n"<>
      "Content-Disposition: form-data; name=\"file\"; filename=\"/tcachedata\"\r\n" <>
      "Content-Type: application/x-directory\r\n\r\n" 

   fileend=  "-----------------------------735323031399963166993862150--"



addFile name content=
  "-----------------------------735323031399963166993862150\r\n"<>
  "Content-Disposition: form-data; name=\""<>name<>"\"; filename=\"tcachedata%2F"<>name<>"\"\r\n"<>
  "Content-Type: text/plain\r\n\r\n"<>content <> "\r\n"
      
ipnsList    = ipfsHeader "POST /api/v0/key/list" ""
ipnsKeyGen  = ipfsHeader "POST /api/v0/key/gen?arg=$1" ""
-- ipnsResolve = ipfsHeader "POST /api/v0/name/resolve?arg=$1" ""
ipnsPublish = ipfsHeader "POST /api/v0/name/publish?arg=$1&key=$2" ""


callService s p= unCloud $ Services.callService s p

jsonFilter field (Raw reg)= withParseString reg $ filt field reg
  where
  filt field reg=
    if not $ '.' `BS.elem` field 
      then do
        locateKey field reg
        tTakeWhile' (/='\"')
        tTakeWhile (/='\"')
      else do
        locateKey field reg
        let rest = BS.takeWhile (/= '.') field
        filt (BS.tail rest) reg
  
  locateKey field reg= do
        tTakeWhile' (/= '\"')
        tDropUntilToken field  
        tDropUntilToken "\""
        tTakeWhile' (/= ':')
        


lockuptabledef= "dappflowlockup"


-- | get either the IPNS id of the index table or its key or Nothing from the command line
-- The index table identifies all the closures serialized that will be used by the program
--
-- > program -p start/localhost/8080/ipns/{IPNS}
--
-- also to use a local KEY associated to an implicit IPNS addr:
--
-- > program -p start/localhost/8000/keyipfs/{KEY}
--
-- By defaault, the progran look for the data by inspecting the local KEY  "dappflowlockup"

chooseIPNSkey =  
  getIPNSid 
  <|>  getKey 

    
  where
  getKey= do
    mkey :: String <- sync (do option1 ("keyipfs" :: String) "give the IPNS key for the program data"
                               input (const True) "enter key name: ")  <|> return ""
    let key= if null mkey then lockuptabledef else  key
    liftIO $ writeIORef ripnsid key
    return key

  getIPNSid= do
    option ("ipns?" :: String) "IPFS: show the ipns id of the data"
    key <- liftIO $ readIORef ripnsid
    liftIO $ putStrLn key
    empty
    
  
ripnsid= unsafePerformIO $ newIORef "No saved data yet"
      
-- | Set IPFS persistence for TCache registers and for all the closure data. it needs a local IPFS daemon.
-- It uses the interface https://docs.ipfs.tech/reference/kubo/rpc/#getting-started
-- It gets either the IPNS id of the index table or its key or Nothing from the command line
-- The index table identifies all the closures serialized that will be used by the program. It identifies "the database" 
--
-- > program -p start/localhost/8080/ipns/{IPNS}
--
-- also to use a local KEY associated to an implicit IPNS addr:
--
-- > program -p start/localhost/8000/keyipfs/{KEY}
--
-- By default, the progran look for the data by inspecting the local KEY  "dappflowlockup" 
setIPFS = local $ localExceptionHandlers $ do
      onException $ \(ConnectionError _ _) -> do
            liftIO $ putStrLn $ "Is the ipfs daemon running?"
            empty
        

 
      (ipnsid, table,key) <- do
        -- look for a ipns id in the command line
        ipns :: String <- sync (do option1 ("ipns" :: String) "give the IPNS identifier for the program data"  
                                   input (const True) "enter ipns id: ") <|> return ""
        if not $ null ipns then  do
          liftIO $ putStrLn $ "using state at /ipns/" <> ipns
          Raw tablestr <- callService ipfsCat $ "/ipns/" <>  ipns

          let table= read $ BS.unpack tablestr
          liftIO $ atomically $ flushDBRef persistDBRef
          liftIO $ writeIORef ripnsid lockuptabledef

          return (ipns,table,lockuptabledef)
        else do
          -- if there is no id, alternatively it look for a IPNS key in the command line
          key <- chooseIPNSkey

          Raw r <- callService ipnsList ()  `catcht` \(ErrorCall e) -> do
                                      liftIO $ print ("ERROR IPNSLIST",e)
                                      return (Raw mempty)
                                      --  Just(HTTPHeaders (_,code,_) _ :: HTTPHeaders) <-  getData 
                                      --  if code == "404" then return $ Raw mempty else throwt e

          liftIO $ atomically $ flushDBRef persistDBRef -- the connection uses this DBRef before IPFS storage is being set
          let m = if BS.null r then Just M.empty else (decode r :: Maybe (M.Map String [Maybe (M.Map String String)]))
          guard (isJust m) <|> error "ipnsList error, is the kubo IPFS daemon running?"
          let map = fromJust m
              mlist =  M.lookup "Keys" map
              mlist'= if isJust mlist then fromJust mlist else [] :: [Maybe (M.Map String String)]
              ks = filter (\mm -> case mm of Nothing -> False; Just m ->  M.lookup "Name" m ==  Just key) $  mlist'
              
          tr ("KS",ks)

          liftIO $ putStrLn "retrieving index state from IPFS..."

          if null ks
              then do
                  tr "ipnsKeyGen"
                  ipnsid <- callService ipnsKeyGen (key :: String) >>= jsonFilter "Id" 
          
                  tr ipnsid
                  return (BS.unpack ipnsid,M.empty,lockuptabledef)
              else do
                  let ipnsid= fromJust $  M.lookup "Id" $ fromJust $ head ks 
                  Raw tablestr <- callService ipfsCat ("/ipns/" <>  ipnsid) `catcht` \(ErrorCall e) -> do
                                    return $ Raw "fromList[]"
                  tr ("TABLESTR",tablestr)
                  let table= read  $ BS.unpack tablestr
                  return (ipnsid,table,key)
      tr("IPNSID, TABLE",ipnsid,table)
     
      rindex <- liftIO $ newIORef  table
      let iPFSPersist= TC.Persist {
          readByKey = \k -> do
            r <- keepCollect 1 0  $ do
              let mipns = M.lookup k table
              if isNothing mipns 
                then return Nothing
                else do
                  Raw r <- callService ipfsCat (BS.unpack $ fromJust mipns) 
                  return $ Just r
            return $ head r,
          -- called by Data.TCache.*syncCache primitives
          write = \k content -> do
                    tr "write"
                    keepCollect 1 0 $ do 
                             ipfsid <- callService (ipfsAddmUpload(addFile k $ BS.unpack content)) () >>= jsonFilter "Hash"
                             liftIO $ atomicModifyIORef rindex $ \m -> (M.insert k ipfsid m,())
                    return(),

          delete = \k -> error $ show ("deleting",k)
          }
      liftIO $ TC.setDefaultPersist iPFSPersist
      tr "after setDefaultPersist "
      fork $ saveIndex key ipnsid rindex
  where
  saveIndex key ipnsid rindex= do
    react'  onSave  -- activated after each cycle of save to disk of the modified registers in the cache, to save the index data
    tr("SAVEINDEX")
    -- the data has been saved already, only the index remain to be saved
    index  <- liftIO $ readIORef rindex
    ipfsid <- callService (ipfsAddmUpload (addFile (key :: String) $ show index)) () >>=  jsonFilter "Hash" 
    tr "IPNS PUBLISH"
    liftIO $ putStrLn "publishing a new program state"
    r <- callService ipnsPublish ("/ipfs/" <> BS.unpack ipfsid :: String , key :: String) >>= jsonFilter "Name"
    liftIO $ putStrLn $ "Program state saved at: /ipns/" <> BS.unpack  r
    return()
    where
    -- callback that set up an action when writing of registers finish
    onSave :: (() -> IO ()) -> IO ()
    onSave fx= TC.setConditions (return ())  (fx ())
    
    react' mx= react mx (return())


-- main2= keep' $ do
--     Raw r <- callService (ipfsAddmUpload $ addFile "hellx" "hello content") () -- <> addFile "word" "word content\r\n" ) ()
--     -- Raw r <- callService (ipfsAddmUpload $ addFile "wordx" "wordx content\r\n") ()
--     liftIO $ print ("r",r)


-- data Dat= Dat Int deriving (Read,Show,Typeable)
-- instance Indexable Dat where key _= "DAT"

-- -- main= keep' $ chooseIPFS


-- main= keep' $  do
--     setIPFS

--     id <- genPersistId
--     liftIO $ print ("RESULT",id)
--     liftIO $ syncCache

