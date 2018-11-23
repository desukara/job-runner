module Desukara.FirejailRunner (
   firejailRunner 
) where

import DbLib
import DbLib.GuildDataDb.Messages
import DbLib.GuildDataDb.Channels

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan
import Control.Concurrent.MVar
import Control.Concurrent.Async 
import qualified Data.ByteString.Lazy.Char8 as B
import Data.List (intercalate)
import Data.Time.Clock
import Data.UUID.V4
import Data.Csv 
import System.Directory
import System.Process
import System.Exit (ExitCode)
import GHC.IO.Handle

type DataRequest = (DataChannel, DataFrom, DataUntil)
type DataChannel = String
type DataFrom = Maybe UTCTime
type DataUntil = Maybe UTCTime

type ProgramPath = String
type ProgramArg = String
type OutputDirectory = String

type StdOut = String
type Finished = (Directory, Log, ExitCode)
type Directory = String 
type Log = [String]

firejailRunner  :: DbContext 
                -> [DataRequest]
                -> ProgramPath -> [ProgramArg]
                -> (OutputDirectory -> IO ())
                -> IO (Chan StdOut, Chan Finished)
firejailRunner ctx 
               datareqs
               program args
               init
    = do
        stdout <- newChan
        finished <- newChan

        let run = 
                do                 -- prepare environment
                uuid <- nextRandom 
                let rootDirectory = "desukara-chroot-" ++ show uuid ++ "/"
                    rootDirectoryPath = "/tmp/" ++ rootDirectory

                    dataDirectory = "data/"
                    dataDirectoryPath = rootDirectoryPath ++ dataDirectory

                    outputDirectory = "output/"
                    outputDirectoryPath = rootDirectoryPath ++ outputDirectory

                createDirectory rootDirectoryPath
                createDirectory dataDirectoryPath
                createDirectory outputDirectoryPath

                -- populate data folder 
                msgQ <- mapM (\(chan, from, until) -> 
                                queryChannelRange ctx chan from until) datareqs

                chanQ <- getActiveChannels ctx

                let msgs = concat msgQ
                    msgsEncoded = encodeDefaultOrderedByNameWith (defaultEncodeOptions {
                        encUseCrLf = False,
                        encIncludeHeader = True,
                        encQuoting = QuoteAll
                    }) msgs 

                    queriedChannels = map (\(chan, _, _) -> chan) datareqs
                    channels = filter (\c -> channelId c `elem` queriedChannels) chanQ
                    channelsEncoded = B.pack $ 
                        concatMap (\chan -> "\"" ++ channelId chan   ++ "\","
                                         ++ "\"" ++ channelName chan ++ "\"\n") channels 

                B.writeFile "/tmp/channels.csv" channelsEncoded
                B.writeFile "/tmp/messages.csv" msgsEncoded

                B.writeFile (dataDirectoryPath ++ "channels.csv") channelsEncoded 
                B.writeFile (dataDirectoryPath ++ "messages.csv") msgsEncoded

                -- run provided init
                init rootDirectoryPath

                -- run program in firejail
                let fireJailFlags =
                        [   "--noprofile" 
                        -- ,   "--rlimit-as=" ++ show (512 * 10^6) -- 512mb virtual memory
                        ,   "--rlimit-cpu=" ++ show 10 -- 10s cpu time limit
                        ,   "--rlimit-fsize=" ++ show (5 * 10^6) -- 5mb max file creation
                        ,   "--net=none"
                        ,   "--private-dev"
                        ,   "--private-tmp"
                        ,   "--blacklist=/tmp"
                        ,   "--private-etc=fonts"
                        ,   "--private=" ++ rootDirectoryPath
                        ,   "--quiet"
                        ]

                    locale = "export LC_ALL=C;"

                    bash =
                        [   "bash",
                            "-c",
                            locale ++ (intercalate " " $ [program] ++ args)
                        ]

                (_, Just hout, Just herr, ph) <- createProcess
                    (proc "firejail" $ fireJailFlags ++ bash) 
                    { cwd = Just rootDirectoryPath,
                      std_out = CreatePipe,
                      std_err = CreatePipe
                    }

                blackbox <- newMVar []

                let readLoop handle = do
                        blackboxOld <- takeMVar blackbox
                        isEOF <- hIsEOF handle 

                        if not isEOF 
                        then do
                            line <- hGetLine handle 
                            writeChan stdout line
                            putMVar blackbox (blackboxOld ++ [line])

                            readLoop handle
                        else do
                            putMVar blackbox blackboxOld
                            return ()

                stdoutLoop <- async $ readLoop hout
                stderrLoop <- async $ readLoop herr

                forkIO $ do 
                            exitcode <- waitForProcess ph
                            wait stdoutLoop
                            wait stderrLoop
                            log <- takeMVar blackbox
                            writeChan finished (rootDirectoryPath, log, exitcode)

                return ()
        forkIO run
        return (stdout, finished)

