package com.example

import com.example.data.backend.ServerEmulatedEngine
import com.example.data.model.TransactionType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DailyBonusTest {

    @Test
    fun dailyBonus_requiresCompletedViewThenGrantsExactly50OncePerServerDay() =
        kotlinx.coroutines.runBlocking {
            var now = 1_759_529_600_000L
            val engine = ServerEmulatedEngine { now }

            val advertiser = engine.initAccount("daily-advertiser", "daily-advertiser").getOrThrow()
            val viewer = engine.initAccount("daily-viewer", "daily-viewer").getOrThrow()
            now += 24 * 60 * 60 * 1000L

            val beforeView = engine.claimDailyBonus(viewer.userId).getOrThrow()
            assertFalse(beforeView.granted)
            assertEquals("VISIT_REQUIRED", beforeView.reason)

            engine.createCampaign(
                url = "https://example.com",
                normalizedUrl = "https://example.com",
                domain = "example.com",
                durationSeconds = 5,
                targetViews = 1,
                keyword = null,
                callerUserId = advertiser.userId,
                preflightToken = "emulated-preflight-token"
            ).getOrThrow()

            val session = engine.requestViewSession(viewer.userId).getOrThrow()
                ?: error("Expected a view session")

            assertTrue(engine.signalContentReady(session.id, viewer.userId).getOrThrow())
            now += 5_000L

            val completion = engine.completeViewSession(
                session.id,
                "daily-view-completion-key-001",
                viewer.userId
            ).getOrThrow()
            assertFalse(completion.alreadyCompleted)

            val first = engine.claimDailyBonus(viewer.userId).getOrThrow()
            val second = engine.claimDailyBonus(viewer.userId).getOrThrow()

            assertTrue(first.granted)
            assertEquals(50L, first.amount)
            assertEquals("ALREADY_CLAIMED", second.reason)

            val updated = engine.fetchAccount(viewer.userId).getOrThrow()
            assertEquals(viewer.availableCoins + completion.reward + 50L, updated.availableCoins)
            assertEquals(
                1,
                engine.fetchTransactions(viewer.userId).getOrThrow()
                    .count { it.type == TransactionType.DAILY_BONUS && it.amount == 50L }
            )
        }

    @Test
    fun dailyBonus_stillRejectsMissingCallerIdentity() =
        kotlinx.coroutines.runBlocking {
            val engine = ServerEmulatedEngine()
            val result = engine.claimDailyBonus(null)

            assertTrue(result.isFailure)
            assertTrue(
                result.exceptionOrNull()?.message?.startsWith("UNAUTHORIZED") == true
            )
        }
}
