package com.example

import com.example.data.backend.ServerEmulatedEngine
import com.example.data.model.Campaign
import com.example.data.model.CampaignStatus
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.UUID

class ServerAuthoritativeSecurityTest {

    private lateinit var engine: ServerEmulatedEngine

    @Before
    fun setup() {
        engine = ServerEmulatedEngine()
    }

    // =========================================================================
    // 1. Welcome Bonus Tests
    // =========================================================================

    @Test
    fun testWelcomeBonus_newAccountReceivesExactlyOneBonus() = runBlocking {
        val installId = "inst_test_1"
        val result = engine.initAccount(installId, handle = "user_alpha")

        assertTrue(result.isSuccess)
        val account = result.getOrThrow()
        assertEquals(150L, account.availableCoins)
        assertEquals(150L, account.lifetimeEarned)
        assertEquals(0L, account.reservedCoins)

        val txs = engine.fetchTransactions(account.userId).getOrThrow()
        assertEquals(1, txs.size)
        assertEquals(150L, txs[0].amount)
    }

    @Test
    fun testWelcomeBonus_repeatedInitializationGivesNoSecondBonus() = runBlocking {
        val installId = "inst_test_2"
        val first = engine.initAccount(installId, handle = "user_beta").getOrThrow()
        assertEquals(150L, first.availableCoins)

        // Simulate app restart / repeated initialization
        val second = engine.initAccount(installId, handle = "user_beta").getOrThrow()
        assertEquals(150L, second.availableCoins)

        val txs = engine.fetchTransactions(second.userId).getOrThrow()
        // Must remain exactly 1 transaction
        assertEquals(1, txs.size)
    }

    @Test
    fun testWelcomeBonus_reinstallWithSameIdentityGivesNoSecondBonus() = runBlocking {
        val userHandle = "user_gamma"
        val firstInstall = engine.initAccount("inst_device_1", handle = userHandle).getOrThrow()
        assertEquals(150L, firstInstall.availableCoins)

        // User reinstalls app (new installId, but links to same server identity)
        val secondInstall = engine.initAccount("inst_device_2", handle = userHandle).getOrThrow()
        assertEquals(150L, secondInstall.availableCoins)

        val txs = engine.fetchTransactions(userHandle).getOrThrow()
        assertEquals(1, txs.size)
    }

    @Test
    fun testWelcomeBonus_sameInstallIdCannotRegisterSecondAccount() = runBlocking {
        val sharedInstallId = "device_hardware_uuid_999"
        val firstAccount = engine.initAccount(sharedInstallId, handle = "user_first").getOrThrow()
        assertEquals(150L, firstAccount.availableCoins)

        // Attempting to farm welcome bonus by creating a second account with same device install ID must be rejected
        val secondAccountResult = engine.initAccount(sharedInstallId, handle = "user_attacker")
        assertTrue(secondAccountResult.isFailure)
        assertTrue(secondAccountResult.exceptionOrNull()?.message?.contains("INSTALL_ALREADY_REGISTERED") == true)
    }

    @Test
    fun testWelcomeBonus_blankInstallIdRejected() = runBlocking {
        val resBlank = engine.initAccount("   ", handle = "user_blank")
        assertTrue(resBlank.isFailure)
        assertTrue(resBlank.exceptionOrNull()?.message?.contains("INVALID_INSTALL_ID") == true)
    }

    // =========================================================================
    // 2. Campaign Validation & Budget Reservation Tests
    // =========================================================================

    @Test
    fun testCampaign_insufficientCoinsRejected() = runBlocking {
        val account = engine.initAccount("inst_camp_1", handle = "user_camp_1").getOrThrow()
        // Welcome bonus is 150 coins. Let's request a campaign needing 1400 coins (100 views * 14 coins)
        val result = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 15,
            targetViews = 100
        )

        assertTrue(result.isFailure)
        val errorMsg = result.exceptionOrNull()?.message ?: ""
        assertTrue(errorMsg.contains("INSUFFICIENT_BALANCE") || errorMsg.contains("کافی نیست"))

