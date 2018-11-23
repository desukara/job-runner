module Desukara.JobTypes.RScript (
    runRScriptJob
) where

import DbLib
import DbLib.JobManagerDb.Jobs
import Desukara.FirejailRunner

import Control.Concurrent.Chan
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception
import Data.List (intercalate)
import System.Process
import System.Directory
import System.FilePath.Posix
import System.Exit

rJobOutput = defaultOutput {
    description = "",
    footer = Just "R Script Job"
}

rHeader = intercalate "\n"
    [ "library(anytime)"
    , "Messages <- read.table(\"data/messages.csv\", header=TRUE, sep=\",\")" 
    , "if (nrow(Messages) == 0) { stop(\"No data found (channel is either not enabled or is scheduled for future indexing).\") }"
    , "Channels <- read.table(\"data/channels.csv\", col.names = c(\"channelId\", \"channelName\"), sep=\",\")"
    , "Messages$messageId <- lapply(Messages$messageId, as.character)"
    , "Messages$messageLastIndexed <- anytime(Messages$messageLastIndexed)"
    , "Messages$messageChannel <- lapply(Messages$messageChannel, as.character)"
    , "Messages$messageChannelName <- with(Channels, channelName[match(Messages$messageChannel, Channels$channelId)])"
    , "Messages$messageGuild <- lapply(Messages$messageGuild, as.character)" 
    , "Messages$messageAuthor <- lapply(Messages$messageAuthor, as.character)"
    , "Messages$messageTimestamp <- anytime(Messages$messageTimestamp)"
    , "Messages$messageEditedTimestamp <- anytime(Messages$messageEditedTimestamp)"
    , "png(\"output/default.png\", width=800, height=600, pointsize=16)"
    , ""
    ]

runRScriptJob :: DbContext -> Job -> IO ()
runRScriptJob ctx job =
    do
        let jobid = jobId job
            requestedData = jobRequestedChannelData job
            requestedDataFrom = jobRequestedChannelDataFrom job
            requestedDataTo = jobRequestedChannelDataUntil job
            rs = jobParameters job
            script = rHeader ++ rsScript rs

        setJobStatus Running ctx jobid
        setJobOutput rJobOutput {
            description = "Crunching numbers, please wait..."
            
        } ctx jobid
        setJobDirty True ctx jobid

        let init path = do
                writeFile ("/tmp/script.r") script -- debug purposes
                writeFile (path ++ "script.r") script

        (stdout, finished) <- firejailRunner 
            ctx (zip3 requestedData requestedDataFrom requestedDataTo)   
            "Rscript" ["--slave", "./script.r"] init

        let updateLoop = 
                do
                    line <- readChan stdout
                    putStrLn (take 50 line)
                    setJobOutput rJobOutput {
                        description = "Crunching numbers...\n",
                        inlineTitles = ["Log"],
                        inlineText = ["```\n" ++ line ++ "\n```"]
                    } ctx jobid
                    setJobDirty True ctx jobid
                    updateLoop
        -- todo figure out why this isn't printing?

        thread <- forkIO updateLoop
        (path, log, exitcode) <- readChan finished -- block until finished
        killThread thread
       
        -- todo configurable
        let excerpt = "```\n" ++ (take 256 $ intercalate "\n" log) ++ "```\n"

        -- stat & upload images
        let outputDirectory = path ++ "output/"
        filePaths <- fmap (map (outputDirectory ++)) $ listDirectory outputDirectory
        let plots = filter (\x -> takeExtension x == ".png") filePaths

        mapM_ (\plot -> 
                createProcess (shell $ "scp -o ConnectTimeout=10 -i /etc/desukara/uploads.key "
                            ++ plot ++ " desukara@lolc.at:/var/www/uploads.lolc.at/" ++ jobid ++ takeFileName plot)) plots -- todo configurable

        threadDelay (1 * 10^6) -- todo: check for completion of transfer...

        -- todo configurable
        let urls = map (\x -> "https://uploads.lolc.at/" ++ jobid ++ takeFileName x) plots 

        case exitcode of
           ExitSuccess -> do
                maybeResult <- try (readFile $ path ++ "output/result.txt") 
                    :: IO (Either SomeException String)
                case maybeResult of
                    Left _ -> do
                        setJobOutput rJobOutput {
                            imageUrls = urls,
                            inlineTitles = ["Job finished!"],
                            inlineText = [ "**Raw Output:** (first 256 chars)\n" 
                                        ++ excerpt
                                        ++ "*hint: write your human-readable results to `output/result.txt`...*\n\n"]
                        } ctx jobid
                        setJobStatus Finished ctx jobid
                    Right result -> do

                        -- post
                        setJobOutput rJobOutput {
                            imageUrls = urls,
                            inlineTitles = ["Success!"],
                            inlineText = [result]
                        } ctx jobid
                        setJobStatus Finished ctx jobid
           ExitFailure _ -> do
                setJobOutput rJobOutput {
                    inlineTitles = ["Uh oh!"],
                    inlineText = ["The interpreter died...\n"
                               ++ "**Errors:**\n"
                               ++ excerpt ]
                } ctx jobid
                setJobStatus Failed ctx jobid

        threadDelay (1 * 10^6)
        setJobDirty True ctx jobid

        -- cleanup
        removePathForcibly path

