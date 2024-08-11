-----------------------------------------------------------------------------
--
-- Module      :  Transient.Move.Utils
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- |
--
-----------------------------------------------------------------------------
{-# LANGUAGE CPP, ScopedTypeVariables #-}
module Transient.Move.Utils (initNode,initNodeDef, initNodeServ, addService, inputNodes, simpleWebApp, initWebApp
, onServer, onBrowser, atServer, atBrowser, runTestNodes, showURL)
 where

--import Transient.Base
import Transient.Internals
import Transient.Logged
import Transient.Console
import Transient.Move.Internals
import Transient.Move.Web
import Control.Applicative
import Control.Monad.State
import Data.IORef
import System.Environment
import System.IO.Error
import Data.Typeable
import Data.List((\\), isPrefixOf)
import qualified Data.ByteString.Lazy.Char8 as BS
import Control.Exception hiding(onException)
import System.IO.Unsafe
import Data.TCache(syncCache,clearSyncCacheProc,defaultCheck)

rretry= unsafePerformIO $ newIORef False

-- | ask in the console for the port number and initializes a node in the port specified
-- It needs the application to be initialized with `keep` to get input from the user.
-- the port can be entered in the command line with "<program> -p  start/<PORT>"
--
-- A node is also a web server that send to the browser the program if it has been
-- compiled to JavaScript with ghcjs. `initNode` also initializes the web nodes.
--
-- This sequence compiles to JScript and executes the program with a node in the port 8080
--
-- > ghc program.hs
-- > ghcjs program.hs -o static/out
-- > ./program -p start/myhost/8080
--
-- `initNode`, when the application has been loaded and executed in the browser, will perform a `wormhole` to his server node.
--  So the application run within this wormhole.
--
--  Since the code is executed both in server node and browser node, to avoid confusion and in order
-- to execute in a single logical thread, use `onServer` for code that you need to execute only in the server
-- node, and `onBrowser` for code that you need in the browser, although server code could call the browser
-- and vice-versa.
--
-- To invoke from browser to server and vice-versa, use `atRemote`.
--
-- To translate the code from the browser to the server node, use `teleport`.
--
initNode :: Loggable a => Cloud a -> TransIO a
initNode app= do
   node <- getNodeParams 
   rport <- liftIO $ newIORef $ nodePort node
   node' <- return node `onException'` ( \(e :: IOException) -> do
             if (ioeGetErrorString e ==  "resource busy") 
              then do
                 liftIO $ putStr "Port busy: " >> print (nodePort node)
                 retry <- liftIO $ readIORef rretry
                 if retry then do liftIO $ print "retrying with next port" ;continue else empty
                 port <- liftIO $ atomicModifyIORef rport $ \p -> (p+1,p+1)
                 return node{nodePort= port}
                 
              else return node )
   return () -- !> ("NODE", node')
   initWebApp node' app



getNodeParams  :: TransIO Node
getNodeParams  =
      if isBrowserInstance then  liftIO createWebNode else
#ifdef ghcjs_HOST_OS
              empty
#else
        do
         --  oneThread $ 
          option "start" "re/start node"

          host <- input' (Just "localhost") (const True) "hostname of this node. (Must be reachable, default:localhost)? "
          retry <-input' (Just "n") (== "retry") "if you want to retry with higher port numbers when the port is busy, write 'retry': "
          when (retry == "retry") $ liftIO $ writeIORef rretry True
          port <- input  (const True) "port to listen? "
          liftIO $ createNode host port
         <|> getCookie
         <|> syncmodes
      
    where
    syncmodes= commit <|> confsave
    confsave= do
       option "savepol" "configure synchronization policy with permanent storage"
       maxnum <- input' (Just 1000) (const True) "max number of cached objects? (default 1000)"
       time <- input' (Just 10) (const True) "time between check for objects to be saved? (default 10 sec)"
       liftIO $ clearSyncCacheProc time defaultCheck maxnum
       liftIO $ delConsoleAction "savepol"
       liftIO $ do
          putStr "syncing each "
          print time
          putStr "seconds."
          putStr " Max objects: "
          print maxnum
          putStrLn ""

       empty
    commit= do
      option "save" "commit now the current execution state to permanent storage"
      abduce
      liftIO $ syncCache
      liftIO $ print "saved the execution state"
      empty
      
    getCookie= do
      if isBrowserInstance then return() else do
         option "cookie" "set the cookie"
         c <- input (const True) "cookie: "
         liftIO $ writeIORef rcookie  c
      empty
#endif
    
initNodeDef :: Loggable a => String -> Int -> Cloud a -> TransIO a
initNodeDef host port app= do
   node <- def <|> getNodeParams 
   initWebApp node app
   where
   def= do
        args <- liftIO  getArgs
        if null args then liftIO $ createNode host port else empty

-- Add a service
addService :: Service -> Cloud ()
addService s= local $ do
   node <- getMyNode
   let node'= node{nodeServices= s:nodeServices node}
   setMyNode node'
   nodes <- getNodes
   setNodes $ node' : tail nodes

   
   


initNodeServ :: Loggable a => Service -> String -> Int -> Cloud a -> TransIO a
initNodeServ services host port app= do
   node <- def <|> getNodeParams
   let node'= node{nodeServices=[services]}
   initWebApp node' $  app
   where
   def= do
        args <- liftIO  getArgs
        if null args then liftIO $ createNode host port else empty

-- | ask for nodes to be added to the list of known nodes. it also ask to connect to the node to get
-- his list of known nodes. It returns empty.
-- to input a node, enter "add" then the host and the port, the service description (if any) and "y" or "n"
-- to either connect to that node and synchronize their lists of nodes or not.
--
-- A typical sequence of initiation of an application that includes `initNode` and `inputNodes` is:
--
-- > program -p start/host/8000/add/host2/8001/n/add/host3/8005/y
--
-- "start/host/8000" is read by `initNode`. The rest is initiated by `inputNodes` in this case two nodes are added.
-- the first of the two is not connected to synchronize their list of nodes. The second does.
inputNodes :: Cloud empty
inputNodes= onServer $ do 
--   local $ abduce >> labelState (BS.pack "inputNodes")
  listNodes <|> addNew
  
  where
  addNew= do
          local $ do
                 option "add"  "add a new node"
                 return ()
          host      <- local $ do
                          r <- input (const True) "Hostname of the node (none): "
                          if r ==  "" then stop else return r

          port      <- local $ input (const True) "port? "
          serv      <- local $ nodeServices <$> getMyNode 
          services  <- local $ input' (Just serv) (const True) ("services? ("++ show serv ++ ") ")

          connectit <- local $ input (\x -> x=="y" || x== "n") "connect to the node to interchange node lists? (n) "
            

          nnode <- localIO $ createNodeServ host port  services
          if connectit== "y" then connect'  nnode
                             else  local $ do
                               liftIO $ putStr "Added node: ">> print nnode
                               addNodes [nnode]
          empty

  listNodes=  do
          local $ option "nodes" "list nodes"
          local $ do
             nodes <- getNodes
             liftIO $ putStrLn "list of nodes known in this node:"
             liftIO $ mapM  (\(i,n) -> do putStr (show i); putChar('\t'); print n) $ zip [0..] nodes
          empty
     


       
-- | executes the application in the server and the Web browser.
-- the browser must point to http://hostname:port where port is the first parameter.
-- It creates a wormhole to the server.
-- The code of the program after `simpleWebApp` run in the browser unless `teleport` translates the execution to the server.
-- To run something in the server and get the result back to the browser, use  `atRemote`
-- This last also works in the other side; If the application was teleported to the server, `atRemote` will
-- execute his parameter in the browser.
--
-- It is necesary to compile the application with ghcjs:
--
-- > ghcjs program.js
-- > ghcjs program.hs -o static/out
--
-- > ./program
--
--
simpleWebApp :: (Typeable a, Loggable a) => Integer -> Cloud a -> IO ()
simpleWebApp port app = do
   node <- createNode "localhost" $ fromIntegral port
   keep $ initWebApp node app
   return ()




-- | use this instead of simpleWebApp when you have to do some initializations in the server prior to the
-- initialization of the web server
initWebApp :: (Loggable a) => Node -> Cloud a -> TransIO a
initWebApp node app=  do
    conn <- defConnection
    liftIO $ writeIORef (myNode conn)  node
    setNodes  [node]
    serverNode <- getWebServerNode  :: TransIO Node
    mynode     <- if isBrowserInstance
                    then  do
                        addNodes [serverNode]
                        return node
                    else return serverNode
    
    runCloud $ do
        listen mynode <|> listenContsFromNodes <|> return()
      --   onAll $ topState >>= showThreads

        serverNode <- onAll getWebServerNode
        
        onAll abduce  -- to allow onFinish and onWaitthreads to fire
        wormhole' serverNode $ do 

#ifndef ghcjs_HOST_OS
                 local  optionEndpoints  
#else
                 local empty
#endif   
                   <|> app -- ;(minput "" "end" :: Cloud())
      where
      listenContsFromNodes= onAll $ do c <- getState; firstCont ; receive c Nothing 0
         
-- | run N nodes (N ports to listen) in the same program. For testing purposes.
-- It add them to the list of known nodes, so it is possible to perform `clustered` operations with them.
runTestNodes ports= do
    nodes <- onAll $ mapM (\p -> liftIO $ createNode "localhost" p) ports
    onAll $ addNodes nodes
    foldl (<|>) empty (map listen1 nodes) <|> return()
    where 
    listen1 n= do
      listen n
      onAll $ do
        ns <- getNodes
        addNodes $ n: (ns \\[n])
        conn <- getState <|> error "runTestNodes error"
        liftIO $ writeIORef (myNode conn)  n

