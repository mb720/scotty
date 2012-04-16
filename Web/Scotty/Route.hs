{-# LANGUAGE OverloadedStrings #-}
module Web.Scotty.Route
    ( get, post, put, delete, addroute, matchAny, notFound,
      capture, regex, function, literal
    ) where

import Web.Scotty.Action
import Web.Scotty.Types

import Control.Monad.Error
import qualified Control.Monad.State as MS

import Data.Monoid (mconcat)
import qualified Data.Text.Lazy as T

import Network.HTTP.Types
import Network.Wai

import Web.Scotty.Util

import qualified Text.Regex as Regex
import Control.Arrow ((***))

-- | get = 'addroute' 'GET'
get :: RoutePattern -> ActionM () -> ScottyM ()
get = addroute GET

-- | post = 'addroute' 'POST'
post :: RoutePattern -> ActionM () -> ScottyM ()
post = addroute POST

-- | put = 'addroute' 'PUT'
put :: RoutePattern -> ActionM () -> ScottyM ()
put = addroute PUT

-- | delete = 'addroute' 'DELETE'
delete :: RoutePattern -> ActionM () -> ScottyM ()
delete = addroute DELETE

-- | Add a route that matches regardless of the HTTP verb.
matchAny :: RoutePattern -> ActionM () -> ScottyM ()
matchAny pattern action = mapM_ (\v -> addroute v pattern action) [minBound..maxBound]

-- | Specify an action to take if nothing else is found. Note: this _always_ matches,
-- so should generally be the last route specified.
notFound :: ActionM () -> ScottyM ()
notFound action = matchAny (Function (\req -> Just [("path", path req)])) (status status404 >> action)

-- | Define a route with a 'StdMethod', 'T.Text' value representing the path spec,
-- and a body ('ActionM') which modifies the response.
--
-- > addroute GET "/" $ text "beam me up!"
--
-- The path spec can include values starting with a colon, which are interpreted
-- as /captures/. These are named wildcards that can be looked up with 'param'.
--
-- > addroute GET "/foo/:bar" $ do
-- >     v <- param "bar"
-- >     text v
--
-- >>> curl http://localhost:3000/foo/something
-- something
addroute :: StdMethod -> RoutePattern -> ActionM () -> ScottyM ()
addroute method pat action = MS.modify (addRoute r)
    where r = route method pat action

route :: StdMethod -> RoutePattern -> ActionM () -> Middleware
route method pat action app req =
    if Right method == parseMethod (requestMethod req)
    then case matchRoute pat req of
            Just captures -> do
                env <- mkEnv method req captures
                res <- lift $ runAction env action
                maybe tryNext return res
            Nothing -> tryNext
    else tryNext
  where tryNext = app req

matchRoute :: RoutePattern -> Request -> Maybe [Param]

matchRoute (Literal pat) req | pat == path req = Just []
                             | otherwise       = Nothing

matchRoute (Function fun) req = fun req

matchRoute (Capture pat) req = go (T.split (=='/') pat) (T.split (=='/') $ path req) []
    where go [] [] prs = Just prs -- request string and pattern match!
          go [] r  prs | T.null (mconcat r)  = Just prs -- in case request has trailing slashes
                       | otherwise           = Nothing  -- request string is longer than pattern
          go p  [] prs | T.null (mconcat p)  = Just prs -- in case pattern has trailing slashes
                       | otherwise           = Nothing  -- request string is not long enough
          go (p:ps) (r:rs) prs | p == r          = go ps rs prs -- equal literals, keeping checking
                               | T.null p        = Nothing      -- p is null, but r is not, fail
                               | T.head p == ':' = go ps rs $ (T.tail p, r) : prs -- p is a capture, add to params
                               | otherwise       = Nothing      -- both literals, but unequal, fail

path :: Request -> T.Text
path = strictByteStringToLazyText . rawPathInfo

-- | Match requests using a regular expression.
--   Named captures are not yet supported.
--
-- > get (regex "^/f(.*)r$") $ do
-- >    path <- param "0"
-- >    cap <- param "1"
-- >    text $ mconcat ["Path: ", path, "\nCapture: ", cap]
--
-- >>> curl http://localhost:3000/foo/bar
-- Path: /foo/bar
-- Capture: oo/ba
--
regex :: String -> RoutePattern
regex pattern = Function $ \ req -> fmap (map (T.pack . show *** T.pack) . zip [0 :: Int ..] . strip)
                                         (Regex.matchRegexAll rgx $ T.unpack $ path req)
    where rgx = Regex.mkRegex pattern
          strip (_, match, _, subs) = match : subs

-- | Standard Sinatra-style route. Named captures are prepended with colons.
--   This is the default route type generated by OverloadedString routes. i.e.
--
-- > get (capture "/foo/:bar") $ ...
--
--   and
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > ...
-- > get "/foo/:bar" $ ...
--
--   are equivalent.
capture :: String -> RoutePattern
capture = Capture . T.pack

-- | Build a route based on a function which can match using the entire 'Request' object.
--   'Nothing' indicates the route does not match. A 'Just' value indicates
--   a successful match, optionally returning a list of key-value pairs accessible
--   by 'param'.
--
-- > get (function $ \req -> Just [("version", T.pack $ show $ httpVersion req)]) $ do
-- >     v <- param "version"
-- >     text v
--
-- >>> curl http://localhost:3000/
-- HTTP/1.1
--
function :: (Request -> Maybe [Param]) -> RoutePattern
function = Function

-- | Build a route that requires the requested path match exactly, without captures.
literal :: String -> RoutePattern
literal = Literal . T.pack