        // Balance must remain intact
        val refetched = engine.fetchAccount(account.userId).getOrThrow()
        assertEquals(150L, refetched.availableCoins)
        assertEquals(0L, refetched.reservedCoins)
    }

    @Test
    fun testCampaign_validCampaignCreatedAndBudgetReserved() = runBlocking {
        val account = engine.initAccount("inst_camp_2", handle = "user_camp_2").getOrThrow()
        // 10 views * 14 coins = 140 coins <= 150 available
        val result = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 15,
            targetViews = 10
        )

        assertTrue(result.isSuccess)
        val campaign = result.getOrThrow()
        assertEquals(10, campaign.targetViews)
        assertEquals(140L, campaign.totalBudget)
        assertEquals(CampaignStatus.ACTIVE, campaign.status)

        val refetched = engine.fetchAccount(account.userId).getOrThrow()
        assertEquals(10L, refetched.availableCoins) // 150 - 140
        assertEquals(140L, refetched.reservedCoins)

        val txs = engine.fetchTransactions(account.userId).getOrThrow()
        assertEquals(2, txs.size) // Welcome bonus + Reservation
        assertEquals(-140L, txs[0].amount)
    }

    @Test
    fun testCampaign_keywordLongerThan25Rejected() = runBlocking {
        engine.initAccount("inst_keyword_limit", handle = "keyword_user").getOrThrow()

        val result = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 5,
            targetViews = 1,
            keyword = "12345678901234567890123456"
        )

        assertTrue(result.isFailure)
        assertTrue(result.exceptionOrNull()?.message?.contains("INVALID_KEYWORD") == true)

        val account = engine.fetchAccount("keyword_user").getOrThrow()
        assertEquals(150L, account.availableCoins)
        assertEquals(0L, account.reservedCoins)
    }

    @Test
    fun testCampaign_invalidDurationRejected() = runBlocking {
        engine.initAccount("inst_camp_3", handle = "user_camp_3").getOrThrow()
        val result = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 999, // Unsupported duration
            targetViews = 5
        )

        assertTrue(result.isFailure)
    }

    @Test
    fun testCampaign_zeroOrNegativeViewsRejected() = runBlocking {
        engine.initAccount("inst_camp_4", handle = "user_camp_4").getOrThrow()
        val zeroRes = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 15,
            targetViews = 0
        )
        assertTrue(zeroRes.isFailure)

        val negRes = engine.createCampaign(
            url = "https://example.com",
            normalizedUrl = "https://example.com",
            domain = "example.com",
            durationSeconds = 15,
            targetViews = -10
        )
        assertTrue(negRes.isFailure)
    }

    // =========================================================================
    // 3. View Session & Reward Validation Tests
    // =========================================================================

    @Test
    fun testView_selfCampaignRejected() = runBlocking {
        val owner = engine.initAccount("inst_owner", handle = "owner_user").getOrThrow()
        engine.createCampaign(
            url = "https://mysite.com",
            normalizedUrl = "https://mysite.com",
            domain = "mysite.com",
            durationSeconds = 5,
            targetViews = 10
        ).getOrThrow()

        // Same user attempts to request view session
        val sessionResult = engine.requestViewSession(owner.userId).getOrThrow()
        // Must reject self campaign (no session returned)
        assertNull(sessionResult)
    }

    @Test
    fun testView_validSessionRewardedOnceAndDuplicateCompletionPrevented() = runBlocking {
        // 1. Create campaign from advertiser
        engine.initAccount("inst_adv", handle = "advertiser").getOrThrow()
        engine.createCampaign(
            url = "https://target-site.com",
            normalizedUrl = "https://target-site.com",
            domain = "target-site.com",
            durationSeconds = 5,
            targetViews = 10
        ).getOrThrow()

        // 2. Viewer requests session
        val viewer = engine.initAccount("inst_viewer", handle = "viewer_1").getOrThrow()
        val initialBalance = viewer.availableCoins

        val session = engine.requestViewSession(viewer.userId).getOrThrow()
        assertNotNull(session)
        assertEquals("target-site.com", session!!.domain)

        // 3. Signal content ready
        engine.signalContentReady(session.id)

        // Simulate server clock duration passing
        Thread.sleep(4100) // 5s required - 1s network tolerance = 4.0s

        // 4. Complete view session
        val idempotencyKey = "test_key_1"
        val rewardRes = engine.completeViewSession(session.id, idempotencyKey)
        assertTrue(rewardRes.isSuccess)
        val completion = rewardRes.getOrThrow()
        assertEquals(3L, completion.reward) // 5s duration reward = 3 coins
        assertEquals(initialBalance + completion.reward, completion.availableCoins)
        assertEquals(1, completion.completedViewsCount)
        assertEquals(150L + completion.reward, completion.lifetimeEarned)
        assertTrue(!completion.alreadyCompleted)

        val refetchedViewer = engine.fetchAccount(viewer.userId).getOrThrow()
        assertEquals(completion.availableCoins, refetchedViewer.availableCoins)

        // 5. Duplicate completion attempt with same idempotency key
        val dupRewardRes = engine.completeViewSession(session.id, idempotencyKey)
        assertTrue(dupRewardRes.isSuccess)
        assertEquals(completion.reward, dupRewardRes.getOrThrow().reward)
        assertTrue(dupRewardRes.getOrThrow().alreadyCompleted)

        // Balance MUST NOT increase twice!
        val viewerAfterDup = engine.fetchAccount(viewer.userId).getOrThrow()
        assertEquals(initialBalance + completion.reward, viewerAfterDup.availableCoins)

        // 6. Duplicate completion attempt with different idempotency key on completed session
        val diffKeyRes = engine.completeViewSession(session.id, "different_key_2")
        assertTrue(diffKeyRes.isSuccess)
        val viewerAfterDiffKey = engine.fetchAccount(viewer.userId).getOrThrow()
        assertEquals(initialBalance + completion.reward, viewerAfterDiffKey.availableCoins)
    }

    @Test
    fun testView_incompleteOrNonContentReadySessionCannotBeCompleted() = runBlocking {
        engine.initAccount("inst_adv_ready", handle = "advertiser_ready").getOrThrow()
        engine.createCampaign(
            url = "https://ready-test.com",
            normalizedUrl = "https://ready-test.com",
            domain = "ready-test.com",
            durationSeconds = 5,
            targetViews = 5
        ).getOrThrow()

        val viewer = engine.initAccount("inst_viewer_not_ready", handle = "viewer_not_ready").getOrThrow()
        val session = engine.requestViewSession(viewer.userId).getOrThrow()!!

        // Notice: signalContentReady was NEVER called (session is INITIALIZED, not CONTENT_READY)
        val completeRes = engine.completeViewSession(session.id, "key_unready_1")
        assertTrue(completeRes.isFailure)
        assertTrue(completeRes.exceptionOrNull()?.message?.contains("INVALID_SESSION_STATUS") == true)
    }

    @Test
    fun testIdempotency_differentSessionReusingKeyRejected() = runBlocking {
        engine.initAccount("inst_adv_idem", handle = "advertiser_idem").getOrThrow()
        engine.createCampaign(
            url = "https://idem-test.com",
            normalizedUrl = "https://idem-test.com",
            domain = "idem-test.com",
            durationSeconds = 5,
            targetViews = 10
        ).getOrThrow()

        val viewer1 = engine.initAccount("inst_v_idem1", handle = "viewer_idem1").getOrThrow()
        val session1 = engine.requestViewSession(viewer1.userId).getOrThrow()!!
        engine.signalContentReady(session1.id)
        Thread.sleep(4100)
        val reusedKey = "shared_key_unique_123"
        val res1 = engine.completeViewSession(session1.id, reusedKey)
        assertTrue(res1.isSuccess)

        // Another session attempting to reuse the same key must be rejected
        val viewer2 = engine.initAccount("inst_v_idem2", handle = "viewer_idem2").getOrThrow()
        val session2 = engine.requestViewSession(viewer2.userId).getOrThrow()!!
        engine.signalContentReady(session2.id)
        Thread.sleep(4100)
        val res2 = engine.completeViewSession(session2.id, reusedKey)
        assertTrue(res2.isFailure)
        assertTrue(res2.exceptionOrNull()?.message?.contains("IDEMPOTENCY_KEY_CONFLICT") == true)
    }

    @Test
    fun testView_exhaustedOrInactiveCampaignRejected() = runBlocking {
        engine.initAccount("inst_adv_2", handle = "advertiser_2").getOrThrow()
        val campaign = engine.createCampaign(
            url = "https://one-view-site.com",
            normalizedUrl = "https://one-view-site.com",
            domain = "one-view-site.com",
            durationSeconds = 5,
            targetViews = 1 // Only 1 view allowed
        ).getOrThrow()

        val viewer1 = engine.initAccount("inst_v1", handle = "viewer_alpha").getOrThrow()
        val session1 = engine.requestViewSession(viewer1.userId).getOrThrow()
        assertNotNull(session1)
        engine.signalContentReady(session1!!.id)
        Thread.sleep(4100)
        engine.completeViewSession(session1.id, "key_v1")

        // Campaign should now be COMPLETED / exhausted
        val viewer2 = engine.initAccount("inst_v2", handle = "viewer_beta").getOrThrow()
        val session2 = engine.requestViewSession(viewer2.userId).getOrThrow()
        assertNull(session2) // Exhausted campaign rejected
    }

    @Test
    fun testView_pausedCampaignAllowsCompletionOfInFlightSession() = runBlocking {
        engine.initAccount("inst_adv_p", handle = "advertiser_p").getOrThrow()
        val campaign = engine.createCampaign(
            url = "https://pause-test.com",
            normalizedUrl = "https://pause-test.com",
            domain = "pause-test.com",
            durationSeconds = 5,
            targetViews = 5,
            callerUserId = "advertiser_p"
        ).getOrThrow()

        val viewer = engine.initAccount("inst_viewer_p", handle = "viewer_p").getOrThrow()
        val session = engine.requestViewSession(viewer.userId).getOrThrow()!!
        engine.signalContentReady(session.id, callerUserId = viewer.userId)

        // Advertiser pauses campaign while viewer is genuinely watching
        engine.pauseCampaign(campaign.id, callerUserId = "advertiser_p")

        Thread.sleep(4100)

        // In-flight session issued prior to pause must be allowed to complete and be rewarded
        val completeRes = engine.completeViewSession(session.id, "key_pause_1", callerUserId = viewer.userId)
        assertTrue(completeRes.isSuccess)
        assertEquals(3L, completeRes.getOrThrow().reward)

        // However, NEW sessions must NOT be dispatched for paused campaign
        val viewer2 = engine.initAccount("inst_v_p2", handle = "viewer_p2").getOrThrow()
        val newSession = engine.requestViewSession(viewer2.userId).getOrThrow()
        assertNull(newSession)
    }

    @Test
    fun testView_signalContentReadyIsIdempotent() = runBlocking {
        engine.initAccount("inst_adv_signal", handle = "advertiser_signal").getOrThrow()
        engine.createCampaign(
            url = "https://signal-test.com",
            normalizedUrl = "https://signal-test.com",
            domain = "signal-test.com",
            durationSeconds = 5,
            targetViews = 2
        ).getOrThrow()

        val viewer = engine.initAccount("inst_viewer_signal", handle = "viewer_signal").getOrThrow()
        val session = engine.requestViewSession(viewer.userId).getOrThrow()!!

        assertTrue(engine.signalContentReady(session.id, callerUserId = viewer.userId).getOrThrow())
        assertTrue(!engine.signalContentReady(session.id, callerUserId = viewer.userId).getOrThrow())
    }

    @Test
    fun testView_cancelSessionPreventsImmediateReuseAndIsOwnerBound() = runBlocking {
        engine.initAccount("inst_adv_cancel", handle = "advertiser_cancel").getOrThrow()
        engine.createCampaign(
            url = "https://cancel-test.com",
            normalizedUrl = "https://cancel-test.com",
            domain = "cancel-test.com",
            durationSeconds = 5,
            targetViews = 2
        ).getOrThrow()

        val viewer = engine.initAccount("inst_viewer_cancel", handle = "viewer_cancel").getOrThrow()
        val otherViewer = engine.initAccount("inst_other_cancel", handle = "viewer_other_cancel").getOrThrow()
        val session = engine.requestViewSession(viewer.userId).getOrThrow()!!

        assertTrue(engine.cancelViewSession(session.id, callerUserId = viewer.userId).getOrThrow())
        assertTrue(engine.cancelViewSession(session.id, callerUserId = viewer.userId).getOrThrow() == false)
        assertTrue(engine.cancelViewSession(session.id, callerUserId = otherViewer.userId).isFailure)

        val newSession = engine.requestViewSession(viewer.userId).getOrThrow()
        assertNotNull(newSession)
        assertTrue(newSession!!.id != session.id)
    }

    @Test
    fun testView_randomizedDistributionAvoidsAdvertiserMonopoly() = runBlocking {
        var now = 1_000_000L
        val distributionEngine = ServerEmulatedEngine { now }

        val advertisers = listOf(
            distributionEngine.initAccount("inst_dist_adv_1", handle = "dist_adv_1").getOrThrow(),
            distributionEngine.initAccount("inst_dist_adv_2", handle = "dist_adv_2").getOrThrow(),
            distributionEngine.initAccount("inst_dist_adv_3", handle = "dist_adv_3").getOrThrow(),
            distributionEngine.initAccount("inst_dist_adv_4", handle = "dist_adv_4").getOrThrow()
        )

        listOf(
            "https://distribution-one.example.com",
            "https://distribution-two.example.com",
            "https://distribution-three.example.com",
            "https://distribution-four.example.com"
        ).forEachIndexed { index, url ->
            distributionEngine.createCampaign(
                url = url,
                normalizedUrl = url,
                domain = "distribution-${index + 1}.example.com",
                durationSeconds = 5,
                targetViews = 20,
                callerUserId = advertisers[index].userId
            ).getOrThrow()
        }

        val viewer = distributionEngine.initAccount(
            "inst_dist_viewer",
            handle = "dist_viewer"
        ).getOrThrow()

        val firstSession = distributionEngine.requestViewSession(viewer.userId).getOrThrow()!!
        val firstCampaign = distributionEngine.fetchCampaigns(viewer.userId).getOrThrow()
            .first { it.id == firstSession.campaignId }
        val firstOwner = firstCampaign.ownerId

        distributionEngine.signalContentReady(firstSession.id, callerUserId = viewer.userId)
        now += 4_000L
        assertTrue(
            distributionEngine.completeViewSession(
                firstSession.id,
                "distribution_complete_1",
                callerUserId = viewer.userId
            ).isSuccess
        )

        val selectedCampaignIds = linkedSetOf<String>()
        repeat(20) {
            val session = distributionEngine.requestViewSession(viewer.userId).getOrThrow()!!
            selectedCampaignIds += session.campaignId

            val campaign = distributionEngine.fetchCampaigns(viewer.userId).getOrThrow()
                .first { it.id == session.campaignId }

            assertTrue(
                "Recently completed advertiser was selected again too soon",
                campaign.ownerId != firstOwner
            )

            assertTrue(
                distributionEngine.cancelViewSession(
                    session.id,
                    callerUserId = viewer.userId
                ).getOrThrow()
            )
            now += 1_000L
        }

        assertTrue(
            "Randomized viewer distribution selected only one campaign across 20 requests",
            selectedCampaignIds.size >= 2
        )
    }

    // =========================================================================
    // 4. Concurrency Race Condition Tests
    // =========================================================================

    @Test
    fun testConcurrency_twoSimultaneousCompletionsProduceExactlyOneReward() = runBlocking {
        engine.initAccount("inst_adv_c", handle = "advertiser_c").getOrThrow()
        engine.createCampaign(
            url = "https://concurrent-site.com",
            normalizedUrl = "https://concurrent-site.com",
            domain = "concurrent-site.com",
            durationSeconds = 5,
            targetViews = 5
        ).getOrThrow()

        val viewer = engine.initAccount("inst_viewer_c", handle = "viewer_concurrent").getOrThrow()
        val initialCoins = viewer.availableCoins
        val session = engine.requestViewSession(viewer.userId).getOrThrow()!!
        engine.signalContentReady(session.id)
        Thread.sleep(4100)

        // Launch 2 parallel completion coroutines
        val task1 = async { engine.completeViewSession(session.id, "race_key_1") }
        val task2 = async { engine.completeViewSession(session.id, "race_key_1") }

        val results = awaitAll(task1, task2)
        assertTrue(results.all { it.isSuccess })

        val finalViewer = engine.fetchAccount(viewer.userId).getOrThrow()
        // Exactly one reward of 3 coins must be credited!
        assertEquals(initialCoins + 3L, finalViewer.availableCoins)
    }

    @Test
    fun testConcurrency_twoSimultaneousCampaignCreationsCannotOverspend() = runBlocking {
        // User has 150 coins.
        // We attempt 2 simultaneous campaign creations each demanding 140 coins (Total = 280 > 150)
        val user = engine.initAccount("inst_overspend", handle = "user_overspend").getOrThrow()
        assertEquals(150L, user.availableCoins)

        val task1 = async {
            engine.createCampaign(
                url = "https://site1.com",
                normalizedUrl = "https://site1.com",
                domain = "site1.com",
                durationSeconds = 15,
                targetViews = 10 // 140 coins
            )
        }
        val task2 = async {
            engine.createCampaign(
                url = "https://site2.com",
                normalizedUrl = "https://site2.com",
                domain = "site2.com",
                durationSeconds = 15,
                targetViews = 10 // 140 coins
            )
        }

        val results = awaitAll(task1, task2)
        val successes = results.count { it.isSuccess }
        val failures = results.count { it.isFailure }

        // Exactly one MUST succeed and the other MUST fail due to insufficient coins!
        assertEquals(1, successes)
        assertEquals(1, failures)

        val refetched = engine.fetchAccount(user.userId).getOrThrow()
        assertEquals(10L, refetched.availableCoins) // 150 - 140
        assertEquals(140L, refetched.reservedCoins)
        assertTrue(refetched.availableCoins >= 0) // No overspending
    }
}
