package com.example

import com.example.data.backend.ServerEmulatedEngine
import com.example.data.model.TransactionType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class CoinTransferTest {

    @Test
    fun transferMovesCoinsAtomicallyAndCreatesBothLedgerEntries() = kotlinx.coroutines.runBlocking {
        val engine = ServerEmulatedEngine()
        val sender = engine.initAccount("install-sender", "sender").getOrThrow()
        val recipient = engine.initAccount("install-recipient", "recipient").getOrThrow()

        val result = engine.transferCoins(
            recipientHandle = recipient.userHandle,
            amount = 40L,
            idempotencyKey = "transfer-test-0000001",
            note = "test transfer",
            callerUserId = sender.userId
        ).getOrThrow()

        assertEquals(40L, result.amount)
        assertEquals(110L, engine.fetchAccount(sender.userId).getOrThrow().availableCoins)
        assertEquals(190L, engine.fetchAccount(recipient.userId).getOrThrow().availableCoins)

        val senderTx = engine.fetchTransactions(sender.userId).getOrThrow()
            .firstOrNull { it.referenceId == result.transferId }
        val recipientTx = engine.fetchTransactions(recipient.userId).getOrThrow()
            .firstOrNull { it.referenceId == result.transferId }

        assertNotNull(senderTx)
        assertNotNull(recipientTx)
        assertEquals(TransactionType.COIN_TRANSFER_SENT, senderTx!!.type)
        assertEquals(-40L, senderTx.amount)
        assertEquals(TransactionType.COIN_TRANSFER_RECEIVED, recipientTx!!.type)
        assertEquals(40L, recipientTx.amount)
    }

    @Test
    fun retryWithSameIdempotencyKeyDoesNotTransferTwice() = kotlinx.coroutines.runBlocking {
        val engine = ServerEmulatedEngine()
        val sender = engine.initAccount("install-sender-2", "sender2").getOrThrow()
        val recipient = engine.initAccount("install-recipient-2", "recipient2").getOrThrow()
        val key = "transfer-test-0000002"

        val first = engine.transferCoins(
            recipientHandle = recipient.userHandle,
            amount = 25L,
            idempotencyKey = key,
            callerUserId = sender.userId
        ).getOrThrow()

        val second = engine.transferCoins(
            recipientHandle = recipient.userHandle,
            amount = 999L,
            idempotencyKey = key,
            callerUserId = sender.userId
        ).getOrThrow()

        assertEquals(first.transferId, second.transferId)
        assertEquals(125L, engine.fetchAccount(sender.userId).getOrThrow().availableCoins)
        assertEquals(175L, engine.fetchAccount(recipient.userId).getOrThrow().availableCoins)
        assertEquals(1, engine.fetchTransactions(sender.userId).getOrThrow()
            .count { it.referenceId == first.transferId })
    }
}
