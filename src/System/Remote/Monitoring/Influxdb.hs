{-# LANGUAGE OverloadedStrings #-}

-- | This module lets you periodically flush metrics to a influxdb
-- backend. Example usage:
--
-- > main = do
-- >   store <- newStore
-- >   forkInfluxdb defaultInfluxdbOptions store
--
-- You probably want to include some of the predefined metrics defined
-- in the @ekg-core@ package, by calling e.g. the 'EKG.registerGcMetrics'
-- function defined in that pacakge.
--
-- NOTE: This package has been modelled after the @ekg-carbon@ package, and
--       is almost identical. The author is indebted to those fine folks who
--       wrote the @ekg-carbon@ package.

module System.Remote.Monitoring.Influxdb
  ( InfluxdbOptions(..)
  , defaultInfluxdbOptions
  , forkInfluxdb
  , forkInfluxdbRestart
  ) where

import Data.Monoid ((<>))
import Data.Time.Clock as Time (getCurrentTime, diffUTCTime, UTCTime)
import qualified Data.Text as T
import qualified System.Metrics as EKG
import qualified System.Metrics.Distribution as Stats
import qualified Data.Map as M
import qualified Data.Vector as V
import qualified Database.InfluxDB as Influxdb
import Control.Exception (SomeException, try, bracket)
import Control.Concurrent (ThreadId, forkIO, myThreadId, threadDelay, throwTo)
import Control.Monad (forever)
import qualified Data.HashMap.Strict as HashMap
import Control.Lens ((&), (.~))
import Data.String (fromString)

--------------------------------------------------------------------------------
-- | Options to control how to connect to the Influxdb server and how often to
-- flush metrics. The flush interval should match the shortest retention rate of
-- the matching retention periods, or you risk over-riding previous samples.
data InfluxdbOptions = InfluxdbOptions
  { -- | The hostname or IP address of the server running influxdb
    host :: !T.Text
    -- | Server port of the TCP line receiver interface.
  , port :: !Int
    -- | The Influxdb database name
  , database :: !T.Text
    -- | The amount of time between sampling EKG metrics and pushing to Influxdb.
  , flushInterval :: !Int
    -- | Prefix to add to all matric names.
  , prefix :: !T.Text
    -- | Suffix to add to all metric names. This is particularly
    -- useful for sending per host stats by settings this value to:
    -- @takeWhile (/= \'.\') \<$\> getHostName@, using @getHostName@
    -- from the @Network.BSD@ module in the network package.
  , suffix :: !T.Text
  } deriving (Eq, Show)

--------------------------------------------------------------------------------
-- | Defaults
--
-- * @host@ = @\"127.0.0.1\"@
--
-- * @port@ = @8086@
--
-- * @flushInterval@ = @1000@
--
-- * Empty 'database', 'prefix' and 'suffix'.
defaultInfluxdbOptions :: InfluxdbOptions
defaultInfluxdbOptions = InfluxdbOptions
    { host          = "127.0.0.1"
    , port          = 8086
    , database      = ""
    , flushInterval = 1000
    , prefix        = ""
    , suffix        = ""
    }

--------------------------------------------------------------------------------
-- | Create a thread that periodically flushes the metrics in 'EKG.Store' to
-- Influxdb. If the thread flushing statistics throws an exception (for example,
-- the network connection is lost), this exception will be thrown up to the thread
-- that called 'forkInfluxdb'. For more control, see 'forkInfluxdbRestart'.
forkInfluxdb :: InfluxdbOptions -> EKG.Store -> IO ThreadId
forkInfluxdb opts store =
  do parent <- myThreadId
     forkInfluxdbRestart opts
                         store
                         (\e _ -> throwTo parent e)

--------------------------------------------------------------------------------
-- | Create a thread that periodically flushes the metrics in 'EKG.Store' to
-- Influxdb. If the thread flushing statistics throws an exception (for example,
-- the network connection is lost), the callback function will be invoked with the
-- exception that was thrown, and an 'IO' computation to restart the handler.
--
-- For example, you can use 'forkInfluxdbRestart' to log failures and restart
-- logging:
--
-- > forkInfluxdbRestart defaultInfluxdbOptions
-- >                     store
-- >                     (\ex restart -> do hPutStrLn stderr ("ekg-influxdb: " ++ show ex)
-- >                                        restart)
forkInfluxdbRestart :: InfluxdbOptions
                    -> EKG.Store
                    -> (SomeException -> IO () -> IO ())
                    -> IO ThreadId
forkInfluxdbRestart opts store exceptionHandler = forkIO go
  where
    params = (Influxdb.writeParams (fromString . T.unpack $ database opts))
             & Influxdb.server . Influxdb.host .~ (fromString . T.unpack $ host opts)
             & Influxdb.server . Influxdb.port .~ (port opts)
    go = do
        terminated <-
          try $ bracket
          (return params)
          (\_ -> return ())
          (loop store opts)
        case terminated of
          Left exception -> exceptionHandler exception go
          Right _ -> go

--------------------------------------------------------------------------------
loop :: EKG.Store -> InfluxdbOptions -> Influxdb.WriteParams -> IO ()
loop store opts params = forever $ do
  start <- getCurrentTime
  sample <- EKG.sampleAll store
  flushSample sample params opts
  end <- getCurrentTime
  let diff :: Int
      diff = truncate (diffUTCTime end start * 1000)
  threadDelay (flushInterval opts * 1000 - diff)

flushSample :: EKG.Sample -> Influxdb.WriteParams -> InfluxdbOptions -> IO ()
flushSample sample params opts = do
  t <- getCurrentTime
  sendMetrics params
    (V.map renamed
      (HashMap.foldlWithKey' (\ms k v -> metrics k v t <> ms)
        V.empty
        sample))

  where
  renamed (Metric n v t) =
    let p = if T.null (prefix opts) then "" else prefix opts <> "."
        s = if T.null (suffix opts) then "" else "." <> suffix opts
    in Metric (p <> n <> s) v t

  metrics n (EKG.Counter i) t = V.singleton (Metric ("counter." <> n) (fromIntegral i) t)
  metrics n (EKG.Gauge i) t = V.singleton (Metric ("gauge." <> n) (fromIntegral i) t)
  metrics _ (EKG.Label {}) _ = V.empty
  metrics n (EKG.Distribution stats) t =
    let f n' v = Metric ("dist." <> n <> "." <> n') v t
    in V.fromList [ f "variance" (Stats.variance stats)
                  , f "count" (fromIntegral $ Stats.count stats)
                  , f "sum" (Stats.sum stats)
                  , f "min" (Stats.min stats)
                  , f "max" (Stats.max stats)
                  ]

data Metric = Metric
  { path  :: !T.Text
  , value :: !Double
  , timestamp :: !UTCTime
  } deriving (Show)

sendMetrics :: Influxdb.WriteParams -> V.Vector Metric -> IO ()
sendMetrics params metrics = V.forM_ metrics $ \metric -> do
  let tags   = M.empty
      values = M.singleton "value" (Influxdb.FieldFloat (value metric))
    in Influxdb.write params $ Influxdb.Line (fromString . T.unpack $ path metric) tags values (Just (timestamp metric))
