{-# LANGUAGE NumericUnderscores #-}

module CLI (
  Opts (..),
  optsParser,
) where

import Cardano.Ledger.Binary (mkVersion64)
import Cardano.Ledger.Plutus.Evaluate
import Options.Applicative
import Text.Read (readMaybe)

data Opts = Opts
  { optsScriptWithContext :: !String
  , optsTimeout :: !Int
  , optsOverrides :: !PlutusDebugOverrides
  }
  deriving (Show)

overridesParser :: Parser PlutusDebugOverrides
overridesParser =
  PlutusDebugOverrides
    <$> option
      (Just <$> str)
      ( long "script"
          <> short 's'
          <> value Nothing
          <> help "Plutus script hex without context"
      )
    <*> option
      (mkVersion64 <$> auto)
      ( long "protocol-version"
          <> short 'v'
          <> value Nothing
          <> help "Major protocol version"
      )
    <*> option
      (Just <$> auto)
      ( long "language"
          <> short 'l'
          <> value Nothing
          <> help "Plutus language version"
      )
    <*> option
      (mapM readMaybe . words <$> str)
      ( long "cost-model-values"
          <> short 'c'
          <> value Nothing
          <> help ""
      )
    <*> option
      (Just <$> auto)
      ( long "execution-units-memory"
          <> value Nothing
          <> help ""
      )
    <*> option
      (Just <$> auto)
      ( long "execution-units-steps"
          <> value Nothing
          <> help ""
      )
    <*> switch
      ( long "enforce-execution-units"
          <> help
            ( "By default plutus-debug upon a failure will re-evaluate supplied script one more time "
                <> "without bounding execution in order to report expected execution units. "
                <> "In case when this unbounded computation is a problem, this flag allows for "
                <> "disabling this reporting of expected execution units."
            )
      )

optsParser :: Parser Opts
optsParser =
  Opts
    <$> strArgument (metavar "SCRIPT_WITH_CONTEXT(BASE64)")
    <*> option
      auto
      ( long "timeout"
          <> short 't'
          <> value 5_000_000
          <> help
            ( "Timeout in number of milliseconds. Default is 5000000 ms (or 5 seconds). "
                <> "Specifying a negative number will effectively remove the timeout and unbound execution."
            )
      )
    <*> overridesParser
