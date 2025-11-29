#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/projects/transient-stack" && mkdir -p static && ghcjs -DDEBUG  --make   -i${LIB}/transient/src -i${LIB}/transient-universe/src  -i${LIB}/axiom/src   $1 -o static/out &&  ./todo  $1  $2 $3

{-# LANGUAGE CPP, DeriveDataTypeable, OverloadedStrings, ScopedTypeVariables #-}

#ifndef ghcjs_HOST_OS
import Transient.Base
import Transient.Move.Utils
import Control.Applicative

main= keep $ initNode $ do
    
    return()

#else
import Transient.Internals

import Transient.Logged
import GHCJS.HPlay.View as V
import GHCJS.HPlay.Cell
import Data.Dynamic

import JavaScript.Web.Storage
import qualified Data.ByteString as B
import qualified Data.JSString as JS
import Control.Applicative
import Prelude hiding (div,span,id,all)
import Data.Typeable
import Control.Monad(when)
import Control.Monad.IO.Class
import qualified Data.IntMap as M
import Data.Monoid
import Control.Monad(guard)
import Data.Maybe


data Status= Completed | Active deriving (Show,Eq,Read)

type Tasks = M.IntMap  (String,Status)

-- instance Serialize Status where
--   toJSON= Str . toJSString . show
--   parseJSON (Str jss)=  return . read  $ fromJSStr jss

data PresentationMode= Mode String deriving Typeable

all= ""
active= "active"
completed= "completed"

str s= s :: String

main= do
  addHeader $ link ! atr "rel" "stylesheet" ! atr "type" "text/css" ! href "base.css"
  
  runBody $ do


      
            -- rawHtml(p ! id "here" $ str "PEPE") 
      

        -- render $ at "#here" Insert $ Widget $ do
        --     render $ Widget $ do norender $ tr "click"; norender $ p (str "click")  `pass` OnClick
            -- r <- do  
                        (rawHtml $ p $ str "00000 ")  !> "0000"
                        -- rawHtml $ p ! id "pepe" $ noHtml
                        -- render $ at "#pepe" Insert $ Widget $ 
                        x <- inputString Nothing `fire` OnChange <|>  inputString Nothing `fire` OnChange
                          --r2 <- render $ inputString Nothing `fire` OnChange
                          
                          -- render(rawHtml $ p $ str "11111 ")  !> "1111"
                          -- render(rawHtml $ p r)   !> "2222"
                          -- return r)  
                            --           <|>  
                            -- ( 
                            --     do
                            --       inputString Nothing `fire` OnChange  )
                                  -- rawHtml (p  x)
                                  -- return x)
                                -- render $ 
                                -- return x)
                        rawHtml $ p x    
            -- alert r
            -- rawHtml $ p $ ("llegó",r)
            -- render $ Widget $ do norender $ tr "world"; norender $ rawHtml $  p $ str "world"
            -- rawHtml $ p ("llegó"++ show r)

    --     -- tr "TRACE"

    --     rawHtml $ p $ str "world")

      -- (p (str "hello") `pass` OnClick) `wcallback` const(rawHtml $ p $ str "world")
      -- counter 0
      
