module Main where

import qualified Data.Text as T 
import qualified Data.Text.IO as TIO

import DbLib
import DbLib.JobManagerDb.Jobs

import Desukara.JobTypes.RScript

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan
import System.Environment (getArgs)

type JobRunnerId = Int

main :: IO ()
main = do
  args <- getArgs
  let ourId = read $ head args

  e <- connect (T.pack "jobrunner.cfg")
  case e of
    Left _ -> putStrLn "Could not connect"
    Right ctx -> mainLoop ctx ourId

mainLoop :: DbContext -> JobRunnerId -> IO ()
mainLoop ctx ourId =
  do
      jobs <- getAvailableJobs ctx ourId 

      if length jobs > 0
      then do
        let selectedJob = head jobs

        putStrLn "Starting job: " ++ show jobid ++ " ..." 

        case jobParameters selectedJob of
          RScript _ _ ->  runRScriptJob ctx selectedJob

        putStrLn "Job finished!" 

      else return ()

      threadDelay (1 * 10^6)
      mainLoop ctx ourId