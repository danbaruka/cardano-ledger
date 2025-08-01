{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Babbage.Rules.Utxo (
  BabbageUTXO,
  BabbageUtxoPredFailure (..),
  utxoTransition,
  feesOK,
  validateTotalCollateral,
  validateCollateralEqBalance,
  validateOutputTooSmallUTxO,
  disjointRefInputs,
) where

import Cardano.Ledger.Allegra.Rules (AllegraUtxoPredFailure, shelleyToAllegraUtxoPredFailure)
import qualified Cardano.Ledger.Allegra.Rules as Allegra (
  validateOutsideValidityIntervalUTxO,
 )
import Cardano.Ledger.Alonzo.Rules (
  AlonzoUtxoEvent (..),
  AlonzoUtxoPredFailure (..),
  AlonzoUtxosPredFailure (..),
  allegraToAlonzoUtxoPredFailure,
 )
import qualified Cardano.Ledger.Alonzo.Rules as Alonzo (
  validateExUnitsTooBigUTxO,
  validateInsufficientCollateral,
  validateOutputTooBigUTxO,
  validateOutsideForecast,
  validateScriptsNotPaidUTxO,
  validateTooManyCollateralInputs,
  validateWrongNetworkInTxBody,
 )
import Cardano.Ledger.Alonzo.Tx (AlonzoTx (..))
import Cardano.Ledger.Alonzo.TxWits (unRedeemersL)
import Cardano.Ledger.Babbage.Collateral (collAdaBalance)
import Cardano.Ledger.Babbage.Core
import Cardano.Ledger.Babbage.Era (BabbageEra, BabbageUTXO)
import Cardano.Ledger.Babbage.Rules.Ppup ()
import Cardano.Ledger.Babbage.Rules.Utxos (BabbageUTXOS)
import Cardano.Ledger.BaseTypes (
  Mismatch (..),
  ProtVer (..),
  ShelleyBase,
  epochInfo,
  networkId,
  systemStart,
 )
import Cardano.Ledger.Binary (DecCBOR (..), EncCBOR (..), Sized (..), natVersion)
import Cardano.Ledger.Binary.Coders
import Cardano.Ledger.Coin (Coin (..), DeltaCoin, toDeltaCoin)
import Cardano.Ledger.Rules.ValidationMode (
  Test,
  runTest,
  runTestOnSignal,
 )
import Cardano.Ledger.Shelley.LedgerState (UTxOState (utxosUtxo))
import Cardano.Ledger.Shelley.Rules (ShelleyPpupPredFailure, ShelleyUtxoPredFailure, UtxoEnv)
import qualified Cardano.Ledger.Shelley.Rules as Shelley
import Cardano.Ledger.State
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Ledger.Val ((<->))
import qualified Cardano.Ledger.Val as Val (inject, isAdaOnly, pointwise)
import Control.DeepSeq (NFData)
import Control.Monad (unless, when)
import Control.Monad.Trans.Reader (asks)
import Control.SetAlgebra (eval, (◁))
import Control.State.Transition.Extended (
  Embed (..),
  STS (..),
  TRC (..),
  TransitionRule,
  failureOnNonEmpty,
  judgmentContext,
  liftSTS,
  trans,
  validate,
 )
import Data.Bifunctor (first)
import Data.Coerce (coerce)
import Data.Foldable (sequenceA_, toList)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Lens.Micro
import NoThunks.Class (InspectHeapNamed (..), NoThunks (..))
import Validation (Validation, failureIf, failureUnless)

-- ======================================================

-- | Predicate failure for the Babbage Era
data BabbageUtxoPredFailure era
  = AlonzoInBabbageUtxoPredFailure (AlonzoUtxoPredFailure era) -- Inherited from Alonzo
  | -- | The collateral is not equivalent to the total collateral asserted by the transaction
    IncorrectTotalCollateralField
      -- | collateral provided
      DeltaCoin
      -- | collateral amount declared in transaction body
      Coin
  | -- | list of supplied transaction outputs that are too small,
    -- together with the minimum value for the given output.
    BabbageOutputTooSmallUTxO
      [(TxOut era, Coin)]
  | -- | TxIns that appear in both inputs and reference inputs
    BabbageNonDisjointRefInputs
      (NonEmpty TxIn)
  deriving (Generic)

type instance EraRuleFailure "UTXO" BabbageEra = BabbageUtxoPredFailure BabbageEra

instance InjectRuleFailure "UTXO" BabbageUtxoPredFailure BabbageEra

instance InjectRuleFailure "UTXO" AlonzoUtxoPredFailure BabbageEra where
  injectFailure = AlonzoInBabbageUtxoPredFailure

instance InjectRuleFailure "UTXO" ShelleyPpupPredFailure BabbageEra where
  injectFailure = AlonzoInBabbageUtxoPredFailure . UtxosFailure . injectFailure

instance InjectRuleFailure "UTXO" ShelleyUtxoPredFailure BabbageEra where
  injectFailure =
    AlonzoInBabbageUtxoPredFailure
      . allegraToAlonzoUtxoPredFailure
      . shelleyToAllegraUtxoPredFailure

instance InjectRuleFailure "UTXO" AllegraUtxoPredFailure BabbageEra where
  injectFailure = AlonzoInBabbageUtxoPredFailure . allegraToAlonzoUtxoPredFailure

instance InjectRuleFailure "UTXO" AlonzoUtxosPredFailure BabbageEra where
  injectFailure = AlonzoInBabbageUtxoPredFailure . UtxosFailure

deriving instance
  ( Era era
  , Show (AlonzoUtxoPredFailure era)
  , Show (PredicateFailure (EraRule "UTXO" era))
  , Show (TxOut era)
  , Show (Script era)
  , Show TxIn
  ) =>
  Show (BabbageUtxoPredFailure era)

deriving instance
  ( Era era
  , Eq (AlonzoUtxoPredFailure era)
  , Eq (PredicateFailure (EraRule "UTXO" era))
  , Eq (TxOut era)
  , Eq (Script era)
  , Eq TxIn
  ) =>
  Eq (BabbageUtxoPredFailure era)

instance
  ( Era era
  , NFData (Value era)
  , NFData (TxOut era)
  , NFData (PredicateFailure (EraRule "UTXOS" era))
  ) =>
  NFData (BabbageUtxoPredFailure era)

-- =======================================================

-- | feesOK is a predicate with several parts. Some parts only apply in special circumstances.
--   1) The fee paid is >= the minimum fee
--   2) If the total ExUnits are 0 in both Memory and Steps, no further part needs to be checked.
--   3) The collateral consists only of VKey addresses
--   4) The collateral inputs do not contain any non-ADA part
--   5) The collateral is sufficient to cover the appropriate percentage of the
--      fee marked in the transaction
--   6) The collateral is equivalent to total collateral asserted by the transaction
--   7) There is at least one collateral input
--
--   feesOK can differ from Era to Era, as new notions of fees arise. This is the Babbage version
--   See: Figure 2: Functions related to fees and collateral, in the Babbage specification
--   In the spec feesOK is a boolean function. Because wee need to handle predicate failures
--   in the implementaion, it is coded as a Test. Which is a validation.
--   This version is generic in that it can be lifted to any PredicateFailure type that
--   embeds BabbageUtxoPred era. This makes it possibly useful in future Eras.
feesOK ::
  forall era rule.
  ( EraUTxO era
  , BabbageEraTxBody era
  , AlonzoEraTxWits era
  , InjectRuleFailure rule AlonzoUtxoPredFailure era
  , InjectRuleFailure rule BabbageUtxoPredFailure era
  ) =>
  PParams era ->
  Tx era ->
  UTxO era ->
  Test (EraRuleFailure rule era)