{-
counter (n :: Int)= p n `pass` OnClick `wcallback` const (counter $ n+1)


todo ::  Widget ()
todo = do
      section ! id "todoapp" $ do
        nelem "header" ! id "header"
        section ! id "main" $ do
          ul ! id "todo-list"  $ noHtml

        footer ! id "footer"  $ do
          span ! id "todo-count" $ noHtml
          ul ! id "filters" $ noHtml
          span ! id "clear-holder" $ noHtml

      footer ! id "info" $ do
        p $ str $ "Double-click to edit a todo"
        p $ do
           toElem $ str "Created by "
           a ! href "http://twitter.com/agocorona" $ str "Alberto G. Corona"
           p $ do
              toElem  $ str "Part of "
              a ! href "http://todomvc.com" $ str "TodoMVC"

   ++> header                       --             ++> add HTML to a widget
    **> toggleAll
    **> filters all
    **> itemsLeft
    **> showClearCompleted           --             **> is the *> applicative operator

 where

 itemsLeft= at "#todo-count" Insert $ do
    n <- getTasks >>= return . M.size . M.filter ((==) Active . snd) . fst
    rawHtml $ do 
              strong (show n)
              toElem $ str $ case n of
                1 -> " item left"
                _ -> " items left"

 showClearCompleted= at "#clear-holder" Insert $ do
    (tasks,_) <- getTasks
    let n =  M.size . M.filter ((==) Completed . snd)   $ tasks
    when (n >0) $ do
        (button ! id "clear-completed" $ str "Clear completed") `pass` OnClick
        setTasks $ M.filter ((==) Active . snd) tasks
        displayFiltered

 filters op =at "#filters" Insert $ do
      alert "filters"
      op' <- links op `fire` OnClick <|> return op
      alert "filters2"

      setState $ Mode op'
      
      displayFiltered
    
    where
    links op=
        li ! clas op all       <<< wlink all        (toElem $ str "All")     <|>
        li ! clas op active    <<< wlink active     (toElem $ str "Active")  <|>
        li ! clas op completed <<< wlink completed  (toElem $ str "Completed")

    clas current op= atr "class" $ if current== op then "selected" else "unsel"

 header = at "#header" Insert $ h1 (str "todos") ++>  newTodo

 toggleAll = at "#main" Prepend $ do
    t <- getCheckBoxes $ setCheckBox False "toggle" `fire` OnClick ! atr "class"  "toggle-all"
    let newst=  case t of
            ([] :: [String]) ->  Active
            _  ->  Completed
    (tasks,_) <- Widget getTasks ::  Widget (Tasks, Int)
    filtered  <- getFiltered tasks
    let filtered' = M.map (\(t,_) -> (t,newst)) filtered
        tasks'    = M.union filtered' tasks
    setTasks tasks'
    displayFiltered
    itemsLeft

 displayFiltered = do
    (tasks,_) <- Widget getTasks
    filtered <- getFiltered tasks
    at "#todo-list" Insert $ foldr (<|>) mempty $ reverse
                                      [display  i | i <- M.keys filtered]
   **> return ()

 getFiltered :: M.IntMap (String, Status)-> Widget (M.IntMap (String, Status))
 getFiltered tasks= do
   Mode todisplay <- Widget getState <|> return (Mode all)
   let ts= M.filter (fil todisplay)  tasks 
   return ts

   where
   fil  f (t,st)
     | f==all=   True
     | f==active = case st of
                         Active -> True
                         _      -> False
     | otherwise = case st of
                         Completed -> True
                         _         -> False


 getEventData'= do
     EventData evname d <-getEventData
     let evd = fromDynamic d
     guard $ isJust evd
     return (evname,fromJust evd) 
     
 newTodo= do
      let entry= boxCell "new-todo"
      task <- mk entry Nothing `fire` OnKeyUp
                ! atr "placeholder" "What needs to be done?"
                ! atr "autofocus" ""
      (evname, evdata) <- getEventData'
      when( evdata == Key 13) $ do
         entry .= ""
         idtask <- addTask task Active
         Mode m <-  getState <|> return (Mode all)
         when (m /= completed) $ at "#todo-list" Prepend $ display idtask
         itemsLeft

 display idtask = li <<< do

   (li <<< ( toggleActive  **> destroy))  `wcallback` const (delTask idtask)

   return ()

   where
   toggleActive = do
        Just (task ,st) <- getTask idtask
        let checked= case st of Completed -> True; Active -> False
        let checkit= case st of Completed -> ["check"]; _ -> []
        ch <- (getCheckBoxes $ setCheckBox checked "check" `fire` OnClick ! atr "class" "toggle") <|> return checkit
   
        case ch of
          ["check" :: String] -> changeState  idtask Completed task
          _                   -> changeState  idtask Active task

   destroy= (button ! atr "class" "destroy" $ noHtml) `pass` OnClick

   changeState  i stat task=
          insertTask i task stat
      **> itemsLeft
      **> showClearCompleted
      **> viewEdit i stat task

   viewEdit :: M.Key -> Status -> String -> Widget ()
   viewEdit idtask st task  = do
        let lab= case st of
                 Completed  -> label ! atr "class" "completed"
                 Active     -> label
        lab  task `pass` OnDblClick
        empty

    --  `wcallback` const (do
    --         ntask <-  inputString (Just task) `fire` OnKeyUp ! atr "class" "edit"
    --         ( _, Key k) <- getEventData'
    --         guard (k== 13) 
    --         return ntask

    --    `wcallback` (\ntask -> do
    --         insertTask idtask ntask st
    --         viewEdit idtask st ntask))

-- Model, using LocalStorage

getTasks :: MonadIO m  => m (Tasks, Int)
getTasks= liftIO $ do
    mt <- getItem "tasks" localStorage
    case fmap (read  . JS.unpack) mt of
      Nothing ->   setItem "tasks" (JS.pack  $ show (M.toList (M.empty :: Tasks),0 :: Int)) localStorage >> getTasks
      Just (ts,n) -> return (M.fromList ts, n)

getTask i= liftIO $ do
     (tasks,id) <- getTasks
     return $ M.lookup i tasks

setTasks :: MonadIO m => Tasks -> m ()
setTasks tasks=  liftIO $ do
      (_,n) <- getTasks
      setItem "tasks" (JS.pack  $ show (M.toList tasks,n)) localStorage

addTask :: String -> Status -> Widget Int
addTask task state= liftIO $ do
     (tasks,id) <- getTasks
     let tasks'= M.insert id  (task, state) tasks
     setItem "tasks" (JS.pack  $ show (M.toList tasks', id+1)) localStorage
     return id

insertTask id task state= liftIO $ do
     (tasks,i) <- getTasks
     let tasks'= M.insert  id (task,state) tasks
     setItem "tasks" (JS.pack $ show (M.toList tasks', i)) localStorage
     return tasks'

delTask i= liftIO $ do
   (tasks,_) <- getTasks
   setTasks $ M.delete i tasks

#endif

-}