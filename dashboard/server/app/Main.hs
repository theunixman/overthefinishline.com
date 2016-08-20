{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Control.Monad (forM_, mzero, unless, void, when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Logger (runStderrLoggingT)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except
import Control.Monad.Trans.List
import Control.Monad.Trans.Maybe
import Data.Aeson hiding (json)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringC
import Data.ByteString.Lazy (toStrict)
import qualified Data.Function as Function
import qualified Data.List as List
import qualified Data.Map as Map
import Data.Maybe (catMaybes, fromJust, isJust, listToMaybe, mapMaybe)
import qualified Data.Text as Text
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Clock (NominalDiffTime, getCurrentTime)
import qualified Database.Persist as Database
import qualified Database.Esqueleto as Sql
import Database.Esqueleto hiding (delete, get)
import Database.Persist.Postgresql (ConnectionString, runMigration, runSqlPersistMPool, withPostgresqlPool)
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (badRequest400, internalServerError500)
import Network.OAuth.OAuth2 as OAuth2
import qualified Network.Wai.Parse as Parse
import qualified Network.Wai.Handler.Warp as Warp
import Network.Wai.Middleware.Static (addBase, noDots, staticPolicy, (>->))
import System.Environment (getEnv, lookupEnv)
import System.FilePath
import System.IO.Error
import System.Posix.Signals
import Web.Spock

import OverTheFinishLine.Dashboard.Enumerations
import OverTheFinishLine.Dashboard.GitHub
import OverTheFinishLine.Dashboard.Model

type Port = Int
data Configuration = Configuration {
  configurationPort :: Port,
  configurationClientPath :: FilePath,
  configurationGitHubOAuthCredentials :: OAuth2,
  configurationDatabaseConnectionString :: ConnectionString,
  configurationDatabasePoolSize :: Int,
  configurationSessionTTL :: NominalDiffTime,
  configurationSessionStoreInterval :: NominalDiffTime
}

type Context = SpockActionCtx () () (Maybe UserId) ()

main :: IO ()
main = readConfiguration >>= server

server :: Configuration -> IO ()
server configuration =
  runStderrLoggingT $ withPostgresqlPool databaseConnectionString databasePoolSize $ \pool -> liftIO $ do
    putStrLn ("Application starting on port " ++ show port ++ ".")
    flip runSqlPersistMPool pool $ runMigration migrateAll
    httpManager <- newManager tlsManagerSettings
    app <- createApp configuration pool httpManager
    Warp.runSettings warpSettings app
  where
    databaseConnectionString = configurationDatabaseConnectionString configuration
    databasePoolSize = configurationDatabasePoolSize configuration
    port = configurationPort configuration
    warpSettings = Warp.defaultSettings
      |> Warp.setPort port
      |> Warp.setGracefulShutdownTimeout (Just 1)
      |> Warp.setInstallShutdownHandler (\closeSockets ->
          void $ installHandler sigTERM (Catch (closeSockets >> putStrLn "Application shut down.")) Nothing)

createApp configuration databaseConnectionPool httpManager =
  spockAsApp $ spock spockConfiguration $ do
    middleware $ staticPolicy (noDots >-> addBase (configurationClientPath configuration))

    get root appHtml

    get ("authentication" <//> "by" <//> "github") authenticateWithGitHub

    get ("authorization" <//> "by" <//> "github") $ do
      userId <- runExceptT storeUser
      either handleException storeSession userId

    get "projects" appHtml

    post "projects" $ do
      requestParams <- params
      project <- runExceptT $ do
        user <- readUser
        storeProject user requestParams
      either handleException (redirect . uncurry projectUrl) project

    get ("projects" <//> (var :: Var Text) <//> (var :: Var Text)) $ const $ const appHtml

    get ("projects" <//> (var :: Var Text) <//> (var :: Var Text) <//> "edit") $ const $ const appHtml

    post ("projects" <//> (var :: Var Text) <//> (var :: Var Text) <//> "edit") $ \username projectName -> do
      requestParams <- params
      project <- runExceptT $  do
        user <- readUserByName username
        updateProject user projectName requestParams
      either handleException (redirect . uncurry projectUrl) project

    subcomponent "api" $ do
      get "me" $ do
        me <- runExceptT $ do
          Entity userId user <- readUser
          projects <- readMyProjects userId user
          return (user, projects)
        either handleException (uncurry renderMe) me

      get ("projects" <//> var <//> var) $ \username projectName -> do
        now <- liftIO getCurrentTime
        pullRequests <- runExceptT $ do
          accessToken <- readAccessToken
          repositories <- withDatabase (
              select $ from $ \(user `InnerJoin` project `InnerJoin` repository) -> do
                  on (project ^. ProjectId ==. repository ^. ProjectRepositoryProjectId)
                  on (user ^. UserId ==. project ^. ProjectUserId)
                  where_ $
                    user ^. UserUsername ==. val username
                    &&. project ^. ProjectName ==. val projectName
                  return repository
            ) `onEmpty` QueryFailure "No repositories found."
          concat <$> mapM (fetchGitHubPullRequests accessToken . projectRepositoryName . entityVal) repositories
        let dashboard = Dashboard now <$> pullRequests
        either handleException render dashboard

      get ("projects" <//> var <//> var <//> "edit") $ \username projectName -> do
        project <- runExceptT $ do
          Entity userId user <- readUserByName username
          project <- readProject user projectName
          return $ MySingleProject user project
        either handleException render project

  where
    appHtml = file "text/html" (configurationClientPath configuration </> "index.html")

    authenticateWithGitHub = redirect $ decodeUtf8 $ authorizationUrl gitHubOAuthCredentials

    storeSession userId = do
      sessionRegenerateId
      writeSession $ Just userId
      redirect "/"

    storeUser = do
      code <- param "code" `orException` MissingParam "code"
      accessToken <- withExceptT (InvalidAuthenticationCode . decodeUtf8 . toStrict) $
        ExceptT $ liftIO $ fetchAccessToken httpManager gitHubOAuthCredentials (encodeUtf8 code)
      (GitHubUser gitHubUserId gitHubUserLogin gitHubUserAvatarUrl) <- fetchGitHubUser accessToken
      let accessTokenString = OAuth2.accessToken accessToken
      withDatabase $ do
        let user = User gitHubUserLogin gitHubUserAvatarUrl
        let serviceUser = ServiceUser GitHub gitHubUserId
        serviceCredentials <- getBy serviceUser
        case serviceCredentials of
          Nothing -> do
            userId <- insert user
            insert $ ServiceCredentials userId GitHub gitHubUserId accessTokenString
            return userId
          Just (Entity serviceCredentialsId (ServiceCredentials userId _ _ _)) -> do
            repsert userId user
            update $ \serviceCredentials -> do
              set serviceCredentials [ServiceCredentialsAccessToken =. val accessTokenString]
              where_ (serviceCredentials ^. ServiceCredentialsId ==. val serviceCredentialsId)
            return userId

    storeProject (Entity userId user) requestParams = do
      (project, repositoryNames) <- projectParams userId requestParams
      withDatabase $ do
        projectId <- insert project
        mapM_ (insert . ProjectRepository projectId) repositoryNames
      return (user, project)

    updateProject (Entity userId user) existingProjectName requestParams = do
      (project, repositoryNames) <- projectParams userId requestParams
      Entity projectId _ <- withDatabase (getBy (UniqueProjectNameByUser userId existingProjectName))
                              `orException` MissingProject existingProjectName
      withDatabase $ do
        replace projectId project
        Sql.delete $ from $ \repository -> where_ (repository ^. ProjectRepositoryProjectId ==. val projectId)
        mapM_ (insert . ProjectRepository projectId) repositoryNames
        return (user, project)

    projectParams userId requestParams = do
      projectName <- textParam "project-name" requestParams
      repositoryNames <- textListParam "repository-names[]" requestParams
      let project = Project userId projectName
      return (project, repositoryNames)

    fetchGitHubUser accessToken =
      fetch accessToken "https://api.github.com/user"

    fetchGitHubPullRequests accessToken repositoryName =
      fetch accessToken $ mconcat ["https://api.github.com/repos/", encodeUtf8 repositoryName, "/pulls"]

    fetch accessToken =
      withExceptT (QueryFailure . decodeUtf8 . toStrict)
        . ExceptT . liftIO . authGetJSON httpManager accessToken

    readAccessToken :: ExceptT Exception Context AccessToken
    readAccessToken = do
      userId <- readUserId
      let userService = UserService userId GitHub
      (Entity _ (ServiceCredentials _ _ _ accessToken)) <- withDatabase (getBy userService) `orException` MissingUser
      return $ AccessToken accessToken Nothing Nothing Nothing Nothing

    readUserId :: ExceptT Exception Context UserId
    readUserId = readSession `orException` UnauthenticatedUser

    readUser :: ExceptT Exception Context (Entity User)
    readUser = do
      userId <- readUserId
      user <- withDatabase (Database.get userId) `orException` MissingUser
      return $ Entity userId user

    readUserByName :: Text -> ExceptT Exception Context (Entity User)
    readUserByName username = do
      userId <- readUserId
      users <- withDatabase $
        select $ from $ \user -> do
          where_ (user ^. UserId ==. val userId &&. user ^. UserUsername ==. val username)
          return user
      return (listToMaybe users) `orException` QueryFailure "Invalid user."

    readMyProjects :: Key User -> User -> ExceptT Exception Context [MyProject]
    readMyProjects userId user = do
      projectsAndRepositoryEntities <- withDatabase $
        select $ from $ \(project `LeftOuterJoin` repository) -> do
          on (just (project ^. ProjectId) ==. repository ?. ProjectRepositoryProjectId)
          where_ (project ^. ProjectUserId ==. val userId)
          orderBy [asc (project ^. ProjectName), asc (repository ?. ProjectRepositoryName)]
          return (project, repository)
      let projectsAndRepositories = map (\(p, r) -> (entityVal p, entityVal <$> r)) projectsAndRepositoryEntities
      let groupedProjectsAndRepositories = groupQueryBy fst snd projectsAndRepositories
      let myProject project repositories = MyProject (projectName project) (projectUrl user project) (map projectRepositoryName (catMaybes repositories))
      return $ map (uncurry myProject) groupedProjectsAndRepositories

    readProject :: User -> Text -> ExceptT Exception Context MyProject
    readProject user projectName = do
      projectAndRepositories :: [(Entity Project, Maybe (Entity ProjectRepository))] <- withDatabase $
        select $ from $ \(project `LeftOuterJoin` repository) -> do
          on (just (project ^. ProjectId) ==. repository ?. ProjectRepositoryProjectId)
          where_ (project ^. ProjectName ==. val projectName)
          orderBy [asc (repository ?. ProjectRepositoryName)]
          return (project, repository)
      project <- return (entityVal . fst <$> listToMaybe projectAndRepositories)
                   `orException` QueryFailure "Invalid project."
      let repositories = map entityVal $ mapMaybe snd projectAndRepositories
      return $ MyProject projectName (projectUrl user project) (map projectRepositoryName repositories)

    renderMe user projects = render (Me user projects)

    render value = json (AuthenticatedResponse value)

    textParam :: Monad a => Text -> [(Text, Text)] -> ExceptT Exception a Text
    textParam name params = return (lookup name params) `orException` MissingParam name

    textListParam :: Monad a => Text -> [(Text, Text)] -> ExceptT Exception a [Text]
    textListParam name params = return values `onEmpty` MissingParam name
      where
        values = filter (/= "") $ map snd $ filter ((== name) . fst) params

    orException :: Monad m => m (Maybe a) -> e -> ExceptT e m a
    maybe `orException` exception = maybeToExceptT exception (MaybeT maybe)

    onEmpty :: Monad m => m [a] -> e -> ExceptT e m [a]
    list `onEmpty` exception = ExceptT ((\l -> when (null l) (Left exception) >> Right l) <$> list)

    handleException UnauthenticatedUser =
      json unauthenticatedResponse
    handleException MissingUser =
      json unauthenticatedResponse
    handleException (MissingProject project) = do
      setStatus badRequest400
      errorJson "missing project" ["project" .= project]
    handleException (MissingParam param) = do
      setStatus badRequest400
      errorJson "missing param" ["param" .= param]
    handleException (InvalidAuthenticationCode message) = do
      setStatus badRequest400
      errorJson "invalid authentication code" ["message" .= message]
    handleException (QueryFailure message) = do
      setStatus internalServerError500
      errorJson "internal failure" ["message" .= message]

    errorJson message extras = json $ object (("error" .= (message :: Text)) : extras)

    gitHubOAuthCredentials = configurationGitHubOAuthCredentials configuration

    spockConfiguration = (defaultSpockCfg Nothing PCNoDatabase ()) {
      spc_sessionCfg = (defaultSessionCfg Nothing) {
        sc_sessionTTL = configurationSessionTTL configuration,
        sc_sessionExpandTTL = True,
        sc_housekeepingInterval = configurationSessionStoreInterval configuration,
        sc_persistCfg = Just sessionPersistenceConfiguration
      }
    }

    sessionPersistenceConfiguration :: SessionPersistCfg (Maybe UserId)
    sessionPersistenceConfiguration = SessionPersistCfg {
      spc_load =
        map (\(Entity _ (Session sessionId expiryTime value)) -> (sessionId, expiryTime, Just value))
          <$> withDatabase (select $ from return),
      spc_store = \sessions -> withDatabase $ do
        existingSessionsById <- foldr (\s a -> Map.insert ((sessionSessionId . entityVal) s) s a) Map.empty <$> (select $ from return)
        let databaseSessions = mapMaybe (\(sessionId, expiryTime, value) -> Session sessionId expiryTime <$> value) sessions
        let entities = map (\session@(Session sessionId _ _) -> (Map.lookup sessionId existingSessionsById, session)) databaseSessions
        let (sessionsToUpdate, sessionsToInsert) = List.partition (isJust . fst) entities
        insertedKeys <- insertMany (map snd sessionsToInsert)
        forM_ sessionsToUpdate $ \(Just (Entity key oldValue), newValue) ->
          unless (oldValue == newValue) (replace key newValue)
        let updatedKeys = map (entityKey . fromJust . fst) sessionsToUpdate
        Sql.delete $ from $ \session ->
          where_ (session ^. SessionId `notIn` valList (insertedKeys ++ updatedKeys))
    }

    withDatabase :: MonadIO m => SqlPersistM a -> m a
    withDatabase = flip liftSqlPersistMPool databaseConnectionPool

readConfiguration =
  Configuration
    <$> readEnv "PORT"
    <*> getEnv "CLIENT_PATH"
    <*> (OAuth2
      <$> byteStringEnv "GITHUB_OAUTH_CLIENT_ID"
      <*> byteStringEnv "GITHUB_OAUTH_CLIENT_SECRET"
      <*> pure "https://github.com/login/oauth/authorize?scope=user:email%20repo"
      <*> pure "https://github.com/login/oauth/access_token"
      <*> pure Nothing)
    <*> do
      host <- getEnv "DATABASE_HOST"
      port <- getEnv "DATABASE_PORT"
      database <- getEnv "DATABASE_DASHBOARD_NAME"
      username <- getEnv "DATABASE_DASHBOARD_USERNAME"
      password <- getEnv "DATABASE_DASHBOARD_PASSWORD"
      return $ ByteStringC.pack $ unwords $ map (\(key, value) -> key ++ "='" ++ value ++ "'") [
        ("host", host),
        ("port", port),
        ("dbname", database),
        ("user", username),
        ("password", password)]
    <*> readEnv "DATABASE_POOL_SIZE"
    <*> (fromInteger <$> readDefaultedEnv "SESSION_TTL" 3600)
    <*> (fromInteger <$> readDefaultedEnv "SESSION_STORE_INTERVAL" 10)
  where
    byteStringEnv name = ByteStringC.pack <$> getEnv name

    readEnv :: Read a => String -> IO a
    readEnv name = do
      value <- getEnv name
      readIO value `catchIOError` \theError -> do
        putStrLn $ "Failed to parse the variable " ++ name ++ " with the value \"" ++ value ++ "\"."
        ioError theError

    readDefaultedEnv :: Read a => String -> a -> IO a
    readDefaultedEnv name defaultValue = do
      value <- lookupEnv name
      maybe (return defaultValue) (\value ->
        readIO value `catchIOError` \theError -> do
          putStrLn $ "Failed to parse the variable " ++ name ++ " with the value \"" ++ value ++ "\"."
          ioError theError
        ) value

groupQueryBy :: Eq k => (v -> k) -> (v -> w) -> [v] -> [(k, [w])]
groupQueryBy keyFunction valueFunction list =
  map (\g -> (keyFunction (List.head g), map valueFunction g)) grouped
  where
    grouped = List.groupBy ((==) `Function.on` keyFunction) list

(|>) = flip ($)
