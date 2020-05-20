#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB=~/workspace/transient-stack/ && runghc   -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1 ${2} ${3}

-- mkdir -p ./static && ghcjs --make   -i../transient/src -i../transient-universe/src -i../transient-universe-tls/src  -i../axiom/src   $1 -o static/out && runghc   -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}
-- 
{---------------------------------- lenguaje interpretado ----------------

para que?
   une interactivo,log y ...
   shell en la nube
   

programacion interactiva
  salida de cada paso a un pipe, visible  con opcion o enganchable a un siguiente  paso

entrada de datos de ejecución y entrada de programación: 
    una por teclado
    la otra por pipe

lenguaje interpretado: orden pipe, shell (), "runAt node", except en input
(shell "ls ") |>  (at ip:port (shell "grep mydir"))

paranteses: (proc ....) means "proc" is the only process that consume input commands until ')'

proc kafka * |port> myprocess 
   myprocess read from a process whose manifest is called "kafka", any instance of it. 
   the port is defined in the manifest

proc "mywebserv" <port|  process
    "process" access the port of the process with "mywebserv" manifest
   
shell "ls /etc" ||  shell "ls /var" 

   parallel execution. output of both to the standard output
   
(proc1 |port>,proc2)  
      pair the output of both processes separated by comma.    absence of output means standard output

proc |> onexcept "exc" proc2 |> proc3
     exception handling  

 proc  |port> out out1
 proc2  !> out out2
 |out1> proc3
 
proc1 |> proc2= do
    capture standard output of proc1
    proc1 
  <|>
    capture standard input of proc2 connect to previous capture
    proc2 r

(proc  |event1> mailbox1)    |> proc2 |>  (proc3 <| mailbox1)

proc forward event1 to mailbox1, pipe stdio to proc2
how to codify these event1... endpoints? mailboxes?
componentes generalmente son servidores/clientes de web services
   el shell solo engancha puertos, de la compatibilidad de los interfaces no puede tratar
   definir cloud mailboxes

el shell solo engancha puertos, de la compatibilidad de los interfaces no puede tratar
  se pueden usar mailboxes para desacoplar webservices?
      en vez de hacer llamadas directas entre servicios, usar mailboxes
      serian parte del manifest:
      un programa

at node proc= do
  runAt node  proc
 <|>
   in <- get standard input
   runAt node $ writeInput de proc in
       


variables o streams
var name value= do


como se interpreta la linea?

option "s" "s"  >> liftIO (print "s pressed")  <|>  option "t" "t"  >>  liftIO (print "t pressed)

  (op1 |> op2)
  infix no permite interacción si no se ejecuta linealmente
      s |> t
  f y g tiene el mismo standard input y output a no ser que sean comandos proc, shell o runAt
     se trata igual. t si lee de input, es del output de s.
  
  ejecución lineal:
  ejecutar op1
  redireccionar standard input 
  ejecutar t



(shell "ls ") |>  (at ip:port (shell "grep mydir"))
al contrario que runAt at establece un proceso permanente en el nodo remoto, que recibe entradas
son procesos externos que no pueden iniciarse cada vez que hay una entrada.


-}
{-#LANGUAGE ScopedTypeVariables #-}
import Transient.Internals
import Transient.Indeterminism
import Transient.Move.Utils
import Transient.Move
import Control.Applicative
import System.Process
import Control.Exception hiding (onException)
import qualified Data.Map as M 
import System.IO
import Control.Monad.IO.Class 
import Data.IORef
import System.IO.Unsafe
import GHC.IO.Handle
import Control.Monad
import Control.Exception hiding(onException)

rops= unsafePerformIO $ newIORef (0 :: Int)


main= keep $ initNode $ inputNodes  <|> do
  (node,npipe) <- cmd  <|> optionAt
  localIO $ putStrLn "executing"
  n <- localIO $ atomicModifyIORef rops $ \ops -> (ops+1,ops)
  view node npipe <|> bind

rbind= unsafePerformIO $ newIORef False
bind= do
  local $ option "|" "bind"
  localIO $ putStrLn $ "The last output will forwarded to the next command"
  localIO $ writeIORef  rbind True
  

view node npipe= do
  n <- localIO $ readIORef rops
  local $ option ("v" ++ show n) "to see the output"
  tr "AFTER VIEW"
  line <- runAt node $ local $ do
    ps <-  liftIO $ readIORef rPipes 
    let (rr,_) = (reverse ps) !! npipe
    tr ("NPIPE",npipe)
    l <- waitEventsEnd $ hGetLine rr 
    return l
    
  localIO $ putStrLn line
    
waitEventsEnd mx= waitEvents mx `onException'` \(SomeException _) -> empty

-- send commands and pipe the last output to the remote node, return pipe?
optionAt= do
  local $ option  "at" "execute in another node"
  node <- local $ do
    host <- input' (Just "localhost") (const True) "hostname of the node. (Must be reachable, default:localhost)? "
    port <- input  (const True) "port of the node? "
    liftIO $ createNode host port
  do
    localIO $ writeIORef lineprocessmode False

    inp <- local $ inputf False "input1" (show node)  Nothing (const True)  
    (runAt node  $ local $ do 
            liftIO $ processLine inp
            empty) <|> 
        (do
            redir <- localIO $ readIORef rbind
            guard (redir==True)
            -- falta pasar la salida del nodo fuente
            (pipr,pipw) <- lazy $ liftIO $ readIORef rPipes >>= return . head
            wormhole node $ do
              teleport
              (rr,ww) <- lazy $ liftIO createPipe
              localIO $ atomicModifyIORef  rPipes $ \ps -> ((rr,ww):ps,())
              teleport

              localIO $ print "AQUI AQUI AQUI"
              line <- local $ waitEventsEnd $  hGetLine pipr
              atRemote $ localIO $ hPutStrLn ww line
              empty)  <|> 
        (do
            npipe<- runAt node $ localIO $ readIORef routs
            len <- localIO $ readIORef rPipes >>= return . length 
            return (node,npipe-1))

cmd= do
  expr <- local $ inputf False "input" ">"  Nothing (const True) 
  executeStreamIt expr

rconsole= unsafePerformIO $ newIORef $ error "console node not defined"


withCon mx= do
  local  popConsoleHandlers
  r <- mx
  local pushConsoleHandlers
  return r
  where
  popConsoleHandlers= do
    cbs <- liftIO $ atomicModifyIORef rcb $ \cbs -> ([],cbs) -- remove local node options
    setState cbs

  atConsole mx= do
     console <-  onAll $ liftIO  $ readIORef rconsole
     runAt console mx

  pushConsoleHandlers= do
    cbs <- getState
    liftIO $ writeIORef rcb cbs -- restore local node options


routs= unsafePerformIO $ newIORef (0 :: Int)
rPipes= unsafePerformIO $ newIORef ([] :: [(Handle,Handle)])

redirectOutput = local $ do
   
   (rr,ww) <- liftIO createPipe 
   stdout_dup <- liftIO $ hDuplicate stdout
   liftIO $ hDuplicateTo ww stdout  
   --finish stdout_dup  
   liftIO $ atomicModifyIORef routs $ \n -> (n+1,n+1)
   liftIO $ atomicModifyIORef rPipes $ \ps -> ((rr,ww):ps,())
  --  where
  --  read rr = waitEvents $  hGetLine rr 
   
  --  finish stdout_dup = onException $ \(SomeException _) -> do

  --    liftIO $ hDuplicateTo stdout_dup stdout
  --    liftIO $ putStrLn "restored control"
  --    empty
{-
ejecuta procesos aislados

bin los engancha automaticamente

-}
executeStreamIt expr =  local $ do
  redir <- liftIO $ readIORef rbind
  (_, Just o, Just err,h) 
     <- 
      if redir 
        then do

          liftIO $ print  "executestreamitredir"
          (rr,ww) <- liftIO $ readIORef rPipes >>= return . head
          liftIO $ createProcess $ (shell expr){std_in=UseHandle rr,std_err=CreatePipe,std_out=CreatePipe}

        else
          liftIO $ createProcess $ (shell expr){std_in=Inherit,std_err=CreatePipe,std_out=CreatePipe}


  liftIO $ atomicModifyIORef rPipes $ \pp -> ((o,error "input not defined"): pp,())
  n <- liftIO $ atomicModifyIORef routs $ \n -> (n+1,n)
  nod <- getMyNode
  return (nod,n)
      


{-
      abduce

      
      -- onException $ \(SomeException e) ->  do 
      --        liftIO $ do
      --            print ("watch:",e) 
      --            cleanupProcess r 
      --            atomicModifyIORef rinput $ \map -> (M.delete header map,())
      --        empty 
      
     
      --liftIO $ atomicModifyIORef rinput $ \map -> (M.insert header (input1 r) map,())
      
      line <- watch (output r) <|> watch (err r) <|> watchExitError r 
      
      --putMailbox' box line   
      
      --hlog <- liftIO $ openFile logfile AppendMode 
      --liftIO $ hPutStrLn  hlog line
      --liftIO $ hClose hlog    
      return line
      
      where

      input1 r= inp where (Just inp,_,_,_)= r
      output r= out where (_,Just out,_,_)= r
      err r= err where    (_,_,Just err,_)= r
      handle r= h where   (_,_,_,h)= r

      watch :: Handle -> TransIO String
      watch h = do
        abduce
        mline  <-  threads 0 $ (parallel $  (SMore <$> hGetLine' h) `catch` \(SomeException e) -> return SDone)
        case mline of
           SDone -> empty
           SError e -> do liftIO $ print ("watch:",e); empty
           SMore line ->  return line
           
        where

        hGetLine' h= do
          buff <- newIORef []
          getMore buff
          
          where

          getMore buff= do
            b <- hWaitForInput h 10
            if not b
                then do
                   r <-readIORef buff
                   if null r then getMore buff else return r
                else do
                      c <- hGetChar h
                      if c == '\n' then readIORef buff else do
                        modifyIORef buff $ \str -> str ++ [c]
                        getMore buff

      watchExitError r= do    -- make it similar to watch
        abduce
        liftIO $ waitForProcess $ handle r
        errors <- liftIO $  hGetContents (err r)
        return errors


rinput= unsafePerformIO $ newIORef M.empty 
-}