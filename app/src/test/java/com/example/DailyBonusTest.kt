package com.example

import com.example.data.backend.DeviceEvidence
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
            val evidence = DeviceEvidence(
                installId = "daily-install-1",
                androidId = "0123456789abcdef"
            )
            now += 24 * 60 * 60 * 1000L

            val first = engine.claimDailyBonus(evidence, account.userId).getOrThrow()
            val second = engine.claimDailyBonus(evidence, account.userId).getOrThrow()

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
    fun dailyBonus_sameDeviceCannotBeClaimedBySecondAuthUser() =
        kotlinx.coroutines.runBlocking {
            var now = 1_759_529_600_000L
            val engine = ServerEmulatedEngine { now }
            val first = engine.initAccount("daily-install-a", "daily-user-a").getOrThrow()
            val second = engine.initAccount("daily-install-b", "daily-user-b").getOrThrow()
            val evidence = DeviceEvidence(
                installId = "daily-install-a",
                androidId = "0123456789abcdef"
            )
            val secondBefore = engine.fetchAccount(second.userId).getOrThrow()

            now += 24 * 60 * 60 * 1000L

            val granted = engine.claimDailyBonus(evidence, first.userId).getOrThrow()
            val replay = engine.claimDailyBonus(evidence, second.userId).getOrThrow()

            assertTrue(granted.granted)
            assertEquals(50L, granted.amount)
            assertEquals("ALREADY_CLAIMED", replay.reason)
            assertEquals(
                first.availableCoins + 50L,
                engine.fetchAccount(first.userId).getOrThrow().availableCoins
            )
            assertEquals(
                secondBefore.availableCoins,
                engine.fetchAccount(second.userId).getOrThrow().availableCoins
            )
        }

    @Test
    fun dailyBonus_rejectsMissingDeviceEvidence() =
        kotlinx.coroutines.runBlocking {
            val engine = ServerEmulatedEngine()
            val account = engine.initAccount("daily-install-1", "daily-user-1").getOrThrow()
            val result = engine.claimDailyBonus(DeviceEvidence(installId = ""), account.userId)

            assertTrue(result.isFailure)
            assertTrue(
                result.exceptionOrNull()?.message?.startsWith("DEVICE_EVIDENCE_REQUIRED") == true
            )
        }

    @Test
    fun dailyBonus_rejectsMissingCallerIdentity() =
        kotlinx.coroutines.runBlocking {
            val engine = ServerEmulatedEngine()
            val result = engine.claimDailyBonus(
                evidence = DeviceEvidence(
                    installId = "daily-install-1",
                    androidId = "0123456789abcdef"
                ),
                callerUserId = null
            )

            assertTrue(result.isFailure)
            assertTrue(
                result.exceptionOrNull()?.message?.startsWith("UNAUTHORIZED") == true
            )
        }
}
