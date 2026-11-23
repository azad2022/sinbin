package com.example.ui.screens

import com.example.data.model.DailyBonusResult
import com.example.data.repository.buildRolling30Leaderboard
import com.example.data.model.Rolling30LeaderboardEntry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HomeScreenBehaviorTest {

    @Test
    fun welcomeBonusBanner_isVisibleOnlyWithinTwoHours() {
        val grantedAt = 1_000_000L

        assertTrue(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt + WELCOME_BONUS_BANNER_DURATION_MS - 1L
            )
        )
        assertFalse(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt + WELCOME_BONUS_BANNER_DURATION_MS
            )
        )
        assertFalse(
            isWelcomeBonusBannerVisible(
                grantedAtMillis = grantedAt,
                nowMillis = grantedAt - 1L
            )
        )
    }

    @Test
    fun alreadyClaimedDailyBonusBannerIsHiddenWithoutChangingGrantLogic() {
        assertFalse(
            shouldShowDailyBonusBanner(
                DailyBonusResult(
                    granted = false,
                    amount = 0L,
                    grantDate = "2026-10-09",
                    reason = "ALREADY_CLAIMED"
                )
            )
        )
    }

    @Test
    fun dailyBonusBannerRemainsForActionableAndNewlyGrantedStates() {
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "2026-10-09", "WELCOME_DAY")
            )
        )
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "2026-10-09", "VISIT_REQUIRED")
            )
        )
        assertTrue(
            shouldShowDailyBonusBanner(
                DailyBonusResult(true, 50L, "2026-10-09", null)
            )
        )
    }

    @Test
    fun homeActionCardsRotateRequestedSubtitlesWithoutRemovingOriginalCopy() {
        assertEquals(
            listOf(
                "با مشاهده وب‌سایت‌های دیگران سکه رایگان دریافت کن و به موجودی خودت اضافه کن.",
                "هر چقدر بیشتر بازدید کنی امکان اینکه نفر اول لیدربورد بشی بیشتر میشه",
                "نفرات برتر لیدربورد لینک های آنها در صفحات ابتدایی مرورگر به ترتیب نمایش داده میشه"
            ),
            HOME_VIEWING_CARD_SUBTITLES
        )
        assertEquals(
            listOf(
                "با سکه‌های خود برای وب‌سایتت بازدید واقعی، هدفمند و بر اساس ثانیه دلخواه دریافت کن.",
                "زمان بیشتر و بازدید بیشتر و مداوم از وبسایتت تاثیر سئوی آن بیشتر خواهد بود",
                "سکه های بیشتر بگیر بازدید بیشتر دریافت کن و با تداوم باعث سئوی سایتت شو"
            ),
            HOME_ADVERTISING_CARD_SUBTITLES
        )
    }

    @Test
    fun dailyBonusBannerIsHiddenWhenServerDateIsMissing() {
        assertFalse(
            shouldShowDailyBonusBanner(
                DailyBonusResult(false, 50L, "", "VISIT_REQUIRED")
            )
        )
    }

    @Test
    fun leaderboardPodiumOrdersRowsAsBronzeGoldSilverForVisualPlacement() {
        val entries = listOf(
            Rolling30LeaderboardEntry(rank = 5, userHandle = "fifth", completedViews = 3),
            Rolling30LeaderboardEntry(rank = 2, userHandle = "second", completedViews = 25),
            Rolling30LeaderboardEntry(rank = 1, userHandle = "first", completedViews = 47),
            Rolling30LeaderboardEntry(rank = 4, userHandle = "fourth", completedViews = 5),
            Rolling30LeaderboardEntry(rank = 3, userHandle = "third", completedViews = 9)
        )

        assertEquals(
            listOf(3, 1, 2),
            rolling30LeaderboardPodiumOrder(entries).map { it?.rank }
        )
    }

    @Test
    fun leaderboardShowsOnlyTopFiveAndPlacesFourthAndFifthInRows() {
        val entries = (8 downTo 1).map { rank ->
            Rolling30LeaderboardEntry(
                rank = rank,
                userHandle = "user_$rank",
                completedViews = rank * 10
            )
        }

        assertEquals(
            listOf(1, 2, 3, 4, 5),
            rolling30LeaderboardTopFive(entries).map { it.rank }
        )
        assertEquals(
            listOf(4, 5),
            rolling30LeaderboardLowerRows(entries).map { it.rank }
        )
    }

    @Test
    fun leaderboardHandlesMissingPodiumRanksWithoutInventingEntries() {
        val entries = listOf(
            Rolling30LeaderboardEntry(rank = 1, userHandle = "first", completedViews = 7),
            Rolling30LeaderboardEntry(rank = 3, userHandle = "third", completedViews = 2)
        )

        assertEquals(
            listOf(3, 1, null),
            rolling30LeaderboardPodiumOrder(entries).map { it?.rank }
        )
    }

    @Test
    fun rolling30LeaderboardShowsServerRankViewsAndGapForUserOutsideTopFive() {
        val rows = (1..8).map { rank ->
            Rolling30LeaderboardEntry(
                rank = rank,
                userHandle = "user_$rank",
                completedViews = 100 - (rank * 10)
            )
        }

        val result = buildRolling30Leaderboard(rows.reversed(), "USER_8")

        assertEquals(listOf(1, 2, 3, 4, 5), result.entries.map { it.rank })
        assertEquals(8, result.currentUserRank)
        assertEquals(20, result.currentUserViews)
        assertEquals(11, result.viewsToNextRank)
    }

    @Test
    fun rolling30LeaderboardDoesNotInventGapWhenPreviousRankIsMissing() {
        val result = buildRolling30Leaderboard(
            listOf(
                Rolling30LeaderboardEntry(1, "first", 20),
                Rolling30LeaderboardEntry(3, "current", 5)
            ),
            "current"
        )

        assertEquals(3, result.currentUserRank)
        assertEquals(5, result.currentUserViews)
        assertEquals(null, result.viewsToNextRank)
    }

}
