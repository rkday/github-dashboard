 {-# LANGUAGE OverloadedStrings #-}

import Github.Issues
import Data.Either
import Data.Maybe
import Data.Time.Clock
import Data.Time.Calendar (addDays)
import Data.Aeson
import Data.Monoid
import Data.Configurator
import qualified Data.Configurator.Types as DCTypes (Value)     
import Web.Scotty
import Network.HTTP.Types.Status
import Data.List (intersect)
import Data.IORef
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent

data CrossThreadData = CrossThreadData {
      issues :: Either [(String, Error)] [Issue],
      prs :: Either [(String, Error)] [Issue],
      recentlyClosedIssues :: Either [(String, Error)] [Issue],
      recentlyClosedCount :: Int,
      recentlyOpenedCount :: Int
    }
    
data TruncatedIssue =  TruncatedIssue {
      whenOpened :: UTCTime,
      whenClosed :: Maybe UTCTime,
      priority :: String,
      issueURL :: Maybe String,
      title :: String,
      createdBy :: String,
      ownedBy :: String
    } deriving Show

instance ToJSON TruncatedIssue where
    toJSON (TruncatedIssue whenOpened whenClosed priority issueURL title createdBy ownedBy) = object ["description" .= title,
                                                                                                "when_opened" .= whenOpened,
                                                                                                "when_closed" .= whenClosed,
                                                                                                "url" .= issueURL,
                                                                                                "raiser" .= createdBy,
                                                                                                "owner" .= ownedBy,
                                                                                                "priority" .= priority
                                                                                               ]
getFortnightAgo :: IO UTCTime
getFortnightAgo = do
    now <- getCurrentTime
    return $ UTCTime (addDays (-14) (utctDay now)) (utctDayTime now)
                   
convertJSON
  :: Either a [Issue]
     -> Either a Value
convertJSON (Left errs) = Left errs
convertJSON (Right issues) = Right (toJSON (map summariseIssue issues))
               
summariseIssue :: Issue -> TruncatedIssue
summariseIssue issue =
    TruncatedIssue (fromGithubDate $ issueCreatedAt issue)
                       (fmap fromGithubDate $ issueClosedAt issue)
                       (priorityFromLabels (map labelName $ issueLabels issue))
                       (issueHtmlUrl issue)
                       (issueTitle issue)
                       (githubOwnerLogin $ issueUser issue)
                       (fromMaybe "nobody" $ fmap githubOwnerLogin $ issueAssignee issue)

doToLeft :: (a -> c) -> (Either a b) -> (Either c b)
doToLeft fn (Left a) = Left (fn a)
doToLeft _ (Right a) = Right a
                        
                       
getOpenIssues :: Maybe GithubAuth -> [IssueLimitation] -> String -> String -> IO (Either (String, Error) [Issue])
getOpenIssues auth limitations user name = fmap (doToLeft (\x -> (name, x))) (issuesForRepo' auth user name limitations)
    
onlyPRs :: Either a [Issue] -> Either a [Issue]
onlyPRs (Right issues) = Right (filter isPullRequest issues)
onlyPRs (Left errs) = Left errs
                     
notPRs :: Either a [Issue] -> Either a [Issue]
notPRs (Right issues) = Right (filter (not . isPullRequest) issues)
notPRs (Left errs) = Left errs
                     
multiGetIssues :: String -> [String] -> Maybe GithubAuth -> [IssueLimitation] -> IO (Either [(String, Error)] [Issue])
multiGetIssues user names auth limitations = fmap issuesTransform $ sequence $ map (getOpenIssues auth limitations user) names

issuesTransform :: [Either a [b]] -> Either [a] [b]
issuesTransform input =
    if null $ lefts input then
       Right (concat $ rights input)
    else
        Left (lefts input)

overlap list1 list2 = not $ null (intersect list1 list2)
             
priorityFromLabels_base highPriorityLabels mediumPriorityLabels lowPriorityLabels labels =
    if (overlap labels highPriorityLabels) then "1 - high" else
    if (overlap labels mediumPriorityLabels) then "2 - medium" else
    if (overlap labels lowPriorityLabels) then "4 - low" else
        "3 - unknown"

priorityFromLabels = priorityFromLabels_base ["high-priority", "priority:high"] ["medium-priority", "priority:medium"]  ["low-priority", "priority:low"] 
        
isPullRequest :: Issue -> Bool
isPullRequest issue = isJust $ issuePullRequest issue

                      
scottyPRs :: Either [(String, Error)] [Issue] -> Int -> Int -> ActionM ()
scottyPRs (Left a) _ _ = do
  status status503
  Web.Scotty.json $ object ["errors" .= (show a)]
scottyPRs (Right a) ro rc  = do
  setHeader "Access-Control-Allow-Methods" "POST, GET, OPTIONS"
  setHeader "Access-Control-Allow-Headers" "X-PINGOTHER"
  setHeader "Access-Control-Max-Age" "1728000"
  setHeader "Access-Control-Allow-Origin" "*"
  Web.Scotty.json $ object ["issues" .= (map summariseIssue a),
                            "recentlyOpened" .= toJSON ro,
                            "recentlyClosed" .= toJSON rc
                         ]

openedSince :: UTCTime -> Issue -> Bool
openedSince when issue = (fromGithubDate (issueCreatedAt issue)) > when

closedSince :: UTCTime -> Issue -> Bool
closedSince when issue = case (issueClosedAt issue) of
                                    Nothing -> False
                                    Just date -> (fromGithubDate date) > when

  
updateIssues:: String -> [String] -> Maybe GithubAuth -> IORef (CrossThreadData) -> IO ()
updateIssues repoOwner repoNames auth resultRef = do
  putStrLn "Updating issues from Github"
  fortnightAgo <- getFortnightAgo
  everything <- multiGetIssues repoOwner repoNames auth [Open]
  closedIssues <- fmap notPRs $ multiGetIssues repoOwner repoNames auth [OnlyClosed, (Since fortnightAgo)]
  let openPRs = onlyPRs everything
  let openIssues = notPRs everything
  let openIssueCount = (either length (length . filter (openedSince fortnightAgo)) openIssues) + (either length (length . filter (openedSince fortnightAgo)) closedIssues)
  let recentlyClosedIssues = either Left (Right . (filter (closedSince fortnightAgo))) closedIssues
  let closedIssueCount = either length length recentlyClosedIssues
  writeIORef resultRef (CrossThreadData openIssues openPRs recentlyClosedIssues closedIssueCount openIssueCount)
  putStrLn "Updated issues from Github"

updateIssuesLoop :: String -> [String] -> Maybe GithubAuth -> IORef (CrossThreadData) -> IO ()
updateIssuesLoop repoOwner repoNames auth resultRef = do
  updateIssues repoOwner repoNames auth resultRef
  threadDelay (1000 * 1000 * 60 * 30)
  updateIssuesLoop repoOwner repoNames auth resultRef
                   
main =
    do
      cfg <- load [Required "./githubissues.cfg"]
      lst <- require cfg "repoNames"
      user <- require cfg "repoOwner"
      oauthToken <- Data.Configurator.lookup cfg "oauthToken"
      let oauth = fmap GithubOAuth oauthToken
      ctd <- newIORef $ CrossThreadData (Right []) (Right []) (Right []) (-1) (-1)
      forkIO $ updateIssuesLoop user lst oauth ctd
      scotty 3005 $ do
        get "/prs" $ do
                      openPRs <- liftIO $ fmap prs $ readIORef ctd
                      scottyPRs openPRs (-1) (-1)
        get "/issues" $ do
                      openIssues <- liftIO $ fmap issues $ readIORef ctd
                      ro <- liftIO $ fmap recentlyOpenedCount $ readIORef ctd
                      rc <- liftIO $ fmap recentlyClosedCount $ readIORef ctd
                      scottyPRs openIssues ro rc
        get "/recentlyClosed" $ do
                      issues <- liftIO $ fmap recentlyClosedIssues $ readIORef ctd
                      scottyPRs issues 0 0
        get "/dashboard" $ file "./dashboard.html"
        get "/dashboard.js" $ file "./dashboard.js"
