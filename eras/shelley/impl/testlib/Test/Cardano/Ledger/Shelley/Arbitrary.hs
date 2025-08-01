{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- Due to Delegation usage
{-# OPTIONS_GHC -Wno-orphans -Wno-deprecations #-}

module Test.Cardano.Ledger.Shelley.Arbitrary (
  collectionDatumMaxSize,
  metadataMaxSize,
  genMetadata,
  genMetadata',
  genUtf8StringOfSize,
  RawSeed (..),
  ASC (..),
  StakeProportion (..),
  sizedNativeScriptGens,
) where

import qualified Cardano.Chain.UTxO as Byron
import Cardano.Ledger.BaseTypes
import Cardano.Ledger.Shelley (ShelleyEra)
import Cardano.Ledger.Shelley.API (
  ApplyTxError (ApplyTxError),
  MultiSig,
  ShelleyDelegCert,
  ShelleyTx (ShelleyTx),
  TxBody (ShelleyTxBody),
 )
import Cardano.Ledger.Shelley.Core
import Cardano.Ledger.Shelley.Genesis
import Cardano.Ledger.Shelley.LedgerState
import Cardano.Ledger.Shelley.PParams
import Cardano.Ledger.Shelley.PoolRank
import Cardano.Ledger.Shelley.RewardUpdate
import Cardano.Ledger.Shelley.Rewards (
  LeaderOnlyReward (..),
  PoolRewardInfo (..),
  StakeShare (..),
 )
import Cardano.Ledger.Shelley.Rules (
  PredicateFailure,
  ShelleyDelegPredFailure,
  ShelleyDelegsPredFailure,
  ShelleyDelplPredFailure,
  ShelleyLedgerPredFailure,
  ShelleyLedgersPredFailure,
  ShelleyPoolPredFailure (..),
  ShelleyPpupPredFailure,
  ShelleyUtxoPredFailure,
  ShelleyUtxowPredFailure,
  VotingPeriod,
 )
import Cardano.Ledger.Shelley.Scripts (
  ShelleyEraScript (..),
  pattern RequireAllOf,
  pattern RequireAnyOf,
  pattern RequireMOf,
  pattern RequireSignature,
 )
import Cardano.Ledger.Shelley.State
import Cardano.Ledger.Shelley.Transition
import Cardano.Ledger.Shelley.Translation (FromByronTranslationContext)
import Cardano.Ledger.Shelley.TxAuxData
import Cardano.Ledger.Shelley.TxCert (
  GenesisDelegCert (..),
  ShelleyTxCert,
 )
import Cardano.Ledger.Shelley.TxOut
import Cardano.Ledger.Shelley.TxWits (ShelleyTxWits (ShelleyTxWits))
import Control.Exception (assert)
import Control.Monad.Identity (Identity)
import qualified Data.ByteString.Char8 as BS (length, pack)
import qualified Data.ListMap as LM
import qualified Data.Map.Strict as Map (fromList)
import Data.Sequence.Strict (fromList)
import qualified Data.Text as T (pack)
import qualified Data.Text.Encoding as T (encodeUtf8)
import Data.Word (Word64)
import Generic.Random (genericArbitraryU)
import Test.Cardano.Chain.UTxO.Gen (genCompactTxOut)
import Test.Cardano.Ledger.Common
import Test.Cardano.Ledger.Core.Arbitrary ()
import Test.Cardano.Ledger.Core.Utils (unsafeBoundRational)
import Test.QuickCheck.Hedgehog (hedgehog)

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.PParams --------------------------------------------------------
------------------------------------------------------------------------------------------

instance Era era => Arbitrary (ShelleyPParams Identity era) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Era era => Arbitrary (ShelleyPParams StrictMaybe era) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance (Era era, Arbitrary (PParamsUpdate era)) => Arbitrary (ProposedPPUpdates era) where
  arbitrary = ProposedPPUpdates <$> scale (`div` 15) arbitrary

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.TxOut ----------------------------------------------------------
------------------------------------------------------------------------------------------

instance (EraTxOut era, Arbitrary (Value era)) => Arbitrary (ShelleyTxOut era) where
  arbitrary = ShelleyTxOut <$> arbitrary <*> scale (`div` 15) arbitrary

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.LedgerState ----------------------------------------------------
------------------------------------------------------------------------------------------

instance
  ( EraTxOut era
  , Arbitrary (TxOut era)
  , Arbitrary (Value era)
  , Arbitrary (PParams era)
  , Arbitrary (StashedAVVMAddresses era)
  , Arbitrary (GovState era)
  , Arbitrary (CertState era)
  , Arbitrary (InstantStake era)
  ) =>
  Arbitrary (NewEpochState era)
  where
  arbitrary =
    NewEpochState
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

instance
  ( EraTxOut era
  , Arbitrary (TxOut era)
  , Arbitrary (GovState era)
  , Arbitrary (CertState era)
  , Arbitrary (InstantStake era)
  ) =>
  Arbitrary (EpochState era)
  where
  arbitrary =
    EpochState
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
  shrink = genericShrink

instance
  ( EraTxOut era
  , Arbitrary (TxOut era)
  , Arbitrary (GovState era)
  , Arbitrary (CertState era)
  , Arbitrary (InstantStake era)
  ) =>
  Arbitrary (LedgerState era)
  where
  arbitrary =
    LedgerState
      <$> arbitrary
      <*> arbitrary
  shrink LedgerState {..} =
    -- We drop the first element in the list so the list does not contain the
    -- original LedgerState which would cause `shrink` to loop indefinitely.
    drop 1 $
      LedgerState
        <$> (lsUTxOState : shrink lsUTxOState)
        <*> (lsCertState : shrink lsCertState)

instance
  ( EraTxOut era
  , Arbitrary (TxOut era)
  , Arbitrary (GovState era)
  , Arbitrary (InstantStake era)
  ) =>
  Arbitrary (UTxOState era)
  where
  arbitrary =
    UTxOState
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary

  -- The 'genericShrink' function returns first the immediate subterms of a
  -- value (in case it is a recursive data-type), and then shrinks the value
  -- itself. Since 'UTxOState' is not a recursive data-type, there are no
  -- subterms, and we can use `recursivelyShrink` directly. This is particularly
  -- important when abstracting away the different fields of the ledger state,
  -- since the generic subterms instances will overlap due to GHC not having
  -- enough context to infer if 'a' and 'b' are the same types (since in this
  -- case this will depend on the definition of 'era').
  --
  -- > instance OVERLAPPING_ GSubtermsIncl (K1 i a) a where
  -- > instance OVERLAPPING_ GSubtermsIncl (K1 i a) b where
  shrink = recursivelyShrink

instance Arbitrary (ShelleyInstantStake era) where
  arbitrary = ShelleyInstantStake <$> arbitrary <*> arbitrary
  shrink = genericShrink

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.PoolRank -------------------------------------------------------
------------------------------------------------------------------------------------------

instance Arbitrary Likelihood where
  arbitrary = Likelihood <$> arbitrary

instance Arbitrary LogWeight where
  arbitrary = LogWeight <$> arbitrary

instance Arbitrary PerformanceEstimate where
  arbitrary = PerformanceEstimate <$> arbitrary

instance Arbitrary NonMyopic where
  arbitrary = NonMyopic <$> arbitrary <*> arbitrary
  shrink = genericShrink

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.Rewards --------------------------------------------------------
------------------------------------------------------------------------------------------
deriving newtype instance Arbitrary StakeShare

instance Arbitrary LeaderOnlyReward where
  arbitrary = LeaderOnlyReward <$> arbitrary <*> arbitrary
  shrink = genericShrink

instance Arbitrary PoolRewardInfo where
  arbitrary =
    PoolRewardInfo
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
  shrink = genericShrink

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.RewardUpdate ---------------------------------------------------
------------------------------------------------------------------------------------------

instance Arbitrary RewardUpdate where
  arbitrary =
    RewardUpdate
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
  shrink = genericShrink

instance Arbitrary RewardAns where
  arbitrary = RewardAns <$> arbitrary <*> arbitrary
  shrink = genericShrink

instance Arbitrary (RewardPulser ShelleyBase RewardAns) where
  arbitrary = RSLP <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary PulsingRewUpdate where
  arbitrary =
    oneof
      [ Pulsing <$> arbitrary <*> arbitrary
      , Complete <$> arbitrary
      ]
  shrink = genericShrink

instance Arbitrary RewardSnapShot where
  arbitrary =
    RewardSnapShot
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
  shrink = genericShrink

instance Arbitrary FreeVars where
  arbitrary =
    FreeVars
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
  shrink = genericShrink

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.Governance -----------------------------------------------------
------------------------------------------------------------------------------------------

instance Arbitrary (PParams era) => Arbitrary (FuturePParams era) where
  arbitrary = scale (`div` 10) genericArbitraryU

instance
  ( Era era
  , Arbitrary (PParamsUpdate era)
  , Arbitrary (PParams era)
  ) =>
  Arbitrary (ShelleyGovState era)
  where
  arbitrary = ShelleyGovState <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary
  shrink = genericShrink

------------------------------------------------------------------------------------------
-- Cardano.Ledger.Shelley.TxAuxData ------------------------------------------------------
------------------------------------------------------------------------------------------

-- | Max size of generated Metadatum List and Map
collectionDatumMaxSize :: Int
collectionDatumMaxSize = 5

-- | Max size of generated Metadata map
metadataMaxSize :: Int
metadataMaxSize = 3

-- | Generate ShelleyTxAuxData (and compute hash) with given frequency
genMetadata :: Era era => Int -> Gen (StrictMaybe (ShelleyTxAuxData era))
genMetadata metadataFrequency =
  frequency
    [ (metadataFrequency, SJust <$> genMetadata')
    , (100 - metadataFrequency, pure SNothing)
    ]

-- | Generate Metadata (and compute hash) of size up to 'metadataMaxSize'
genMetadata' :: Era era => Gen (ShelleyTxAuxData era)
genMetadata' = do
  n <- choose (1, metadataMaxSize)
  ShelleyTxAuxData . Map.fromList
    <$> vectorOf n genMetadatum

-- | Generate one of the Metadatum
genMetadatum :: Gen (Word64, Metadatum)
genMetadatum = do
  (,)
    <$> arbitrary
    <*> oneof
      [ genDatumInt
      , genDatumString
      , genDatumBytestring
      , genMetadatumList
      , genMetadatumMap
      ]

genDatumInt :: Gen Metadatum
genDatumInt =
  I
    <$> frequency
      [ (8, choose (minVal, maxVal))
      , (1, pure minVal)
      , (1, pure maxVal)
      ]
  where
    minVal, maxVal :: Integer
    minVal = -maxVal
    maxVal = fromIntegral (maxBound :: Word64)

genDatumString :: Gen Metadatum
genDatumString =
  sized $ \sz -> do
    n <- choose (0, min sz 64)
    cs <- genUtf8StringOfSize n
    let s = T.pack cs
    assert (BS.length (T.encodeUtf8 s) == n) $
      return (S s)

-- | Produce an arbitrary Unicode string such that it's UTF8 encoding size in
-- bytes is exactly the given length.
genUtf8StringOfSize :: Int -> Gen [Char]
genUtf8StringOfSize 0 = return []
genUtf8StringOfSize n = do
  cz <- choose (1, min n 4)
  c <- case cz of
    1 -> choose ('\x00000', '\x00007f')
    2 -> choose ('\x00080', '\x0007ff')
    3 ->
      oneof
        [ choose ('\x00800', '\x00d7ff')
        , -- skipping UTF-16 surrogates d800--dfff
          choose ('\x0e000', '\x00ffff')
        ]
    _ -> choose ('\x10000', '\x10ffff')
  cs <- genUtf8StringOfSize (n - cz)
  return (c : cs)

genDatumBytestring :: Gen Metadatum
genDatumBytestring =
  sized $ \sz -> do
    n <- choose (0, min sz 64)
    B . BS.pack <$> vectorOf n arbitrary

-- | Generate a 'MD.List [Metadatum]'
--
-- Note: to limit generated metadata size, impact on transaction fees and
-- cost of hashing, we generate only lists of "simple" Datums, not lists
-- of list or map Datum.
genMetadatumList :: Gen Metadatum
genMetadatumList = List <$> vectorOfMetadatumSimple

-- | Generate a 'MD.Map ('[(Metadatum, Metadatum)]')
genMetadatumMap :: Gen Metadatum
genMetadatumMap =
  Map <$> (zip <$> vectorOfMetadatumSimple <*> vectorOfMetadatumSimple)

vectorOfMetadatumSimple :: Gen [Metadatum]
vectorOfMetadatumSimple = do
  n <- choose (1, collectionDatumMaxSize)
  vectorOf
    n
    ( oneof
        [ genDatumInt
        , genDatumString
        , genDatumBytestring
        ]
    )

------------------------------------------------------------------------------------------
-- Era-independent generators ------------------------------------------------------------
------------------------------------------------------------------------------------------

instance Era era => Arbitrary (ShelleyTxCert era) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Arbitrary ShelleyDelegCert where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Arbitrary GenesisDelegCert where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Arbitrary MIRCert where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Arbitrary MIRTarget where
  arbitrary =
    oneof
      [ StakeAddressesMIR <$> arbitrary
      , SendToOppositePotMIR <$> arbitrary
      ]

instance Arbitrary MIRPot where
  arbitrary = genericArbitraryU

instance (Era era, Arbitrary (PParamsUpdate era)) => Arbitrary (Update era) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Arbitrary Byron.CompactTxOut where
  arbitrary = hedgehog genCompactTxOut

instance Arbitrary ASC where
  arbitrary =
    ASC
      . mkActiveSlotCoeff
      . unsafeBoundRational
      . fromRational
      . toRational
      <$> choose @Double (0.01, 0.5)

newtype ASC = ASC ActiveSlotCoeff
  deriving (Show)

instance Arbitrary StakeProportion where
  arbitrary = StakeProportion . toRational <$> choose @Double (0, 1)
  shrink (StakeProportion r) = StakeProportion <$> shrinkRealFrac r

newtype StakeProportion = StakeProportion Rational
  deriving (Show)

instance Arbitrary (TxBody ShelleyEra) where
  arbitrary =
    ShelleyTxBody
      <$> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> arbitrary
      <*> scale (`div` 15) arbitrary
      <*> arbitrary

genTx ::
  ( Arbitrary (TxBody era)
  , Arbitrary (TxAuxData era)
  , Arbitrary (TxWits era)
  ) =>
  Gen (ShelleyTx era)
genTx =
  ShelleyTx
    <$> arbitrary
    <*> resize maxTxWits arbitrary
    <*> arbitrary

maxTxWits :: Int
maxTxWits = 5

instance Arbitrary Metadatum where
  arbitrary = sizedMetadatum maxMetadatumDepth

instance Era era => Arbitrary (ShelleyTxAuxData era) where
  arbitrary = ShelleyTxAuxData <$> arbitrary

deriving newtype instance Arbitrary NominalDiffTimeMicro

maxMetadatumDepth :: Int
maxMetadatumDepth = 2

maxMetadatumListLens :: Int
maxMetadatumListLens = 5

sizedMetadatum :: Int -> Gen Metadatum
sizedMetadatum 0 =
  oneof
    [ I <$> arbitrary
    , B <$> arbitrary
    , S . T.pack <$> arbitrary
    ]
sizedMetadatum n =
  let xsGen = listOf (sizedMetadatum (n - 1))
   in oneof
        [ Map <$> (zip <$> resize maxMetadatumListLens xsGen <*> xsGen)
        , List <$> resize maxMetadatumListLens xsGen
        , I <$> arbitrary
        , B <$> arbitrary
        , S . T.pack <$> arbitrary
        ]

instance Arbitrary VotingPeriod where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance (Arbitrary k, Arbitrary v) => Arbitrary (LM.ListMap k v) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance
  ( ShelleyEraScript era
  , NativeScript era ~ MultiSig era
  ) =>
  Arbitrary (MultiSig era)
  where
  arbitrary = sizedMultiSig maxMultiSigDepth

maxMultiSigDepth :: Int
maxMultiSigDepth = 3

maxMultiSigListLens :: Int
maxMultiSigListLens = 4

sizedMultiSig :: ShelleyEraScript era => Int -> Gen (NativeScript era)
sizedMultiSig 0 = RequireSignature <$> arbitrary
sizedMultiSig n = oneof $ sizedNativeScriptGens n

sizedNativeScriptGens :: ShelleyEraScript era => Int -> [Gen (NativeScript era)]
sizedNativeScriptGens n =
  [ RequireSignature <$> arbitrary
  , RequireAllOf <$> (fromList <$> resize maxMultiSigListLens (listOf (sizedMultiSig (n - 1))))
  , RequireAnyOf <$> (fromList <$> resize maxMultiSigListLens (listOf (sizedMultiSig (n - 1))))
  , do
      subs <- resize maxMultiSigListLens (listOf (sizedMultiSig (n - 1)))
      let i = length subs
      RequireMOf <$> choose (0, i) <*> pure (fromList subs)
  ]

instance
  Arbitrary (PParams ShelleyEra) =>
  Arbitrary ShelleyGenesis
  where
  arbitrary = do
    sgSystemStart <- arbitrary
    sgNetworkMagic <- arbitrary
    sgNetworkId <- arbitrary
    sgActiveSlotsCoeff <- arbitrary
    sgSecurityParam <- arbitrary
    sgEpochLength <- arbitrary
    sgSlotsPerKESPeriod <- arbitrary
    sgMaxKESEvolutions <- arbitrary
    sgSlotLength <- (* 1000000) <$> arbitrary
    sgUpdateQuorum <- arbitrary
    sgMaxLovelaceSupply <- arbitrary
    sgProtocolParams <- arbitrary
    sgGenDelegs <- arbitrary
    sgInitialFunds <- arbitrary
    sgStaking <- arbitrary
    pure ShelleyGenesis {..}

instance Arbitrary ShelleyGenesisStaking where
  arbitrary = ShelleyGenesisStaking <$> arbitrary <*> arbitrary

instance
  ( Era era
  , EraScript era
  , Arbitrary (Script era)
  ) =>
  Arbitrary (ShelleyTxWits era)
  where
  arbitrary =
    ShelleyTxWits
      <$> arbitrary
      <*> (mscriptsToWits <$> arbitrary)
      <*> arbitrary
    where
      mscriptsToWits = Map.fromList . map (\s -> (hashScript @era s, s))

instance Era era => Arbitrary (ShelleyPpupPredFailure era) where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance Era era => Arbitrary (ShelleyPoolPredFailure era) where
  arbitrary =
    oneof
      [ StakePoolNotRegisteredOnKeyPOOL <$> arbitrary
      , do
          a <- arbitrary
          b <- arbitrary
          StakePoolRetirementWrongEpochPOOL (Mismatch a b) . Mismatch a <$> arbitrary
      , StakePoolCostTooLowPOOL <$> arbitrary
      , WrongNetworkPOOL <$> arbitrary <*> arbitrary
      , PoolMedataHashTooBig <$> arbitrary <*> arbitrary
      ]
  shrink = genericShrink

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "POOL" era))
  , Arbitrary (PredicateFailure (EraRule "DELEG" era))
  ) =>
  Arbitrary (ShelleyDelplPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink = recursivelyShrink

instance
  Era era =>
  Arbitrary (ShelleyDelegPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "DELPL" era))
  ) =>
  Arbitrary (ShelleyDelegsPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink = recursivelyShrink

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "LEDGER" era))
  ) =>
  Arbitrary (ShelleyLedgersPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink = genericShrink

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "DELEGS" era))
  , Arbitrary (PredicateFailure (EraRule "UTXOW" era))
  ) =>
  Arbitrary (ShelleyLedgerPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink _ = []

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "UTXO" era))
  ) =>
  Arbitrary (ShelleyUtxowPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink _ = []

instance
  ( EraTx era
  , Arbitrary (TxBody era)
  , Arbitrary (Value era)
  , Arbitrary (TxAuxData era)
  , Arbitrary (Script era)
  , Arbitrary (TxWits era)
  ) =>
  Arbitrary (ShelleyTx era)
  where
  arbitrary = genTx

instance
  ( Era era
  , Arbitrary (PredicateFailure (EraRule "LEDGER" era))
  ) =>
  Arbitrary (ApplyTxError era)
  where
  arbitrary = ApplyTxError <$> arbitrary
  shrink (ApplyTxError xs) = [ApplyTxError xs' | xs' <- shrink xs]

instance
  ( Era era
  , Arbitrary (Value era)
  , Arbitrary (TxOut era)
  , Arbitrary (EraRuleFailure "PPUP" era)
  ) =>
  Arbitrary (ShelleyUtxoPredFailure era)
  where
  arbitrary = genericArbitraryU
  shrink _ = []

data RawSeed = RawSeed !Word64 !Word64 !Word64 !Word64 !Word64
  deriving (Eq, Show)

instance Arbitrary RawSeed where
  arbitrary =
    RawSeed
      <$> chooseAny
      <*> chooseAny
      <*> chooseAny
      <*> chooseAny
      <*> chooseAny

instance Era era => Arbitrary (ShelleyCertState era) where
  arbitrary = ShelleyCertState <$> arbitrary <*> arbitrary
  shrink = genericShrink

instance Arbitrary FromByronTranslationContext where
  arbitrary = genericArbitraryU
  shrink _ = []

deriving newtype instance Arbitrary (TransitionConfig ShelleyEra)
