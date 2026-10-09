package com.example.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SettingsScreenBehaviorTest {

    @Test
    fun leaderboardTopThreeReceiveTheMatchingMedalLabel() {
        assertEquals("مدال نفر اول لیدربورد", leaderboardMedalLabel(1))
        assertEquals("مدال نفر دوم لیدربورد", leaderboardMedalLabel(2))
        assertEquals("مدال نفر سوم لیدربورد", leaderboardMedalLabel(3))
    }

    @Test
    fun usersOutsideTopThreeDoNotReceiveAMedal() {
        assertNull(leaderboardMedalLabel(null))
        assertNull(leaderboardMedalLabel(0))
        assertNull(leaderboardMedalLabel(4))
        assertNull(leaderboardMedalLabel(100))
    }
}
