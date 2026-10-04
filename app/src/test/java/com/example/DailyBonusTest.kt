package com.example

import com.example.data.backend.ServerEmulatedEngine
import com.example.data.model.TransactionType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyBonusTest {

    @Test
    fun dailyBonus_grantsExactly50OncePerServerDayAndCreatesLedgerEntry() =
        kotlinx.coroutines.runBlocking {
            var now = 1_759_529_600_000L
            val engine = ServerEmulatedEngine { now }

            val account = engine.initAccount("daily-install-1", "daily-user-1").getOrThrow()
            now += 24 * 60 * 60 * 1000L

            val first = engine.claimDailyBonus(account.userId).getOrThrow()
            val second = engine.claimDailyBonus(account.userId).getOrThrow()

            assertTrue(first.granted)
            assertEquals(50L, first.amount)
            assertEquals("ALREADY_CLAIMED", second.reason)

            val updated = engine.fetchAccount(account.userId).getOrThrow()
            assertEquals(account.availableCoins + 50L, updated.availableCoins)
            assertEquals(
                1,
                engine.fetchTransactions(account.userId).getOrThrow()
                    .count { it.type == TransactionType.DAILY_BONUS && it.amount == 50L }
            )
        }

    @Test
    fun dailyBonus_rejectsMissingCallerIdentity() =
        kotlinx.coroutines.runBlocking {
            val engine = ServerEmulatedEngine()
            val result = engine.claimDailyBonus(null)

            assertTrue(result.isFailure)
            assertTrue(
                result.exceptionOrNull()?.message?.startsWith("UNAUTHORIZED") == true
            )
        }
}