feesOK pp tx u@(UTxO utxo) =
  let txBody = tx ^. bodyTxL
      collateral' = txBody ^. collateralInputsTxBodyL -- Inputs allocated to pay txfee
      -- restrict Utxo to those inputs we use to pay fees.
      utxoCollateral = eval (collateral' ◁ utxo)
      theFee = txBody ^. feeTxBodyL -- Coin supplied to pay fees
      minFee = getMinFeeTxUtxo pp tx u
   in sequenceA_
        [ -- Part 1: minfee pp tx ≤ txfee txBody
          failureUnless
            (minFee <= theFee)
            (injectFailure $ FeeTooSmallUTxO Mismatch {mismatchSupplied = theFee, mismatchExpected = minFee})
        , -- Part 2: (txrdmrs tx ≠ ∅ ⇒ validateCollateral)
          unless (null $ tx ^. witsTxL . rdmrsTxWitsL . unRedeemersL) $
            validateTotalCollateral pp txBody utxoCollateral
        ]

-- | Test that inputs and refInpts are disjoint, in Conway and later Eras.
disjointRefInputs ::
  forall era.
  EraPParams era =>
  PParams era ->
  Set TxIn ->
  Set TxIn ->
  Test (BabbageUtxoPredFailure era)
disjointRefInputs pp inputs refInputs =
  when
    ( pvMajor (pp ^. ppProtocolVersionL) > eraProtVerHigh @BabbageEra
        && pvMajor (pp ^. ppProtocolVersionL) < natVersion @11
    )
    (failureOnNonEmpty common BabbageNonDisjointRefInputs)
  where
    common = inputs `Set.intersection` refInputs

validateTotalCollateral ::
  forall era rule.
  ( BabbageEraTxBody era
  , InjectRuleFailure rule AlonzoUtxoPredFailure era
  , InjectRuleFailure rule BabbageUtxoPredFailure era
  ) =>
  PParams era ->
  TxBody era ->
  Map.Map TxIn (TxOut era) ->
  Test (EraRuleFailure rule era)
validateTotalCollateral pp txBody utxoCollateral =
  sequenceA_
    [ -- Part 3: (∀(a,_,_) ∈ range (collateral txb ◁ utxo), a ∈ Addrvkey)
      fromAlonzoValidation $ Alonzo.validateScriptsNotPaidUTxO utxoCollateral
    , -- Part 4: isAdaOnly balance
      fromAlonzoValidation $
        validateCollateralContainsNonADA txBody utxoCollateral
    , -- Part 5: balance ≥ ⌈txfee txb ∗ (collateralPercent pp) / 100⌉
      fromAlonzoValidation $ Alonzo.validateInsufficientCollateral pp txBody bal
    , -- Part 6: (txcoll tx ≠ ◇) ⇒ balance = txcoll tx
      first (fmap injectFailure) $ validateCollateralEqBalance bal (txBody ^. totalCollateralTxBodyL)
    , -- Part 7: collInputs tx ≠ ∅
      fromAlonzoValidation $ failureIf (null utxoCollateral) (NoCollateralInputs @era)
    ]
  where
    bal = collAdaBalance txBody utxoCollateral
    fromAlonzoValidation = first (fmap injectFailure)

-- | This validation produces the same failure as in Alonzo, but is slightly different
-- then the corresponding one in Alonzo, due to addition of the collateral return output:
--
-- 1. Collateral amount can be specified exactly, thus protecting user against unnecessary
-- loss.
--
-- 2. Collateral inputs can contain multi-assets, as long all of them are returned to the
-- `collateralReturnTxBodyL`. This design decision was also intentional, in order to
-- simplify utxo selection for collateral.
validateCollateralContainsNonADA ::
  forall era.
  BabbageEraTxBody era =>
  TxBody era ->
  Map.Map TxIn (TxOut era) ->
  Test (AlonzoUtxoPredFailure era)
validateCollateralContainsNonADA txBody utxoCollateral =
  failureUnless onlyAdaInCollateral $ CollateralContainsNonADA valueWithNonAda
  where
    onlyAdaInCollateral =
      utxoCollateralAndReturnHaveOnlyAda || allNonAdaIsConsumedByReturn
    -- When we do not have any non-ada TxOuts we can short-circuit the more expensive
    -- validation of NonAda being fully consumed by the return output, which requires
    -- computation of the full balance on the Value, not just the Coin.
    utxoCollateralAndReturnHaveOnlyAda =
      utxoCollateralHasOnlyAda && areAllAdaOnly (txBody ^. collateralReturnTxBodyL)
    utxoCollateralHasOnlyAda = areAllAdaOnly utxoCollateral
    -- Whenever return TxOut consumes all of the NonAda value then the total collateral
    -- balance is considered valid.
    allNonAdaIsConsumedByReturn = Val.isAdaOnly totalCollateralBalance
    -- When reporting failure the NonAda value can be present in either:
    -- - Only in collateral inputs.
    -- - Only in return output, thus we report the return output value, rather than utxo.
    -- - Both inputs and return address, but does not balance out. In which case
    --   we report utxo balance
    valueWithNonAda =
      case txBody ^. collateralReturnTxBodyL of
        SNothing -> collateralBalance
        SJust retTxOut ->
          if utxoCollateralHasOnlyAda
            then retTxOut ^. valueTxOutL
            else collateralBalance
    -- This is the balance that is provided by the collateral inputs
    collateralBalance = sumAllValue utxoCollateral
    -- This is the total amount that will be spent as collateral. This is where we account
    -- for the fact that we can remove Non-Ada assets from collateral inputs, by directing
    -- them to the return TxOut.
    totalCollateralBalance = case txBody ^. collateralReturnTxBodyL of
      SNothing -> collateralBalance
      SJust retTxOut -> collateralBalance <-> (retTxOut ^. valueTxOutL @era)

-- > (txcoll tx ≠ ◇) => balance == txcoll tx
validateCollateralEqBalance ::
  DeltaCoin -> StrictMaybe Coin -> Validation (NonEmpty (BabbageUtxoPredFailure era)) ()
validateCollateralEqBalance bal txcoll =
  case txcoll of
    SNothing -> pure ()
    SJust tc -> failureUnless (bal == toDeltaCoin tc) (IncorrectTotalCollateralField bal tc)

-- > getValue txout ≥ inject ( serSize txout ∗ coinsPerUTxOByte pp )
validateOutputTooSmallUTxO ::
  (EraTxOut era, Foldable f) =>
  PParams era ->
  f (Sized (TxOut era)) ->
  Test (BabbageUtxoPredFailure era)
validateOutputTooSmallUTxO pp outs =
  failureUnless (null outputsTooSmall) $ BabbageOutputTooSmallUTxO outputsTooSmall
  where
    outs' = map (\out -> (sizedValue out, getMinCoinSizedTxOut pp out)) (toList outs)
    outputsTooSmall =
      filter
        ( \(out, minSize) ->
            let v = out ^. valueTxOutL
             in -- pointwise is used because non-ada amounts must be >= 0 too
                not $
                  Val.pointwise
                    (>=)
                    v
                    (Val.inject minSize)
        )
        outs'

-- | The UTxO transition rule for the Babbage eras.
utxoTransition ::
  forall era.
  ( EraUTxO era
  , BabbageEraTxBody era
  , AlonzoEraTxWits era
  , Tx era ~ AlonzoTx era
  , InjectRuleFailure "UTXO" ShelleyUtxoPredFailure era
  , InjectRuleFailure "UTXO" AllegraUtxoPredFailure era
  , InjectRuleFailure "UTXO" AlonzoUtxoPredFailure era
  , InjectRuleFailure "UTXO" BabbageUtxoPredFailure era
  , Environment (EraRule "UTXO" era) ~ UtxoEnv era
  , State (EraRule "UTXO" era) ~ UTxOState era
  , Signal (EraRule "UTXO" era) ~ AlonzoTx era
  , BaseM (EraRule "UTXO" era) ~ ShelleyBase
  , STS (EraRule "UTXO" era)
  , -- In this function we we call the UTXOS rule, so we need some assumptions
    Embed (EraRule "UTXOS" era) (EraRule "UTXO" era)
  , Environment (EraRule "UTXOS" era) ~ UtxoEnv era
  , State (EraRule "UTXOS" era) ~ UTxOState era
  , Signal (EraRule "UTXOS" era) ~ Tx era
  , EraCertState era
  ) =>
  TransitionRule (EraRule "UTXO" era)
utxoTransition = do
  TRC (Shelley.UtxoEnv slot pp certState, utxos, tx) <- judgmentContext
  let utxo = utxosUtxo utxos

  {-   txb := txbody tx   -}
  let txBody = tx ^. bodyTxL
      allInputs = txBody ^. allInputsTxBodyF
      refInputs :: Set TxIn
      refInputs = txBody ^. referenceInputsTxBodyL
      inputs :: Set TxIn
      inputs = txBody ^. inputsTxBodyL

  {- inputs ∩ refInputs = ∅ -}
  runTest $ disjointRefInputs pp inputs refInputs

  {- ininterval slot (txvld txb) -}
  runTest $ Allegra.validateOutsideValidityIntervalUTxO slot txBody

  sysSt <- liftSTS $ asks systemStart
  ei <- liftSTS $ asks epochInfo

  {- epochInfoSlotToUTCTime epochInfo systemTime i_f ≠ ◇ -}
  runTest $ Alonzo.validateOutsideForecast ei slot sysSt tx

  {-   txins txb ≠ ∅   -}
  runTestOnSignal $ Shelley.validateInputSetEmptyUTxO txBody

  {-   feesOK pp tx utxo   -}
  validate $ feesOK pp tx utxo -- Generalizes the fee to small from earlier Era's

  {- allInputs = spendInputs txb ∪ collInputs txb ∪ refInputs txb -}
  {- (spendInputs txb ∪ collInputs txb ∪ refInputs txb) ⊆ dom utxo   -}
  runTest $ Shelley.validateBadInputsUTxO utxo allInputs

  {- consumed pp utxo txb = produced pp poolParams txb -}
  runTest $ Shelley.validateValueNotConservedUTxO pp utxo certState txBody

  {-   adaID ∉ supp mint tx - check not needed because mint field of type MultiAsset
   cannot contain ada -}

  {-   ∀ txout ∈ allOuts txb, getValue txout ≥ inject (serSize txout ∗ coinsPerUTxOByte pp) -}
  let allSizedOutputs = txBody ^. allSizedOutputsTxBodyF
  runTest $ validateOutputTooSmallUTxO pp allSizedOutputs

  let allOutputs = fmap sizedValue allSizedOutputs
  {-   ∀ txout ∈ allOuts txb, serSize (getValue txout) ≤ maxValSize pp   -}
  runTest $ Alonzo.validateOutputTooBigUTxO pp allOutputs

  {- ∀ ( _ ↦ (a,_)) ∈ allOuts txb,  a ∈ Addrbootstrap → bootstrapAttrsSize a ≤ 64 -}
  runTestOnSignal $ Shelley.validateOutputBootAddrAttrsTooBig allOutputs

  netId <- liftSTS $ asks networkId

  {- ∀(_ → (a, _)) ∈ allOuts txb, netId a = NetworkId -}
  runTestOnSignal $ Shelley.validateWrongNetwork netId allOutputs

  {- ∀(a → ) ∈ txwdrls txb, netId a = NetworkId -}
  runTestOnSignal $ Shelley.validateWrongNetworkWithdrawal netId txBody

  {- (txnetworkid txb = NetworkId) ∨ (txnetworkid txb = ◇) -}
  runTestOnSignal $ Alonzo.validateWrongNetworkInTxBody netId txBody

  {- txsize tx ≤ maxTxSize pp -}
  runTestOnSignal $ Shelley.validateMaxTxSizeUTxO pp tx

  {-   totExunits tx ≤ maxTxExUnits pp    -}
  runTest $ Alonzo.validateExUnitsTooBigUTxO pp tx

  {-   ‖collateral tx‖  ≤  maxCollInputs pp   -}
  runTest $ Alonzo.validateTooManyCollateralInputs pp txBody

  trans @(EraRule "UTXOS" era) =<< coerce <$> judgmentContext

--------------------------------------------------------------------------------
-- BabbageUTXO STS
--------------------------------------------------------------------------------

instance
  forall era.
  ( EraTx era
  , EraUTxO era
  , BabbageEraTxBody era
  , AlonzoEraTxWits era
  , Tx era ~ AlonzoTx era
  , EraRule "UTXO" era ~ BabbageUTXO era
  , InjectRuleFailure "UTXO" ShelleyUtxoPredFailure era
  , InjectRuleFailure "UTXO" AllegraUtxoPredFailure era
  , InjectRuleFailure "UTXO" AlonzoUtxoPredFailure era
  , InjectRuleFailure "UTXO" BabbageUtxoPredFailure era
  , -- instructions for calling UTXOS from BabbageUTXO
    Embed (EraRule "UTXOS" era) (BabbageUTXO era)
  , Environment (EraRule "UTXOS" era) ~ UtxoEnv era
  , State (EraRule "UTXOS" era) ~ UTxOState era
  , Signal (EraRule "UTXOS" era) ~ Tx era
  , EraCertState era
  , SafeToHash (TxWits era)
  ) =>
  STS (BabbageUTXO era)
  where
  type State (BabbageUTXO era) = UTxOState era
  type Signal (BabbageUTXO era) = AlonzoTx era
  type Environment (BabbageUTXO era) = UtxoEnv era
  type BaseM (BabbageUTXO era) = ShelleyBase
  type PredicateFailure (BabbageUTXO era) = BabbageUtxoPredFailure era
  type Event (BabbageUTXO era) = AlonzoUtxoEvent era

  initialRules = []
  transitionRules = [utxoTransition @era]
  assertions = [Shelley.validSizeComputationCheck]

instance
  ( Era era
  , STS (BabbageUTXOS era)
  , PredicateFailure (EraRule "UTXOS" era) ~ AlonzoUtxosPredFailure era
  , Event (EraRule "UTXOS" era) ~ Event (BabbageUTXOS era)
  ) =>
  Embed (BabbageUTXOS era) (BabbageUTXO era)
  where
  wrapFailed = AlonzoInBabbageUtxoPredFailure . UtxosFailure
  wrapEvent = UtxosEvent

-- ============================================
-- CBOR for Predicate faiure type

instance
  ( Era era
  , EncCBOR (TxOut era)
  , EncCBOR (Value era)
  , EncCBOR (PredicateFailure (EraRule "UTXOS" era))
  , EncCBOR (PredicateFailure (EraRule "UTXO" era))
  , EncCBOR (Script era)
  , EncCBOR TxIn
  , Typeable (TxAuxData era)
  ) =>
  EncCBOR (BabbageUtxoPredFailure era)
  where
  encCBOR =
    encode . \case
      AlonzoInBabbageUtxoPredFailure x -> Sum AlonzoInBabbageUtxoPredFailure 1 !> To x
      IncorrectTotalCollateralField c1 c2 -> Sum IncorrectTotalCollateralField 2 !> To c1 !> To c2
      BabbageOutputTooSmallUTxO x -> Sum BabbageOutputTooSmallUTxO 3 !> To x
      BabbageNonDisjointRefInputs x -> Sum BabbageNonDisjointRefInputs 4 !> To x

instance
  ( Era era
  , DecCBOR (TxOut era)
  , EncCBOR (Value era)
  , DecCBOR (Value era)
  , DecCBOR (PredicateFailure (EraRule "UTXOS" era))
  , DecCBOR (PredicateFailure (EraRule "UTXO" era))
  , Typeable (Script era)
  , Typeable (TxAuxData era)
  ) =>
  DecCBOR (BabbageUtxoPredFailure era)
  where
  decCBOR = decode $ Summands "BabbageUtxoPred" $ \case
    1 -> SumD AlonzoInBabbageUtxoPredFailure <! From
    2 -> SumD IncorrectTotalCollateralField <! From <! From
    3 -> SumD BabbageOutputTooSmallUTxO <! From
    4 -> SumD BabbageNonDisjointRefInputs <! From
    n -> Invalid n

deriving via
  InspectHeapNamed "BabbageUtxoPred" (BabbageUtxoPredFailure era)
  instance
    NoThunks (BabbageUtxoPredFailure era)
