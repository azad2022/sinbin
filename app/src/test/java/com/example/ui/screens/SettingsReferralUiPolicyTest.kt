package com.example.ui.screens

import com.example.data.model.ReferralMembership
import com.example.data.model.ReferralStatus
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsReferralUiPolicyTest {
    @Test
    fun inviteEntryRemainsVisibleWhenStatusCannotBeLoaded() {
        assertTrue(shouldShowReferralCodeEntry(null))
    }

    @Test
    fun inviteEntryRemainsVisibleWhenStatusHasNoInviter() {
        assertTrue(shouldShowReferralCodeEntry(ReferralStatus(myReferral = null)))
    }

    @Test
    fun inviteEntryIsHiddenAfterAnInviterHasBeenRegistered() {
        val membership = ReferralMembership(
            inviterHandle = "inviter",
            createdAt = 1L,
            completedViewsCount = 0,
            uniqueWebsitesCount = 0,
            tier100Paid = false,
            tier500Paid = false
        )
        assertFalse(shouldShowReferralCodeEntry(ReferralStatus(myReferral = membership)))
    }
}
