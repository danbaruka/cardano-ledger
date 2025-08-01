{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Cardano.Ledger.Conway.Tx (
  module BabbageTxReExport,
  tierRefScriptFee,
  refScriptCostStride,
  refScriptCostMultiplier,
  getConwayMinFeeTx,
) where

import Cardano.Ledger.Allegra.Tx (validateTimelock)
import Cardano.Ledger.Alonzo.Core (AlonzoEraTxWits)
import Cardano.Ledger.Alonzo.Tx (
  alonzoMinFeeTx,
  auxDataAlonzoTxL,
  bodyAlonzoTxL,
  isValidAlonzoTxL,
  mkBasicAlonzoTx,
  sizeAlonzoTxF,
  witsAlonzoTxL,
 )
import Cardano.Ledger.Alonzo.TxSeq (
  AlonzoTxSeq (AlonzoTxSeq, txSeqTxns),
  hashAlonzoTxSeq,
 )
import Cardano.Ledger.Babbage.Tx as BabbageTxReExport (
  AlonzoEraTx (..),
  AlonzoTx (..),
 )
import Cardano.Ledger.BaseTypes (unboundRational)
import Cardano.Ledger.Coin (Coin (Coin))
import Cardano.Ledger.Conway.Era (ConwayEra)
import Cardano.Ledger.Conway.PParams (ConwayEraPParams, ppMinFeeRefScriptCostPerByteL)
import Cardano.Ledger.Conway.TxAuxData ()
import Cardano.Ledger.Conway.TxBody ()
import Cardano.Ledger.Conway.TxWits ()
import Cardano.Ledger.Core
import Cardano.Ledger.Val (Val (..))
import GHC.Stack
import Lens.Micro ((^.))

instance EraTx ConwayEra where
  type Tx ConwayEra = AlonzoTx ConwayEra

  mkBasicTx = mkBasicAlonzoTx

  bodyTxL = bodyAlonzoTxL
  {-# INLINE bodyTxL #-}

  witsTxL = witsAlonzoTxL
  {-# INLINE witsTxL #-}

  auxDataTxL = auxDataAlonzoTxL
  {-# INLINE auxDataTxL #-}

  sizeTxF = sizeAlonzoTxF
  {-# INLINE sizeTxF #-}

  validateNativeScript = validateTimelock
  {-# INLINE validateNativeScript #-}

  getMinFeeTx = getConwayMinFeeTx

-- | 25 KiB
refScriptCostStride :: Int
refScriptCostStride = 25_600

refScriptCostMultiplier :: Rational
refScriptCostMultiplier = 1.2

getConwayMinFeeTx ::
  ( EraTx era
  , AlonzoEraTxWits era
  , ConwayEraPParams era
  ) =>
  PParams era ->
  Tx era ->
  Int ->
  Coin
getConwayMinFeeTx pp tx refScriptsSize =
  alonzoMinFeeTx pp tx <+> refScriptsFee
  where
    refScriptCostPerByte = unboundRational (pp ^. ppMinFeeRefScriptCostPerByteL)
    refScriptsFee =
      tierRefScriptFee
        refScriptCostMultiplier
        refScriptCostStride
        refScriptCostPerByte
        refScriptsSize

-- | Calculate the fee for reference scripts using an exponential growth of the price per
-- byte with linear increments
tierRefScriptFee ::
  HasCallStack =>
  -- | Growth factor or step multiplier
  Rational ->
  -- | Increment size in which price grows linearly according to the price
  Int ->
  -- | Base fee. Currently this is customizable by `ppMinFeeRefScriptCostPerByteL`
  Rational ->
  -- | Total RefScript size in bytes
  Int ->
  Coin
tierRefScriptFee multiplier sizeIncrement
  | multiplier <= 0 || sizeIncrement <= 0 = error "Size increment and multiplier must be positive"
  | otherwise = go 0
  where
    go !acc !curTierPrice !n
      | n < sizeIncrement =
          Coin $ floor (acc + toRational n * curTierPrice)
      | otherwise =
          go (acc + sizeIncrementRational * curTierPrice) (multiplier * curTierPrice) (n - sizeIncrement)
    sizeIncrementRational = toRational sizeIncrement

instance AlonzoEraTx ConwayEra where
  isValidTxL = isValidAlonzoTxL
  {-# INLINE isValidTxL #-}

instance EraSegWits ConwayEra where
  type TxSeq ConwayEra = AlonzoTxSeq ConwayEra
  fromTxSeq = txSeqTxns
  toTxSeq = AlonzoTxSeq
  hashTxSeq = hashAlonzoTxSeq
  numSegComponents = 4
