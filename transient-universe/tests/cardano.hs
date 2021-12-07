main= keep $ initNode $  start <|> guess id

start = do
    
   amount <- webpoint "enter the amount to lock"      -- display the path/$d as parameter of the REST call from the type of the response
                                                      -- and the path.
                                                      -- also, it read it from the console if executed in console
                                                      -- generates {"msg"="enter the amount to lock","url"= "https://servername/e/f/w/$d"}
   gameId <- local $ inChain startGame 
   local $ inChain  $ lock amount
   newFlow  gameId                                    -- set a game identifier
   guessText <- webPoint "enter guess text"           -- generates{msg="enter guess text". "url"="https://servername/<gameId>/$d" }
                                                      -- and input it from console
   result <- inChain $ guess guessText                -- the inChain code of "guess" also pay if it is correct
   if result 
       then 
        removeFlow gameId
        webPoint "OK"
       else 
        webPoint "FAIL"

from type to input: 
class Input a where
    inputIt :: a -> TransIO a