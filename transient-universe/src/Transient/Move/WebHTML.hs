#!/usr/bin/env runghc
{-# LANGUAGE OverloadedStrings #-}
module Transient.Move.WebHTML (generateHTML) where

import Transient.Move.Defs
import Transient.Move.Web
import Data.ByteString.Lazy.Char8 as BS
import Data.Aeson
import Data.List.Split (splitOn)
import Data.List (isPrefixOf)

-- | Generates an interactive HTML page for a transient endpoint.
generateHTML :: String -> HTTPReq -> BS.ByteString
generateHTML endpoint req = BS.pack $ """
<html>
<head>
  <title>Transient Endpoint: " ++ endpoint ++ "</title>
  <style>
    body { font-family: sans-serif; margin: 2em; }
    h1, h2 { color: #333; }
    pre { background-color: #eee; padding: 1em; border-radius: 5px; white-space: pre-wrap; word-wrap: break-word;}
    form { margin-top: 1em; }
    input { margin-bottom: 0.5em; padding: 8px; width: 300px; border: 1px solid #ccc; border-radius: 4px;}
    input[type=\"submit\"] { width: auto; cursor: pointer; background-color: #4CAF50; color: white;}
    #response { margin-top: 1em; border: 1px solid #ccc; padding: 1em; min-height: 50px;}
    #follow-up a { display: block; margin-top: 0.5em; }
  </style>
</head>
<body>
  <h1>Endpoint: " ++ endpoint ++ "</h1>
  <h2>cURL Command</h2>
  <pre id=\"curl\">" ++ (BS.unpack $ printURL req) ++ "</pre>
  
  <h2>HTML Form</h2>
  <form id=\"endpoint-form\" method=\"" ++ (if reqtype req == POST then \"post\" else \"get\") ++ st\">
    " ++ (generateFormFields req) ++ "
    <input type=\"submit\" value=\"Submit Request">
  </form>
  
  <h2>Response</h2>
  <pre id=\"response\"></pre>
  
  <h2>Follow-up Actions</h2>
  <div id=\"follow-up\"></div>

  <script>
    document.getElementById('endpoint-form').addEventListener('submit', function(event) {
      event.preventDefault();
      const formData = new FormData(event.target);
      const data = Object.fromEntries(formData.entries());
      
      let url = \"" ++ (BS.unpack $ requrl req) ++ "\";
      let body = {};

      // Replace placeholders in URL and prepare body for POST
      if (event.target.method.toLowerCase() === 'post'){
          body= data;
      } else { 
          Object.keys(data).forEach(key => {
            if(url.includes('$' + key)){
              url = url.replace('$' + key, encodeURIComponent(data[key]));
            } else { 
              // add as query parameter if not in path
              const separator = url.includes('?') ? '&' : '?';
              url += separator + key + '=' + encodeURIComponent(data[key]);
            }
          });
      }

      fetch(url, {
        method: event.target.method,
        headers: {
          'Content-Type': 'application/json'
        },
        body: event.target.method.toLowerCase() === 'post' ? JSON.stringify(body) : null
      })
      .then(response => response.json())
      .then(responseData => {
        document.getElementById('response').textContent = JSON.stringify(responseData, null, 2);
        
        const followUpDiv = document.getElementById('follow-up');
        followUpDiv.innerHTML = ''; // Clear previous links

        const actions = Array.isArray(responseData) ? responseData : [responseData];

        actions.forEach(action => {
          if (action.req && action.req.requrl) {
            const link = document.createElement('a');
            const fullUrl = new URL(action.req.requrl, window.location.origin).href;
            link.href = fullUrl + '/html'; // Link to the HTML interface of the next step
            link.textContent = `Continue with: ${action.req.requrl}`;
            followUpDiv.appendChild(link);
          }
        });
      })
      .catch(error => {
        document.getElementById('response').textContent = 'Error: ' + error;
      });
    });
  </script>
</body>
</html>
"

-- | Generate the curl command string from an HTTPReq
printURL :: HTTPReq -> BS.ByteString
printURL req = "curl " <> (if reqtype req == GET then mempty else "-H 'content-type: application/json' -XPOST -d '" <> reqbody req <> "' ") <> requrl req

-- | Generate HTML input fields from an HTTPReq
generateFormFields :: HTTPReq -> String
generateFormFields req = 
    let urlParams = parseParams (BS.unpack $ requrl req)
        bodyParams = parseParams (BS.unpack $ reqbody req)
        allParams = urlParams ++ bodyParams
    in concatMap createInputField allParams

-- | A simple parser for placeholders like $int, $string etc.
parseParams :: String -> [String]
parseParams str = [p | p <- splitOn "/" str, "$" `isPrefixOf` p]

-- | Create an HTML input field based on the parameter type
createInputField :: String -> String
createInputField param = 
    let (inputType, paramName) = case param of
            "$int"     -> ("number", "int")
            "$string"  -> ("text", "string")
            _          -> ("text", tail param) -- Default for other types
    in "<label for=\"" ++ paramName ++ st\">" ++ paramName ++ ":</label><br>"
       ++ "<input type=\"" ++ inputType ++ st\" id=\"" ++ paramName ++ st\" name=\"" ++ paramName ++ st\""><br>"


