{-# LANGUAGE CPP #-}
module Internal.API where

import           Internal.FFI
import           Internal.Type

import           Internal.JS
--------------------------------------------------------------------------------


--------------------------------------------------------------------------------
#ifndef BROWSER
notImplemented :: a
notImplemented = error "Client side call not implemented on server side."
#endif

getDocument :: IO Elem
#ifdef BROWSER
getDocument = Elem <$> js_document
#else
getDocument = notImplemented
#endif

getBody :: IO Elem
#ifdef BROWSER
getBody = Elem <$> js_documentBody
#else
getBody = notImplemented
#endif

newElem :: JSString -> IO Elem
#ifdef BROWSER
newElem = (Elem <$>) . js_documentCreateNode
#else
newElem = notImplemented
#endif

newElemNS :: JSString -> JSString -> IO Elem
#ifdef BROWSER
newElemNS ns e  = Elem <$> js_documentCreateNodeNS ns e
#else
newElemNS = notImplemented
#endif

newTextElem :: JSString -> IO Elem
#ifdef BROWSER
newTextElem = (Elem <$>) . js_createTextNode
#else
newTextElem = notImplemented
#endif

parent :: Elem -> IO Elem
#ifdef BROWSER
parent (Elem c) = Elem <$> js_parentNode c
#else
parent = notImplemented
#endif

-- | Appends one element to another.
addChild :: Elem -- ^ child element to append
         -> Elem -- ^ parent element
         -> IO ()
#ifdef BROWSER
addChild (Elem c) (Elem p) = js_appendChild p c
#else
addChild = notImplemented
#endif

-- | Remove child from parent.
removeChild :: Elem -- ^ child to remove
            -> Elem -- ^ parent node
            -> IO ()
#ifdef BROWSER
removeChild (Elem c) (Elem p) = js_removeChild p c
#else
removeChild = notImplemented
#endif

clearChildren :: Elem -> IO ()
#ifdef BROWSER
clearChildren (Elem e) = js_clearChildren e
#else
clearChildren = notImplemented
#endif

replace :: Elem -> Elem -> IO Elem
#ifdef BROWSER
replace oe@(Elem o) (Elem n) =
  do (Elem par) <- parent oe
     js_replaceChild par o n
     return (Elem n)
#else
replace = notImplemented
#endif

setAttr :: Elem -> PropId -> JSString -> IO ()
#ifdef BROWSER
setAttr (Elem e) p = js_setAttribute e p
#else
setAttr = notImplemented
#endif

setInnerHTML :: Elem -> JSString -> IO ()
#ifdef BROWSER
setInnerHTML (Elem e) = js_setInnerHtml e
#else
setInnerHTML = notImplemented
#endif

getElemById :: JSString -> IO Elem
#ifdef BROWSER
getElemById = (Elem <$>) . js_getElementById
#else
getElemById = notImplemented
#endif

queryAll :: JSString -> IO [Elem]
#ifdef BROWSER
queryAll query =
  do res <- js_querySelectorAll query
     map Elem <$> jsListOf res
#else
queryAll = notImplemented
#endif

-- | Attach an event listener to element.
--
-- Returns an action removing listener, though you still have to release
-- callback manually.
--
-- If you are sure that you do not want to remove handler consider using
-- 'onEvent''.
onEvent :: NamedEvent e => Elem -> e -> Callback (JSVal -> IO()) -> IO (IO ())

-- | Attach endless event listener to element.
--
-- Use this function to attach event handlers which supposed not to be removed
-- during application run.
onEvent' :: NamedEvent e => Elem -> e -> (JSVal -> IO()) -> IO ()

-- | Remove attached event listener.
--
-- Normally you can use action returned by 'onEvent' to detach event listener,
-- however you can also use this function directly.
removeEvent :: NamedEvent e => Elem -> e -> Callback (JSVal -> IO ()) -> IO ()
#ifdef BROWSER
onEvent el'@(Elem el) et cb =
  do js_addEventListener el e cb
     return $ removeEvent el' e cb
  where
    e = pack (eventName et)

onEvent' (Elem el) et hnd =
  do cb <- asyncCallback1 hnd
     js_addEventListener el e cb
  where
    e = pack (eventName et)

removeEvent (Elem el) et cb = js_removeEventListener el (pack (eventName et)) cb
#else
onEvent = notImplemented
onEvent' = notImplemented
removeEvent = notImplemented
#endif
--------------------------------------------------------------------------------
