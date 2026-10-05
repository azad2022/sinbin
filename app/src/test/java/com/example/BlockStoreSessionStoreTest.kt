package com.example

import com.example.data.security.BlockStoreSessionStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Test

class BlockStoreSessionStoreTest {

    @Test
    fun codec_roundTripsRefreshTokenAndUserId() {
        val payload = BlockStoreSessionStore.encode(
            refreshToken = "refresh-token-123",
            userId = "11111111-1111-4111-8111-111111111111"
        )

        val decoded = BlockStoreSessionStore.decode(payload)

        assertNotNull(decoded)
        assertEquals("refresh-token-123", decoded?.refreshToken)
        assertEquals("11111111-1111-4111-8111-111111111111", decoded?.userId)
    }

    @Test
    fun codec_rejectsUnknownVersionAndMissingRefreshToken() {
        val unknown = """{"version":999,"refresh_token":"x"}""".toByteArray()
        val missing = """{"version":1}""".toByteArray()

        assertNull(BlockStoreSessionStore.decode(unknown))
        assertNull(BlockStoreSessionStore.decode(missing))
    }
}
