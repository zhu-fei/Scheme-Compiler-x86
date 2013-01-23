{-# LANGUAGE OverloadedStrings, NamedFieldPuns #-}
module FrameworkHs.Driver
  -- ( runWrapper
  -- , runPass
  -- )
  where

import System.Process                  (runInteractiveCommand, terminateProcess, readProcess, readProcessWithExitCode)
import System.IO                       (stderr, hGetContents, hPutStrLn, hClose, hFlush, hReady, 
                                        Handle, BufferMode(..), hSetBuffering, hIsClosed, hIsReadable)
import System.Exit                     (ExitCode(..))
import Control.Monad                   (when)
import Control.Exception               (throw, catch, SomeException)

import Control.Monad.State.Strict      (StateT, evalStateT, get, put, lift)

import Data.ByteString                 (ByteString, hPut, hGetNonBlocking, hGetLine, concat, writeFile)
import Data.ByteString.Char8           (unpack)
import Data.Monoid                     (mconcat, (<>))
import Data.String                     (IsString(..))
import Prelude as P                    hiding (concat, writeFile)

import Blaze.ByteString.Builder        (Builder, toByteString)
import qualified Blaze.ByteString.Builder.Char8  as BBB

import FrameworkHs.SExpReader.Parser   (readExpr)
import FrameworkHs.SExpReader.LispData (LispVal)
import FrameworkHs.Prims               ()
import FrameworkHs.Helpers             

--------------------------------------------------------------------------------
-- Building and running compilers

-- The compiler monad:
-- type CompileM = StateT CompileState PassM
type CompileM = StateT CompileState IO

-- | The compiler tracks extra state.  
data CompileState =
  CompileState { -- | The result of the previous wrapper, if any.
                 lastresult :: Maybe ByteString,
                 -- | The persistent scheme process for running wrappers
                 runner :: SchemeProc,
                 cfg :: P423Config }

-- | Run a P423 compiler.
runCompiler :: P423Config -> CompileM a -> IO a
runCompiler cfg m = do 
  sp <- makeSchemeEvaluator
  -- return$ runPassM cfg $
  --   evalStateT m (CompileState Nothing sp)
  evalStateT m (CompileState Nothing sp cfg)

-- | Run an individiual pass, converting an input language to an output language.
runPass :: PP b => P423Pass a b -> a -> CompileM b
runPass p code =
    do CompileState {cfg} <- get 
       let code' = pass p cfg code
       _res <- lift$ runWrapper wn code'
       when (trace p) (lift$ printTrace (passName p) code')
       return code'

  where pn = passName p
        wn = wrapperName p
        printTrace :: PP a => String -> a -> IO ()
        printTrace name code = putStrLn ("\n" ++ name ++ ": \n" ++ (unpack $ toByteString $ pp code) ++ "\n")

liftPassM :: PassM a -> CompileM a
liftPassM m = do
  CompileState {cfg} <- get 
  return (runPassM cfg m)

-- | The last step in a compiler (after a series of `runPass`s).
--   Take a bundle of emitted output text representing assembly code.
--   Compile and run the assembly and return the result.
assemble :: Gen -> CompileM String
assemble out = do
  CompileState {cfg} <- get 
  lift$ 
   case runGenM cfg out of
    Left err -> error err
    Right (_,bsout) -> do  
      writeFile "t.s" bsout
      (ec,_,e) <- readProcessWithExitCode assemblyCmd assemblyArgs ""
      case ec of
        ExitSuccess   -> do res <- readProcess "./t" [] ""
                            return (chomp res)
        ExitFailure i -> throw (AssemblyFailedException e)

assemblyCmd :: String
assemblyCmd = "cc"
assemblyArgs :: [String]
assemblyArgs = ["-m64","-o","t","t.s","Framework/runtime.c"]

--------------------------------------------------------------------------------
-- Child Scheme processes

-- | Which Chez Scheme should we use?
scheme :: String
scheme = "petite -q --eedisable"

-- | Tell a scheme process to load the necessary libraries.
loadFramework :: Handle -> IO ()
loadFramework = flip hPutStrLn "(import (Framework driver) (Framework wrappers))"

-- | A `Wrapper` is the name of the language-wrapper (a
-- Scheme-identifier).  That is, the thing that makes the Scheme
-- intermediate representation directly executable in Scheme.
type WrapperName = String

type PassName = String

-- | An interactive scheme process that can evaluate an unlimited
-- number of expressions before being shut down (NOT threadsafe).
data SchemeProc = SchemeProc {
  eval :: ByteString -> IO LispVal,
  shutdown :: IO () }

-- TODO: Implement a timeout:
makeSchemeEvaluator :: IO SchemeProc
makeSchemeEvaluator = do
  (ip,op,ep,pid) <- runInteractiveCommand scheme
  hSetBuffering ep NoBuffering
  hSetBuffering ip LineBuffering
  loadFramework ip
  let shutdown = terminateProcess pid
      -- Shutdown the child process if anything goes wrong:
      wrap io = catch io $ \e -> do
                  hPutStrLn stderr " [Exception!  Shutting down child scheme proccess ]"
                  shutdown
                  throw (e::SomeException)
      eval bstr = wrap$ do
        -- Interaction protocol:  Write expressions, read results delimited by blank lines.
        hPut ip bstr
        hPut ip $ toByteString $ app "newline" []
        hPut ip "\n"
        hFlush ip
        ----------------------------------------
        getRespose
      getRespose = do  
        err <- hGetNonBlocking ep 4096
        -- let err = ""
        if err == "" then
          do lns <- readUntilBlank op
             -- There's a race when an error occurs:
             if lns == "" then waitFor 10000 ep >> getRespose
              else case readExpr (unpack lns) of
                    Left er   -> error $ show er
                    Right lsp -> return lsp
        else
         do error$ "Error from child scheme process:\n"++unpack err
  return$ SchemeProc { eval, shutdown } 



runWrapper :: PP a => WrapperName -> a -> IO LispVal
runWrapper wrapper code =
  do (i,o,e,pid) <- runInteractiveCommand scheme
     loadFramework i
     hPut i $ toByteString $ app (fromString wrapper) [quote code]
     hClose i
     eOut <- hGetContents e
     if (eOut == "")
        then (do oOut <- hGetContents o
                 terminateProcess pid
                 return $
                   (case (readExpr oOut) of
                     Left er   -> error $ show er
                     Right cde -> cde))
        else (do terminateProcess pid
                 error eOut)



--------------------------------------------------------------------------------
-- SExp construction helpers

app :: Builder -> [Builder] -> Builder
app rator rands = "(" <> rator <>
                  mconcat (map (" " <>) rands) <>
                  ")"

quote :: PP a => a -> Builder
quote e = app "quote" [ pp e ]

----------------------------------------

instance IsString Builder where
  fromString = BBB.fromString


readUntilBlank :: Handle -> IO ByteString
readUntilBlank hnd = loop []
 where
   loop acc = do
     l <- hGetLine hnd
     case l of
       "" -> return (concat (reverse acc))       
       ll -> loop (ll:acc)

-- This is a hack for waiting through races between different handles.
waitFor 0 h = error$"Expected output on handle "++show h++" but after waiting a while saw nothing."
waitFor tries hnd = do
  b <- hReady hnd
  if b then return ()
       else waitFor (tries-1) hnd

--------------------------------------------------------------------------------
-- Unit tests

-- Evaluate just one expression:
t0 :: IO String
t0 = do SchemeProc{eval,shutdown} <- makeSchemeEvaluator
        a <- eval "(+ 1 2)"
        shutdown
        return$ show a

-- Evaluate multiple expressions:
t1 :: IO (String,String,String)
t1 = do SchemeProc{eval,shutdown} <- makeSchemeEvaluator
        a <- eval "(+ 1 2)"
        b <- eval "(cons '1 '(2 3))"
        c <- eval "(vector 'a 'b 'c)"
        shutdown
        return (show a, show b, show c)

-- This one intentionally creates an error.
t2 :: IO String
t2 = catchit
 where
   catchit = catch io $ \e -> return$ show (e::SomeException)
   io = 
    do SchemeProc{eval,shutdown} <- makeSchemeEvaluator
       a <- eval "(make-vector 1 2 3)"
       shutdown
       return$ show a

-- "Error from child scheme process:\nException: incorrect number of arguments to #<procedure make-vector>\n"
