#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/home/vsonline/workspace/transient-stack" && runghc  -DDEBUG  -threaded  -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1 ${2} ${3}

{-# LANGUAGE OverloadedStrings,DeriveDataTypeable, FlexibleContexts, ScopedTypeVariables #-}
import Transient.Internals
import Transient.Logged hiding (exec)
import Transient.Move.Internals 
import Transient.Move.Services
import Transient.Parse
import Control.Monad.State
import System.Process
import System.Directory
import qualified Data.ByteString.Lazy.Char8 as BS
import Control.Exception hiding (onException,try)
import Control.Applicative 
import Data.Monoid
import System.Exit
import Data.Typeable
import Data.List
import Data.Maybe
import Data.Char
import qualified Data.Map as M
import Control.Concurrent
--import System.ByteOrder
--import System.IO.Unsafe
up = BS.unpack
pk = BS.pack

{-
ideas: compile info in central node?

modules
mapM notify modules

cuando falla un modulo puede ser por los includes
  not found.. es por los includes.
   el teoría deberían ser siempre las dependencias si el programa ha sido probado
-}

{-
packageFinder mod=do
    PackData list <- getRState
    case lookup mod list of
        Nothing -> addPackageFinder list mod
        Just _ -> putMailbox' mod ()
    where
    addPackageFinder list mod=do
        packages <- findPackages mod
        setRState $ PackData $ list ++[(mod,packages)]
-}
backtrack :: Monad m => m a
backtrack= return (error "backtrack should be used only in exceptions or backtracking")

solver= do
    return  []
        `onException'`  
           \(CompilationErrors errs)-> do 

                case errs of
                 [] -> empty
                 CabalError _ _ _:_ -> backtrack
                 CompError _ _ _ :_ -> backtrack 
                 Module mod:_ -> do
                    continue
                    liftIO $ print ("received",mod)
                    packages <-  findPackages (mod :: BS.ByteString)
                    newRState (1 :: Int)

                    pk <- return (packages !! 0) 
                           `onException'`  
                             \(CompilationErrors errs) -> do
                                case errs of
                                 Module _:_ -> backtrack
                                 CabalError mod' _ _:_ ->do
                                    n <- getRState

                                    liftIO $ print ("CabalError",mod')


                                    tr ("EXC******************",packages !! (n-1), BS.takeWhile (/='/')mod')

                                    if packages !! (n-1) /= BS.takeWhile (/='/')mod' then backtrack else do
                                        continue
                                        --setRState $ n +1
                                        guard (n < length packages)<|> error ("exhausted modules for: " ++ up mod)

                                        cabalInstall $ packages !! (n -1)
                                        return ""


                                 CompError mod' _ _ :_ -> do
                                    n <- getRState

                                    liftIO $ print ("NNN",n)


                                    tr ("EXC******************",packages !! (n-1), BS.takeWhile (/='/')mod')

                                    if packages !! (n-1) /= BS.takeWhile (/='/')mod' then backtrack else do
                                        continue
                                        guard (n < length packages)<|> error ("exhausted modules for: " ++ up mod)

                                        setRState $ n +1
                                        return $ packages !! n
    
                    (maybeLoadPackage mod pk) <> solver :: TransIO [BS.ByteString]


    
guardNotSolved= do
    Solved tf <- getRState <|> error "solved"
    guard $ not tf

type Dir= BS.ByteString

{-
solver' :: TransIO [Dir]
solver'=  do
    --abduce
    PackData list <- getRState
    shuffleMod list
    --addPathToOptions packages



shuffleMod :: [(Module,Packages)] -> TransIO [Dir]
shuffleMod []= do
    addThreads 1
    liftIO $ print "shuffleMod []"
    deleteMailbox' ("new" ::String) ([] ::[BS.ByteString])

    async (return []) <|> newModules
    where
    newModules= do
        liftIO $ print "GETMAILBOX"
        mods <- getMailbox' ("new" :: String)
        liftIO $ print "new mod received"
        pks <-  mapM findPackages (mods :: [BS.ByteString])
        let newpks = zip mods pks
        PackData l <- getRState <|> error "packdata"
        setRState $ PackData $ l <> newpks
        liftIO $ print "before shuffle"
        shuffleMod newpks

shuffleMod list= do
    let (mod,pkgs) = head list
    deleteMailbox' mod () 
    newRState (0 :: Int)
    guardNotSolved
    
    do addThreads 1
       getMailbox' mod :: TransIO ()
       n <- getRState
       guard $ n < length pkgs
       setRState (n+1)
       let pk= pkgs !! n
       dir <- --if n== length pkgs 
           --then cabalInstall mod pk
           --else 
               maybeLoadPackage mod pk

       rest <- shuffleMod $ tail list
       return $ dir:rest
     <|> do
       liftIO $ print "shuffle"
       guard $ not $ null pkgs
       let pk= head pkgs
       dir <- maybeLoadPackage mod pk
       liftIO $ print "maybeLoadPackage"
       liftIO $ print dir
       liftIO $ print $ ("tail", tail list)
       rest <- shuffleMod $ tail list
       return $ dir:rest

  
type Module= BS.ByteString
type Index= Int
type Packages= [BS.ByteString]
data PackData =PackData [(Module,Packages)] deriving (Read,Show)
{-
nextPk mod n= do
    PackData list <- getRState
    case lookup mod list of
      Nothing -> findPackages mod >> nextPk mod n
      Just (index, pks) -> do
          let list' = let (h,t)= span ((/=) mod . fst) list
                          index= fst $ snd $ head t
                          pks= snd $ snd $ head t
                      in  h ++ (mod,(index+1, pks)):tail t

          setRState $ PackData list'
          return $ pks !! index+1
-}
main2= keep $ do
    -- f <- liftIO $ BS.readFile "sal"
    -- setParseString f
    -- r <-  dechunk |- many anyChar
    -- liftIO $ print r

    setState ("Transient.Internals" :: BS.ByteString)
    -- r <- runCloud . callService hackageVersions $ up "transient-universe" :: TransIO Vers
    -- liftIO $ print ("hacageversion", r )
    -- r <- runCloud . callService hackageVersions $ up "transient" :: TransIO Vers
    -- liftIO $ print ("hacageversion2", r)

    r <- mapM (runCloud . callService hackageVersions . up)["transient-universe", "transient"]
    liftIO $ print ("hacageversion2", r ::[Vers])

newtype HTML= HTML BS.ByteString deriving (Show, Read)
instance Loggable HTML where
    deserialize = HTML <$> tTakeUntilToken "/html>"

main4= keep' $ do
    
    r <- searchErr "time-1.9.3/lib/Data/Time/Clock/Internal/SystemTime.hs:1:1: error:\n\
                        \    File name does not match module name:\n\
                        \    Saw: ‘Main’\n\
                        \    Expected: ‘Data.Time.Clock.Internal.SystemTime’" 
    liftIO $ print r
-}
main3= keep' $ do
    r <- withParseStream (return $ SMore "4\r\n\
                \Wiki\r\n\
                \5\r\n\
                \pedia\r\n\
                \E\r\n\
                \ in\r\n\
                \\r\n\
                \chunks.\r\n\
                \0\r\n\
                \\r\n"
                {-
                \4\r\n\
                \Wika\r\n\
                \5\r\n\
                \pedia\r\n\
                \E\r\n\
                \ in\r\n\
                \\r\n\
                \chunks.\r\n\
                \0\r\n\
                \\r\n" -})$  do
                    r <-(dechunk |- many parseString)
                    -- tDropUntilToken "\r\n"
                    -- r2 <-  (dechunk |- many parseString)
                    -- return  (r,r2)
                    return r
    liftIO $ print r

{-

main5= keep $ do 
    r <-  newNodes <|> do 
                     liftIO $ threadDelay 1000000
                     putMailbox' ("new" ::String) ("a" :: String) --[ getMailbox :: TransIO  String]
                     liftIO $ threadDelay 1000000
                     putMailbox' ("new" ::String)  ("b" :: String) -- [ getMailbox :: TransIO  String]
                     liftIO $ threadDelay 1000000
                     putMailbox' ("new" ::String)  ("c" :: String) -- [ getMailbox :: TransIO  String]
                     liftIO $ threadDelay 1000000
                     
                     putMailbox' ("a" :: String) ("hello" :: String)
                     putMailbox' ("b" :: String) ("world" :: String)
                     putMailbox' ("c" :: String) ("world2" :: String)

                     putMailbox' ("a" :: String) ("hello2" :: String)

                    --  liftIO $ threadDelay 1000000
                    --  liftIO $ print "_--------------"

                    --  putMailbox ("hello" :: String)
                    --  liftIO $ threadDelay 1000000
                    --  liftIO $ print "_--------------"

                    -- putMailbox ("hello" :: String)

                     empty

    liftIO $ print r 

    where
    newNodes=  async (return []) <|> do
        x <- getMailbox' ("new" ::String) :: TransIO  String
        deleteMailbox' ("new" :: String) (""::String)

        liftIO $ print ("received",x)
        (do r <-getMailbox' x;return [r]) <>  newNodes :: TransIO [String]

--  newNodes= newNode  <> (async (return  []) <|> newNodes) :: TransIO [String]
--     newNode= do
--         liftIO $ print "init"
--         --deleteMailbox' ("new" :: String) (""::String)
--         x <- getMailbox' ("new" ::String) :: TransIO  String

--         liftIO $ print ("received",x)
--         --deleteMailbox' x ("" :: String)
--         r <- getMailbox' x 
--         return [r]
-}





main6= keep' $ do
    f <- liftIO $ BS.readFile "sal"
    r <- searchErr f
    liftIO $ print r


main= keep $ do
    option ("compile" :: String) "compile"
    file    <- input  (const  True) "file to compile: " 
    ths     <- input' (Just 0) (const  True) "Number of jobs? (1) " ::  TransIO Int
    options <- input' (Just "") (const True) "compilation options? "
    liftIO $ print options
    setState $ Options (words options )
    setRState $ Solved False 
    build file 


data CompilationError=  Module BS.ByteString | CompError BS.ByteString Int Int | CabalError BS.ByteString Int Int deriving (Show)

--newtype CompilationErrors= CompilationErrors [Either BS.ByteString (BS.ByteString,Int,Int)] deriving (Show)
newtype CompilationErrors= CompilationErrors[CompilationError] deriving Show
instance Exception CompilationErrors




newtype Options= Options [String]
newtype Package= Package (M.Map String String)
build :: String  -> TransIO ()
build file = do
    liftIO $ putStrLn "building " >> putStrLn file


    dirs <- solver 

    --liftIO $ threadDelay 1000000
    liftIO $ print ("dirs",dirs)
      
    (cod,out,errs) <- ghc file dirs
    if cod == ExitSuccess then liftIO $ putStrLn "Success" else do
        liftIO  $ mapM_ putStrLn $ lines errs
        pkerrs <- searchErr $ pk errs
        liftIO $ print ("throw", pkerrs)
        throw  $ CompilationErrors pkerrs
    
splitmod s= 
    let (h,t)= BS.span (/='/') s    
    in (h,  tomod t)
    where
    tomod t=  if BS.null t then t else
        let len= BS.length t
        in replace "/" "." $ BS.tail  $ BS.take (len -3) t 

newtype Solved= Solved Bool

findPackages mod= do        
        Pack packages <- callGoogle mod
        liftIO $ print ("callGoogle=",packages,mod)
        setState mod
        packs <-runCloud $ mapM (callService' hackageVersions . up )  $ packages :: TransIO [Vers]
        
        r <- return $ concatMap (\(Vers p) ->p)   packs
        liftIO $ print ("findPackages=",r) 
        guard (not $ null r) <|> do liftIO $  putStr "no packages for module " ; liftIO $ print mod; empty

        return r
    where 
    callService' serv x = callService serv x -- <|> return  (Vers[])
     


maybeLoadPackage _ ""= return[]        
maybeLoadPackage mod package= do
    maybeLoadPackage' mod package
    let file= fileOf mod
    liftIO $ print file

 
    let grep= "find " <> up package <> " -print0 | grep -FzZ "  <> up file  -- <>" && echo ''"
    (code,path, msgerr) <- exec grep 
    if code /= ExitSuccess  
      then  throwt $ CompilationErrors [CompError package 0 0]
      else do
        liftIO $ print path
        dir <- withParseString (pk path) $ tTakeUntilToken  file
        return ["-i" <> dir]

    where
    maybeLoadPackage' mod package= do
        does <- liftIO $ doesDirectoryExist $ up  package
        when (not does)$ do
            let tar= "https://hackage.haskell.org/package/" <> up package <> ".tar.gz"
            liftIO $ print ("downloading package", tar)
            exec $ "curl -L " <> tar  <> "  | tar xvz" --"cabal download " <> (up  package)
            return()
      

{-
searchErr errs= withParseString errs $ do
    errblocks <- many block
    mapM parseBlock errblocks
    where
    block= do
        fst<- tTakeWhile (/= '\n') 
        lines <- explanation
        return $ fst <> concat lines

    parseBlock errblock= witParseString errblock parse
        
    parse= do
        do 
            tDropUntilToken "Failed to load interface for ‘"
            mod <- tTakeWhile (/= '\EM')
            return $ Left mod
        <|>  do many $ (do string "    "; tDropUntilToken "\n"); empty 
        <|> errorLines


        <|> do 

        --tDropUntilToken "Linking"; tDropUntilToken "\n"
        --do many $ (do string "    "; tDropUntilToken "\n"); empty
        --try(do r <- tTake 50 ; liftIO $ print ("rest2",r); empty) <|> return() 
        
        showNext "next2" 20

        r <- Right <$> ((,,) <$> tTakeWhile (/='/')  <*> 0 <*> 0)
        tDropUntilToken "failed in phase"
        --tr ("linking error", r)
        return $let Right(a,b,c)= r in  Right(if BS.head a == '\n' then BS.tail a else a,b,c)
        --many $ tDropUntilToken "\n" -- discard all the rest

    
    errorLines= try errorLine   -- <|> errorLines
    explanation=   do  many $ (do string "    "; tTakeUntilToken "\n");  

    errorLine= do
        showNext "next" 20
        try (tChar '\n') <|> return ' '
        modlc <- (,,) <$> tTakeWhile' (/=':') <*> int <* tChar ':' <*> int

        (do 
        string  ": error:"
        tr "ERROR"
        tTakeWhile isSpace 

        s <- parseString 
        tr s
        tDropUntilToken "\n"

        explanation 
        guard (s /="warning:")
        return $ Right modlc) <|> return (Right ("",0,0))
-}

searchErr ers= catMaybes <$> do
     setParseString ers
     many $  do
        try missingModule
         <|> try errorLine
         <|> linkingError

    where
    linkingError= do 

        r <- Right <$> ((,,) <$> tTakeWhile (/='/')  <*> 0 <*> 0)
        tDropUntilToken "failed in phase"
        return $let Right(a,b,c)= r in Just $ CompError(if BS.head a == '\n' then BS.tail a else a) b c

    missingModule= do 
              tDropUntilToken "Failed to load interface for ‘"
              mod <- tTakeWhile (/= '\EM')
              explanation
              return $ Just $ Module mod

    explanation= do
        r <- many $ do 
                 string "    ";  
                 s <- tTakeUntilToken "\n"
                 withParseString  s $ (tDropUntilToken ".h:" >> return True) <|> return False
        return $ or r

    errorLine= do
        try (tChar '\n') <|> return ' '

        (modlc,fil,col) <- (,,) <$> tTakeWhile' (/=':') <*> int <* tChar ':' <*> int <* tChar ':' 
        tr ("mod=", modlc)
        

        s <- parseString
        tDropUntilToken "\n"
        
       
        t <-parseString
        liftIO $ print (s,t)

        rr <- tTakeUntilToken "\n"
        hasC1 <- withParseString  rr $ (tDropUntilToken ".h:" >> return True) <|> return False
        hasC <- try explanation <|> return False
        tr ("hasC", hasC,hasC1)

        if hasC || hasC1 then return $ Just $ CabalError modlc fil col

        else if s /="error:" || t =="warning:" then  return Nothing
        else return $ Just $ CompError modlc fil col



-- >>> keep' $ many (return "hello" <|> return "world") >>= liftIO . print
-- []
-- Nothing
--


searchHackage :: BS.ByteString -> TransIO Vers
searchHackage mod= do
        let (p1,p2)=  BS.span  (/= '.') mod
        HPack packages <- runCloud $ callService hackage $ (up p1, up p2)
        liftIO $ putStr "package: " >> print  packages
        setState mod
        guard (not $ null packages) <|> error "no packages found"
        runCloud $ callService hackageVersions $ up $ head packages :: TransIO Vers
    where


    hackage= [("service","hackage"),("type","HTTP")
            ,("nodehost","hackage.haskell.org")
            ,("nodeport","80")
            ,("HTTPstr","GET /packages/search?terms=$1+$2 HTTP/1.1\r\nHost: $hostnode\r\n\r\n")]

hackageVersions=
            [("service","hackageVersions"),("type","HTTP")
            ,("nodehost","hackage.haskell.org")
            ,("nodeport","80")
            ,("HTTPstr","GET /package/$1 HTTP/1.1\r\nHost: $hostnode\r\n\r\n")]


    -- cont <-getCont
    -- (mx, _) <-liftIO $ withMVar crit $ const $ runTransState  cont c
    -- case mx of
    --     Nothing -> empty
    --     Just x -> return x

callGoogle :: BS.ByteString -> TransIO Pack
callGoogle mod= runCloud $ callService google mod
google= [("service","google"),("type","HTTP")
        ,("nodehost","www.google.com")
        ,("nodeport","80")
        ,("HTTPstr","GET /search?q=+$1+site:hackage.haskell.org HTTP/1.1\r\nHost: $hostnode\r\n\r\n" )]

fileOf :: BS.ByteString -> BS.ByteString
fileOf mod= replace "." "/" mod <> ".hs"
        
newtype Vers = Vers [BS.ByteString] deriving (Read,Show)
instance Loggable Vers where
    serialize (Vers p)= undefined
    deserialize= Vers <$>  (do

        mod <- getState <|> error "no mod"
        tr ("MOD", mod :: BS.ByteString)
        --try(do r <- notParsed ; liftIO $ print r; empty) <|> return()
        tDropUntilToken "Versions"
        vs <- reverse . sort . nub <$> (many $ do   
                tDropUntilToken "href=\"/package/"
                m <-tTakeWhile (\c -> c /='\"' && c /= '/')
                tr m
                guard $ hasNumber m

                return m) 

        tDropUntilToken mod
        c <- anyChar
        guard $ c /= '.' -- hasa no sufixes
        --liftIO $ print vs
        tr "VERS PARSEDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"
        return vs

        
     <|> return  []) 
     where
     hasNumber p =  BS.foldl' (\p x -> p || isNumber x) False  p 

newtype HPack= HPack [BS.ByteString] deriving (Read,Show)

instance Loggable HPack where 
    serialize (HPack p)= undefined
    --deserialize= HPack <$> notParsed
    
    deserialize= HPack <$>(many $ do
        tDropUntilToken "/package/"
        
        tTakeWhile (/='\"'))

newtype Pack= Pack [BS.ByteString] deriving (Read,Show,Typeable)

instance Loggable Pack where
    serialize (Pack p)= undefined
    deserialize= do
        Pack .reverse . sort . nub  <$>(many $ do
        tDropUntilToken "hackage.haskell.org/package/" --"https://hackage.haskell.org/package/"
        --chainManyTill (BS.cons) anyChar (try $ tChar '&' <|> (do tChar '-' ; x <-anyChar ; guard $ isNumber x; return x)))
        r <- tTakeWhile (\c -> not (isNumber c) && c /= '&' && c /= '/') -- (\c -> c /= '/' && c/= '&' && c /= '\"')) -- (/= ' ')) -- (/=' '))
        let l= BS.length r -1
        return $ if ( BS.index r l == '-') then BS.take l r else r)
        --where
        --hasNumber = filter (\p ->BS.foldl' (\p x -> p || isNumber x) False  p)

filterMod :: BS.ByteString -> [BS.ByteString] -> TransIO [BS.ByteString]
filterMod mod paks = do
     ss <- mapM (\s -> withParseString s pass) paks 
     return $ catMaybes ss
  where
  pass=  do
      pak <- tTakeWhile ( /= '/') 
      tDropUntilToken $ replace "." "-" mod
      return $ Just pak
    <|> return Nothing

replace a b s | BS.null s = s
                          | otherwise=
                   if BS.isPrefixOf a s
                            then b <>replace a b (BS.drop (BS.length a) s)
                            else BS.head s `BS.cons` replace a b (BS.tail s)

-- cabal pk= 
--     liftIO $ readProcessWithExitCode "cabal" ("install":pk) ""

cabalInstall mod = do
    tr ("CABALINSTALL", mod)
    liftIO $ setCurrentDirectory $ up mod
    Options ops <-  getState <|> return (Options mempty)
    let cabops  = if "-prof" `elem` ops then ["--enable-library-profiling", "--enable-executable-profiling", "--reinstall","--force-reinstalls" ] else []
    tr ("CABAL", ("install":up mod:cabops) )
    r <-  liftIO $ readProcessWithExitCode "cabal" ("install": up mod:cabops) ""
    liftIO $ print r
    
    liftIO $ setCurrentDirectory ".."


ghc proc (dirs :: [Dir])= do
    Options ops <-  getState <|> return (Options mempty)
    let dirss= map up dirs
    liftIO $ print $ "ghc " <> " "<> proc <> " " <> concatMap (<>" ") ops <> concatMap (<>" ") dirss

    liftIO $ readProcessWithExitCode "ghc"  (proc:(ops ++ dirss)) "" --(shell  $ up proc) 

exec proc=  liftIO $ do
    --putStrLn proc
    readCreateProcessWithExitCode (shell proc)  ""
    
